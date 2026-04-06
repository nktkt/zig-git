const std = @import("std");
const types = @import("types.zig");
const url_mod = @import("url.zig");
const http_transport = @import("http_transport.zig");
const ssh_transport = @import("ssh_transport.zig");

/// Transport abstraction layer for git protocol communication.
///
/// Provides a unified interface for communicating with remote git repositories
/// over different transport protocols (HTTP/HTTPS, SSH, git://, local).

/// Reference as advertised by a remote server.
pub const RemoteRef = struct {
    oid: types.ObjectId,
    name: []const u8,

    /// Free the memory allocated for this ref (the name string).
    pub fn deinit(self: *RemoteRef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Result of reference discovery.
pub const RefDiscoveryResult = struct {
    allocator: std.mem.Allocator,
    refs: []RemoteRef,
    capabilities_raw: ?[]u8,
    head_symref: ?[]u8,

    pub fn deinit(self: *RefDiscoveryResult) void {
        for (self.refs) |*r| {
            self.allocator.free(@constCast(r.name));
        }
        self.allocator.free(self.refs);
        if (self.capabilities_raw) |c| self.allocator.free(c);
        if (self.head_symref) |h| self.allocator.free(h);
    }

    /// Find a ref by name.
    pub fn findRef(self: *const RefDiscoveryResult, name: []const u8) ?*const RemoteRef {
        for (self.refs) |*r| {
            if (std.mem.eql(u8, r.name, name)) return r;
        }
        return null;
    }

    /// Find HEAD ref.
    pub fn findHead(self: *const RefDiscoveryResult) ?*const RemoteRef {
        return self.findRef("HEAD");
    }
};

/// Result of a fetch pack operation.
pub const FetchPackResult = struct {
    allocator: std.mem.Allocator,
    pack_data: []u8,
    progress_messages: ?[]u8,

    pub fn deinit(self: *FetchPackResult) void {
        self.allocator.free(self.pack_data);
        if (self.progress_messages) |p| self.allocator.free(p);
    }
};

/// Result of a push pack operation.
pub const PushResult = struct {
    allocator: std.mem.Allocator,
    success: bool,
    messages: ?[]u8,

    pub fn deinit(self: *PushResult) void {
        if (self.messages) |m| self.allocator.free(m);
    }
};

/// Update command for push.
pub const RefUpdate = struct {
    old_oid: types.ObjectId,
    new_oid: types.ObjectId,
    ref_name: []const u8,
    force: bool,
};

/// Transport type enumeration.
pub const TransportType = enum {
    local,
    http,
    https,
    ssh,
    git,

    pub fn fromScheme(scheme: url_mod.Scheme) TransportType {
        return switch (scheme) {
            .http => .http,
            .https => .https,
            .ssh => .ssh,
            .git => .git,
            .file, .local => .local,
        };
    }
};

/// Transport connection handle.
/// This is a tagged union wrapping the actual transport implementation.
pub const Transport = struct {
    allocator: std.mem.Allocator,
    transport_type: TransportType,
    parsed_url: url_mod.GitUrl,
    url_string: []const u8,

    /// State for subprocess-based transports (SSH, git://).
    subprocess: ?SubprocessState,

    pub const SubprocessState = struct {
        process: ?std.process.Child,
        stdout_data: ?[]u8,
        stderr_data: ?[]u8,
    };

    /// Open a transport connection to the given URL.
    pub fn open(allocator: std.mem.Allocator, url_string: []const u8) !Transport {
        const parsed = url_mod.parse(url_string) catch return error.InvalidUrl;

        return Transport{
            .allocator = allocator,
            .transport_type = TransportType.fromScheme(parsed.scheme),
            .parsed_url = parsed,
            .url_string = url_string,
            .subprocess = null,
        };
    }

    /// Discover references from the remote.
    /// For HTTP: GET /info/refs?service=git-upload-pack
    /// For SSH: spawn ssh git-upload-pack and read pkt-lines
    /// For local: read refs directly from the filesystem
    pub fn discoverRefs(self: *Transport, service: Service) !RefDiscoveryResult {
        return switch (self.transport_type) {
            .http, .https => http_transport.discoverRefs(self.allocator, self.url_string, service),
            .ssh => ssh_transport.discoverRefs(self.allocator, self.url_string, service),
            .git => gitProtocolDiscoverRefs(self.allocator, &self.parsed_url, service),
            .local => localDiscoverRefs(self.allocator, &self.parsed_url),
        };
    }

    /// Fetch a pack from the remote using upload-pack protocol.
    pub fn fetchPack(
        self: *Transport,
        want_oids: []const types.ObjectId,
        have_oids: []const types.ObjectId,
    ) !FetchPackResult {
        return switch (self.transport_type) {
            .http, .https => http_transport.fetchPack(self.allocator, self.url_string, want_oids, have_oids),
            .ssh => ssh_transport.fetchPack(self.allocator, self.url_string, want_oids, have_oids),
            .git => gitProtocolFetchPack(self.allocator, &self.parsed_url, want_oids, have_oids),
            .local => error.LocalTransportUseDirectAccess,
        };
    }

    /// Push a pack to the remote using receive-pack protocol.
    pub fn pushPack(
        self: *Transport,
        updates: []const RefUpdate,
        pack_data: []const u8,
    ) !PushResult {
        return switch (self.transport_type) {
            .http, .https => http_transport.pushPack(self.allocator, self.url_string, updates, pack_data),
            .ssh => ssh_transport.pushPack(self.allocator, self.url_string, updates, pack_data),
            .git => error.GitProtocolPushNotSupported,
            .local => error.LocalTransportUseDirectAccess,
        };
    }

    /// Close the transport connection and free resources.
    pub fn close(self: *Transport) void {
        if (self.subprocess) |*sub| {
            if (sub.stdout_data) |d| self.allocator.free(d);
            if (sub.stderr_data) |d| self.allocator.free(d);
            if (sub.process) |*p| {
                _ = p.kill() catch {};
            }
        }
    }
};

/// Service type for ref discovery.
pub const Service = enum {
    upload_pack,
    receive_pack,

    pub fn name(self: Service) []const u8 {
        return switch (self) {
            .upload_pack => "git-upload-pack",
            .receive_pack => "git-receive-pack",
        };
    }
};

/// Auto-detect the transport type for a URL.
pub fn detectTransportType(url_string: []const u8) TransportType {
    const parsed = url_mod.parse(url_string) catch return .local;
    return TransportType.fromScheme(parsed.scheme);
}

/// Open a transport for the given URL.
pub fn openTransport(allocator: std.mem.Allocator, url_string: []const u8) !Transport {
    return Transport.open(allocator, url_string);
}

// --- Git protocol (git://) transport ---
// Uses TCP connection on port 9418.

fn gitProtocolDiscoverRefs(allocator: std.mem.Allocator, parsed_url: *const url_mod.GitUrl, service: Service) !RefDiscoveryResult {
    // For git:// protocol, we connect via TCP and send a request line.
    // For now, shell out to git for the actual protocol.
    _ = service;

    // Build the host string
    const host = parsed_url.host orelse return error.NoHost;
    _ = host;

    // Placeholder: git:// protocol requires raw TCP socket communication.
    // For the initial implementation, return an error suggesting use of SSH or HTTP.
    _ = allocator;
    return error.GitProtocolNotYetImplemented;
}

fn gitProtocolFetchPack(
    allocator: std.mem.Allocator,
    parsed_url: *const url_mod.GitUrl,
    want_oids: []const types.ObjectId,
    have_oids: []const types.ObjectId,
) !FetchPackResult {
    _ = allocator;
    _ = parsed_url;
    _ = want_oids;
    _ = have_oids;
    return error.GitProtocolNotYetImplemented;
}

// --- Local transport ---

fn localDiscoverRefs(allocator: std.mem.Allocator, parsed_url: *const url_mod.GitUrl) !RefDiscoveryResult {
    // For local transport, we read refs directly from the filesystem.
    // This is a simplified version; the full implementation would use
    // the repository module.
    const path = parsed_url.path;

    // Check if path/.git exists or path itself is a bare repo
    var git_dir_buf: [4096]u8 = undefined;
    const git_dir = findLocalGitDir(path, &git_dir_buf) orelse return error.RepositoryNotFound;

    // Read refs from the directory
    var refs_list = std.array_list.Managed(RemoteRef).init(allocator);
    defer refs_list.deinit();

    // Read HEAD
    var head_buf: [4096]u8 = undefined;
    const head_path = concatPath(&head_buf, git_dir, "/HEAD");
    if (readFileSimple(allocator, head_path)) |head_content| {
        defer allocator.free(head_content);
        const trimmed = std.mem.trimRight(u8, head_content, "\n\r ");
        // If HEAD is a symbolic ref, resolve it
        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const ref_target = trimmed[5..];
            var ref_path_buf: [4096]u8 = undefined;
            var pos: usize = 0;
            @memcpy(ref_path_buf[pos..][0..git_dir.len], git_dir);
            pos += git_dir.len;
            ref_path_buf[pos] = '/';
            pos += 1;
            @memcpy(ref_path_buf[pos..][0..ref_target.len], ref_target);
            pos += ref_target.len;
            const ref_file_path = ref_path_buf[0..pos];

            if (readFileSimple(allocator, ref_file_path)) |ref_content| {
                defer allocator.free(ref_content);
                const ref_trimmed = std.mem.trimRight(u8, ref_content, "\n\r ");
                if (ref_trimmed.len >= 40) {
                    const oid = types.ObjectId.fromHex(ref_trimmed[0..40]) catch
                        types.ObjectId.ZERO;
                    const name_copy = try allocator.alloc(u8, 4);
                    @memcpy(name_copy, "HEAD");
                    try refs_list.append(.{ .oid = oid, .name = name_copy });
                }
            }
        } else if (trimmed.len >= 40) {
            const oid = types.ObjectId.fromHex(trimmed[0..40]) catch types.ObjectId.ZERO;
            const name_copy = try allocator.alloc(u8, 4);
            @memcpy(name_copy, "HEAD");
            try refs_list.append(.{ .oid = oid, .name = name_copy });
        }
    }

    // Read refs/heads/ and refs/tags/
    try readRefsDir(allocator, git_dir, "refs/heads", &refs_list);
    try readRefsDir(allocator, git_dir, "refs/tags", &refs_list);

    return RefDiscoveryResult{
        .allocator = allocator,
        .refs = try refs_list.toOwnedSlice(),
        .capabilities_raw = null,
        .head_symref = null,
    };
}

fn readRefsDir(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    prefix: []const u8,
    refs_list: *std.array_list.Managed(RemoteRef),
) !void {
    var dir_path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(dir_path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    dir_path_buf[pos] = '/';
    pos += 1;
    @memcpy(dir_path_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    const dir_path = dir_path_buf[0..pos];

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        // Build full file path
        var file_path_buf: [4096]u8 = undefined;
        var fpos: usize = 0;
        @memcpy(file_path_buf[fpos..][0..dir_path.len], dir_path);
        fpos += dir_path.len;
        file_path_buf[fpos] = '/';
        fpos += 1;
        @memcpy(file_path_buf[fpos..][0..entry.name.len], entry.name);
        fpos += entry.name.len;
        const file_path = file_path_buf[0..fpos];

        if (readFileSimple(allocator, file_path)) |content| {
            defer allocator.free(content);
            const trimmed = std.mem.trimRight(u8, content, "\n\r ");
            if (trimmed.len >= 40) {
                const oid = types.ObjectId.fromHex(trimmed[0..40]) catch continue;

                // Build ref name: prefix/entry.name
                var ref_name_buf: [512]u8 = undefined;
                var rpos: usize = 0;
                @memcpy(ref_name_buf[rpos..][0..prefix.len], prefix);
                rpos += prefix.len;
                ref_name_buf[rpos] = '/';
                rpos += 1;
                @memcpy(ref_name_buf[rpos..][0..entry.name.len], entry.name);
                rpos += entry.name.len;

                const name_copy = try allocator.alloc(u8, rpos);
                @memcpy(name_copy, ref_name_buf[0..rpos]);
                try refs_list.append(.{ .oid = oid, .name = name_copy });
            }
        }
    }
}

// --- Helpers ---

fn findLocalGitDir(path: []const u8, buf: []u8) ?[]const u8 {
    // Check path/.git
    const git_suffix = "/.git";
    if (path.len + git_suffix.len <= buf.len) {
        @memcpy(buf[0..path.len], path);
        @memcpy(buf[path.len..][0..git_suffix.len], git_suffix);
        const git_path = buf[0 .. path.len + git_suffix.len];
        if (isDirectory(git_path)) return git_path;
    }

    // Check if path itself is a bare repo
    const head_suffix = "/HEAD";
    if (path.len + head_suffix.len <= buf.len) {
        @memcpy(buf[0..path.len], path);
        @memcpy(buf[path.len..][0..head_suffix.len], head_suffix);
        const head_path = buf[0 .. path.len + head_suffix.len];
        if (isFile(head_path)) {
            @memcpy(buf[0..path.len], path);
            return buf[0..path.len];
        }
    }

    return null;
}

fn concatPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn isDirectory(path: []const u8) bool {
    const dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    @constCast(&dir).close();
    return true;
}

fn isFile(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    @constCast(&file).close();
    return true;
}

fn readFileSimple(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    if (stat.size > 1024 * 1024) return null;
    const buf = allocator.alloc(u8, @intCast(stat.size)) catch return null;
    const n = file.readAll(buf) catch {
        allocator.free(buf);
        return null;
    };
    if (n < buf.len) {
        const trimmed = allocator.alloc(u8, n) catch {
            allocator.free(buf);
            return null;
        };
        @memcpy(trimmed, buf[0..n]);
        allocator.free(buf);
        return trimmed;
    }
    return buf;
}

// --- Tests ---

test "detectTransportType" {
    try std.testing.expectEqual(TransportType.https, detectTransportType("https://github.com/user/repo.git"));
    try std.testing.expectEqual(TransportType.http, detectTransportType("http://example.com/repo.git"));
    try std.testing.expectEqual(TransportType.ssh, detectTransportType("ssh://git@github.com/repo.git"));
    try std.testing.expectEqual(TransportType.ssh, detectTransportType("git@github.com:user/repo.git"));
    try std.testing.expectEqual(TransportType.git, detectTransportType("git://example.com/repo.git"));
    try std.testing.expectEqual(TransportType.local, detectTransportType("/path/to/repo"));
    try std.testing.expectEqual(TransportType.local, detectTransportType("file:///path/to/repo"));
}

test "Transport.open" {
    var t = try Transport.open(std.testing.allocator, "https://github.com/user/repo.git");
    defer t.close();
    try std.testing.expectEqual(TransportType.https, t.transport_type);
}

test "Service name" {
    try std.testing.expectEqualStrings("git-upload-pack", Service.upload_pack.name());
    try std.testing.expectEqualStrings("git-receive-pack", Service.receive_pack.name());
}
