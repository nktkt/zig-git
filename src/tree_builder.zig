const std = @import("std");
const types = @import("types.zig");
const loose = @import("loose.zig");
const index_mod = @import("index.zig");

/// A single entry in a tree object being built.
pub const TreeBuildEntry = struct {
    mode: []const u8,
    name: []const u8,
    oid: types.ObjectId,
};

/// Build a tree object hierarchy from the index and write all tree objects
/// to the object database. Returns the root tree OID.
///
/// The algorithm:
///   1. Group index entries by their top-level directory component.
///   2. For entries that are plain files (no '/'), add them directly to the
///      current tree.
///   3. For entries in subdirectories, collect all entries sharing the same
///      first directory component, strip that prefix, and recursively build
///      a subtree. Add the subtree OID to the current tree.
///   4. Serialize the tree entries in sorted order and write as a loose object.
pub fn buildTree(allocator: std.mem.Allocator, git_dir: []const u8, idx: *const index_mod.Index) !types.ObjectId {
    // Collect all (name, mode, oid) pairs from the index.
    // We pass them as a flat list to the recursive builder with the full paths.
    const entries = idx.entries.items;
    if (entries.len == 0) {
        // Empty tree
        return writeTreeObject(allocator, git_dir, &[_]TreeBuildEntry{});
    }

    return buildTreeRecursive(allocator, git_dir, entries, "");
}

/// Recursively build tree objects for a set of index entries that share
/// a common prefix. `prefix` is the path prefix that has already been
/// consumed (empty string for root).
fn buildTreeRecursive(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    entries: []const index_mod.IndexEntry,
    prefix: []const u8,
) !types.ObjectId {
    // We need to group entries by their immediate child name under `prefix`.
    // - If an entry's remaining path (after prefix) has no '/', it's a blob.
    // - If it has a '/', the part before the first '/' is a subtree name.

    var tree_entries = std.array_list.Managed(TreeBuildEntry).init(allocator);
    defer tree_entries.deinit();

    // We also need to collect groups of entries that belong to the same subtree.
    // Since index entries are sorted, entries in the same subtree are contiguous.
    var i: usize = 0;
    while (i < entries.len) {
        const entry = &entries[i];
        const remaining = getRemaining(entry.name, prefix);
        if (remaining.len == 0) {
            // Should not happen if data is well-formed; skip.
            i += 1;
            continue;
        }

        if (std.mem.indexOfScalar(u8, remaining, '/')) |slash_pos| {
            // This entry is inside a subdirectory.
            const dir_name = remaining[0..slash_pos];

            // Collect all entries that share this directory prefix.
            const sub_prefix = buildSubPrefix(allocator, prefix, dir_name) catch {
                i += 1;
                continue;
            };
            defer allocator.free(sub_prefix);

            // Find the range of entries sharing this subdirectory.
            var j = i + 1;
            while (j < entries.len) {
                const next_remaining = getRemaining(entries[j].name, prefix);
                if (next_remaining.len == 0) break;
                if (!std.mem.startsWith(u8, next_remaining, dir_name)) break;
                if (next_remaining.len <= dir_name.len) break;
                if (next_remaining[dir_name.len] != '/') break;
                j += 1;
            }

            // Recursively build the subtree from entries[i..j].
            const subtree_oid = try buildTreeRecursive(allocator, git_dir, entries[i..j], sub_prefix);

            try tree_entries.append(.{
                .mode = "40000",
                .name = dir_name,
                .oid = subtree_oid,
            });

            i = j;
        } else {
            // This entry is a file directly in this tree level.
            const mode_str = modeToString(entry.mode);
            try tree_entries.append(.{
                .mode = mode_str,
                .name = remaining,
                .oid = entry.oid,
            });
            i += 1;
        }
    }

    return writeTreeObject(allocator, git_dir, tree_entries.items);
}

/// Get the part of the entry path that remains after stripping the prefix.
fn getRemaining(full_path: []const u8, prefix: []const u8) []const u8 {
    if (prefix.len == 0) return full_path;
    if (full_path.len <= prefix.len) return "";
    if (!std.mem.startsWith(u8, full_path, prefix)) return "";
    // prefix always ends with '/' due to how we build it
    return full_path[prefix.len..];
}

/// Build a sub-prefix string: "prefix" + "dir_name" + "/"
fn buildSubPrefix(allocator: std.mem.Allocator, prefix: []const u8, dir_name: []const u8) ![]u8 {
    const len = prefix.len + dir_name.len + 1;
    const buf = try allocator.alloc(u8, len);
    var pos: usize = 0;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos..][0..dir_name.len], dir_name);
    pos += dir_name.len;
    buf[pos] = '/';
    return buf;
}

/// Convert a numeric mode (from index entry) to the string used in tree objects.
fn modeToString(mode: u32) []const u8 {
    // Common modes:
    // 0o100644 = 33188 -> regular file
    // 0o100755 = 33261 -> executable
    // 0o120000 = 40960 -> symlink
    // 0o040000 = 16384 -> directory (shouldn't appear for blobs, but handle it)
    // 0o160000 = 57344 -> gitlink (submodule)

    if (mode == 0o100644 or mode == 0o100664) return "100644";
    if (mode == 0o100755) return "100755";
    if (mode == 0o120000) return "120000";
    if (mode == 0o040000) return "40000";
    if (mode == 0o160000) return "160000";

    // Default: regular file
    return "100644";
}

/// Serialize tree entries and write the tree object to the object database.
/// Tree entries must already be sorted (index entries are sorted, so they
/// should arrive in order). Git sorts tree entries with a special rule:
/// directories are sorted as if they have a trailing '/'.
fn writeTreeObject(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    entries: []const TreeBuildEntry,
) !types.ObjectId {
    // Sort entries by git tree ordering.
    // We need a mutable copy for sorting.
    const sorted = try allocator.alloc(TreeBuildEntry, entries.len);
    defer allocator.free(sorted);
    @memcpy(sorted, entries);

    std.mem.sort(TreeBuildEntry, sorted, {}, struct {
        fn lessThan(_: void, a: TreeBuildEntry, b: TreeBuildEntry) bool {
            return treeEntryOrder(a, b) == .lt;
        }
    }.lessThan);

    // Calculate the total size of the tree content.
    var total_size: usize = 0;
    for (sorted) |*entry| {
        // "MODE NAME\0" + 20 bytes OID
        total_size += entry.mode.len + 1 + entry.name.len + 1 + types.OID_RAW_LEN;
    }

    // Build the tree content.
    const tree_data = try allocator.alloc(u8, total_size);
    defer allocator.free(tree_data);
    var pos: usize = 0;

    for (sorted) |*entry| {
        // MODE
        @memcpy(tree_data[pos..][0..entry.mode.len], entry.mode);
        pos += entry.mode.len;
        // space
        tree_data[pos] = ' ';
        pos += 1;
        // NAME
        @memcpy(tree_data[pos..][0..entry.name.len], entry.name);
        pos += entry.name.len;
        // NUL
        tree_data[pos] = 0;
        pos += 1;
        // 20-byte raw OID
        @memcpy(tree_data[pos..][0..types.OID_RAW_LEN], &entry.oid.bytes);
        pos += types.OID_RAW_LEN;
    }

    // Write as a loose object with type "tree".
    const oid = loose.writeLooseObject(allocator, git_dir, .tree, tree_data) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Object already exists — compute the OID and return it.
            return computeTreeOid(tree_data);
        },
        else => return err,
    };
    return oid;
}

/// Compute the OID for a tree object without writing it.
fn computeTreeOid(data: []const u8) types.ObjectId {
    const hash = @import("hash.zig");
    var header_buf: [64]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    hwriter.writeAll("tree ") catch unreachable;
    hwriter.print("{d}", .{data.len}) catch unreachable;
    hwriter.writeByte(0) catch unreachable;
    const header = header_buf[0..hstream.pos];

    var hasher = hash.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    return types.ObjectId{ .bytes = hasher.finalResult() };
}

/// Git tree entry sort order. Directories sort as if they have a trailing '/'.
fn treeEntryOrder(a: TreeBuildEntry, b: TreeBuildEntry) std.math.Order {
    const a_is_tree = std.mem.eql(u8, a.mode, "40000");
    const b_is_tree = std.mem.eql(u8, b.mode, "40000");
    return treeNameOrder(a.name, a_is_tree, b.name, b_is_tree);
}

/// Compare two tree entry names using git's sorting rules.
/// Directories are compared as if they have a trailing '/'.
fn treeNameOrder(a_name: []const u8, a_is_tree: bool, b_name: []const u8, b_is_tree: bool) std.math.Order {
    const min_len = @min(a_name.len, b_name.len);
    for (a_name[0..min_len], b_name[0..min_len]) |ca, cb| {
        if (ca < cb) return .lt;
        if (ca > cb) return .gt;
    }
    // If names match up to min_len, compare the "virtual next character"
    const a_next: u8 = if (a_name.len > min_len) a_name[min_len] else if (a_is_tree) '/' else 0;
    const b_next: u8 = if (b_name.len > min_len) b_name[min_len] else if (b_is_tree) '/' else 0;
    if (a_next < b_next) return .lt;
    if (a_next > b_next) return .gt;
    // If still equal and lengths differ, continue comparing
    if (a_name.len == b_name.len) return .eq;
    // Recurse on the remaining portions is unnecessary for typical cases;
    // the virtual next char comparison handles it.
    if (a_name.len < b_name.len) return .lt;
    return .gt;
}

/// Parse an existing tree object's data into a list of TreeBuildEntry items.
/// The returned entries reference the data slice — caller must ensure data
/// lives long enough.
pub fn parseTreeEntries(allocator: std.mem.Allocator, data: []const u8) ![]TreeBuildEntry {
    var entries = std.array_list.Managed(TreeBuildEntry).init(allocator);
    errdefer entries.deinit();

    var pos: usize = 0;
    while (pos < data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse return error.InvalidTree;
        const mode = data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, data, space_pos + 1, 0) orelse return error.InvalidTree;
        const name = data[space_pos + 1 .. null_pos];
        if (null_pos + 1 + types.OID_RAW_LEN > data.len) return error.InvalidTree;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, data[null_pos + 1 ..][0..types.OID_RAW_LEN]);
        pos = null_pos + 1 + types.OID_RAW_LEN;

        try entries.append(.{
            .mode = mode,
            .name = name,
            .oid = oid,
        });
    }

    return entries.toOwnedSlice();
}

/// Convenience: Build a tree from an Index, returning the root tree OID as hex.
pub fn buildTreeHex(allocator: std.mem.Allocator, git_dir: []const u8, idx: *const index_mod.Index) ![types.OID_HEX_LEN]u8 {
    const oid = try buildTree(allocator, git_dir, idx);
    return oid.toHex();
}

test "modeToString" {
    try std.testing.expectEqualStrings("100644", modeToString(0o100644));
    try std.testing.expectEqualStrings("100755", modeToString(0o100755));
    try std.testing.expectEqualStrings("120000", modeToString(0o120000));
    try std.testing.expectEqualStrings("40000", modeToString(0o040000));
    try std.testing.expectEqualStrings("160000", modeToString(0o160000));
}

test "getRemaining" {
    try std.testing.expectEqualStrings("main.zig", getRemaining("src/main.zig", "src/"));
    try std.testing.expectEqualStrings("src/main.zig", getRemaining("src/main.zig", ""));
    try std.testing.expectEqualStrings("file.zig", getRemaining("a/b/file.zig", "a/b/"));
}

test "treeNameOrder" {
    // file < dir-with-slash
    try std.testing.expect(treeNameOrder("abc", false, "abd", false) == .lt);
    try std.testing.expect(treeNameOrder("abc", false, "abc", false) == .eq);
    try std.testing.expect(treeNameOrder("abd", false, "abc", false) == .gt);
}
