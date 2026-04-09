const std = @import("std");
const config_mod = @import("config.zig");
const repository = @import("repository.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Config scope for read/write.
pub const ConfigScope = enum {
    local,
    global,
    system,
};

/// Extended config command mode.
pub const ConfigCommand = enum {
    get,
    set,
    list,
    unset,
    unset_all,
    rename_section,
    remove_section,
    edit,
};

/// Get the config file path for a given scope.
pub fn getConfigPath(
    scope: ConfigScope,
    git_dir: ?[]const u8,
    buf: []u8,
) ?[]const u8 {
    switch (scope) {
        .local => {
            const gd = git_dir orelse return null;
            if (gd.len + "/config".len > buf.len) return null;
            @memcpy(buf[0..gd.len], gd);
            const suffix = "/config";
            @memcpy(buf[gd.len..][0..suffix.len], suffix);
            return buf[0 .. gd.len + suffix.len];
        },
        .global => {
            // ~/.gitconfig
            const home = getHomeDir() orelse return null;
            const suffix = "/.gitconfig";
            if (home.len + suffix.len > buf.len) return null;
            @memcpy(buf[0..home.len], home);
            @memcpy(buf[home.len..][0..suffix.len], suffix);
            return buf[0 .. home.len + suffix.len];
        },
        .system => {
            const path = "/etc/gitconfig";
            if (path.len > buf.len) return null;
            @memcpy(buf[0..path.len], path);
            return buf[0..path.len];
        },
    }
}

/// Run extended config command.
pub fn runConfigExt(
    repo: ?*repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var scope: ConfigScope = .local;
    var command: ConfigCommand = .get;
    var key: ?[]const u8 = null;
    var value: ?[]const u8 = null;
    var extra_arg: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--global")) {
            scope = .global;
        } else if (std.mem.eql(u8, arg, "--system")) {
            scope = .system;
        } else if (std.mem.eql(u8, arg, "--local")) {
            scope = .local;
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            command = .list;
        } else if (std.mem.eql(u8, arg, "--unset")) {
            command = .unset;
        } else if (std.mem.eql(u8, arg, "--unset-all")) {
            command = .unset_all;
        } else if (std.mem.eql(u8, arg, "--rename-section")) {
            command = .rename_section;
        } else if (std.mem.eql(u8, arg, "--remove-section")) {
            command = .remove_section;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--edit")) {
            command = .edit;
        } else if (std.mem.eql(u8, arg, "--get")) {
            command = .get;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (key == null) {
                key = arg;
            } else if (value == null) {
                value = arg;
            } else if (extra_arg == null) {
                extra_arg = arg;
            }
        }
    }

    // Determine config path
    var path_buf: [4096]u8 = undefined;
    const git_dir = if (repo) |r| r.git_dir else null;
    const config_path = getConfigPath(scope, git_dir, &path_buf) orelse {
        try stderr_file.writeAll("fatal: unable to determine config file path\n");
        std.process.exit(128);
    };

    switch (command) {
        .list => try listConfig(allocator, config_path),
        .get => try getConfig(allocator, config_path, key),
        .set => {
            if (key != null and value != null) {
                try setConfig(allocator, config_path, key.?, value.?);
            } else if (key != null and value == null) {
                // Just a get with positional key
                try getConfig(allocator, config_path, key);
            } else {
                try stderr_file.writeAll("usage: zig-git config [--global|--local|--system] <key> [<value>]\n");
                std.process.exit(1);
            }
        },
        .unset => {
            if (key == null) {
                try stderr_file.writeAll("fatal: key required for --unset\n");
                std.process.exit(1);
            }
            try unsetConfig(allocator, config_path, key.?, false);
        },
        .unset_all => {
            if (key == null) {
                try stderr_file.writeAll("fatal: key required for --unset-all\n");
                std.process.exit(1);
            }
            try unsetConfig(allocator, config_path, key.?, true);
        },
        .rename_section => {
            if (key == null or value == null) {
                try stderr_file.writeAll("fatal: --rename-section requires <old-name> <new-name>\n");
                std.process.exit(1);
            }
            try renameSection(allocator, config_path, key.?, value.?);
        },
        .remove_section => {
            if (key == null) {
                try stderr_file.writeAll("fatal: --remove-section requires <name>\n");
                std.process.exit(1);
            }
            try removeSection(allocator, config_path, key.?);
        },
        .edit => {
            try editConfig(config_path);
        },
    }
}

// ---------------------------------------------------------------------------
// List all config entries
// ---------------------------------------------------------------------------

fn listConfig(allocator: std.mem.Allocator, path: []const u8) !void {
    var cfg = config_mod.Config.loadFile(allocator, path) catch {
        try stderr_file.writeAll("fatal: unable to read config file\n");
        std.process.exit(128);
    };
    defer cfg.deinit();

    var buf: [1024]u8 = undefined;
    for (cfg.entries.items) |*entry| {
        if (entry.subsection) |ss| {
            const line = std.fmt.bufPrint(&buf, "{s}.{s}.{s}={s}\n", .{ entry.section, ss, entry.key, entry.value }) catch continue;
            try stdout_file.writeAll(line);
        } else {
            const line = std.fmt.bufPrint(&buf, "{s}.{s}={s}\n", .{ entry.section, entry.key, entry.value }) catch continue;
            try stdout_file.writeAll(line);
        }
    }
}

// ---------------------------------------------------------------------------
// Get a single config value
// ---------------------------------------------------------------------------

fn getConfig(allocator: std.mem.Allocator, path: []const u8, key: ?[]const u8) !void {
    if (key == null) {
        try stderr_file.writeAll("fatal: key required\n");
        std.process.exit(1);
    }

    var cfg = config_mod.Config.loadFile(allocator, path) catch {
        try stderr_file.writeAll("fatal: unable to read config file\n");
        std.process.exit(128);
    };
    defer cfg.deinit();

    if (cfg.get(key.?)) |val| {
        try stdout_file.writeAll(val);
        try stdout_file.writeAll("\n");
    } else {
        std.process.exit(1);
    }
}

// ---------------------------------------------------------------------------
// Set a config value
// ---------------------------------------------------------------------------

fn setConfig(allocator: std.mem.Allocator, path: []const u8, key: []const u8, value: []const u8) !void {
    var cfg = config_mod.Config.loadFile(allocator, path) catch {
        // Create a new config
        var new_cfg = config_mod.Config.init(allocator);
        try new_cfg.set(key, value);
        try new_cfg.writeFile(path);
        new_cfg.deinit();
        return;
    };
    defer cfg.deinit();

    try cfg.set(key, value);
    try cfg.writeFile(path);
}

// ---------------------------------------------------------------------------
// Unset a config value
// ---------------------------------------------------------------------------

fn unsetConfig(allocator: std.mem.Allocator, path: []const u8, key: []const u8, all: bool) !void {
    var cfg = config_mod.Config.loadFile(allocator, path) catch {
        try stderr_file.writeAll("fatal: unable to read config file\n");
        std.process.exit(128);
    };
    defer cfg.deinit();

    // Parse the compound key
    const dot_pos = std.mem.lastIndexOfScalar(u8, key, '.') orelse {
        try stderr_file.writeAll("error: invalid key\n");
        std.process.exit(1);
    };

    const section_and_subsec = key[0..dot_pos];
    const key_name = key[dot_pos + 1 ..];

    // Determine section and optional subsection
    var section: []const u8 = section_and_subsec;
    var subsection: ?[]const u8 = null;

    if (std.mem.indexOfScalar(u8, section_and_subsec, '.')) |sub_dot| {
        section = section_and_subsec[0..sub_dot];
        subsection = section_and_subsec[sub_dot + 1 ..];
    }

    var removed = false;
    var idx: usize = 0;
    while (idx < cfg.entries.items.len) {
        const entry = &cfg.entries.items[idx];
        const section_match = eqlCaseInsensitive(entry.section, section);
        const subsec_match = eqlOptionalCI(entry.subsection, subsection);
        const key_match = eqlCaseInsensitive(entry.key, key_name);

        if (section_match and subsec_match and key_match) {
            entry.deinit(cfg.allocator);
            _ = cfg.entries.orderedRemove(idx);
            removed = true;
            if (!all) break;
        } else {
            idx += 1;
        }
    }

    if (!removed) {
        try stderr_file.writeAll("error: key not found\n");
        std.process.exit(5);
    }

    try cfg.writeFile(path);
}

// ---------------------------------------------------------------------------
// Rename section
// ---------------------------------------------------------------------------

fn renameSection(allocator: std.mem.Allocator, path: []const u8, old_name: []const u8, new_name: []const u8) !void {
    var cfg = config_mod.Config.loadFile(allocator, path) catch {
        try stderr_file.writeAll("fatal: unable to read config file\n");
        std.process.exit(128);
    };
    defer cfg.deinit();

    var found = false;
    for (cfg.entries.items) |*entry| {
        if (eqlCaseInsensitive(entry.section, old_name)) {
            // Replace the section name
            cfg.allocator.free(entry.section);
            entry.section = try cfg.allocator.alloc(u8, new_name.len);
            @memcpy(entry.section, new_name);
            toLowerInPlace(entry.section);
            found = true;
        }
    }

    if (!found) {
        try stderr_file.writeAll("error: section not found\n");
        std.process.exit(1);
    }

    try cfg.writeFile(path);
}

// ---------------------------------------------------------------------------
// Remove section
// ---------------------------------------------------------------------------

fn removeSection(allocator: std.mem.Allocator, path: []const u8, section_name: []const u8) !void {
    var cfg = config_mod.Config.loadFile(allocator, path) catch {
        try stderr_file.writeAll("fatal: unable to read config file\n");
        std.process.exit(128);
    };
    defer cfg.deinit();

    var found = false;
    var idx: usize = 0;
    while (idx < cfg.entries.items.len) {
        const entry = &cfg.entries.items[idx];
        if (eqlCaseInsensitive(entry.section, section_name)) {
            entry.deinit(cfg.allocator);
            _ = cfg.entries.orderedRemove(idx);
            found = true;
        } else {
            idx += 1;
        }
    }

    if (!found) {
        try stderr_file.writeAll("error: section not found\n");
        std.process.exit(1);
    }

    try cfg.writeFile(path);
}

// ---------------------------------------------------------------------------
// Edit config in editor
// ---------------------------------------------------------------------------

fn editConfig(path: []const u8) !void {
    // Find editor from environment
    const editor = getEditor();

    // Print info message
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Opening {s} in {s}...\n", .{ path, editor }) catch return;
    try stdout_file.writeAll(msg);

    // We can't easily spawn a subprocess in this Zig setup, so print advice
    try stderr_file.writeAll("Note: Interactive editing requires a terminal.\n");
    var cmd_buf: [1024]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "Run: {s} {s}\n", .{ editor, path }) catch return;
    try stderr_file.writeAll(cmd);
}

fn getEditor() []const u8 {
    // Check environment variables
    const env_vars = [_][]const u8{ "GIT_EDITOR", "VISUAL", "EDITOR" };
    for (env_vars) |env_name| {
        const val = std.posix.getenv(env_name);
        if (val) |v| {
            if (v.len > 0) return v;
        }
    }
    return "vi";
}

// ---------------------------------------------------------------------------
// Include directive support
// ---------------------------------------------------------------------------

/// Load a config file with include directive support.
pub fn loadConfigWithIncludes(
    allocator: std.mem.Allocator,
    path: []const u8,
    git_dir: ?[]const u8,
) !config_mod.Config {
    var cfg = try config_mod.Config.loadFile(allocator, path);
    errdefer cfg.deinit();

    // Process include directives
    try processIncludes(allocator, &cfg, path, git_dir);

    return cfg;
}

fn processIncludes(
    allocator: std.mem.Allocator,
    cfg: *config_mod.Config,
    base_path: []const u8,
    git_dir: ?[]const u8,
) !void {
    // Iterate through entries looking for include directives
    var idx: usize = 0;
    while (idx < cfg.entries.items.len) : (idx += 1) {
        const entry = &cfg.entries.items[idx];

        if (std.mem.eql(u8, entry.section, "include") and std.mem.eql(u8, entry.key, "path")) {
            const include_path = resolveIncludePath(allocator, entry.value, base_path) orelse continue;
            defer if (!std.mem.eql(u8, include_path, entry.value)) allocator.free(@constCast(include_path));

            // Load the included config
            var included = config_mod.Config.loadFile(allocator, include_path) catch continue;
            defer included.deinit();

            // Merge entries
            for (included.entries.items) |*inc_entry| {
                const owned_section = try allocator.alloc(u8, inc_entry.section.len);
                @memcpy(owned_section, inc_entry.section);

                var owned_subsection: ?[]u8 = null;
                if (inc_entry.subsection) |ss| {
                    owned_subsection = try allocator.alloc(u8, ss.len);
                    @memcpy(owned_subsection.?, ss);
                }

                const owned_key = try allocator.alloc(u8, inc_entry.key.len);
                @memcpy(owned_key, inc_entry.key);

                const owned_value = try allocator.alloc(u8, inc_entry.value.len);
                @memcpy(owned_value, inc_entry.value);

                try cfg.entries.append(.{
                    .section = owned_section,
                    .subsection = owned_subsection,
                    .key = owned_key,
                    .value = owned_value,
                });
            }
        } else if (std.mem.eql(u8, entry.section, "includeif")) {
            // Conditional includes: [includeIf "gitdir:~/work/"]
            if (entry.subsection) |condition| {
                if (std.mem.startsWith(u8, condition, "gitdir:")) {
                    const dir_pattern = condition["gitdir:".len..];
                    if (matchesGitDir(dir_pattern, git_dir)) {
                        if (std.mem.eql(u8, entry.key, "path")) {
                            const include_path = resolveIncludePath(allocator, entry.value, base_path) orelse continue;
                            defer if (!std.mem.eql(u8, include_path, entry.value)) allocator.free(@constCast(include_path));

                            var included = config_mod.Config.loadFile(allocator, include_path) catch continue;
                            defer included.deinit();

                            for (included.entries.items) |*inc_entry| {
                                const owned_section = try allocator.alloc(u8, inc_entry.section.len);
                                @memcpy(owned_section, inc_entry.section);

                                var owned_subsection: ?[]u8 = null;
                                if (inc_entry.subsection) |ss| {
                                    owned_subsection = try allocator.alloc(u8, ss.len);
                                    @memcpy(owned_subsection.?, ss);
                                }

                                const owned_key = try allocator.alloc(u8, inc_entry.key.len);
                                @memcpy(owned_key, inc_entry.key);

                                const owned_value = try allocator.alloc(u8, inc_entry.value.len);
                                @memcpy(owned_value, inc_entry.value);

                                try cfg.entries.append(.{
                                    .section = owned_section,
                                    .subsection = owned_subsection,
                                    .key = owned_key,
                                    .value = owned_value,
                                });
                            }
                        }
                    }
                }
            }
        }
    }
}

fn resolveIncludePath(allocator: std.mem.Allocator, include_value: []const u8, base_path: []const u8) ?[]const u8 {
    _ = allocator;
    // If path starts with ~/, expand home directory
    if (std.mem.startsWith(u8, include_value, "~/")) {
        const home = getHomeDir() orelse return null;
        _ = home;
        // For simplicity, return the raw value
        return include_value;
    }

    // If absolute, use as-is
    if (include_value.len > 0 and include_value[0] == '/') {
        return include_value;
    }

    // Relative path: resolve relative to the base config file's directory
    _ = base_path;
    return include_value;
}

fn matchesGitDir(pattern: []const u8, git_dir: ?[]const u8) bool {
    const gd = git_dir orelse return false;

    // Simple prefix match
    if (std.mem.startsWith(u8, pattern, "~/")) {
        const home = getHomeDir() orelse return false;
        // Check if git_dir starts with $HOME + pattern suffix
        if (!std.mem.startsWith(u8, gd, home)) return false;
        const rest_pattern = pattern[2..];
        const rest_gd = gd[home.len..];
        if (rest_gd.len > 0 and rest_gd[0] == '/') {
            return std.mem.startsWith(u8, rest_gd[1..], rest_pattern) or
                std.mem.startsWith(u8, rest_gd, rest_pattern);
        }
        return false;
    }

    // Absolute pattern
    return std.mem.startsWith(u8, gd, pattern);
}

// ---------------------------------------------------------------------------
// Layered config reading (local -> global -> system)
// ---------------------------------------------------------------------------

/// Read a config value with proper precedence: local > global > system.
pub fn getLayeredConfig(
    allocator: std.mem.Allocator,
    git_dir: ?[]const u8,
    key: []const u8,
) ?[]const u8 {
    var path_buf: [4096]u8 = undefined;

    // Try local first
    if (getConfigPath(.local, git_dir, &path_buf)) |local_path| {
        var cfg = config_mod.Config.loadFile(allocator, local_path) catch {
            // Fall through to global
            return getGlobalOrSystemConfig(allocator, key);
        };
        defer cfg.deinit();
        if (cfg.get(key)) |val| {
            // Note: val points into cfg which we're about to deinit.
            // The caller should copy it if needed.
            return val;
        }
    }

    return getGlobalOrSystemConfig(allocator, key);
}

fn getGlobalOrSystemConfig(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    var path_buf: [4096]u8 = undefined;

    // Try global
    if (getConfigPath(.global, null, &path_buf)) |global_path| {
        var cfg = config_mod.Config.loadFile(allocator, global_path) catch {
            return getSystemConfig(allocator, key);
        };
        defer cfg.deinit();
        if (cfg.get(key)) |val| return val;
    }

    return getSystemConfig(allocator, key);
}

fn getSystemConfig(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    var path_buf: [4096]u8 = undefined;

    if (getConfigPath(.system, null, &path_buf)) |system_path| {
        var cfg = config_mod.Config.loadFile(allocator, system_path) catch return null;
        defer cfg.deinit();
        if (cfg.get(key)) |val| return val;
    }

    return null;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getHomeDir() ?[]const u8 {
    return std.posix.getenv("HOME");
}

fn eqlCaseInsensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |ac, i| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl = if (b[i] >= 'A' and b[i] <= 'Z') b[i] + 32 else b[i];
        if (al != bl) return false;
    }
    return true;
}

fn eqlOptionalCI(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return eqlCaseInsensitive(a.?, b.?);
}

fn toLowerInPlace(s: []u8) void {
    for (s) |*c| {
        if (c.* >= 'A' and c.* <= 'Z') c.* += 32;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "getConfigPath local" {
    var buf: [4096]u8 = undefined;
    const path = getConfigPath(.local, "/tmp/.git", &buf);
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/tmp/.git/config", path.?);
}

test "getConfigPath system" {
    var buf: [4096]u8 = undefined;
    const path = getConfigPath(.system, null, &buf);
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/etc/gitconfig", path.?);
}

test "eqlCaseInsensitive" {
    try std.testing.expect(eqlCaseInsensitive("Hello", "hello"));
    try std.testing.expect(eqlCaseInsensitive("ABC", "abc"));
    try std.testing.expect(!eqlCaseInsensitive("abc", "abcd"));
}

test "matchesGitDir" {
    try std.testing.expect(matchesGitDir("/tmp/myrepo/", "/tmp/myrepo/.git"));
    try std.testing.expect(!matchesGitDir("/other/path/", "/tmp/myrepo/.git"));
}
