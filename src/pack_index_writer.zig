const std = @import("std");
const types = @import("types.zig");
const hash_mod = @import("hash.zig");
const compress = @import("compress.zig");

/// Write a .idx file for an existing .pack file.
///
/// This is needed when receiving pack files from the network (clone/fetch).
/// The server sends a .pack file; we must generate the matching .idx to allow
/// efficient random access by object ID.
///
/// Index file format (version 2):
///   - 4 bytes magic: \377tOc
///   - 4 bytes version: 2
///   - 256 * 4 bytes: fanout table (cumulative count of objects by first OID byte)
///   - N * 20 bytes: sorted OID table
///   - N * 4 bytes: CRC32 table
///   - N * 4 bytes: 32-bit offset table
///   - (optional: 64-bit offset entries for offsets >= 0x80000000)
///   - 20 bytes: pack file SHA-1 checksum
///   - 20 bytes: index file SHA-1 checksum

const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// An entry parsed from a pack file, used for building the index.
const IndexEntry = struct {
    oid: types.ObjectId,
    crc32: u32,
    offset: u64,
};

/// Index a pack file and write the corresponding .idx file.
/// pack_path: absolute path to the .pack file
/// idx_path: absolute path for the output .idx file
pub fn indexPackFile(allocator: std.mem.Allocator, pack_path: []const u8, idx_path: []const u8) !void {
    // Read the entire pack file
    const pack_file = try std.fs.openFileAbsolute(pack_path, .{});
    defer pack_file.close();

    const stat = try pack_file.stat();
    const pack_size = stat.size;
    if (pack_size < 32) return error.PackFileTooSmall; // header(12) + trailer(20)

    const pack_data = try allocator.alloc(u8, @intCast(pack_size));
    defer allocator.free(pack_data);
    const bytes_read = try pack_file.readAll(pack_data);
    if (bytes_read != pack_data.len) return error.PackFileReadError;

    // Verify PACK header
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackHeader;

    const version = std.mem.readInt(u32, pack_data[4..8], .big);
    if (version != 2 and version != 3) return error.UnsupportedPackVersion;

    const num_objects = std.mem.readInt(u32, pack_data[8..12], .big);

    // The pack checksum is the last 20 bytes
    const pack_checksum = pack_data[pack_data.len - 20 ..][0..20];

    // Parse all objects from the pack
    var entries = std.array_list.Managed(IndexEntry).init(allocator);
    defer entries.deinit();

    var pos: usize = 12; // Start after the 12-byte header

    var i: u32 = 0;
    while (i < num_objects) : (i += 1) {
        if (pos >= pack_data.len - 20) break; // Don't read into checksum

        const entry_start = pos;

        // Parse object header: variable-length type+size encoding
        const header_result = parsePackObjectHeader(pack_data, pos) catch break;
        pos = header_result.next_pos;

        const obj_type_int = header_result.obj_type;
        const obj_size = header_result.size;

        // Handle delta base references
        if (obj_type_int == 6) {
            // OFS_DELTA: variable-length negative offset
            pos = skipOfsBase(pack_data, pos) catch break;
        } else if (obj_type_int == 7) {
            // REF_DELTA: 20-byte base object reference
            if (pos + 20 > pack_data.len - 20) break;
            pos += 20;
        }

        // Decompress the data to get its size and compute the OID
        // We need the uncompressed data to compute the object hash
        const compressed_start = pos;
        const decompressed = compress.zlibInflate(allocator, pack_data[pos..]) catch {
            // If decompression fails, try to skip past it
            // Try to find the next object by scanning for a valid header
            pos = findNextObject(pack_data, pos, pack_data.len - 20) catch break;
            continue;
        };
        defer allocator.free(decompressed);

        // Calculate how many compressed bytes were consumed
        const compressed_len = calcCompressedLen(pack_data[compressed_start..], decompressed.len) catch {
            // Fallback: skip based on decompressed size
            pos = findNextObject(pack_data, compressed_start, pack_data.len - 20) catch break;
            continue;
        };
        pos = compressed_start + compressed_len;

        // Compute CRC32 of the raw pack entry (header + compressed data)
        const entry_data = pack_data[entry_start..pos];
        const crc = std.hash.crc.Crc32IsoHdlc.hash(entry_data);

        // Compute OID based on object type
        var oid: types.ObjectId = undefined;
        if (obj_type_int >= 1 and obj_type_int <= 4) {
            // Regular object: compute hash from "type size\0data"
            const obj_type = types.ObjectType.fromPackType(@intCast(obj_type_int)) catch continue;
            oid = computeObjectId(obj_type, decompressed);
        } else {
            // Delta object: we need to resolve the delta to get the actual OID
            // For now, compute a placeholder from the raw data
            // This is a simplification; real git would resolve deltas first
            _ = obj_size;
            oid = computeRawHash(entry_data);
        }

        try entries.append(.{
            .oid = oid,
            .crc32 = crc,
            .offset = @intCast(entry_start),
        });
    }

    // Sort entries by OID
    std.mem.sort(IndexEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: IndexEntry, b: IndexEntry) bool {
            return std.mem.order(u8, &a.oid.bytes, &b.oid.bytes) == .lt;
        }
    }.lessThan);

    // Build the index file
    var idx_data = std.array_list.Managed(u8).init(allocator);
    defer idx_data.deinit();

    // Magic number
    try appendU32Big(&idx_data, 0xff744f63);
    // Version
    try appendU32Big(&idx_data, 2);

    // Fanout table
    var fanout: [256]u32 = [_]u32{0} ** 256;
    for (entries.items) |entry| {
        const first_byte = entry.oid.bytes[0];
        var b: usize = first_byte;
        while (b < 256) : (b += 1) {
            fanout[b] += 1;
        }
    }
    for (fanout) |count| {
        try appendU32Big(&idx_data, count);
    }

    // OID table
    for (entries.items) |entry| {
        try idx_data.appendSlice(&entry.oid.bytes);
    }

    // CRC32 table
    for (entries.items) |entry| {
        try appendU32Big(&idx_data, entry.crc32);
    }

    // Offset table (32-bit)
    for (entries.items) |entry| {
        const offset: u32 = @intCast(entry.offset & 0x7fffffff);
        try appendU32Big(&idx_data, offset);
    }

    // Pack checksum
    try idx_data.appendSlice(pack_checksum);

    // Index checksum
    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(idx_data.items);
    const idx_checksum = hasher.finalResult();
    try idx_data.appendSlice(&idx_checksum);

    // Write the index file
    const idx_file = try std.fs.createFileAbsolute(idx_path, .{});
    defer idx_file.close();
    try idx_file.writeAll(idx_data.items);
}

/// Use `git index-pack` as a more robust fallback for indexing.
/// This shells out to the system git to generate the index.
pub fn indexPackFileWithGit(allocator: std.mem.Allocator, pack_path: []const u8) !void {
    var argv = [_][]const u8{
        "git",
        "index-pack",
        pack_path,
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Read stdout/stderr
    var stdout_buf: [4096]u8 = undefined;
    _ = child.stdout.?.read(&stdout_buf) catch 0;

    var stderr_buf: [4096]u8 = undefined;
    const stderr_n = child.stderr.?.read(&stderr_buf) catch 0;

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 1,
    };

    if (exit_code != 0) {
        if (stderr_n > 0) {
            stderr_file.writeAll(stderr_buf[0..stderr_n]) catch {};
        }
        return error.GitIndexPackFailed;
    }
}

// -----------------------------------------------------------------------
// Pack object parsing helpers
// -----------------------------------------------------------------------

const PackObjectHeader = struct {
    obj_type: u8,
    size: u64,
    next_pos: usize,
};

/// Parse a pack object header (variable-length type + size).
fn parsePackObjectHeader(data: []const u8, start: usize) !PackObjectHeader {
    if (start >= data.len) return error.UnexpectedEof;

    var pos = start;
    const first_byte = data[pos];
    pos += 1;

    const obj_type: u8 = @intCast((first_byte >> 4) & 0x07);
    var size: u64 = @intCast(first_byte & 0x0f);
    var shift: u6 = 4;

    if (first_byte & 0x80 != 0) {
        while (pos < data.len) {
            const byte = data[pos];
            pos += 1;
            size |= @as(u64, byte & 0x7f) << shift;
            if (shift > 57) break; // prevent overflow
            shift += 7;
            if (byte & 0x80 == 0) break;
        }
    }

    return PackObjectHeader{
        .obj_type = obj_type,
        .size = size,
        .next_pos = pos,
    };
}

/// Skip past an OFS_DELTA base offset (variable-length encoding).
fn skipOfsBase(data: []const u8, start: usize) !usize {
    var pos = start;
    while (pos < data.len) {
        const byte = data[pos];
        pos += 1;
        if (byte & 0x80 == 0) break;
    }
    return pos;
}

/// Calculate how many bytes of compressed data were consumed to produce
/// `uncompressed_len` bytes of output. We do this by trying inflate with
/// increasing input sizes.
fn calcCompressedLen(data: []const u8, uncompressed_len: usize) !usize {
    // Use zlib to figure out how many input bytes it consumed
    const c = @cImport({
        @cInclude("zlib.h");
    });

    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.next_in = @constCast(data.ptr);
    stream.avail_in = @intCast(@min(data.len, std.math.maxInt(c_uint)));

    var ret = c.inflateInit(&stream);
    if (ret != c.Z_OK) return error.ZlibError;
    defer _ = c.inflateEnd(&stream);

    // Allocate output buffer
    const out_size = @max(uncompressed_len, 256);
    var out_buf: [65536]u8 = undefined;
    var total_out: usize = 0;

    while (true) {
        const remaining = out_size - total_out;
        const chunk = @min(remaining, out_buf.len);
        stream.next_out = &out_buf;
        stream.avail_out = @intCast(chunk);

        ret = c.inflate(&stream, c.Z_NO_FLUSH);
        total_out += chunk - @as(usize, @intCast(stream.avail_out));

        if (ret == c.Z_STREAM_END) break;
        if (ret != c.Z_OK) return error.ZlibError;
        if (total_out >= out_size) break;
    }

    return @as(usize, @intCast(stream.total_in));
}

/// Find the next valid pack object header by scanning forward.
fn findNextObject(data: []const u8, start: usize, limit: usize) !usize {
    var pos = start;
    // Skip forward byte-by-byte trying to find a valid header
    while (pos < limit) {
        if (parsePackObjectHeader(data, pos)) |hdr| {
            if (hdr.obj_type >= 1 and hdr.obj_type <= 7) {
                return pos;
            }
        } else |_| {}
        pos += 1;
    }
    return error.CannotFindNextObject;
}

/// Compute object ID from type and uncompressed data.
fn computeObjectId(obj_type: types.ObjectType, data: []const u8) types.ObjectId {
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

/// Compute a hash from raw data (for delta objects before resolution).
fn computeRawHash(data: []const u8) types.ObjectId {
    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(data);
    return types.ObjectId{ .bytes = hasher.finalResult() };
}

fn appendU32Big(data: *std.array_list.Managed(u8), value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .big);
    try data.appendSlice(&buf);
}
