const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const init_mod = @import("init.zig");
const config_mod = @import("config.zig");
const remote_mod = @import("remote.zig");
const ref_mod = @import("ref.zig");
const loose = @import("loose.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Clone a local repository.
pub fn cloneRepository(allocator: std.mem.Allocator, source_url: []const u8, target_dir: ?[]const u8) !void {
    // Resolve source path
    const source_path = remote_mod.resolveLocalUrl(source_url) orelse {
        try stderr_file.writeAll("fatal: only local repositories are supported for clone\n");
        return error.UnsupportedProtocol;
    };

    // Resolve to absolute path if relative
    var abs_source_buf: [4096]u8 = undefined;
    const abs_source = try resolveAbsolutePath(allocator, source_path, &abs_source_buf);

    // Determine the target directory name
    var target_name_buf: [1024]u8 = undefined;
    const target_name: []const u8 = if (target_dir) |d| d else deriveRepoName(abs_source, &target_name_buf);

    // Print cloning message
    {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Cloning into '{s}'...\n", .{target_name}) catch
            "Cloning...\n";
        try stderr_file.writeAll(msg);
    }

    // Verify source is a git repository
    var source_git_dir_buf: [4096]u8 = undefined;
    const source_git_dir = findGitDir(abs_source, &source_git_dir_buf) orelse {
        try stderr_file.writeAll("fatal: repository not found\n");
        return error.RepositoryNotFound;
    };

    // Initialize target repository
    const git_dir = try init_mod.initRepository(allocator, .{
        .directory = target_name,
    });
    defer allocator.free(git_dir);

    // Set up remote "origin"
    try remote_mod.addRemote(allocator, git_dir, "origin", source_url);

    // Copy objects: first pack files, then loose objects
    try copyPackFiles(allocator, source_git_dir, git_dir);
    try copyLooseObjects(source_git_dir, git_dir);

    // Copy refs as remote tracking branches
    try setupRemoteRefs(allocator, source_git_dir, git_dir, "origin");

    // Set up HEAD to match source
    try setupHead(allocator, source_git_dir, git_dir);

    // Checkout the default branch
    try checkoutHead(allocator, git_dir);
}

/// Run the clone command from CLI args.
pub fn runClone(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        try stderr_file.writeAll("usage: zig-git clone <repository> [<directory>]\n");
        std.process.exit(1);
    }

    var source: ?[]const u8 = null;
    var target: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            // Skip flags for now
            continue;
        }
        if (source == null) {
            source = arg;
        } else if (target == null) {
            target = arg;
        }
    }

    if (source == null) {
        try stderr_file.writeAll("usage: zig-git clone <repository> [<directory>]\n");
        std.process.exit(1);
    }

    cloneRepository(allocator, source.?, target) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: clone failed: {s}\n", .{@errorName(err)}) catch
            "fatal: clone failed\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };
}

// --- Internal helpers ---

/// Resolve a possibly-relative path to an absolute path.
fn resolveAbsolutePath(allocator: std.mem.Allocator, path: []const u8, buf: []u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        @memcpy(buf[0..path.len], path);
        return buf[0..path.len];
    }
    // Make relative to cwd
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    @memcpy(buf[0..cwd.len], cwd);
    buf[cwd.len] = '/';
    @memcpy(buf[cwd.len + 1 ..][0..path.len], path);
    return buf[0 .. cwd.len + 1 + path.len];
}

/// Derive a repository name from a URL/path.
/// "/path/to/repo.git" -> "repo", "/path/to/repo" -> "repo"
fn deriveRepoName(source: []const u8, buf: []u8) []const u8 {
    var path = source;
    // Strip trailing slashes
    while (path.len > 1 and path[path.len - 1] == '/') {
        path = path[0 .. path.len - 1];
    }
    // Get basename
    const basename = std.fs.path.basename(path);
    // Strip .git extension
    if (std.mem.endsWith(u8, basename, ".git") and basename.len > 4) {
        const name = basename[0 .. basename.len - 4];
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    @memcpy(buf[0..basename.len], basename);
    return buf[0..basename.len];
}

/// Find the .git directory within a path.
fn findGitDir(path: []const u8, buf: []u8) ?[]const u8 {
    // Check if path/.git exists
    const git_suffix = "/.git";
    if (path.len + git_suffix.len > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    @memcpy(buf[path.len..][0..git_suffix.len], git_suffix);
    const git_path = buf[0 .. path.len + git_suffix.len];
    if (isDirectory(git_path)) return git_path;

    // Check if path itself is a bare repo (has HEAD and objects/)
    if (path.len + "/HEAD".len > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    @memcpy(buf[path.len..][0.."/HEAD".len], "/HEAD");
    const head_path = buf[0 .. path.len + "/HEAD".len];
    if (isFile(head_path)) {
        // Return path itself as git_dir (bare repo)
        @memcpy(buf[0..path.len], path);
        return buf[0..path.len];
    }

    return null;
}

/// Copy pack files from source to target.
fn copyPackFiles(allocator: std.mem.Allocator, source_git_dir: []const u8, target_git_dir: []const u8) !void {
    var src_path_buf: [4096]u8 = undefined;
    const src_pack_dir = concatPath(&src_path_buf, source_git_dir, "/objects/pack");

    var dir = std.fs.openDirAbsolute(src_pack_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pack") and
            !std.mem.endsWith(u8, entry.name, ".idx"))
        {
            continue;
        }

        // Build source file path
        var file_src_buf: [4096]u8 = undefined;
        var pos: usize = 0;
        @memcpy(file_src_buf[pos..][0..src_pack_dir.len], src_pack_dir);
        pos += src_pack_dir.len;
        file_src_buf[pos] = '/';
        pos += 1;
        @memcpy(file_src_buf[pos..][0..entry.name.len], entry.name);
        pos += entry.name.len;
        const file_src = file_src_buf[0..pos];

        // Build target file path
        var file_dst_buf: [4096]u8 = undefined;
        var dpos: usize = 0;
        @memcpy(file_dst_buf[dpos..][0..target_git_dir.len], target_git_dir);
        dpos += target_git_dir.len;
        const pack_suffix = "/objects/pack/";
        @memcpy(file_dst_buf[dpos..][0..pack_suffix.len], pack_suffix);
        dpos += pack_suffix.len;
        @memcpy(file_dst_buf[dpos..][0..entry.name.len], entry.name);
        dpos += entry.name.len;
        const file_dst = file_dst_buf[0..dpos];

        // Copy the file
        try copyFile(allocator, file_src, file_dst);
    }
}

/// Copy loose objects from source to target.
fn copyLooseObjects(source_git_dir: []const u8, target_git_dir: []const u8) !void {
    // Iterate over objects/XX directories
    var src_path_buf: [4096]u8 = undefined;
    const src_obj_dir = concatPath(&src_path_buf, source_git_dir, "/objects");

    var dir = std.fs.openDirAbsolute(src_obj_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len != 2) continue;
        // Skip special directories
        if (std.mem.eql(u8, entry.name, "pack") or std.mem.eql(u8, entry.name, "info")) continue;

        // Ensure target subdir exists
        var dst_subdir_buf: [4096]u8 = undefined;
        var pos: usize = 0;
        @memcpy(dst_subdir_buf[pos..][0..target_git_dir.len], target_git_dir);
        pos += target_git_dir.len;
        const obj_prefix = "/objects/";
        @memcpy(dst_subdir_buf[pos..][0..obj_prefix.len], obj_prefix);
        pos += obj_prefix.len;
        @memcpy(dst_subdir_buf[pos..][0..entry.name.len], entry.name);
        pos += entry.name.len;
        const dst_subdir = dst_subdir_buf[0..pos];
        std.fs.makeDirAbsolute(dst_subdir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Open source subdir and copy files
        var src_subdir_buf: [4096]u8 = undefined;
        var spos: usize = 0;
        @memcpy(src_subdir_buf[spos..][0..src_obj_dir.len], src_obj_dir);
        spos += src_obj_dir.len;
        src_subdir_buf[spos] = '/';
        spos += 1;
        @memcpy(src_subdir_buf[spos..][0..entry.name.len], entry.name);
        spos += entry.name.len;
        const src_subdir = src_subdir_buf[0..spos];

        var sub_dir = std.fs.openDirAbsolute(src_subdir, .{ .iterate = true }) catch continue;
        defer sub_dir.close();

        var sub_iter = sub_dir.iterate();
        while (try sub_iter.next()) |obj_entry| {
            if (obj_entry.kind != .file) continue;

            // Source file
            var obj_src_buf: [4096]u8 = undefined;
            var opos: usize = 0;
            @memcpy(obj_src_buf[opos..][0..src_subdir.len], src_subdir);
            opos += src_subdir.len;
            obj_src_buf[opos] = '/';
            opos += 1;
            @memcpy(obj_src_buf[opos..][0..obj_entry.name.len], obj_entry.name);
            opos += obj_entry.name.len;
            const obj_src = obj_src_buf[0..opos];

            // Dest file
            var obj_dst_buf: [4096]u8 = undefined;
            var odpos: usize = 0;
            @memcpy(obj_dst_buf[odpos..][0..dst_subdir.len], dst_subdir);
            odpos += dst_subdir.len;
            obj_dst_buf[odpos] = '/';
            odpos += 1;
            @memcpy(obj_dst_buf[odpos..][0..obj_entry.name.len], obj_entry.name);
            odpos += obj_entry.name.len;
            const obj_dst = obj_dst_buf[0..odpos];

            // Copy only if doesn't exist
            copyFileIfMissing(obj_src, obj_dst) catch continue;
        }
    }
}

/// Set up remote tracking refs from source refs.
fn setupRemoteRefs(allocator: std.mem.Allocator, source_git_dir: []const u8, target_git_dir: []const u8, remote_name: []const u8) !void {
    // List source branches
    const branch_refs = try ref_mod.listRefs(allocator, source_git_dir, "refs/heads/");
    defer ref_mod.freeRefEntries(allocator, branch_refs);

    for (branch_refs) |entry| {
        // Convert refs/heads/X -> refs/remotes/<remote>/X
        if (std.mem.startsWith(u8, entry.name, "refs/heads/")) {
            const branch_name = entry.name["refs/heads/".len..];

            var ref_name_buf: [512]u8 = undefined;
            var pos: usize = 0;
            const prefix = "refs/remotes/";
            @memcpy(ref_name_buf[pos..][0..prefix.len], prefix);
            pos += prefix.len;
            @memcpy(ref_name_buf[pos..][0..remote_name.len], remote_name);
            pos += remote_name.len;
            ref_name_buf[pos] = '/';
            pos += 1;
            @memcpy(ref_name_buf[pos..][0..branch_name.len], branch_name);
            pos += branch_name.len;
            const ref_name = ref_name_buf[0..pos];

            ref_mod.createRef(allocator, target_git_dir, ref_name, entry.oid, null) catch continue;
        }
    }

    // Also copy tags
    const tag_refs = try ref_mod.listRefs(allocator, source_git_dir, "refs/tags/");
    defer ref_mod.freeRefEntries(allocator, tag_refs);

    for (tag_refs) |entry| {
        ref_mod.createRef(allocator, target_git_dir, entry.name, entry.oid, null) catch continue;
    }
}

/// Set up HEAD in the target to match source.
fn setupHead(allocator: std.mem.Allocator, source_git_dir: []const u8, target_git_dir: []const u8) !void {
    // Read source HEAD
    const head_target = try ref_mod.readHead(allocator, source_git_dir);
    if (head_target) |target| {
        defer allocator.free(target);

        // Set up HEAD as symbolic ref
        try ref_mod.updateSymRef(target_git_dir, "HEAD", target);

        // Also create the local branch pointing to the same commit
        const oid = ref_mod.readRef(allocator, source_git_dir, target) catch return;
        ref_mod.createRef(allocator, target_git_dir, target, oid, null) catch return;
    }
}

/// Simple checkout: write the tree of HEAD to the working directory.
fn checkoutHead(allocator: std.mem.Allocator, git_dir: []const u8) !void {
    // Open the newly created repository
    var repo = repository.Repository.discover(allocator, git_dir) catch return;
    defer repo.deinit();

    // Resolve HEAD to a commit
    const head_oid = ref_mod.readRef(allocator, git_dir, "HEAD") catch return;

    // Read the commit
    var commit_obj = repo.readObject(allocator, &head_oid) catch return;
    defer commit_obj.deinit();

    if (commit_obj.obj_type != .commit) return;

    // Parse tree OID from commit
    const tree_oid = parseCommitTree(commit_obj.data) catch return;

    // Determine working directory (parent of .git dir)
    const work_dir = std.fs.path.dirname(git_dir) orelse return;

    // Checkout the tree recursively
    checkoutTree(allocator, &repo, &tree_oid, work_dir) catch return;
}

/// Recursively checkout a tree to the working directory.
fn checkoutTree(allocator: std.mem.Allocator, repo: *repository.Repository, tree_oid: *const types.ObjectId, dest_dir: []const u8) !void {
    var tree_obj = try repo.readObject(allocator, tree_oid);
    defer tree_obj.deinit();

    if (tree_obj.obj_type != .tree) return error.NotATree;

    var pos: usize = 0;
    while (pos < tree_obj.data.len) {
        // Parse tree entry: "<mode> <name>\0<20-byte-oid>"
        const space_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, pos, ' ') orelse break;
        const null_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, space_pos, 0) orelse break;

        const mode_str = tree_obj.data[pos..space_pos];
        const name = tree_obj.data[space_pos + 1 .. null_pos];

        if (null_pos + 1 + types.OID_RAW_LEN > tree_obj.data.len) break;
        var entry_oid: types.ObjectId = undefined;
        @memcpy(&entry_oid.bytes, tree_obj.data[null_pos + 1 ..][0..types.OID_RAW_LEN]);

        pos = null_pos + 1 + types.OID_RAW_LEN;

        // Build destination path
        var path_buf: [4096]u8 = undefined;
        var ppos: usize = 0;
        @memcpy(path_buf[ppos..][0..dest_dir.len], dest_dir);
        ppos += dest_dir.len;
        path_buf[ppos] = '/';
        ppos += 1;
        @memcpy(path_buf[ppos..][0..name.len], name);
        ppos += name.len;
        const full_path = path_buf[0..ppos];

        if (std.mem.eql(u8, mode_str, "40000")) {
            // Directory - create and recurse
            std.fs.makeDirAbsolute(full_path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => continue,
            };
            checkoutTree(allocator, repo, &entry_oid, full_path) catch continue;
        } else {
            // File - write contents
            var blob_obj = repo.readObject(allocator, &entry_oid) catch continue;
            defer blob_obj.deinit();

            const file = std.fs.createFileAbsolute(full_path, .{}) catch continue;
            defer file.close();
            file.writeAll(blob_obj.data) catch continue;

            // Set executable bit if mode is 100755
            if (std.mem.eql(u8, mode_str, "100755")) {
                const stat = file.stat() catch continue;
                const new_mode = stat.mode | 0o111;
                file.chmod(new_mode) catch {};
            }
        }
    }
}

/// Parse the tree OID from commit data.
fn parseCommitTree(data: []const u8) !types.ObjectId {
    if (data.len < 5 + types.OID_HEX_LEN) return error.InvalidCommitFormat;
    if (!std.mem.startsWith(u8, data, "tree ")) return error.InvalidCommitFormat;
    return types.ObjectId.fromHex(data[5..][0..types.OID_HEX_LEN]);
}

/// Copy a file from src to dst.
fn copyFile(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const src_file = try std.fs.openFileAbsolute(src, .{});
    defer src_file.close();

    const stat = try src_file.stat();
    const data = try allocator.alloc(u8, stat.size);
    defer allocator.free(data);
    const n = try src_file.readAll(data);

    const dst_file = try std.fs.createFileAbsolute(dst, .{});
    defer dst_file.close();
    try dst_file.writeAll(data[0..n]);
}

/// Copy a file only if the destination doesn't exist.
fn copyFileIfMissing(src: []const u8, dst: []const u8) !void {
    // Check if dst exists
    const check = std.fs.openFileAbsolute(dst, .{});
    if (check) |f| {
        @constCast(&f).close();
        return; // Already exists
    } else |_| {}

    // Read source
    const src_file = try std.fs.openFileAbsolute(src, .{});
    defer src_file.close();

    var buf: [65536]u8 = undefined;
    const dst_file = try std.fs.createFileAbsolute(dst, .{});
    defer dst_file.close();

    while (true) {
        const n = try src_file.read(&buf);
        if (n == 0) break;
        try dst_file.writeAll(buf[0..n]);
    }
}

fn concatPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn isDirectory(path: []const u8) bool {
    const dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    @constCast(&dir).close();
    return true;
}

fn isFile(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    @constCast(&file).close();
    return true;
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

test "deriveRepoName" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("repo", deriveRepoName("/path/to/repo.git", &buf));
    try std.testing.expectEqualStrings("myproject", deriveRepoName("/path/to/myproject", &buf));
    try std.testing.expectEqualStrings("foo", deriveRepoName("/foo/", &buf));
}
