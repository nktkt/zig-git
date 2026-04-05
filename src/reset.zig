const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");
const tree_diff = @import("tree_diff.zig");
const checkout_mod = @import("checkout.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const ResetMode = enum {
    soft,
    mixed,
    hard,
};

/// Get the working directory from git_dir.
fn getWorkDir(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    if (std.fs.path.dirname(git_dir)) |parent| {
        return parent;
    }
    return git_dir;
}

/// Get the commit tree OID from commit data.
fn getCommitTreeOid(commit_data: []const u8) !types.ObjectId {
    return tree_diff.getCommitTreeOid(commit_data);
}

/// Build an index from a flattened tree.
fn buildIndexFromTree(
    allocator: std.mem.Allocator,
    flat: *const checkout_mod.FlatTreeResult,
) !index_mod.Index {
    var idx = index_mod.Index.init(allocator);
    errdefer idx.deinit();

    for (flat.entries.items) |*entry| {
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

/// Write a blob to the working tree.
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
    removeEmptyParents(work_dir, full_path);
}

fn removeEmptyParents(work_dir: []const u8, path: []const u8) void {
    var current = path;
    while (true) {
        const parent = std.fs.path.dirname(current) orelse return;
        if (parent.len <= work_dir.len) return;
        std.fs.deleteDirAbsolute(parent) catch return;
        current = parent;
    }
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

/// Get the index path for the repo.
fn getIndexPath(git_dir: []const u8, buf: []u8) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.writeAll(git_dir) catch return "";
    writer.writeAll("/index") catch return "";
    return buf[0..stream.pos];
}

/// Main reset entry point.
pub fn runReset(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var mode: ResetMode = .mixed;
    var target_ref: ?[]const u8 = null;
    var file_to_unstage: ?[]const u8 = null;

    // Parse args
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--soft")) {
            mode = .soft;
        } else if (std.mem.eql(u8, arg, "--mixed")) {
            mode = .mixed;
        } else if (std.mem.eql(u8, arg, "--hard")) {
            mode = .hard;
        } else if (std.mem.eql(u8, arg, "--")) {
            // Everything after -- is file paths
            i += 1;
            if (i < args.len) {
                file_to_unstage = args[i];
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Could be a commit ref or a file path
            // If we already have a target_ref and this looks like a file, treat as file
            if (target_ref != null) {
                file_to_unstage = arg;
            } else {
                // Try to resolve as a ref first
                if (repo.resolveRef(allocator, arg)) |_| {
                    target_ref = arg;
                } else |_| {
                    // Could be a file path for unstaging
                    file_to_unstage = arg;
                }
            }
        }
    }

    // If we have a file to unstage, do that instead
    if (file_to_unstage) |file_path| {
        return resetFile(repo, allocator, file_path);
    }

    // Resolve target commit
    const target_name = target_ref orelse "HEAD";
    const target_oid = repo.resolveRef(allocator, target_name) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: Failed to resolve '{s}' as a valid ref.\n", .{target_name}) catch
            "fatal: Failed to resolve ref\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    // Verify it's a commit
    var target_commit = try repo.readObject(allocator, &target_oid);
    defer target_commit.deinit();

    if (target_commit.obj_type != .commit) {
        try stderr_file.writeAll("fatal: cannot reset to a non-commit object\n");
        std.process.exit(128);
    }

    // Get old HEAD for reflog
    const old_head_oid = repo.resolveRef(allocator, "HEAD") catch types.ObjectId.ZERO;

    // Step 1: Update HEAD/branch ref to target
    const head_ref = ref_mod.readHead(allocator, repo.git_dir) catch null;
    defer if (head_ref) |h| allocator.free(h);

    if (head_ref) |branch_ref| {
        // HEAD points to a branch - update the branch
        try ref_mod.createRef(allocator, repo.git_dir, branch_ref, target_oid, null);
    } else {
        // Detached HEAD - update HEAD directly
        try writeDetachedHead(repo.git_dir, target_oid);
    }

    const target_tree_oid = try getCommitTreeOid(target_commit.data);

    // Step 2: If mixed or hard, reset index to match target tree
    if (mode == .mixed or mode == .hard) {
        var target_flat = try checkout_mod.flattenTree(allocator, repo, &target_tree_oid);
        defer target_flat.deinit();

        var new_idx = try buildIndexFromTree(allocator, &target_flat);
        defer new_idx.deinit();

        var idx_path_buf: [4096]u8 = undefined;
        const idx_path = getIndexPath(repo.git_dir, &idx_path_buf);
        try new_idx.writeToFile(idx_path);

        // Step 3: If hard, update working tree
        if (mode == .hard) {
            const work_dir = getWorkDir(repo.git_dir);

            // Get current tree to find files to delete
            if (old_head_oid.eql(&types.ObjectId.ZERO)) {
                // No previous HEAD; just write target files
            } else {
                var old_commit = repo.readObject(allocator, &old_head_oid) catch null;
                if (old_commit) |*oc| {
                    defer oc.deinit();
                    if (oc.obj_type == .commit) {
                        const old_tree_oid = getCommitTreeOid(oc.data) catch null;
                        if (old_tree_oid) |otoid| {
                            var old_flat = checkout_mod.flattenTree(allocator, repo, &otoid) catch null;
                            if (old_flat) |*of| {
                                defer of.deinit();
                                for (of.entries.items) |*entry| {
                                    if (target_flat.findByPath(entry.path) == null) {
                                        deleteFromWorkTree(work_dir, entry.path);
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Write all target files
            for (target_flat.entries.items) |*entry| {
                writeBlobToWorkTree(allocator, repo, work_dir, entry.path, &entry.oid, entry.mode) catch {};
            }
        }
    }

    // Append reflog
    var reflog_msg_buf: [256]u8 = undefined;
    const mode_str = switch (mode) {
        .soft => "soft",
        .mixed => "mixed",
        .hard => "hard",
    };
    const reflog_msg = std.fmt.bufPrint(&reflog_msg_buf, "reset: moving to {s} (--{s})", .{ target_name, mode_str }) catch "reset";
    reflog_mod.appendReflog(repo.git_dir, "HEAD", old_head_oid, target_oid, reflog_msg) catch {};

    // Remove merge state if any
    removeMergeState(repo.git_dir);

    // Print result
    const hex = target_oid.toHex();
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "HEAD is now at {s}\n", .{hex[0..7]}) catch "HEAD updated\n";

    if (mode == .hard) {
        try stdout_file.writeAll(msg);
    } else {
        // For soft/mixed, print "Unstaged changes after reset:" if there are changes
        try stdout_file.writeAll(msg);
    }
}

/// Reset a single file in the index to its HEAD version (unstage).
fn resetFile(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !void {
    // Load the index
    var idx_path_buf: [4096]u8 = undefined;
    const idx_path = getIndexPath(repo.git_dir, &idx_path_buf);

    var idx = try index_mod.Index.readFromFile(allocator, idx_path);
    defer idx.deinit();

    // Get HEAD commit tree
    const head_oid = repo.resolveRef(allocator, "HEAD") catch {
        // No HEAD - just remove from index
        if (idx.removeEntry(file_path)) {
            try idx.writeToFile(idx_path);
        }
        return;
    };

    var head_commit = try repo.readObject(allocator, &head_oid);
    defer head_commit.deinit();

    if (head_commit.obj_type != .commit) return;

    const tree_oid = try getCommitTreeOid(head_commit.data);

    // Flatten the tree to find the file
    var head_flat = try checkout_mod.flattenTree(allocator, repo, &tree_oid);
    defer head_flat.deinit();

    if (head_flat.findByPath(file_path)) |head_entry| {
        // File exists in HEAD - reset index entry to HEAD version
        const name_copy = try allocator.alloc(u8, file_path.len);
        @memcpy(name_copy, file_path);

        // Remove existing entry and add the HEAD version
        _ = idx.removeEntry(file_path);
        try idx.addEntry(.{
            .ctime_s = 0,
            .ctime_ns = 0,
            .mtime_s = 0,
            .mtime_ns = 0,
            .dev = 0,
            .ino = 0,
            .mode = head_entry.mode,
            .uid = 0,
            .gid = 0,
            .file_size = 0,
            .oid = head_entry.oid,
            .flags = 0,
            .name = name_copy,
            .owned = true,
        });
    } else {
        // File doesn't exist in HEAD - remove from index
        _ = idx.removeEntry(file_path);
    }

    try idx.writeToFile(idx_path);
}

fn removeMergeState(git_dir: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);

    const mh_suffix = "/MERGE_HEAD";
    @memcpy(path_buf[git_dir.len..][0..mh_suffix.len], mh_suffix);
    std.fs.deleteFileAbsolute(path_buf[0 .. git_dir.len + mh_suffix.len]) catch {};

    const mm_suffix = "/MERGE_MSG";
    @memcpy(path_buf[git_dir.len..][0..mm_suffix.len], mm_suffix);
    std.fs.deleteFileAbsolute(path_buf[0 .. git_dir.len + mm_suffix.len]) catch {};
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
