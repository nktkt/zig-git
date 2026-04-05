const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");

/// Represents the kind of change for a file between two trees.
pub const ChangeKind = enum {
    added,
    deleted,
    modified,
};

/// A single file change between two trees.
pub const TreeChange = struct {
    path: []const u8,
    old_oid: ?types.ObjectId,
    new_oid: ?types.ObjectId,
    old_mode: ?[]const u8,
    new_mode: ?[]const u8,
    kind: ChangeKind,
};

/// Result of diffing two trees. Owns all allocated memory.
pub const TreeDiffResult = struct {
    changes: std.array_list.Managed(TreeChange),
    /// Pool of owned strings (paths, mode strings).
    strings: std.array_list.Managed([]u8),

    pub fn deinit(self: *TreeDiffResult) void {
        self.changes.deinit();
        for (self.strings.items) |s| {
            self.changes.allocator.free(s);
        }
        self.strings.deinit();
    }
};

/// Represents a parsed entry from a tree object's binary data.
const ParsedTreeEntry = struct {
    mode: []const u8,
    name: []const u8,
    oid: types.ObjectId,
};

/// Compare two tree OIDs and return list of file-level changes.
/// Either old_tree_oid or new_tree_oid can be null (for initial commit or deletion).
pub fn diffTrees(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    old_tree_oid: ?*const types.ObjectId,
    new_tree_oid: ?*const types.ObjectId,
) !TreeDiffResult {
    var result = TreeDiffResult{
        .changes = std.array_list.Managed(TreeChange).init(allocator),
        .strings = std.array_list.Managed([]u8).init(allocator),
    };
    errdefer result.deinit();

    try diffTreesRecursive(repo, allocator, old_tree_oid, new_tree_oid, "", &result);

    return result;
}

/// Recursively diff two trees, accumulating changes.
fn diffTreesRecursive(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    old_tree_oid: ?*const types.ObjectId,
    new_tree_oid: ?*const types.ObjectId,
    prefix: []const u8,
    result: *TreeDiffResult,
) !void {
    // Read old tree entries
    var old_entries = std.array_list.Managed(ParsedTreeEntry).init(allocator);
    defer old_entries.deinit();
    var old_data_holder: ?types.Object = null;
    defer if (old_data_holder) |*o| o.deinit();

    if (old_tree_oid) |oid| {
        var obj = try repo.readObject(allocator, oid);
        if (obj.obj_type != .tree) {
            obj.deinit();
            return error.NotATree;
        }
        old_data_holder = obj;
        try parseTreeEntries(obj.data, &old_entries);
    }

    // Read new tree entries
    var new_entries = std.array_list.Managed(ParsedTreeEntry).init(allocator);
    defer new_entries.deinit();
    var new_data_holder: ?types.Object = null;
    defer if (new_data_holder) |*o| o.deinit();

    if (new_tree_oid) |oid| {
        var obj = try repo.readObject(allocator, oid);
        if (obj.obj_type != .tree) {
            obj.deinit();
            return error.NotATree;
        }
        new_data_holder = obj;
        try parseTreeEntries(obj.data, &new_entries);
    }

    // Merge-style comparison: both lists are sorted by name (git guarantees this).
    var oi: usize = 0;
    var ni: usize = 0;

    while (oi < old_entries.items.len or ni < new_entries.items.len) {
        const cmp = entryCompare(
            if (oi < old_entries.items.len) &old_entries.items[oi] else null,
            if (ni < new_entries.items.len) &new_entries.items[ni] else null,
        );

        if (cmp == .only_old) {
            // Entry only in old tree -> deleted
            const old_e = &old_entries.items[oi];
            const full_path = try buildPath(allocator, prefix, old_e.name);
            try result.strings.append(full_path);

            if (isTreeMode(old_e.mode)) {
                // Recursively mark all entries as deleted
                try diffTreesRecursive(repo, allocator, &old_e.oid, null, full_path, result);
            } else {
                const mode_copy = try dupeString(allocator, old_e.mode);
                try result.strings.append(mode_copy);
                try result.changes.append(.{
                    .path = full_path,
                    .old_oid = old_e.oid,
                    .new_oid = null,
                    .old_mode = mode_copy,
                    .new_mode = null,
                    .kind = .deleted,
                });
            }
            oi += 1;
        } else if (cmp == .only_new) {
            // Entry only in new tree -> added
            const new_e = &new_entries.items[ni];
            const full_path = try buildPath(allocator, prefix, new_e.name);
            try result.strings.append(full_path);

            if (isTreeMode(new_e.mode)) {
                try diffTreesRecursive(repo, allocator, null, &new_e.oid, full_path, result);
            } else {
                const mode_copy = try dupeString(allocator, new_e.mode);
                try result.strings.append(mode_copy);
                try result.changes.append(.{
                    .path = full_path,
                    .old_oid = null,
                    .new_oid = new_e.oid,
                    .old_mode = null,
                    .new_mode = mode_copy,
                    .kind = .added,
                });
            }
            ni += 1;
        } else {
            // Same name in both trees
            const old_e = &old_entries.items[oi];
            const new_e = &new_entries.items[ni];
            const full_path = try buildPath(allocator, prefix, old_e.name);
            try result.strings.append(full_path);

            const old_is_tree = isTreeMode(old_e.mode);
            const new_is_tree = isTreeMode(new_e.mode);

            if (old_is_tree and new_is_tree) {
                // Both are trees -> recurse if OIDs differ
                if (!old_e.oid.eql(&new_e.oid)) {
                    try diffTreesRecursive(repo, allocator, &old_e.oid, &new_e.oid, full_path, result);
                }
            } else if (old_is_tree and !new_is_tree) {
                // Tree replaced by blob
                try diffTreesRecursive(repo, allocator, &old_e.oid, null, full_path, result);
                const mode_copy = try dupeString(allocator, new_e.mode);
                try result.strings.append(mode_copy);
                try result.changes.append(.{
                    .path = full_path,
                    .old_oid = null,
                    .new_oid = new_e.oid,
                    .old_mode = null,
                    .new_mode = mode_copy,
                    .kind = .added,
                });
            } else if (!old_is_tree and new_is_tree) {
                // Blob replaced by tree
                const mode_copy = try dupeString(allocator, old_e.mode);
                try result.strings.append(mode_copy);
                try result.changes.append(.{
                    .path = full_path,
                    .old_oid = old_e.oid,
                    .new_oid = null,
                    .old_mode = mode_copy,
                    .new_mode = null,
                    .kind = .deleted,
                });
                try diffTreesRecursive(repo, allocator, null, &new_e.oid, full_path, result);
            } else {
                // Both are blobs -> check if modified
                if (!old_e.oid.eql(&new_e.oid) or !std.mem.eql(u8, old_e.mode, new_e.mode)) {
                    const old_mode_copy = try dupeString(allocator, old_e.mode);
                    try result.strings.append(old_mode_copy);
                    const new_mode_copy = try dupeString(allocator, new_e.mode);
                    try result.strings.append(new_mode_copy);
                    try result.changes.append(.{
                        .path = full_path,
                        .old_oid = old_e.oid,
                        .new_oid = new_e.oid,
                        .old_mode = old_mode_copy,
                        .new_mode = new_mode_copy,
                        .kind = .modified,
                    });
                }
            }
            oi += 1;
            ni += 1;
        }
    }
}

const CompareResult = enum {
    only_old,
    only_new,
    both,
};

fn entryCompare(old_entry: ?*const ParsedTreeEntry, new_entry: ?*const ParsedTreeEntry) CompareResult {
    if (old_entry == null) return .only_new;
    if (new_entry == null) return .only_old;

    const old_e = old_entry.?;
    const new_e = new_entry.?;

    // Git sorts tree entries with a trailing '/' for directories
    const order = compareTreeEntryNames(old_e.name, old_e.mode, new_e.name, new_e.mode);
    if (order == .lt) return .only_old;
    if (order == .gt) return .only_new;
    return .both;
}

/// Compare tree entry names as git does (directories get trailing '/').
fn compareTreeEntryNames(
    a_name: []const u8,
    a_mode: []const u8,
    b_name: []const u8,
    b_mode: []const u8,
) std.math.Order {
    const a_is_tree = isTreeMode(a_mode);
    const b_is_tree = isTreeMode(b_mode);

    // Compare byte by byte, then handle the trailing '/' for trees
    const min_len = @min(a_name.len, b_name.len);
    for (a_name[0..min_len], b_name[0..min_len]) |a, b| {
        if (a < b) return .lt;
        if (a > b) return .gt;
    }

    // If one is shorter, compare the trailing character
    const a_next: u8 = if (a_name.len > min_len) a_name[min_len] else if (a_is_tree) '/' else 0;
    const b_next: u8 = if (b_name.len > min_len) b_name[min_len] else if (b_is_tree) '/' else 0;

    if (a_name.len == b_name.len) return .eq;
    if (a_next < b_next) return .lt;
    if (a_next > b_next) return .gt;
    return .eq;
}

fn isTreeMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "40000");
}

/// Parse all entries from a tree object's binary data.
fn parseTreeEntries(data: []const u8, entries: *std.array_list.Managed(ParsedTreeEntry)) !void {
    var pos: usize = 0;

    while (pos < data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse return error.InvalidTreeEntry;
        const mode = data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, data, space_pos + 1, 0) orelse return error.InvalidTreeEntry;
        const name = data[space_pos + 1 .. null_pos];

        if (null_pos + 1 + types.OID_RAW_LEN > data.len) return error.InvalidTreeEntry;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, data[null_pos + 1 ..][0..types.OID_RAW_LEN]);
        pos = null_pos + 1 + types.OID_RAW_LEN;

        try entries.append(.{
            .mode = mode,
            .name = name,
            .oid = oid,
        });
    }
}

/// Build a full path from a prefix and a name.
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

fn dupeString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const copy = try allocator.alloc(u8, s.len);
    @memcpy(copy, s);
    return copy;
}

/// Parse a commit object's data and extract the tree OID.
pub fn getCommitTreeOid(commit_data: []const u8) !types.ObjectId {
    const tree_prefix = "tree ";
    if (!std.mem.startsWith(u8, commit_data, tree_prefix)) return error.InvalidCommit;
    const newline = std.mem.indexOfScalar(u8, commit_data, '\n') orelse return error.InvalidCommit;
    if (newline < tree_prefix.len + types.OID_HEX_LEN) return error.InvalidCommit;
    const tree_hex = commit_data[tree_prefix.len..][0..types.OID_HEX_LEN];
    return types.ObjectId.fromHex(tree_hex);
}

/// Parse parent OIDs from commit data.
pub fn getCommitParents(allocator: std.mem.Allocator, commit_data: []const u8) !std.array_list.Managed(types.ObjectId) {
    var parents = std.array_list.Managed(types.ObjectId).init(allocator);
    errdefer parents.deinit();

    var lines = std.mem.splitScalar(u8, commit_data, '\n');
    // Skip tree line
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) break; // End of headers
        if (std.mem.startsWith(u8, line, "parent ")) {
            if (line.len < 7 + types.OID_HEX_LEN) continue;
            const oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch continue;
            try parents.append(oid);
        }
    }

    return parents;
}

test "isTreeMode" {
    try std.testing.expect(isTreeMode("40000"));
    try std.testing.expect(!isTreeMode("100644"));
    try std.testing.expect(!isTreeMode("100755"));
}
