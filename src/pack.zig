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
    data: []align(std.heap.page_size_min) const u8,
    data_len: usize,
    num_objects: u32,
    idx: pack_index.PackIndex,
    file: std.fs.File,

    pub fn open(pack_path: []const u8) !PackFile {
        const file = std.fs.openFileAbsolute(pack_path, .{}) catch return error.PackFileNotFound;
        errdefer file.close();

        const stat = try file.stat();
        if (stat.size < PACK_HEADER_SIZE) return error.PackFileTruncated;

        const data = try std.posix.mmap(null, stat.size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, file.handle, 0);
        errdefer std.posix.munmap(@constCast(@alignCast(data)));

        if (!std.mem.eql(u8, data[0..4], PACK_MAGIC)) return error.InvalidPackFile;

        const version = std.mem.readInt(u32, data[4..8], .big);
        if (version != PACK_VERSION) return error.UnsupportedPackVersion;

        const num_objects = std.mem.readInt(u32, data[8..12], .big);

        var idx_path_buf: [4096]u8 = undefined;
        const idx_path = packToIdxPath(pack_path, &idx_path_buf) orelse return error.PackIndexNotFound;

        var idx = pack_index.PackIndex.open(idx_path) catch return error.PackIndexNotFound;
        errdefer idx.close();

        return PackFile{
            .data = data,
            .data_len = stat.size,
            .num_objects = num_objects,
            .idx = idx,
            .file = file,
        };
    }

    pub fn close(self: *PackFile) void {
        self.idx.close();
        std.posix.munmap(@constCast(@alignCast(self.data)));
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

        var pos: usize = @intCast(offset);
        if (pos >= self.data_len) return error.PackFileTruncated;

        // Read type and size from variable-length header
        const first_byte = self.data[pos];
        pos += 1;
        const raw_type: u3 = @intCast((first_byte >> 4) & 0x07);
        var size: u64 = first_byte & 0x0f;
        var shift: u6 = 4;

        if (first_byte & 0x80 != 0) {
            while (true) {
                if (pos >= self.data_len) return error.PackFileTruncated;
                const b = self.data[pos];
                pos += 1;
                size |= @as(u64, b & 0x7f) << shift;
                if (b & 0x80 == 0) break;
                shift = @min(shift + 7, 63);
            }
        }

        const pack_type = try types.PackObjectType.fromInt(raw_type);

        if (pack_type.isBase()) {
            const remaining = self.data[pos..self.data_len];

            const usize_size: usize = @intCast(size);
            const data = try compress.zlibInflateKnownSize(allocator, remaining, usize_size);

            return types.Object{
                .obj_type = try pack_type.toObjectType(),
                .data = data,
                .allocator = allocator,
            };
        }

        switch (pack_type) {
            .ofs_delta => {
                if (pos >= self.data_len) return error.PackFileTruncated;
                var delta_offset: u64 = self.data[pos] & 0x7f;
                var has_more = self.data[pos] & 0x80 != 0;
                pos += 1;
                while (has_more) {
                    if (pos >= self.data_len) return error.PackFileTruncated;
                    delta_offset = (delta_offset + 1) << 7 | (self.data[pos] & 0x7f);
                    has_more = self.data[pos] & 0x80 != 0;
                    pos += 1;
                }

                const base_offset = offset - delta_offset;

                const remaining = self.data[pos..self.data_len];
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
                if (pos + types.OID_RAW_LEN > self.data_len) return error.PackFileTruncated;
                var base_oid: types.ObjectId = undefined;
                @memcpy(&base_oid.bytes, self.data[pos..][0..types.OID_RAW_LEN]);
                pos += types.OID_RAW_LEN;

                const remaining = self.data[pos..self.data_len];
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
