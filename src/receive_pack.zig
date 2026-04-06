const std = @import("std");
const types = @import("types.zig");
const pkt_line = @import("pkt_line.zig");
const capabilities = @import("capabilities.zig");
const transport_mod = @import("transport.zig");

/// Client-side receive-pack protocol (for push).
///
/// Implements the client side of the git receive-pack protocol, used to
/// upload objects to a remote repository:
///
/// 1. Reference discovery from server
/// 2. Send update commands: "OLD_OID NEW_OID refname"
/// 3. Send pack data containing the objects to push
/// 4. Read result status from server
/// 5. Handle report-status capability

const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Status of a single ref update.
pub const RefUpdateStatus = enum {
    ok,
    rejected_non_fast_forward,
    rejected_already_exists,
    rejected_nodelete,
    rejected_other,
    error_other,
};

/// Result of a ref update from the server.
pub const RefUpdateResult = struct {
    ref_name: []const u8,
    status: RefUpdateStatus,
    message: ?[]const u8,
};

/// Overall push result.
pub const PushReport = struct {
    allocator: std.mem.Allocator,
    ok: bool,
    ref_results: std.array_list.Managed(RefUpdateResult),
    server_message: ?[]u8,

    pub fn init(allocator: std.mem.Allocator) PushReport {
        return .{
            .allocator = allocator,
            .ok = true,
            .ref_results = std.array_list.Managed(RefUpdateResult).init(allocator),
            .server_message = null,
        };
    }

    pub fn deinit(self: *PushReport) void {
        for (self.ref_results.items) |*r| {
            self.allocator.free(@constCast(r.ref_name));
            if (r.message) |m| self.allocator.free(@constCast(m));
        }
        self.ref_results.deinit();
        if (self.server_message) |m| self.allocator.free(m);
    }
};

/// Receive pack session state.
pub const ReceivePackSession = struct {
    allocator: std.mem.Allocator,
    server_caps: capabilities.Capabilities,
    refs: std.array_list.Managed(AdvertisedRef),
    use_side_band_64k: bool,
    use_report_status: bool,
    use_ofs_delta: bool,
    use_delete_refs: bool,
    use_push_options: bool,
    use_quiet: bool,
    use_atomic: bool,

    pub const AdvertisedRef = struct {
        oid: types.ObjectId,
        name: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) ReceivePackSession {
        return .{
            .allocator = allocator,
            .server_caps = capabilities.Capabilities.init(allocator),
            .refs = std.array_list.Managed(AdvertisedRef).init(allocator),
            .use_side_band_64k = false,
            .use_report_status = false,
            .use_ofs_delta = false,
            .use_delete_refs = false,
            .use_push_options = false,
            .use_quiet = false,
            .use_atomic = false,
        };
    }

    pub fn deinit(self: *ReceivePackSession) void {
        self.server_caps.deinit();
        for (self.refs.items) |*r| {
            self.allocator.free(@constCast(r.name));
        }
        self.refs.deinit();
    }

    /// Parse the reference advertisement from the server for receive-pack.
    pub fn parseRefAdvertisement(self: *ReceivePackSession, data: []const u8) !void {
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

                    // Skip service header
                    if (std.mem.startsWith(u8, payload, "# ")) {
                        continue;
                    }

                    if (first_line) {
                        first_line = false;
                        // Parse capabilities from NUL-separated part
                        if (capabilities.extractCapsFromFirstLine(pkt.data)) |caps_str| {
                            try self.server_caps.parse(caps_str);
                        }
                        self.negotiateFeatures();
                    }

                    // Parse ref entry: OID SP refname
                    if (payload.len < 41) continue;
                    if (payload[40] != ' ') continue;

                    const oid_hex = payload[0..40];
                    var ref_name = payload[41..];

                    // Strip NUL and capabilities
                    if (std.mem.indexOfScalar(u8, ref_name, 0)) |nul_pos| {
                        ref_name = ref_name[0..nul_pos];
                    }

                    const oid = types.ObjectId.fromHex(oid_hex) catch continue;
                    const name_copy = try self.allocator.alloc(u8, ref_name.len);
                    @memcpy(name_copy, ref_name);

                    try self.refs.append(.{
                        .oid = oid,
                        .name = name_copy,
                    });
                },
            }
        }
    }

    /// Negotiate which features to use based on server capabilities.
    fn negotiateFeatures(self: *ReceivePackSession) void {
        self.use_side_band_64k = self.server_caps.has("side-band-64k");
        self.use_report_status = self.server_caps.has("report-status");
        self.use_ofs_delta = self.server_caps.has("ofs-delta");
        self.use_delete_refs = self.server_caps.has("delete-refs");
        self.use_push_options = self.server_caps.has("push-options");
        self.use_quiet = self.server_caps.has("quiet");
        self.use_atomic = self.server_caps.has("atomic");
    }

    /// Find a remote ref by name.
    pub fn findRef(self: *const ReceivePackSession, name: []const u8) ?*const AdvertisedRef {
        for (self.refs.items) |*r| {
            if (std.mem.eql(u8, r.name, name)) return r;
        }
        return null;
    }

    /// Get the old OID for a ref, or ZERO if it doesn't exist.
    pub fn getOldOid(self: *const ReceivePackSession, ref_name: []const u8) types.ObjectId {
        if (self.findRef(ref_name)) |r| {
            return r.oid;
        }
        return types.ObjectId.ZERO;
    }

    /// Build the update commands for push.
    /// Returns pkt-line formatted data to send to the server.
    pub fn buildUpdateCommands(
        self: *ReceivePackSession,
        updates: []const transport_mod.RefUpdate,
    ) ![]u8 {
        var request = std.array_list.Managed(u8).init(self.allocator);
        errdefer request.deinit();

        var first = true;
        for (updates) |update| {
            const old_hex = update.old_oid.toHex();
            const new_hex = update.new_oid.toHex();

            if (first) {
                first = false;
                // First command includes capabilities
                var caps_buf: [512]u8 = undefined;
                const caps_str = self.buildClientCaps(&caps_buf);
                if (caps_str.len > 0) {
                    try pkt_line.formatPktLineList(
                        &request,
                        "{s} {s} {s}\x00{s}\n",
                        .{ &old_hex, &new_hex, update.ref_name, caps_str },
                    );
                } else {
                    try pkt_line.formatPktLineList(
                        &request,
                        "{s} {s} {s}\n",
                        .{ &old_hex, &new_hex, update.ref_name },
                    );
                }
            } else {
                try pkt_line.formatPktLineList(
                    &request,
                    "{s} {s} {s}\n",
                    .{ &old_hex, &new_hex, update.ref_name },
                );
            }
        }

        try pkt_line.writeFlushList(&request);

        return request.toOwnedSlice();
    }

    /// Build the client capabilities string for receive-pack.
    fn buildClientCaps(self: *const ReceivePackSession, buf: []u8) []const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        var wrote_one = false;

        const cap_list = [_]struct { flag: bool, name: []const u8 }{
            .{ .flag = self.use_report_status, .name = "report-status" },
            .{ .flag = self.use_side_band_64k, .name = "side-band-64k" },
            .{ .flag = self.use_ofs_delta, .name = "ofs-delta" },
            .{ .flag = self.use_quiet, .name = "quiet" },
            .{ .flag = self.use_atomic, .name = "atomic" },
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

    /// Check if a ref update is a delete operation.
    pub fn isDelete(update: *const transport_mod.RefUpdate) bool {
        return std.mem.eql(u8, &update.new_oid.bytes, &types.ObjectId.ZERO.bytes);
    }

    /// Check if a ref update is a create operation.
    pub fn isCreate(update: *const transport_mod.RefUpdate) bool {
        return std.mem.eql(u8, &update.old_oid.bytes, &types.ObjectId.ZERO.bytes);
    }
};

/// Parse the report-status response from the server.
/// Format:
///   unpack ok\n  or  unpack <error-msg>\n
///   ok <refname>\n  or  ng <refname> <reason>\n
///   ...
///   flush
pub fn parseReportStatus(allocator: std.mem.Allocator, data: []const u8) !PushReport {
    var report = PushReport.init(allocator);
    errdefer report.deinit();

    var pos: usize = 0;

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

                // Handle side-band demultiplexing
                if (payload.len > 0) {
                    const first = payload[0];
                    if (first == 1) {
                        // Side-band data channel - these are the actual status lines
                        payload = payload[1..];
                        // The data channel might contain multiple pkt-lines
                        try parseStatusLines(allocator, payload, &report);
                        continue;
                    } else if (first == 2) {
                        // Progress channel, skip
                        continue;
                    } else if (first == 3) {
                        // Error channel
                        report.ok = false;
                        if (payload.len > 1) {
                            const msg_copy = try allocator.alloc(u8, payload.len - 1);
                            @memcpy(msg_copy, payload[1..]);
                            if (report.server_message) |old| allocator.free(old);
                            report.server_message = msg_copy;
                        }
                        continue;
                    }
                }

                // Direct (non side-band) status parsing
                try parseOneStatusLine(allocator, payload, &report);
            },
        }
    }

    return report;
}

/// Parse status lines from a data buffer (may contain embedded pkt-lines).
fn parseStatusLines(allocator: std.mem.Allocator, data: []const u8, report: *PushReport) !void {
    // Try to parse as pkt-lines first
    var inner_pos: usize = 0;
    while (inner_pos < data.len) {
        const inner_pkt = pkt_line.readPktLine(data, inner_pos) catch {
            // Not pkt-line encoded, try direct parsing
            try parseOneStatusLine(allocator, data, report);
            break;
        };
        inner_pos += inner_pkt.bytes_consumed;

        switch (inner_pkt.packet_type) {
            .flush => break,
            .delim, .response_end => continue,
            .data => {
                var inner_payload = inner_pkt.data;
                if (inner_payload.len > 0 and inner_payload[inner_payload.len - 1] == '\n') {
                    inner_payload = inner_payload[0 .. inner_payload.len - 1];
                }
                try parseOneStatusLine(allocator, inner_payload, report);
            },
        }
    }
}

/// Parse a single status line.
fn parseOneStatusLine(allocator: std.mem.Allocator, line: []const u8, report: *PushReport) !void {
    if (std.mem.startsWith(u8, line, "unpack ")) {
        const rest = line[7..];
        if (!std.mem.eql(u8, rest, "ok")) {
            report.ok = false;
            const msg_copy = try allocator.alloc(u8, rest.len);
            @memcpy(msg_copy, rest);
            if (report.server_message) |old| allocator.free(old);
            report.server_message = msg_copy;
        }
    } else if (std.mem.startsWith(u8, line, "ok ")) {
        const ref_name = line[3..];
        const name_copy = try allocator.alloc(u8, ref_name.len);
        @memcpy(name_copy, ref_name);
        try report.ref_results.append(.{
            .ref_name = name_copy,
            .status = .ok,
            .message = null,
        });
    } else if (std.mem.startsWith(u8, line, "ng ")) {
        const rest = line[3..];
        // Format: "ng <refname> <reason>"
        if (std.mem.indexOfScalar(u8, rest, ' ')) |space_pos| {
            const ref_name = rest[0..space_pos];
            const reason = rest[space_pos + 1 ..];

            const name_copy = try allocator.alloc(u8, ref_name.len);
            @memcpy(name_copy, ref_name);
            const reason_copy = try allocator.alloc(u8, reason.len);
            @memcpy(reason_copy, reason);

            const status: RefUpdateStatus = if (std.mem.indexOf(u8, reason, "non-fast-forward") != null)
                .rejected_non_fast_forward
            else if (std.mem.indexOf(u8, reason, "already exists") != null)
                .rejected_already_exists
            else
                .rejected_other;

            report.ok = false;
            try report.ref_results.append(.{
                .ref_name = name_copy,
                .status = status,
                .message = reason_copy,
            });
        } else {
            // Just ref name, no reason
            const name_copy = try allocator.alloc(u8, rest.len);
            @memcpy(name_copy, rest);
            report.ok = false;
            try report.ref_results.append(.{
                .ref_name = name_copy,
                .status = .error_other,
                .message = null,
            });
        }
    }
}

/// Parse the report-status response that may arrive via side-band encoding.
pub fn parseReportStatusSideBand(allocator: std.mem.Allocator, data: []const u8) !PushReport {
    // First try to demux side-band data
    var status_data = std.array_list.Managed(u8).init(allocator);
    defer status_data.deinit();

    var pos: usize = 0;
    var found_side_band = false;

    while (pos < data.len) {
        const pkt = pkt_line.readPktLine(data, pos) catch break;
        pos += pkt.bytes_consumed;

        switch (pkt.packet_type) {
            .flush => break,
            .delim, .response_end => continue,
            .data => {
                if (pkt.data.len > 0 and pkt.data[0] >= 1 and pkt.data[0] <= 3) {
                    found_side_band = true;
                    if (pkt.data[0] == 1) {
                        try status_data.appendSlice(pkt.data[1..]);
                    }
                } else {
                    try status_data.appendSlice(pkt.data);
                }
            },
        }
    }

    if (found_side_band and status_data.items.len > 0) {
        return parseReportStatus(allocator, status_data.items);
    }

    return parseReportStatus(allocator, data);
}

/// Build a ref update for creating a new branch.
pub fn createRefUpdate(new_oid: types.ObjectId, ref_name: []const u8) transport_mod.RefUpdate {
    return .{
        .old_oid = types.ObjectId.ZERO,
        .new_oid = new_oid,
        .ref_name = ref_name,
        .force = false,
    };
}

/// Build a ref update for updating an existing branch.
pub fn updateRefUpdate(old_oid: types.ObjectId, new_oid: types.ObjectId, ref_name: []const u8) transport_mod.RefUpdate {
    return .{
        .old_oid = old_oid,
        .new_oid = new_oid,
        .ref_name = ref_name,
        .force = false,
    };
}

/// Build a ref update for deleting a branch.
pub fn deleteRefUpdate(old_oid: types.ObjectId, ref_name: []const u8) transport_mod.RefUpdate {
    return .{
        .old_oid = old_oid,
        .new_oid = types.ObjectId.ZERO,
        .ref_name = ref_name,
        .force = false,
    };
}

/// Build a ref update with force flag.
pub fn forceRefUpdate(old_oid: types.ObjectId, new_oid: types.ObjectId, ref_name: []const u8) transport_mod.RefUpdate {
    return .{
        .old_oid = old_oid,
        .new_oid = new_oid,
        .ref_name = ref_name,
        .force = true,
    };
}

// --- Tests ---

test "ReceivePackSession init/deinit" {
    var session = ReceivePackSession.init(std.testing.allocator);
    defer session.deinit();
    try std.testing.expectEqual(@as(usize, 0), session.refs.items.len);
}

test "parseReportStatus success" {
    // Build a simple report-status response
    var response = std.array_list.Managed(u8).init(std.testing.allocator);
    defer response.deinit();

    try pkt_line.writePktLineList(&response, "unpack ok\n");
    try pkt_line.writePktLineList(&response, "ok refs/heads/main\n");
    try pkt_line.writeFlushList(&response);

    var report = try parseReportStatus(std.testing.allocator, response.items);
    defer report.deinit();

    try std.testing.expect(report.ok);
    try std.testing.expectEqual(@as(usize, 1), report.ref_results.items.len);
    try std.testing.expectEqual(RefUpdateStatus.ok, report.ref_results.items[0].status);
}

test "parseReportStatus failure" {
    var response = std.array_list.Managed(u8).init(std.testing.allocator);
    defer response.deinit();

    try pkt_line.writePktLineList(&response, "unpack ok\n");
    try pkt_line.writePktLineList(&response, "ng refs/heads/main non-fast-forward\n");
    try pkt_line.writeFlushList(&response);

    var report = try parseReportStatus(std.testing.allocator, response.items);
    defer report.deinit();

    try std.testing.expect(!report.ok);
    try std.testing.expectEqual(@as(usize, 1), report.ref_results.items.len);
    try std.testing.expectEqual(RefUpdateStatus.rejected_non_fast_forward, report.ref_results.items[0].status);
}

test "createRefUpdate" {
    const oid = try types.ObjectId.fromHex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    const update = createRefUpdate(oid, "refs/heads/main");
    try std.testing.expect(update.old_oid.eql(&types.ObjectId.ZERO));
    try std.testing.expect(update.new_oid.eql(&oid));
    try std.testing.expectEqualStrings("refs/heads/main", update.ref_name);
}

test "deleteRefUpdate" {
    const oid = try types.ObjectId.fromHex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    const update = deleteRefUpdate(oid, "refs/heads/main");
    try std.testing.expect(update.new_oid.eql(&types.ObjectId.ZERO));
}

test "ReceivePackSession.isDelete" {
    const update = transport_mod.RefUpdate{
        .old_oid = try types.ObjectId.fromHex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"),
        .new_oid = types.ObjectId.ZERO,
        .ref_name = "refs/heads/main",
        .force = false,
    };
    try std.testing.expect(ReceivePackSession.isDelete(&update));
}

test "buildUpdateCommands" {
    var session = ReceivePackSession.init(std.testing.allocator);
    defer session.deinit();

    const old_oid = types.ObjectId.ZERO;
    const new_oid = try types.ObjectId.fromHex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");

    const updates = [_]transport_mod.RefUpdate{
        .{
            .old_oid = old_oid,
            .new_oid = new_oid,
            .ref_name = "refs/heads/main",
            .force = false,
        },
    };

    const data = try session.buildUpdateCommands(&updates);
    defer std.testing.allocator.free(data);

    try std.testing.expect(data.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, data, "refs/heads/main") != null);
}
