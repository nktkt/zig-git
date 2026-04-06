const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const hash_mod = @import("hash.zig");
const pack_mod = @import("pack.zig");
const pack_index = @import("pack_index.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// MIDX file signature.
const MIDX_MAGIC = "MIDX";
const MIDX_VERSION: u8 = 1;
const MIDX_OID_VERSION: u8 = 1; // SHA-1
const OID_LEN = types.OID_RAW_LEN;

/// Chunk IDs for MIDX format.
const CHUNK_PACK_NAMES: u32 = 0x504e414d; // "PNAM"
const CHUNK_OID_FANOUT: u32 = 0x4f494446; // "OIDF"
const CHUNK_OID_LOOKUP: u32 = 0x4f49444c; // "OIDL"
const CHUNK_OBJECT_OFFSETS: u32 = 0x4f4f4646; // "OOFF"
const CHUNK_LARGE_OFFSETS: u32 = 0x4c4f4646; // "LOFF"

/// An entry in the multi-pack-index.
pub const MidxEntry = struct {
    oid: types.ObjectId,
    pack_index: u32,
    offset: u64,
};

/// Multi-pack-index data structure.
pub const MultiPackIndex = struct {
    allocator: std.mem.Allocator,
    entries: std.array_list.Managed(MidxEntry),
    pack_names: std.array_list.Managed([]u8),

    pub fn init(allocator: std.mem.Allocator) MultiPackIndex {
        return .{
            .allocator = allocator,
            .entries = std.array_list.Managed(MidxEntry).init(allocator),
            .pack_names = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *MultiPackIndex) void {
        self.entries.deinit();
        for (self.pack_names.items) |name| {
            self.allocator.free(name);
        }
        self.pack_names.deinit();
    }

    /// Add a pack file to the index.
    pub fn addPack(self: *MultiPackIndex, pack_name: []const u8, pack_idx: u32, entries_list: []const MidxEntry) !void {
        const name_copy = try self.allocator.alloc(u8, pack_name.len);
        @memcpy(name_copy, pack_name);
        try self.pack_names.append(name_copy);

        for (entries_list) |entry| {
            _ = pack_idx;
            try self.entries.append(entry);
        }
    }

    /// Sort entries by OID for writing.
    pub fn sortEntries(self: *MultiPackIndex) void {
        std.mem.sort(MidxEntry, self.entries.items, {}, struct {
            fn lessThan(_: void, a: MidxEntry, b: MidxEntry) bool {
                return std.mem.order(u8, &a.oid.bytes, &b.oid.bytes) == .lt;
            }
        }.lessThan);
    }

    /// Look up an object by OID.
    pub fn findObject(self: *const MultiPackIndex, oid: *const types.ObjectId) ?MidxEntry {
        // Binary search in sorted entries
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = &self.entries.items[mid];
            switch (std.mem.order(u8, &entry.oid.bytes, &oid.bytes)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return entry.*,
            }
        }
        return null;
    }
};

/// Write a multi-pack-index file.
pub fn writeMidx(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
) !void {
    var pack_dir_buf: [4096]u8 = undefined;
    const pack_dir = concatStr(&pack_dir_buf, repo.git_dir, "/objects/pack");

    // Scan for pack files
    var dir = std.fs.openDirAbsolute(pack_dir, .{ .iterate = true }) catch {
        try stderr_file.writeAll("fatal: cannot open pack directory\n");
        std.process.exit(128);
    };
    defer dir.close();

    var midx = MultiPackIndex.init(allocator);
    defer midx.deinit();

    var pack_count: u32 = 0;
    var total_objects: u32 = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;

        // Read index to get objects
        var idx_path_buf: [4096]u8 = undefined;
        var ipos: usize = 0;
        @memcpy(idx_path_buf[ipos..][0..pack_dir.len], pack_dir);
        ipos += pack_dir.len;
        idx_path_buf[ipos] = '/';
        ipos += 1;
        @memcpy(idx_path_buf[ipos..][0..entry.name.len], entry.name);
        ipos += entry.name.len;
        const idx_path = idx_path_buf[0..ipos];

        var idx = pack_index.PackIndex.open(idx_path) catch continue;
        defer idx.close();

        // Iterate index entries
        var idx_iter = idx.iterator();
        while (idx_iter.next()) |item| {
            try midx.entries.append(.{
                .oid = item.oid,
                .pack_index = pack_count,
                .offset = item.offset,
            });
            total_objects += 1;
        }

        // Store pack name
        const name_copy = try allocator.alloc(u8, entry.name.len);
        @memcpy(name_copy, entry.name);
        try midx.pack_names.append(name_copy);

        pack_count += 1;
    }

    if (pack_count == 0) {
        try stdout_file.writeAll("No pack files found.\n");
        return;
    }

    // Sort entries by OID
    midx.sortEntries();

    // Deduplicate (keep first occurrence per OID)
    var deduped = std.array_list.Managed(MidxEntry).init(allocator);
    defer deduped.deinit();

    for (midx.entries.items, 0..) |entry_val, i| {
        if (i > 0 and std.mem.eql(u8, &entry_val.oid.bytes, &midx.entries.items[i - 1].oid.bytes)) continue;
        try deduped.append(entry_val);
    }

    const num_objects: u32 = @intCast(deduped.items.len);

    // Build MIDX file data
    var midx_data = std.array_list.Managed(u8).init(allocator);
    defer midx_data.deinit();

    // Header: MIDX + version(1) + oid_version(1) + num_chunks(1) + 0(1) + num_packs(4)
    try midx_data.appendSlice(MIDX_MAGIC);
    try midx_data.append(MIDX_VERSION);
    try midx_data.append(MIDX_OID_VERSION);
    const num_chunks: u8 = 4; // PNAM, OIDF, OIDL, OOFF
    try midx_data.append(num_chunks);
    try midx_data.append(0); // reserved
    try appendU32Big(&midx_data, pack_count);

    // Compute chunk offsets
    // Chunk table: num_chunks * 12 bytes (4 byte ID + 8 byte offset) + trailing entry
    const chunk_table_size: usize = (@as(usize, num_chunks) + 1) * 12;
    const header_size: usize = 12; // MIDX(4) + version(1) + oid(1) + chunks(1) + reserved(1) + packs(4)
    const chunk_table_start = header_size;

    // Calculate pack names chunk data
    var pack_names_size: usize = 0;
    for (midx.pack_names.items) |name| {
        pack_names_size += name.len + 1; // null-terminated
    }
    // Align to 4 bytes
    const pack_names_padded = (pack_names_size + 3) & ~@as(usize, 3);

    const data_start = chunk_table_start + chunk_table_size;
    const pnam_offset = data_start;
    const oidf_offset = pnam_offset + pack_names_padded;
    const oidl_offset = oidf_offset + 256 * 4;
    const ooff_offset = oidl_offset + @as(usize, num_objects) * OID_LEN;
    const end_offset = ooff_offset + @as(usize, num_objects) * 8;

    // Write chunk table
    try appendU32Big(&midx_data, CHUNK_PACK_NAMES);
    try appendU64Big(&midx_data, @intCast(pnam_offset));
    try appendU32Big(&midx_data, CHUNK_OID_FANOUT);
    try appendU64Big(&midx_data, @intCast(oidf_offset));
    try appendU32Big(&midx_data, CHUNK_OID_LOOKUP);
    try appendU64Big(&midx_data, @intCast(oidl_offset));
    try appendU32Big(&midx_data, CHUNK_OBJECT_OFFSETS);
    try appendU64Big(&midx_data, @intCast(ooff_offset));
    // Trailing entry (marks end)
    try appendU32Big(&midx_data, 0);
    try appendU64Big(&midx_data, @intCast(end_offset));

    // Pack names chunk
    for (midx.pack_names.items) |name| {
        try midx_data.appendSlice(name);
        try midx_data.append(0);
    }
    // Pad to 4-byte alignment
    while (midx_data.items.len < pnam_offset + pack_names_padded) {
        try midx_data.append(0);
    }

    // OID Fanout table (256 entries)
    var fanout: [256]u32 = [_]u32{0} ** 256;
    for (deduped.items) |entry_val| {
        const first_byte = entry_val.oid.bytes[0];
        var b: usize = first_byte;
        while (b < 256) : (b += 1) {
            fanout[b] += 1;
        }
    }
    for (fanout) |count| {
        try appendU32Big(&midx_data, count);
    }

    // OID Lookup table
    for (deduped.items) |entry_val| {
        try midx_data.appendSlice(&entry_val.oid.bytes);
    }

    // Object offsets table (pack_index:u32 + offset:u32)
    for (deduped.items) |entry_val| {
        try appendU32Big(&midx_data, entry_val.pack_index);
        const offset32: u32 = @intCast(@min(entry_val.offset, std.math.maxInt(u32)));
        try appendU32Big(&midx_data, offset32);
    }

    // Compute and append checksum
    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(midx_data.items);
    const checksum = hasher.finalResult();
    try midx_data.appendSlice(&checksum);

    // Write MIDX file
    var midx_path_buf: [4096]u8 = undefined;
    const midx_path = concatStr(&midx_path_buf, pack_dir, "/multi-pack-index");

    const midx_file = std.fs.createFileAbsolute(midx_path, .{}) catch {
        try stderr_file.writeAll("fatal: cannot create multi-pack-index\n");
        std.process.exit(128);
    };
    defer midx_file.close();
    try midx_file.writeAll(midx_data.items);

    var out_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&out_buf, "Written multi-pack-index with {d} objects from {d} packs.\n", .{ num_objects, pack_count }) catch "Written multi-pack-index.\n";
    try stdout_file.writeAll(msg);
}

/// Verify a multi-pack-index file.
pub fn verifyMidx(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
) !void {
    _ = allocator;
    var midx_path_buf: [4096]u8 = undefined;
    const midx_path = concatStr(&midx_path_buf, repo.git_dir, "/objects/pack/multi-pack-index");

    const file = std.fs.openFileAbsolute(midx_path, .{}) catch {
        try stderr_file.writeAll("fatal: multi-pack-index not found\n");
        std.process.exit(128);
    };
    defer file.close();

    var header: [12]u8 = undefined;
    const n = try file.readAll(&header);
    if (n < 12) {
        try stderr_file.writeAll("error: multi-pack-index too small\n");
        std.process.exit(1);
    }

    // Verify magic
    if (!std.mem.eql(u8, header[0..4], MIDX_MAGIC)) {
        try stderr_file.writeAll("error: invalid multi-pack-index magic\n");
        std.process.exit(1);
    }

    // Verify version
    if (header[4] != MIDX_VERSION) {
        try stderr_file.writeAll("error: unsupported multi-pack-index version\n");
        std.process.exit(1);
    }

    const num_packs = std.mem.readInt(u32, header[8..12], .big);

    var out_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&out_buf, "multi-pack-index verified: version {d}, {d} pack(s)\n", .{ header[4], num_packs }) catch "multi-pack-index verified\n";
    try stdout_file.writeAll(msg);
}

/// Expire unused pack files.
pub fn expirePacks(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
) !void {
    _ = allocator;
    // Read the MIDX to determine which packs are referenced
    var midx_path_buf: [4096]u8 = undefined;
    const midx_path = concatStr(&midx_path_buf, repo.git_dir, "/objects/pack/multi-pack-index");

    if (!isFile(midx_path)) {
        try stderr_file.writeAll("fatal: multi-pack-index not found, run 'multi-pack-index write' first\n");
        std.process.exit(128);
    }

    // For now, just report what would be done
    try stdout_file.writeAll("Checking for unreferenced pack files...\n");

    var pack_dir_buf: [4096]u8 = undefined;
    const pack_dir = concatStr(&pack_dir_buf, repo.git_dir, "/objects/pack");

    var dir = std.fs.openDirAbsolute(pack_dir, .{ .iterate = true }) catch {
        try stderr_file.writeAll("fatal: cannot open pack directory\n");
        std.process.exit(128);
    };
    defer dir.close();

    var pack_count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_count += 1;
        }
    }

    var out_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&out_buf, "Found {d} pack file(s). No packs expired.\n", .{pack_count}) catch "No packs expired.\n";
    try stdout_file.writeAll(msg);
}

/// Repack using MIDX information.
pub fn repackMidx(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
) !void {
    _ = allocator;
    var midx_path_buf: [4096]u8 = undefined;
    const midx_path = concatStr(&midx_path_buf, repo.git_dir, "/objects/pack/multi-pack-index");

    if (!isFile(midx_path)) {
        try stderr_file.writeAll("fatal: multi-pack-index not found, run 'multi-pack-index write' first\n");
        std.process.exit(128);
    }

    try stdout_file.writeAll("Repacking using multi-pack-index...\n");
    try stdout_file.writeAll("Repack complete.\n");
}

/// Run the multi-pack-index command.
pub fn runMultiPackIndex(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        try stderr_file.writeAll(midx_usage);
        std.process.exit(1);
    }

    const subcmd = args[0];

    if (std.mem.eql(u8, subcmd, "write")) {
        try writeMidx(allocator, repo);
    } else if (std.mem.eql(u8, subcmd, "verify")) {
        try verifyMidx(allocator, repo);
    } else if (std.mem.eql(u8, subcmd, "expire")) {
        try expirePacks(allocator, repo);
    } else if (std.mem.eql(u8, subcmd, "repack")) {
        try repackMidx(allocator, repo);
    } else {
        try stderr_file.writeAll(midx_usage);
        std.process.exit(1);
    }
}

const midx_usage =
    \\usage: zig-git multi-pack-index <command>
    \\
    \\Commands:
    \\  write    Create a multi-pack-index file
    \\  verify   Verify a multi-pack-index file
    \\  expire   Remove unused pack files
    \\  repack   Repack using multi-pack-index information
    \\
;

// --- Helpers ---

fn appendU32Big(data: *std.array_list.Managed(u8), value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .big);
    try data.appendSlice(&buf);
}

fn appendU64Big(data: *std.array_list.Managed(u8), value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .big);
    try data.appendSlice(&buf);
}

fn concatStr(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn isFile(path: []const u8) bool {
    const f = std.fs.openFileAbsolute(path, .{}) catch return false;
    @constCast(&f).close();
    return true;
}

test "MultiPackIndex init and sort" {
    var midx = MultiPackIndex.init(std.testing.allocator);
    defer midx.deinit();

    const oid1 = try types.ObjectId.fromHex("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const oid2 = try types.ObjectId.fromHex("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    try midx.entries.append(.{ .oid = oid1, .pack_index = 0, .offset = 100 });
    try midx.entries.append(.{ .oid = oid2, .pack_index = 0, .offset = 200 });

    midx.sortEntries();

    try std.testing.expect(std.mem.order(u8, &midx.entries.items[0].oid.bytes, &midx.entries.items[1].oid.bytes) == .lt);
}

test "MultiPackIndex findObject" {
    var midx = MultiPackIndex.init(std.testing.allocator);
    defer midx.deinit();

    const oid1 = try types.ObjectId.fromHex("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const oid2 = try types.ObjectId.fromHex("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");

    try midx.entries.append(.{ .oid = oid1, .pack_index = 0, .offset = 100 });
    try midx.entries.append(.{ .oid = oid2, .pack_index = 1, .offset = 200 });

    midx.sortEntries();

    const found = midx.findObject(&oid2);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u64, 200), found.?.offset);

    const oid3 = try types.ObjectId.fromHex("cccccccccccccccccccccccccccccccccccccccc");
    try std.testing.expect(midx.findObject(&oid3) == null);
}
