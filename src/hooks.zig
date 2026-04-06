const std = @import("std");

/// Known git hook names.
pub const HookName = enum {
    pre_commit,
    prepare_commit_msg,
    commit_msg,
    post_commit,
    pre_rebase,
    post_checkout,
    post_merge,
    pre_push,
    pre_receive,
    update,
    post_receive,
    post_update,
    pre_auto_gc,
    post_rewrite,
    applypatch_msg,
    pre_applypatch,
    post_applypatch,
    fsmonitor_watchman,
    p4_changelist,
    p4_prepare_changelist,
    p4_post_changelist,
    p4_pre_submit,
    push_to_checkout,
    sendemail_validate,

    /// Convert to the filesystem filename for the hook.
    pub fn toFileName(self: HookName) []const u8 {
        return switch (self) {
            .pre_commit => "pre-commit",
            .prepare_commit_msg => "prepare-commit-msg",
            .commit_msg => "commit-msg",
            .post_commit => "post-commit",
            .pre_rebase => "pre-rebase",
            .post_checkout => "post-checkout",
            .post_merge => "post-merge",
            .pre_push => "pre-push",
            .pre_receive => "pre-receive",
            .update => "update",
            .post_receive => "post-receive",
            .post_update => "post-update",
            .pre_auto_gc => "pre-auto-gc",
            .post_rewrite => "post-rewrite",
            .applypatch_msg => "applypatch-msg",
            .pre_applypatch => "pre-applypatch",
            .post_applypatch => "post-applypatch",
            .fsmonitor_watchman => "fsmonitor-watchman",
            .p4_changelist => "p4-changelist",
            .p4_prepare_changelist => "p4-prepare-changelist",
            .p4_post_changelist => "p4-post-changelist",
            .p4_pre_submit => "p4-pre-submit",
            .push_to_checkout => "push-to-checkout",
            .sendemail_validate => "sendemail-validate",
        };
    }

    /// Parse a hook name from a string.
    pub fn fromString(s: []const u8) ?HookName {
        if (std.mem.eql(u8, s, "pre-commit")) return .pre_commit;
        if (std.mem.eql(u8, s, "prepare-commit-msg")) return .prepare_commit_msg;
        if (std.mem.eql(u8, s, "commit-msg")) return .commit_msg;
        if (std.mem.eql(u8, s, "post-commit")) return .post_commit;
        if (std.mem.eql(u8, s, "pre-rebase")) return .pre_rebase;
        if (std.mem.eql(u8, s, "post-checkout")) return .post_checkout;
        if (std.mem.eql(u8, s, "post-merge")) return .post_merge;
        if (std.mem.eql(u8, s, "pre-push")) return .pre_push;
        if (std.mem.eql(u8, s, "pre-receive")) return .pre_receive;
        if (std.mem.eql(u8, s, "update")) return .update;
        if (std.mem.eql(u8, s, "post-receive")) return .post_receive;
        if (std.mem.eql(u8, s, "post-update")) return .post_update;
        if (std.mem.eql(u8, s, "pre-auto-gc")) return .pre_auto_gc;
        if (std.mem.eql(u8, s, "post-rewrite")) return .post_rewrite;
        if (std.mem.eql(u8, s, "applypatch-msg")) return .applypatch_msg;
        if (std.mem.eql(u8, s, "pre-applypatch")) return .pre_applypatch;
        if (std.mem.eql(u8, s, "post-applypatch")) return .post_applypatch;
        if (std.mem.eql(u8, s, "fsmonitor-watchman")) return .fsmonitor_watchman;
        if (std.mem.eql(u8, s, "p4-changelist")) return .p4_changelist;
        if (std.mem.eql(u8, s, "p4-prepare-changelist")) return .p4_prepare_changelist;
        if (std.mem.eql(u8, s, "p4-post-changelist")) return .p4_post_changelist;
        if (std.mem.eql(u8, s, "p4-pre-submit")) return .p4_pre_submit;
        if (std.mem.eql(u8, s, "push-to-checkout")) return .push_to_checkout;
        if (std.mem.eql(u8, s, "sendemail-validate")) return .sendemail_validate;
        return null;
    }
};

/// Result of running a hook.
pub const HookResult = enum {
    /// Hook ran successfully (exit code 0) or hook does not exist.
    success,
    /// Hook exists but returned non-zero exit code.
    rejected,
    /// Hook could not be executed (permission error, etc.).
    failed,
    /// Hook was not found.
    not_found,
};

/// Options for hook execution.
pub const HookOptions = struct {
    /// Timeout in milliseconds. 0 = no timeout.
    timeout_ms: u64 = 0,
    /// Stdin data to pass to the hook.
    stdin_data: ?[]const u8 = null,
    /// Working directory for the hook process.
    work_dir: ?[]const u8 = null,
};

/// Check if a hook exists in the given git directory.
pub fn hookExists(git_dir: []const u8, hook_name: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const path = buildHookPath(&path_buf, git_dir, hook_name) orelse return false;

    // Check if the file exists and is executable
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    const stat = file.stat() catch return false;
    // Check executable bit (owner execute)
    const mode = stat.mode;
    return (mode & 0o100) != 0;
}

/// Build the full path to a hook file.
fn buildHookPath(buf: []u8, git_dir: []const u8, hook_name: []const u8) ?[]const u8 {
    const hooks_dir = "/hooks/";
    const total = git_dir.len + hooks_dir.len + hook_name.len;
    if (total > buf.len) return null;

    @memcpy(buf[0..git_dir.len], git_dir);
    @memcpy(buf[git_dir.len..][0..hooks_dir.len], hooks_dir);
    @memcpy(buf[git_dir.len + hooks_dir.len ..][0..hook_name.len], hook_name);
    return buf[0..total];
}

/// Run a hook by name. Returns the hook result.
/// If the hook does not exist, returns .not_found.
pub fn runHook(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    hook_name: []const u8,
    hook_args: []const []const u8,
    options: HookOptions,
) !HookResult {
    var path_buf: [4096]u8 = undefined;
    const hook_path = buildHookPath(&path_buf, git_dir, hook_name) orelse return .failed;

    // Check if hook exists
    if (!hookExists(git_dir, hook_name)) return .not_found;

    return executeHook(allocator, hook_path, hook_args, options);
}

/// Run a hook by HookName enum.
pub fn runHookByName(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    name: HookName,
    hook_args: []const []const u8,
    options: HookOptions,
) !HookResult {
    return runHook(allocator, git_dir, name.toFileName(), hook_args, options);
}

/// Execute a hook script.
fn executeHook(
    allocator: std.mem.Allocator,
    hook_path: []const u8,
    hook_args: []const []const u8,
    options: HookOptions,
) !HookResult {
    // Build argv
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append(hook_path);
    for (hook_args) |arg| {
        try argv.append(arg);
    }

    var child = std.process.Child.init(argv.items, allocator);

    // Set working directory
    if (options.work_dir) |wd| {
        child.cwd = wd;
    }

    // Configure stdin
    if (options.stdin_data != null) {
        child.stdin_behavior = .Pipe;
    } else {
        child.stdin_behavior = .Inherit;
    }

    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch return .failed;

    // Write stdin data if provided
    if (options.stdin_data) |data| {
        if (child.stdin) |stdin| {
            stdin.writeAll(data) catch {};
            stdin.close();
            child.stdin = null;
        }
    }

    // Wait for the process
    const term = child.wait() catch return .failed;

    return switch (term) {
        .Exited => |code| if (code == 0) .success else .rejected,
        .Signal, .Stopped, .Unknown => .failed,
    };
}

/// Run the `zig-git hook run <hook-name>` command.
pub fn runHookCmd(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    args: []const []const u8,
) !void {
    const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    if (args.len < 2 or !std.mem.eql(u8, args[0], "run")) {
        try stderr.writeAll("usage: zig-git hook run <hook-name> [-- <args>]\n");
        std.process.exit(1);
    }

    const hook_name_str = args[1];

    // Collect additional args (after --)
    var hook_args = std.array_list.Managed([]const u8).init(allocator);
    defer hook_args.deinit();

    var found_separator = false;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            found_separator = true;
            continue;
        }
        if (found_separator) {
            try hook_args.append(arg);
        }
    }

    // Determine work directory
    const work_dir: ?[]const u8 = if (std.mem.endsWith(u8, git_dir, "/.git"))
        git_dir[0 .. git_dir.len - 5]
    else
        null;

    const result = try runHook(allocator, git_dir, hook_name_str, hook_args.items, .{
        .work_dir = work_dir,
    });

    switch (result) {
        .success => {},
        .not_found => {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "hook '{s}' not found\n", .{hook_name_str}) catch "hook not found\n";
            try stdout.writeAll(msg);
        },
        .rejected => {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "hook '{s}' was rejected (non-zero exit)\n", .{hook_name_str}) catch "hook rejected\n";
            try stderr.writeAll(msg);
            std.process.exit(1);
        },
        .failed => {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "hook '{s}' failed to execute\n", .{hook_name_str}) catch "hook failed\n";
            try stderr.writeAll(msg);
            std.process.exit(1);
        },
    }
}

/// List all available hooks in the hooks directory.
pub fn listHooks(allocator: std.mem.Allocator, git_dir: []const u8) !std.array_list.Managed([]u8) {
    var result = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit();
    }

    var path_buf: [4096]u8 = undefined;
    const hooks_suffix = "/hooks";
    @memcpy(path_buf[0..git_dir.len], git_dir);
    @memcpy(path_buf[git_dir.len..][0..hooks_suffix.len], hooks_suffix);
    const hooks_dir_path = path_buf[0 .. git_dir.len + hooks_suffix.len];

    var dir = std.fs.openDirAbsolute(hooks_dir_path, .{ .iterate = true }) catch return result;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        // Skip sample hooks
        if (std.mem.endsWith(u8, entry.name, ".sample")) continue;

        const name = try allocator.alloc(u8, entry.name.len);
        @memcpy(name, entry.name);
        try result.append(name);
    }

    return result;
}

/// Get descriptions for common hooks.
pub fn hookDescription(name: HookName) []const u8 {
    return switch (name) {
        .pre_commit => "Runs before a commit is created. Can abort the commit.",
        .prepare_commit_msg => "Runs after default message is created, before editor opens.",
        .commit_msg => "Validates the commit message. Can abort the commit.",
        .post_commit => "Runs after a commit is created. Cannot abort.",
        .pre_rebase => "Runs before a rebase starts. Can abort the rebase.",
        .post_checkout => "Runs after checkout. Cannot abort.",
        .post_merge => "Runs after merge. Cannot abort.",
        .pre_push => "Runs before push. Can abort the push.",
        .pre_receive => "Runs on remote before refs are updated.",
        .update => "Runs once per ref on remote before update.",
        .post_receive => "Runs on remote after refs are updated.",
        .post_update => "Runs on remote after all refs are updated.",
        .pre_auto_gc => "Runs before auto garbage collection.",
        .post_rewrite => "Runs after commands that rewrite commits.",
        .applypatch_msg => "Runs during git-am to validate patch message.",
        .pre_applypatch => "Runs after patch is applied but before commit.",
        .post_applypatch => "Runs after patch commit is made.",
        .fsmonitor_watchman => "Provides file system monitor data.",
        .p4_changelist => "Runs during p4 submit.",
        .p4_prepare_changelist => "Runs after p4 changelist is created.",
        .p4_post_changelist => "Runs after p4 submit.",
        .p4_pre_submit => "Runs before p4 submit.",
        .push_to_checkout => "Runs when push tries to update checked-out branch.",
        .sendemail_validate => "Runs to validate patches before sending email.",
    };
}

test "HookName toFileName" {
    try std.testing.expectEqualStrings("pre-commit", HookName.pre_commit.toFileName());
    try std.testing.expectEqualStrings("post-checkout", HookName.post_checkout.toFileName());
    try std.testing.expectEqualStrings("prepare-commit-msg", HookName.prepare_commit_msg.toFileName());
}

test "HookName fromString" {
    try std.testing.expect(HookName.fromString("pre-commit").? == .pre_commit);
    try std.testing.expect(HookName.fromString("commit-msg").? == .commit_msg);
    try std.testing.expect(HookName.fromString("nonexistent") == null);
}

test "buildHookPath" {
    var buf: [4096]u8 = undefined;
    const path = buildHookPath(&buf, "/repo/.git", "pre-commit");
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/repo/.git/hooks/pre-commit", path.?);
}

test "hookDescription coverage" {
    // Ensure all hooks have a description (doesn't crash)
    inline for (std.meta.fields(HookName)) |field| {
        const name: HookName = @enumFromInt(field.value);
        const desc = hookDescription(name);
        try std.testing.expect(desc.len > 0);
    }
}
