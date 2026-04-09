const std = @import("std");
const pkt_line = @import("pkt_line.zig");
const capabilities = @import("capabilities.zig");
const types = @import("types.zig");

/// Git protocol v2 implementation.
///
/// Protocol v2 is a more structured version of the git transport protocol.
/// Instead of the server dumping all refs on connect, the client explicitly
/// requests what it needs via commands:
///   - ls-refs: list references
///   - fetch: download objects
///   - push: upload objects (via receive-pack)
///
/// Each command is sent as a pkt-line sequence:
///   command=<name> LF
///   <capabilities> LF
///   0001 (delimiter)
///   <arguments> LF
///   0000 (flush)

/// Protocol version constants.
pub const PROTOCOL_VERSION_1 = 1;
pub const PROTOCOL_VERSION_2 = 2;

/// V2 command names.
pub const Command = enum {
    ls_refs,
    fetch,
    push,
    object_info,

    pub fn toString(self: Command) []const u8 {
        return switch (self) {
            .ls_refs => "ls-refs",
            .fetch => "fetch",
            .push => "push",
            .object_info => "object-info",
        };
    }

    pub fn fromString(s: []const u8) ?Command {
        if (std.mem.eql(u8, s, "ls-refs")) return .ls_refs;
        if (std.mem.eql(u8, s, "fetch")) return .fetch;
        if (std.mem.eql(u8, s, "push")) return .push;
        if (std.mem.eql(u8, s, "object-info")) return .object_info;
        return null;
    }
};

/// Fetch command arguments.
pub const FetchArgs = struct {
    wants: std.array_list.Managed([40]u8),
    haves: std.array_list.Managed([40]u8),
    done: bool,
    thin_pack: bool,
    ofs_delta: bool,
    include_tag: bool,
    shallow: std.array_list.Managed([40]u8),
    deepen: ?u32,
    deepen_since: ?i64,
    deepen_not: std.array_list.Managed([]const u8),
    filter_spec: ?[]const u8,
    no_progress: bool,
    /// Server options to send.
    server_options: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator) FetchArgs {
        return .{
            .wants = std.array_list.Managed([40]u8).init(allocator),
            .haves = std.array_list.Managed([40]u8).init(allocator),
            .done = false,
            .thin_pack = true,
            .ofs_delta = true,
            .include_tag = true,
            .shallow = std.array_list.Managed([40]u8).init(allocator),
            .deepen = null,
            .deepen_since = null,
            .deepen_not = std.array_list.Managed([]const u8).init(allocator),
            .filter_spec = null,
            .no_progress = false,
            .server_options = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *FetchArgs) void {
        self.wants.deinit();
        self.haves.deinit();
        self.shallow.deinit();
        self.deepen_not.deinit();
        self.server_options.deinit();
    }

    pub fn addWant(self: *FetchArgs, oid_hex: *const [40]u8) !void {
        try self.wants.append(oid_hex.*);
    }

    pub fn addHave(self: *FetchArgs, oid_hex: *const [40]u8) !void {
        try self.haves.append(oid_hex.*);
    }

    pub fn addShallow(self: *FetchArgs, oid_hex: *const [40]u8) !void {
        try self.shallow.append(oid_hex.*);
    }

    pub fn setDeepen(self: *FetchArgs, depth: u32) void {
        self.deepen = depth;
    }

    pub fn setDeepenSince(self: *FetchArgs, timestamp: i64) void {
        self.deepen_since = timestamp;
    }
};

/// ls-refs command arguments.
pub const LsRefsArgs = struct {
    /// Request peeled object IDs for annotated tags.
    peel: bool,
    /// Request symref targets.
    symrefs: bool,
    /// Ref prefixes to filter by (server only sends matching refs).
    ref_prefixes: std.array_list.Managed([]const u8),
    /// Request unborn symref info.
    unborn: bool,

    pub fn init(allocator: std.mem.Allocator) LsRefsArgs {
        return .{
            .peel = true,
            .symrefs = true,
            .ref_prefixes = std.array_list.Managed([]const u8).init(allocator),
            .unborn = false,
        };
    }

    pub fn deinit(self: *LsRefsArgs) void {
        self.ref_prefixes.deinit();
    }

    pub fn addRefPrefix(self: *LsRefsArgs, prefix: []const u8) !void {
        try self.ref_prefixes.append(prefix);
    }
};

/// A ref returned by ls-refs.
pub const LsRefsEntry = struct {
    oid_hex: [40]u8,
    ref_name: []const u8,
    symref_target: ?[]const u8,
    peeled_oid_hex: ?[40]u8,
};

/// Result of ls-refs command.
pub const LsRefsResult = struct {
    entries: std.array_list.Managed(LsRefsEntry),
    /// Backing buffer for allocated strings (ref names, symref targets).
    string_buf: std.array_list.Managed(u8),

    pub fn init(allocator: std.mem.Allocator) LsRefsResult {
        return .{
            .entries = std.array_list.Managed(LsRefsEntry).init(allocator),
            .string_buf = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *LsRefsResult) void {
        self.entries.deinit();
        self.string_buf.deinit();
    }
};

/// Fetch response sections.
pub const FetchResponseSection = enum {
    acknowledgments,
    shallow_info,
    wanted_refs,
    packfile,
    unknown,

    pub fn fromString(s: []const u8) FetchResponseSection {
        if (std.mem.eql(u8, s, "acknowledgments")) return .acknowledgments;
        if (std.mem.eql(u8, s, "shallow-info")) return .shallow_info;
        if (std.mem.eql(u8, s, "wanted-refs")) return .wanted_refs;
        if (std.mem.eql(u8, s, "packfile")) return .packfile;
        return .unknown;
    }
};

/// Build the version negotiation request for protocol v2.
/// This is sent as extra parameters in the initial connection.
pub fn buildVersionRequest(buf: []u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll("version=2");
    return buf[0..fbs.pos];
}

/// Build the ls-refs command request as pkt-line data.
pub fn buildLsRefsRequest(allocator: std.mem.Allocator, args: *const LsRefsArgs) !std.array_list.Managed(u8) {
    var list = std.array_list.Managed(u8).init(allocator);
    errdefer list.deinit();

    // Command line
    try pkt_line.writePktLineList(&list, "command=ls-refs\n");

    // Agent capability
    try pkt_line.writePktLineList(&list, "agent=zig-git/0.2.0\n");

    // Delimiter before arguments
    try pkt_line.writeDelimList(&list);

    // Arguments
    if (args.peel) {
        try pkt_line.writePktLineList(&list, "peel\n");
    }
    if (args.symrefs) {
        try pkt_line.writePktLineList(&list, "symrefs\n");
    }
    if (args.unborn) {
        try pkt_line.writePktLineList(&list, "unborn\n");
    }

    // Ref prefixes
    for (args.ref_prefixes.items) |prefix| {
        var line_buf: [1024]u8 = undefined;
        const n = pkt_line.formatPktLine(&line_buf, "ref-prefix {s}\n", .{prefix}) catch continue;
        try list.appendSlice(line_buf[0..n]);
    }

    // Flush to end
    try pkt_line.writeFlushList(&list);

    return list;
}

/// Parse ls-refs response from pkt-line data.
pub fn parseLsRefsResponse(allocator: std.mem.Allocator, data: []const u8) !LsRefsResult {
    var result = LsRefsResult.init(allocator);
    errdefer result.deinit();

    var pos: usize = 0;
    while (pos < data.len) {
        const pkt = pkt_line.readPktLine(data, pos) catch break;
        pos += pkt.bytes_consumed;

        switch (pkt.packet_type) {
            .flush, .response_end => break,
            .delim => continue,
            .data => {
                var payload = pkt.data;
                if (payload.len > 0 and payload[payload.len - 1] == '\n') {
                    payload = payload[0 .. payload.len - 1];
                }
                const entry = try parseLsRefsLine(&result, payload);
                try result.entries.append(entry);
            },
        }
    }

    return result;
}

/// Parse a single ls-refs response line.
/// Format: <oid> <refname> [symref-target:<target>] [peeled:<oid>]
fn parseLsRefsLine(result: *LsRefsResult, line: []const u8) !LsRefsEntry {
    var entry: LsRefsEntry = .{
        .oid_hex = undefined,
        .ref_name = "",
        .symref_target = null,
        .peeled_oid_hex = null,
    };

    if (line.len < 41) return error.InvalidLsRefsLine;

    // OID is first 40 chars
    @memcpy(&entry.oid_hex, line[0..40]);

    if (line[40] != ' ') return error.InvalidLsRefsLine;

    // Rest is ref name and optional attributes separated by spaces
    const remaining = line[41..];

    // Find the ref name (first token)
    var token_iter = std.mem.splitScalar(u8, remaining, ' ');
    if (token_iter.next()) |ref_name_token| {
        // Store ref name in the string buffer
        const start = result.string_buf.items.len;
        try result.string_buf.appendSlice(ref_name_token);
        entry.ref_name = result.string_buf.items[start..];
    }

    // Parse optional attributes
    while (token_iter.next()) |attr| {
        if (std.mem.startsWith(u8, attr, "symref-target:")) {
            const target = attr["symref-target:".len..];
            const start = result.string_buf.items.len;
            try result.string_buf.appendSlice(target);
            entry.symref_target = result.string_buf.items[start..];
        } else if (std.mem.startsWith(u8, attr, "peeled:")) {
            const peeled = attr["peeled:".len..];
            if (peeled.len >= 40) {
                @memcpy(&entry.peeled_oid_hex.?, peeled[0..40]);
            }
        }
    }

    return entry;
}

/// Build the fetch command request as pkt-line data.
pub fn buildFetchRequest(allocator: std.mem.Allocator, args: *const FetchArgs) !std.array_list.Managed(u8) {
    var list = std.array_list.Managed(u8).init(allocator);
    errdefer list.deinit();

    // Command line
    try pkt_line.writePktLineList(&list, "command=fetch\n");

    // Agent capability
    try pkt_line.writePktLineList(&list, "agent=zig-git/0.2.0\n");

    // Server options
    for (args.server_options.items) |opt| {
        var line_buf: [1024]u8 = undefined;
        const n = pkt_line.formatPktLine(&line_buf, "server-option={s}\n", .{opt}) catch continue;
        try list.appendSlice(line_buf[0..n]);
    }

    // Delimiter before arguments
    try pkt_line.writeDelimList(&list);

    // Capability arguments (what the client supports for this fetch)
    if (args.thin_pack) {
        try pkt_line.writePktLineList(&list, "thin-pack\n");
    }
    if (args.ofs_delta) {
        try pkt_line.writePktLineList(&list, "ofs-delta\n");
    }
    if (args.include_tag) {
        try pkt_line.writePktLineList(&list, "include-tag\n");
    }
    if (args.no_progress) {
        try pkt_line.writePktLineList(&list, "no-progress\n");
    }

    // Want lines
    for (args.wants.items) |*oid_hex| {
        var line_buf: [256]u8 = undefined;
        const n = pkt_line.formatPktLine(&line_buf, "want {s}\n", .{oid_hex}) catch continue;
        try list.appendSlice(line_buf[0..n]);
    }

    // Have lines
    for (args.haves.items) |*oid_hex| {
        var line_buf: [256]u8 = undefined;
        const n = pkt_line.formatPktLine(&line_buf, "have {s}\n", .{oid_hex}) catch continue;
        try list.appendSlice(line_buf[0..n]);
    }

    // Shallow lines
    for (args.shallow.items) |*oid_hex| {
        var line_buf: [256]u8 = undefined;
        const n = pkt_line.formatPktLine(&line_buf, "shallow {s}\n", .{oid_hex}) catch continue;
        try list.appendSlice(line_buf[0..n]);
    }

    // Deepen
    if (args.deepen) |depth| {
        var line_buf: [256]u8 = undefined;
        const n = pkt_line.formatPktLine(&line_buf, "deepen {d}\n", .{depth}) catch 0;
        if (n > 0) try list.appendSlice(line_buf[0..n]);
    }

    // Deepen-since
    if (args.deepen_since) |timestamp| {
        var line_buf: [256]u8 = undefined;
        const n = pkt_line.formatPktLine(&line_buf, "deepen-since {d}\n", .{timestamp}) catch 0;
        if (n > 0) try list.appendSlice(line_buf[0..n]);
    }

    // Deepen-not
    for (args.deepen_not.items) |ref| {
        var line_buf: [1024]u8 = undefined;
        const n = pkt_line.formatPktLine(&line_buf, "deepen-not {s}\n", .{ref}) catch continue;
        try list.appendSlice(line_buf[0..n]);
    }

    // Filter
    if (args.filter_spec) |filter| {
        var line_buf: [1024]u8 = undefined;
        const n = pkt_line.formatPktLine(&line_buf, "filter {s}\n", .{filter}) catch 0;
        if (n > 0) try list.appendSlice(line_buf[0..n]);
    }

    // Done
    if (args.done) {
        try pkt_line.writePktLineList(&list, "done\n");
    }

    // Flush to end
    try pkt_line.writeFlushList(&list);

    return list;
}

/// Acknowledgment types in fetch response.
pub const AckStatus = enum {
    nak,
    ack,
    ack_common,
    ack_ready,
};

/// A single acknowledgment entry.
pub const AckEntry = struct {
    status: AckStatus,
    oid_hex: ?[40]u8,
};

/// Result of parsing a fetch response.
pub const FetchResponse = struct {
    allocator: std.mem.Allocator,
    acks: std.array_list.Managed(AckEntry),
    shallow_oids: std.array_list.Managed([40]u8),
    unshallow_oids: std.array_list.Managed([40]u8),
    pack_data_offset: ?usize,
    /// Total bytes consumed from input.
    bytes_consumed: usize,

    pub fn init(allocator: std.mem.Allocator) FetchResponse {
        return .{
            .allocator = allocator,
            .acks = std.array_list.Managed(AckEntry).init(allocator),
            .shallow_oids = std.array_list.Managed([40]u8).init(allocator),
            .unshallow_oids = std.array_list.Managed([40]u8).init(allocator),
            .pack_data_offset = null,
            .bytes_consumed = 0,
        };
    }

    pub fn deinit(self: *FetchResponse) void {
        self.acks.deinit();
        self.shallow_oids.deinit();
        self.unshallow_oids.deinit();
    }

    pub fn hasAck(self: *const FetchResponse) bool {
        for (self.acks.items) |*ack| {
            if (ack.status == .ack or ack.status == .ack_common or ack.status == .ack_ready) {
                return true;
            }
        }
        return false;
    }

    pub fn isReady(self: *const FetchResponse) bool {
        for (self.acks.items) |*ack| {
            if (ack.status == .ack_ready) return true;
        }
        return false;
    }
};

/// Parse a fetch response from pkt-line data.
pub fn parseFetchResponse(allocator: std.mem.Allocator, data: []const u8) !FetchResponse {
    var response = FetchResponse.init(allocator);
    errdefer response.deinit();

    var pos: usize = 0;
    var current_section: FetchResponseSection = .unknown;

    while (pos < data.len) {
        const pkt = pkt_line.readPktLine(data, pos) catch break;
        pos += pkt.bytes_consumed;

        switch (pkt.packet_type) {
            .flush => {
                // End of response
                break;
            },
            .response_end => break,
            .delim => {
                // Section boundary
                continue;
            },
            .data => {
                var payload = pkt.data;
                if (payload.len > 0 and payload[payload.len - 1] == '\n') {
                    payload = payload[0 .. payload.len - 1];
                }

                // Detect section headers
                if (std.mem.eql(u8, payload, "acknowledgments") or
                    std.mem.eql(u8, payload, "shallow-info") or
                    std.mem.eql(u8, payload, "wanted-refs") or
                    std.mem.eql(u8, payload, "packfile"))
                {
                    current_section = FetchResponseSection.fromString(payload);

                    if (current_section == .packfile) {
                        // Everything after "packfile" section header is side-band pack data
                        response.pack_data_offset = pos;
                        break;
                    }
                    continue;
                }

                switch (current_section) {
                    .acknowledgments => {
                        const ack = parseAckLine(payload);
                        try response.acks.append(ack);
                    },
                    .shallow_info => {
                        if (std.mem.startsWith(u8, payload, "shallow ")) {
                            if (payload.len >= "shallow ".len + 40) {
                                var oid_hex: [40]u8 = undefined;
                                @memcpy(&oid_hex, payload["shallow ".len..][0..40]);
                                try response.shallow_oids.append(oid_hex);
                            }
                        } else if (std.mem.startsWith(u8, payload, "unshallow ")) {
                            if (payload.len >= "unshallow ".len + 40) {
                                var oid_hex: [40]u8 = undefined;
                                @memcpy(&oid_hex, payload["unshallow ".len..][0..40]);
                                try response.unshallow_oids.append(oid_hex);
                            }
                        }
                    },
                    .wanted_refs, .packfile, .unknown => {},
                }
            },
        }
    }

    response.bytes_consumed = pos;
    return response;
}

/// Parse an acknowledgment line from the server.
fn parseAckLine(line: []const u8) AckEntry {
    if (std.mem.eql(u8, line, "NAK")) {
        return AckEntry{ .status = .nak, .oid_hex = null };
    }

    if (std.mem.startsWith(u8, line, "ACK ")) {
        const rest = line["ACK ".len..];
        if (rest.len >= 40) {
            var oid_hex: [40]u8 = undefined;
            @memcpy(&oid_hex, rest[0..40]);

            // Check for status suffix
            if (rest.len > 41) {
                const suffix = rest[41..];
                if (std.mem.eql(u8, suffix, "common")) {
                    return AckEntry{ .status = .ack_common, .oid_hex = oid_hex };
                } else if (std.mem.eql(u8, suffix, "ready")) {
                    return AckEntry{ .status = .ack_ready, .oid_hex = oid_hex };
                }
            }
            return AckEntry{ .status = .ack, .oid_hex = oid_hex };
        }
    }

    return AckEntry{ .status = .nak, .oid_hex = null };
}

/// Detect protocol version from server's initial response.
/// In v2, the server sends "version 2\n" as the first line.
pub fn detectProtocolVersion(data: []const u8) u8 {
    const pkt = pkt_line.readPktLine(data, 0) catch return PROTOCOL_VERSION_1;

    if (pkt.packet_type != .data) return PROTOCOL_VERSION_1;

    var payload = pkt.data;
    if (payload.len > 0 and payload[payload.len - 1] == '\n') {
        payload = payload[0 .. payload.len - 1];
    }

    if (std.mem.eql(u8, payload, "version 2")) {
        return PROTOCOL_VERSION_2;
    }

    return PROTOCOL_VERSION_1;
}

/// Parse server capabilities from v2 initial handshake.
/// After "version 2" line, server sends capability lines until flush.
pub fn parseV2Capabilities(allocator: std.mem.Allocator, data: []const u8) !V2CapabilityInfo {
    var info = V2CapabilityInfo{
        .caps = capabilities.Capabilities.init(allocator),
        .bytes_consumed = 0,
    };
    errdefer info.caps.deinit();

    var pos: usize = 0;

    // Skip "version 2" line
    const first_pkt = pkt_line.readPktLine(data, pos) catch return info;
    pos += first_pkt.bytes_consumed;

    // Read capability lines until flush
    while (pos < data.len) {
        const pkt = pkt_line.readPktLine(data, pos) catch break;
        pos += pkt.bytes_consumed;

        switch (pkt.packet_type) {
            .flush => break,
            .delim, .response_end => continue,
            .data => {
                try info.caps.parseV2Line(pkt.data);
            },
        }
    }

    info.bytes_consumed = pos;
    return info;
}

pub const V2CapabilityInfo = struct {
    caps: capabilities.Capabilities,
    bytes_consumed: usize,
};

/// Check if the server supports a specific v2 command.
pub fn serverSupportsCommand(caps: *const capabilities.Capabilities, cmd: Command) bool {
    return caps.hasV2(cmd.toString());
}

/// Build the extra parameters for Git HTTP requests to request protocol v2.
/// Returns the Git-Protocol header value.
pub fn httpProtocolV2Header(buf: []u8) ![]const u8 {
    const header = "version=2";
    if (buf.len < header.len) return error.BufferTooSmall;
    @memcpy(buf[0..header.len], header);
    return buf[0..header.len];
}

/// Stateless connection state for HTTP transport.
/// In HTTP mode, each request is independent — the client must send
/// all state (haves, wants, etc.) in each request.
pub const StatelessRPC = struct {
    /// Whether we're in stateless mode (HTTP).
    enabled: bool,
    /// Capabilities discovered from server.
    server_caps: ?capabilities.Capabilities,
    /// Protocol version in use.
    version: u8,

    pub fn init() StatelessRPC {
        return .{
            .enabled = false,
            .server_caps = null,
            .version = PROTOCOL_VERSION_1,
        };
    }

    pub fn deinit(self: *StatelessRPC) void {
        if (self.server_caps) |*caps| {
            caps.deinit();
        }
    }

    pub fn isV2(self: *const StatelessRPC) bool {
        return self.version == PROTOCOL_VERSION_2;
    }
};

/// Build a v2 request with object-format capability included.
pub fn buildV2RequestHeader(list: *std.array_list.Managed(u8), command: Command, object_format: ?[]const u8) !void {
    // Command
    var cmd_buf: [256]u8 = undefined;
    var cmd_fbs = std.io.fixedBufferStream(&cmd_buf);
    const cmd_writer = cmd_fbs.writer();
    try cmd_writer.writeAll("command=");
    try cmd_writer.writeAll(command.toString());
    try cmd_writer.writeByte('\n');
    try pkt_line.writePktLineList(list, cmd_buf[0..cmd_fbs.pos]);

    // Agent
    try pkt_line.writePktLineList(list, "agent=zig-git/0.2.0\n");

    // Object format if specified
    if (object_format) |fmt| {
        var fmt_buf: [256]u8 = undefined;
        var fmt_fbs = std.io.fixedBufferStream(&fmt_buf);
        const fmt_writer = fmt_fbs.writer();
        try fmt_writer.writeAll("object-format=");
        try fmt_writer.writeAll(fmt);
        try fmt_writer.writeByte('\n');
        try pkt_line.writePktLineList(list, fmt_buf[0..fmt_fbs.pos]);
    }
}

/// Determine if we need to do multi-round negotiation.
/// In v2 with HTTP, each fetch request is independent, so we may
/// need multiple rounds to find common ancestors.
pub fn needsNegotiation(haves_count: usize, acks: []const AckEntry) bool {
    if (haves_count == 0) return false;

    // Check if server is ready
    for (acks) |*ack| {
        if (ack.status == .ack_ready) return false;
    }

    // If server NAK'd everything, we might need more rounds
    // unless we have no more haves to send
    return true;
}

/// Maximum number of negotiation rounds before giving up and sending done.
pub const MAX_NEGOTIATION_ROUNDS = 256;

/// Calculate how many haves to send in each round.
/// Starts small and doubles each round (exponential backoff).
pub fn havesPerRound(round: u32) u32 {
    const base: u32 = 32;
    const shift: u5 = @intCast(@min(round, 10));
    const result = base << shift;
    return @min(result, 16384);
}

// --- Tests ---

test "Command toString and fromString" {
    try std.testing.expectEqualStrings("ls-refs", Command.ls_refs.toString());
    try std.testing.expectEqualStrings("fetch", Command.fetch.toString());
    try std.testing.expectEqual(Command.ls_refs, Command.fromString("ls-refs").?);
    try std.testing.expectEqual(Command.fetch, Command.fromString("fetch").?);
    try std.testing.expect(Command.fromString("unknown") == null);
}

test "detectProtocolVersion v2" {
    // Build a "version 2\n" pkt-line
    var buf: [256]u8 = undefined;
    const n = try pkt_line.writePktLine(&buf, "version 2\n");
    try std.testing.expectEqual(@as(u8, PROTOCOL_VERSION_2), detectProtocolVersion(buf[0..n]));
}

test "detectProtocolVersion v1" {
    // A typical v1 response starts with a ref line
    var buf: [256]u8 = undefined;
    const n = try pkt_line.writePktLine(&buf, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 HEAD\n");
    try std.testing.expectEqual(@as(u8, PROTOCOL_VERSION_1), detectProtocolVersion(buf[0..n]));
}

test "buildLsRefsRequest" {
    var args = LsRefsArgs.init(std.testing.allocator);
    defer args.deinit();

    try args.addRefPrefix("refs/heads/");
    try args.addRefPrefix("refs/tags/");

    var req = try buildLsRefsRequest(std.testing.allocator, &args);
    defer req.deinit();

    // Should contain command=ls-refs, peel, symrefs, ref-prefix lines, and flush
    try std.testing.expect(req.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, req.items, "command=ls-refs") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.items, "peel") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.items, "symrefs") != null);
}

test "buildFetchRequest" {
    var args = FetchArgs.init(std.testing.allocator);
    defer args.deinit();

    const oid = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391".*;
    try args.addWant(&oid);
    args.done = true;

    var req = try buildFetchRequest(std.testing.allocator, &args);
    defer req.deinit();

    try std.testing.expect(req.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, req.items, "command=fetch") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.items, "want") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.items, "done") != null);
}

test "parseAckLine NAK" {
    const ack = parseAckLine("NAK");
    try std.testing.expectEqual(AckStatus.nak, ack.status);
    try std.testing.expect(ack.oid_hex == null);
}

test "parseAckLine ACK" {
    const ack = parseAckLine("ACK e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    try std.testing.expectEqual(AckStatus.ack, ack.status);
    try std.testing.expect(ack.oid_hex != null);
}

test "parseAckLine ACK ready" {
    const ack = parseAckLine("ACK e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 ready");
    try std.testing.expectEqual(AckStatus.ack_ready, ack.status);
}

test "FetchArgs init and deinit" {
    var args = FetchArgs.init(std.testing.allocator);
    defer args.deinit();

    const oid = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391".*;
    try args.addWant(&oid);
    try args.addHave(&oid);
    try std.testing.expectEqual(@as(usize, 1), args.wants.items.len);
    try std.testing.expectEqual(@as(usize, 1), args.haves.items.len);
}

test "havesPerRound" {
    try std.testing.expectEqual(@as(u32, 32), havesPerRound(0));
    try std.testing.expectEqual(@as(u32, 64), havesPerRound(1));
    try std.testing.expectEqual(@as(u32, 128), havesPerRound(2));
}

test "httpProtocolV2Header" {
    var buf: [64]u8 = undefined;
    const header = try httpProtocolV2Header(&buf);
    try std.testing.expectEqualStrings("version=2", header);
}

test "needsNegotiation" {
    // No haves: no negotiation needed
    try std.testing.expect(!needsNegotiation(0, &.{}));

    // Ready ack: no more negotiation
    const ready_acks = [_]AckEntry{.{ .status = .ack_ready, .oid_hex = null }};
    try std.testing.expect(!needsNegotiation(5, &ready_acks));

    // NAK with haves: need more negotiation
    const nak_acks = [_]AckEntry{.{ .status = .nak, .oid_hex = null }};
    try std.testing.expect(needsNegotiation(5, &nak_acks));
}

test "FetchResponseSection fromString" {
    try std.testing.expectEqual(FetchResponseSection.acknowledgments, FetchResponseSection.fromString("acknowledgments"));
    try std.testing.expectEqual(FetchResponseSection.packfile, FetchResponseSection.fromString("packfile"));
    try std.testing.expectEqual(FetchResponseSection.unknown, FetchResponseSection.fromString("foobar"));
}

test "StatelessRPC" {
    var rpc = StatelessRPC.init();
    defer rpc.deinit();
    try std.testing.expect(!rpc.isV2());
    try std.testing.expect(!rpc.enabled);
}

test "buildV2RequestHeader" {
    var list = std.array_list.Managed(u8).init(std.testing.allocator);
    defer list.deinit();
    try buildV2RequestHeader(&list, .ls_refs, null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "command=ls-refs") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "agent=zig-git") != null);
}
