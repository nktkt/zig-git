const std = @import("std");
const types = @import("types.zig");

const IDX_MAGIC: u32 = 0xff744f63;
const IDX_VERSION: u32 = 2;
const FANOUT_ENTRIES = 256;
const FANOUT_OFFSET = 8;
const FANOUT_SIZE = FANOUT_ENTRIES * 4;
const OID_TABLE_OFFSET = FANOUT_OFFSET + FANOUT_SIZE;

pub const PackIndex = struct {
    data: []align(std.heap.page_size_min) const u8,
    data_len: usize,
    num_objects: u32,
    file: std.fs.File,

    pub fn open(path: []const u8) !PackIndex {
        const file = std.fs.openFileAbsolute(path, .{}) catch return error.PackIndexNotFound;
        errdefer file.close();

        const stat = try file.stat();
        if (stat.size < OID_TABLE_OFFSET) return error.PackIndexTooSmall;

        const data = try std.posix.mmap(null, stat.size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, file.handle, 0);
        errdefer std.posix.munmap(@constCast(@alignCast(data)));

        const magic = readU32(data, 0);
        const version = readU32(data, 4);
        if (magic != IDX_MAGIC or version != IDX_VERSION) {
            return error.InvalidPackIndex;
        }

        const num_objects = readU32(data, FANOUT_OFFSET + (255 * 4));

        return PackIndex{
            .data = data,
            .data_len = stat.size,
            .num_objects = num_objects,
            .file = file,
        };
    }

    pub fn close(self: *PackIndex) void {
        std.posix.munmap(@constCast(@alignCast(self.data)));
        self.file.close();
    }

    pub fn objectCount(self: *const PackIndex) u32 {
        return self.num_objects;
    }

    pub fn findOffset(self: *const PackIndex, oid: *const types.ObjectId) ?u64 {
        const first_byte = oid.bytes[0];

        const lo: u32 = if (first_byte == 0) 0 else readU32(self.data, FANOUT_OFFSET + (@as(u32, first_byte) - 1) * 4);
        const hi: u32 = readU32(self.data, FANOUT_OFFSET + @as(u32, first_byte) * 4);

        if (lo >= hi) return null;

        const oid_table_start = OID_TABLE_OFFSET;
        var low = lo;
        var high = hi;

        while (low < high) {
            const mid = low + (high - low) / 2;
            const entry_offset = oid_table_start + @as(usize, mid) * types.OID_RAW_LEN;
            const entry_oid = self.data[entry_offset..][0..types.OID_RAW_LEN];

            switch (std.mem.order(u8, entry_oid, &oid.bytes)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return self.getOffset(mid),
            }
        }

        return null;
    }

    fn getOffset(self: *const PackIndex, index: u32) ?u64 {
        const n: usize = self.num_objects;
        const offset_table_start = OID_TABLE_OFFSET + n * types.OID_RAW_LEN + n * 4;
        const offset_entry = offset_table_start + @as(usize, index) * 4;

        if (offset_entry + 4 > self.data_len) return null;
        const raw_offset = readU32(self.data, offset_entry);

        if (raw_offset & 0x80000000 != 0) {
            const large_idx = raw_offset & 0x7fffffff;
            const large_table_start = offset_table_start + n * 4;
            const large_entry = large_table_start + @as(usize, large_idx) * 8;
            if (large_entry + 8 > self.data_len) return null;
            return readU64(self.data, large_entry);
        }

        return @as(u64, raw_offset);
    }

    pub fn getOid(self: *const PackIndex, index: u32) ?types.ObjectId {
        const oid_offset = OID_TABLE_OFFSET + @as(usize, index) * types.OID_RAW_LEN;
        if (oid_offset + types.OID_RAW_LEN > self.data_len) return null;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, self.data[oid_offset..][0..types.OID_RAW_LEN]);
        return oid;
    }

    pub const Iterator = struct {
        pack_index: *const PackIndex,
        current: u32,

        pub fn next(self: *Iterator) ?struct { oid: types.ObjectId, offset: u64 } {
            if (self.current >= self.pack_index.num_objects) return null;
            const oid = self.pack_index.getOid(self.current) orelse return null;
            const offset = self.pack_index.getOffset(self.current) orelse return null;
            self.current += 1;
            return .{ .oid = oid, .offset = offset };
        }
    };

    pub fn iterator(self: *const PackIndex) Iterator {
        return Iterator{
            .pack_index = self,
            .current = 0,
        };
    }
};

fn readU32(data: []const u8, offset: usize) u32 {
    const bytes = data[offset..][0..4];
    return std.mem.readInt(u32, bytes, .big);
}

fn readU64(data: []const u8, offset: usize) u64 {
    const bytes = data[offset..][0..8];
    return std.mem.readInt(u64, bytes, .big);
}
