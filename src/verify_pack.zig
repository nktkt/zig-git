const std = @import("std");
const types = @import("types.zig");
const pack_mod = @import("pack.zig");
const pack_index = @import("pack_index.zig");
const compress = @import("compress.zig");
const hash_mod = @import("hash.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const PACK_MAGIC = "PACK";
const PACK_HEADER_SIZE = 12;

pub fn runVerifyPack(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var verbose = false;
    var stat_only = false;
    var idx_paths = std.array_list.Managed([]const u8).init(allocator);
    defer idx_paths.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--stat-only")) {
            stat_only = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try idx_paths.append(arg);
        }
    }

    if (idx_paths.items.len == 0) {
        try stderr_file.writeAll("usage: zig-git verify-pack [-v | --verbose] [-s | --stat-only] <pack>.idx ...\n");
        std.process.exit(1);
    }

    for (idx_paths.items) |idx_path| {
        verifyPackFile(allocator, idx_path, verbose, stat_only) catch |err| {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: {s}: {s}\n", .{ idx_path, @errorName(err) }) catch "error: verify-pack failed\n";
            try stderr_file.writeAll(msg);
            std.process.exit(1);
        };
    }
}

fn verifyPackFile(allocator: std.mem.Allocator, idx_path: []const u8, verbose: bool, stat_only: bool) !void {
    // Determine pack path from idx path
    var pack_path_buf: [4096]u8 = undefined;
    const pack_path = idxToPackPath(idx_path, &pack_path_buf) orelse {
        try stderr_file.writeAll("error: not a .idx file\n");
        return error.InvalidPackIndex;
    };

    // Open the idx file
    var idx = try pack_index.PackIndex.open(idx_path);
    defer idx.close();

    // Open the pack file
    const pack_file = std.fs.openFileAbsolute(pack_path, .{}) catch return error.PackFileNotFound;
    defer @constCast(&pack_file).close();

    // Verify pack header
    var header: [PACK_HEADER_SIZE]u8 = undefined;
    const header_n = try @constCast(&pack_file).readAll(&header);
    if (header_n < PACK_HEADER_SIZE) return error.PackFileTruncated;
    if (!std.mem.eql(u8, header[0..4], PACK_MAGIC)) return error.InvalidPackFile;

    const version = std.mem.readInt(u32, header[4..8], .big);
    if (version != 2) return error.UnsupportedPackVersion;

    const num_objects = std.mem.readInt(u32, header[8..12], .big);

    // Verify the idx reports the same count
    if (idx.num_objects != num_objects) {
        try stderr_file.writeAll("error: pack/index object count mismatch\n");
        return error.PackIndexMismatch;
    }

    // Verify pack checksum
    const pack_stat = try @constCast(&pack_file).stat();
    if (pack_stat.size < 20) return error.PackFileTruncated;

    // Read last 20 bytes (SHA-1 checksum)
    try @constCast(&pack_file).seekTo(pack_stat.size - 20);
    var stored_checksum: [20]u8 = undefined;
    _ = try @constCast(&pack_file).readAll(&stored_checksum);

    // Compute SHA-1 of everything except the last 20 bytes
    const data_size = pack_stat.size - 20;
    try @constCast(&pack_file).seekTo(0);
    var hasher = hash_mod.Sha1.init(.{});
    var total_read: u64 = 0;
    while (total_read < data_size) {
        var read_buf: [8192]u8 = undefined;
        const to_read: usize = @intCast(@min(data_size - total_read, 8192));
        const n = try @constCast(&pack_file).readAll(read_buf[0..to_read]);
        if (n == 0) break;
        hasher.update(read_buf[0..n]);
        total_read += n;
    }
    const computed_checksum = hasher.finalResult();
    if (!std.mem.eql(u8, &stored_checksum, &computed_checksum)) {
        try stderr_file.writeAll("error: pack checksum mismatch\n");
        return error.PackChecksumMismatch;
    }

    // Statistics
    var total_objects: u32 = 0;
    var delta_count: u32 = 0;
    var max_depth: u32 = 0;

    // Open a PackFile for reading objects
    var pack = pack_mod.PackFile.open(pack_path) catch return error.PackFileNotFound;
    defer pack.close();

    // Iterate over all objects in the index
    var iter = idx.iterator();
    while (iter.next()) |item| {
        total_objects += 1;

        if (verbose and !stat_only) {
            // Read the object to verify it and print info
            var obj = pack.readObject(allocator, item.offset) catch |err| {
                var buf: [256]u8 = undefined;
                const hex = item.oid.toHex();
                const msg = std.fmt.bufPrint(&buf, "error: {s}: {s}\n", .{ &hex, @errorName(err) }) catch "error: object read failed\n";
                try stderr_file.writeAll(msg);
                continue;
            };
            defer obj.deinit();

            // Print: SHA TYPE SIZE OFFSET
            var buf: [512]u8 = undefined;
            const hex = item.oid.toHex();
            const line = std.fmt.bufPrint(&buf, "{s} {s} {d} {d}\n", .{
                &hex,
                obj.obj_type.toString(),
                obj.data.len,
                item.offset,
            }) catch continue;
            try stdout_file.writeAll(line);

            // Check if it's a delta by peeking at the raw type
            const raw_type = readPackObjectType(&pack, item.offset) catch continue;
            if (raw_type == 6 or raw_type == 7) {
                delta_count += 1;
                // Estimate depth (simplified)
                const depth = estimateDeltaDepth(&pack, allocator, item.offset) catch 1;
                if (depth > max_depth) max_depth = depth;
            }
        } else {
            // Just verify the object can be read
            var obj = pack.readObject(allocator, item.offset) catch |err| {
                var buf: [256]u8 = undefined;
                const hex = item.oid.toHex();
                const msg = std.fmt.bufPrint(&buf, "error: {s}: {s}\n", .{ &hex, @errorName(err) }) catch "error: object read failed\n";
                try stderr_file.writeAll(msg);
                continue;
            };
            obj.deinit();

            const raw_type = readPackObjectType(&pack, item.offset) catch continue;
            if (raw_type == 6 or raw_type == 7) {
                delta_count += 1;
            }
        }
    }

    // Print statistics
    if (!stat_only) {
        var buf: [512]u8 = undefined;
        const hex_checksum = checksumToHex(&stored_checksum);
        const stats = std.fmt.bufPrint(&buf, "{s} pack {s}: ok\n", .{
            pack_path,
            &hex_checksum,
        }) catch return;
        try stderr_file.writeAll(stats);
    }

    // Always print chain info
    {
        var buf: [256]u8 = undefined;
        const stats = std.fmt.bufPrint(&buf, "total {d}, delta {d}, max depth {d}\n", .{
            total_objects,
            delta_count,
            max_depth,
        }) catch return;
        try stderr_file.writeAll(stats);
    }
}

fn readPackObjectType(pack: *pack_mod.PackFile, offset: u64) !u3 {
    try pack.file.seekTo(offset);
    var first: [1]u8 = undefined;
    _ = try pack.file.readAll(&first);
    return @intCast((first[0] >> 4) & 0x07);
}

fn estimateDeltaDepth(pack: *pack_mod.PackFile, allocator: std.mem.Allocator, offset: u64) !u32 {
    _ = allocator;
    var depth: u32 = 0;
    var current_offset = offset;

    while (depth < 64) {
        try pack.file.seekTo(current_offset);
        var first: [1]u8 = undefined;
        _ = try pack.file.readAll(&first);
        const raw_type: u3 = @intCast((first[0] >> 4) & 0x07);

        // Skip size bytes
        if (first[0] & 0x80 != 0) {
            while (true) {
                var b: [1]u8 = undefined;
                _ = try pack.file.readAll(&b);
                if (b[0] & 0x80 == 0) break;
            }
        }

        if (raw_type == 6) {
            // OFS_DELTA
            depth += 1;
            var ob: [1]u8 = undefined;
            _ = try pack.file.readAll(&ob);
            var delta_offset: u64 = ob[0] & 0x7f;
            if (ob[0] & 0x80 != 0) {
                while (true) {
                    var b: [1]u8 = undefined;
                    _ = try pack.file.readAll(&b);
                    delta_offset = (delta_offset + 1) << 7 | (b[0] & 0x7f);
                    if (b[0] & 0x80 == 0) break;
                }
            }
            current_offset = current_offset - delta_offset;
        } else if (raw_type == 7) {
            // REF_DELTA
            depth += 1;
            var base_oid: types.ObjectId = undefined;
            _ = try pack.file.readAll(&base_oid.bytes);
            const base_offset = pack.idx.findOffset(&base_oid) orelse break;
            current_offset = base_offset;
        } else {
            // Base object
            break;
        }
    }

    return depth;
}

fn checksumToHex(checksum: *const [20]u8) [40]u8 {
    var hex: [40]u8 = undefined;
    hash_mod.bytesToHex(checksum, &hex);
    return hex;
}

fn idxToPackPath(idx_path: []const u8, buf: []u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, idx_path, ".idx")) return null;
    const base_len = idx_path.len - 4;
    if (base_len + 5 > buf.len) return null;
    @memcpy(buf[0..base_len], idx_path[0..base_len]);
    @memcpy(buf[base_len..][0..5], ".pack");
    return buf[0 .. base_len + 5];
}
