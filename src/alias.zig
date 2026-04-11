const std = @import("std");
const config_mod = @import("config.zig");

const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Result of alias resolution.
pub const AliasResult = struct {
    /// The resolved command and arguments.
    args: [][]const u8,
    /// Whether this is a shell alias (prefixed with '!').
    is_shell: bool,
    /// The shell command string for shell aliases.
    shell_cmd: ?[]const u8,
    /// The backing allocation for alias_value (must be freed).
    shell_cmd_alloc: ?[]u8 = null,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *AliasResult) void {
        if (!self.is_shell) {
            self.allocator.free(self.args);
        }
        if (self.shell_cmd_alloc) |alloc| {
            self.allocator.free(alloc);
        }
    }
};

/// Resolve a command alias. Returns null if the command is not an alias.
/// If it is an alias, returns the expanded arguments.
pub fn resolveAlias(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    command: []const u8,
    extra_args: []const []const u8,
) !?AliasResult {
    // Load config
    var config_path_buf: [4096]u8 = undefined;
    const config_path = buildPath(&config_path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch return null;
    defer cfg.deinit();

    // Look up alias.<command>
    var key_buf: [256]u8 = undefined;
    const key = buildCompoundKey(&key_buf, "alias.", command);

    const alias_value_raw = cfg.get(key) orelse return null;

    // Copy alias value so it survives cfg.deinit()
    const alias_value = try allocator.alloc(u8, alias_value_raw.len);
    @memcpy(alias_value, alias_value_raw);

    // Check for shell alias (starts with '!')
    if (alias_value.len > 0 and alias_value[0] == '!') {
        // Shell alias: everything after '!' is the shell command
        return AliasResult{
            .args = &[_][]u8{},
            .is_shell = true,
            .shell_cmd = alias_value[1..],
            .shell_cmd_alloc = alias_value,
            .allocator = allocator,
        };
    }

    // Split the alias value into words
    var alias_args = std.array_list.Managed([]const u8).init(allocator);
    errdefer alias_args.deinit();

    var iter = std.mem.splitScalar(u8, alias_value, ' ');
    while (iter.next()) |word| {
        const trimmed = std.mem.trimLeft(u8, word, " \t");
        const trimmed2 = std.mem.trimRight(u8, trimmed, " \t");
        if (trimmed2.len > 0) {
            try alias_args.append(trimmed2);
        }
    }

    // Append extra args from the command line
    for (extra_args) |arg| {
        try alias_args.append(arg);
    }

    if (alias_args.items.len == 0) {
        allocator.free(alias_value);
        return null;
    }

    const result_args = try alias_args.toOwnedSlice();

    return AliasResult{
        .args = result_args,
        .is_shell = false,
        .shell_cmd = null,
        .shell_cmd_alloc = alias_value,
        .allocator = allocator,
    };
}

/// Execute a shell alias command.
pub fn executeShellAlias(allocator: std.mem.Allocator, shell_cmd: []const u8, extra_args: []const []const u8) !void {
    // Build the full shell command with extra args (shell-quoted to prevent injection)
    var full_cmd = std.array_list.Managed(u8).init(allocator);
    defer full_cmd.deinit();

    try full_cmd.appendSlice(shell_cmd);

    for (extra_args) |arg| {
        try full_cmd.append(' ');
        // Shell-quote each argument to prevent injection
        try full_cmd.append('\'');
        for (arg) |ch| {
            if (ch == '\'') {
                try full_cmd.appendSlice("'\\''");
            } else {
                try full_cmd.append(ch);
            }
        }
        try full_cmd.append('\'');
    }

    // Execute using /bin/sh -c
    var child = std.process.Child.init(&[_][]const u8{
        "/bin/sh",
        "-c",
        full_cmd.items,
    }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const result = try child.wait();

    switch (result) {
        .Exited => |code| {
            if (code != 0) {
                std.process.exit(code);
            }
        },
        else => {
            std.process.exit(128);
        },
    }
}

/// List all configured aliases.
pub fn listAliases(allocator: std.mem.Allocator, git_dir: []const u8) !void {
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    var config_path_buf: [4096]u8 = undefined;
    const config_path = buildPath(&config_path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch return;
    defer cfg.deinit();

    for (cfg.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.section, "alias")) {
            var buf: [512]u8 = undefined;
            if (entry.subsection) |ss| {
                const line = std.fmt.bufPrint(&buf, "alias.{s} = {s}\n", .{ ss, entry.value }) catch continue;
                stdout_file.writeAll(line) catch {};
            } else {
                const line = std.fmt.bufPrint(&buf, "{s} = {s}\n", .{ entry.key, entry.value }) catch continue;
                stdout_file.writeAll(line) catch {};
            }
        }
    }
}

// -- Helpers --

fn buildPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn buildCompoundKey(buf: []u8, prefix: []const u8, name: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    return buf[0..pos];
}
