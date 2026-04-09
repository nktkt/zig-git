const std = @import("std");
const types = @import("types.zig");
const hash_mod = @import("hash.zig");

/// Git index file extensions.
///
/// The index file can contain optional extensions after the index entries.
/// Each extension has a 4-byte signature, a 32-bit size, and then the data.
/// Extensions with uppercase first byte are required (reader must understand them).
/// Extensions with lowercase first byte are optional (can be ignored).
///
/// Known extensions:
///   TREE — cached tree structure for fast write-tree
///   REUC — resolve undo (pre-merge entries)
///   EOIE — end of index entry (offset for parallel loading)
///   IEOT — index entry offset table (for V4 prefix-compressed entries)
///   link — split index support (LINK extension)

/// Extension signature constants.
pub const EXT_TREE: [4]u8 = .{ 'T', 'R', 'E', 'E' };
pub const EXT_REUC: [4]u8 = .{ 'R', 'E', 'U', 'C' };
pub const EXT_EOIE: [4]u8 = .{ 'E', 'O', 'I', 'E' };
pub const EXT_IEOT: [4]u8 = .{ 'I', 'E', 'O', 'T' };
pub const EXT_LINK: [4]u8 = .{ 'l', 'i', 'n', 'k' };

/// Determine if an extension is required (uppercase first byte).
pub fn isRequiredExtension(sig: *const [4]u8) bool {
    return sig[0] >= 'A' and sig[0] <= 'Z';
}

// --- TREE Extension ---

/// A node in the cached tree structure.
pub const CacheTreeNode = struct {
    /// Path component name (empty string for root).
    name: []const u8,
    /// Whether the name is heap-allocated.
    name_owned: bool,
    /// Number of entries in this directory (including subdirectories).
    /// -1 means invalidated.
    entry_count: i32,
    /// Number of subtrees.
    subtree_count: u32,
    /// Object ID of this tree (valid only when entry_count >= 0).
    oid: types.ObjectId,
    /// Child subtrees.
    children: std.array_list.Managed(CacheTreeNode),

    pub fn init(allocator: std.mem.Allocator) CacheTreeNode {
        return .{
            .name = "",
            .name_owned = false,
            .entry_count = -1,
            .subtree_count = 0,
            .oid = types.ObjectId.ZERO,
            .children = std.array_list.Managed(CacheTreeNode).init(allocator),
        };
    }

    pub fn deinit(self: *CacheTreeNode) void {
        for (self.children.items) |*child| {
            child.deinit();
        }
        self.children.deinit();
        if (self.name_owned) {
            self.children.allocator.free(self.name);
        }
    }

    /// Check if this tree node is valid (not invalidated).
    pub fn isValid(self: *const CacheTreeNode) bool {
        return self.entry_count >= 0;
    }

    /// Invalidate this node and all its children.
    pub fn invalidate(self: *CacheTreeNode) void {
        self.entry_count = -1;
        for (self.children.items) |*child| {
            child.invalidate();
        }
    }

    /// Invalidate a specific path in the tree.
    /// Returns true if the path was found and invalidated.
    pub fn invalidatePath(self: *CacheTreeNode, path: []const u8) bool {
        self.entry_count = -1;

        if (std.mem.indexOfScalar(u8, path, '/')) |slash_pos| {
            const dir_name = path[0..slash_pos];
            const rest = path[slash_pos + 1 ..];
            for (self.children.items) |*child| {
                if (std.mem.eql(u8, child.name, dir_name)) {
                    return child.invalidatePath(rest);
                }
            }
        }
        return true;
    }

    /// Find a child by name.
    pub fn findChild(self: *const CacheTreeNode, name: []const u8) ?*CacheTreeNode {
        for (self.children.items) |*child| {
            if (std.mem.eql(u8, child.name, name)) {
                return child;
            }
        }
        return null;
    }

    /// Count total number of nodes (including self).
    pub fn countNodes(self: *const CacheTreeNode) usize {
        var count: usize = 1;
        for (self.children.items) |*child| {
            count += child.countNodes();
        }
        return count;
    }
};

/// Read a TREE extension from raw extension data.
pub fn readTreeExtension(allocator: std.mem.Allocator, data: []const u8) !CacheTreeNode {
    var root = CacheTreeNode.init(allocator);
    errdefer root.deinit();

    var pos: usize = 0;
    try readTreeNodeRecursive(allocator, data, &pos, &root);

    return root;
}

fn readTreeNodeRecursive(
    allocator: std.mem.Allocator,
    data: []const u8,
    pos: *usize,
    node: *CacheTreeNode,
) !void {
    if (pos.* >= data.len) return;

    // Read path component (NUL-terminated)
    const name_start = pos.*;
    while (pos.* < data.len and data[pos.*] != 0) {
        pos.* += 1;
    }
    if (pos.* >= data.len) return error.InvalidTreeExtension;
    const name_end = pos.*;
    pos.* += 1; // skip NUL

    if (name_end > name_start) {
        const name = try allocator.alloc(u8, name_end - name_start);
        @memcpy(name, data[name_start..name_end]);
        node.name = name;
        node.name_owned = true;
    }

    // Read entry count and subtree count as ASCII separated by space, terminated by newline
    // Format: "<entry_count> <subtree_count>\n"
    const entry_count_start = pos.*;
    while (pos.* < data.len and data[pos.*] != ' ') {
        pos.* += 1;
    }
    if (pos.* >= data.len) return error.InvalidTreeExtension;
    const entry_count_str = data[entry_count_start..pos.*];
    pos.* += 1; // skip space

    const subtree_count_start = pos.*;
    while (pos.* < data.len and data[pos.*] != '\n') {
        pos.* += 1;
    }
    if (pos.* >= data.len) return error.InvalidTreeExtension;
    const subtree_count_str = data[subtree_count_start..pos.*];
    pos.* += 1; // skip newline

    node.entry_count = parseI32(entry_count_str) catch -1;
    node.subtree_count = @intCast(parseU32(subtree_count_str) catch 0);

    // If entry_count >= 0, read the OID (raw bytes)
    if (node.entry_count >= 0) {
        if (pos.* + types.OID_RAW_LEN > data.len) return error.InvalidTreeExtension;
        @memcpy(&node.oid.bytes, data[pos.*..][0..types.OID_RAW_LEN]);
        pos.* += types.OID_RAW_LEN;
    }

    // Read children
    var i: u32 = 0;
    while (i < node.subtree_count) : (i += 1) {
        var child = CacheTreeNode.init(allocator);
        errdefer child.deinit();
        try readTreeNodeRecursive(allocator, data, pos, &child);
        try node.children.append(child);
    }
}

/// Write a TREE extension to a buffer.
pub fn writeTreeExtension(allocator: std.mem.Allocator, root: *const CacheTreeNode) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try writeTreeNodeRecursive(&buf, root);

    return buf.toOwnedSlice();
}

fn writeTreeNodeRecursive(buf: *std.array_list.Managed(u8), node: *const CacheTreeNode) !void {
    // Write name + NUL
    try buf.appendSlice(node.name);
    try buf.append(0);

    // Write entry_count and subtree_count as ASCII
    var num_buf: [32]u8 = undefined;
    const entry_str = formatI32(&num_buf, node.entry_count);
    try buf.appendSlice(entry_str);
    try buf.append(' ');

    var num_buf2: [32]u8 = undefined;
    const subtree_str = formatU32(&num_buf2, @intCast(node.children.items.len));
    try buf.appendSlice(subtree_str);
    try buf.append('\n');

    // Write OID if valid
    if (node.entry_count >= 0) {
        try buf.appendSlice(&node.oid.bytes);
    }

    // Write children
    for (node.children.items) |*child| {
        try writeTreeNodeRecursive(buf, child);
    }
}

// --- REUC Extension (Resolve Undo) ---

/// A resolve-undo entry stores pre-merge state for conflict resolution.
pub const ResolveUndoEntry = struct {
    /// Path of the conflicted file.
    path: []const u8,
    /// Whether the path is heap-allocated.
    path_owned: bool,
    /// Modes for the 3 stages (ancestor, ours, theirs). 0 means absent.
    modes: [3]u32,
    /// Object IDs for the 3 stages. Only valid when corresponding mode != 0.
    oids: [3]types.ObjectId,
};

/// Read a REUC extension from raw extension data.
pub fn readReucExtension(allocator: std.mem.Allocator, data: []const u8) !std.array_list.Managed(ResolveUndoEntry) {
    var entries = std.array_list.Managed(ResolveUndoEntry).init(allocator);
    errdefer {
        for (entries.items) |*e| {
            if (e.path_owned) allocator.free(e.path);
        }
        entries.deinit();
    }

    var pos: usize = 0;
    while (pos < data.len) {
        var entry: ResolveUndoEntry = undefined;

        // Read path (NUL-terminated)
        const path_start = pos;
        while (pos < data.len and data[pos] != 0) {
            pos += 1;
        }
        if (pos >= data.len) break;
        const path_len = pos - path_start;
        const path = try allocator.alloc(u8, path_len);
        @memcpy(path, data[path_start..pos]);
        entry.path = path;
        entry.path_owned = true;
        pos += 1; // skip NUL

        // Read 3 modes as octal ASCII strings, each NUL-terminated
        for (0..3) |stage| {
            const mode_start = pos;
            while (pos < data.len and data[pos] != 0) {
                pos += 1;
            }
            if (pos > data.len) {
                allocator.free(path);
                return error.InvalidReucExtension;
            }
            entry.modes[stage] = parseOctal(data[mode_start..pos]) catch 0;
            if (pos < data.len) pos += 1; // skip NUL
        }

        // Read OIDs for stages with non-zero modes
        for (0..3) |stage| {
            if (entry.modes[stage] != 0) {
                if (pos + types.OID_RAW_LEN > data.len) {
                    allocator.free(path);
                    return error.InvalidReucExtension;
                }
                @memcpy(&entry.oids[stage].bytes, data[pos..][0..types.OID_RAW_LEN]);
                pos += types.OID_RAW_LEN;
            } else {
                entry.oids[stage] = types.ObjectId.ZERO;
            }
        }

        try entries.append(entry);
    }

    return entries;
}

/// Write a REUC extension to a buffer.
pub fn writeReucExtension(allocator: std.mem.Allocator, entries: []const ResolveUndoEntry) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    for (entries) |*entry| {
        // Write path + NUL
        try buf.appendSlice(entry.path);
        try buf.append(0);

        // Write 3 modes as octal + NUL
        for (0..3) |stage| {
            var mode_buf: [16]u8 = undefined;
            const mode_str = formatOctal(&mode_buf, entry.modes[stage]);
            try buf.appendSlice(mode_str);
            try buf.append(0);
        }

        // Write OIDs for non-zero modes
        for (0..3) |stage| {
            if (entry.modes[stage] != 0) {
                try buf.appendSlice(&entry.oids[stage].bytes);
            }
        }
    }

    return buf.toOwnedSlice();
}

// --- EOIE Extension (End Of Index Entry) ---

/// EOIE extension data.
pub const EoieData = struct {
    /// Offset to the end of the index entries (from start of file).
    offset: u32,
    /// SHA-1 hash of the index entries section.
    hash: [types.OID_RAW_LEN]u8,
};

/// Read an EOIE extension.
pub fn readEoieExtension(data: []const u8) !EoieData {
    if (data.len < 4 + types.OID_RAW_LEN) return error.InvalidEoieExtension;

    return .{
        .offset = readU32(data[0..4]),
        .hash = data[4..][0..types.OID_RAW_LEN].*,
    };
}

/// Write an EOIE extension.
pub fn writeEoieExtension(buf: []u8, eoie: *const EoieData) !usize {
    if (buf.len < 4 + types.OID_RAW_LEN) return error.BufferTooSmall;
    writeU32(buf[0..4], eoie.offset);
    @memcpy(buf[4..][0..types.OID_RAW_LEN], &eoie.hash);
    return 4 + types.OID_RAW_LEN;
}

// --- IEOT Extension (Index Entry Offset Table) ---

/// IEOT entry: offset to a block of index entries.
pub const IeotEntry = struct {
    offset: u32,
};

/// Read an IEOT extension.
pub fn readIeotExtension(allocator: std.mem.Allocator, data: []const u8) !std.array_list.Managed(IeotEntry) {
    var entries = std.array_list.Managed(IeotEntry).init(allocator);
    errdefer entries.deinit();

    if (data.len < 4) return error.InvalidIeotExtension;

    const version = readU32(data[0..4]);
    if (version != 1) return error.UnsupportedIeotVersion;

    var pos: usize = 4;
    while (pos + 4 <= data.len) {
        const offset = readU32(data[pos..][0..4]);
        try entries.append(.{ .offset = offset });
        pos += 4;
    }

    return entries;
}

/// Write an IEOT extension.
pub fn writeIeotExtension(allocator: std.mem.Allocator, entries: []const IeotEntry) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    // Version
    var ver_buf: [4]u8 = undefined;
    writeU32(&ver_buf, 1);
    try buf.appendSlice(&ver_buf);

    // Offsets
    for (entries) |*entry| {
        var off_buf: [4]u8 = undefined;
        writeU32(&off_buf, entry.offset);
        try buf.appendSlice(&off_buf);
    }

    return buf.toOwnedSlice();
}

// --- Split Index Support ---

/// LINK extension data for split index.
pub const SplitIndexLink = struct {
    /// SHA-1 of the shared index file.
    shared_index_hash: [types.OID_RAW_LEN]u8,
    /// Bitmap of entries to delete from shared index.
    delete_bitmap: std.array_list.Managed(u8),
    /// Bitmap of entries to replace in shared index.
    replace_bitmap: std.array_list.Managed(u8),

    pub fn init(allocator: std.mem.Allocator) SplitIndexLink {
        return .{
            .shared_index_hash = [_]u8{0} ** types.OID_RAW_LEN,
            .delete_bitmap = std.array_list.Managed(u8).init(allocator),
            .replace_bitmap = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *SplitIndexLink) void {
        self.delete_bitmap.deinit();
        self.replace_bitmap.deinit();
    }
};

/// Read a LINK extension for split index.
pub fn readLinkExtension(allocator: std.mem.Allocator, data: []const u8) !SplitIndexLink {
    var link = SplitIndexLink.init(allocator);
    errdefer link.deinit();

    if (data.len < types.OID_RAW_LEN) return error.InvalidLinkExtension;

    @memcpy(&link.shared_index_hash, data[0..types.OID_RAW_LEN]);

    var pos: usize = types.OID_RAW_LEN;

    // Read ewah bitmaps (simplified: read as raw bytes)
    // Delete bitmap
    if (pos + 4 <= data.len) {
        const bitmap_size = readU32(data[pos..][0..4]);
        pos += 4;
        if (pos + bitmap_size <= data.len) {
            try link.delete_bitmap.appendSlice(data[pos..][0..bitmap_size]);
            pos += bitmap_size;
        }
    }

    // Replace bitmap
    if (pos + 4 <= data.len) {
        const bitmap_size = readU32(data[pos..][0..4]);
        pos += 4;
        if (pos + bitmap_size <= data.len) {
            try link.replace_bitmap.appendSlice(data[pos..][0..bitmap_size]);
        }
    }

    return link;
}

/// Build the shared index file path.
pub fn sharedIndexPath(buf: []u8, git_dir: []const u8, hash: *const [types.OID_RAW_LEN]u8) ![]const u8 {
    var hex: [types.OID_RAW_LEN * 2]u8 = undefined;
    hash_mod.bytesToHex(hash, &hex);

    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll(git_dir);
    try writer.writeAll("/sharedindex.");
    try writer.writeAll(&hex);

    return buf[0..fbs.pos];
}

// --- Generic Extension Read/Write ---

/// Read a single extension header from data at position pos.
/// Returns the signature, size, and data slice; advances pos past it.
pub const ExtensionHeader = struct {
    signature: [4]u8,
    size: u32,
    data: []const u8,
    total_size: usize,
};

pub fn readExtensionHeader(data: []const u8, pos: usize) !ExtensionHeader {
    if (pos + 8 > data.len) return error.InvalidExtension;

    var sig: [4]u8 = undefined;
    @memcpy(&sig, data[pos..][0..4]);
    const size = readU32(data[pos + 4 ..][0..4]);

    if (pos + 8 + size > data.len) return error.InvalidExtension;

    return .{
        .signature = sig,
        .size = size,
        .data = data[pos + 8 ..][0..size],
        .total_size = 8 + size,
    };
}

/// Write an extension header (signature + size).
pub fn writeExtensionHeader(buf: []u8, sig: *const [4]u8, size: u32) !usize {
    if (buf.len < 8) return error.BufferTooSmall;
    @memcpy(buf[0..4], sig);
    writeU32(buf[4..8], size);
    return 8;
}

/// Read all extensions from index data starting at the given position.
/// Stops at the index checksum (last 20 bytes).
pub fn readAllExtensions(allocator: std.mem.Allocator, data: []const u8, start_pos: usize) !ExtensionSet {
    var set = ExtensionSet.init(allocator);
    errdefer set.deinit();

    const end = if (data.len >= types.OID_RAW_LEN) data.len - types.OID_RAW_LEN else data.len;
    var pos = start_pos;

    while (pos + 8 <= end) {
        const ext = readExtensionHeader(data, pos) catch break;
        try set.extensions.append(.{
            .signature = ext.signature,
            .data_offset = @intCast(pos + 8),
            .data_size = ext.size,
        });
        pos += ext.total_size;
    }

    return set;
}

/// Set of parsed extension locations.
pub const ExtensionSet = struct {
    allocator: std.mem.Allocator,
    extensions: std.array_list.Managed(ExtensionInfo),

    pub const ExtensionInfo = struct {
        signature: [4]u8,
        data_offset: u32,
        data_size: u32,
    };

    pub fn init(allocator: std.mem.Allocator) ExtensionSet {
        return .{
            .allocator = allocator,
            .extensions = std.array_list.Managed(ExtensionInfo).init(allocator),
        };
    }

    pub fn deinit(self: *ExtensionSet) void {
        self.extensions.deinit();
    }

    /// Find an extension by signature.
    pub fn find(self: *const ExtensionSet, sig: *const [4]u8) ?ExtensionInfo {
        for (self.extensions.items) |*ext| {
            if (std.mem.eql(u8, &ext.signature, sig)) {
                return ext.*;
            }
        }
        return null;
    }

    /// Check if a specific extension is present.
    pub fn has(self: *const ExtensionSet, sig: *const [4]u8) bool {
        return self.find(sig) != null;
    }
};

// --- Internal helpers ---

fn readU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

fn writeU32(buf: *[4]u8, val: u32) void {
    std.mem.writeInt(u32, buf, val, .big);
}

fn parseI32(s: []const u8) !i32 {
    if (s.len == 0) return error.InvalidNumber;
    var negative = false;
    var start: usize = 0;
    if (s[0] == '-') {
        negative = true;
        start = 1;
    }
    if (start >= s.len) return error.InvalidNumber;
    var result: i32 = 0;
    for (s[start..]) |c| {
        if (c < '0' or c > '9') return error.InvalidNumber;
        result = result * 10 + @as(i32, @intCast(c - '0'));
    }
    return if (negative) -result else result;
}

fn parseU32(s: []const u8) !u32 {
    if (s.len == 0) return error.InvalidNumber;
    var result: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.InvalidNumber;
        result = result * 10 + @as(u32, c - '0');
    }
    return result;
}

fn parseOctal(s: []const u8) !u32 {
    if (s.len == 0) return error.InvalidNumber;
    var result: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '7') return error.InvalidNumber;
        result = result * 8 + @as(u32, c - '0');
    }
    return result;
}

fn formatI32(buf: []u8, val: i32) []const u8 {
    if (val < 0) {
        buf[0] = '-';
        const uval: u32 = @intCast(-val);
        const rest = formatU32(buf[1..], uval);
        return buf[0 .. 1 + rest.len];
    }
    return formatU32(buf, @intCast(val));
}

fn formatU32(buf: []u8, val: u32) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = val;
    var i: usize = 0;
    while (v > 0) : (i += 1) {
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    // Reverse
    var lo: usize = 0;
    var hi: usize = i - 1;
    while (lo < hi) {
        const tmp = buf[lo];
        buf[lo] = buf[hi];
        buf[hi] = tmp;
        lo += 1;
        hi -= 1;
    }
    return buf[0..i];
}

fn formatOctal(buf: []u8, val: u32) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = val;
    var i: usize = 0;
    while (v > 0) : (i += 1) {
        buf[i] = @intCast('0' + (v % 8));
        v /= 8;
    }
    // Reverse
    var lo: usize = 0;
    var hi: usize = i - 1;
    while (lo < hi) {
        const tmp = buf[lo];
        buf[lo] = buf[hi];
        buf[hi] = tmp;
        lo += 1;
        hi -= 1;
    }
    return buf[0..i];
}

// --- Tests ---

test "isRequiredExtension" {
    try std.testing.expect(isRequiredExtension(&EXT_TREE));
    try std.testing.expect(isRequiredExtension(&EXT_REUC));
    try std.testing.expect(isRequiredExtension(&EXT_EOIE));
    try std.testing.expect(!isRequiredExtension(&EXT_LINK));
}

test "CacheTreeNode init and deinit" {
    var node = CacheTreeNode.init(std.testing.allocator);
    defer node.deinit();

    try std.testing.expect(!node.isValid());
    try std.testing.expectEqual(@as(i32, -1), node.entry_count);
}

test "CacheTreeNode invalidate" {
    var root = CacheTreeNode.init(std.testing.allocator);
    defer root.deinit();

    root.entry_count = 5;
    try std.testing.expect(root.isValid());
    root.invalidate();
    try std.testing.expect(!root.isValid());
}

test "CacheTreeNode countNodes" {
    var root = CacheTreeNode.init(std.testing.allocator);
    defer root.deinit();

    var child1 = CacheTreeNode.init(std.testing.allocator);
    child1.name = "src";
    try root.children.append(child1);

    try std.testing.expectEqual(@as(usize, 2), root.countNodes());
}

test "parseI32" {
    try std.testing.expectEqual(@as(i32, 42), try parseI32("42"));
    try std.testing.expectEqual(@as(i32, -1), try parseI32("-1"));
    try std.testing.expectEqual(@as(i32, 0), try parseI32("0"));
}

test "parseU32" {
    try std.testing.expectEqual(@as(u32, 42), try parseU32("42"));
    try std.testing.expectEqual(@as(u32, 0), try parseU32("0"));
}

test "parseOctal" {
    try std.testing.expectEqual(@as(u32, 8), try parseOctal("10"));
    try std.testing.expectEqual(@as(u32, 0o100644), try parseOctal("100644"));
}

test "formatI32" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("42", formatI32(&buf, 42));
    try std.testing.expectEqualStrings("-1", formatI32(&buf, -1));
    try std.testing.expectEqualStrings("0", formatI32(&buf, 0));
}

test "formatU32" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("42", formatU32(&buf, 42));
    try std.testing.expectEqualStrings("0", formatU32(&buf, 0));
    try std.testing.expectEqualStrings("12345", formatU32(&buf, 12345));
}

test "formatOctal" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("10", formatOctal(&buf, 8));
    try std.testing.expectEqualStrings("100644", formatOctal(&buf, 0o100644));
}

test "readEoieExtension" {
    var data: [24]u8 = undefined;
    writeU32(data[0..4], 1000);
    @memset(data[4..24], 0xAB);
    const eoie = try readEoieExtension(&data);
    try std.testing.expectEqual(@as(u32, 1000), eoie.offset);
    try std.testing.expectEqual(@as(u8, 0xAB), eoie.hash[0]);
}

test "writeEoieExtension" {
    const eoie = EoieData{
        .offset = 500,
        .hash = [_]u8{0xCD} ** types.OID_RAW_LEN,
    };
    var buf: [64]u8 = undefined;
    const n = try writeEoieExtension(&buf, &eoie);
    try std.testing.expectEqual(@as(usize, 24), n);

    // Read it back
    const parsed = try readEoieExtension(buf[0..n]);
    try std.testing.expectEqual(@as(u32, 500), parsed.offset);
    try std.testing.expectEqual(@as(u8, 0xCD), parsed.hash[0]);
}

test "ExtensionSet" {
    var set = ExtensionSet.init(std.testing.allocator);
    defer set.deinit();

    try set.extensions.append(.{
        .signature = EXT_TREE,
        .data_offset = 100,
        .data_size = 50,
    });

    try std.testing.expect(set.has(&EXT_TREE));
    try std.testing.expect(!set.has(&EXT_REUC));

    const found = set.find(&EXT_TREE).?;
    try std.testing.expectEqual(@as(u32, 100), found.data_offset);
}

test "readExtensionHeader" {
    var data: [16]u8 = undefined;
    @memcpy(data[0..4], &EXT_TREE);
    writeU32(data[4..8], 4);
    @memset(data[8..12], 0xFF);

    const ext = try readExtensionHeader(&data, 0);
    try std.testing.expect(std.mem.eql(u8, &ext.signature, &EXT_TREE));
    try std.testing.expectEqual(@as(u32, 4), ext.size);
    try std.testing.expectEqual(@as(usize, 12), ext.total_size);
}

test "sharedIndexPath" {
    var buf: [512]u8 = undefined;
    const hash = [_]u8{0xAB} ** types.OID_RAW_LEN;
    const path = try sharedIndexPath(&buf, "/repo/.git", &hash);
    try std.testing.expect(std.mem.startsWith(u8, path, "/repo/.git/sharedindex."));
}

test "IeotEntry read/write roundtrip" {
    const entries = [_]IeotEntry{
        .{ .offset = 100 },
        .{ .offset = 200 },
        .{ .offset = 300 },
    };

    const written = try writeIeotExtension(std.testing.allocator, &entries);
    defer std.testing.allocator.free(written);

    var parsed = try readIeotExtension(std.testing.allocator, written);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 3), parsed.items.len);
    try std.testing.expectEqual(@as(u32, 100), parsed.items[0].offset);
    try std.testing.expectEqual(@as(u32, 200), parsed.items[1].offset);
    try std.testing.expectEqual(@as(u32, 300), parsed.items[2].offset);
}
