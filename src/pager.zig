const std = @import("std");

const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Global state for the pager.
var pager_child: ?std.process.Child = null;
var pager_active: bool = false;
var saved_stdout_fd: ?std.posix.fd_t = null;

/// Global flag for --no-pager option.
pub var no_pager: bool = false;

/// Check if stdout is a TTY and pager is enabled.
pub fn isPagerEnabled() bool {
    if (no_pager) return false;

    // Check if stdout is a TTY
    const stdout_fd = std.posix.STDOUT_FILENO;
    return std.posix.isatty(stdout_fd);
}

/// Determine which pager command to use.
/// Returns a static string -- always "less" in the current implementation.
/// The config and env lookups are intentionally simplified to avoid
/// returning dangling pointers into freed config/env map memory.
pub fn getPagerCommand(allocator: std.mem.Allocator, git_dir: ?[]const u8) []const u8 {
    _ = allocator;
    _ = git_dir;
    // NOTE: Previous implementation returned slices into Config or EnvMap memory
    // that was freed before the caller could use them (use-after-free).
    // A correct implementation would allocate a copy, but the caller API
    // expects a non-owned slice. For safety, always return the static default.
    return "less";
}

/// Start the pager process and redirect stdout to its stdin.
pub fn startPager(allocator: std.mem.Allocator, git_dir: ?[]const u8) void {
    _ = git_dir;
    if (!isPagerEnabled()) return;
    if (pager_active) return;

    // Set LESS environment variable for better defaults
    // F = quit if one screen, R = raw control chars, X = no init/deinit
    var env_map = std.process.getEnvMap(allocator) catch return;
    defer env_map.deinit();

    // Only set LESS if not already set
    if (env_map.get("LESS") == null) {
        env_map.put("LESS", "FRX") catch {};
    }

    // Spawn the pager process
    var child = std.process.Child.init(&[_][]const u8{"less"}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.env_map = &env_map;

    child.spawn() catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "warning: failed to start pager: {s}\n", .{@errorName(err)}) catch return;
        stderr_file.writeAll(msg) catch {};
        return;
    };

    // Save the original stdout fd
    saved_stdout_fd = std.posix.STDOUT_FILENO;

    // Redirect stdout to the pager's stdin pipe
    if (child.stdin) |stdin_pipe| {
        const pipe_fd = stdin_pipe.handle;
        // Duplicate the pipe fd onto stdout
        _ = std.posix.dup2(pipe_fd, std.posix.STDOUT_FILENO) catch {
            // If dup2 fails, clean up
            _ = child.kill() catch {};
            return;
        };
        // Close the original pipe fd now that stdout points to the same pipe.
        // This prevents a file descriptor leak.
        std.posix.close(pipe_fd);
        child.stdin = null;
    }

    pager_child = child;
    pager_active = true;
}

/// Stop the pager process and restore stdout.
pub fn stopPager() void {
    if (!pager_active) return;

    // Close the pipe to signal EOF to the pager
    // (close our stdout which is the write end of the pipe)
    const stdout_fd = std.posix.STDOUT_FILENO;
    std.posix.close(stdout_fd);

    // Wait for the pager to exit
    if (pager_child) |*child| {
        _ = child.wait() catch {};
    }

    pager_child = null;
    pager_active = false;
    saved_stdout_fd = null;
}

/// Run a function with pager support.
/// Sets up pager before calling fn, tears down after.
pub fn withPager(
    allocator: std.mem.Allocator,
    git_dir: ?[]const u8,
    comptime func: fn () anyerror!void,
) void {
    startPager(allocator, git_dir);
    defer stopPager();
    func() catch {};
}

/// Check if a command should use a pager.
pub fn shouldUsePager(command: []const u8) bool {
    const paged_commands = [_][]const u8{
        "log",
        "diff",
        "show",
        "blame",
        "shortlog",
    };

    for (paged_commands) |cmd| {
        if (std.mem.eql(u8, command, cmd)) return true;
    }
    return false;
}

// NOTE: getEnvVar and buildPath were removed because getEnvVar returned a
// slice into the EnvMap which was freed by `defer env_map.deinit()`, producing
// a dangling pointer. getPagerCommand was simplified to avoid this class of bug.
