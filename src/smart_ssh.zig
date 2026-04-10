const std = @import("std");
const types = @import("types.zig");
const pkt_line = @import("pkt_line.zig");
const capabilities = @import("capabilities.zig");
const transport_mod = @import("transport.zig");
const url_mod = @import("url.zig");
const smart_http = @import("smart_http.zig");

/// SSH transport for git clone/fetch/push.
///
/// Implements git transport over SSH by spawning an `ssh` subprocess that
/// runs `git-upload-pack` or `git-receive-pack` on the remote host.
///
/// Supported URL formats:
///   ssh://[user@]host[:port]/path
///   [user@]host:path  (SCP-style)
///   git@github.com:user/repo.git

const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Maximum response size (512 MB).
const MAX_RESPONSE: usize = 512 * 1024 * 1024;

// -----------------------------------------------------------------------
// Reference Discovery
// -----------------------------------------------------------------------

/// Discover refs from a remote SSH git repository.
/// Spawns: ssh [options] user@host "git-upload-pack '/path'"
/// Reads pkt-line ref advertisement from stdout.
pub fn discoverRefsSsh(
    allocator: std.mem.Allocator,
    url_string: []const u8,
    service: []const u8,
) !smart_http.DiscoverResult {
    const parsed = url_mod.parse(url_string) catch return error.InvalidUrl;

    // Build ssh command
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("ssh");
    try argv.append("-o");
    try argv.append("StrictHostKeyChecking=accept-new");
    try argv.append("-o");
    try argv.append("BatchMode=yes");

    // Port
    var port_buf: [16]u8 = undefined;
    if (parsed.port != 22 and parsed.port != 0) {
        try argv.append("-p");
        var fbs = std.io.fixedBufferStream(&port_buf);
        fbs.writer().print("{d}", .{parsed.port}) catch return error.BufferTooSmall;
        try argv.append(port_buf[0..fbs.pos]);
    }

    // user@host
    var host_buf: [512]u8 = undefined;
    var hpos: usize = 0;
    if (parsed.user) |user| {
        @memcpy(host_buf[hpos..][0..user.len], user);
        hpos += user.len;
        host_buf[hpos] = '@';
        hpos += 1;
    }
    const host = parsed.host orelse return error.NoHost;
    @memcpy(host_buf[hpos..][0..host.len], host);
    hpos += host.len;
    try argv.append(host_buf[0..hpos]);

    // Remote command: git-upload-pack '/path'
    var cmd_buf: [4096]u8 = undefined;
    var cpos: usize = 0;
    @memcpy(cmd_buf[cpos..][0..service.len], service);
    cpos += service.len;
    cmd_buf[cpos] = ' ';
    cpos += 1;
    cmd_buf[cpos] = '\'';
    cpos += 1;

    // For SCP-style, path doesn't start with /
    const path = parsed.path;
    if (path.len > 0 and path[0] != '/') {
        cmd_buf[cpos] = '/';
        cpos += 1;
    }
    @memcpy(cmd_buf[cpos..][0..path.len], path);
    cpos += path.len;
    cmd_buf[cpos] = '\'';
    cpos += 1;
    try argv.append(cmd_buf[0..cpos]);

    // Spawn
    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Close stdin immediately for ref discovery
    if (child.stdin) |stdin| {
        stdin.close();
        child.stdin = null;
    }

    // Read stdout
    const stdout_data = try readAllPipe(allocator, child.stdout.?);
    defer allocator.free(stdout_data);

    // Read stderr
    const stderr_data = try readAllPipe(allocator, child.stderr.?);
    defer allocator.free(stderr_data);

    const term = try child.wait();
    _ = term;

    if (stdout_data.len == 0) {
        if (stderr_data.len > 0) {
            stderr_file.writeAll(stderr_data) catch {};
        }
        return error.EmptyResponse;
    }

    // Parse pkt-line ref advertisement (same format as smart HTTP, but without
    // the "# service=..." preamble)
    return parseSshRefAdvertisement(allocator, stdout_data);
}

/// Parse SSH ref advertisement (no service header, just refs).
fn parseSshRefAdvertisement(allocator: std.mem.Allocator, data: []const u8) !smart_http.DiscoverResult {
    var refs_list = std.array_list.Managed(smart_http.DiscoveredRef).init(allocator);
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
                if (payload.len > 0 and payload[payload.len - 1] == '\n') {
                    payload = payload[0 .. payload.len - 1];
                }

                if (first_ref) {
                    first_ref = false;
                    if (capabilities.extractCapsFromFirstLine(pkt.data)) |cs| {
                        caps_raw = try allocator.alloc(u8, cs.len);
                        @memcpy(caps_raw.?, cs);

                        // Look for symref=HEAD:...
                        var iter = std.mem.splitScalar(u8, cs, ' ');
                        while (iter.next()) |token| {
                            if (std.mem.startsWith(u8, token, "symref=HEAD:")) {
                                const target = token["symref=HEAD:".len..];
                                head_symref = try allocator.alloc(u8, target.len);
                                @memcpy(head_symref.?, target);
                                break;
                            }
                        }
                    }
                }

                if (payload.len < 41) continue;
                if (payload[40] != ' ') continue;

                const oid_hex = payload[0..40];
                var ref_name = payload[41..];

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

    return smart_http.DiscoverResult{
        .allocator = allocator,
        .refs = try refs_list.toOwnedSlice(),
        .capabilities_str = caps_raw,
        .head_symref = head_symref,
    };
}

// -----------------------------------------------------------------------
// Fetch Pack (via SSH)
// -----------------------------------------------------------------------

/// Fetch pack data via SSH.
/// Spawns ssh with git-upload-pack, reads ref advertisement, sends wants/haves,
/// reads pack data from stdout.
pub fn fetchPackSsh(
    allocator: std.mem.Allocator,
    url_string: []const u8,
    wants: []const types.ObjectId,
    haves: []const types.ObjectId,
    server_caps_str: ?[]const u8,
) ![]u8 {
    if (wants.len == 0) return error.NoWants;

    const parsed = url_mod.parse(url_string) catch return error.InvalidUrl;

    // Parse server caps
    var server_caps = capabilities.Capabilities.init(allocator);
    defer server_caps.deinit();
    if (server_caps_str) |cs| {
        server_caps.parse(cs) catch {};
    }

    const use_side_band = server_caps.has("side-band-64k");
    const use_ofs_delta = server_caps.has("ofs-delta");

    // Build SSH argv
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("ssh");
    try argv.append("-o");
    try argv.append("StrictHostKeyChecking=accept-new");
    try argv.append("-o");
    try argv.append("BatchMode=yes");

    var port_buf: [16]u8 = undefined;
    if (parsed.port != 22 and parsed.port != 0) {
        try argv.append("-p");
        var fbs = std.io.fixedBufferStream(&port_buf);
        fbs.writer().print("{d}", .{parsed.port}) catch return error.BufferTooSmall;
        try argv.append(port_buf[0..fbs.pos]);
    }

    var host_buf: [512]u8 = undefined;
    var hpos: usize = 0;
    if (parsed.user) |user| {
        @memcpy(host_buf[hpos..][0..user.len], user);
        hpos += user.len;
        host_buf[hpos] = '@';
        hpos += 1;
    }
    const host = parsed.host orelse return error.NoHost;
    @memcpy(host_buf[hpos..][0..host.len], host);
    hpos += host.len;
    try argv.append(host_buf[0..hpos]);

    var cmd_buf: [4096]u8 = undefined;
    var cpos: usize = 0;
    const svc = "git-upload-pack";
    @memcpy(cmd_buf[cpos..][0..svc.len], svc);
    cpos += svc.len;
    cmd_buf[cpos] = ' ';
    cpos += 1;
    cmd_buf[cpos] = '\'';
    cpos += 1;
    const path = parsed.path;
    if (path.len > 0 and path[0] != '/') {
        cmd_buf[cpos] = '/';
        cpos += 1;
    }
    @memcpy(cmd_buf[cpos..][0..path.len], path);
    cpos += path.len;
    cmd_buf[cpos] = '\'';
    cpos += 1;
    try argv.append(cmd_buf[0..cpos]);

    // Spawn
    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Read the ref advertisement first (we already have it but protocol requires we read it)
    const ref_data = try readUntilFlush(allocator, child.stdout.?);
    defer allocator.free(ref_data);

    // Build want/have request
    var request = std.array_list.Managed(u8).init(allocator);
    defer request.deinit();

    var first_want = true;
    for (wants) |oid| {
        const hex = oid.toHex();
        if (first_want) {
            first_want = false;
            var caps_buf: [512]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&caps_buf);
            const writer = fbs.writer();
            writer.writeAll("multi_ack_detailed") catch {};
            if (use_side_band) writer.writeAll(" side-band-64k") catch {};
            if (use_ofs_delta) writer.writeAll(" ofs-delta") catch {};
            writer.writeAll(" thin-pack no-progress include-tag agent=zig-git/0.2.0") catch {};
            const client_caps = caps_buf[0..fbs.pos];
            try pkt_line.formatPktLineList(&request, "want {s} {s}\n", .{ &hex, client_caps });
        } else {
            try pkt_line.formatPktLineList(&request, "want {s}\n", .{&hex});
        }
    }

    try pkt_line.writeFlushList(&request);

    for (haves) |oid| {
        const hex = oid.toHex();
        try pkt_line.formatPktLineList(&request, "have {s}\n", .{&hex});
    }

    try pkt_line.writePktLineList(&request, "done\n");

    // Send to stdin
    if (child.stdin) |stdin| {
        stdin.writeAll(request.items) catch {};
        stdin.close();
        child.stdin = null;
    }

    // Read the response (NAK/ACK + pack data)
    const response = try readAllPipe(allocator, child.stdout.?);
    defer allocator.free(response);

    // Read stderr
    const stderr_data = try readAllPipe(allocator, child.stderr.?);
    defer allocator.free(stderr_data);

    const term = try child.wait();
    _ = term;

    // Extract pack data
    return smart_http.extractPackFromResponse(allocator, response, use_side_band) catch |err| {
        // If side-band extraction fails, try without
        if (err == error.NoPackData) {
            if (std.mem.indexOf(u8, response, "PACK")) |pack_pos| {
                const result = try allocator.alloc(u8, response.len - pack_pos);
                @memcpy(result, response[pack_pos..]);
                return result;
            }
        }
        return err;
    };
}

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

/// Read all data from a pipe.
fn readAllPipe(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var buf: [16384]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch break;
        if (n == 0) break;
        try result.appendSlice(buf[0..n]);
        if (result.items.len > MAX_RESPONSE) return error.ResponseTooLarge;
    }

    return result.toOwnedSlice();
}

/// Read pkt-lines from a pipe until a flush packet.
fn readUntilFlush(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var buf: [16384]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch break;
        if (n == 0) break;
        try result.appendSlice(buf[0..n]);

        // Check if we have a flush packet
        if (containsFlush(result.items)) break;

        if (result.items.len > MAX_RESPONSE) return error.ResponseTooLarge;
    }

    return result.toOwnedSlice();
}

/// Check if a buffer contains a flush packet.
fn containsFlush(data: []const u8) bool {
    var pos: usize = 0;
    while (pos < data.len) {
        const pkt = pkt_line.readPktLine(data, pos) catch return false;
        pos += pkt.bytes_consumed;
        if (pkt.packet_type == .flush) return true;
    }
    return false;
}
