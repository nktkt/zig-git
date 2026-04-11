const std = @import("std");
const c = @cImport({
    @cInclude("zlib.h");
});

pub const Error = error{
    ZlibDataError,
    ZlibStreamError,
    ZlibMemError,
    ZlibBufError,
    ZlibVersionError,
    OutOfMemory,
};

pub fn zlibInflate(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    if (input.len > std.math.maxInt(c_uint)) return error.ZlibBufError;
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.next_in = @constCast(input.ptr);
    stream.avail_in = @intCast(input.len);

    var ret = c.inflateInit(&stream);
    if (ret != c.Z_OK) return zlibErr(ret);
    defer _ = c.inflateEnd(&stream);

    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var buf: [8192]u8 = undefined;
    while (true) {
        stream.next_out = &buf;
        stream.avail_out = buf.len;
        ret = c.inflate(&stream, c.Z_NO_FLUSH);
        if (ret != c.Z_OK and ret != c.Z_STREAM_END) {
            return zlibErr(ret);
        }
        const have = buf.len - stream.avail_out;
        if (have > 0) {
            result.appendSlice(buf[0..have]) catch return error.OutOfMemory;
        }
        if (ret == c.Z_STREAM_END) break;
    }

    return result.toOwnedSlice() catch return error.OutOfMemory;
}

/// Inflate with a pre-allocated output buffer (avoids ArrayList growth overhead).
/// Used when the decompressed size is known in advance (e.g., from pack object headers).
pub fn zlibInflateKnownSize(allocator: std.mem.Allocator, input: []const u8, expected_size: usize) Error![]u8 {
    if (input.len > std.math.maxInt(c_uint)) return error.ZlibBufError;
    if (expected_size > std.math.maxInt(c_uint)) return error.ZlibBufError;
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.next_in = @constCast(input.ptr);
    stream.avail_in = @intCast(input.len);

    var ret = c.inflateInit(&stream);
    if (ret != c.Z_OK) return zlibErr(ret);
    defer _ = c.inflateEnd(&stream);

    const result = allocator.alloc(u8, expected_size) catch return error.OutOfMemory;
    errdefer allocator.free(result);

    stream.next_out = result.ptr;
    stream.avail_out = @intCast(expected_size);

    ret = c.inflate(&stream, c.Z_FINISH);
    if (ret == c.Z_STREAM_END) {
        return result;
    }
    if (ret != c.Z_OK and ret != c.Z_BUF_ERROR) {
        return zlibErr(ret);
    }

    // If we didn't finish in one call, continue with remaining buffer space
    while (true) {
        ret = c.inflate(&stream, c.Z_NO_FLUSH);
        if (ret == c.Z_STREAM_END) break;
        if (ret != c.Z_OK) {
            return zlibErr(ret);
        }
    }

    return result;
}

/// Returns the number of compressed bytes consumed from input.
/// Useful for pack file reading where we need to know where the compressed data ends.
pub fn zlibInflateWithConsumed(allocator: std.mem.Allocator, input: []const u8, expected_size: usize) Error!struct { data: []u8, consumed: usize } {
    if (input.len > std.math.maxInt(c_uint)) return error.ZlibBufError;
    if (expected_size > std.math.maxInt(c_uint)) return error.ZlibBufError;
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.next_in = @constCast(input.ptr);
    stream.avail_in = @intCast(input.len);

    var ret = c.inflateInit(&stream);
    if (ret != c.Z_OK) return zlibErr(ret);
    defer _ = c.inflateEnd(&stream);

    const result = allocator.alloc(u8, expected_size) catch return error.OutOfMemory;
    errdefer allocator.free(result);

    stream.next_out = result.ptr;
    stream.avail_out = @intCast(expected_size);

    ret = c.inflate(&stream, c.Z_FINISH);
    if (ret == c.Z_STREAM_END) {
        return .{ .data = result, .consumed = stream.total_in };
    }
    if (ret != c.Z_OK and ret != c.Z_BUF_ERROR) {
        return zlibErr(ret);
    }

    while (true) {
        ret = c.inflate(&stream, c.Z_NO_FLUSH);
        if (ret == c.Z_STREAM_END) break;
        if (ret != c.Z_OK) {
            return zlibErr(ret);
        }
    }

    return .{ .data = result, .consumed = stream.total_in };
}

pub fn zlibDeflate(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    if (input.len > std.math.maxInt(c_uint)) return error.ZlibBufError;
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    stream.next_in = @constCast(input.ptr);
    stream.avail_in = @intCast(input.len);

    var ret = c.deflateInit(&stream, c.Z_DEFAULT_COMPRESSION);
    if (ret != c.Z_OK) return zlibErr(ret);
    defer _ = c.deflateEnd(&stream);

    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var buf: [8192]u8 = undefined;
    while (true) {
        stream.next_out = &buf;
        stream.avail_out = buf.len;
        ret = c.deflate(&stream, c.Z_FINISH);
        if (ret != c.Z_OK and ret != c.Z_STREAM_END) {
            return zlibErr(ret);
        }
        const have = buf.len - stream.avail_out;
        if (have > 0) {
            result.appendSlice(buf[0..have]) catch return error.OutOfMemory;
        }
        if (ret == c.Z_STREAM_END) break;
    }

    return result.toOwnedSlice() catch return error.OutOfMemory;
}

fn zlibErr(ret: c_int) Error {
    return switch (ret) {
        c.Z_DATA_ERROR => error.ZlibDataError,
        c.Z_STREAM_ERROR => error.ZlibStreamError,
        c.Z_MEM_ERROR => error.ZlibMemError,
        c.Z_BUF_ERROR => error.ZlibBufError,
        c.Z_VERSION_ERROR => error.ZlibVersionError,
        else => error.ZlibStreamError,
    };
}
