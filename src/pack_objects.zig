const std = @import("std");
const types = @import("types.zig");
const hash_mod = @import("hash.zig");
const compress = @import("compress.zig");
const repository = @import("repository.zig");
const object_walk = @import("object_walk.zig");
const ref_mod = @import("ref.zig");

/// Default sliding window size for delta compression.
const DEFAULT_WINDOW_SIZE: usize = 10;
/// Default maximum delta chain depth.
const DEFAULT_DEPTH_LIMIT: usize = 50;
/// Minimum object size for delta compression attempt.
const MIN_DELTA_SIZE: usize = 64;
/// Maximum delta result size as ratio of target (don't bother if delta > 90% of target).
const MAX_DELTA_RATIO: usize = 90;

/// An object to be packed, with optional delta representation.
pub const PackObject = struct {
    oid: types.ObjectId,
    obj_type: types.ObjectType,
    data: []u8,
    size: usize,
    // Delta info (null if stored as full object)
    delta_base_oid: ?types.ObjectId,
    delta_data: ?[]u8,
    delta_depth: u32,
    // Offset in pack file (set during writing)
    offset: u64,
    crc32: u32,
    // For sorting
    name_hash: u32,
};

/// Configuration for pack generation.
pub const PackObjectsConfig = struct {
    window_size: usize = DEFAULT_WINDOW_SIZE,
    depth_limit: usize = DEFAULT_DEPTH_LIMIT,
    thin_pack: bool = false,
    reuse_deltas: bool = true,
    progress: bool = true,
};

/// Result of packing objects.
pub const PackResult = struct {
    pack_hash: types.ObjectId,
    pack_path: []u8,
    idx_path: []u8,
    num_objects: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PackResult) void {
        self.allocator.free(self.pack_path);
        self.allocator.free(self.idx_path);
    }
};

/// Statistics about the packing process.
pub const PackStats = struct {
    total_objects: u32 = 0,
    delta_objects: u32 = 0,
    full_objects: u32 = 0,
    total_size: u64 = 0,
    delta_size: u64 = 0,
};

/// Create a delta instruction stream from base to target.
/// Returns null if delta would be larger than target.
pub fn createDelta(allocator: std.mem.Allocator, base: []const u8, target: []const u8) !?[]u8 {
    if (base.len == 0 or target.len == 0) return null;

    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    // Write base size (variable-length encoding)
    try writeVarSize(&result, base.len);
    // Write target size
    try writeVarSize(&result, target.len);

    // Build a simple index of 4-byte chunks in the base
    const IndexEntry = struct { offset: u32, next: u32 };
    const HASH_SIZE = 4096;
    var hash_table: [HASH_SIZE]u32 = [_]u32{0xFFFFFFFF} ** HASH_SIZE;
    var index_entries = std.array_list.Managed(IndexEntry).init(allocator);
    defer index_entries.deinit();

    // Index the base in 4-byte windows
    if (base.len >= 4) {
        var bi: usize = 0;
        while (bi + 4 <= base.len) : (bi += 1) {
            const h = chunkHash(base[bi..][0..4]) % HASH_SIZE;
            try index_entries.append(.{
                .offset = @intCast(bi),
                .next = hash_table[h],
            });
            hash_table[h] = @intCast(index_entries.items.len - 1);
        }
    }

    // Process target, trying to find matches in base
    var ti: usize = 0;
    var add_start: usize = 0;

    while (ti < target.len) {
        var best_offset: usize = 0;
        var best_length: usize = 0;

        // Try to find a match in the base
        if (ti + 4 <= target.len) {
            const h = chunkHash(target[ti..][0..4]) % HASH_SIZE;
            var idx = hash_table[h];

            while (idx != 0xFFFFFFFF) {
                const entry = index_entries.items[idx];
                const boff = entry.offset;

                // Check how long the match extends
                var match_len: usize = 0;
                const max_match = @min(base.len - boff, target.len - ti);
                while (match_len < max_match and base[boff + match_len] == target[ti + match_len]) {
                    match_len += 1;
                }

                if (match_len >= 4 and match_len > best_length) {
                    best_offset = boff;
                    best_length = match_len;
                    // Cap at 0x10000 for copy instruction
                    if (best_length >= 0x10000) {
                        best_length = 0x10000;
                        break;
                    }
                }

                idx = entry.next;
            }
        }

        if (best_length >= 4) {
            // Flush any pending add data
            if (ti > add_start) {
                try emitAdd(&result, target[add_start..ti]);
            }
            // Emit copy instruction
            try emitCopy(&result, best_offset, best_length);
            ti += best_length;
            add_start = ti;
        } else {
            ti += 1;
            // Flush add data in chunks of 127 (max for add instruction)
            if (ti - add_start >= 127) {
                try emitAdd(&result, target[add_start..ti]);
                add_start = ti;
            }
        }
    }

    // Flush remaining add data
    if (ti > add_start) {
        try emitAdd(&result, target[add_start..ti]);
    }

    const delta = try result.toOwnedSlice();

    // Check if the delta is actually smaller than the target
    if (delta.len >= target.len * MAX_DELTA_RATIO / 100) {
        allocator.free(delta);
        return null;
    }

    return delta;
}

/// Pack all objects reachable from the given repository's refs.
pub fn packAllObjects(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    config: PackObjectsConfig,
    output_base_path: []const u8,
) !PackResult {
    // Collect all refs as tips
    var tips = std.array_list.Managed(types.ObjectId).init(allocator);
    defer tips.deinit();

    const ref_prefixes = [_][]const u8{ "refs/heads/", "refs/tags/", "refs/remotes/" };
    for (ref_prefixes) |prefix| {
        const refs = ref_mod.listRefs(allocator, repo.git_dir, prefix) catch continue;
        defer {
            for (refs) |e| allocator.free(@constCast(e.name));
            allocator.free(refs);
        }
        for (refs) |entry| {
            try tips.append(entry.oid);
        }
    }

    // Also include HEAD
    if (repo.resolveRef(allocator, "HEAD")) |head_oid| {
        try tips.append(head_oid);
    } else |_| {}

    // Walk all reachable objects
    const empty: []const types.ObjectId = &.{};
    const all_oids = try object_walk.walkObjects(allocator, repo, tips.items, empty);
    defer allocator.free(all_oids);

    // Read and collect all object data
    var objects = std.array_list.Managed(PackObject).init(allocator);
    defer {
        for (objects.items) |*obj| {
            allocator.free(obj.data);
            if (obj.delta_data) |dd| allocator.free(dd);
        }
        objects.deinit();
    }

    for (all_oids) |oid| {
        const obj = repo.readObject(allocator, &oid) catch continue;
        const data = obj.data;
        // Don't deinit obj since we're taking ownership of data
        const size = data.len;

        try objects.append(.{
            .oid = oid,
            .obj_type = obj.obj_type,
            .data = data,
            .size = size,
            .delta_base_oid = null,
            .delta_data = null,
            .delta_depth = 0,
            .offset = 0,
            .crc32 = 0,
            .name_hash = oidNameHash(&oid),
        });
    }

    if (objects.items.len == 0) {
        const pack_path = try allocator.alloc(u8, output_base_path.len + 5);
        @memcpy(pack_path[0..output_base_path.len], output_base_path);
        @memcpy(pack_path[output_base_path.len..], ".pack");
        const idx_path = try allocator.alloc(u8, output_base_path.len + 4);
        @memcpy(idx_path[0..output_base_path.len], output_base_path);
        @memcpy(idx_path[output_base_path.len..], ".idx");
        return PackResult{
            .pack_hash = types.ObjectId.ZERO,
            .pack_path = pack_path,
            .idx_path = idx_path,
            .num_objects = 0,
            .allocator = allocator,
        };
    }

    // Sort objects by type, then by size (for better delta compression)
    std.mem.sort(PackObject, objects.items, {}, struct {
        fn lessThan(_: void, a: PackObject, b: PackObject) bool {
            const a_type = @intFromEnum(a.obj_type);
            const b_type = @intFromEnum(b.obj_type);
            if (a_type != b_type) return a_type < b_type;
            // Within same type, sort by name hash then size
            if (a.name_hash != b.name_hash) return a.name_hash < b.name_hash;
            return a.size < b.size;
        }
    }.lessThan);

    // Delta compression pass
    try deltaCompress(allocator, objects.items, config);

    // Write the pack file
    return writePack(allocator, objects.items, output_base_path);
}

/// Perform delta compression on the sorted object list using a sliding window.
fn deltaCompress(
    allocator: std.mem.Allocator,
    objects: []PackObject,
    config: PackObjectsConfig,
) !void {
    if (objects.len < 2) return;

    const window = config.window_size;

    var i: usize = 0;
    while (i < objects.len) : (i += 1) {
        if (objects[i].size < MIN_DELTA_SIZE) continue;

        // Look backward in the window for potential delta bases
        const start = if (i >= window) i - window else 0;
        var best_delta: ?[]u8 = null;
        var best_base_idx: usize = 0;
        var best_delta_size: usize = std.math.maxInt(usize);

        var j: usize = start;
        while (j < i) : (j += 1) {
            // Only delta against same type
            if (objects[j].obj_type != objects[i].obj_type) continue;
            // Don't exceed depth limit
            if (objects[j].delta_depth >= config.depth_limit) continue;
            // Skip if base is much smaller (unlikely to produce good delta)
            if (objects[j].size * 4 < objects[i].size) continue;

            const delta = createDelta(allocator, objects[j].data, objects[i].data) catch continue;
            if (delta) |d| {
                if (d.len < best_delta_size) {
                    if (best_delta) |old| allocator.free(old);
                    best_delta = d;
                    best_delta_size = d.len;
                    best_base_idx = j;
                } else {
                    allocator.free(d);
                }
            }
        }

        if (best_delta) |delta| {
            objects[i].delta_base_oid = objects[best_base_idx].oid;
            objects[i].delta_data = delta;
            objects[i].delta_depth = objects[best_base_idx].delta_depth + 1;
        }
    }
}

/// Write the pack file and index from the object list.
fn writePack(
    allocator: std.mem.Allocator,
    objects: []PackObject,
    output_base_path: []const u8,
) !PackResult {
    const num_objects: u32 = @intCast(objects.len);

    var pack_data = std.array_list.Managed(u8).init(allocator);
    defer pack_data.deinit();

    // Pack header
    try pack_data.appendSlice("PACK");
    try appendU32Big(&pack_data, 2); // version
    try appendU32Big(&pack_data, num_objects);

    // Write each object
    // First pass: build an OID -> offset map for ref_delta
    var oid_offset_map = std.AutoHashMap([types.OID_RAW_LEN]u8, u64).init(allocator);
    defer oid_offset_map.deinit();

    for (objects) |*obj| {
        obj.offset = @intCast(pack_data.items.len);

        if (obj.delta_data) |delta| {
            // Write as ref_delta
            const compressed = try compress.zlibDeflate(allocator, delta);
            defer allocator.free(compressed);

            // ref_delta type header
            const header_start = pack_data.items.len;
            try writePackObjHeader(&pack_data, 7, delta.len); // 7 = ref_delta
            // Base OID
            try pack_data.appendSlice(&obj.delta_base_oid.?.bytes);
            // Compressed delta data
            try pack_data.appendSlice(compressed);
            const header_end = pack_data.items.len;
            obj.crc32 = computeCrc32(pack_data.items[header_start..header_end]);
        } else {
            // Write as full object
            const type_int: u8 = @intFromEnum(obj.obj_type);
            const compressed = try compress.zlibDeflate(allocator, obj.data);
            defer allocator.free(compressed);

            const header_start = pack_data.items.len;
            try writePackObjHeader(&pack_data, type_int, obj.size);
            try pack_data.appendSlice(compressed);
            const header_end = pack_data.items.len;
            obj.crc32 = computeCrc32(pack_data.items[header_start..header_end]);
        }

        try oid_offset_map.put(obj.oid.bytes, obj.offset);
    }

    // Pack checksum
    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(pack_data.items);
    const pack_hash = hasher.finalResult();
    try pack_data.appendSlice(&pack_hash);

    // Write pack file
    const pack_path = try allocator.alloc(u8, output_base_path.len + 5);
    @memcpy(pack_path[0..output_base_path.len], output_base_path);
    @memcpy(pack_path[output_base_path.len..], ".pack");

    const pack_file = try std.fs.createFileAbsolute(pack_path, .{});
    defer pack_file.close();
    try pack_file.writeAll(pack_data.items);

    // Write index file
    const idx_path = try allocator.alloc(u8, output_base_path.len + 4);
    @memcpy(idx_path[0..output_base_path.len], output_base_path);
    @memcpy(idx_path[output_base_path.len..], ".idx");

    try writeIndex(allocator, objects, &pack_hash, idx_path);

    return PackResult{
        .pack_hash = types.ObjectId{ .bytes = pack_hash },
        .pack_path = pack_path,
        .idx_path = idx_path,
        .num_objects = num_objects,
        .allocator = allocator,
    };
}

/// Write a pack index file (version 2).
fn writeIndex(
    allocator: std.mem.Allocator,
    objects: []PackObject,
    pack_hash: *const [20]u8,
    idx_path: []const u8,
) !void {
    const num_objects: u32 = @intCast(objects.len);

    // Sort by OID for the index
    const sorted_indices = try allocator.alloc(u32, num_objects);
    defer allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*idx, i| {
        idx.* = @intCast(i);
    }

    const objs = objects;
    std.mem.sort(u32, sorted_indices, objs, struct {
        fn lessThan(ctx: []const PackObject, a: u32, b: u32) bool {
            return std.mem.order(u8, &ctx[a].oid.bytes, &ctx[b].oid.bytes) == .lt;
        }
    }.lessThan);

    var idx_data = std.array_list.Managed(u8).init(allocator);
    defer idx_data.deinit();

    // Magic + version
    try appendU32Big(&idx_data, 0xff744f63);
    try appendU32Big(&idx_data, 2);

    // Fanout table
    var fanout: [256]u32 = [_]u32{0} ** 256;
    for (sorted_indices) |idx| {
        const first_byte = objs[idx].oid.bytes[0];
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
        try idx_data.appendSlice(&objs[idx].oid.bytes);
    }

    // CRC32 table
    for (sorted_indices) |idx| {
        try appendU32Big(&idx_data, objs[idx].crc32);
    }

    // Offset table (32-bit)
    for (sorted_indices) |idx| {
        const offset: u32 = @intCast(objs[idx].offset);
        try appendU32Big(&idx_data, offset);
    }

    // Pack checksum
    try idx_data.appendSlice(pack_hash);

    // Index checksum
    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(idx_data.items);
    const idx_hash = hasher.finalResult();
    try idx_data.appendSlice(&idx_hash);

    const idx_file = try std.fs.createFileAbsolute(idx_path, .{});
    defer idx_file.close();
    try idx_file.writeAll(idx_data.items);
}

/// Compute packing statistics from a list of objects.
pub fn computeStats(objects: []const PackObject) PackStats {
    var stats = PackStats{};
    stats.total_objects = @intCast(objects.len);
    for (objects) |*obj| {
        if (obj.delta_data != null) {
            stats.delta_objects += 1;
            stats.delta_size += obj.delta_data.?.len;
        } else {
            stats.full_objects += 1;
        }
        stats.total_size += obj.size;
    }
    return stats;
}

/// Enumerate all objects in the repository (loose + packed).
pub fn enumerateAllObjects(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
) ![]types.ObjectId {
    var oid_set = std.AutoHashMap([types.OID_RAW_LEN]u8, void).init(allocator);
    defer oid_set.deinit();

    // Scan loose objects
    var dir_path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(dir_path_buf[pos..][0..repo.git_dir.len], repo.git_dir);
    pos += repo.git_dir.len;
    const obj_suffix = "/objects";
    @memcpy(dir_path_buf[pos..][0..obj_suffix.len], obj_suffix);
    pos += obj_suffix.len;
    const objects_dir = dir_path_buf[0..pos];

    if (std.fs.openDirAbsolute(objects_dir, .{ .iterate = true })) |dir_handle| {
        var dir = dir_handle;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len != 2) continue;
            // Validate hex
            const valid = isHexByte(entry.name);
            if (!valid) continue;

            // Scan subdirectory
            if (dir.openDir(entry.name, .{ .iterate = true })) |sub_handle| {
                var sub_dir = sub_handle;
                defer sub_dir.close();
                var sub_iter = sub_dir.iterate();
                while (try sub_iter.next()) |sub_entry| {
                    if (sub_entry.kind != .file) continue;
                    if (sub_entry.name.len != types.OID_HEX_LEN - 2) continue;

                    var hex_buf: [types.OID_HEX_LEN]u8 = undefined;
                    hex_buf[0] = entry.name[0];
                    hex_buf[1] = entry.name[1];
                    @memcpy(hex_buf[2..], sub_entry.name[0 .. types.OID_HEX_LEN - 2]);
                    const oid = types.ObjectId.fromHex(&hex_buf) catch continue;
                    try oid_set.put(oid.bytes, {});
                }
            } else |_| {}
        }
    } else |_| {}

    // Scan pack files
    for (repo.packs.items) |*pack_entry| {
        var idx_iter = pack_entry.pack.idx.iterator();
        while (idx_iter.next()) |item| {
            try oid_set.put(item.oid.bytes, {});
        }
    }

    // Collect results
    var result = std.array_list.Managed(types.ObjectId).init(allocator);
    defer result.deinit();

    var map_iter = oid_set.keyIterator();
    while (map_iter.next()) |key| {
        try result.append(types.ObjectId{ .bytes = key.* });
    }

    return result.toOwnedSlice();
}

// --- Internal helpers ---

fn writeVarSize(data: *std.array_list.Managed(u8), size: usize) !void {
    var s = size;
    while (true) {
        var byte: u8 = @intCast(s & 0x7f);
        s >>= 7;
        if (s > 0) byte |= 0x80;
        try data.append(byte);
        if (s == 0) break;
    }
}

fn emitCopy(data: *std.array_list.Managed(u8), offset: usize, size: usize) !void {
    var cmd: u8 = 0x80;
    var off_bytes: [4]u8 = undefined;
    var size_bytes: [3]u8 = undefined;
    var off_count: u8 = 0;
    var size_count: u8 = 0;

    // Encode offset bytes
    const off32: u32 = @intCast(offset);
    if (off32 & 0xFF != 0 or (off32 >> 8) == 0) {
        off_bytes[off_count] = @intCast(off32 & 0xFF);
        off_count += 1;
        cmd |= 0x01;
    }
    if (off32 & 0xFF00 != 0) {
        off_bytes[off_count] = @intCast((off32 >> 8) & 0xFF);
        off_count += 1;
        cmd |= 0x02;
    }
    if (off32 & 0xFF0000 != 0) {
        off_bytes[off_count] = @intCast((off32 >> 16) & 0xFF);
        off_count += 1;
        cmd |= 0x04;
    }
    if (off32 & 0xFF000000 != 0) {
        off_bytes[off_count] = @intCast((off32 >> 24) & 0xFF);
        off_count += 1;
        cmd |= 0x08;
    }

    // Encode size bytes (special: 0 means 0x10000)
    const sz: u32 = if (size == 0x10000) 0 else @intCast(size);
    if (sz != 0) {
        if (sz & 0xFF != 0 or (sz >> 8) == 0) {
            size_bytes[size_count] = @intCast(sz & 0xFF);
            size_count += 1;
            cmd |= 0x10;
        }
        if (sz & 0xFF00 != 0) {
            size_bytes[size_count] = @intCast((sz >> 8) & 0xFF);
            size_count += 1;
            cmd |= 0x20;
        }
        if (sz & 0xFF0000 != 0) {
            size_bytes[size_count] = @intCast((sz >> 16) & 0xFF);
            size_count += 1;
            cmd |= 0x40;
        }
    }

    try data.append(cmd);
    try data.appendSlice(off_bytes[0..off_count]);
    try data.appendSlice(size_bytes[0..size_count]);
}

fn emitAdd(data: *std.array_list.Managed(u8), bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const chunk_size: u8 = @intCast(@min(remaining.len, 127));
        try data.append(chunk_size);
        try data.appendSlice(remaining[0..chunk_size]);
        remaining = remaining[chunk_size..];
    }
}

fn chunkHash(data: *const [4]u8) u32 {
    var h: u32 = 0;
    h = h *% 31 +% data[0];
    h = h *% 31 +% data[1];
    h = h *% 31 +% data[2];
    h = h *% 31 +% data[3];
    return h;
}

fn oidNameHash(oid: *const types.ObjectId) u32 {
    return std.mem.readInt(u32, oid.bytes[0..4], .big);
}

fn isHexByte(name: []const u8) bool {
    if (name.len != 2) return false;
    for (name) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

fn writePackObjHeader(data: *std.array_list.Managed(u8), obj_type: u8, size: usize) !void {
    var s = size;
    var first_byte: u8 = @as(u8, (obj_type & 0x07)) << 4;
    first_byte |= @as(u8, @intCast(s & 0x0f));
    s >>= 4;
    if (s > 0) first_byte |= 0x80;
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

test "createDelta basic" {
    const allocator = std.testing.allocator;
    const base = "Hello, world! This is a test string for delta compression.";
    const target = "Hello, world! This is a modified test string for delta.";

    const delta = try createDelta(allocator, base, target);
    if (delta) |d| {
        defer allocator.free(d);
        // Delta should be smaller than target
        try std.testing.expect(d.len < target.len);
    }
}

test "createDelta identical" {
    const allocator = std.testing.allocator;
    const base = "Hello, world! This is a test.";
    const target = "Hello, world! This is a test.";

    const delta = try createDelta(allocator, base, target);
    if (delta) |d| {
        defer allocator.free(d);
        // Delta of identical data should be very small
        try std.testing.expect(d.len < target.len);
    }
}

test "writeVarSize" {
    var data = std.array_list.Managed(u8).init(std.testing.allocator);
    defer data.deinit();
    try writeVarSize(&data, 127);
    try std.testing.expectEqual(@as(usize, 1), data.items.len);
    try std.testing.expectEqual(@as(u8, 127), data.items[0]);
}

test "writeVarSize large" {
    var data = std.array_list.Managed(u8).init(std.testing.allocator);
    defer data.deinit();
    try writeVarSize(&data, 128);
    try std.testing.expectEqual(@as(usize, 2), data.items.len);
}
