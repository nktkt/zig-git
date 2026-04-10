const std = @import("std");
const types = @import("types.zig");
const pkt_line = @import("pkt_line.zig");
const capabilities = @import("capabilities.zig");
const transport_mod = @import("transport.zig");
const url_mod = @import("url.zig");
const upload_pack = @import("upload_pack.zig");

/// Smart HTTP transport for git clone/fetch/push.
///
/// This module implements the git "smart HTTP" protocol by shelling out to
/// `curl` as a subprocess. The protocol uses two endpoints:
///   GET  <base>/info/refs?service=git-upload-pack    -- reference discovery
///   POST <base>/git-upload-pack                      -- pack negotiation & download
///   POST <base>/git-receive-pack                     -- push
///
/// For public repositories (like GitHub public repos), no authentication is
/// required for clone/fetch. Authentication is handled via:
///   - Credentials embedded in URL (user:token@host)
///   - The -u flag to curl for Basic auth

const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Maximum response size for ref discovery (16 MB).
const MAX_REF_RESPONSE: usize = 16 * 1024 * 1024;

/// Maximum response size for pack data (512 MB).
const MAX_PACK_RESPONSE: usize = 512 * 1024 * 1024;

/// A reference discovered from the remote.
pub const DiscoveredRef = struct {
    oid: types.ObjectId,
    name: []const u8,
};

/// Result of reference discovery.
pub const DiscoverResult = struct {
    allocator: std.mem.Allocator,
    refs: []DiscoveredRef,
    capabilities_str: ?[]u8,
    head_symref: ?[]u8,

    pub fn deinit(self: *DiscoverResult) void {
        for (self.refs) |ref| {
            self.allocator.free(@constCast(ref.name));
        }
        self.allocator.free(self.refs);
        if (self.capabilities_str) |c| self.allocator.free(c);
        if (self.head_symref) |h| self.allocator.free(h);
    }
};

// -----------------------------------------------------------------------
// Reference Discovery (GET /info/refs?service=git-upload-pack)
// -----------------------------------------------------------------------

/// Discover refs from a remote HTTP(S) git repository.
/// This performs:
///   GET <url>/info/refs?service=git-upload-pack
/// and parses the pkt-line response.
pub fn discoverRefsHttp(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    service: []const u8,
) !DiscoverResult {
    // Build URL: <base>/info/refs?service=<service>
    var url_buf: [4096]u8 = undefined;
    const full_url = buildInfoRefsUrl(&url_buf, base_url, service) orelse
        return error.UrlTooLong;

    // Run curl
    const response = try runCurlGet(allocator, full_url);
    defer allocator.free(response);

    if (response.len == 0) return error.EmptyResponse;

    // Parse the pkt-line ref advertisement
    return parseSmartHttpRefs(allocator, response);
}

/// Build the info/refs URL.
fn buildInfoRefsUrl(buf: []u8, base_url: []const u8, service: []const u8) ?[]const u8 {
    // Strip trailing slash from base URL
    var base = base_url;
    while (base.len > 0 and base[base.len - 1] == '/') {
        base = base[0 .. base.len - 1];
    }

    const suffix = "/info/refs?service=";
    const total = base.len + suffix.len + service.len;
    if (total > buf.len) return null;

    var pos: usize = 0;
    @memcpy(buf[pos..][0..base.len], base);
    pos += base.len;
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    @memcpy(buf[pos..][0..service.len], service);
    pos += service.len;

    return buf[0..pos];
}

/// Parse the smart HTTP ref advertisement response.
/// The response format is:
///   pkt-line: "# service=git-upload-pack\n"
///   flush
///   pkt-line: "<oid> <refname>\0<capabilities>\n"  (first ref with caps)
///   pkt-line: "<oid> <refname>\n"                   (subsequent refs)
///   ...
///   flush
fn parseSmartHttpRefs(allocator: std.mem.Allocator, data: []const u8) !DiscoverResult {
    var refs_list = std.array_list.Managed(DiscoveredRef).init(allocator);
    defer refs_list.deinit();

    var caps_raw: ?[]u8 = null;
    var head_symref: ?[]u8 = null;

    var pos: usize = 0;
    var first_ref = true;
    var past_service_header = false;

    while (pos < data.len) {
        const pkt = pkt_line.readPktLine(data, pos) catch break;
        pos += pkt.bytes_consumed;

        switch (pkt.packet_type) {
            .flush => {
                if (!past_service_header) {
                    // First flush separates the service header from refs
                    past_service_header = true;
                    continue;
                }
                // Second flush means end of refs
                break;
            },
            .delim, .response_end => continue,
            .data => {
                var payload = pkt.data;
                // Strip trailing LF
                if (payload.len > 0 and payload[payload.len - 1] == '\n') {
                    payload = payload[0 .. payload.len - 1];
                }

                // Skip "# service=..." header
                if (std.mem.startsWith(u8, payload, "# ")) {
                    continue;
                }

                // Extract capabilities from first ref line
                if (first_ref) {
                    first_ref = false;
                    // Capabilities are after the NUL byte in the raw pkt data
                    if (capabilities.extractCapsFromFirstLine(pkt.data)) |cs| {
                        caps_raw = try allocator.alloc(u8, cs.len);
                        @memcpy(caps_raw.?, cs);

                        // Look for symref=HEAD:... in caps
                        head_symref = try extractHeadSymref(allocator, cs);
                    }
                }

                // Parse: OID SP refname
                if (payload.len < 41) continue;
                if (payload[40] != ' ') continue;

                const oid_hex = payload[0..40];
                var ref_name = payload[41..];

                // Strip NUL and capabilities from ref name
                if (std.mem.indexOfScalar(u8, ref_name, 0)) |nul_pos| {
                    ref_name = ref_name[0..nul_pos];
                }

                const oid = types.ObjectId.fromHex(oid_hex) catch continue;
                const name_copy = try allocator.alloc(u8, ref_name.len);
                @memcpy(name_copy, ref_name);

                try refs_list.append(.{
                    .oid = oid,
                    .name = name_copy,
                });
            },
        }
    }

    return DiscoverResult{
        .allocator = allocator,
        .refs = try refs_list.toOwnedSlice(),
        .capabilities_str = caps_raw,
        .head_symref = head_symref,
    };
}

/// Extract HEAD symref target from capability string.
fn extractHeadSymref(allocator: std.mem.Allocator, caps_str: []const u8) !?[]u8 {
    // Caps are space-separated; look for "symref=HEAD:<target>"
    var iter = std.mem.splitScalar(u8, caps_str, ' ');
    while (iter.next()) |token| {
        if (std.mem.startsWith(u8, token, "symref=HEAD:")) {
            const target = token["symref=HEAD:".len..];
            const result = try allocator.alloc(u8, target.len);
            @memcpy(result, target);
            return result;
        }
    }
    return null;
}

// -----------------------------------------------------------------------
// Fetch Pack (POST /git-upload-pack)
// -----------------------------------------------------------------------

/// Fetch a pack file from a remote HTTP(S) git repository.
///
/// Builds the upload-pack negotiation request (want/have/done),
/// POSTs it to <url>/git-upload-pack, and extracts the pack data
/// from the response.
///
/// Returns the raw pack data (starting with "PACK" header).
pub fn fetchPackHttp(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    wants: []const types.ObjectId,
    haves: []const types.ObjectId,
    server_caps_str: ?[]const u8,
) ![]u8 {
    if (wants.len == 0) return error.NoWants;

    // Parse server capabilities to negotiate features
    var server_caps = capabilities.Capabilities.init(allocator);
    defer server_caps.deinit();
    if (server_caps_str) |cs| {
        server_caps.parse(cs) catch {};
    }

    const use_side_band = server_caps.has("side-band-64k");
    const use_ofs_delta = server_caps.has("ofs-delta");
    const use_thin_pack = server_caps.has("thin-pack");
    _ = use_thin_pack;

    // Build the request body
    var request = std.array_list.Managed(u8).init(allocator);
    defer request.deinit();

    // want lines
    var first_want = true;
    for (wants) |oid| {
        const hex = oid.toHex();
        if (first_want) {
            first_want = false;
            // First want includes capabilities
            var caps_buf: [512]u8 = undefined;
            const client_caps = buildClientCaps(&caps_buf, use_side_band, use_ofs_delta);
            try pkt_line.formatPktLineList(&request, "want {s} {s}\n", .{ &hex, client_caps });
        } else {
            try pkt_line.formatPktLineList(&request, "want {s}\n", .{&hex});
        }
    }

    // flush after wants
    try pkt_line.writeFlushList(&request);

    // have lines
    for (haves) |oid| {
        const hex = oid.toHex();
        try pkt_line.formatPktLineList(&request, "have {s}\n", .{&hex});
    }

    // done
    try pkt_line.writePktLineList(&request, "done\n");

    // Build the POST URL
    var url_buf: [4096]u8 = undefined;
    const post_url = buildServiceUrl(&url_buf, base_url, "git-upload-pack") orelse
        return error.UrlTooLong;

    // POST the request
    const response = try runCurlPost(
        allocator,
        post_url,
        "application/x-git-upload-pack-request",
        request.items,
    );
    defer allocator.free(response);

    if (response.len == 0) return error.EmptyResponse;

    // Extract pack data from the response
    return extractPackFromResponse(allocator, response, use_side_band);
}

/// Build the client capabilities string for upload-pack.
fn buildClientCaps(buf: []u8, use_side_band: bool, use_ofs_delta: bool) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    writer.writeAll("multi_ack_detailed") catch return buf[0..0];

    if (use_side_band) {
        writer.writeAll(" side-band-64k") catch return buf[0..fbs.pos];
    }

    if (use_ofs_delta) {
        writer.writeAll(" ofs-delta") catch return buf[0..fbs.pos];
    }

    writer.writeAll(" thin-pack") catch return buf[0..fbs.pos];
    writer.writeAll(" no-progress") catch return buf[0..fbs.pos];
    writer.writeAll(" include-tag") catch return buf[0..fbs.pos];
    writer.writeAll(" agent=zig-git/0.2.0") catch return buf[0..fbs.pos];

    return buf[0..fbs.pos];
}

/// Build the service endpoint URL for POST.
fn buildServiceUrl(buf: []u8, base_url: []const u8, service_name: []const u8) ?[]const u8 {
    var base = base_url;
    while (base.len > 0 and base[base.len - 1] == '/') {
        base = base[0 .. base.len - 1];
    }

    const total = base.len + 1 + service_name.len;
    if (total > buf.len) return null;

    var pos: usize = 0;
    @memcpy(buf[pos..][0..base.len], base);
    pos += base.len;
    buf[pos] = '/';
    pos += 1;
    @memcpy(buf[pos..][0..service_name.len], service_name);
    pos += service_name.len;

    return buf[0..pos];
}

/// Extract pack data from the upload-pack response.
/// The response may contain NAK/ACK lines before the pack data,
/// and the pack data may be side-band encoded.
pub fn extractPackFromResponse(
    allocator: std.mem.Allocator,
    data: []const u8,
    use_side_band: bool,
) ![]u8 {
    if (!use_side_band) {
        // No side-band: find the "PACK" header and return everything from there
        if (std.mem.indexOf(u8, data, "PACK")) |pack_pos| {
            const result = try allocator.alloc(u8, data.len - pack_pos);
            @memcpy(result, data[pack_pos..]);
            return result;
        }
        return error.NoPackData;
    }

    // Side-band: parse pkt-lines, collecting band-1 (pack data)
    var pack_buf = std.array_list.Managed(u8).init(allocator);
    errdefer pack_buf.deinit();

    var pos: usize = 0;
    while (pos < data.len) {
        // Check for raw PACK data (no pkt-line framing)
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
                    2 => {
                        // progress message, print to stderr
                        stderr_file.writeAll(rest) catch {};
                    },
                    3 => {
                        // error from server
                        stderr_file.writeAll("remote error: ") catch {};
                        stderr_file.writeAll(rest) catch {};
                        stderr_file.writeAll("\n") catch {};
                        return error.ServerError;
                    },
                    else => {
                        // Not side-band; might be NAK/ACK text
                        // Check if payload starts with "NAK" or "ACK"
                        if (std.mem.startsWith(u8, pkt.data, "NAK") or
                            std.mem.startsWith(u8, pkt.data, "ACK"))
                        {
                            continue;
                        }
                        try pack_buf.appendSlice(pkt.data);
                    },
                }
            },
        }
    }

    if (pack_buf.items.len == 0) return error.NoPackData;

    // Validate PACK header
    if (pack_buf.items.len >= 4 and std.mem.eql(u8, pack_buf.items[0..4], "PACK")) {
        return pack_buf.toOwnedSlice();
    }

    // Maybe pack data didn't start with side-band after all, search for PACK in buffer
    if (std.mem.indexOf(u8, pack_buf.items, "PACK")) |pack_pos| {
        const result = try allocator.alloc(u8, pack_buf.items.len - pack_pos);
        @memcpy(result, pack_buf.items[pack_pos..]);
        pack_buf.deinit();
        return result;
    }

    pack_buf.deinit();
    return error.NoPackData;
}

// -----------------------------------------------------------------------
// Push Pack (POST /git-receive-pack)
// -----------------------------------------------------------------------

/// Push a pack to a remote HTTP(S) git repository.
pub fn pushPackHttp(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    updates: []const transport_mod.RefUpdate,
    pack_data: []const u8,
    server_caps_str: ?[]const u8,
) !bool {
    if (updates.len == 0) return true;

    // Parse server caps
    var server_caps = capabilities.Capabilities.init(allocator);
    defer server_caps.deinit();
    if (server_caps_str) |cs| {
        server_caps.parse(cs) catch {};
    }

    const use_report_status = server_caps.has("report-status");
    const use_side_band = server_caps.has("side-band-64k");

    // Build command list
    var request = std.array_list.Managed(u8).init(allocator);
    defer request.deinit();

    var first = true;
    for (updates) |update| {
        const old_hex = update.old_oid.toHex();
        const new_hex = update.new_oid.toHex();

        if (first) {
            first = false;
            var caps_buf: [512]u8 = undefined;
            const client_caps = buildPushClientCaps(&caps_buf, use_report_status, use_side_band);
            try pkt_line.formatPktLineList(
                &request,
                "{s} {s} {s}\x00{s}\n",
                .{ &old_hex, &new_hex, update.ref_name, client_caps },
            );
        } else {
            try pkt_line.formatPktLineList(
                &request,
                "{s} {s} {s}\n",
                .{ &old_hex, &new_hex, update.ref_name },
            );
        }
    }

    try pkt_line.writeFlushList(&request);

    // Append pack data
    try request.appendSlice(pack_data);

    // Build POST URL
    var url_buf: [4096]u8 = undefined;
    const post_url = buildServiceUrl(&url_buf, base_url, "git-receive-pack") orelse
        return error.UrlTooLong;

    // POST
    const response = try runCurlPost(
        allocator,
        post_url,
        "application/x-git-receive-pack-request",
        request.items,
    );
    defer allocator.free(response);

    // Parse report-status if available
    if (use_report_status and response.len > 0) {
        return parseReportStatus(response);
    }

    return true;
}

/// Build client capabilities for receive-pack.
fn buildPushClientCaps(buf: []u8, report_status: bool, side_band: bool) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    var wrote_one = false;

    if (report_status) {
        writer.writeAll("report-status") catch return buf[0..fbs.pos];
        wrote_one = true;
    }

    if (side_band) {
        if (wrote_one) writer.writeByte(' ') catch {};
        writer.writeAll("side-band-64k") catch return buf[0..fbs.pos];
        wrote_one = true;
    }

    if (wrote_one) writer.writeByte(' ') catch {};
    writer.writeAll("agent=zig-git/0.2.0") catch return buf[0..fbs.pos];

    return buf[0..fbs.pos];
}

/// Parse a report-status response. Returns true if all updates succeeded.
fn parseReportStatus(data: []const u8) bool {
    var pos: usize = 0;
    while (pos < data.len) {
        const pkt = pkt_line.readPktLine(data, pos) catch break;
        pos += pkt.bytes_consumed;

        switch (pkt.packet_type) {
            .flush => break,
            .delim, .response_end => continue,
            .data => {
                var payload = pkt.data;

                // Handle side-band
                if (payload.len > 0 and payload[0] >= 1 and payload[0] <= 3) {
                    if (payload[0] == 3) {
                        // Error
                        stderr_file.writeAll("remote error: ") catch {};
                        stderr_file.writeAll(payload[1..]) catch {};
                        stderr_file.writeAll("\n") catch {};
                        return false;
                    }
                    if (payload[0] == 2) continue; // progress
                    payload = payload[1..]; // band 1 = data
                }

                if (payload.len > 0 and payload[payload.len - 1] == '\n') {
                    payload = payload[0 .. payload.len - 1];
                }

                if (std.mem.startsWith(u8, payload, "unpack ")) {
                    if (!std.mem.eql(u8, payload[7..], "ok")) {
                        return false;
                    }
                } else if (std.mem.startsWith(u8, payload, "ng ")) {
                    return false;
                }
            },
        }
    }
    return true;
}

// -----------------------------------------------------------------------
// curl subprocess helpers
// -----------------------------------------------------------------------

/// Run a curl GET request and return the response body.
fn runCurlGet(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("curl");
    try argv.append("--silent");
    try argv.append("--show-error");
    try argv.append("--location");
    try argv.append("--max-redirs");
    try argv.append("10");
    try argv.append(url);

    return runCurlProcess(allocator, argv.items, null);
}

/// Run a curl POST request and return the response body.
fn runCurlPost(
    allocator: std.mem.Allocator,
    url: []const u8,
    content_type: []const u8,
    body: []const u8,
) ![]u8 {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("curl");
    try argv.append("--silent");
    try argv.append("--show-error");
    try argv.append("--location");
    try argv.append("--max-redirs");
    try argv.append("10");
    try argv.append("-X");
    try argv.append("POST");
    try argv.append("-H");

    // Build Content-Type header
    var ct_buf: [256]u8 = undefined;
    const ct_prefix = "Content-Type: ";
    @memcpy(ct_buf[0..ct_prefix.len], ct_prefix);
    @memcpy(ct_buf[ct_prefix.len..][0..content_type.len], content_type);
    const ct_header = try allocator.alloc(u8, ct_prefix.len + content_type.len);
    @memcpy(ct_header, ct_buf[0 .. ct_prefix.len + content_type.len]);
    defer allocator.free(ct_header);

    try argv.append(ct_header);
    try argv.append("--data-binary");
    try argv.append("@-");
    try argv.append(url);

    return runCurlProcess(allocator, argv.items, body);
}

/// Spawn curl, optionally write body to stdin, return stdout.
fn runCurlProcess(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    body: ?[]const u8,
) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = if (body != null) .Pipe else .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Write body to stdin if provided
    if (body) |b| {
        if (child.stdin) |stdin| {
            stdin.writeAll(b) catch {};
            stdin.close();
            child.stdin = null;
        }
    }

    // Read all stdout
    const stdout_data = try readAll(allocator, child.stdout.?);
    errdefer allocator.free(stdout_data);

    // Read stderr (for error messages)
    const stderr_data = try readAll(allocator, child.stderr.?);
    defer allocator.free(stderr_data);

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 1,
    };

    if (exit_code != 0) {
        if (stderr_data.len > 0) {
            stderr_file.writeAll("curl error: ") catch {};
            stderr_file.writeAll(stderr_data) catch {};
            if (stderr_data.len == 0 or stderr_data[stderr_data.len - 1] != '\n') {
                stderr_file.writeAll("\n") catch {};
            }
        }
        allocator.free(stdout_data);
        return error.CurlFailed;
    }

    return stdout_data;
}

/// Read all data from a file (pipe).
fn readAll(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var buf: [16384]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch break;
        if (n == 0) break;
        try result.appendSlice(buf[0..n]);
        if (result.items.len > MAX_PACK_RESPONSE) return error.ResponseTooLarge;
    }

    return result.toOwnedSlice();
}
