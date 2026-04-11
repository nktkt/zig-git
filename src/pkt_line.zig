const std = @import("std");

/// Git pkt-line protocol format.
///
/// The pkt-line format is used in all git transport protocols (HTTP smart, SSH, git://).
/// Each line is prefixed by a 4-hex-digit length that includes the 4 bytes of the length
/// itself. Special packets use reserved lengths:
///   0000 = flush packet (end of message)
///   0001 = delimiter packet (section separator in protocol v2)
///   0002 = response-end packet
///
/// Side-band demultiplexing uses the first byte of the data payload:
///   band 1 = pack data
///   band 2 = progress messages (to stderr)
///   band 3 = error messages (fatal)

/// Packet types returned from reading.
pub const PacketType = enum {
    data,
    flush,
    delim,
    response_end,
};

/// Result of reading a pkt-line.
pub const PktLineResult = struct {
    packet_type: PacketType,
    data: []const u8,
    bytes_consumed: usize,
};

/// Side-band channel identifiers.
pub const SideBand = enum(u8) {
    pack_data = 1,
    progress = 2,
    err = 3,
};

/// Side-band demux result.
pub const SideBandResult = struct {
    band: SideBand,
    data: []const u8,
};

/// Error set for pkt-line operations.
pub const PktLineError = error{
    InvalidPktLineLength,
    PktLineTooShort,
    BufferTooSmall,
    InvalidHexChar,
    PktLineTooLarge,
    InvalidSideBand,
    UnexpectedFlush,
    ServerError,
};

// Maximum pkt-line length per git spec.
pub const MAX_PKT_LEN = 65520;

// Minimum data pkt-line length (4 bytes header + at least 1 byte data).
const MIN_DATA_LEN = 5;

/// Write a pkt-line with the given data into a buffer.
/// Returns the number of bytes written.
/// The format is: LLLL<data> where LLLL is the 4-hex-digit total length (including the 4 bytes).
pub fn writePktLine(buf: []u8, data: []const u8) PktLineError!usize {
    const total_len = data.len + 4;
    if (total_len > MAX_PKT_LEN) return PktLineError.PktLineTooLarge;
    if (buf.len < total_len) return PktLineError.BufferTooSmall;

    // Write the 4-hex-digit length prefix
    const hex_chars = "0123456789abcdef";
    buf[0] = hex_chars[(total_len >> 12) & 0xf];
    buf[1] = hex_chars[(total_len >> 8) & 0xf];
    buf[2] = hex_chars[(total_len >> 4) & 0xf];
    buf[3] = hex_chars[total_len & 0xf];

    // Copy data
    @memcpy(buf[4..][0..data.len], data);

    return total_len;
}

/// Write a pkt-line into a dynamic list.
pub fn writePktLineList(list: *std.array_list.Managed(u8), data: []const u8) !void {
    const total_len = data.len + 4;
    if (total_len > MAX_PKT_LEN) return PktLineError.PktLineTooLarge;

    const hex_chars = "0123456789abcdef";
    var hdr: [4]u8 = undefined;
    hdr[0] = hex_chars[(total_len >> 12) & 0xf];
    hdr[1] = hex_chars[(total_len >> 8) & 0xf];
    hdr[2] = hex_chars[(total_len >> 4) & 0xf];
    hdr[3] = hex_chars[total_len & 0xf];

    try list.appendSlice(&hdr);
    try list.appendSlice(data);
}

/// Write a flush packet (0000) into a buffer. Returns 4.
pub fn writeFlush(buf: []u8) PktLineError!usize {
    if (buf.len < 4) return PktLineError.BufferTooSmall;
    buf[0] = '0';
    buf[1] = '0';
    buf[2] = '0';
    buf[3] = '0';
    return 4;
}

/// Write a flush packet into a dynamic list.
pub fn writeFlushList(list: *std.array_list.Managed(u8)) !void {
    try list.appendSlice("0000");
}

/// Write a delimiter packet (0001) into a buffer. Returns 4.
pub fn writeDelim(buf: []u8) PktLineError!usize {
    if (buf.len < 4) return PktLineError.BufferTooSmall;
    buf[0] = '0';
    buf[1] = '0';
    buf[2] = '0';
    buf[3] = '1';
    return 4;
}

/// Write a delimiter packet into a dynamic list.
pub fn writeDelimList(list: *std.array_list.Managed(u8)) !void {
    try list.appendSlice("0001");
}

/// Write a response-end packet (0002) into a buffer. Returns 4.
pub fn writeResponseEnd(buf: []u8) PktLineError!usize {
    if (buf.len < 4) return PktLineError.BufferTooSmall;
    buf[0] = '0';
    buf[1] = '0';
    buf[2] = '0';
    buf[3] = '2';
    return 4;
}

/// Write a response-end packet into a dynamic list.
pub fn writeResponseEndList(list: *std.array_list.Managed(u8)) !void {
    try list.appendSlice("0002");
}

/// Read one pkt-line from data starting at position pos.
/// Returns a PktLineResult with the packet type, data slice, and bytes consumed.
/// Advances the logical position by bytes_consumed.
pub fn readPktLine(data: []const u8, pos: usize) PktLineError!PktLineResult {
    if (pos + 4 > data.len) return PktLineError.PktLineTooShort;

    // Parse the 4-hex-digit length
    const len_val = parseHex4(data[pos..][0..4]) catch return PktLineError.InvalidPktLineLength;

    // Special packets
    if (len_val == 0) {
        return PktLineResult{
            .packet_type = .flush,
            .data = &.{},
            .bytes_consumed = 4,
        };
    }
    if (len_val == 1) {
        return PktLineResult{
            .packet_type = .delim,
            .data = &.{},
            .bytes_consumed = 4,
        };
    }
    if (len_val == 2) {
        return PktLineResult{
            .packet_type = .response_end,
            .data = &.{},
            .bytes_consumed = 4,
        };
    }

    // len_val includes the 4 bytes of the length prefix itself
    if (len_val < 4) return PktLineError.InvalidPktLineLength;
    if (len_val > MAX_PKT_LEN) return PktLineError.PktLineTooLarge;

    const data_len = len_val - 4;
    if (pos + 4 + data_len > data.len) return PktLineError.PktLineTooShort;

    const payload = data[pos + 4 ..][0..data_len];

    return PktLineResult{
        .packet_type = .data,
        .data = payload,
        .bytes_consumed = len_val,
    };
}

/// Read all pkt-lines from a buffer until a flush packet or end of data.
/// Returns a list of data payloads (excluding flush/delim/response-end).
/// Caller owns the returned list.
pub fn readAllPktLines(allocator: std.mem.Allocator, data: []const u8) !ReadAllResult {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    errdefer lines.deinit();

    var pos: usize = 0;
    while (pos < data.len) {
        const result = readPktLine(data, pos) catch break;
        pos += result.bytes_consumed;

        switch (result.packet_type) {
            .flush => break,
            .delim, .response_end => continue,
            .data => {
                // Strip trailing newline if present
                var payload = result.data;
                if (payload.len > 0 and payload[payload.len - 1] == '\n') {
                    payload = payload[0 .. payload.len - 1];
                }
                try lines.append(payload);
            },
        }
    }

    return ReadAllResult{
        .lines = lines,
        .bytes_consumed = pos,
    };
}

pub const ReadAllResult = struct {
    lines: std.array_list.Managed([]const u8),
    bytes_consumed: usize,

    pub fn deinit(self: *ReadAllResult) void {
        self.lines.deinit();
    }
};

/// Demultiplex side-band data from a pkt-line payload.
/// The first byte of the payload indicates the band.
pub fn demuxSideBand(payload: []const u8) PktLineError!SideBandResult {
    if (payload.len < 1) return PktLineError.InvalidSideBand;

    const band_byte = payload[0];
    const rest = payload[1..];

    return switch (band_byte) {
        1 => SideBandResult{ .band = .pack_data, .data = rest },
        2 => SideBandResult{ .band = .progress, .data = rest },
        3 => SideBandResult{ .band = .err, .data = rest },
        else => PktLineError.InvalidSideBand,
    };
}

/// Read side-band demuxed pack data from a buffer.
/// Concatenates all band-1 data, writes band-2 to progress_buf.
/// Returns the pack data and total bytes consumed from input.
pub fn readSideBandData(
    allocator: std.mem.Allocator,
    data: []const u8,
) !SideBandReadResult {
    var pack_data = std.array_list.Managed(u8).init(allocator);
    errdefer pack_data.deinit();

    var progress = std.array_list.Managed(u8).init(allocator);
    errdefer progress.deinit();

    var pos: usize = 0;
    while (pos < data.len) {
        const pkt = readPktLine(data, pos) catch break;
        pos += pkt.bytes_consumed;

        switch (pkt.packet_type) {
            .flush => break,
            .delim, .response_end => continue,
            .data => {
                if (pkt.data.len == 0) continue;

                const sb = demuxSideBand(pkt.data) catch {
                    // If not side-band encoded, treat entire payload as pack data
                    try pack_data.appendSlice(pkt.data);
                    continue;
                };

                switch (sb.band) {
                    .pack_data => try pack_data.appendSlice(sb.data),
                    .progress => try progress.appendSlice(sb.data),
                    .err => {
                        // Server error -- errdefer will clean up pack_data and progress
                        return PktLineError.ServerError;
                    },
                }
            },
        }
    }

    return SideBandReadResult{
        .pack_data = pack_data,
        .progress = progress,
        .bytes_consumed = pos,
    };
}

pub const SideBandReadResult = struct {
    pack_data: std.array_list.Managed(u8),
    progress: std.array_list.Managed(u8),
    bytes_consumed: usize,

    pub fn deinit(self: *SideBandReadResult) void {
        self.pack_data.deinit();
        self.progress.deinit();
    }
};

/// Format a pkt-line string with a trailing newline.
/// Useful for sending commands like "want OID\n".
pub fn formatPktLine(buf: []u8, comptime fmt: []const u8, args: anytype) PktLineError!usize {
    // Format into a temporary area starting at offset 4
    if (buf.len < 5) return PktLineError.BufferTooSmall;

    var fbs = std.io.fixedBufferStream(buf[4..]);
    const writer = fbs.writer();
    writer.print(fmt, args) catch return PktLineError.BufferTooSmall;
    const data_len = fbs.pos;

    const total_len = data_len + 4;
    if (total_len > MAX_PKT_LEN) return PktLineError.PktLineTooLarge;

    // Write the length prefix
    const hex_chars = "0123456789abcdef";
    buf[0] = hex_chars[(total_len >> 12) & 0xf];
    buf[1] = hex_chars[(total_len >> 8) & 0xf];
    buf[2] = hex_chars[(total_len >> 4) & 0xf];
    buf[3] = hex_chars[total_len & 0xf];

    return total_len;
}

/// Format a pkt-line and append to a dynamic list.
pub fn formatPktLineList(list: *std.array_list.Managed(u8), comptime fmt: []const u8, args: anytype) !void {
    var tmp_buf: [MAX_PKT_LEN]u8 = undefined;
    const n = try formatPktLine(&tmp_buf, fmt, args);
    try list.appendSlice(tmp_buf[0..n]);
}

// --- Internal helpers ---

/// Parse a 4-character hex string into a u16 value.
fn parseHex4(hex: *const [4]u8) !u16 {
    var result: u16 = 0;
    for (hex) |c| {
        const val: u16 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return PktLineError.InvalidHexChar,
        };
        result = (result << 4) | val;
    }
    return result;
}

// --- Tests ---

test "writePktLine basic" {
    var buf: [256]u8 = undefined;
    const n = try writePktLine(&buf, "hello\n");
    try std.testing.expectEqual(@as(usize, 10), n);
    try std.testing.expectEqualStrings("000ahello\n", buf[0..10]);
}

test "writeFlush" {
    var buf: [4]u8 = undefined;
    const n = try writeFlush(&buf);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("0000", &buf);
}

test "writeDelim" {
    var buf: [4]u8 = undefined;
    const n = try writeDelim(&buf);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("0001", &buf);
}

test "readPktLine data" {
    const input = "000ahello\n0000";
    const result = try readPktLine(input, 0);
    try std.testing.expectEqual(PacketType.data, result.packet_type);
    try std.testing.expectEqualStrings("hello\n", result.data);
    try std.testing.expectEqual(@as(usize, 10), result.bytes_consumed);

    // Read the flush after it
    const flush = try readPktLine(input, 10);
    try std.testing.expectEqual(PacketType.flush, flush.packet_type);
    try std.testing.expectEqual(@as(usize, 4), flush.bytes_consumed);
}

test "readPktLine flush" {
    const result = try readPktLine("0000", 0);
    try std.testing.expectEqual(PacketType.flush, result.packet_type);
}

test "readPktLine delim" {
    const result = try readPktLine("0001", 0);
    try std.testing.expectEqual(PacketType.delim, result.packet_type);
}

test "readPktLine response_end" {
    const result = try readPktLine("0002", 0);
    try std.testing.expectEqual(PacketType.response_end, result.packet_type);
}

test "demuxSideBand" {
    const payload = "\x01pack-data-here";
    const result = try demuxSideBand(payload);
    try std.testing.expectEqual(SideBand.pack_data, result.band);
    try std.testing.expectEqualStrings("pack-data-here", result.data);
}

test "demuxSideBand progress" {
    const payload = "\x02remote: Counting objects\n";
    const result = try demuxSideBand(payload);
    try std.testing.expectEqual(SideBand.progress, result.band);
}

test "formatPktLine" {
    var buf: [256]u8 = undefined;
    const n = try formatPktLine(&buf, "want {s}\n", .{"abc123"});
    try std.testing.expect(n > 4);
    // Verify the length prefix
    const result = try readPktLine(&buf, 0);
    try std.testing.expectEqual(PacketType.data, result.packet_type);
    try std.testing.expectEqualStrings("want abc123\n", result.data);
}

test "writePktLineList" {
    var list = std.array_list.Managed(u8).init(std.testing.allocator);
    defer list.deinit();

    try writePktLineList(&list, "hello\n");
    try std.testing.expectEqualStrings("000ahello\n", list.items);
}

test "parseHex4" {
    try std.testing.expectEqual(@as(u16, 0x000a), try parseHex4("000a"));
    try std.testing.expectEqual(@as(u16, 0xffff), try parseHex4("ffff"));
    try std.testing.expectEqual(@as(u16, 0x0000), try parseHex4("0000"));
    try std.testing.expectEqual(@as(u16, 0x0004), try parseHex4("0004"));
}
