const std = @import("std");
const types = @import("types.zig");
const pack_index = @import("pack_index.zig");
const compress = @import("compress.zig");
const delta_mod = @import("delta.zig");

const PACK_MAGIC = "PACK";
const PACK_VERSION: u32 = 2;
const PACK_HEADER_SIZE = 12;
const MAX_DELTA_DEPTH = 64;

pub const PackFile = struct {
    file: std.fs.File,
    num_objects: u32,
    idx: pack_index.PackIndex,

    pub fn open(pack_path: []const u8) !PackFile {
        const file = std.fs.openFileAbsolute(pack_path, .{}) catch return error.PackFileNotFound;
        errdefer file.close();

        var header: [PACK_HEADER_SIZE]u8 = undefined;
        const n = try file.readAll(&header);
        if (n < PACK_HEADER_SIZE) return error.PackFileTruncated;
        if (!std.mem.eql(u8, header[0..4], PACK_MAGIC)) return error.InvalidPackFile;

        const version = std.mem.readInt(u32, header[4..8], .big);
        if (version != PACK_VERSION) return error.UnsupportedPackVersion;

        const num_objects = std.mem.readInt(u32, header[8..12], .big);

        var idx_path_buf: [4096]u8 = undefined;
        const idx_path = packToIdxPath(pack_path, &idx_path_buf) orelse return error.PackIndexNotFound;

        var idx = pack_index.PackIndex.open(idx_path) catch return error.PackIndexNotFound;
        errdefer idx.close();

        return PackFile{
            .file = file,
            .num_objects = num_objects,
            .idx = idx,
        };
    }

    pub fn close(self: *PackFile) void {
        self.idx.close();
        self.file.close();
    }

    pub fn findObject(self: *const PackFile, oid: *const types.ObjectId) ?u64 {
        return self.idx.findOffset(oid);
    }

    pub fn readObject(self: *PackFile, allocator: std.mem.Allocator, offset: u64) !types.Object {
        return self.readObjectAtOffset(allocator, offset, 0);
    }

    fn readObjectAtOffset(self: *PackFile, allocator: std.mem.Allocator, offset: u64, depth: u32) !types.Object {
        if (depth > MAX_DELTA_DEPTH) return error.DeltaChainTooDeep;

        try self.file.seekTo(offset);

        // Read type and size from variable-length header
        var first: [1]u8 = undefined;
        _ = try self.file.readAll(&first);
        const first_byte = first[0];
        const raw_type: u3 = @intCast((first_byte >> 4) & 0x07);
        var size: u64 = first_byte & 0x0f;
        var shift: u6 = 4;

        if (first_byte & 0x80 != 0) {
            while (true) {
                var b_buf: [1]u8 = undefined;
                _ = try self.file.readAll(&b_buf);
                const b = b_buf[0];
                size |= @as(u64, b & 0x7f) << shift;
                if (b & 0x80 == 0) break;
                shift = @min(shift + 7, 63);
            }
        }

        const pack_type = try types.PackObjectType.fromInt(raw_type);

        if (pack_type.isBase()) {
            const current_pos = try self.file.getPos();
            const remaining = try self.readChunk(allocator, current_pos);
            defer allocator.free(remaining);

            const data = try compress.zlibInflate(allocator, remaining);

            if (data.len > size) {
                const trimmed = try allocator.alloc(u8, @intCast(size));
                @memcpy(trimmed, data[0..@intCast(size)]);
                allocator.free(data);
                return types.Object{
                    .obj_type = try pack_type.toObjectType(),
                    .data = trimmed,
                    .allocator = allocator,
                };
            }

            return types.Object{
                .obj_type = try pack_type.toObjectType(),
                .data = data,
                .allocator = allocator,
            };
        }

        switch (pack_type) {
            .ofs_delta => {
                var ob_buf: [1]u8 = undefined;
                _ = try self.file.readAll(&ob_buf);
                var delta_offset: u64 = ob_buf[0] & 0x7f;
                if (ob_buf[0] & 0x80 != 0) {
                    while (true) {
                        var b_buf: [1]u8 = undefined;
                        _ = try self.file.readAll(&b_buf);
                        delta_offset = (delta_offset + 1) << 7 | (b_buf[0] & 0x7f);
                        if (b_buf[0] & 0x80 == 0) break;
                    }
                }

                const base_offset = offset - delta_offset;

                const current_pos = try self.file.getPos();
                const remaining = try self.readChunk(allocator, current_pos);
                defer allocator.free(remaining);
                const delta_data = try compress.zlibInflate(allocator, remaining);
                defer allocator.free(delta_data);

                var base_obj = try self.readObjectAtOffset(allocator, base_offset, depth + 1);
                defer base_obj.deinit();

                const result_data = try delta_mod.applyDelta(allocator, base_obj.data, delta_data);

                return types.Object{
                    .obj_type = base_obj.obj_type,
                    .data = result_data,
                    .allocator = allocator,
                };
            },
            .ref_delta => {
                var base_oid: types.ObjectId = undefined;
                _ = try self.file.readAll(&base_oid.bytes);

                const current_pos = try self.file.getPos();
                const remaining = try self.readChunk(allocator, current_pos);
                defer allocator.free(remaining);
                const delta_data = try compress.zlibInflate(allocator, remaining);
                defer allocator.free(delta_data);

                const base_offset = self.idx.findOffset(&base_oid) orelse return error.DeltaBaseNotFound;

                var base_obj = try self.readObjectAtOffset(allocator, base_offset, depth + 1);
                defer base_obj.deinit();

                const result_data = try delta_mod.applyDelta(allocator, base_obj.data, delta_data);

                return types.Object{
                    .obj_type = base_obj.obj_type,
                    .data = result_data,
                    .allocator = allocator,
                };
            },
            else => return error.InvalidPackObjectType,
        }
    }

    fn readChunk(self: *PackFile, allocator: std.mem.Allocator, start_pos: u64) ![]u8 {
        const chunk_size: usize = 1024 * 1024;
        const stat = try self.file.stat();
        const available = stat.size - start_pos;
        const to_read: usize = @intCast(@min(available, chunk_size));

        try self.file.seekTo(start_pos);
        const buf = try allocator.alloc(u8, to_read);
        errdefer allocator.free(buf);

        const bytes_read = try self.file.readAll(buf);
        if (bytes_read < to_read) {
            const trimmed = try allocator.alloc(u8, bytes_read);
            @memcpy(trimmed, buf[0..bytes_read]);
            allocator.free(buf);
            return trimmed;
        }

        return buf;
    }
};

fn packToIdxPath(pack_path: []const u8, buf: []u8) ?[]const u8 {
    if (pack_path.len < 5) return null;
    if (!std.mem.endsWith(u8, pack_path, ".pack")) return null;
    const base_len = pack_path.len - 5;
    if (base_len + 4 > buf.len) return null;
    @memcpy(buf[0..base_len], pack_path[0..base_len]);
    @memcpy(buf[base_len..][0..4], ".idx");
    return buf[0 .. base_len + 4];
}
