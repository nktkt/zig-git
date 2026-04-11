const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");
const loose = @import("loose.zig");
const tree_diff = @import("tree_diff.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// A flattened tree entry: path, mode, and oid for a single blob/file.
pub const FlatTreeEntry = struct {
    path: []const u8,
    mode: u32,
    oid: types.ObjectId,
};

/// Result of flattenTree. Owns all allocated memory.
pub const FlatTreeResult = struct {
    entries: std.array_list.Managed(FlatTreeEntry),
    strings: std.array_list.Managed([]u8),

    pub fn deinit(self: *FlatTreeResult) void {
        self.entries.deinit();
        for (self.strings.items) |s| {
            self.entries.allocator.free(s);
        }
        self.strings.deinit();
    }

    /// Find an entry by path.
    pub fn findByPath(self: *const FlatTreeResult, path: []const u8) ?*const FlatTreeEntry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.path, path)) return e;
        }
        return null;
    }
};

/// Recursively walk a tree object and return a flat list of all blob entries
/// with their full paths, modes, and OIDs.
pub fn flattenTree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    tree_oid: *const types.ObjectId,
) !FlatTreeResult {
    var result = FlatTreeResult{
        .entries = std.array_list.Managed(FlatTreeEntry).init(allocator),
        .strings = std.array_list.Managed([]u8).init(allocator),
    };
    errdefer result.deinit();

    try flattenTreeRecursive(allocator, repo, tree_oid, "", &result);
    return result;
}

fn flattenTreeRecursive(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    tree_oid: *const types.ObjectId,
    prefix: []const u8,
    result: *FlatTreeResult,
) !void {
    var obj = try repo.readObject(allocator, tree_oid);
    defer obj.deinit();

    if (obj.obj_type != .tree) return error.NotATree;

    var pos: usize = 0;
    const data = obj.data;

    while (pos < data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse return error.InvalidTreeEntry;
        const mode_str = data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, data, space_pos + 1, 0) orelse return error.InvalidTreeEntry;
        const name = data[space_pos + 1 .. null_pos];

        if (null_pos + 1 + types.OID_RAW_LEN > data.len) return error.InvalidTreeEntry;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, data[null_pos + 1 ..][0..types.OID_RAW_LEN]);
        pos = null_pos + 1 + types.OID_RAW_LEN;

        // Build full path
        const full_path = try buildPath(allocator, prefix, name);
        try result.strings.append(full_path);

        if (std.mem.eql(u8, mode_str, "40000")) {
            // Recurse into subdirectory
            try flattenTreeRecursive(allocator, repo, &oid, full_path, result);
        } else {
            // Parse mode
            const mode = parseModeString(mode_str);
            try result.entries.append(.{
                .path = full_path,
                .mode = mode,
                .oid = oid,
            });
        }
    }
}

fn parseModeString(mode_str: []const u8) u32 {
    var result: u32 = 0;
    for (mode_str) |c| {
        if (c < '0' or c > '7') break;
        result = result * 8 + @as(u32, c - '0');
    }
    return result;
}

fn buildPath(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    if (prefix.len == 0) {
        const path = try allocator.alloc(u8, name.len);
        @memcpy(path, name);
        return path;
    }
    const total = prefix.len + 1 + name.len;
    const path = try allocator.alloc(u8, total);
    @memcpy(path[0..prefix.len], prefix);
    path[prefix.len] = '/';
    @memcpy(path[prefix.len + 1 ..], name);
    return path;
}

/// Get the working directory from git_dir (strip /.git suffix).
fn getWorkDir(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    if (std.fs.path.dirname(git_dir)) |parent| {
        return parent;
    }
    return git_dir;
}

/// Read commit data and extract the tree OID.
fn getCommitTreeOid(commit_data: []const u8) !types.ObjectId {
    return tree_diff.getCommitTreeOid(commit_data);
}

/// Extract the first line of the commit message body.
fn getCommitSubject(commit_data: []const u8) []const u8 {
    // Find double newline separating headers from body
    var i: usize = 0;
    while (i < commit_data.len) {
        if (i + 1 < commit_data.len and commit_data[i] == '\n' and commit_data[i + 1] == '\n') {
            const body_start = i + 2;
            if (body_start >= commit_data.len) return "";
            const end = std.mem.indexOfScalar(u8, commit_data[body_start..], '\n') orelse commit_data.len - body_start;
            return commit_data[body_start .. body_start + end];
        }
        i += 1;
    }
    return "";
}

/// Resolve a ref string to a branch name. Returns the branch name (without refs/heads/ prefix)
/// if the string refers to a branch, otherwise null.
fn resolveToBranch(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8) ?[]const u8 {
    // Check if refs/heads/<name> exists
    var path_buf: [4096]u8 = undefined;
    const suffix = "/refs/heads/";
    const total_len = git_dir.len + suffix.len + name.len;
    if (total_len > path_buf.len) return null;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    @memcpy(path_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    @memcpy(path_buf[pos..][0..name.len], name);
    pos += name.len;
    const ref_path = path_buf[0..pos];

    const content = readFileContents(allocator, ref_path) catch return null;
    allocator.free(content);
    return name;
}

/// Write a blob to the working tree at the given relative path.
fn writeBlobToWorkTree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    work_dir: []const u8,
    rel_path: []const u8,
    oid: *const types.ObjectId,
    mode: u32,
) !void {
    // Read the blob object
    var obj = try repo.readObject(allocator, oid);
    defer obj.deinit();

    if (obj.obj_type != .blob) return error.NotABlob;

    // Build full path
    var path_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&path_buf);
    const writer = stream.writer();
    try writer.writeAll(work_dir);
    try writer.writeByte('/');
    try writer.writeAll(rel_path);
    const full_path = path_buf[0..stream.pos];

    // Ensure parent directory exists
    const dir_end = std.mem.lastIndexOfScalar(u8, full_path, '/') orelse return error.InvalidPath;
    mkdirRecursive(full_path[0..dir_end]) catch {};

    // Write file
    const file = try std.fs.createFileAbsolute(full_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(obj.data);

    // Set executable bit if mode indicates it
    if (mode & 0o111 != 0) {
        // On POSIX, set executable permission
        const stat = try file.stat();
        const new_mode = stat.mode | 0o111;
        try file.chmod(new_mode);
    }
}

/// Delete a file from the working tree.
fn deleteFromWorkTree(work_dir: []const u8, rel_path: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&path_buf);
    const writer = stream.writer();
    writer.writeAll(work_dir) catch return;
    writer.writeByte('/') catch return;
    writer.writeAll(rel_path) catch return;
    const full_path = path_buf[0..stream.pos];

    std.fs.deleteFileAbsolute(full_path) catch {};

    // Try to remove empty parent directories
    removeEmptyParents(work_dir, full_path);
}

/// Try to remove empty parent directories up to work_dir.
fn removeEmptyParents(work_dir: []const u8, path: []const u8) void {
    var current = path;
    while (true) {
        const parent = std.fs.path.dirname(current) orelse return;
        if (parent.len <= work_dir.len) return;
        // Try to remove; if non-empty or other error, stop
        std.fs.deleteDirAbsolute(parent) catch return;
        current = parent;
    }
}

/// Build an index from a flattened tree.
fn buildIndexFromTree(
    allocator: std.mem.Allocator,
    flat: *const FlatTreeResult,
) !index_mod.Index {
    var idx = index_mod.Index.init(allocator);
    errdefer idx.deinit();

    for (flat.entries.items) |*entry| {
        // Create owned copy of the name
        const name_copy = try allocator.alloc(u8, entry.path.len);
        @memcpy(name_copy, entry.path);

        try idx.addEntry(.{
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

    return idx;
}

/// Write a direct (non-symref) OID to HEAD for detached HEAD mode.
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

/// Main checkout entry point.
pub fn runCheckout(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var create_branch = false;
    var target: ?[]const u8 = null;
    var restore_file: ?[]const u8 = null;
    var saw_dashdash = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-b")) {
            create_branch = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            saw_dashdash = true;
            // The next arg is a file to restore
            i += 1;
            if (i < args.len) {
                restore_file = args[i];
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (target == null) {
                target = arg;
            } else if (saw_dashdash) {
                restore_file = arg;
            }
        }
    }

    if (restore_file) |file_path| {
        return restoreFileFromIndex(repo, allocator, file_path);
    }

    if (target == null) {
        try stderr_file.writeAll("fatal: you must specify a branch or commit to checkout\n");
        std.process.exit(1);
    }

    if (create_branch) {
        return checkoutCreateBranch(repo, allocator, target.?);
    }

    // Check if target is a branch name
    if (resolveToBranch(allocator, repo.git_dir, target.?)) |branch_name| {
        return checkoutBranch(repo, allocator, branch_name);
    }

    // Try as a commit (detached HEAD)
    const oid = repo.resolveRef(allocator, target.?) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: pathspec '{s}' did not match any file(s) known to git\n", .{target.?}) catch
            "error: pathspec did not match\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    };

    return checkoutDetached(repo, allocator, oid, target.?);
}

/// Checkout an existing branch.
fn checkoutBranch(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    branch_name: []const u8,
) !void {
    // Resolve the target branch ref
    var ref_buf: [512]u8 = undefined;
    const ref_prefix = "refs/heads/";
    if (ref_prefix.len + branch_name.len > ref_buf.len) {
        try stderr_file.writeAll("error: branch name too long\n");
        std.process.exit(1);
    }
    @memcpy(ref_buf[0..ref_prefix.len], ref_prefix);
    @memcpy(ref_buf[ref_prefix.len..][0..branch_name.len], branch_name);
    const target_ref = ref_buf[0 .. ref_prefix.len + branch_name.len];

    const target_oid = ref_mod.readRef(allocator, repo.git_dir, target_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: branch '{s}' not found\n", .{branch_name}) catch
            "error: branch not found\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    };

    // Read the target commit to get its tree
    var target_commit = try repo.readObject(allocator, &target_oid);
    defer target_commit.deinit();
    if (target_commit.obj_type != .commit) {
        try stderr_file.writeAll("error: target is not a commit\n");
        std.process.exit(1);
    }
    const target_tree_oid = try getCommitTreeOid(target_commit.data);

    // Read current HEAD commit tree (if any)
    var current_tree_oid: ?types.ObjectId = null;
    const head_oid_result = repo.resolveRef(allocator, "HEAD");
    if (head_oid_result) |head_oid| {
        var head_commit = repo.readObject(allocator, &head_oid) catch null;
        if (head_commit) |*hc| {
            defer hc.deinit();
            if (hc.obj_type == .commit) {
                current_tree_oid = getCommitTreeOid(hc.data) catch null;
            }
        }
    } else |_| {}

    const work_dir = getWorkDir(repo.git_dir);

    // Flatten target tree
    var target_flat = try flattenTree(allocator, repo, &target_tree_oid);
    defer target_flat.deinit();

    // If we have a current tree, figure out what changed
    if (current_tree_oid) |cur_tree| {
        var current_flat = try flattenTree(allocator, repo, &cur_tree);
        defer current_flat.deinit();

        // Delete files that are in current but not in target
        for (current_flat.entries.items) |*entry| {
            if (target_flat.findByPath(entry.path) == null) {
                deleteFromWorkTree(work_dir, entry.path);
            }
        }
    }

    // Write all files from target tree to working directory
    for (target_flat.entries.items) |*entry| {
        writeBlobToWorkTree(allocator, repo, work_dir, entry.path, &entry.oid, entry.mode) catch {};
    }

    // Build and write new index
    var new_idx = try buildIndexFromTree(allocator, &target_flat);
    defer new_idx.deinit();

    var idx_path_buf: [4096]u8 = undefined;
    var idx_stream = std.io.fixedBufferStream(&idx_path_buf);
    const idx_writer = idx_stream.writer();
    try idx_writer.writeAll(repo.git_dir);
    try idx_writer.writeAll("/index");
    const idx_path = idx_path_buf[0..idx_stream.pos];

    try new_idx.writeToFile(idx_path);

    // Update HEAD symref to point to the branch
    try ref_mod.updateSymRef(repo.git_dir, "HEAD", target_ref);

    // Append reflog
    const old_oid = if (head_oid_result) |h| h else |_| types.ObjectId.ZERO;
    var reflog_msg_buf: [256]u8 = undefined;
    const reflog_msg = std.fmt.bufPrint(&reflog_msg_buf, "checkout: moving from HEAD to {s}", .{branch_name}) catch "checkout";
    reflog_mod.appendReflog(repo.git_dir, "HEAD", old_oid, target_oid, reflog_msg) catch {};

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Switched to branch '{s}'\n", .{branch_name}) catch "Switched to branch\n";
    try stderr_file.writeAll(msg);
}

/// Create and switch to a new branch.
fn checkoutCreateBranch(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    branch_name: []const u8,
) !void {
    // Resolve HEAD
    const head_oid = repo.resolveRef(allocator, "HEAD") catch {
        try stderr_file.writeAll("fatal: not a valid object name: 'HEAD'\n");
        std.process.exit(128);
    };

    // Build ref name
    var ref_buf: [512]u8 = undefined;
    const ref_prefix = "refs/heads/";
    if (ref_prefix.len + branch_name.len > ref_buf.len) {
        try stderr_file.writeAll("fatal: branch name too long\n");
        std.process.exit(128);
    }
    @memcpy(ref_buf[0..ref_prefix.len], ref_prefix);
    @memcpy(ref_buf[ref_prefix.len..][0..branch_name.len], branch_name);
    const target_ref = ref_buf[0 .. ref_prefix.len + branch_name.len];

    // Check if branch already exists
    if (ref_mod.readRef(allocator, repo.git_dir, target_ref)) |_| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: a branch named '{s}' already exists\n", .{branch_name}) catch
            "fatal: branch already exists\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    } else |_| {}

    // Create the branch ref at HEAD
    try ref_mod.createRef(allocator, repo.git_dir, target_ref, head_oid, null);

    // Update HEAD symref
    try ref_mod.updateSymRef(repo.git_dir, "HEAD", target_ref);

    // Append reflog
    reflog_mod.appendReflog(repo.git_dir, target_ref, types.ObjectId.ZERO, head_oid, "branch: Created from HEAD") catch {};
    reflog_mod.appendReflog(repo.git_dir, "HEAD", head_oid, head_oid, "checkout: moving to new branch") catch {};

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Switched to a new branch '{s}'\n", .{branch_name}) catch "Switched to a new branch\n";
    try stderr_file.writeAll(msg);
}

/// Checkout a specific commit (detached HEAD).
fn checkoutDetached(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    oid: types.ObjectId,
    name: []const u8,
) !void {
    // Read the commit
    var commit_obj = try repo.readObject(allocator, &oid);
    defer commit_obj.deinit();

    if (commit_obj.obj_type != .commit) {
        try stderr_file.writeAll("error: target is not a commit\n");
        std.process.exit(1);
    }

    const target_tree_oid = try getCommitTreeOid(commit_obj.data);
    const subject = getCommitSubject(commit_obj.data);
    const hex = oid.toHex();

    // Get current tree for diffing
    var current_tree_oid: ?types.ObjectId = null;
    const head_oid_result = repo.resolveRef(allocator, "HEAD");
    if (head_oid_result) |head_oid| {
        var head_commit = repo.readObject(allocator, &head_oid) catch null;
        if (head_commit) |*hc| {
            defer hc.deinit();
            if (hc.obj_type == .commit) {
                current_tree_oid = getCommitTreeOid(hc.data) catch null;
            }
        }
    } else |_| {}

    const work_dir = getWorkDir(repo.git_dir);

    // Flatten target tree
    var target_flat = try flattenTree(allocator, repo, &target_tree_oid);
    defer target_flat.deinit();

    // Delete files not in target
    if (current_tree_oid) |cur_tree| {
        var current_flat = try flattenTree(allocator, repo, &cur_tree);
        defer current_flat.deinit();

        for (current_flat.entries.items) |*entry| {
            if (target_flat.findByPath(entry.path) == null) {
                deleteFromWorkTree(work_dir, entry.path);
            }
        }
    }

    // Write target tree files
    for (target_flat.entries.items) |*entry| {
        writeBlobToWorkTree(allocator, repo, work_dir, entry.path, &entry.oid, entry.mode) catch {};
    }

    // Build and write index
    var new_idx = try buildIndexFromTree(allocator, &target_flat);
    defer new_idx.deinit();

    var idx_path_buf: [4096]u8 = undefined;
    var idx_stream = std.io.fixedBufferStream(&idx_path_buf);
    const idx_writer = idx_stream.writer();
    try idx_writer.writeAll(repo.git_dir);
    try idx_writer.writeAll("/index");
    const idx_path = idx_path_buf[0..idx_stream.pos];

    try new_idx.writeToFile(idx_path);

    // Write detached HEAD (direct OID)
    try writeDetachedHead(repo.git_dir, oid);

    // Append reflog
    const old_oid = if (head_oid_result) |h| h else |_| types.ObjectId.ZERO;
    var reflog_msg_buf: [256]u8 = undefined;
    const reflog_msg = std.fmt.bufPrint(&reflog_msg_buf, "checkout: moving to {s}", .{name}) catch "checkout";
    reflog_mod.appendReflog(repo.git_dir, "HEAD", old_oid, oid, reflog_msg) catch {};

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "HEAD is now at {s} {s}\n", .{ hex[0..7], subject }) catch "HEAD is now at detached commit\n";
    try stderr_file.writeAll(msg);

    try stderr_file.writeAll("Note: switching to a detached HEAD state.\n");
}

/// Restore a file from the index to the working tree.
fn restoreFileFromIndex(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !void {
    // Load the index
    var idx_path_buf: [4096]u8 = undefined;
    var idx_stream = std.io.fixedBufferStream(&idx_path_buf);
    const idx_writer = idx_stream.writer();
    try idx_writer.writeAll(repo.git_dir);
    try idx_writer.writeAll("/index");
    const idx_path = idx_path_buf[0..idx_stream.pos];

    var idx = try index_mod.Index.readFromFile(allocator, idx_path);
    defer idx.deinit();

    // Find the entry
    const entry_idx = idx.findEntry(file_path) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: pathspec '{s}' did not match any file(s) known to git\n", .{file_path}) catch
            "error: pathspec did not match\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    };

    const entry = &idx.entries.items[entry_idx];
    const work_dir = getWorkDir(repo.git_dir);

    try writeBlobToWorkTree(allocator, repo, work_dir, entry.name, &entry.oid, entry.mode);
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
