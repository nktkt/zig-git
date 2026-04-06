const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const config_mod = @import("config.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };
const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };

/// Credential data structure.
pub const Credential = struct {
    protocol: ?[]const u8 = null,
    host: ?[]const u8 = null,
    path: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,

    allocator: ?std.mem.Allocator = null,
    owned_strings: [16]?[]u8 = [_]?[]u8{null} ** 16,
    owned_count: usize = 0,

    pub fn deinit(self: *Credential) void {
        if (self.allocator) |alloc| {
            for (self.owned_strings[0..self.owned_count]) |ms| {
                if (ms) |s| alloc.free(s);
            }
        }
    }

    fn addOwned(self: *Credential, s: []u8) bool {
        if (self.owned_count < 16) {
            self.owned_strings[self.owned_count] = s;
            self.owned_count += 1;
            return true;
        }
        return false;
    }

    /// Format credential for output.
    pub fn format(self: *const Credential, buf: []u8) []const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();
        if (self.protocol) |p| {
            writer.writeAll("protocol=") catch {};
            writer.writeAll(p) catch {};
            writer.writeByte('\n') catch {};
        }
        if (self.host) |h| {
            writer.writeAll("host=") catch {};
            writer.writeAll(h) catch {};
            writer.writeByte('\n') catch {};
        }
        if (self.path) |pa| {
            writer.writeAll("path=") catch {};
            writer.writeAll(pa) catch {};
            writer.writeByte('\n') catch {};
        }
        if (self.username) |u| {
            writer.writeAll("username=") catch {};
            writer.writeAll(u) catch {};
            writer.writeByte('\n') catch {};
        }
        if (self.password) |pw| {
            writer.writeAll("password=") catch {};
            writer.writeAll(pw) catch {};
            writer.writeByte('\n') catch {};
        }
        writer.writeByte('\n') catch {};
        return buf[0..stream.pos];
    }

    /// Build a URL from credential fields.
    pub fn toUrl(self: *const Credential, buf: []u8) []const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();
        if (self.protocol) |p| {
            writer.writeAll(p) catch {};
            writer.writeAll("://") catch {};
        }
        if (self.username) |u| {
            writer.writeAll(u) catch {};
            if (self.password) |pw| {
                writer.writeByte(':') catch {};
                writer.writeAll(pw) catch {};
            }
            writer.writeByte('@') catch {};
        }
        if (self.host) |h| {
            writer.writeAll(h) catch {};
        }
        if (self.path) |pa| {
            writer.writeByte('/') catch {};
            writer.writeAll(pa) catch {};
        }
        writer.writeByte('\n') catch {};
        return buf[0..stream.pos];
    }
};

/// Parse credential from input lines (protocol format).
pub fn parseCredential(allocator: std.mem.Allocator, input: []const u8) !Credential {
    var cred = Credential{};
    cred.allocator = allocator;

    var line_iter = std.mem.splitScalar(u8, input, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r ");
        if (trimmed.len == 0) break;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const key = trimmed[0..eq_pos];
            const value = trimmed[eq_pos + 1 ..];

            // Make owned copy
            const owned = try allocator.alloc(u8, value.len);
            @memcpy(owned, value);
            if (!cred.addOwned(owned)) {
                allocator.free(owned);
                continue;
            }

            if (std.mem.eql(u8, key, "protocol")) {
                cred.protocol = owned;
            } else if (std.mem.eql(u8, key, "host")) {
                cred.host = owned;
            } else if (std.mem.eql(u8, key, "path")) {
                cred.path = owned;
            } else if (std.mem.eql(u8, key, "username")) {
                cred.username = owned;
            } else if (std.mem.eql(u8, key, "password")) {
                cred.password = owned;
            }
        }
    }

    return cred;
}

/// Parse a URL into credential fields.
pub fn parseUrl(allocator: std.mem.Allocator, url: []const u8) !Credential {
    var cred = Credential{};
    cred.allocator = allocator;

    var remaining = url;

    // Parse protocol
    if (std.mem.indexOf(u8, remaining, "://")) |proto_end| {
        const proto = try allocator.alloc(u8, proto_end);
        @memcpy(proto, remaining[0..proto_end]);
        if (!cred.addOwned(proto)) {
            allocator.free(proto);
            return cred;
        }
        cred.protocol = proto;
        remaining = remaining[proto_end + 3 ..];
    }

    // Parse username:password@host
    if (std.mem.indexOf(u8, remaining, "@")) |at_pos| {
        const user_part = remaining[0..at_pos];
        remaining = remaining[at_pos + 1 ..];

        if (std.mem.indexOf(u8, user_part, ":")) |colon_pos| {
            const user = try allocator.alloc(u8, colon_pos);
            @memcpy(user, user_part[0..colon_pos]);
            if (!cred.addOwned(user)) {
                allocator.free(user);
                return cred;
            }
            cred.username = user;

            const pass_src = user_part[colon_pos + 1 ..];
            const pass = try allocator.alloc(u8, pass_src.len);
            @memcpy(pass, pass_src);
            if (!cred.addOwned(pass)) {
                allocator.free(pass);
                return cred;
            }
            cred.password = pass;
        } else {
            const user = try allocator.alloc(u8, user_part.len);
            @memcpy(user, user_part);
            if (!cred.addOwned(user)) {
                allocator.free(user);
                return cred;
            }
            cred.username = user;
        }
    }

    // Parse host and path
    if (std.mem.indexOf(u8, remaining, "/")) |slash_pos| {
        const host = try allocator.alloc(u8, slash_pos);
        @memcpy(host, remaining[0..slash_pos]);
        if (!cred.addOwned(host)) {
            allocator.free(host);
            return cred;
        }
        cred.host = host;

        const path_src = remaining[slash_pos + 1 ..];
        const trimmed_path = std.mem.trimRight(u8, path_src, "\n\r ");
        if (trimmed_path.len > 0) {
            const path = try allocator.alloc(u8, trimmed_path.len);
            @memcpy(path, trimmed_path);
            if (!cred.addOwned(path)) {
                allocator.free(path);
                return cred;
            }
            cred.path = path;
        }
    } else {
        const host_src = std.mem.trimRight(u8, remaining, "\n\r ");
        if (host_src.len > 0) {
            const host = try allocator.alloc(u8, host_src.len);
            @memcpy(host, host_src);
            if (!cred.addOwned(host)) {
                allocator.free(host);
                return cred;
            }
            cred.host = host;
        }
    }

    return cred;
}

/// Read credentials from the plaintext store (~/.git-credentials).
fn readCredentialStore(allocator: std.mem.Allocator, cred: *Credential) !bool {
    // Try ~/.git-credentials
    const home = std.posix.getenv("HOME") orelse return false;

    var path_buf: [4096]u8 = undefined;
    const cred_path = concatStr(&path_buf, home, "/.git-credentials");

    const content = readFileContent(allocator, cred_path) catch return false;
    defer allocator.free(content);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r ");
        if (trimmed.len == 0) continue;

        // Each line is a URL: protocol://user:pass@host/path
        var stored_cred = parseUrl(allocator, trimmed) catch continue;
        defer stored_cred.deinit();

        // Match protocol and host
        if (cred.protocol != null and stored_cred.protocol != null) {
            if (!std.mem.eql(u8, cred.protocol.?, stored_cred.protocol.?)) continue;
        }
        if (cred.host != null and stored_cred.host != null) {
            if (!std.mem.eql(u8, cred.host.?, stored_cred.host.?)) continue;
        }

        // Found a match - fill in username/password
        if (stored_cred.username) |u| {
            if (cred.username == null) {
                const owned = try allocator.alloc(u8, u.len);
                @memcpy(owned, u);
                if (!cred.addOwned(owned)) {
                    allocator.free(owned);
                    continue;
                }
                cred.username = owned;
            }
        }
        if (stored_cred.password) |p| {
            if (cred.password == null) {
                const owned = try allocator.alloc(u8, p.len);
                @memcpy(owned, p);
                if (!cred.addOwned(owned)) {
                    allocator.free(owned);
                    continue;
                }
                cred.password = owned;
            }
        }
        return true;
    }

    return false;
}

/// Write credentials to the plaintext store.
fn writeCredentialStore(allocator: std.mem.Allocator, cred: *const Credential) !void {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    var path_buf: [4096]u8 = undefined;
    const cred_path = concatStr(&path_buf, home, "/.git-credentials");

    // Read existing content
    var content = std.array_list.Managed(u8).init(allocator);
    defer content.deinit();

    const existing = readFileContent(allocator, cred_path) catch null;
    if (existing) |e| {
        try content.appendSlice(e);
        allocator.free(e);
    }

    // Build URL line
    var url_buf: [1024]u8 = undefined;
    const url_line = cred.toUrl(&url_buf);
    try content.appendSlice(url_line);

    // Write back
    const file = std.fs.createFileAbsolute(cred_path, .{}) catch return error.CannotWriteCredentials;
    defer file.close();
    file.writeAll(content.items) catch return error.CannotWriteCredentials;
}

/// Remove matching credentials from the store.
fn rejectCredentialStore(allocator: std.mem.Allocator, cred: *const Credential) !void {
    const home = std.posix.getenv("HOME") orelse return;

    var path_buf: [4096]u8 = undefined;
    const cred_path = concatStr(&path_buf, home, "/.git-credentials");

    const content = readFileContent(allocator, cred_path) catch return;
    defer allocator.free(content);

    var new_content = std.array_list.Managed(u8).init(allocator);
    defer new_content.deinit();

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r ");
        if (trimmed.len == 0) continue;

        var stored_cred = parseUrl(allocator, trimmed) catch {
            try new_content.appendSlice(line);
            try new_content.append('\n');
            continue;
        };
        defer stored_cred.deinit();

        // Check if this matches the credential to reject
        var matches = true;
        if (cred.protocol != null and stored_cred.protocol != null) {
            if (!std.mem.eql(u8, cred.protocol.?, stored_cred.protocol.?)) matches = false;
        }
        if (cred.host != null and stored_cred.host != null) {
            if (!std.mem.eql(u8, cred.host.?, stored_cred.host.?)) matches = false;
        }
        if (cred.username != null and stored_cred.username != null) {
            if (!std.mem.eql(u8, cred.username.?, stored_cred.username.?)) matches = false;
        }

        if (!matches) {
            try new_content.appendSlice(line);
            try new_content.append('\n');
        }
    }

    const file = std.fs.createFileAbsolute(cred_path, .{}) catch return;
    defer file.close();
    file.writeAll(new_content.items) catch {};
}

/// Get the configured credential helper.
fn getCredentialHelper(allocator: std.mem.Allocator, git_dir: []const u8) ?[]const u8 {
    var config_path_buf: [4096]u8 = undefined;
    const config_path = concatStr(&config_path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch return null;
    defer cfg.deinit();

    return cfg.get("credential.helper");
}

/// Fill credentials (credential fill command).
pub fn credentialFill(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
) !void {
    // Read input from stdin
    var input_buf: [4096]u8 = undefined;
    const n = stdin_file.readAll(&input_buf) catch 0;
    const input = input_buf[0..n];

    var cred = parseCredential(allocator, input) catch {
        try stderr_file.writeAll("error: cannot parse credential input\n");
        std.process.exit(1);
    };
    defer cred.deinit();

    // Check configured helper
    const helper = getCredentialHelper(allocator, repo.git_dir);

    if (helper) |h| {
        if (std.mem.eql(u8, h, "store")) {
            _ = readCredentialStore(allocator, &cred) catch false;
        }
        // 'cache' and 'osxkeychain' would need more complex implementations
    } else {
        // Default: try store
        _ = readCredentialStore(allocator, &cred) catch false;
    }

    // Output the credential
    var out_buf: [4096]u8 = undefined;
    const output = cred.format(&out_buf);
    try stdout_file.writeAll(output);
}

/// Approve credentials (credential approve command).
pub fn credentialApprove(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
) !void {
    var input_buf: [4096]u8 = undefined;
    const n = stdin_file.readAll(&input_buf) catch 0;
    const input = input_buf[0..n];

    var cred = parseCredential(allocator, input) catch return;
    defer cred.deinit();

    const helper = getCredentialHelper(allocator, repo.git_dir);

    if (helper) |h| {
        if (std.mem.eql(u8, h, "store")) {
            writeCredentialStore(allocator, &cred) catch {};
        }
    } else {
        writeCredentialStore(allocator, &cred) catch {};
    }
}

/// Reject credentials (credential reject command).
pub fn credentialReject(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
) !void {
    var input_buf: [4096]u8 = undefined;
    const n = stdin_file.readAll(&input_buf) catch 0;
    const input = input_buf[0..n];

    var cred = parseCredential(allocator, input) catch return;
    defer cred.deinit();

    const helper = getCredentialHelper(allocator, repo.git_dir);

    if (helper) |h| {
        if (std.mem.eql(u8, h, "store")) {
            rejectCredentialStore(allocator, &cred) catch {};
        }
    } else {
        rejectCredentialStore(allocator, &cred) catch {};
    }
}

/// Run the credential command.
pub fn runCredential(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        try stderr_file.writeAll(credential_usage);
        std.process.exit(1);
    }

    const subcmd = args[0];

    if (std.mem.eql(u8, subcmd, "fill")) {
        try credentialFill(allocator, repo);
    } else if (std.mem.eql(u8, subcmd, "approve")) {
        try credentialApprove(allocator, repo);
    } else if (std.mem.eql(u8, subcmd, "reject")) {
        try credentialReject(allocator, repo);
    } else {
        try stderr_file.writeAll(credential_usage);
        std.process.exit(1);
    }
}

const credential_usage =
    \\usage: zig-git credential <command>
    \\
    \\Commands:
    \\  fill     Get credentials for a URL
    \\  approve  Mark credentials as valid
    \\  reject   Mark credentials as invalid
    \\
    \\Protocol format (stdin/stdout):
    \\  protocol=https
    \\  host=github.com
    \\  username=user
    \\  password=token
    \\
;

// --- Helpers ---

fn readFileContent(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return error.FileNotFound;
    defer file.close();
    const stat = try file.stat();
    if (stat.size > 1024 * 1024) return error.FileTooLarge;
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    const n = try file.readAll(buf);
    if (n < buf.len) {
        const trimmed = try allocator.alloc(u8, n);
        @memcpy(trimmed, buf[0..n]);
        allocator.free(buf);
        return trimmed;
    }
    return buf;
}

fn concatStr(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

test "parseCredential" {
    var cred = try parseCredential(std.testing.allocator, "protocol=https\nhost=github.com\nusername=user\npassword=pass\n");
    defer cred.deinit();

    try std.testing.expectEqualStrings("https", cred.protocol.?);
    try std.testing.expectEqualStrings("github.com", cred.host.?);
    try std.testing.expectEqualStrings("user", cred.username.?);
    try std.testing.expectEqualStrings("pass", cred.password.?);
}

test "parseUrl" {
    var cred = try parseUrl(std.testing.allocator, "https://user:pass@github.com/repo");
    defer cred.deinit();

    try std.testing.expectEqualStrings("https", cred.protocol.?);
    try std.testing.expectEqualStrings("github.com", cred.host.?);
    try std.testing.expectEqualStrings("user", cred.username.?);
    try std.testing.expectEqualStrings("pass", cred.password.?);
    try std.testing.expectEqualStrings("repo", cred.path.?);
}

test "Credential format" {
    var cred = Credential{
        .protocol = "https",
        .host = "github.com",
        .username = "user",
        .password = "pass",
    };
    var buf: [512]u8 = undefined;
    const output = cred.format(&buf);
    try std.testing.expect(std.mem.indexOf(u8, output, "protocol=https") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "host=github.com") != null);
}
