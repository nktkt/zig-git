const std = @import("std");
const types = @import("types.zig");
const pkt_line = @import("pkt_line.zig");
const capabilities = @import("capabilities.zig");
const transport_mod = @import("transport.zig");

/// Client-side upload-pack protocol (for fetch/clone).
///
/// Implements the client side of the git upload-pack protocol, used to
/// download objects from a remote repository:
///
/// 1. Reference discovery: parse advertised refs from server
/// 2. Want/have negotiation:
///    a. Send "want OID capabilities..." for refs we want
///    b. Send "have OID" for objects we already have
///    c. Receive ACK/NAK responses
///    d. Receive pack data
/// 3. Pack data receiver: read pack stream from server

const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Negotiation ACK type.
pub const AckType = enum {
    nak,
    ack,
    ack_continue,
    ack_common,
    ack_ready,
};

/// ACK response from server.
pub const AckResponse = struct {
    ack_type: AckType,
    oid: ?types.ObjectId,
};

/// Parsed ref advertisement.
pub const AdvertisedRef = struct {
    oid: types.ObjectId,
    name: []const u8,
    symref_target: ?[]const u8,
};

/// Upload pack session state.
pub const UploadPackSession = struct {
    allocator: std.mem.Allocator,
    server_caps: capabilities.Capabilities,
    refs: std.array_list.Managed(AdvertisedRef),
    shallow_oids: std.array_list.Managed(types.ObjectId),
    use_side_band_64k: bool,
    use_ofs_delta: bool,
    use_thin_pack: bool,
    use_include_tag: bool,
    use_no_done: bool,

    pub fn init(allocator: std.mem.Allocator) UploadPackSession {
        return .{
            .allocator = allocator,
            .server_caps = capabilities.Capabilities.init(allocator),
            .refs = std.array_list.Managed(AdvertisedRef).init(allocator),
            .shallow_oids = std.array_list.Managed(types.ObjectId).init(allocator),
            .use_side_band_64k = false,
            .use_ofs_delta = false,
            .use_thin_pack = false,
            .use_include_tag = false,
            .use_no_done = false,
        };
    }

    pub fn deinit(self: *UploadPackSession) void {
        self.server_caps.deinit();
        for (self.refs.items) |*r| {
            self.allocator.free(@constCast(r.name));
            if (r.symref_target) |t| self.allocator.free(@constCast(t));
        }
        self.refs.deinit();
        self.shallow_oids.deinit();
    }

    /// Parse the reference advertisement from the server.
    /// Input is the raw response data (already pkt-line formatted).
    pub fn parseRefAdvertisement(self: *UploadPackSession, data: []const u8) !void {
        var pos: usize = 0;
        var first_line = true;

        while (pos < data.len) {
            const pkt = pkt_line.readPktLine(data, pos) catch break;
            pos += pkt.bytes_consumed;

            switch (pkt.packet_type) {
                .flush => break,
                .delim, .response_end => continue,
                .data => {
                    var payload = pkt.data;
                    // Strip trailing LF
                    if (payload.len > 0 and payload[payload.len - 1] == '\n') {
                        payload = payload[0 .. payload.len - 1];
                    }

                    // First line may be "# service=git-upload-pack" (HTTP smart)
                    if (std.mem.startsWith(u8, payload, "# ")) {
                        continue;
                    }

                    if (first_line) {
                        first_line = false;
                        // Parse capabilities from NUL-separated part
                        if (capabilities.extractCapsFromFirstLine(pkt.data)) |caps_str| {
                            try self.server_caps.parse(caps_str);
                        }
                        // Negotiate features
                        self.negotiateFeatures();
                    }

                    // Parse ref entry
                    if (payload.len < 41) continue;
                    if (payload[40] != ' ') continue;

                    const oid_hex = payload[0..40];
                    var ref_name = payload[41..];

                    // Strip capabilities (NUL and everything after)
                    if (std.mem.indexOfScalar(u8, ref_name, 0)) |nul_pos| {
                        ref_name = ref_name[0..nul_pos];
                    }

                    const oid = types.ObjectId.fromHex(oid_hex) catch continue;
                    const name_copy = try self.allocator.alloc(u8, ref_name.len);
                    @memcpy(name_copy, ref_name);

                    // Check for symref in capabilities
                    var symref_target: ?[]const u8 = null;
                    if (std.mem.eql(u8, ref_name, "HEAD")) {
                        if (self.server_caps.getValue("symref")) |sv| {
                            // Format: HEAD:refs/heads/main
                            if (std.mem.startsWith(u8, sv, "HEAD:")) {
                                const target = sv[5..];
                                const target_copy = try self.allocator.alloc(u8, target.len);
                                @memcpy(target_copy, target);
                                symref_target = target_copy;
                            }
                        }
                    }

                    try self.refs.append(.{
                        .oid = oid,
                        .name = name_copy,
                        .symref_target = symref_target,
                    });
                },
            }
        }
    }

    /// Negotiate which features to use based on server capabilities.
    fn negotiateFeatures(self: *UploadPackSession) void {
        self.use_side_band_64k = self.server_caps.has("side-band-64k");
        self.use_ofs_delta = self.server_caps.has("ofs-delta");
        self.use_thin_pack = self.server_caps.has("thin-pack");
        self.use_include_tag = self.server_caps.has("include-tag");
        self.use_no_done = self.server_caps.has("no-done") and self.server_caps.has("multi_ack_detailed");
    }

    /// Build the want/have negotiation request.
    /// Returns the pkt-line formatted request data.
    pub fn buildNegotiationRequest(
        self: *UploadPackSession,
        want_oids: []const types.ObjectId,
        have_oids: []const types.ObjectId,
    ) ![]u8 {
        var request = std.array_list.Managed(u8).init(self.allocator);
        errdefer request.deinit();

        if (want_oids.len == 0) return request.toOwnedSlice();

        // Send want lines
        var first_want = true;
        for (want_oids) |oid| {
            const hex = oid.toHex();

            if (first_want) {
                first_want = false;
                // First want line includes capabilities
                var caps_buf: [512]u8 = undefined;
                const caps_str = self.buildClientCaps(&caps_buf);
                try pkt_line.formatPktLineList(&request, "want {s} {s}\n", .{ &hex, caps_str });
            } else {
                try pkt_line.formatPktLineList(&request, "want {s}\n", .{&hex});
            }
        }

        // Flush after wants (required by protocol)
        try pkt_line.writeFlushList(&request);

        // Send have lines
        for (have_oids) |oid| {
            const hex = oid.toHex();
            try pkt_line.formatPktLineList(&request, "have {s}\n", .{&hex});
        }

        // Send done
        try pkt_line.writePktLineList(&request, "done\n");

        return request.toOwnedSlice();
    }

    /// Build the client capabilities string.
    fn buildClientCaps(self: *const UploadPackSession, buf: []u8) []const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        var wrote_one = false;

        const cap_list = [_]struct { flag: bool, name: []const u8 }{
            .{ .flag = true, .name = "multi_ack_detailed" },
            .{ .flag = self.use_side_band_64k, .name = "side-band-64k" },
            .{ .flag = self.use_thin_pack, .name = "thin-pack" },
            .{ .flag = self.use_ofs_delta, .name = "ofs-delta" },
            .{ .flag = self.use_include_tag, .name = "include-tag" },
            .{ .flag = self.use_no_done, .name = "no-done" },
            .{ .flag = true, .name = "no-progress" },
            .{ .flag = true, .name = "agent=zig-git/0.2.0" },
        };

        for (cap_list) |cap| {
            if (cap.flag) {
                if (wrote_one) writer.writeByte(' ') catch break;
                writer.writeAll(cap.name) catch break;
                wrote_one = true;
            }
        }

        return buf[0..fbs.pos];
    }

    /// Find a ref by name.
    pub fn findRef(self: *const UploadPackSession, name: []const u8) ?*const AdvertisedRef {
        for (self.refs.items) |*r| {
            if (std.mem.eql(u8, r.name, name)) return r;
        }
        return null;
    }

    /// Get HEAD's symref target, if available.
    pub fn getHeadSymref(self: *const UploadPackSession) ?[]const u8 {
        if (self.findRef("HEAD")) |head| {
            return head.symref_target;
        }
        return null;
    }

    /// Get all branch refs (refs/heads/*).
    pub fn getBranchRefs(self: *const UploadPackSession) []const AdvertisedRef {
        // Can't filter in-place without allocation, so return all and let caller filter
        return self.refs.items;
    }
};

/// Parse ACK/NAK responses from the server during negotiation.
pub fn parseAckResponse(line: []const u8) AckResponse {
    var l = line;
    if (l.len > 0 and l[l.len - 1] == '\n') {
        l = l[0 .. l.len - 1];
    }

    if (std.mem.eql(u8, l, "NAK")) {
        return .{ .ack_type = .nak, .oid = null };
    }

    if (std.mem.startsWith(u8, l, "ACK ")) {
        if (l.len >= 44) { // "ACK " + 40 hex
            const oid = types.ObjectId.fromHex(l[4..44]) catch {
                return .{ .ack_type = .nak, .oid = null };
            };

            // Check for qualifier
            if (l.len > 44) {
                const qualifier = l[45..];
                if (std.mem.eql(u8, qualifier, "continue")) {
                    return .{ .ack_type = .ack_continue, .oid = oid };
                } else if (std.mem.eql(u8, qualifier, "common")) {
                    return .{ .ack_type = .ack_common, .oid = oid };
                } else if (std.mem.eql(u8, qualifier, "ready")) {
                    return .{ .ack_type = .ack_ready, .oid = oid };
                }
            }

            return .{ .ack_type = .ack, .oid = oid };
        }
    }

    return .{ .ack_type = .nak, .oid = null };
}

/// Parse server response to negotiation.
/// Returns ACK responses and extracts pack data start position.
pub fn parseNegotiationResponse(
    allocator: std.mem.Allocator,
    data: []const u8,
) !NegotiationResult {
    var acks = std.array_list.Managed(AckResponse).init(allocator);
    errdefer acks.deinit();

    var pos: usize = 0;
    var pack_start: ?usize = null;

    while (pos < data.len) {
        // Check if we've hit the pack data (starts with "PACK")
        if (pos + 4 <= data.len and std.mem.eql(u8, data[pos..][0..4], "PACK")) {
            pack_start = pos;
            break;
        }

        const pkt = pkt_line.readPktLine(data, pos) catch break;
        pos += pkt.bytes_consumed;

        switch (pkt.packet_type) {
            .flush => continue,
            .delim, .response_end => continue,
            .data => {
                var payload = pkt.data;
                // Check for side-band
                if (payload.len > 0) {
                    const first = payload[0];
                    if (first == 1) {
                        // Side-band pack data
                        const rest = payload[1..];
                        if (rest.len >= 4 and std.mem.eql(u8, rest[0..4], "PACK")) {
                            // Found pack data via side-band
                            // Return position of the pkt-line containing pack data
                            pack_start = pos - pkt.bytes_consumed;
                            break;
                        }
                        continue;
                    } else if (first == 2) {
                        // Progress message, skip
                        continue;
                    } else if (first == 3) {
                        // Error message
                        return error.ServerError;
                    }
                }

                // Parse ACK/NAK
                const ack = parseAckResponse(payload);
                try acks.append(ack);
            },
        }
    }

    return NegotiationResult{
        .acks = acks,
        .pack_data_offset = pack_start,
    };
}

pub const NegotiationResult = struct {
    acks: std.array_list.Managed(AckResponse),
    pack_data_offset: ?usize,

    pub fn deinit(self: *NegotiationResult) void {
        self.acks.deinit();
    }

    /// Check if we got any ACK (not NAK).
    pub fn hasAck(self: *const NegotiationResult) bool {
        for (self.acks.items) |ack| {
            if (ack.ack_type != .nak) return true;
        }
        return false;
    }

    /// Check if the server is ready to send pack data.
    pub fn isReady(self: *const NegotiationResult) bool {
        for (self.acks.items) |ack| {
            if (ack.ack_type == .ack_ready or ack.ack_type == .ack) return true;
        }
        return false;
    }
};

/// Extract pack data from a server response that may use side-band encoding.
/// Returns just the raw pack bytes (PACK header + data).
pub fn extractPackData(
    allocator: std.mem.Allocator,
    data: []const u8,
    use_side_band: bool,
) ![]u8 {
    if (!use_side_band) {
        // No side-band: find PACK header and return everything from there
        if (std.mem.indexOf(u8, data, "PACK")) |pack_pos| {
            const result = try allocator.alloc(u8, data.len - pack_pos);
            @memcpy(result, data[pack_pos..]);
            return result;
        }
        return error.NoPackData;
    }

    // Side-band encoded: demux pkt-lines and concatenate band-1 data
    var pack_buf = std.array_list.Managed(u8).init(allocator);
    errdefer pack_buf.deinit();

    var pos: usize = 0;
    while (pos < data.len) {
        // Check for raw PACK data
        if (pos + 4 <= data.len and std.mem.eql(u8, data[pos..][0..4], "PACK")) {
            try pack_buf.appendSlice(data[pos..]);
            break;
        }

        const pkt = pkt_line.readPktLine(data, pos) catch break;
        pos += pkt.bytes_consumed;

        switch (pkt.packet_type) {
            .flush => break,
            .delim, .response_end => continue,
            .data => {
                if (pkt.data.len == 0) continue;

                const band = pkt.data[0];
                const rest = pkt.data[1..];

                switch (band) {
                    1 => try pack_buf.appendSlice(rest), // pack data
                    2 => {}, // progress, ignore
                    3 => return error.ServerError, // error
                    else => {
                        // Might not be side-band encoded after all
                        try pack_buf.appendSlice(pkt.data);
                    },
                }
            },
        }
    }

    if (pack_buf.items.len == 0) return error.NoPackData;

    return pack_buf.toOwnedSlice();
}

/// Build a shallow/deepen request for shallow clone.
pub fn buildShallowRequest(
    allocator: std.mem.Allocator,
    depth: ?u32,
    deepen_since: ?[]const u8,
    deepen_not: ?[]const u8,
) !?[]u8 {
    if (depth == null and deepen_since == null and deepen_not == null) return null;

    var request = std.array_list.Managed(u8).init(allocator);
    errdefer request.deinit();

    if (depth) |d| {
        try pkt_line.formatPktLineList(&request, "deepen {d}\n", .{d});
    }

    if (deepen_since) |since| {
        try pkt_line.formatPktLineList(&request, "deepen-since {s}\n", .{since});
    }

    if (deepen_not) |not_ref| {
        try pkt_line.formatPktLineList(&request, "deepen-not {s}\n", .{not_ref});
    }

    return request.toOwnedSlice();
}

/// Convert a RefDiscoveryResult (from transport) into an UploadPackSession with parsed refs.
pub fn sessionFromDiscovery(
    allocator: std.mem.Allocator,
    discovery: *const transport_mod.RefDiscoveryResult,
) !UploadPackSession {
    var session = UploadPackSession.init(allocator);
    errdefer session.deinit();

    // Parse capabilities if available
    if (discovery.capabilities_raw) |caps_raw| {
        try session.server_caps.parse(caps_raw);
        session.negotiateFeatures();
    }

    // Copy refs
    for (discovery.refs) |*r| {
        const name_copy = try allocator.alloc(u8, r.name.len);
        @memcpy(name_copy, r.name);

        var symref_target: ?[]const u8 = null;
        if (std.mem.eql(u8, r.name, "HEAD")) {
            if (discovery.head_symref) |hs| {
                const hs_copy = try allocator.alloc(u8, hs.len);
                @memcpy(hs_copy, hs);
                symref_target = hs_copy;
            }
        }

        try session.refs.append(.{
            .oid = r.oid,
            .name = name_copy,
            .symref_target = symref_target,
        });
    }

    return session;
}

// --- Tests ---

test "parseAckResponse NAK" {
    const result = parseAckResponse("NAK\n");
    try std.testing.expectEqual(AckType.nak, result.ack_type);
    try std.testing.expect(result.oid == null);
}

test "parseAckResponse ACK" {
    const result = parseAckResponse("ACK e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\n");
    try std.testing.expectEqual(AckType.ack, result.ack_type);
    try std.testing.expect(result.oid != null);
}

test "parseAckResponse ACK continue" {
    const result = parseAckResponse("ACK e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 continue\n");
    try std.testing.expectEqual(AckType.ack_continue, result.ack_type);
}

test "parseAckResponse ACK ready" {
    const result = parseAckResponse("ACK e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 ready\n");
    try std.testing.expectEqual(AckType.ack_ready, result.ack_type);
}

test "UploadPackSession init/deinit" {
    var session = UploadPackSession.init(std.testing.allocator);
    defer session.deinit();
    try std.testing.expectEqual(@as(usize, 0), session.refs.items.len);
}

test "buildNegotiationRequest" {
    var session = UploadPackSession.init(std.testing.allocator);
    defer session.deinit();

    const want = try types.ObjectId.fromHex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    const wants = [_]types.ObjectId{want};
    const haves = [_]types.ObjectId{};

    const request = try session.buildNegotiationRequest(&wants, &haves);
    defer std.testing.allocator.free(request);

    try std.testing.expect(request.len > 0);
    // Should contain "want" and "done"
    try std.testing.expect(std.mem.indexOf(u8, request, "want") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "done") != null);
}

test "buildShallowRequest" {
    const result = try buildShallowRequest(std.testing.allocator, 1, null, null);
    if (result) |r| {
        defer std.testing.allocator.free(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "deepen 1") != null);
    }
}
