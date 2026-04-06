const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const gc_mod = @import("gc.zig");
const repack_mod = @import("repack.zig");
const pack_refs_mod = @import("pack_refs.zig");
const commit_graph_write = @import("commit_graph_write.zig");
const reflog_expire_mod = @import("reflog_expire.zig");
const prune_mod = @import("prune.zig");
const config_mod = @import("config.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Maintenance task type.
pub const TaskType = enum {
    gc,
    commit_graph,
    prefetch,
    loose_objects,
    incremental_repack,
    pack_refs,
};

/// Task schedule.
pub const Schedule = enum {
    hourly,
    daily,
    weekly,
};

/// Task configuration.
const TaskConfig = struct {
    task_type: TaskType,
    schedule: Schedule,
    enabled: bool,
};

/// Default task configurations.
const default_tasks = [_]TaskConfig{
    .{ .task_type = .gc, .schedule = .daily, .enabled = true },
    .{ .task_type = .commit_graph, .schedule = .hourly, .enabled = true },
    .{ .task_type = .prefetch, .schedule = .hourly, .enabled = false },
    .{ .task_type = .loose_objects, .schedule = .daily, .enabled = true },
    .{ .task_type = .incremental_repack, .schedule = .daily, .enabled = true },
    .{ .task_type = .pack_refs, .schedule = .daily, .enabled = true },
};

/// Run the maintenance command.
pub fn runMaintenance(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        try stderr_file.writeAll("usage: zig-git maintenance <subcommand>\n");
        try stderr_file.writeAll("\nSubcommands:\n");
        try stderr_file.writeAll("  run          Run maintenance tasks\n");
        try stderr_file.writeAll("  register     Register repo for maintenance\n");
        try stderr_file.writeAll("  unregister   Unregister repo from maintenance\n");
        try stderr_file.writeAll("  start        Enable background maintenance\n");
        std.process.exit(1);
    }

    const subcmd = args[0];
    const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, subcmd, "run")) {
        try runMaintenanceTasks(repo, allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "register")) {
        try registerRepo(repo, allocator);
    } else if (std.mem.eql(u8, subcmd, "unregister")) {
        try unregisterRepo(repo, allocator);
    } else if (std.mem.eql(u8, subcmd, "start")) {
        try startMaintenance(repo, allocator);
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: unknown maintenance subcommand: {s}\n", .{subcmd}) catch "fatal: unknown subcommand\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    }
}

/// Run maintenance tasks.
fn runMaintenanceTasks(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var specific_task: ?TaskType = null;
    var quiet = false;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--task=")) {
            const task_name = arg["--task=".len..];
            specific_task = parseTaskType(task_name);
            if (specific_task == null) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: unknown task: {s}\n", .{task_name}) catch "fatal: unknown task\n";
                try stderr_file.writeAll(msg);
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        }
    }

    if (specific_task) |task| {
        try runTask(repo, allocator, task, quiet);
    } else {
        // Run all enabled tasks
        for (default_tasks) |task_config| {
            if (!task_config.enabled) continue;
            if (!quiet) {
                const name = taskTypeName(task_config.task_type);
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Running task: {s}\n", .{name}) catch continue;
                try stdout_file.writeAll(msg);
            }
            runTask(repo, allocator, task_config.task_type, quiet) catch |err| {
                if (!quiet) {
                    const name = taskTypeName(task_config.task_type);
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "warning: task {s} failed: {s}\n", .{ name, @errorName(err) }) catch continue;
                    stderr_file.writeAll(msg) catch {};
                }
            };
        }
    }

    if (!quiet) {
        try stdout_file.writeAll("Maintenance complete.\n");
    }
}

/// Run a specific maintenance task.
fn runTask(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    task: TaskType,
    quiet: bool,
) !void {
    switch (task) {
        .gc => {
            try gc_mod.runGcInternal(allocator, repo, .{ .quiet = quiet });
        },
        .commit_graph => {
            const count = try commit_graph_write.writeCommitGraph(allocator, repo);
            if (!quiet) {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Updated commit-graph with {d} commits.\n", .{count}) catch return;
                try stdout_file.writeAll(msg);
            }
        },
        .prefetch => {
            // Prefetch is a no-op for now (requires network)
            if (!quiet) {
                try stdout_file.writeAll("Skipping prefetch (no remotes configured).\n");
            }
        },
        .loose_objects => {
            const loose_count = repack_mod.countLooseObjects(repo);
            if (loose_count > 100) {
                try repack_mod.repackRepository(allocator, repo, .{
                    .all = false,
                    .delete_old = false,
                    .quiet = quiet,
                });
            } else if (!quiet) {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Only {d} loose objects, skipping.\n", .{loose_count}) catch return;
                try stdout_file.writeAll(msg);
            }
        },
        .incremental_repack => {
            const pack_count = repack_mod.countPackFiles(repo);
            if (pack_count > 5) {
                try repack_mod.repackRepository(allocator, repo, .{
                    .all = true,
                    .delete_old = true,
                    .quiet = quiet,
                });
            } else if (!quiet) {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Only {d} pack files, skipping incremental repack.\n", .{pack_count}) catch return;
                try stdout_file.writeAll(msg);
            }
        },
        .pack_refs => {
            const count = try pack_refs_mod.packRefs(allocator, repo, .{ .all = true });
            if (!quiet) {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Packed {d} refs.\n", .{count}) catch return;
                try stdout_file.writeAll(msg);
            }
        },
    }
}

/// Register the repository for background maintenance.
fn registerRepo(repo: *repository.Repository, allocator: std.mem.Allocator) !void {
    // Write maintenance config to .git/config
    var config_path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(config_path_buf[pos..][0..repo.git_dir.len], repo.git_dir);
    pos += repo.git_dir.len;
    const suffix = "/config";
    @memcpy(config_path_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    const config_path = config_path_buf[0..pos];

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch {
        try stderr_file.writeAll("warning: could not load config, creating new\n");
        return;
    };
    defer cfg.deinit();

    cfg.set("maintenance.auto", "true") catch {};
    cfg.writeFile(config_path) catch {
        try stderr_file.writeAll("fatal: could not write config\n");
        std.process.exit(128);
    };

    try stdout_file.writeAll("Repository registered for maintenance.\n");
}

/// Unregister the repository from background maintenance.
fn unregisterRepo(repo: *repository.Repository, allocator: std.mem.Allocator) !void {
    var config_path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(config_path_buf[pos..][0..repo.git_dir.len], repo.git_dir);
    pos += repo.git_dir.len;
    const suffix = "/config";
    @memcpy(config_path_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    const config_path = config_path_buf[0..pos];

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch return;
    defer cfg.deinit();

    cfg.set("maintenance.auto", "false") catch {};
    cfg.writeFile(config_path) catch {
        try stderr_file.writeAll("fatal: could not write config\n");
        std.process.exit(128);
    };

    try stdout_file.writeAll("Repository unregistered from maintenance.\n");
}

/// Enable background maintenance.
fn startMaintenance(repo: *repository.Repository, allocator: std.mem.Allocator) !void {
    // Register first
    try registerRepo(repo, allocator);

    // In a real implementation, this would set up a cron job or launchd plist.
    // For now, just inform the user.
    try stdout_file.writeAll("Background maintenance enabled.\n");
    try stdout_file.writeAll("Note: Background scheduling requires system-specific setup.\n");
    try stdout_file.writeAll("Run 'zig-git maintenance run' manually or set up a cron job:\n");
    try stdout_file.writeAll("  */15 * * * * cd /path/to/repo && zig-git maintenance run --quiet\n");
}

fn parseTaskType(name: []const u8) ?TaskType {
    if (std.mem.eql(u8, name, "gc")) return .gc;
    if (std.mem.eql(u8, name, "commit-graph")) return .commit_graph;
    if (std.mem.eql(u8, name, "prefetch")) return .prefetch;
    if (std.mem.eql(u8, name, "loose-objects")) return .loose_objects;
    if (std.mem.eql(u8, name, "incremental-repack")) return .incremental_repack;
    if (std.mem.eql(u8, name, "pack-refs")) return .pack_refs;
    return null;
}

fn taskTypeName(t: TaskType) []const u8 {
    return switch (t) {
        .gc => "gc",
        .commit_graph => "commit-graph",
        .prefetch => "prefetch",
        .loose_objects => "loose-objects",
        .incremental_repack => "incremental-repack",
        .pack_refs => "pack-refs",
    };
}

test "parseTaskType" {
    try std.testing.expect(parseTaskType("gc") != null);
    try std.testing.expect(parseTaskType("commit-graph") != null);
    try std.testing.expect(parseTaskType("nonexistent") == null);
}
