const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");
const checkout_mod = @import("checkout.zig");
const tree_diff = @import("tree_diff.zig");
const loose = @import("loose.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Run the switch command.
pub fn runSwitch(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var create_branch: ?[]const u8 = null;
    var force_create = false;
    var detach = false;
    var target: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("fatal: -c requires a branch name\n");
                std.process.exit(1);
            }
            create_branch = args[i];
        } else if (std.mem.eql(u8, arg, "-C")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("fatal: -C requires a branch name\n");
                std.process.exit(1);
            }
            create_branch = args[i];
            force_create = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--detach")) {
            detach = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            target = arg;
        }
    }

    // Handle "switch -" for previous branch
    if (target != null and std.mem.eql(u8, target.?, "-")) {
        // Read previous branch from reflog
        target = readPreviousBranch(allocator, repo.git_dir);
        if (target == null) {
            try stderr_file.writeAll("fatal: no previous branch to switch to\n");
            std.process.exit(1);
        }
    }

    // Check for uncommitted changes
    if (target != null or create_branch != null) {
        if (try hasUncommittedChanges(repo, allocator)) {
            try stderr_file.writeAll("error: Your local changes to the following files would be overwritten by switch:\n");
            try stderr_file.writeAll("Please commit your changes or stash them before you switch branches.\n");
            std.process.exit(1);
        }
    }

    if (create_branch) |new_branch| {
        return createAndSwitch(repo, allocator, new_branch, target, force_create);
    }

    if (target == null) {
        try stderr_file.writeAll("fatal: missing branch or commit argument\n");
        std.process.exit(1);
    }

    if (detach) {
        return switchDetached(repo, allocator, target.?);
    }

    // Check if target is a branch
    if (isBranch(allocator, repo.git_dir, target.?)) {
        return switchToBranch(repo, allocator, target.?);
    }

    // Not a branch and not --detach
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "fatal: a branch is expected, got '{s}'\nhint: use 'zig-git switch -d {s}' to detach HEAD at the commit\n", .{ target.?, target.? }) catch
        "fatal: a branch is expected\n";
    try stderr_file.writeAll(msg);
    std.process.exit(1);
}

fn switchToBranch(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    branch_name: []const u8,
) !void {
    var ref_buf: [256]u8 = undefined;
    const ref_prefix = "refs/heads/";
    @memcpy(ref_buf[0..ref_prefix.len], ref_prefix);
    @memcpy(ref_buf[ref_prefix.len..][0..branch_name.len], branch_name);
    const target_ref = ref_buf[0 .. ref_prefix.len + branch_name.len];

    const target_oid = ref_mod.readRef(allocator, repo.git_dir, target_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: invalid reference: {s}\n", .{branch_name}) catch
            "fatal: invalid reference\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    };

    const old_oid = repo.resolveRef(allocator, "HEAD") catch types.ObjectId.ZERO;

    // Update working tree
    try updateWorkingTree(repo, allocator, &old_oid, &target_oid);

    // Point HEAD to the branch
    try writeSymbolicHead(repo.git_dir, target_ref);

    // Reflog
    var msg_buf: [256]u8 = undefined;
    const reflog_msg = std.fmt.bufPrint(&msg_buf, "switch: moving from HEAD to {s}", .{branch_name}) catch "switch";
    reflog_mod.appendReflog(repo.git_dir, "HEAD", old_oid, target_oid, reflog_msg) catch {};

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Switched to branch '{s}'\n", .{branch_name}) catch "Switched to branch\n";
    try stderr_file.writeAll(msg);
}

fn switchDetached(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    ref_str: []const u8,
) !void {
    const target_oid = repo.resolveRef(allocator, ref_str) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: invalid reference: {s}\n", .{ref_str}) catch
            "fatal: invalid reference\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    };

    const old_oid = repo.resolveRef(allocator, "HEAD") catch types.ObjectId.ZERO;

    try updateWorkingTree(repo, allocator, &old_oid, &target_oid);

    // Write raw OID to HEAD (detached)
    try writeDetachedHead(repo.git_dir, target_oid);

    var msg_buf: [256]u8 = undefined;
    const reflog_msg = std.fmt.bufPrint(&msg_buf, "switch: moving to {s}", .{ref_str}) catch "switch";
    reflog_mod.appendReflog(repo.git_dir, "HEAD", old_oid, target_oid, reflog_msg) catch {};

    const hex = target_oid.toHex();
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "HEAD is now at {s}\n", .{hex[0..7]}) catch "HEAD detached\n";
    try stderr_file.writeAll(msg);
}

fn createAndSwitch(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    new_branch: []const u8,
    start_point: ?[]const u8,
    force_create: bool,
) !void {
    // Resolve start point (default HEAD)
    const start_ref = start_point orelse "HEAD";
    const start_oid = repo.resolveRef(allocator, start_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: not a valid object name: '{s}'\n", .{start_ref}) catch
            "fatal: not a valid object name\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    };

    // Check if branch already exists
    var ref_buf: [256]u8 = undefined;
    const ref_prefix = "refs/heads/";
    @memcpy(ref_buf[0..ref_prefix.len], ref_prefix);
    @memcpy(ref_buf[ref_prefix.len..][0..new_branch.len], new_branch);
    const target_ref = ref_buf[0 .. ref_prefix.len + new_branch.len];

    if (!force_create) {
        if (ref_mod.readRef(allocator, repo.git_dir, target_ref)) |_| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: a branch named '{s}' already exists\n", .{new_branch}) catch
                "fatal: branch already exists\n";
            try stderr_file.writeAll(msg);
            std.process.exit(128);
        } else |_| {}
    }

    // Create the branch ref
    try ref_mod.createRef(allocator, repo.git_dir, target_ref, start_oid, null);

    const old_oid = repo.resolveRef(allocator, "HEAD") catch types.ObjectId.ZERO;

    // Update working tree if needed
    if (!old_oid.eql(&start_oid)) {
        try updateWorkingTree(repo, allocator, &old_oid, &start_oid);
    }

    // Point HEAD to the new branch
    try writeSymbolicHead(repo.git_dir, target_ref);

    var msg_buf: [256]u8 = undefined;
    const reflog_msg = std.fmt.bufPrint(&msg_buf, "switch: moving to {s}", .{new_branch}) catch "switch";
    reflog_mod.appendReflog(repo.git_dir, "HEAD", old_oid, start_oid, reflog_msg) catch {};

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Switched to a new branch '{s}'\n", .{new_branch}) catch "Switched to new branch\n";
    try stderr_file.writeAll(msg);
}

fn updateWorkingTree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    old_oid: *const types.ObjectId,
    new_oid: *const types.ObjectId,
) !void {
    if (old_oid.eql(new_oid)) return;

    const work_dir = getWorkDir(repo.git_dir);

    // Get the target tree
    var new_commit = try repo.readObject(allocator, new_oid);
    defer new_commit.deinit();
    if (new_commit.obj_type != .commit) return error.NotACommit;
    const new_tree_oid = try tree_diff.getCommitTreeOid(new_commit.data);

    var new_flat = try checkout_mod.flattenTree(allocator, repo, &new_tree_oid);
    defer new_flat.deinit();

    // Get current tree
    if (!std.mem.eql(u8, &old_oid.bytes, &types.ObjectId.ZERO.bytes)) {
        var old_commit = repo.readObject(allocator, old_oid) catch null;
        defer if (old_commit) |*o| o.deinit();

        if (old_commit) |oc| {
            if (oc.obj_type == .commit) {
                const old_tree_oid = tree_diff.getCommitTreeOid(oc.data) catch null;
                if (old_tree_oid) |oto| {
                    var old_flat = checkout_mod.flattenTree(allocator, repo, &oto) catch null;
                    defer if (old_flat) |*of| of.deinit();

                    if (old_flat) |*of| {
                        // Delete files not in new tree
                        for (of.entries.items) |*entry| {
                            if (new_flat.findByPath(entry.path) == null) {
                                deleteFromWorkTree(work_dir, entry.path);
                            }
                        }
                    }
                }
            }
        }
    }

    // Write all new tree files
    for (new_flat.entries.items) |*entry| {
        writeBlobToWorkTree(allocator, repo, work_dir, entry.path, &entry.oid, entry.mode) catch {};
    }

    // Update index
    var new_idx = index_mod.Index.init(allocator);
    defer new_idx.deinit();

    for (new_flat.entries.items) |*entry| {
        const name_copy = try allocator.alloc(u8, entry.path.len);
        @memcpy(name_copy, entry.path);
        try new_idx.addEntry(.{
            .ctime_s = 0,
            .ctime_ns = 0,
            .mtime_s = 0,
            .mtime_ns = 0,
            .dev = 0,
            .ino = 0,
            .mode = entry.mode,
            .uid = 0,
            .gid = 0,
            .file_size = 0,
            .oid = entry.oid,
            .flags = 0,
            .name = name_copy,
            .owned = true,
        });
    }

    var idx_path_buf: [4096]u8 = undefined;
    var idx_stream = std.io.fixedBufferStream(&idx_path_buf);
    const idx_writer = idx_stream.writer();
    try idx_writer.writeAll(repo.git_dir);
    try idx_writer.writeAll("/index");
    const idx_path = idx_path_buf[0..idx_stream.pos];
    try new_idx.writeToFile(idx_path);
}

fn hasUncommittedChanges(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !bool {
    // Load index
    var idx_path_buf: [4096]u8 = undefined;
    var idx_stream = std.io.fixedBufferStream(&idx_path_buf);
    const idx_writer = idx_stream.writer();
    try idx_writer.writeAll(repo.git_dir);
    try idx_writer.writeAll("/index");
    const idx_path = idx_path_buf[0..idx_stream.pos];

    var idx = index_mod.Index.readFromFile(allocator, idx_path) catch return false;
    defer idx.deinit();

    const work_dir = getWorkDir(repo.git_dir);

    // Check if any tracked file is modified
    for (idx.entries.items) |*entry| {
        var file_path_buf: [4096]u8 = undefined;
        var fp_stream = std.io.fixedBufferStream(&file_path_buf);
        const fp_writer = fp_stream.writer();
        try fp_writer.writeAll(work_dir);
        try fp_writer.writeByte('/');
        try fp_writer.writeAll(entry.name);
        const file_path = file_path_buf[0..fp_stream.pos];

        const file = std.fs.openFileAbsolute(file_path, .{}) catch continue;
        defer file.close();
        const stat = file.stat() catch continue;
        if (stat.size != entry.file_size) return true;
    }

    return false;
}

fn isBranch(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    const suffix = "/refs/heads/";
    @memcpy(path_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    @memcpy(path_buf[pos..][0..name.len], name);
    pos += name.len;
    const ref_path = path_buf[0..pos];

    const file = std.fs.openFileAbsolute(ref_path, .{}) catch {
        // Also check packed-refs
        var ref_name_buf: [256]u8 = undefined;
        const ref_name = std.fmt.bufPrint(&ref_name_buf, "refs/heads/{s}", .{name}) catch return false;
        _ = ref_mod.readRef(allocator, git_dir, ref_name) catch return false;
        return true;
    };
    file.close();
    return true;
}

fn readPreviousBranch(allocator: std.mem.Allocator, git_dir: []const u8) ?[]const u8 {
    // Read from reflog - find the second entry which has "checkout: moving from X to Y"
    var result = reflog_mod.readReflog(allocator, git_dir, "HEAD") catch return null;
    defer result.deinit();

    // Most recent entry is last - scan from end
    const entries = result.entries;
    if (entries.len < 2) return null;

    // Look for "moving from X to" in recent reflog messages
    for (0..entries.len) |ri| {
        const idx = entries.len - 1 - ri;
        const msg = entries[idx].message;
        if (std.mem.indexOf(u8, msg, "moving from ")) |start| {
            const after_from = msg[start + "moving from ".len..];
            if (std.mem.indexOf(u8, after_from, " to ")) |space| {
                // Return the branch name as a slice into constant memory
                // We need to allocate a copy since reflog will be freed
                const branch = after_from[0..space];
                const copy = allocator.alloc(u8, branch.len) catch return null;
                @memcpy(copy, branch);
                return copy;
            }
        }
    }

    return null;
}

fn writeSymbolicHead(git_dir: []const u8, target_ref: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    const suffix = "/HEAD";
    @memcpy(path_buf[git_dir.len..][0..suffix.len], suffix);
    const head_path = path_buf[0 .. git_dir.len + suffix.len];

    var content_buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&content_buf);
    const writer = stream.writer();
    try writer.writeAll("ref: ");
    try writer.writeAll(target_ref);
    try writer.writeByte('\n');

    const file = try std.fs.createFileAbsolute(head_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content_buf[0..stream.pos]);
}

fn writeDetachedHead(git_dir: []const u8, oid: types.ObjectId) !void {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    const suffix = "/HEAD";
    @memcpy(path_buf[git_dir.len..][0..suffix.len], suffix);
    const head_path = path_buf[0 .. git_dir.len + suffix.len];

    const hex = oid.toHex();
    var content_buf: [types.OID_HEX_LEN + 1]u8 = undefined;
    @memcpy(content_buf[0..types.OID_HEX_LEN], &hex);
    content_buf[types.OID_HEX_LEN] = '\n';

    const file = try std.fs.createFileAbsolute(head_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(&content_buf);
}

fn getWorkDir(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    if (std.fs.path.dirname(git_dir)) |parent| {
        return parent;
    }
    return git_dir;
}

fn writeBlobToWorkTree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    work_dir: []const u8,
    rel_path: []const u8,
    oid: *const types.ObjectId,
    mode: u32,
) !void {
    var obj = try repo.readObject(allocator, oid);
    defer obj.deinit();
    if (obj.obj_type != .blob) return error.NotABlob;

    var path_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&path_buf);
    const writer = stream.writer();
    try writer.writeAll(work_dir);
    try writer.writeByte('/');
    try writer.writeAll(rel_path);
    const full_path = path_buf[0..stream.pos];

    const dir_end = std.mem.lastIndexOfScalar(u8, full_path, '/') orelse return error.InvalidPath;
    mkdirRecursive(full_path[0..dir_end]) catch {};

    const file = try std.fs.createFileAbsolute(full_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(obj.data);

    if (mode & 0o111 != 0) {
        const stat = try file.stat();
        const new_mode = stat.mode | 0o111;
        try file.chmod(new_mode);
    }
}

fn deleteFromWorkTree(work_dir: []const u8, rel_path: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&path_buf);
    const writer = stream.writer();
    writer.writeAll(work_dir) catch return;
    writer.writeByte('/') catch return;
    writer.writeAll(rel_path) catch return;
    const full_path = path_buf[0..stream.pos];

    std.fs.deleteFileAbsolute(full_path) catch {};
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
