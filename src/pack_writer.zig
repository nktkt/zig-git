const std = @import("std");
const types = @import("types.zig");
const hash_mod = @import("hash.zig");
const compress = @import("compress.zig");

/// Pack file format version.
const PACK_VERSION: u32 = 2;
const PACK_MAGIC = "PACK";

/// Entry stored in the pack before writing.
const PackEntry = struct {
    obj_type: types.ObjectType,
    data: []const u8,
    oid: types.ObjectId,
    offset: u64,
    crc32: u32,
};

/// Writes a new pack file (.pack) and its index (.idx).
pub const PackWriter = struct {
    allocator: std.mem.Allocator,
    output_path: []const u8,
    entries: std.array_list.Managed(PackEntry),
    object_data: std.array_list.Managed([]u8),

    /// Initialize a new PackWriter.
    /// output_path is the base path without extension (e.g., "/repo/.git/objects/pack/pack-<hash>").
    pub fn init(allocator: std.mem.Allocator, output_path: []const u8) PackWriter {
        return .{
            .allocator = allocator,
            .output_path = output_path,
            .entries = std.array_list.Managed(PackEntry).init(allocator),
            .object_data = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *PackWriter) void {
        for (self.object_data.items) |data| {
            self.allocator.free(data);
        }
        self.object_data.deinit();
        self.entries.deinit();
    }

    /// Add an object to the pack.
    pub fn addObject(self: *PackWriter, obj_type: types.ObjectType, data: []const u8) !types.ObjectId {
        // Compute the OID
        const oid = computeObjectId(obj_type, data);

        // Check for duplicates
        for (self.entries.items) |*entry| {
            if (entry.oid.eql(&oid)) return oid;
        }

        // Compress the data
        const compressed = try compress.zlibDeflate(self.allocator, data);
        try self.object_data.append(compressed);

        try self.entries.append(.{
            .obj_type = obj_type,
            .data = compressed,
            .oid = oid,
            .offset = 0, // Will be set during finish()
            .crc32 = 0, // Will be set during finish()
        });

        return oid;
    }

    /// Add an object with a known OID and already-raw data.
    pub fn addObjectWithOid(self: *PackWriter, obj_type: types.ObjectType, data: []const u8, oid: types.ObjectId) !void {
        // Check for duplicates
        for (self.entries.items) |*entry| {
            if (entry.oid.eql(&oid)) return;
        }

        // Compress the data
        const compressed = try compress.zlibDeflate(self.allocator, data);
        try self.object_data.append(compressed);

        try self.entries.append(.{
            .obj_type = obj_type,
            .data = compressed,
            .oid = oid,
            .offset = 0,
            .crc32 = 0,
        });
    }

    /// Write the pack file and index, returning the pack hash.
    /// Creates <output_path>.pack and <output_path>.idx.
    pub fn finish(self: *PackWriter) !types.ObjectId {
        if (self.entries.items.len == 0) return types.ObjectId.ZERO;

        const num_objects: u32 = @intCast(self.entries.items.len);

        // Build the pack file in memory
        var pack_data = std.array_list.Managed(u8).init(self.allocator);
        defer pack_data.deinit();

        // Write pack header
        try pack_data.appendSlice(PACK_MAGIC);
        try appendU32Big(&pack_data, PACK_VERSION);
        try appendU32Big(&pack_data, num_objects);

        // Write each object
        for (self.entries.items) |*entry| {
            entry.offset = @intCast(pack_data.items.len);

            // Write type+size header
            const type_int: u8 = @intFromEnum(entry.obj_type);

            // Compute uncompressed size from the stored compressed data
            // We need to decompress to get the original size, but we can also
            // recompute from the deflated data. For simplicity, inflate to get size.
            const uncompressed = compress.zlibInflate(self.allocator, entry.data) catch {
                // Fallback: use compressed size as an estimate
                try writePackObjHeader(&pack_data, type_int, entry.data.len);
                // Compute CRC32 over everything we wrote for this object
                const start = entry.offset;
                entry.crc32 = computeCrc32(pack_data.items[@intCast(start)..]);
                try pack_data.appendSlice(entry.data);
                continue;
            };
            const orig_size = uncompressed.len;
            self.allocator.free(uncompressed);

            const header_start = pack_data.items.len;
            try writePackObjHeader(&pack_data, type_int, orig_size);
            try pack_data.appendSlice(entry.data);
            const header_end = pack_data.items.len;

            entry.crc32 = computeCrc32(pack_data.items[header_start..header_end]);
        }

        // Compute SHA-1 of everything
        var hasher = hash_mod.Sha1.init(.{});
        hasher.update(pack_data.items);
        const pack_hash = hasher.finalResult();

        // Append the hash at the end of the pack
        try pack_data.appendSlice(&pack_hash);

        // Write the pack file
        var pack_path_buf: [4096]u8 = undefined;
        const pack_path = concatStr(&pack_path_buf, self.output_path, ".pack");
        const pack_file = try std.fs.createFileAbsolute(pack_path, .{});
        defer pack_file.close();
        try pack_file.writeAll(pack_data.items);

        // Write the index file
        try self.writeIndex(&pack_hash);

        return types.ObjectId{ .bytes = pack_hash };
    }

    fn writeIndex(self: *PackWriter, pack_hash: *const [20]u8) !void {
        const num_objects: u32 = @intCast(self.entries.items.len);

        // Sort entries by OID for the index
        const sorted_indices = try self.allocator.alloc(u32, num_objects);
        defer self.allocator.free(sorted_indices);
        for (sorted_indices, 0..) |*idx, i| {
            idx.* = @intCast(i);
        }

        const entries = self.entries.items;
        std.mem.sort(u32, sorted_indices, entries, struct {
            fn lessThan(ctx: []const PackEntry, a: u32, b: u32) bool {
                return std.mem.order(u8, &ctx[a].oid.bytes, &ctx[b].oid.bytes) == .lt;
            }
        }.lessThan);

        var idx_data = std.array_list.Managed(u8).init(self.allocator);
        defer idx_data.deinit();

        // Magic number and version
        try appendU32Big(&idx_data, 0xff744f63);
        try appendU32Big(&idx_data, 2);

        // Fanout table (256 entries)
        var fanout: [256]u32 = [_]u32{0} ** 256;
        for (sorted_indices) |idx| {
            const first_byte = entries[idx].oid.bytes[0];
            var b: usize = first_byte;
            while (b < 256) : (b += 1) {
                fanout[b] += 1;
            }
        }
        for (fanout) |count| {
            try appendU32Big(&idx_data, count);
        }

        // OID table
        for (sorted_indices) |idx| {
            try idx_data.appendSlice(&entries[idx].oid.bytes);
        }

        // CRC32 table
        for (sorted_indices) |idx| {
            try appendU32Big(&idx_data, entries[idx].crc32);
        }

        // Offset table (32-bit)
        for (sorted_indices) |idx| {
            const offset: u32 = @intCast(entries[idx].offset);
            try appendU32Big(&idx_data, offset);
        }

        // Pack checksum
        try idx_data.appendSlice(pack_hash);

        // Index checksum
        var hasher = hash_mod.Sha1.init(.{});
        hasher.update(idx_data.items);
        const idx_hash = hasher.finalResult();
        try idx_data.appendSlice(&idx_hash);

        // Write the index file
        var idx_path_buf: [4096]u8 = undefined;
        const idx_path = concatStr(&idx_path_buf, self.output_path, ".idx");
        const idx_file = try std.fs.createFileAbsolute(idx_path, .{});
        defer idx_file.close();
        try idx_file.writeAll(idx_data.items);
    }
};

/// Compute the object ID (SHA-1 of "type size\0data").
pub fn computeObjectId(obj_type: types.ObjectType, data: []const u8) types.ObjectId {
    var header_buf: [64]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    hwriter.writeAll(obj_type.toString()) catch return types.ObjectId.ZERO;
    hwriter.writeByte(' ') catch return types.ObjectId.ZERO;
    hwriter.print("{d}", .{data.len}) catch return types.ObjectId.ZERO;
    hwriter.writeByte(0) catch return types.ObjectId.ZERO;
    const header = header_buf[0..hstream.pos];

    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    return types.ObjectId{ .bytes = hasher.finalResult() };
}

/// Write a pack object header (type + variable-length size encoding).
fn writePackObjHeader(data: *std.array_list.Managed(u8), obj_type: u8, size: usize) !void {
    var s = size;
    var first_byte: u8 = @as(u8, (obj_type & 0x07)) << 4;
    first_byte |= @as(u8, @intCast(s & 0x0f));
    s >>= 4;
    if (s > 0) {
        first_byte |= 0x80;
    }
    try data.append(first_byte);
    while (s > 0) {
        var byte: u8 = @intCast(s & 0x7f);
        s >>= 7;
        if (s > 0) byte |= 0x80;
        try data.append(byte);
    }
}

fn appendU32Big(data: *std.array_list.Managed(u8), value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .big);
    try data.appendSlice(&buf);
}

fn computeCrc32(data: []const u8) u32 {
    return std.hash.crc.Crc32IsoHdlc.hash(data);
}

fn concatStr(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

test "computeObjectId empty blob" {
    const oid = computeObjectId(.blob, "");
    const hex = oid.toHex();
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &hex);
}

test "writePackObjHeader small" {
    var data = std.array_list.Managed(u8).init(std.testing.allocator);
    defer data.deinit();
    try writePackObjHeader(&data, 3, 5); // blob, size 5
    try std.testing.expectEqual(@as(usize, 1), data.items.len);
    try std.testing.expectEqual(@as(u8, 0x35), data.items[0]); // type=3<<4 | size=5
}

test "writePackObjHeader large" {
    var data = std.array_list.Managed(u8).init(std.testing.allocator);
    defer data.deinit();
    try writePackObjHeader(&data, 1, 256); // commit, size 256
    try std.testing.expect(data.items.len > 1);
    // First byte: type=1, low 4 bits of size = 0, continuation bit set
    try std.testing.expectEqual(@as(u8, (1 << 4) | 0x80), data.items[0]);
}
