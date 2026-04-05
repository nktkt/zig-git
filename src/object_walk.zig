const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");

/// Walk the object graph from a set of tip commits.
/// Returns all reachable object IDs, excluding those reachable from the exclude set.
/// Caller owns the returned slice.
pub fn walkObjects(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    tips: []const types.ObjectId,
    exclude: []const types.ObjectId,
) ![]types.ObjectId {
    // Build the exclude set: walk from exclude tips first
    var visited = OidSet.init(allocator);
    defer visited.deinit();

    // Walk exclude commits to build the exclusion set
    var exclude_queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer exclude_queue.deinit();

    for (exclude) |oid| {
        if (!visited.contains(&oid)) {
            try visited.put(oid);
            try exclude_queue.append(oid);
        }
    }

    // BFS over exclude set (only need to mark commits, not collect)
    while (exclude_queue.items.len > 0) {
        const current = exclude_queue.orderedRemove(0);
        // Only follow commit parents for exclude set
        var obj = repo.readObject(allocator, &current) catch continue;
        defer obj.deinit();

        if (obj.obj_type == .commit) {
            const parents = try parseCommitParents(allocator, obj.data);
            defer allocator.free(parents);
            for (parents) |parent_oid| {
                if (!visited.contains(&parent_oid)) {
                    try visited.put(parent_oid);
                    try exclude_queue.append(parent_oid);
                }
            }
        }
    }

    // Now walk from tips, collecting objects not in exclude set
    var result = std.array_list.Managed(types.ObjectId).init(allocator);
    defer result.deinit();

    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();

    for (tips) |oid| {
        if (!visited.contains(&oid)) {
            try visited.put(oid);
            try queue.append(oid);
            try result.append(oid);
        }
    }

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);

        var obj = repo.readObject(allocator, &current) catch continue;
        defer obj.deinit();

        switch (obj.obj_type) {
            .commit => {
                // Parse tree and parents from commit
                const tree_oid = parseCommitTree(obj.data) catch continue;
                if (!visited.contains(&tree_oid)) {
                    try visited.put(tree_oid);
                    try queue.append(tree_oid);
                    try result.append(tree_oid);
                }

                const parents = try parseCommitParents(allocator, obj.data);
                defer allocator.free(parents);
                for (parents) |parent_oid| {
                    if (!visited.contains(&parent_oid)) {
                        try visited.put(parent_oid);
                        try queue.append(parent_oid);
                        try result.append(parent_oid);
                    }
                }
            },
            .tree => {
                // Parse tree entries
                var pos: usize = 0;
                while (pos < obj.data.len) {
                    const entry_oid = parseTreeEntry(obj.data, &pos) catch break;
                    if (!visited.contains(&entry_oid)) {
                        try visited.put(entry_oid);
                        try queue.append(entry_oid);
                        try result.append(entry_oid);
                    }
                }
            },
            .tag => {
                // Parse the object the tag points to
                const target = parseTagObject(obj.data) catch continue;
                if (!visited.contains(&target)) {
                    try visited.put(target);
                    try queue.append(target);
                    try result.append(target);
                }
            },
            .blob => {
                // Blobs are leaf nodes, nothing to walk
            },
        }
    }

    return result.toOwnedSlice();
}

/// Count reachable objects from tips (useful for progress reporting).
pub fn countReachableObjects(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    tips: []const types.ObjectId,
) !u32 {
    const empty: []const types.ObjectId = &.{};
    const objects = try walkObjects(allocator, repo, tips, empty);
    defer allocator.free(objects);
    return @intCast(objects.len);
}

/// Find objects in source that are missing from target.
/// Returns OIDs of objects present in source but not in target.
pub fn findMissingObjects(
    allocator: std.mem.Allocator,
    source_repo: *repository.Repository,
    target_repo: *repository.Repository,
    tips: []const types.ObjectId,
    exclude: []const types.ObjectId,
) ![]types.ObjectId {
    // Walk from tips in source to get all reachable objects
    const all_objects = try walkObjects(allocator, source_repo, tips, exclude);
    defer allocator.free(all_objects);

    // Filter to only those missing from target
    var missing = std.array_list.Managed(types.ObjectId).init(allocator);
    defer missing.deinit();

    for (all_objects) |oid| {
        if (!target_repo.objectExists(&oid)) {
            try missing.append(oid);
        }
    }

    return missing.toOwnedSlice();
}

// --- Internal parsers ---

/// Parse the tree OID from commit object data.
fn parseCommitTree(data: []const u8) !types.ObjectId {
    // Format: "tree <hex>\n..."
    if (data.len < 5 + types.OID_HEX_LEN) return error.InvalidCommitFormat;
    if (!std.mem.startsWith(u8, data, "tree ")) return error.InvalidCommitFormat;
    return types.ObjectId.fromHex(data[5..][0..types.OID_HEX_LEN]);
}

/// Parse parent OIDs from commit object data.
/// Caller owns the returned slice.
fn parseCommitParents(allocator: std.mem.Allocator, data: []const u8) ![]types.ObjectId {
    var parents = std.array_list.Managed(types.ObjectId).init(allocator);
    defer parents.deinit();

    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) break; // Empty line ends headers
        if (std.mem.startsWith(u8, line, "parent ")) {
            if (line.len >= 7 + types.OID_HEX_LEN) {
                const oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch continue;
                try parents.append(oid);
            }
        }
    }

    return parents.toOwnedSlice();
}

/// Parse a single tree entry, advancing pos.
/// Tree format: "<mode> <name>\0<20-byte-oid>"
fn parseTreeEntry(data: []const u8, pos: *usize) !types.ObjectId {
    if (pos.* >= data.len) return error.EndOfTree;

    // Find the null byte separating name from oid
    const start = pos.*;
    const null_pos = std.mem.indexOfScalarPos(u8, data, start, 0) orelse return error.InvalidTreeEntry;

    if (null_pos + 1 + types.OID_RAW_LEN > data.len) return error.InvalidTreeEntry;

    var oid: types.ObjectId = undefined;
    @memcpy(&oid.bytes, data[null_pos + 1 ..][0..types.OID_RAW_LEN]);

    pos.* = null_pos + 1 + types.OID_RAW_LEN;
    return oid;
}

/// Parse the target object from a tag object.
fn parseTagObject(data: []const u8) !types.ObjectId {
    // Format: "object <hex>\n..."
    if (data.len < 7 + types.OID_HEX_LEN) return error.InvalidTagFormat;
    if (!std.mem.startsWith(u8, data, "object ")) return error.InvalidTagFormat;
    return types.ObjectId.fromHex(data[7..][0..types.OID_HEX_LEN]);
}

// --- OID Set (hash set for ObjectIds) ---

const OidSet = struct {
    map: std.AutoHashMap([types.OID_RAW_LEN]u8, void),

    fn init(allocator: std.mem.Allocator) OidSet {
        return .{
            .map = std.AutoHashMap([types.OID_RAW_LEN]u8, void).init(allocator),
        };
    }

    fn deinit(self: *OidSet) void {
        self.map.deinit();
    }

    fn contains(self: *const OidSet, oid: *const types.ObjectId) bool {
        return self.map.contains(oid.bytes);
    }

    fn put(self: *OidSet, oid: types.ObjectId) !void {
        try self.map.put(oid.bytes, {});
    }
};

test "parseCommitTree" {
    const data = "tree e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\nparent abc\n\nmessage";
    const oid = try parseCommitTree(data);
    const hex = oid.toHex();
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &hex);
}

test "parseCommitParents" {
    const data = "tree e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\nparent aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nparent bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n\nmessage";
    const parents = try parseCommitParents(std.testing.allocator, data);
    defer std.testing.allocator.free(parents);
    try std.testing.expectEqual(@as(usize, 2), parents.len);
}
