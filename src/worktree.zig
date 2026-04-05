const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_diff = @import("tree_diff.zig");
const ref_mod = @import("ref.zig");
const checkout_mod = @import("checkout.zig");
const index_mod = @import("index.zig");
const loose = @import("loose.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Worktree subcommands.
pub const WorktreeCommand = enum {
    list,
    add,
    remove,
    prune,
    lock,
    unlock,
    move_wt,
};

/// Information about a worktree.
pub const WorktreeInfo = struct {
    path: []u8,
    head_oid: ?types.ObjectId,
    branch: ?[]u8,
    is_bare: bool,
    is_main: bool,
    is_detached: bool,
    is_locked: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WorktreeInfo) void {
        self.allocator.free(self.path);
        if (self.branch) |b| self.allocator.free(b);
    }
};

/// Entry point for the worktree command.
pub fn runWorktree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        try printWorktreeUsage();
        std.process.exit(1);
    }

    const subcmd_str = args[0];
    const subcmd = parseWorktreeCommand(subcmd_str) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: unknown worktree subcommand '{s}'\n", .{subcmd_str}) catch
            "error: unknown worktree subcommand\n";
        try stderr_file.writeAll(msg);
        try printWorktreeUsage();
        std.process.exit(1);
    };

    const sub_args = args[1..];

    switch (subcmd) {
        .list => return worktreeList(repo, allocator),
        .add => return worktreeAdd(repo, allocator, sub_args),
        .remove => return worktreeRemove(repo, allocator, sub_args),
        .prune => return worktreePrune(repo, allocator),
        .lock => return worktreeLock(repo, allocator, sub_args),
        .unlock => return worktreeUnlock(repo, allocator, sub_args),
        .move_wt => {
            try stderr_file.writeAll("error: worktree move is not yet implemented\n");
            std.process.exit(1);
        },
    }
}

fn parseWorktreeCommand(s: []const u8) ?WorktreeCommand {
    if (std.mem.eql(u8, s, "list")) return .list;
    if (std.mem.eql(u8, s, "add")) return .add;
    if (std.mem.eql(u8, s, "remove")) return .remove;
    if (std.mem.eql(u8, s, "prune")) return .prune;
    if (std.mem.eql(u8, s, "lock")) return .lock;
    if (std.mem.eql(u8, s, "unlock")) return .unlock;
    if (std.mem.eql(u8, s, "move")) return .move_wt;
    return null;
}

fn printWorktreeUsage() !void {
    try stderr_file.writeAll(
        \\usage: zig-git worktree <subcommand>
        \\
        \\Subcommands:
        \\  list                    List linked worktrees
        \\  add <path> [<branch>]   Create a new worktree
        \\  remove <path>           Remove a worktree
        \\  prune                   Prune stale worktree information
        \\  lock <path>             Lock a worktree
        \\  unlock <path>           Unlock a worktree
        \\
    );
}

/// List all worktrees.
fn worktreeList(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    var worktrees = try collectWorktrees(allocator, repo.git_dir);
    defer {
        for (worktrees.items) |*wt| {
            wt.deinit();
        }
        worktrees.deinit();
    }

    for (worktrees.items) |*wt| {
        try outputWorktreeInfo(wt);
    }
}

/// Add a new worktree.
fn worktreeAdd(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var wt_path: ?[]const u8 = null;
    var branch_name: ?[]const u8 = null;
    var create_branch = false;
    var detach = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-b")) {
            create_branch = true;
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("error: -b requires a branch name\n");
                std.process.exit(1);
            }
            branch_name = args[i];
        } else if (std.mem.eql(u8, arg, "--detach")) {
            detach = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (wt_path == null) {
                wt_path = arg;
            } else if (branch_name == null) {
                branch_name = arg;
            }
        }
    }

    if (wt_path == null) {
        try stderr_file.writeAll("error: no path specified for worktree\n");
        std.process.exit(1);
    }

    const path = wt_path.?;

    // Resolve the absolute path
    var abs_path_buf: [4096]u8 = undefined;
    const abs_path = try resolveAbsolutePath(allocator, path, &abs_path_buf);

    // Get the main repository git dir
    const main_git_dir = getMainGitDir(repo.git_dir);

    // Determine the worktree name (last component of path)
    const wt_name = std.fs.path.basename(abs_path);

    // Resolve the commit to checkout
    const checkout_ref = branch_name orelse "HEAD";
    const head_oid = repo.resolveRef(allocator, checkout_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: invalid reference '{s}'\n", .{checkout_ref}) catch
            "fatal: invalid reference\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    // Create the target directory
    std.fs.makeDirAbsolute(abs_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try stderr_file.writeAll("fatal: destination path already exists\n");
            std.process.exit(128);
        },
        error.FileNotFound => {
            // Try to create parent directories
            const parent = std.fs.path.dirname(abs_path) orelse {
                try stderr_file.writeAll("fatal: cannot create worktree directory\n");
                std.process.exit(128);
            };
            mkdirRecursive(parent) catch {
                try stderr_file.writeAll("fatal: cannot create parent directories\n");
                std.process.exit(128);
            };
            std.fs.makeDirAbsolute(abs_path) catch {
                try stderr_file.writeAll("fatal: cannot create worktree directory\n");
                std.process.exit(128);
            };
        },
        else => {
            try stderr_file.writeAll("fatal: cannot create worktree directory\n");
            std.process.exit(128);
        },
    };

    // Create .git/worktrees/<name>/ in the main repo
    var wt_dir_buf: [4096]u8 = undefined;
    var wt_dir_pos: usize = 0;
    @memcpy(wt_dir_buf[wt_dir_pos..][0..main_git_dir.len], main_git_dir);
    wt_dir_pos += main_git_dir.len;
    const wt_suffix = "/worktrees/";
    @memcpy(wt_dir_buf[wt_dir_pos..][0..wt_suffix.len], wt_suffix);
    wt_dir_pos += wt_suffix.len;
    @memcpy(wt_dir_buf[wt_dir_pos..][0..wt_name.len], wt_name);
    wt_dir_pos += wt_name.len;
    const wt_admin_dir = wt_dir_buf[0..wt_dir_pos];

    mkdirRecursive(wt_admin_dir) catch {
        try stderr_file.writeAll("fatal: cannot create worktree admin directory\n");
        std.process.exit(128);
    };

    // Write gitdir file in worktrees/<name>/gitdir (points to the worktree's .git file)
    {
        var gitdir_path_buf: [4096]u8 = undefined;
        const gitdir_path = buildPath(&gitdir_path_buf, wt_admin_dir, "/gitdir");

        const file = try std.fs.createFileAbsolute(gitdir_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(abs_path);
        try file.writeAll("/.git\n");
    }

    // Write HEAD in worktrees/<name>/HEAD
    {
        var head_path_buf: [4096]u8 = undefined;
        const head_path = buildPath(&head_path_buf, wt_admin_dir, "/HEAD");

        const file = try std.fs.createFileAbsolute(head_path, .{ .truncate = true });
        defer file.close();

        if (branch_name != null and !detach) {
            // Create a symbolic ref
            try file.writeAll("ref: refs/heads/");
            try file.writeAll(branch_name.?);
            try file.writeAll("\n");

            // Create the branch if needed
            if (create_branch) {
                var ref_path_buf: [4096]u8 = undefined;
                var rpos: usize = 0;
                @memcpy(ref_path_buf[rpos..][0..main_git_dir.len], main_git_dir);
                rpos += main_git_dir.len;
                const refs_prefix = "/refs/heads/";
                @memcpy(ref_path_buf[rpos..][0..refs_prefix.len], refs_prefix);
                rpos += refs_prefix.len;
                @memcpy(ref_path_buf[rpos..][0..branch_name.?.len], branch_name.?);
                rpos += branch_name.?.len;

                // Ensure directory exists
                const dir_end = std.mem.lastIndexOfScalar(u8, ref_path_buf[0..rpos], '/') orelse {
                    try stderr_file.writeAll("fatal: invalid branch name\n");
                    std.process.exit(128);
                };
                mkdirRecursive(ref_path_buf[0..dir_end]) catch {};

                const ref_file = try std.fs.createFileAbsolute(ref_path_buf[0..rpos], .{ .truncate = true });
                defer ref_file.close();
                const hex = head_oid.toHex();
                try ref_file.writeAll(&hex);
                try ref_file.writeAll("\n");
            }
        } else {
            // Detached HEAD
            const hex = head_oid.toHex();
            try file.writeAll(&hex);
            try file.writeAll("\n");
        }
    }

    // Write commondir in worktrees/<name>/commondir
    {
        var cd_path_buf: [4096]u8 = undefined;
        const cd_path = buildPath(&cd_path_buf, wt_admin_dir, "/commondir");

        const file = try std.fs.createFileAbsolute(cd_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("../..\n");
    }

    // Create .git file in the worktree directory (pointing to admin dir)
    {
        var git_file_path_buf: [4096]u8 = undefined;
        const git_file_path = buildPath(&git_file_path_buf, abs_path, "/.git");

        const file = try std.fs.createFileAbsolute(git_file_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("gitdir: ");
        try file.writeAll(wt_admin_dir);
        try file.writeAll("\n");
    }

    // Checkout the tree into the worktree
    var obj = try repo.readObject(allocator, &head_oid);
    defer obj.deinit();

    if (obj.obj_type == .commit) {
        const tree_oid = try tree_diff.getCommitTreeOid(obj.data);
        try checkoutTreeToDir(allocator, repo, &tree_oid, abs_path);
    }

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Preparing worktree (new branch '{s}') at '{s}'\n", .{
        branch_name orelse "detached",
        abs_path,
    }) catch "Worktree created.\n";
    try stdout_file.writeAll(msg);
}

/// Remove a worktree.
fn worktreeRemove(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var force = false;
    var target_path: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            target_path = arg;
        }
    }

    if (target_path == null) {
        try stderr_file.writeAll("error: no worktree path specified\n");
        std.process.exit(1);
    }

    var abs_path_buf: [4096]u8 = undefined;
    const abs_path = try resolveAbsolutePath(allocator, target_path.?, &abs_path_buf);

    const main_git_dir = getMainGitDir(repo.git_dir);

    // Find the worktree admin directory
    const wt_name = std.fs.path.basename(abs_path);

    var wt_dir_buf: [4096]u8 = undefined;
    var wt_dir_pos: usize = 0;
    @memcpy(wt_dir_buf[wt_dir_pos..][0..main_git_dir.len], main_git_dir);
    wt_dir_pos += main_git_dir.len;
    const wt_suffix = "/worktrees/";
    @memcpy(wt_dir_buf[wt_dir_pos..][0..wt_suffix.len], wt_suffix);
    wt_dir_pos += wt_suffix.len;
    @memcpy(wt_dir_buf[wt_dir_pos..][0..wt_name.len], wt_name);
    wt_dir_pos += wt_name.len;
    const wt_admin_dir = wt_dir_buf[0..wt_dir_pos];

    // Check if the admin dir exists
    {
        const dir = std.fs.openDirAbsolute(wt_admin_dir, .{}) catch {
            try stderr_file.writeAll("error: not a valid worktree\n");
            std.process.exit(1);
        };
        @constCast(&dir).close();
    }

    // Check for lock
    {
        var lock_buf: [4096]u8 = undefined;
        const lock_path = buildPath(&lock_buf, wt_admin_dir, "/locked");
        const lock_file = std.fs.openFileAbsolute(lock_path, .{}) catch null;
        if (lock_file) |f| {
            f.close();
            try stderr_file.writeAll("error: worktree is locked\n");
            try stderr_file.writeAll("hint: use 'zig-git worktree unlock' first\n");
            std.process.exit(1);
        }
    }

    // Remove the worktree directory
    removeDirectoryRecursive(abs_path) catch {
        try stderr_file.writeAll("warning: could not remove worktree directory\n");
    };

    // Remove admin files
    removeAdminDir(wt_admin_dir);

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Removed worktree '{s}'\n", .{abs_path}) catch
        "Worktree removed.\n";
    try stdout_file.writeAll(msg);
}

/// Prune stale worktree information.
fn worktreePrune(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator;
    const main_git_dir = getMainGitDir(repo.git_dir);

    var wt_dir_buf: [4096]u8 = undefined;
    const wt_dir = buildPath(&wt_dir_buf, main_git_dir, "/worktrees");

    var dir = std.fs.openDirAbsolute(wt_dir, .{ .iterate = true }) catch {
        try stdout_file.writeAll("Nothing to prune.\n");
        return;
    };
    defer dir.close();

    var pruned_count: usize = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        // Check if the worktree directory still exists
        var gitdir_path_buf: [4096]u8 = undefined;
        var gpos: usize = 0;
        @memcpy(gitdir_path_buf[gpos..][0..wt_dir.len], wt_dir);
        gpos += wt_dir.len;
        gitdir_path_buf[gpos] = '/';
        gpos += 1;
        @memcpy(gitdir_path_buf[gpos..][0..entry.name.len], entry.name);
        gpos += entry.name.len;
        const sub_dir = gitdir_path_buf[0..gpos];

        var gitdir_file_buf: [4096]u8 = undefined;
        const gitdir_file_path = buildPath(&gitdir_file_buf, sub_dir, "/gitdir");

        // Read the gitdir file to see where the worktree is
        const file = std.fs.openFileAbsolute(gitdir_file_path, .{}) catch {
            // No gitdir file, prune this entry
            removeAdminDir(sub_dir);
            pruned_count += 1;
            continue;
        };
        defer file.close();

        var read_buf: [4096]u8 = undefined;
        const n = file.read(&read_buf) catch {
            removeAdminDir(sub_dir);
            pruned_count += 1;
            continue;
        };
        const content = std.mem.trimRight(u8, read_buf[0..n], "\n\r ");

        // Check if the worktree path exists
        const wt_git_file = std.fs.openFileAbsolute(content, .{}) catch {
            // Worktree doesn't exist anymore, prune
            removeAdminDir(sub_dir);
            pruned_count += 1;
            continue;
        };
        wt_git_file.close();
    }

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Pruned {d} stale worktree entries.\n", .{pruned_count}) catch
        "Pruning complete.\n";
    try stdout_file.writeAll(msg);
}

/// Lock a worktree.
fn worktreeLock(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var target_path: ?[]const u8 = null;
    var reason: []const u8 = "";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--reason")) {
            i += 1;
            if (i < args.len) reason = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            target_path = arg;
        }
    }

    if (target_path == null) {
        try stderr_file.writeAll("error: no worktree path specified\n");
        std.process.exit(1);
    }

    var abs_path_buf: [4096]u8 = undefined;
    const abs_path = try resolveAbsolutePath(allocator, target_path.?, &abs_path_buf);

    const main_git_dir = getMainGitDir(repo.git_dir);
    const wt_name = std.fs.path.basename(abs_path);

    var lock_path_buf: [4096]u8 = undefined;
    var lpos: usize = 0;
    @memcpy(lock_path_buf[lpos..][0..main_git_dir.len], main_git_dir);
    lpos += main_git_dir.len;
    const lock_suffix = "/worktrees/";
    @memcpy(lock_path_buf[lpos..][0..lock_suffix.len], lock_suffix);
    lpos += lock_suffix.len;
    @memcpy(lock_path_buf[lpos..][0..wt_name.len], wt_name);
    lpos += wt_name.len;
    const locked_suffix = "/locked";
    @memcpy(lock_path_buf[lpos..][0..locked_suffix.len], locked_suffix);
    lpos += locked_suffix.len;
    const lock_path = lock_path_buf[0..lpos];

    const file = std.fs.createFileAbsolute(lock_path, .{ .truncate = true }) catch {
        try stderr_file.writeAll("error: cannot lock worktree\n");
        std.process.exit(1);
    };
    defer file.close();
    file.writeAll(reason) catch {};

    try stdout_file.writeAll("Worktree locked.\n");
}

/// Unlock a worktree.
fn worktreeUnlock(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var target_path: ?[]const u8 = null;

    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            target_path = arg;
        }
    }

    if (target_path == null) {
        try stderr_file.writeAll("error: no worktree path specified\n");
        std.process.exit(1);
    }

    var abs_path_buf: [4096]u8 = undefined;
    const abs_path = try resolveAbsolutePath(allocator, target_path.?, &abs_path_buf);

    const main_git_dir = getMainGitDir(repo.git_dir);
    const wt_name = std.fs.path.basename(abs_path);

    var lock_path_buf: [4096]u8 = undefined;
    var lpos: usize = 0;
    @memcpy(lock_path_buf[lpos..][0..main_git_dir.len], main_git_dir);
    lpos += main_git_dir.len;
    const lock_suffix = "/worktrees/";
    @memcpy(lock_path_buf[lpos..][0..lock_suffix.len], lock_suffix);
    lpos += lock_suffix.len;
    @memcpy(lock_path_buf[lpos..][0..wt_name.len], wt_name);
    lpos += wt_name.len;
    const locked_suffix = "/locked";
    @memcpy(lock_path_buf[lpos..][0..locked_suffix.len], locked_suffix);
    lpos += locked_suffix.len;
    const lock_path = lock_path_buf[0..lpos];

    std.fs.deleteFileAbsolute(lock_path) catch {
        try stderr_file.writeAll("error: worktree is not locked\n");
        std.process.exit(1);
    };

    try stdout_file.writeAll("Worktree unlocked.\n");
}

/// Collect information about all worktrees.
fn collectWorktrees(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
) !std.array_list.Managed(WorktreeInfo) {
    var worktrees = std.array_list.Managed(WorktreeInfo).init(allocator);
    errdefer {
        for (worktrees.items) |*wt| wt.deinit();
        worktrees.deinit();
    }

    const main_git_dir = getMainGitDir(git_dir);

    // Add the main worktree
    {
        const work_dir = getWorkDir(main_git_dir);
        const path = try allocator.alloc(u8, work_dir.len);
        @memcpy(path, work_dir);

        const head_ref = ref_mod.readHead(allocator, main_git_dir) catch null;
        var branch: ?[]u8 = null;
        if (head_ref) |h| {
            branch = try allocator.alloc(u8, h.len);
            @memcpy(branch.?, h);
            allocator.free(h);
        }

        const head_oid = ref_mod.readRef(allocator, main_git_dir, "HEAD") catch null;

        try worktrees.append(.{
            .path = path,
            .head_oid = head_oid,
            .branch = branch,
            .is_bare = false,
            .is_main = true,
            .is_detached = head_ref == null,
            .is_locked = false,
            .allocator = allocator,
        });
    }

    // Scan worktrees directory
    var wt_dir_buf: [4096]u8 = undefined;
    const wt_dir = buildPath(&wt_dir_buf, main_git_dir, "/worktrees");

    var dir = std.fs.openDirAbsolute(wt_dir, .{ .iterate = true }) catch return worktrees;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        const wt_info = try readWorktreeInfo(allocator, wt_dir, entry.name);
        try worktrees.append(wt_info);
    }

    return worktrees;
}

/// Read worktree info from an admin directory entry.
fn readWorktreeInfo(
    allocator: std.mem.Allocator,
    wt_dir: []const u8,
    name: []const u8,
) !WorktreeInfo {
    var sub_dir_buf: [4096]u8 = undefined;
    var spos: usize = 0;
    @memcpy(sub_dir_buf[spos..][0..wt_dir.len], wt_dir);
    spos += wt_dir.len;
    sub_dir_buf[spos] = '/';
    spos += 1;
    @memcpy(sub_dir_buf[spos..][0..name.len], name);
    spos += name.len;
    const sub_dir = sub_dir_buf[0..spos];

    // Read gitdir to get the worktree path
    var gitdir_file_buf: [4096]u8 = undefined;
    const gitdir_file_path = buildPath(&gitdir_file_buf, sub_dir, "/gitdir");

    const gitdir_content = readFileContents(allocator, gitdir_file_path) catch {
        const path = try allocator.alloc(u8, name.len);
        @memcpy(path, name);
        return WorktreeInfo{
            .path = path,
            .head_oid = null,
            .branch = null,
            .is_bare = false,
            .is_main = false,
            .is_detached = true,
            .is_locked = false,
            .allocator = allocator,
        };
    };
    defer allocator.free(gitdir_content);

    const wt_git_path = std.mem.trimRight(u8, gitdir_content, "\n\r ");
    // The worktree path is the parent of the .git file
    const wt_path = std.fs.path.dirname(wt_git_path) orelse wt_git_path;

    const path = try allocator.alloc(u8, wt_path.len);
    @memcpy(path, wt_path);

    // Read HEAD
    var head_file_buf: [4096]u8 = undefined;
    const head_file_path = buildPath(&head_file_buf, sub_dir, "/HEAD");

    const head_content = readFileContents(allocator, head_file_path) catch null;
    defer if (head_content) |h| allocator.free(h);

    var head_oid: ?types.ObjectId = null;
    var branch: ?[]u8 = null;
    var is_detached = true;

    if (head_content) |hc| {
        const trimmed = std.mem.trimRight(u8, hc, "\n\r ");
        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            is_detached = false;
            const ref_target = trimmed[5..];
            branch = try allocator.alloc(u8, ref_target.len);
            @memcpy(branch.?, ref_target);
        }
        if (trimmed.len >= types.OID_HEX_LEN) {
            head_oid = types.ObjectId.fromHex(trimmed[0..types.OID_HEX_LEN]) catch null;
        }
    }

    // Check if locked
    var lock_buf: [4096]u8 = undefined;
    const lock_path = buildPath(&lock_buf, sub_dir, "/locked");
    const is_locked = blk: {
        const f = std.fs.openFileAbsolute(lock_path, .{}) catch break :blk false;
        f.close();
        break :blk true;
    };

    return WorktreeInfo{
        .path = path,
        .head_oid = head_oid,
        .branch = branch,
        .is_bare = false,
        .is_main = false,
        .is_detached = is_detached,
        .is_locked = is_locked,
        .allocator = allocator,
    };
}

/// Output information about a single worktree.
fn outputWorktreeInfo(wt: *const WorktreeInfo) !void {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try writer.writeAll(wt.path);

    try writer.writeAll("  ");

    if (wt.head_oid) |oid| {
        const hex = oid.toHex();
        try writer.writeAll(hex[0..7]);
    } else {
        try writer.writeAll("0000000");
    }

    try writer.writeAll(" ");

    if (wt.is_detached) {
        try writer.writeAll("(detached HEAD)");
    } else if (wt.branch) |b| {
        // Strip refs/heads/ prefix for display
        if (std.mem.startsWith(u8, b, "refs/heads/")) {
            try writer.writeAll("[");
            try writer.writeAll(b[11..]);
            try writer.writeAll("]");
        } else {
            try writer.writeAll("[");
            try writer.writeAll(b);
            try writer.writeAll("]");
        }
    }

    if (wt.is_locked) {
        try writer.writeAll(" locked");
    }

    try writer.writeByte('\n');

    try stdout_file.writeAll(buf[0..stream.pos]);
}

/// Checkout a tree into a directory (for new worktree setup).
fn checkoutTreeToDir(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    tree_oid: *const types.ObjectId,
    dir_path: []const u8,
) !void {
    var flat = try checkout_mod.flattenTree(allocator, repo, tree_oid);
    defer flat.deinit();

    for (flat.entries.items) |*entry| {
        var obj = repo.readObject(allocator, &entry.oid) catch continue;
        defer obj.deinit();

        if (obj.obj_type != .blob) continue;

        var path_buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&path_buf);
        const writer = stream.writer();
        try writer.writeAll(dir_path);
        try writer.writeByte('/');
        try writer.writeAll(entry.path);
        const full_path = path_buf[0..stream.pos];

        const dir_end = std.mem.lastIndexOfScalar(u8, full_path, '/') orelse continue;
        mkdirRecursive(full_path[0..dir_end]) catch {};

        const file = std.fs.createFileAbsolute(full_path, .{ .truncate = true }) catch continue;
        defer file.close();
        file.writeAll(obj.data) catch {};
    }
}

/// Remove an admin directory and all its contents.
fn removeAdminDir(path: []const u8) void {
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file) {
            dir.deleteFile(entry.name) catch {};
        }
    }
    // Close before deleting
    dir.close();
    std.fs.deleteDirAbsolute(path) catch {};
}

/// Recursively remove a directory and all its contents.
fn removeDirectoryRecursive(path: []const u8) !void {
    // Use a simple approach: try to delete the directory, which fails if non-empty
    // Then iterate and delete contents
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        var sub_path_buf: [4096]u8 = undefined;
        var sp: usize = 0;
        @memcpy(sub_path_buf[sp..][0..path.len], path);
        sp += path.len;
        sub_path_buf[sp] = '/';
        sp += 1;
        @memcpy(sub_path_buf[sp..][0..entry.name.len], entry.name);
        sp += entry.name.len;
        const sub_path = sub_path_buf[0..sp];

        if (entry.kind == .directory) {
            try removeDirectoryRecursive(sub_path);
        } else {
            std.fs.deleteFileAbsolute(sub_path) catch {};
        }
    }
    dir.close();

    std.fs.deleteDirAbsolute(path) catch {};
}

/// Get the main git dir (strip /worktrees/<name> if present).
fn getMainGitDir(git_dir: []const u8) []const u8 {
    // If git_dir contains /worktrees/, the main git_dir is everything before that
    if (std.mem.indexOf(u8, git_dir, "/worktrees/")) |idx| {
        return git_dir[0..idx];
    }
    return git_dir;
}

fn getWorkDir(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    if (std.fs.path.dirname(git_dir)) |parent| return parent;
    return git_dir;
}

fn resolveAbsolutePath(allocator: std.mem.Allocator, path: []const u8, buf: []u8) ![]const u8 {
    if (path.len > 0 and path[0] == '/') {
        @memcpy(buf[0..path.len], path);
        return buf[0..path.len];
    }

    // Get CWD and join
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    @memcpy(buf[0..cwd.len], cwd);
    buf[cwd.len] = '/';
    @memcpy(buf[cwd.len + 1 ..][0..path.len], path);
    return buf[0 .. cwd.len + 1 + path.len];
}

fn buildPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn readFileContents(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.size > 1024 * 1024) return error.FileTooLarge;
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    const n = try file.readAll(buf);
    if (n < buf.len) {
        const trimmed = try allocator.alloc(u8, n);
        @memcpy(trimmed, buf[0..n]);
        allocator.free(buf);
        return trimmed;
    }
    return buf;
}

fn mkdirRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
            try mkdirRecursive(parent);
            std.fs.makeDirAbsolute(path) catch |err2| switch (err2) {
                error.PathAlreadyExists => return,
                else => return err2,
            };
        },
        else => return err,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseWorktreeCommand" {
    try std.testing.expect(parseWorktreeCommand("list") == .list);
    try std.testing.expect(parseWorktreeCommand("add") == .add);
    try std.testing.expect(parseWorktreeCommand("remove") == .remove);
    try std.testing.expect(parseWorktreeCommand("prune") == .prune);
    try std.testing.expect(parseWorktreeCommand("lock") == .lock);
    try std.testing.expect(parseWorktreeCommand("unlock") == .unlock);
    try std.testing.expect(parseWorktreeCommand("xyz") == null);
}

test "getMainGitDir" {
    try std.testing.expectEqualStrings("/repo/.git", getMainGitDir("/repo/.git"));
    try std.testing.expectEqualStrings("/repo/.git", getMainGitDir("/repo/.git/worktrees/foo"));
}

test "getWorkDir" {
    try std.testing.expectEqualStrings("/repo", getWorkDir("/repo/.git"));
}

test "buildPath" {
    var buf: [256]u8 = undefined;
    const result = buildPath(&buf, "/foo", "/bar");
    try std.testing.expectEqualStrings("/foo/bar", result);
}
