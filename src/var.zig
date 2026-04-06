const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const config_mod = @import("config.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Known git logical variables.
pub const GitVar = enum {
    GIT_AUTHOR_IDENT,
    GIT_COMMITTER_IDENT,
    GIT_EDITOR,
    GIT_PAGER,
    GIT_DEFAULT_BRANCH,

    pub fn fromString(s: []const u8) ?GitVar {
        if (std.mem.eql(u8, s, "GIT_AUTHOR_IDENT")) return .GIT_AUTHOR_IDENT;
        if (std.mem.eql(u8, s, "GIT_COMMITTER_IDENT")) return .GIT_COMMITTER_IDENT;
        if (std.mem.eql(u8, s, "GIT_EDITOR")) return .GIT_EDITOR;
        if (std.mem.eql(u8, s, "GIT_PAGER")) return .GIT_PAGER;
        if (std.mem.eql(u8, s, "GIT_DEFAULT_BRANCH")) return .GIT_DEFAULT_BRANCH;
        return null;
    }
};

/// Resolve the author identity string.
/// Format: "Name <email> timestamp timezone"
fn resolveAuthorIdent(allocator: std.mem.Allocator, git_dir: []const u8) ![]const u8 {
    // Check environment variables first
    const env_name = std.posix.getenv("GIT_AUTHOR_NAME");
    const env_email = std.posix.getenv("GIT_AUTHOR_EMAIL");
    const env_date = std.posix.getenv("GIT_AUTHOR_DATE");

    var name: []const u8 = "unknown";
    var email: []const u8 = "unknown@unknown";

    // Try config
    var config_path_buf: [4096]u8 = undefined;
    const config_path = concatStr(&config_path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch null;
    defer if (cfg) |*c| c.deinit();

    if (env_name) |n| {
        name = n;
    } else if (cfg) |c| {
        if (c.get("user.name")) |n| name = n;
    }

    if (env_email) |e| {
        email = e;
    } else if (cfg) |c| {
        if (c.get("user.email")) |e| email = e;
    }

    // Build the identity string
    var buf: [1024]u8 = undefined;
    if (env_date) |d| {
        const result = std.fmt.bufPrint(&buf, "{s} <{s}> {s}\n", .{ name, email, d }) catch return "unknown <unknown> 0 +0000\n";
        return result;
    }

    // Use current time
    const timestamp = std.time.timestamp();
    const result = std.fmt.bufPrint(&buf, "{s} <{s}> {d} +0000\n", .{ name, email, timestamp }) catch return "unknown <unknown> 0 +0000\n";
    return result;
}

/// Resolve the committer identity string.
fn resolveCommitterIdent(allocator: std.mem.Allocator, git_dir: []const u8) ![]const u8 {
    const env_name = std.posix.getenv("GIT_COMMITTER_NAME");
    const env_email = std.posix.getenv("GIT_COMMITTER_EMAIL");
    const env_date = std.posix.getenv("GIT_COMMITTER_DATE");

    var name: []const u8 = "unknown";
    var email: []const u8 = "unknown@unknown";

    var config_path_buf: [4096]u8 = undefined;
    const config_path = concatStr(&config_path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch null;
    defer if (cfg) |*c| c.deinit();

    if (env_name) |n| {
        name = n;
    } else if (cfg) |c| {
        if (c.get("user.name")) |n| name = n;
    }

    if (env_email) |e| {
        email = e;
    } else if (cfg) |c| {
        if (c.get("user.email")) |e| email = e;
    }

    var buf: [1024]u8 = undefined;
    if (env_date) |d| {
        const result = std.fmt.bufPrint(&buf, "{s} <{s}> {s}\n", .{ name, email, d }) catch return "unknown <unknown> 0 +0000\n";
        return result;
    }

    const timestamp = std.time.timestamp();
    const result = std.fmt.bufPrint(&buf, "{s} <{s}> {d} +0000\n", .{ name, email, timestamp }) catch return "unknown <unknown> 0 +0000\n";
    return result;
}

/// Resolve the configured editor.
fn resolveEditor(allocator: std.mem.Allocator, git_dir: []const u8) []const u8 {
    // 1. GIT_EDITOR env
    if (std.posix.getenv("GIT_EDITOR")) |e| return e;

    // 2. core.editor config
    var config_path_buf: [4096]u8 = undefined;
    const config_path = concatStr(&config_path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch null;
    defer if (cfg) |*c| c.deinit();

    if (cfg) |c| {
        if (c.get("core.editor")) |e| return e;
    }

    // 3. VISUAL env
    if (std.posix.getenv("VISUAL")) |e| return e;

    // 4. EDITOR env
    if (std.posix.getenv("EDITOR")) |e| return e;

    // 5. Default
    return "vi";
}

/// Resolve the configured pager.
fn resolvePager(allocator: std.mem.Allocator, git_dir: []const u8) []const u8 {
    // 1. GIT_PAGER env
    if (std.posix.getenv("GIT_PAGER")) |p| return p;

    // 2. core.pager config
    var config_path_buf: [4096]u8 = undefined;
    const config_path = concatStr(&config_path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch null;
    defer if (cfg) |*c| c.deinit();

    if (cfg) |c| {
        if (c.get("core.pager")) |p| return p;
    }

    // 3. PAGER env
    if (std.posix.getenv("PAGER")) |p| return p;

    // 4. Default
    return "less";
}

/// Resolve the default branch name.
fn resolveDefaultBranch(allocator: std.mem.Allocator, git_dir: []const u8) []const u8 {
    // 1. init.defaultBranch config
    var config_path_buf: [4096]u8 = undefined;
    const config_path = concatStr(&config_path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch null;
    defer if (cfg) |*c| c.deinit();

    if (cfg) |c| {
        if (c.get("init.defaultBranch")) |b| return b;
    }

    // 2. Try global config (~/.gitconfig)
    if (std.posix.getenv("HOME")) |home| {
        var global_buf: [4096]u8 = undefined;
        const global_path = concatStr(&global_buf, home, "/.gitconfig");
        var global_cfg = config_mod.Config.loadFile(allocator, global_path) catch null;
        defer if (global_cfg) |*c| c.deinit();

        if (global_cfg) |c| {
            if (c.get("init.defaultBranch")) |b| return b;
        }
    }

    // 3. Default
    return "main";
}

/// Resolve a git variable.
pub fn resolveVar(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    var_name: GitVar,
) ![]const u8 {
    return switch (var_name) {
        .GIT_AUTHOR_IDENT => try resolveAuthorIdent(allocator, git_dir),
        .GIT_COMMITTER_IDENT => try resolveCommitterIdent(allocator, git_dir),
        .GIT_EDITOR => resolveEditor(allocator, git_dir),
        .GIT_PAGER => resolvePager(allocator, git_dir),
        .GIT_DEFAULT_BRANCH => resolveDefaultBranch(allocator, git_dir),
    };
}

/// List all known variables and their values.
pub fn listVars(allocator: std.mem.Allocator, git_dir: []const u8) !void {
    const vars = [_]struct { name: []const u8, var_type: GitVar }{
        .{ .name = "GIT_AUTHOR_IDENT", .var_type = .GIT_AUTHOR_IDENT },
        .{ .name = "GIT_COMMITTER_IDENT", .var_type = .GIT_COMMITTER_IDENT },
        .{ .name = "GIT_EDITOR", .var_type = .GIT_EDITOR },
        .{ .name = "GIT_PAGER", .var_type = .GIT_PAGER },
        .{ .name = "GIT_DEFAULT_BRANCH", .var_type = .GIT_DEFAULT_BRANCH },
    };

    for (vars) |v| {
        const value = resolveVar(allocator, git_dir, v.var_type) catch "unknown";
        var buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}={s}\n", .{ v.name, value }) catch continue;
        try stdout_file.writeAll(line);
    }
}

/// Run the var command.
pub fn runVar(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        // List all variables
        try listVars(allocator, repo.git_dir);
        return;
    }

    const var_name_str = args[0];

    if (std.mem.eql(u8, var_name_str, "-l") or std.mem.eql(u8, var_name_str, "--list")) {
        try listVars(allocator, repo.git_dir);
        return;
    }

    const var_name = GitVar.fromString(var_name_str) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: unknown variable '{s}'\n", .{var_name_str}) catch "error: unknown variable\n";
        try stderr_file.writeAll(msg);
        try stderr_file.writeAll(var_usage);
        std.process.exit(1);
    };

    const value = resolveVar(allocator, repo.git_dir, var_name) catch {
        try stderr_file.writeAll("error: cannot resolve variable\n");
        std.process.exit(1);
    };

    // Some values already have trailing newline (identity strings)
    if (std.mem.endsWith(u8, value, "\n")) {
        try stdout_file.writeAll(value);
    } else {
        try stdout_file.writeAll(value);
        try stdout_file.writeAll("\n");
    }
}

const var_usage =
    \\usage: zig-git var <variable>
    \\
    \\Variables:
    \\  GIT_AUTHOR_IDENT     Author identity
    \\  GIT_COMMITTER_IDENT  Committer identity
    \\  GIT_EDITOR           Configured editor
    \\  GIT_PAGER            Configured pager
    \\  GIT_DEFAULT_BRANCH   Default branch name
    \\
;

// --- Helpers ---

fn concatStr(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

test "GitVar fromString" {
    try std.testing.expect(GitVar.fromString("GIT_EDITOR") != null);
    try std.testing.expect(GitVar.fromString("GIT_EDITOR").? == .GIT_EDITOR);
    try std.testing.expect(GitVar.fromString("NONEXISTENT") == null);
}

test "GitVar fromString all" {
    try std.testing.expect(GitVar.fromString("GIT_AUTHOR_IDENT").? == .GIT_AUTHOR_IDENT);
    try std.testing.expect(GitVar.fromString("GIT_COMMITTER_IDENT").? == .GIT_COMMITTER_IDENT);
    try std.testing.expect(GitVar.fromString("GIT_PAGER").? == .GIT_PAGER);
    try std.testing.expect(GitVar.fromString("GIT_DEFAULT_BRANCH").? == .GIT_DEFAULT_BRANCH);
}
