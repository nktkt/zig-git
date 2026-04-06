const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const hash_mod = @import("hash.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Default depth for shallow clones.
const DEFAULT_DEPTH: u32 = 1;

/// Check if the repository is a shallow clone.
pub fn isShallow(git_dir: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const shallow_path = concatStr(&path_buf, git_dir, "/shallow");
    const file = std.fs.openFileAbsolute(shallow_path, .{}) catch return false;
    file.close();
    return true;
}

/// Get the list of shallow boundary commits.
/// These are commits where history stops in a shallow clone.
/// Caller owns the returned slice.
pub fn getShallowCommits(allocator: std.mem.Allocator, git_dir: []const u8) ![]types.ObjectId {
    var path_buf: [4096]u8 = undefined;
    const shallow_path = concatStr(&path_buf, git_dir, "/shallow");

    const content = readFileContent(allocator, shallow_path) catch return &[_]types.ObjectId{};
    defer allocator.free(content);

    var commits = std.array_list.Managed(types.ObjectId).init(allocator);
    defer commits.deinit();

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r \t");
        if (trimmed.len < types.OID_HEX_LEN) continue;
        const oid = types.ObjectId.fromHex(trimmed[0..types.OID_HEX_LEN]) catch continue;
        try commits.append(oid);
    }

    return commits.toOwnedSlice();
}

/// Check if a given commit OID is a shallow boundary.
pub fn isShallowCommit(allocator: std.mem.Allocator, git_dir: []const u8, oid: *const types.ObjectId) bool {
    const commits = getShallowCommits(allocator, git_dir) catch return false;
    defer allocator.free(commits);

    for (commits) |shallow_oid| {
        if (shallow_oid.eql(oid)) return true;
    }
    return false;
}

/// Add a commit to the shallow boundary list.
pub fn addShallowCommit(allocator: std.mem.Allocator, git_dir: []const u8, oid: *const types.ObjectId) !void {
    // Read existing shallow file
    const existing = getShallowCommits(allocator, git_dir) catch &[_]types.ObjectId{};
    defer if (existing.len > 0) allocator.free(existing);

    // Check if already present
    for (existing) |existing_oid| {
        if (existing_oid.eql(oid)) return;
    }

    // Append new commit
    var path_buf: [4096]u8 = undefined;
    const shallow_path = concatStr(&path_buf, git_dir, "/shallow");

    // Build new content
    var content = std.array_list.Managed(u8).init(allocator);
    defer content.deinit();

    for (existing) |existing_oid| {
        const hex = existing_oid.toHex();
        try content.appendSlice(&hex);
        try content.append('\n');
    }

    const hex = oid.toHex();
    try content.appendSlice(&hex);
    try content.append('\n');

    const file = std.fs.createFileAbsolute(shallow_path, .{}) catch return error.CannotWriteShallowFile;
    defer file.close();
    file.writeAll(content.items) catch return error.CannotWriteShallowFile;
}

/// Remove a commit from the shallow boundary list.
pub fn removeShallowCommit(allocator: std.mem.Allocator, git_dir: []const u8, oid: *const types.ObjectId) !void {
    const existing = getShallowCommits(allocator, git_dir) catch return;
    defer allocator.free(existing);

    var content = std.array_list.Managed(u8).init(allocator);
    defer content.deinit();

    var removed = false;
    for (existing) |existing_oid| {
        if (existing_oid.eql(oid)) {
            removed = true;
            continue;
        }
        const hex = existing_oid.toHex();
        try content.appendSlice(&hex);
        try content.append('\n');
    }

    if (!removed) return;

    var path_buf: [4096]u8 = undefined;
    const shallow_path = concatStr(&path_buf, git_dir, "/shallow");

    if (content.items.len == 0) {
        // Remove the shallow file entirely
        std.fs.deleteFileAbsolute(shallow_path) catch {};
        return;
    }

    const file = std.fs.createFileAbsolute(shallow_path, .{}) catch return error.CannotWriteShallowFile;
    defer file.close();
    file.writeAll(content.items) catch return error.CannotWriteShallowFile;
}

/// Walk commits from a tip with depth limit, collecting shallow boundaries.
/// Returns the commits within the depth limit and adds boundary commits to the shallow set.
pub fn walkWithDepth(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    tip: *const types.ObjectId,
    depth: u32,
) !WalkResult {
    var result = WalkResult{
        .commits = std.array_list.Managed(types.ObjectId).init(allocator),
        .boundaries = std.array_list.Managed(types.ObjectId).init(allocator),
    };
    errdefer {
        result.commits.deinit();
        result.boundaries.deinit();
    }

    const DepthEntry = struct {
        oid: types.ObjectId,
        depth_val: u32,
    };

    var queue = std.array_list.Managed(DepthEntry).init(allocator);
    defer queue.deinit();

    var visited = std.AutoHashMap([types.OID_RAW_LEN]u8, void).init(allocator);
    defer visited.deinit();

    try queue.append(.{ .oid = tip.*, .depth_val = 0 });
    try visited.put(tip.bytes, {});

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);

        if (current.depth_val >= depth) {
            // This commit is at the boundary
            try result.boundaries.append(current.oid);
            continue;
        }

        try result.commits.append(current.oid);

        // Read commit to find parents
        var obj = repo.readObject(allocator, &current.oid) catch continue;
        defer obj.deinit();

        if (obj.obj_type != .commit) continue;

        const parents = try parseCommitParents(allocator, obj.data);
        defer allocator.free(parents);

        for (parents) |parent_oid| {
            if (!visited.contains(parent_oid.bytes)) {
                try visited.put(parent_oid.bytes, {});
                try queue.append(.{ .oid = parent_oid, .depth_val = current.depth_val + 1 });
            }
        }
    }

    return result;
}

pub const WalkResult = struct {
    commits: std.array_list.Managed(types.ObjectId),
    boundaries: std.array_list.Managed(types.ObjectId),

    pub fn deinit(self: *WalkResult) void {
        self.commits.deinit();
        self.boundaries.deinit();
    }
};

/// Deepen a shallow clone by the specified number of commits.
pub fn deepen(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    additional_depth: u32,
) !void {
    const shallow_commits = try getShallowCommits(allocator, repo.git_dir);
    defer allocator.free(shallow_commits);

    if (shallow_commits.len == 0) {
        try stdout_file.writeAll("Repository is not shallow.\n");
        return;
    }

    var new_boundaries = std.array_list.Managed(types.ObjectId).init(allocator);
    defer new_boundaries.deinit();

    for (shallow_commits) |shallow_oid| {
        // Walk from this shallow boundary further
        var walk = try walkWithDepth(allocator, repo, &shallow_oid, additional_depth);
        defer walk.deinit();

        // New shallow boundaries
        for (walk.boundaries.items) |boundary| {
            try new_boundaries.append(boundary);
        }
    }

    // Update shallow file
    var path_buf: [4096]u8 = undefined;
    const shallow_path = concatStr(&path_buf, repo.git_dir, "/shallow");

    if (new_boundaries.items.len == 0) {
        // No more boundaries - remove shallow file
        std.fs.deleteFileAbsolute(shallow_path) catch {};
        try stdout_file.writeAll("Repository is no longer shallow.\n");
    } else {
        var content = std.array_list.Managed(u8).init(allocator);
        defer content.deinit();

        for (new_boundaries.items) |boundary| {
            const hex = boundary.toHex();
            try content.appendSlice(&hex);
            try content.append('\n');
        }

        const file = std.fs.createFileAbsolute(shallow_path, .{}) catch {
            try stderr_file.writeAll("fatal: cannot write shallow file\n");
            std.process.exit(128);
        };
        defer file.close();
        file.writeAll(content.items) catch {
            try stderr_file.writeAll("fatal: cannot write shallow file\n");
            std.process.exit(128);
        };

        var out_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&out_buf, "Deepened by {d} commits. {d} new boundary commit(s).\n", .{ additional_depth, new_boundaries.items.len }) catch "Deepened.\n";
        try stdout_file.writeAll(msg);
    }
}

/// Convert a shallow clone to a full clone.
pub fn unshallow(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
) !void {
    _ = allocator;
    if (!isShallow(repo.git_dir)) {
        try stdout_file.writeAll("Repository is not shallow.\n");
        return;
    }

    var path_buf: [4096]u8 = undefined;
    const shallow_path = concatStr(&path_buf, repo.git_dir, "/shallow");

    std.fs.deleteFileAbsolute(shallow_path) catch {
        try stderr_file.writeAll("fatal: cannot remove shallow file\n");
        std.process.exit(128);
    };

    try stdout_file.writeAll("Repository is no longer shallow.\n");
    try stdout_file.writeAll("Note: you may need to fetch to get full history.\n");
}

/// Show shallow status information.
pub fn showStatus(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
) !void {
    if (!isShallow(git_dir)) {
        try stdout_file.writeAll("This repository is not shallow.\n");
        return;
    }

    const commits = try getShallowCommits(allocator, git_dir);
    defer allocator.free(commits);

    var out_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&out_buf, "This is a shallow repository with {d} boundary commit(s):\n", .{commits.len}) catch "This is a shallow repository.\n";
    try stdout_file.writeAll(msg);

    for (commits) |oid| {
        const hex = oid.toHex();
        var line_buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "  {s}\n", .{hex[0..7]}) catch continue;
        try stdout_file.writeAll(line);
    }
}

/// Parse options related to shallow cloning.
pub const ShallowOptions = struct {
    depth: ?u32 = null,
    deepen_amount: ?u32 = null,
    do_unshallow: bool = false,

    pub fn parseArg(self: *ShallowOptions, arg: []const u8) bool {
        if (std.mem.startsWith(u8, arg, "--depth=")) {
            self.depth = std.fmt.parseInt(u32, arg["--depth=".len..], 10) catch return false;
            return true;
        }
        if (std.mem.startsWith(u8, arg, "--deepen=")) {
            self.deepen_amount = std.fmt.parseInt(u32, arg["--deepen=".len..], 10) catch return false;
            return true;
        }
        if (std.mem.eql(u8, arg, "--unshallow")) {
            self.do_unshallow = true;
            return true;
        }
        return false;
    }
};

// --- Helpers ---

fn readFileContent(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return error.FileNotFound;
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

fn parseCommitParents(allocator: std.mem.Allocator, data: []const u8) ![]types.ObjectId {
    var parents = std.array_list.Managed(types.ObjectId).init(allocator);
    defer parents.deinit();

    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "parent ")) {
            if (line.len >= 7 + types.OID_HEX_LEN) {
                const oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch continue;
                try parents.append(oid);
            }
        }
    }

    return parents.toOwnedSlice();
}

fn concatStr(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

test "isShallow returns false for non-existent" {
    try std.testing.expect(!isShallow("/nonexistent/path/.git"));
}

test "ShallowOptions parseArg" {
    var opts = ShallowOptions{};
    try std.testing.expect(opts.parseArg("--depth=5"));
    try std.testing.expectEqual(@as(?u32, 5), opts.depth);

    try std.testing.expect(opts.parseArg("--deepen=3"));
    try std.testing.expectEqual(@as(?u32, 3), opts.deepen_amount);

    try std.testing.expect(opts.parseArg("--unshallow"));
    try std.testing.expect(opts.do_unshallow);

    try std.testing.expect(!opts.parseArg("--other"));
}
