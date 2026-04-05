const std = @import("std");

// Git delta format:
// - Base size (variable-length encoding)
// - Result size (variable-length encoding)
// - Instructions:
//   - Copy from base: MSB set. Bits 0-3 indicate which offset bytes follow,
//     bits 4-6 indicate which size bytes follow
//   - Add new data: MSB clear. Lower 7 bits = length, followed by that many bytes

pub fn applyDelta(allocator: std.mem.Allocator, base: []const u8, delta: []const u8) ![]u8 {
    var pos: usize = 0;

    // Read base size (for validation)
    const base_size = readVarSize(delta, &pos);
    if (base_size != base.len) return error.DeltaBaseSizeMismatch;

    // Read result size
    const result_size = readVarSize(delta, &pos);

    var result = try allocator.alloc(u8, result_size);
    errdefer allocator.free(result);
    var result_pos: usize = 0;

    while (pos < delta.len) {
        const cmd = delta[pos];
        pos += 1;

        if (cmd & 0x80 != 0) {
            // Copy from base
            var copy_offset: usize = 0;
            var copy_size: usize = 0;

            if (cmd & 0x01 != 0) {
                copy_offset = delta[pos];
                pos += 1;
            }
            if (cmd & 0x02 != 0) {
                copy_offset |= @as(usize, delta[pos]) << 8;
                pos += 1;
            }
            if (cmd & 0x04 != 0) {
                copy_offset |= @as(usize, delta[pos]) << 16;
                pos += 1;
            }
            if (cmd & 0x08 != 0) {
                copy_offset |= @as(usize, delta[pos]) << 24;
                pos += 1;
            }

            if (cmd & 0x10 != 0) {
                copy_size = delta[pos];
                pos += 1;
            }
            if (cmd & 0x20 != 0) {
                copy_size |= @as(usize, delta[pos]) << 8;
                pos += 1;
            }
            if (cmd & 0x40 != 0) {
                copy_size |= @as(usize, delta[pos]) << 16;
                pos += 1;
            }

            if (copy_size == 0) copy_size = 0x10000;

            if (copy_offset + copy_size > base.len) return error.DeltaCopyOutOfBounds;
            if (result_pos + copy_size > result_size) return error.DeltaResultOverflow;

            @memcpy(result[result_pos..][0..copy_size], base[copy_offset..][0..copy_size]);
            result_pos += copy_size;
        } else if (cmd != 0) {
            // Add new data
            const add_size: usize = cmd;
            if (pos + add_size > delta.len) return error.DeltaDataTruncated;
            if (result_pos + add_size > result_size) return error.DeltaResultOverflow;

            @memcpy(result[result_pos..][0..add_size], delta[pos..][0..add_size]);
            pos += add_size;
            result_pos += add_size;
        } else {
            // cmd == 0 is reserved/error
            return error.DeltaInvalidCommand;
        }
    }

    if (result_pos != result_size) return error.DeltaResultSizeMismatch;

    return result;
}

fn readVarSize(data: []const u8, pos: *usize) usize {
    var result: usize = 0;
    var shift: u6 = 0;
    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        result |= @as(usize, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    return result;
}

test "delta apply - add only" {
    const allocator = std.testing.allocator;
    // Base: "hello"
    // Delta: base_size=5, result_size=11, add "hello world"
    var delta_buf: [32]u8 = undefined;
    var dpos: usize = 0;

    // base size = 5
    delta_buf[dpos] = 5;
    dpos += 1;
    // result size = 11
    delta_buf[dpos] = 11;
    dpos += 1;
    // add 11 bytes
    delta_buf[dpos] = 11;
    dpos += 1;
    @memcpy(delta_buf[dpos..][0..11], "hello world");
    dpos += 11;

    const result = try applyDelta(allocator, "hello", delta_buf[0..dpos]);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "delta apply - copy" {
    const allocator = std.testing.allocator;
    const base = "hello world";
    // Delta: copy first 5 bytes from base, add " zig"
    var delta_buf: [32]u8 = undefined;
    var dpos: usize = 0;

    // base size = 11
    delta_buf[dpos] = 11;
    dpos += 1;
    // result size = 9
    delta_buf[dpos] = 9;
    dpos += 1;
    // copy: offset=0, size=5 -> cmd = 0x80 | 0x01 | 0x10 = 0x91
    delta_buf[dpos] = 0x91;
    dpos += 1;
    delta_buf[dpos] = 0; // offset byte
    dpos += 1;
    delta_buf[dpos] = 5; // size byte
    dpos += 1;
    // add 4 bytes: " zig"
    delta_buf[dpos] = 4;
    dpos += 1;
    @memcpy(delta_buf[dpos..][0..4], " zig");
    dpos += 4;

    const result = try applyDelta(allocator, base, delta_buf[0..dpos]);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello zig", result);
}
