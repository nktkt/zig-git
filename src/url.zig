const std = @import("std");

/// Git URL parsing and manipulation.
///
/// Supports the following URL formats:
///   - http://host[:port]/path
///   - https://host[:port]/path
///   - ssh://[user@]host[:port]/path
///   - git://host[:port]/path
///   - file:///path
///   - [user@]host:path  (SCP-style, implies SSH)
///   - /absolute/path    (local)
///   - relative/path     (local)

pub const Scheme = enum {
    http,
    https,
    ssh,
    git,
    file,
    local,

    pub fn defaultPort(self: Scheme) u16 {
        return switch (self) {
            .http => 80,
            .https => 443,
            .ssh => 22,
            .git => 9418,
            .file, .local => 0,
        };
    }

    pub fn toString(self: Scheme) []const u8 {
        return switch (self) {
            .http => "http",
            .https => "https",
            .ssh => "ssh",
            .git => "git",
            .file => "file",
            .local => "",
        };
    }
};

/// Parsed Git URL.
pub const GitUrl = struct {
    scheme: Scheme,
    user: ?[]const u8,
    host: ?[]const u8,
    port: u16,
    path: []const u8,

    /// Check if this URL refers to a local path.
    pub fn isLocal(self: *const GitUrl) bool {
        return self.scheme == .file or self.scheme == .local;
    }

    /// Check if this URL uses SSH transport.
    pub fn isSsh(self: *const GitUrl) bool {
        return self.scheme == .ssh;
    }

    /// Check if this URL uses HTTP(S) transport.
    pub fn isHttp(self: *const GitUrl) bool {
        return self.scheme == .http or self.scheme == .https;
    }

    /// Check if this URL uses the native git protocol.
    pub fn isGit(self: *const GitUrl) bool {
        return self.scheme == .git;
    }

    /// Reconstruct the URL as a string into a buffer.
    /// Returns the slice of buf that was written.
    pub fn format(self: *const GitUrl, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        switch (self.scheme) {
            .local => {
                try writer.writeAll(self.path);
            },
            .file => {
                try writer.writeAll("file://");
                try writer.writeAll(self.path);
            },
            .ssh => {
                // If no explicit port and standard SSH, use SCP-style
                if (self.port == 22 or self.port == 0) {
                    if (self.user) |u| {
                        try writer.writeAll(u);
                        try writer.writeByte('@');
                    }
                    if (self.host) |h| {
                        try writer.writeAll(h);
                    }
                    try writer.writeByte(':');
                    // For SCP-style, path shouldn't start with /
                    const p = if (self.path.len > 0 and self.path[0] == '/')
                        self.path[1..]
                    else
                        self.path;
                    try writer.writeAll(p);
                } else {
                    try writer.writeAll("ssh://");
                    if (self.user) |u| {
                        try writer.writeAll(u);
                        try writer.writeByte('@');
                    }
                    if (self.host) |h| {
                        try writer.writeAll(h);
                    }
                    try writer.print(":{d}", .{self.port});
                    try writer.writeAll(self.path);
                }
            },
            .http, .https, .git => {
                try writer.writeAll(self.scheme.toString());
                try writer.writeAll("://");
                if (self.user) |u| {
                    try writer.writeAll(u);
                    try writer.writeByte('@');
                }
                if (self.host) |h| {
                    try writer.writeAll(h);
                }
                const default_port = self.scheme.defaultPort();
                if (self.port != default_port and self.port != 0) {
                    try writer.print(":{d}", .{self.port});
                }
                try writer.writeAll(self.path);
            },
        }

        return buf[0..fbs.pos];
    }

    /// Get the host and port as a "host:port" string, using default port if not specified.
    pub fn hostPort(self: *const GitUrl, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        const h = self.host orelse return error.NoHost;
        try writer.writeAll(h);

        const port = if (self.port != 0) self.port else self.scheme.defaultPort();
        if (port != 0) {
            try writer.print(":{d}", .{port});
        }

        return buf[0..fbs.pos];
    }
};

pub const ParseError = error{
    InvalidUrl,
    EmptyUrl,
};

/// Parse a git URL string into a GitUrl struct.
/// The returned GitUrl references slices of the input string directly.
pub fn parse(url_string: []const u8) ParseError!GitUrl {
    if (url_string.len == 0) return ParseError.EmptyUrl;

    // Check for scheme://
    if (std.mem.indexOf(u8, url_string, "://")) |scheme_end| {
        const scheme_str = url_string[0..scheme_end];
        const after_scheme = url_string[scheme_end + 3 ..];

        if (std.mem.eql(u8, scheme_str, "file")) {
            // file:///path
            return GitUrl{
                .scheme = .file,
                .user = null,
                .host = null,
                .port = 0,
                .path = after_scheme,
            };
        }

        const scheme: Scheme = if (std.mem.eql(u8, scheme_str, "http"))
            .http
        else if (std.mem.eql(u8, scheme_str, "https"))
            .https
        else if (std.mem.eql(u8, scheme_str, "ssh"))
            .ssh
        else if (std.mem.eql(u8, scheme_str, "git"))
            .git
        else
            return ParseError.InvalidUrl;

        return parseAuthorityPath(after_scheme, scheme);
    }

    // Check for SCP-style: [user@]host:path
    // Must contain a colon but NOT start with / (which would be an absolute path)
    // and the colon must not be preceded only by a drive letter (Windows)
    if (url_string[0] != '/' and url_string[0] != '.') {
        if (isSCPStyle(url_string)) {
            return parseSCPStyle(url_string);
        }
    }

    // Local path
    return GitUrl{
        .scheme = .local,
        .user = null,
        .host = null,
        .port = 0,
        .path = url_string,
    };
}

/// Check if a URL string looks like an SCP-style git URL.
/// SCP-style: [user@]host:path where the colon is followed by a non-digit
/// (to distinguish from host:port in scheme:// URLs).
fn isSCPStyle(s: []const u8) bool {
    // Must contain a colon
    const colon_pos = std.mem.indexOfScalar(u8, s, ':') orelse return false;

    // Must have something before the colon (host or user@host)
    if (colon_pos == 0) return false;

    // The part before the colon should not contain slashes (that would be a path)
    const before_colon = s[0..colon_pos];
    if (std.mem.indexOfScalar(u8, before_colon, '/') != null) return false;

    // After the colon, the next char must not be a digit (that would be a port)
    // or it could be empty which would be host: (still SCP-style for an empty path)
    if (colon_pos + 1 < s.len) {
        const next = s[colon_pos + 1];
        // If followed by // it's actually a scheme://
        if (next == '/') {
            if (colon_pos + 2 < s.len and s[colon_pos + 2] == '/') {
                return false;
            }
        }
    }

    return true;
}

/// Parse an SCP-style URL: [user@]host:path
fn parseSCPStyle(s: []const u8) ParseError!GitUrl {
    const colon_pos = std.mem.indexOfScalar(u8, s, ':') orelse return ParseError.InvalidUrl;

    const authority = s[0..colon_pos];
    const path = s[colon_pos + 1 ..];

    var user: ?[]const u8 = null;
    var host: []const u8 = authority;

    if (std.mem.indexOfScalar(u8, authority, '@')) |at_pos| {
        user = authority[0..at_pos];
        host = authority[at_pos + 1 ..];
    }

    if (host.len == 0) return ParseError.InvalidUrl;

    return GitUrl{
        .scheme = .ssh,
        .user = user,
        .host = host,
        .port = 22,
        .path = path,
    };
}

/// Parse authority (user@host:port) and path from after the scheme://.
fn parseAuthorityPath(s: []const u8, scheme: Scheme) ParseError!GitUrl {
    if (s.len == 0) return ParseError.InvalidUrl;

    // Split into authority and path at the first /
    var authority: []const u8 = s;
    var path: []const u8 = "/";

    if (std.mem.indexOfScalar(u8, s, '/')) |slash_pos| {
        authority = s[0..slash_pos];
        path = s[slash_pos..];
    }

    // Parse user@host:port from authority
    var user: ?[]const u8 = null;
    var host_part: []const u8 = authority;

    // Extract user@ if present
    if (std.mem.indexOfScalar(u8, authority, '@')) |at_pos| {
        user = authority[0..at_pos];
        host_part = authority[at_pos + 1 ..];
    }

    // Extract port if present
    var host: []const u8 = host_part;
    var port: u16 = scheme.defaultPort();

    // Look for :port (but be careful with IPv6 brackets)
    if (host_part.len > 0 and host_part[0] == '[') {
        // IPv6: [::1]:port
        if (std.mem.indexOfScalar(u8, host_part, ']')) |bracket_end| {
            host = host_part[0 .. bracket_end + 1];
            if (bracket_end + 1 < host_part.len and host_part[bracket_end + 1] == ':') {
                const port_str = host_part[bracket_end + 2 ..];
                port = std.fmt.parseInt(u16, port_str, 10) catch scheme.defaultPort();
            }
        }
    } else {
        // Regular host: check for trailing :port
        if (std.mem.lastIndexOfScalar(u8, host_part, ':')) |colon_pos| {
            const port_str = host_part[colon_pos + 1 ..];
            if (port_str.len > 0) {
                if (std.fmt.parseInt(u16, port_str, 10)) |p| {
                    host = host_part[0..colon_pos];
                    port = p;
                } else |_| {
                    // Not a valid port number, treat entire thing as host
                }
            }
        }
    }

    if (host.len == 0) return ParseError.InvalidUrl;

    return GitUrl{
        .scheme = scheme,
        .user = user,
        .host = host,
        .port = port,
        .path = path,
    };
}

/// Check if a URL string represents a local path.
pub fn isLocal(url_string: []const u8) bool {
    if (url_string.len == 0) return false;
    if (std.mem.startsWith(u8, url_string, "file://")) return true;
    if (url_string[0] == '/' or url_string[0] == '.') return true;
    // Check for scheme://
    if (std.mem.indexOf(u8, url_string, "://") != null) return false;
    // Check for SCP-style
    if (isSCPStyle(url_string)) return false;
    // Default: assume relative local path
    return true;
}

/// Extract the repository name from a URL (for use as the clone directory).
/// Example: "https://github.com/user/repo.git" -> "repo"
pub fn repoName(url_string: []const u8) []const u8 {
    const parsed = parse(url_string) catch return url_string;

    var path = parsed.path;

    // Strip trailing slashes
    while (path.len > 1 and path[path.len - 1] == '/') {
        path = path[0 .. path.len - 1];
    }

    // Get basename
    const basename = std.fs.path.basename(path);

    // Strip .git extension
    if (std.mem.endsWith(u8, basename, ".git") and basename.len > 4) {
        return basename[0 .. basename.len - 4];
    }

    return basename;
}

// --- Tests ---

test "parse http URL" {
    const url = try parse("http://example.com/repo.git");
    try std.testing.expectEqual(Scheme.http, url.scheme);
    try std.testing.expect(url.user == null);
    try std.testing.expectEqualStrings("example.com", url.host.?);
    try std.testing.expectEqual(@as(u16, 80), url.port);
    try std.testing.expectEqualStrings("/repo.git", url.path);
}

test "parse https URL with port" {
    const url = try parse("https://example.com:8443/repo.git");
    try std.testing.expectEqual(Scheme.https, url.scheme);
    try std.testing.expectEqualStrings("example.com", url.host.?);
    try std.testing.expectEqual(@as(u16, 8443), url.port);
    try std.testing.expectEqualStrings("/repo.git", url.path);
}

test "parse https URL with user" {
    const url = try parse("https://user@example.com/repo.git");
    try std.testing.expectEqual(Scheme.https, url.scheme);
    try std.testing.expectEqualStrings("user", url.user.?);
    try std.testing.expectEqualStrings("example.com", url.host.?);
    try std.testing.expectEqualStrings("/repo.git", url.path);
}

test "parse ssh URL" {
    const url = try parse("ssh://git@github.com/user/repo.git");
    try std.testing.expectEqual(Scheme.ssh, url.scheme);
    try std.testing.expectEqualStrings("git", url.user.?);
    try std.testing.expectEqualStrings("github.com", url.host.?);
    try std.testing.expectEqual(@as(u16, 22), url.port);
    try std.testing.expectEqualStrings("/user/repo.git", url.path);
}

test "parse SCP-style URL" {
    const url = try parse("git@github.com:user/repo.git");
    try std.testing.expectEqual(Scheme.ssh, url.scheme);
    try std.testing.expectEqualStrings("git", url.user.?);
    try std.testing.expectEqualStrings("github.com", url.host.?);
    try std.testing.expectEqualStrings("user/repo.git", url.path);
}

test "parse git protocol URL" {
    const url = try parse("git://example.com/repo.git");
    try std.testing.expectEqual(Scheme.git, url.scheme);
    try std.testing.expectEqualStrings("example.com", url.host.?);
    try std.testing.expectEqual(@as(u16, 9418), url.port);
    try std.testing.expectEqualStrings("/repo.git", url.path);
}

test "parse file URL" {
    const url = try parse("file:///home/user/repo.git");
    try std.testing.expectEqual(Scheme.file, url.scheme);
    try std.testing.expect(url.host == null);
    try std.testing.expectEqualStrings("/home/user/repo.git", url.path);
}

test "parse local absolute path" {
    const url = try parse("/home/user/repo.git");
    try std.testing.expectEqual(Scheme.local, url.scheme);
    try std.testing.expectEqualStrings("/home/user/repo.git", url.path);
}

test "parse local relative path" {
    const url = try parse("./repo.git");
    try std.testing.expectEqual(Scheme.local, url.scheme);
    try std.testing.expectEqualStrings("./repo.git", url.path);
}

test "isLocal" {
    try std.testing.expect(isLocal("/foo/bar"));
    try std.testing.expect(isLocal("./foo/bar"));
    try std.testing.expect(isLocal("file:///foo/bar"));
    try std.testing.expect(!isLocal("https://example.com/repo.git"));
    try std.testing.expect(!isLocal("ssh://git@example.com/repo.git"));
    try std.testing.expect(!isLocal("git@github.com:user/repo.git"));
}

test "repoName" {
    try std.testing.expectEqualStrings("repo", repoName("https://github.com/user/repo.git"));
    try std.testing.expectEqualStrings("repo", repoName("git@github.com:user/repo.git"));
    try std.testing.expectEqualStrings("myproject", repoName("/path/to/myproject"));
    try std.testing.expectEqualStrings("repo", repoName("file:///path/to/repo.git"));
}

test "GitUrl format roundtrip http" {
    const url = try parse("https://example.com/repo.git");
    var buf: [256]u8 = undefined;
    const formatted = try url.format(&buf);
    try std.testing.expectEqualStrings("https://example.com/repo.git", formatted);
}

test "GitUrl isLocal" {
    const local_url = try parse("/foo/bar");
    try std.testing.expect(local_url.isLocal());

    const remote_url = try parse("https://example.com/repo.git");
    try std.testing.expect(!remote_url.isLocal());
    try std.testing.expect(remote_url.isHttp());
}
