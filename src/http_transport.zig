const std = @import("std");
const types = @import("types.zig");
const pkt_line = @import("pkt_line.zig");
const capabilities = @import("capabilities.zig");
const transport_mod = @import("transport.zig");
const url_mod = @import("url.zig");
const upload_pack = @import("upload_pack.zig");
const receive_pack = @import("receive_pack.zig");

/// HTTP smart transport for git.
///
/// Implements the Smart HTTP transport protocol by shelling out to `curl`
/// as a subprocess. This avoids the complexity of implementing TLS directly
/// while supporting both HTTP and HTTPS URLs.
///
/// The smart HTTP protocol uses two endpoints per service:
///   GET  /info/refs?service=<service> — reference discovery
///   POST /<service>                    — data exchange
///
/// The POST endpoint uses content types:
///   Request:  application/x-<service>-request
///   Response: application/x-<service>-result

const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Maximum response size we'll accept (256 MB).
const MAX_RESPONSE_SIZE: usize = 256 * 1024 * 1024;

/// Maximum initial response for ref discovery (16 MB).
const MAX_REF_RESPONSE_SIZE: usize = 16 * 1024 * 1024;

/// HTTP response.
pub const HttpResponse = struct {
    allocator: std.mem.Allocator,
    status_code: u16,
    body: []u8,
    content_type: ?[]u8,

    pub fn deinit(self: *HttpResponse) void {
        self.allocator.free(self.body);
        if (self.content_type) |ct| self.allocator.free(ct);
    }
};

/// Perform an HTTP GET request using curl.
pub fn httpGet(allocator: std.mem.Allocator, url: []const u8) !HttpResponse {
    return curlRequest(allocator, "GET", url, null, null);
}

/// Perform an HTTP POST request using curl.
pub fn httpPost(
    allocator: std.mem.Allocator,
    url: []const u8,
    content_type: []const u8,
    body: []const u8,
) !HttpResponse {
    return curlRequest(allocator, "POST", url, content_type, body);
}

/// Execute a curl command and return the response.
fn curlRequest(
    allocator: std.mem.Allocator,
    method: []const u8,
    url: []const u8,
    content_type: ?[]const u8,
    body: ?[]const u8,
) !HttpResponse {
    var argv_list = std.array_list.Managed([]const u8).init(allocator);
    defer argv_list.deinit();

    // Build curl command
    try argv_list.append("curl");
    try argv_list.append("--silent");
    try argv_list.append("--show-error");
    try argv_list.append("--fail-with-body");
    try argv_list.append("--location"); // Follow redirects
    try argv_list.append("--max-redirs");
    try argv_list.append("10");

    // Write HTTP status code and content-type to stderr format
    // We'll use -w to write status code and -D for headers
    try argv_list.append("-w");
    try argv_list.append("\n%{http_code}\n%{content_type}");

    // Method
    if (std.mem.eql(u8, method, "POST")) {
        try argv_list.append("-X");
        try argv_list.append("POST");
    }

    // Content-Type header
    if (content_type) |ct| {
        try argv_list.append("-H");

        var ct_header_buf: [256]u8 = undefined;
        var pos: usize = 0;
        const prefix = "Content-Type: ";
        @memcpy(ct_header_buf[pos..][0..prefix.len], prefix);
        pos += prefix.len;
        @memcpy(ct_header_buf[pos..][0..ct.len], ct);
        pos += ct.len;

        const ct_header = try allocator.alloc(u8, pos);
        @memcpy(ct_header, ct_header_buf[0..pos]);
        try argv_list.append(ct_header);
    }

    // If we have a body, use --data-binary @-
    if (body != null) {
        try argv_list.append("--data-binary");
        try argv_list.append("@-");
    }

    // URL
    try argv_list.append(url);

    // Spawn curl process
    var child = std.process.Child.init(argv_list.items, allocator);
    child.stdin_behavior = if (body != null) .pipe else .inherit;
    child.stdout_behavior = .pipe;
    child.stderr_behavior = .pipe;

    try child.spawn();

    // Write body to stdin if present
    if (body) |b| {
        if (child.stdin) |stdin| {
            stdin.writeAll(b) catch {};
            stdin.close();
            child.stdin = null;
        }
    }

    // Read stdout and stderr
    const stdout_data = try readChildOutput(allocator, child.stdout.?);
    const stderr_data = try readChildOutput(allocator, child.stderr.?);
    defer allocator.free(stderr_data);

    const term = try child.wait();
    const exit_code = switch (term) {
        .exited => |code| code,
        else => 1,
    };

    // Free the content-type header we allocated
    if (content_type != null) {
        // The header string is at index where we appended it
        // We need to find and free it
        for (argv_list.items) |arg| {
            if (std.mem.startsWith(u8, arg, "Content-Type: ")) {
                allocator.free(@constCast(arg));
                break;
            }
        }
    }

    // Parse the output: body + "\n" + status_code + "\n" + content_type
    var response_body = stdout_data;
    var status_code: u16 = 0;
    var resp_content_type: ?[]u8 = null;

    // Find the last two newlines to extract status code and content type
    if (stdout_data.len > 0) {
        // Work backwards to find the metadata curl appended
        var end = stdout_data.len;

        // Find content-type (last line)
        var ct_start = end;
        while (ct_start > 0 and stdout_data[ct_start - 1] != '\n') {
            ct_start -= 1;
        }
        if (ct_start < end) {
            const ct_str = stdout_data[ct_start..end];
            if (ct_str.len > 0) {
                resp_content_type = try allocator.alloc(u8, ct_str.len);
                @memcpy(resp_content_type.?, ct_str);
            }
            end = if (ct_start > 0) ct_start - 1 else ct_start;
        }

        // Find status code (second to last line)
        var sc_start = end;
        while (sc_start > 0 and stdout_data[sc_start - 1] != '\n') {
            sc_start -= 1;
        }
        if (sc_start < end) {
            const sc_str = stdout_data[sc_start..end];
            status_code = std.fmt.parseInt(u16, sc_str, 10) catch 0;
            end = if (sc_start > 0) sc_start - 1 else sc_start;
        }

        // The actual response body is everything before the metadata
        // We need to create a new allocation for just the body
        const body_len = end;
        if (body_len < stdout_data.len) {
            const new_body = try allocator.alloc(u8, body_len);
            @memcpy(new_body, stdout_data[0..body_len]);
            allocator.free(stdout_data);
            response_body = new_body;
        }
    }

    if (exit_code != 0 and status_code == 0) {
        allocator.free(response_body);
        if (resp_content_type) |ct| allocator.free(ct);
        return error.CurlFailed;
    }

    return HttpResponse{
        .allocator = allocator,
        .status_code = status_code,
        .body = response_body,
        .content_type = resp_content_type,
    };
}

/// Read all output from a child process pipe.
fn readChildOutput(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch break;
        if (n == 0) break;
        try result.appendSlice(buf[0..n]);
        if (result.items.len > MAX_RESPONSE_SIZE) return error.ResponseTooLarge;
    }

    return result.toOwnedSlice();
}

/// Discover references from a remote HTTP git repository.
pub fn discoverRefs(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    service: transport_mod.Service,
) !transport_mod.RefDiscoveryResult {
    // Build the info/refs URL
    var url_buf: [4096]u8 = undefined;
    const full_url = buildInfoRefsUrl(&url_buf, base_url, service) orelse return error.UrlTooLong;

    // Perform GET request
    var response = try httpGet(allocator, full_url);
    defer response.deinit();

    if (response.status_code != 200) {
        return error.HttpError;
    }

    // Verify content type for smart HTTP
    if (response.content_type) |ct| {
        var expected_ct_buf: [128]u8 = undefined;
        const expected_ct = buildServiceContentType(&expected_ct_buf, service, "advertisement") orelse "";
        if (!std.mem.startsWith(u8, ct, expected_ct)) {
            // May be a dumb HTTP server, not supported
            return error.DumbHttpNotSupported;
        }
    }

    // Parse the ref advertisement
    return parseRefAdvertisementResponse(allocator, response.body);
}

/// Fetch a pack from a remote HTTP git repository.
pub fn fetchPack(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    want_oids: []const types.ObjectId,
    have_oids: []const types.ObjectId,
) !transport_mod.FetchPackResult {
    // First, discover refs to get capabilities
    var ref_discovery = try discoverRefs(allocator, base_url, .upload_pack);
    defer ref_discovery.deinit();

    // Build an upload-pack session
    var session = try upload_pack.sessionFromDiscovery(allocator, &ref_discovery);
    defer session.deinit();

    // Build the negotiation request
    const request_data = try session.buildNegotiationRequest(want_oids, have_oids);
    defer allocator.free(request_data);

    // Build the POST URL
    var url_buf: [4096]u8 = undefined;
    const post_url = buildServiceUrl(&url_buf, base_url, "git-upload-pack") orelse return error.UrlTooLong;

    // POST the request
    var response = try httpPost(
        allocator,
        post_url,
        "application/x-git-upload-pack-request",
        request_data,
    );
    defer response.deinit();

    if (response.status_code != 200) {
        return error.HttpError;
    }

    // Extract pack data from the response
    const pack_data = try upload_pack.extractPackData(
        allocator,
        response.body,
        session.use_side_band_64k,
    );

    return transport_mod.FetchPackResult{
        .allocator = allocator,
        .pack_data = pack_data,
        .progress_messages = null,
    };
}

/// Push a pack to a remote HTTP git repository.
pub fn pushPack(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    updates: []const transport_mod.RefUpdate,
    pack_data: []const u8,
) !transport_mod.PushResult {
    // Discover refs to get capabilities
    var ref_discovery = try discoverRefs(allocator, base_url, .receive_pack);
    defer ref_discovery.deinit();

    // Build a receive-pack session
    var session = receive_pack.ReceivePackSession.init(allocator);
    defer session.deinit();

    if (ref_discovery.capabilities_raw) |caps_raw| {
        try session.server_caps.parse(caps_raw);
    }

    // Build update commands
    const commands = try session.buildUpdateCommands(updates);
    defer allocator.free(commands);

    // Concatenate commands + pack data
    var request_body = std.array_list.Managed(u8).init(allocator);
    defer request_body.deinit();

    try request_body.appendSlice(commands);
    try request_body.appendSlice(pack_data);

    // Build the POST URL
    var url_buf: [4096]u8 = undefined;
    const post_url = buildServiceUrl(&url_buf, base_url, "git-receive-pack") orelse return error.UrlTooLong;

    // POST the request
    var response = try httpPost(
        allocator,
        post_url,
        "application/x-git-receive-pack-request",
        request_body.items,
    );
    defer response.deinit();

    if (response.status_code != 200) {
        return transport_mod.PushResult{
            .allocator = allocator,
            .success = false,
            .messages = null,
        };
    }

    // Parse report-status if available
    if (response.body.len > 0) {
        var report = receive_pack.parseReportStatus(allocator, response.body) catch {
            return transport_mod.PushResult{
                .allocator = allocator,
                .success = true,
                .messages = null,
            };
        };
        defer report.deinit();

        var msg: ?[]u8 = null;
        if (report.server_message) |m| {
            msg = try allocator.alloc(u8, m.len);
            @memcpy(msg.?, m);
        }

        return transport_mod.PushResult{
            .allocator = allocator,
            .success = report.ok,
            .messages = msg,
        };
    }

    return transport_mod.PushResult{
        .allocator = allocator,
        .success = true,
        .messages = null,
    };
}

/// Parse the ref advertisement response from the HTTP info/refs endpoint.
fn parseRefAdvertisementResponse(
    allocator: std.mem.Allocator,
    data: []const u8,
) !transport_mod.RefDiscoveryResult {
    var refs_list = std.array_list.Managed(transport_mod.RemoteRef).init(allocator);
    defer refs_list.deinit();

    var caps_raw: ?[]u8 = null;
    var head_symref: ?[]u8 = null;

    var pos: usize = 0;
    var first_ref = true;

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

                // Skip service header line like "# service=git-upload-pack"
                if (std.mem.startsWith(u8, payload, "# ")) {
                    continue;
                }

                // Parse capabilities from first ref line
                if (first_ref) {
                    first_ref = false;
                    if (capabilities.extractCapsFromFirstLine(pkt.data)) |cs| {
                        caps_raw = try allocator.alloc(u8, cs.len);
                        @memcpy(caps_raw.?, cs);

                        // Extract symref for HEAD
                        var caps_obj = capabilities.Capabilities.init(allocator);
                        defer caps_obj.deinit();
                        caps_obj.parse(cs) catch {};
                        if (caps_obj.getValue("symref")) |sv| {
                            if (std.mem.startsWith(u8, sv, "HEAD:")) {
                                const target = sv[5..];
                                head_symref = try allocator.alloc(u8, target.len);
                                @memcpy(head_symref.?, target);
                            }
                        }
                    }
                }

                // Parse ref: OID SP refname
                if (payload.len < 41) continue;
                if (payload[40] != ' ') continue;

                const oid_hex = payload[0..40];
                var ref_name = payload[41..];

                // Strip NUL and capabilities
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

    return transport_mod.RefDiscoveryResult{
        .allocator = allocator,
        .refs = try refs_list.toOwnedSlice(),
        .capabilities_raw = caps_raw,
        .head_symref = head_symref,
    };
}

// --- URL building helpers ---

/// Build the info/refs URL for service discovery.
fn buildInfoRefsUrl(buf: []u8, base_url: []const u8, service: transport_mod.Service) ?[]const u8 {
    const service_name = service.name();
    // URL: base_url/info/refs?service=service_name

    // Strip trailing slash from base URL
    var base = base_url;
    while (base.len > 0 and base[base.len - 1] == '/') {
        base = base[0 .. base.len - 1];
    }

    const suffix = "/info/refs?service=";
    const total = base.len + suffix.len + service_name.len;
    if (total > buf.len) return null;

    var pos: usize = 0;
    @memcpy(buf[pos..][0..base.len], base);
    pos += base.len;
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    @memcpy(buf[pos..][0..service_name.len], service_name);
    pos += service_name.len;

    return buf[0..pos];
}

/// Build the service endpoint URL for POST requests.
fn buildServiceUrl(buf: []u8, base_url: []const u8, service_name: []const u8) ?[]const u8 {
    // Strip trailing slash
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

/// Build the expected content type for a service response.
fn buildServiceContentType(buf: []u8, service: transport_mod.Service, suffix: []const u8) ?[]const u8 {
    const service_name = service.name();
    // Format: "application/x-<service>-<suffix>"
    const prefix = "application/x-";
    const dash = "-";
    const total = prefix.len + service_name.len + dash.len + suffix.len;
    if (total > buf.len) return null;

    var pos: usize = 0;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos..][0..service_name.len], service_name);
    pos += service_name.len;
    @memcpy(buf[pos..][0..dash.len], dash);
    pos += dash.len;
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    return buf[0..pos];
}

/// Parse basic auth credentials from a URL.
/// Format: http://user:pass@host/path
pub fn extractBasicAuth(url_string: []const u8) ?struct { user: []const u8, pass: []const u8 } {
    const parsed = url_mod.parse(url_string) catch return null;
    const user = parsed.user orelse return null;

    // Check if user contains ':' (user:pass)
    if (std.mem.indexOfScalar(u8, user, ':')) |colon_pos| {
        return .{
            .user = user[0..colon_pos],
            .pass = user[colon_pos + 1 ..],
        };
    }

    return .{
        .user = user,
        .pass = "",
    };
}

// --- Tests ---

test "buildInfoRefsUrl" {
    var buf: [512]u8 = undefined;
    const url = buildInfoRefsUrl(&buf, "https://github.com/user/repo.git", .upload_pack).?;
    try std.testing.expectEqualStrings(
        "https://github.com/user/repo.git/info/refs?service=git-upload-pack",
        url,
    );
}

test "buildInfoRefsUrl trailing slash" {
    var buf: [512]u8 = undefined;
    const url = buildInfoRefsUrl(&buf, "https://github.com/user/repo.git/", .upload_pack).?;
    try std.testing.expectEqualStrings(
        "https://github.com/user/repo.git/info/refs?service=git-upload-pack",
        url,
    );
}

test "buildServiceUrl" {
    var buf: [512]u8 = undefined;
    const url = buildServiceUrl(&buf, "https://github.com/user/repo.git", "git-upload-pack").?;
    try std.testing.expectEqualStrings(
        "https://github.com/user/repo.git/git-upload-pack",
        url,
    );
}

test "buildServiceContentType" {
    var buf: [128]u8 = undefined;
    const ct = buildServiceContentType(&buf, .upload_pack, "advertisement").?;
    try std.testing.expectEqualStrings("application/x-git-upload-pack-advertisement", ct);
}

test "extractBasicAuth" {
    const auth = extractBasicAuth("https://user:pass@example.com/repo.git").?;
    try std.testing.expectEqualStrings("user", auth.user);
    try std.testing.expectEqualStrings("pass", auth.pass);
}

test "extractBasicAuth no password" {
    const auth = extractBasicAuth("https://user@example.com/repo.git").?;
    try std.testing.expectEqualStrings("user", auth.user);
    try std.testing.expectEqualStrings("", auth.pass);
}

test "extractBasicAuth none" {
    const result = extractBasicAuth("https://example.com/repo.git");
    try std.testing.expect(result == null);
}

test "parseRefAdvertisementResponse" {
    // Build a mock ref advertisement
    var mock_data = std.array_list.Managed(u8).init(std.testing.allocator);
    defer mock_data.deinit();

    try pkt_line.writePktLineList(&mock_data, "# service=git-upload-pack\n");
    try pkt_line.writeFlushList(&mock_data);
    try pkt_line.writePktLineList(&mock_data, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 HEAD\x00multi_ack side-band-64k\n");
    try pkt_line.writePktLineList(&mock_data, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 refs/heads/main\n");
    try pkt_line.writeFlushList(&mock_data);

    var result = try parseRefAdvertisementResponse(std.testing.allocator, mock_data.items);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.refs.len);
    try std.testing.expectEqualStrings("HEAD", result.refs[0].name);
    try std.testing.expectEqualStrings("refs/heads/main", result.refs[1].name);
    try std.testing.expect(result.capabilities_raw != null);
}
