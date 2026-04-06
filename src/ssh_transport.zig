const std = @import("std");
const types = @import("types.zig");
const pkt_line = @import("pkt_line.zig");
const capabilities = @import("capabilities.zig");
const transport_mod = @import("transport.zig");
const url_mod = @import("url.zig");
const upload_pack = @import("upload_pack.zig");
const receive_pack = @import("receive_pack.zig");

/// SSH transport for git.
///
/// Implements git transport over SSH by spawning an `ssh` subprocess.
/// The SSH transport communicates with `git-upload-pack` (for fetch/clone)
/// or `git-receive-pack` (for push) on the remote host.
///
/// Supported URL formats:
///   ssh://[user@]host[:port]/path
///   [user@]host:path  (SCP-style)
///   git@github.com:user/repo.git

const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Maximum response size (256 MB).
const MAX_RESPONSE_SIZE: usize = 256 * 1024 * 1024;

/// SSH connection state.
pub const SshConnection = struct {
    allocator: std.mem.Allocator,
    process: std.process.Child,
    url: url_mod.GitUrl,

    /// Close the SSH connection.
    pub fn close(self: *SshConnection) void {
        if (self.process.stdin) |stdin| {
            @constCast(&stdin).close();
        }
        _ = self.process.kill() catch {};
    }
};

/// Parse an SSH URL and return the components needed for spawning ssh.
pub fn parseSshUrl(url_string: []const u8) !SshComponents {
    const parsed = url_mod.parse(url_string) catch return error.InvalidUrl;

    if (parsed.scheme != .ssh) return error.NotSshUrl;

    return SshComponents{
        .user = parsed.user,
        .host = parsed.host orelse return error.NoHost,
        .port = parsed.port,
        .path = parsed.path,
    };
}

pub const SshComponents = struct {
    user: ?[]const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
};

/// Build the SSH command arguments for connecting to a remote.
/// Returns a list of argument strings. Caller does NOT own the strings
/// (they point into buf or the input components).
pub fn buildSshArgs(
    components: *const SshComponents,
    service: transport_mod.Service,
    host_buf: []u8,
    cmd_buf: []u8,
    port_buf: []u8,
) !SshArgs {
    var result: SshArgs = .{
        .args = undefined,
        .count = 0,
    };

    // ssh
    result.args[result.count] = "ssh";
    result.count += 1;

    // -o StrictHostKeyChecking=accept-new (don't prompt)
    result.args[result.count] = "-o";
    result.count += 1;
    result.args[result.count] = "StrictHostKeyChecking=accept-new";
    result.count += 1;

    // -o BatchMode=yes (no interactive prompts)
    result.args[result.count] = "-o";
    result.count += 1;
    result.args[result.count] = "BatchMode=yes";
    result.count += 1;

    // Port (if non-standard)
    if (components.port != 22 and components.port != 0) {
        result.args[result.count] = "-p";
        result.count += 1;

        var fbs = std.io.fixedBufferStream(port_buf);
        fbs.writer().print("{d}", .{components.port}) catch return error.BufferTooSmall;
        result.args[result.count] = port_buf[0..fbs.pos];
        result.count += 1;
    }

    // user@host or just host
    if (components.user) |user| {
        var pos: usize = 0;
        @memcpy(host_buf[pos..][0..user.len], user);
        pos += user.len;
        host_buf[pos] = '@';
        pos += 1;
        @memcpy(host_buf[pos..][0..components.host.len], components.host);
        pos += components.host.len;
        result.args[result.count] = host_buf[0..pos];
    } else {
        @memcpy(host_buf[0..components.host.len], components.host);
        result.args[result.count] = host_buf[0..components.host.len];
    }
    result.count += 1;

    // Command: git-upload-pack 'path' or git-receive-pack 'path'
    const svc_name = service.name();
    var pos: usize = 0;
    @memcpy(cmd_buf[pos..][0..svc_name.len], svc_name);
    pos += svc_name.len;
    cmd_buf[pos] = ' ';
    pos += 1;
    cmd_buf[pos] = '\'';
    pos += 1;

    // Handle the path: for SCP-style URLs, path doesn't start with /
    const path = components.path;
    if (path.len > 0 and path[0] != '/') {
        // SCP-style: prepend /
        cmd_buf[pos] = '/';
        pos += 1;
    }
    @memcpy(cmd_buf[pos..][0..path.len], path);
    pos += path.len;
    cmd_buf[pos] = '\'';
    pos += 1;

    result.args[result.count] = cmd_buf[0..pos];
    result.count += 1;

    return result;
}

pub const SshArgs = struct {
    args: [16][]const u8,
    count: usize,

    pub fn slice(self: *const SshArgs) []const []const u8 {
        return self.args[0..self.count];
    }
};

/// Spawn an SSH process for the given service.
fn spawnSsh(
    allocator: std.mem.Allocator,
    url_string: []const u8,
    service: transport_mod.Service,
) !std.process.Child {
    const parsed = url_mod.parse(url_string) catch return error.InvalidUrl;

    if (!parsed.isSsh()) return error.NotSshUrl;

    const components = SshComponents{
        .user = parsed.user,
        .host = parsed.host orelse return error.NoHost,
        .port = parsed.port,
        .path = parsed.path,
    };

    var host_buf: [512]u8 = undefined;
    var cmd_buf: [4096]u8 = undefined;
    var port_buf: [16]u8 = undefined;

    const ssh_args = try buildSshArgs(&components, service, &host_buf, &cmd_buf, &port_buf);

    var child = std.process.Child.init(ssh_args.slice(), allocator);
    child.stdin_behavior = .pipe;
    child.stdout_behavior = .pipe;
    child.stderr_behavior = .pipe;

    try child.spawn();
    return child;
}

/// Discover references from a remote SSH git repository.
pub fn discoverRefs(
    allocator: std.mem.Allocator,
    url_string: []const u8,
    service: transport_mod.Service,
) !transport_mod.RefDiscoveryResult {
    var child = try spawnSsh(allocator, url_string, service);

    // Close stdin - we don't send anything for ref discovery
    if (child.stdin) |stdin| {
        @constCast(&stdin).close();
        child.stdin = null;
    }

    // Read stdout (ref advertisement)
    const stdout_data = try readAllFromPipe(allocator, child.stdout.?);
    defer allocator.free(stdout_data);

    // Read stderr
    const stderr_data = try readAllFromPipe(allocator, child.stderr.?);
    defer allocator.free(stderr_data);

    const term = try child.wait();
    _ = term;

    // Parse the ref advertisement (pkt-line format)
    return parseRefAdvertisement(allocator, stdout_data);
}

/// Fetch a pack from a remote SSH git repository.
pub fn fetchPack(
    allocator: std.mem.Allocator,
    url_string: []const u8,
    want_oids: []const types.ObjectId,
    have_oids: []const types.ObjectId,
) !transport_mod.FetchPackResult {
    var child = try spawnSsh(allocator, url_string, .upload_pack);

    // Read the ref advertisement first
    // We need to read refs before sending wants
    const ref_data = try readUntilFlush(allocator, child.stdout.?);
    defer allocator.free(ref_data);

    // Parse to get capabilities
    var session = upload_pack.UploadPackSession.init(allocator);
    defer session.deinit();
    session.parseRefAdvertisement(ref_data) catch {};

    // Build negotiation request
    const request = try session.buildNegotiationRequest(want_oids, have_oids);
    defer allocator.free(request);

    // Send the request
    if (child.stdin) |stdin| {
        @constCast(&stdin).writeAll(request) catch {};
        @constCast(&stdin).close();
        child.stdin = null;
    }

    // Read the response (ACKs + pack data)
    const response_data = try readAllFromPipe(allocator, child.stdout.?);
    defer allocator.free(response_data);

    // Read stderr for progress
    const stderr_data = try readAllFromPipe(allocator, child.stderr.?);

    const term = try child.wait();
    _ = term;

    // Extract pack data
    const pack_data = upload_pack.extractPackData(
        allocator,
        response_data,
        session.use_side_band_64k,
    ) catch {
        allocator.free(stderr_data);
        return error.NoPackData;
    };

    return transport_mod.FetchPackResult{
        .allocator = allocator,
        .pack_data = pack_data,
        .progress_messages = if (stderr_data.len > 0) stderr_data else blk: {
            allocator.free(stderr_data);
            break :blk null;
        },
    };
}

/// Push a pack to a remote SSH git repository.
pub fn pushPack(
    allocator: std.mem.Allocator,
    url_string: []const u8,
    updates: []const transport_mod.RefUpdate,
    pack_data: []const u8,
) !transport_mod.PushResult {
    var child = try spawnSsh(allocator, url_string, .receive_pack);

    // Read ref advertisement
    const ref_data = try readUntilFlush(allocator, child.stdout.?);
    defer allocator.free(ref_data);

    // Parse to get capabilities
    var session = receive_pack.ReceivePackSession.init(allocator);
    defer session.deinit();
    session.parseRefAdvertisement(ref_data) catch {};

    // Build update commands
    const commands = try session.buildUpdateCommands(updates);
    defer allocator.free(commands);

    // Send commands + pack data
    if (child.stdin) |stdin| {
        @constCast(&stdin).writeAll(commands) catch {};
        @constCast(&stdin).writeAll(pack_data) catch {};
        @constCast(&stdin).close();
        child.stdin = null;
    }

    // Read response
    const response_data = try readAllFromPipe(allocator, child.stdout.?);
    defer allocator.free(response_data);

    // Read stderr
    const stderr_data = try readAllFromPipe(allocator, child.stderr.?);
    defer allocator.free(stderr_data);

    const term = try child.wait();
    _ = term;

    // Parse report-status if available
    if (response_data.len > 0 and session.use_report_status) {
        var report = receive_pack.parseReportStatus(allocator, response_data) catch {
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

/// Parse the ref advertisement from SSH output (pkt-line format).
fn parseRefAdvertisement(
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
                if (payload.len > 0 and payload[payload.len - 1] == '\n') {
                    payload = payload[0 .. payload.len - 1];
                }

                // First ref line has capabilities
                if (first_ref) {
                    first_ref = false;
                    if (capabilities.extractCapsFromFirstLine(pkt.data)) |cs| {
                        caps_raw = try allocator.alloc(u8, cs.len);
                        @memcpy(caps_raw.?, cs);

                        // Extract symref
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

                // Parse: OID SP refname
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

    return transport_mod.RefDiscoveryResult{
        .allocator = allocator,
        .refs = try refs_list.toOwnedSlice(),
        .capabilities_raw = caps_raw,
        .head_symref = head_symref,
    };
}

/// Read all data from a pipe until EOF.
fn readAllFromPipe(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
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

/// Read pkt-lines from a pipe until a flush packet.
fn readUntilFlush(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    // Read data in chunks and look for flush packet
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch break;
        if (n == 0) break;
        try result.appendSlice(buf[0..n]);

        // Check if we've received a flush packet
        if (containsFlush(result.items)) break;

        if (result.items.len > MAX_RESPONSE_SIZE) return error.ResponseTooLarge;
    }

    return result.toOwnedSlice();
}

/// Check if a buffer of pkt-lines contains a flush packet.
fn containsFlush(data: []const u8) bool {
    var pos: usize = 0;
    while (pos < data.len) {
        const pkt = pkt_line.readPktLine(data, pos) catch return false;
        pos += pkt.bytes_consumed;
        if (pkt.packet_type == .flush) return true;
    }
    return false;
}

// --- Tests ---

test "parseSshUrl" {
    const components = try parseSshUrl("ssh://git@github.com/user/repo.git");
    try std.testing.expectEqualStrings("git", components.user.?);
    try std.testing.expectEqualStrings("github.com", components.host);
    try std.testing.expectEqualStrings("/user/repo.git", components.path);
}

test "parseSshUrl SCP-style" {
    const components = try parseSshUrl("git@github.com:user/repo.git");
    try std.testing.expectEqualStrings("git", components.user.?);
    try std.testing.expectEqualStrings("github.com", components.host);
    try std.testing.expectEqualStrings("user/repo.git", components.path);
}

test "buildSshArgs upload-pack" {
    const components = SshComponents{
        .user = "git",
        .host = "github.com",
        .port = 22,
        .path = "/user/repo.git",
    };

    var host_buf: [512]u8 = undefined;
    var cmd_buf: [4096]u8 = undefined;
    var port_buf: [16]u8 = undefined;

    const args = try buildSshArgs(&components, .upload_pack, &host_buf, &cmd_buf, &port_buf);

    // Should have: ssh, -o, StrictHostKeyChecking=accept-new, -o, BatchMode=yes, git@github.com, command
    try std.testing.expect(args.count >= 6);

    // Check that git@github.com is in the args
    var found_host = false;
    for (args.slice()) |arg| {
        if (std.mem.eql(u8, arg, "git@github.com")) {
            found_host = true;
            break;
        }
    }
    try std.testing.expect(found_host);
}

test "buildSshArgs with non-standard port" {
    const components = SshComponents{
        .user = "git",
        .host = "example.com",
        .port = 2222,
        .path = "/repo.git",
    };

    var host_buf: [512]u8 = undefined;
    var cmd_buf: [4096]u8 = undefined;
    var port_buf: [16]u8 = undefined;

    const args = try buildSshArgs(&components, .upload_pack, &host_buf, &cmd_buf, &port_buf);

    // Should include -p 2222
    var found_port_flag = false;
    for (args.slice(), 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.count) {
                try std.testing.expectEqualStrings("2222", args.args[i + 1]);
                found_port_flag = true;
            }
            break;
        }
    }
    try std.testing.expect(found_port_flag);
}

test "containsFlush" {
    var data = std.array_list.Managed(u8).init(std.testing.allocator);
    defer data.deinit();

    try pkt_line.writePktLineList(&data, "hello\n");
    try std.testing.expect(!containsFlush(data.items));

    try pkt_line.writeFlushList(&data);
    try std.testing.expect(containsFlush(data.items));
}

test "parseRefAdvertisement" {
    var mock_data = std.array_list.Managed(u8).init(std.testing.allocator);
    defer mock_data.deinit();

    try pkt_line.writePktLineList(&mock_data, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 HEAD\x00multi_ack side-band-64k symref=HEAD:refs/heads/main\n");
    try pkt_line.writePktLineList(&mock_data, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 refs/heads/main\n");
    try pkt_line.writeFlushList(&mock_data);

    var result = try parseRefAdvertisement(std.testing.allocator, mock_data.items);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.refs.len);
    try std.testing.expectEqualStrings("HEAD", result.refs[0].name);
    try std.testing.expectEqualStrings("refs/heads/main", result.refs[1].name);
    try std.testing.expect(result.capabilities_raw != null);
    try std.testing.expect(result.head_symref != null);
    try std.testing.expectEqualStrings("refs/heads/main", result.head_symref.?);
}
