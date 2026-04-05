const std = @import("std");
const types = @import("types.zig");

const BITMAP_MAGIC = "BITM";
const BITMAP_HEADER_SIZE = 32;

pub const PackBitmap = struct {
    data: []align(std.heap.page_size_min) const u8,
    file: std.fs.File,
    entry_count: u32,
    flags: u16,
    bitmap_start: usize,

    pub fn open(path: []const u8) !PackBitmap {
        const file = std.fs.openFileAbsolute(path, .{}) catch return error.BitmapNotFound;
        errdefer file.close();

        const stat = try file.stat();
        if (stat.size < BITMAP_HEADER_SIZE) return error.BitmapTooSmall;

        const data = try std.posix.mmap(null, stat.size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, file.handle, 0);
        errdefer std.posix.munmap(@constCast(@alignCast(data)));

        if (!std.mem.eql(u8, data[0..4], BITMAP_MAGIC)) return error.InvalidBitmap;

        const version = std.mem.readInt(u16, data[4..6], .big);
        if (version != 1) return error.UnsupportedBitmapVersion;

        const flags = std.mem.readInt(u16, data[6..8], .big);
        const entry_count = std.mem.readInt(u32, data[8..12], .big);

        return PackBitmap{
            .data = data,
            .file = file,
            .entry_count = entry_count,
            .flags = flags,
            .bitmap_start = BITMAP_HEADER_SIZE,
        };
    }

    pub fn close(self: *PackBitmap) void {
        std.posix.munmap(@constCast(@alignCast(self.data)));
        self.file.close();
    }

    pub fn hasHashCache(self: *const PackBitmap) bool {
        return self.flags & 0x04 != 0;
    }
};

pub const EwahBitmap = struct {
    bits: std.array_list.Managed(u64),

    pub fn init(allocator: std.mem.Allocator) EwahBitmap {
        return .{ .bits = std.array_list.Managed(u64).init(allocator) };
    }

    pub fn deinit(self: *EwahBitmap) void {
        self.bits.deinit();
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8, offset: usize) !struct { bitmap: EwahBitmap, bytes_read: usize } {
        var bitmap = EwahBitmap.init(allocator);
        errdefer bitmap.deinit();

        var pos = offset;

        if (pos + 4 > data.len) return error.EwahTruncated;
        pos += 4; // bit_count

        if (pos + 4 > data.len) return error.EwahTruncated;
        const word_count = readU32(data, pos);
        pos += 4;

        var words_read: u32 = 0;
        while (words_read < word_count) {
            if (pos + 8 > data.len) return error.EwahTruncated;
            const rlw = readU64(data, pos);
            pos += 8;
            words_read += 1;

            const fill_bit: u64 = if (rlw & 1 != 0) ~@as(u64, 0) else 0;
            const run_len: u32 = @intCast((rlw >> 1) & 0xFFFFFFFF);
            const literal_count: u32 = @intCast((rlw >> 33) & 0x7FFFFFFF);

            for (0..run_len) |_| {
                try bitmap.bits.append(fill_bit);
            }

            for (0..literal_count) |_| {
                if (pos + 8 > data.len) return error.EwahTruncated;
                const word = readU64(data, pos);
                pos += 8;
                words_read += 1;
                try bitmap.bits.append(word);
            }
        }

        return .{ .bitmap = bitmap, .bytes_read = pos - offset };
    }

    pub fn isSet(self: *const EwahBitmap, bit: usize) bool {
        const word_idx = bit / 64;
        const bit_idx: u6 = @intCast(bit % 64);
        if (word_idx >= self.bits.items.len) return false;
        return (self.bits.items[word_idx] >> bit_idx) & 1 != 0;
    }
};

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

fn readU64(data: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, data[offset..][0..8], .big);
}
