const std = @import("std");
const config_mod = @import("config.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Remote configuration entry.
pub const Remote = struct {
    name: []const u8,
    url: []const u8,
    fetch_refspec: []const u8,
};

/// Get the URL for a named remote from the git config.
/// Caller owns the returned string.
pub fn getRemoteUrl(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8) !?[]const u8 {
    var path_buf: [4096]u8 = undefined;
    const config_path = concatPath(&path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch return null;
    defer cfg.deinit();

    // Build the compound key: remote.<name>.url
    var key_buf: [512]u8 = undefined;
    const key = bufPrint3(&key_buf, "remote.", name, ".url") orelse return null;

    if (cfg.get(key)) |val| {
        const result = try allocator.alloc(u8, val.len);
        @memcpy(result, val);
        return result;
    }
    return null;
}

/// Get the fetch refspec for a named remote from the git config.
/// Caller owns the returned string.
pub fn getRemoteFetchRefspec(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8) !?[]const u8 {
    var path_buf: [4096]u8 = undefined;
    const config_path = concatPath(&path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch return null;
    defer cfg.deinit();

    var key_buf: [512]u8 = undefined;
    const key = bufPrint3(&key_buf, "remote.", name, ".fetch") orelse return null;

    if (cfg.get(key)) |val| {
        const result = try allocator.alloc(u8, val.len);
        @memcpy(result, val);
        return result;
    }
    return null;
}

/// Add a remote to the git config.
pub fn addRemote(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8, url: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    const config_path = concatPath(&path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => config_mod.Config.init(allocator),
        else => return err,
    };
    defer cfg.deinit();

    // Check if remote already exists
    var key_buf: [512]u8 = undefined;
    const url_key = bufPrint3(&key_buf, "remote.", name, ".url") orelse return error.InvalidRemoteName;

    if (cfg.get(url_key) != null) {
        return error.RemoteAlreadyExists;
    }

    // Set remote URL
    try cfg.set(url_key, url);

    // Set fetch refspec: +refs/heads/*:refs/remotes/<name>/*
    var fetch_key_buf: [512]u8 = undefined;
    const fetch_key = bufPrint3(&fetch_key_buf, "remote.", name, ".fetch") orelse return error.InvalidRemoteName;

    var refspec_buf: [512]u8 = undefined;
    const refspec = bufPrint3(&refspec_buf, "+refs/heads/*:refs/remotes/", name, "/*") orelse return error.InvalidRemoteName;

    try cfg.set(fetch_key, refspec);

    try cfg.writeFile(config_path);
}

/// Remove a remote from the git config.
pub fn removeRemote(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    const config_path = concatPath(&path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch return error.ConfigNotFound;
    defer cfg.deinit();

    // Check if remote exists
    var key_buf: [512]u8 = undefined;
    const url_key = bufPrint3(&key_buf, "remote.", name, ".url") orelse return error.InvalidRemoteName;

    if (cfg.get(url_key) == null) {
        return error.RemoteNotFound;
    }

    // Remove all entries for this remote
    var i: usize = 0;
    while (i < cfg.entries.items.len) {
        const entry = &cfg.entries.items[i];
        if (std.mem.eql(u8, entry.section, "remote") and
            entry.subsection != null and
            std.mem.eql(u8, entry.subsection.?, name))
        {
            // Free and remove
            entry.deinit(cfg.allocator);
            _ = cfg.entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }

    try cfg.writeFile(config_path);
}

/// List all remote names.
/// Caller owns the returned slice and strings.
pub fn listRemotes(allocator: std.mem.Allocator, git_dir: []const u8) ![][]const u8 {
    var path_buf: [4096]u8 = undefined;
    const config_path = concatPath(&path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch return allocator.alloc([]const u8, 0);
    defer cfg.deinit();

    var names = std.array_list.Managed([]const u8).init(allocator);
    defer names.deinit();

    for (cfg.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.section, "remote") and
            entry.subsection != null and
            std.mem.eql(u8, entry.key, "url"))
        {
            // Check for duplicates
            var found = false;
            for (names.items) |existing| {
                if (std.mem.eql(u8, existing, entry.subsection.?)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const name_copy = try allocator.alloc(u8, entry.subsection.?.len);
                @memcpy(name_copy, entry.subsection.?);
                try names.append(name_copy);
            }
        }
    }

    return names.toOwnedSlice();
}

/// Remote info with URL for verbose listing.
pub const RemoteInfo = struct {
    name: []const u8,
    url: []const u8,
};

/// List all remotes with their URLs.
/// Caller owns the returned slice and strings.
pub fn listRemotesVerbose(allocator: std.mem.Allocator, git_dir: []const u8) ![]RemoteInfo {
    var path_buf: [4096]u8 = undefined;
    const config_path = concatPath(&path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch return allocator.alloc(RemoteInfo, 0);
    defer cfg.deinit();

    var infos = std.array_list.Managed(RemoteInfo).init(allocator);
    defer infos.deinit();

    for (cfg.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.section, "remote") and
            entry.subsection != null and
            std.mem.eql(u8, entry.key, "url"))
        {
            const name_copy = try allocator.alloc(u8, entry.subsection.?.len);
            @memcpy(name_copy, entry.subsection.?);

            const url_copy = try allocator.alloc(u8, entry.value.len);
            @memcpy(url_copy, entry.value);

            try infos.append(.{
                .name = name_copy,
                .url = url_copy,
            });
        }
    }

    return infos.toOwnedSlice();
}

/// Run the `remote` subcommand.
pub fn runRemote(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8) !void {
    if (args.len == 0) {
        // List remotes (names only)
        const names = try listRemotes(allocator, git_dir);
        defer {
            for (names) |n| allocator.free(@constCast(n));
            allocator.free(names);
        }
        for (names) |name| {
            try stdout_file.writeAll(name);
            try stdout_file.writeAll("\n");
        }
        return;
    }

    const sub = args[0];

    if (std.mem.eql(u8, sub, "-v") or std.mem.eql(u8, sub, "--verbose")) {
        const infos = try listRemotesVerbose(allocator, git_dir);
        defer {
            for (infos) |info| {
                allocator.free(@constCast(info.name));
                allocator.free(@constCast(info.url));
            }
            allocator.free(infos);
        }

        var buf: [1024]u8 = undefined;
        for (infos) |info| {
            // Print fetch line
            const fetch_line = std.fmt.bufPrint(&buf, "{s}\t{s} (fetch)\n", .{ info.name, info.url }) catch continue;
            try stdout_file.writeAll(fetch_line);
            // Print push line
            const push_line = std.fmt.bufPrint(&buf, "{s}\t{s} (push)\n", .{ info.name, info.url }) catch continue;
            try stdout_file.writeAll(push_line);
        }
        return;
    }

    if (std.mem.eql(u8, sub, "add")) {
        if (args.len < 3) {
            try stderr_file.writeAll("usage: zig-git remote add <name> <url>\n");
            std.process.exit(1);
        }
        const name = args[1];
        const url = args[2];
        addRemote(allocator, git_dir, name, url) catch |err| {
            if (err == error.RemoteAlreadyExists) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: remote {s} already exists.\n", .{name}) catch
                    "fatal: remote already exists.\n";
                try stderr_file.writeAll(msg);
                std.process.exit(3);
            }
            return err;
        };
        return;
    }

    if (std.mem.eql(u8, sub, "remove") or std.mem.eql(u8, sub, "rm")) {
        if (args.len < 2) {
            try stderr_file.writeAll("usage: zig-git remote remove <name>\n");
            std.process.exit(1);
        }
        const name = args[1];
        removeRemote(allocator, git_dir, name) catch |err| {
            if (err == error.RemoteNotFound) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: No such remote: '{s}'\n", .{name}) catch
                    "fatal: No such remote\n";
                try stderr_file.writeAll(msg);
                std.process.exit(2);
            }
            return err;
        };
        return;
    }

    if (std.mem.eql(u8, sub, "get-url")) {
        if (args.len < 2) {
            try stderr_file.writeAll("usage: zig-git remote get-url <name>\n");
            std.process.exit(1);
        }
        const name = args[1];
        if (try getRemoteUrl(allocator, git_dir, name)) |url| {
            defer allocator.free(url);
            try stdout_file.writeAll(url);
            try stdout_file.writeAll("\n");
        } else {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: No such remote '{s}'\n", .{name}) catch
                "fatal: No such remote\n";
            try stderr_file.writeAll(msg);
            std.process.exit(2);
        }
        return;
    }

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error: Unknown subcommand: {s}\n", .{sub}) catch
        "error: Unknown subcommand\n";
    try stderr_file.writeAll(msg);
    std.process.exit(1);
}

/// Resolve a possibly file:// prefixed URL to a local path.
/// Returns null if not a local path.
pub fn resolveLocalUrl(url: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, url, "file://")) {
        return url[7..];
    }
    // If it starts with '/' it's an absolute local path
    if (url.len > 0 and url[0] == '/') {
        return url;
    }
    // Relative path (contains no "://" scheme)
    if (std.mem.indexOf(u8, url, "://") == null) {
        return url;
    }
    return null;
}

// --- Helpers ---

fn concatPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn bufPrint3(buf: []u8, a: []const u8, b: []const u8, c: []const u8) ?[]const u8 {
    const total = a.len + b.len + c.len;
    if (total > buf.len) return null;
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    @memcpy(buf[a.len + b.len ..][0..c.len], c);
    return buf[0..total];
}

test "resolveLocalUrl" {
    try std.testing.expectEqualStrings("/foo/bar", resolveLocalUrl("file:///foo/bar").?);
    try std.testing.expectEqualStrings("/foo/bar", resolveLocalUrl("/foo/bar").?);
    try std.testing.expectEqualStrings("relative/path", resolveLocalUrl("relative/path").?);
    try std.testing.expect(resolveLocalUrl("https://example.com/repo.git") == null);
    try std.testing.expect(resolveLocalUrl("ssh://git@example.com/repo.git") == null);
}

test "bufPrint3" {
    var buf: [64]u8 = undefined;
    const result = bufPrint3(&buf, "remote.", "origin", ".url").?;
    try std.testing.expectEqualStrings("remote.origin.url", result);
}
