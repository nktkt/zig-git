const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const repack_mod = @import("repack.zig");
const prune_mod = @import("prune.zig");
const reflog_expire_mod = @import("reflog_expire.zig");
const pack_refs_mod = @import("pack_refs.zig");
const commit_graph_write = @import("commit_graph_write.zig");
const config_mod = @import("config.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Auto thresholds.
const AUTO_LOOSE_THRESHOLD: u32 = 6700;
const AUTO_PACK_THRESHOLD: u32 = 50;

/// Default prune expiry: 2 weeks ago.
const DEFAULT_PRUNE_EXPIRE_DAYS: i64 = 14;

/// GC options.
pub const GcOptions = struct {
    aggressive: bool = false,
    auto: bool = false,
    prune_expire: ?i64 = null, // Unix timestamp
    quiet: bool = false,
};

/// GC statistics.
pub const GcStats = struct {
    loose_objects_before: u32 = 0,
    loose_objects_after: u32 = 0,
    pack_files_before: u32 = 0,
    pack_files_after: u32 = 0,
    pruned_objects: u32 = 0,
    freed_bytes: u64 = 0,
    expired_reflog_entries: u32 = 0,
    packed_refs: u32 = 0,
    commit_graph_commits: u32 = 0,
    temp_files_cleaned: u32 = 0,
};

/// Run the gc command (called from main).
pub fn runGc(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = GcOptions{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--aggressive")) {
            opts.aggressive = true;
        } else if (std.mem.eql(u8, arg, "--auto")) {
            opts.auto = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            opts.quiet = true;
        } else if (std.mem.startsWith(u8, arg, "--prune=")) {
            const time_str = arg["--prune=".len..];
            opts.prune_expire = prune_mod.parseTimeExpression(time_str);
        }
    }

    try runGcInternal(allocator, repo, opts);
}

/// Internal GC function used by both the command and maintenance.
pub fn runGcInternal(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    opts: GcOptions,
) !void {
    var stats = GcStats{};

    // Count initial state
    stats.loose_objects_before = repack_mod.countLooseObjects(repo);
    stats.pack_files_before = repack_mod.countPackFiles(repo);

    // Auto mode: check if GC is needed
    if (opts.auto) {
        if (stats.loose_objects_before < AUTO_LOOSE_THRESHOLD and
            stats.pack_files_before < AUTO_PACK_THRESHOLD)
        {
            if (!opts.quiet) {
                try stdout_file.writeAll("Auto GC: nothing to do.\n");
            }
            return;
        }
        if (!opts.quiet) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Auto GC: {d} loose objects, {d} pack files. Running...\n", .{ stats.loose_objects_before, stats.pack_files_before }) catch return;
            try stdout_file.writeAll(msg);
        }
    }

    if (!opts.quiet) {
        try stdout_file.writeAll("Garbage collecting...\n");
    }

    // Step 1: Expire reflog entries
    if (!opts.quiet) try stdout_file.writeAll("  Expiring reflog entries...\n");
    {
        const expire_result = reflog_expire_mod.expireReflog(allocator, repo, .{
            .all = true,
            .dry_run = false,
        }) catch |err| blk: {
            if (!opts.quiet) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "  Warning: reflog expire failed: {s}\n", .{@errorName(err)}) catch "  Warning: reflog expire failed\n";
                stderr_file.writeAll(msg) catch {};
            }
            break :blk reflog_expire_mod.ReflogExpireResult{};
        };
        stats.expired_reflog_entries = expire_result.expired_count;
    }

    // Step 2: Pack refs
    if (!opts.quiet) try stdout_file.writeAll("  Packing refs...\n");
    {
        stats.packed_refs = pack_refs_mod.packRefs(allocator, repo, .{ .all = true }) catch 0;
    }

    // Step 3: Repack objects
    if (!opts.quiet) try stdout_file.writeAll("  Repacking objects...\n");
    {
        const repack_opts = repack_mod.RepackOptions{
            .all = true,
            .delete_old = true,
            .window_size = if (opts.aggressive) @as(usize, 250) else @as(usize, 10),
            .depth_limit = if (opts.aggressive) @as(usize, 250) else @as(usize, 50),
            .quiet = true, // We handle our own output
        };
        repack_mod.repackRepository(allocator, repo, repack_opts) catch |err| {
            if (!opts.quiet) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "  Warning: repack failed: {s}\n", .{@errorName(err)}) catch "  Warning: repack failed\n";
                stderr_file.writeAll(msg) catch {};
            }
        };
    }

    // Step 4: Prune unreachable objects
    if (!opts.quiet) try stdout_file.writeAll("  Pruning unreachable objects...\n");
    {
        const now = getCurrentTimestamp() orelse 0;
        const prune_expire = opts.prune_expire orelse (now - DEFAULT_PRUNE_EXPIRE_DAYS * 86400);

        const prune_result = prune_mod.pruneObjects(allocator, repo, .{
            .dry_run = false,
            .expire_time = prune_expire,
        }) catch |err| blk: {
            if (!opts.quiet) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "  Warning: prune failed: {s}\n", .{@errorName(err)}) catch "  Warning: prune failed\n";
                stderr_file.writeAll(msg) catch {};
            }
            break :blk prune_mod.PruneResult{};
        };
        stats.pruned_objects = prune_result.deleted_count;
        stats.freed_bytes = prune_result.freed_bytes;
    }

    // Step 5: Clean up temporary files
    if (!opts.quiet) try stdout_file.writeAll("  Cleaning temporary files...\n");
    stats.temp_files_cleaned = cleanTempFiles(repo);

    // Step 6: Write commit-graph (if enabled)
    if (!opts.quiet) try stdout_file.writeAll("  Writing commit-graph...\n");
    {
        if (isCommitGraphEnabled(allocator, repo)) {
            stats.commit_graph_commits = commit_graph_write.writeCommitGraph(allocator, repo) catch 0;
        }
    }

    // Count final state
    stats.loose_objects_after = repack_mod.countLooseObjects(repo);
    stats.pack_files_after = repack_mod.countPackFiles(repo);

    // Print statistics
    if (!opts.quiet) {
        try printStats(stats);
    }
}

/// Clean up temporary files in .git/objects/tmp_*
fn cleanTempFiles(repo: *repository.Repository) u32 {
    var count: u32 = 0;
    var dir_path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(dir_path_buf[pos..][0..repo.git_dir.len], repo.git_dir);
    pos += repo.git_dir.len;
    const obj_suffix = "/objects";
    @memcpy(dir_path_buf[pos..][0..obj_suffix.len], obj_suffix);
    pos += obj_suffix.len;
    const objects_dir = dir_path_buf[0..pos];

    var dir = std.fs.openDirAbsolute(objects_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file and entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "tmp_")) continue;

        // Build full path
        var full_buf: [4096]u8 = undefined;
        var fp: usize = 0;
        @memcpy(full_buf[fp..][0..objects_dir.len], objects_dir);
        fp += objects_dir.len;
        full_buf[fp] = '/';
        fp += 1;
        @memcpy(full_buf[fp..][0..entry.name.len], entry.name);
        fp += entry.name.len;

        if (entry.kind == .file) {
            std.fs.deleteFileAbsolute(full_buf[0..fp]) catch continue;
            count += 1;
        } else if (entry.kind == .directory) {
            std.fs.deleteTreeAbsolute(full_buf[0..fp]) catch continue;
            count += 1;
        }
    }

    return count;
}

/// Check if commit-graph is enabled in config.
fn isCommitGraphEnabled(allocator: std.mem.Allocator, repo: *repository.Repository) bool {
    var config_path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(config_path_buf[pos..][0..repo.git_dir.len], repo.git_dir);
    pos += repo.git_dir.len;
    const suffix = "/config";
    @memcpy(config_path_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    const config_path = config_path_buf[0..pos];

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch return true; // Default to enabled
    defer cfg.deinit();

    if (cfg.get("core.commitGraph")) |val| {
        return std.mem.eql(u8, val, "true");
    }
    // Also check gc.writeCommitGraph
    if (cfg.get("gc.writeCommitGraph")) |val| {
        return std.mem.eql(u8, val, "true");
    }

    return true; // Default enabled
}

/// Print GC statistics.
fn printStats(stats: GcStats) !void {
    try stdout_file.writeAll("\nGC Statistics:\n");

    var buf: [256]u8 = undefined;
    var msg: []const u8 = undefined;

    msg = std.fmt.bufPrint(&buf, "  Loose objects: {d} -> {d}\n", .{ stats.loose_objects_before, stats.loose_objects_after }) catch return;
    try stdout_file.writeAll(msg);

    msg = std.fmt.bufPrint(&buf, "  Pack files: {d} -> {d}\n", .{ stats.pack_files_before, stats.pack_files_after }) catch return;
    try stdout_file.writeAll(msg);

    if (stats.pruned_objects > 0) {
        msg = std.fmt.bufPrint(&buf, "  Pruned objects: {d} ({d} bytes freed)\n", .{ stats.pruned_objects, stats.freed_bytes }) catch return;
        try stdout_file.writeAll(msg);
    }

    if (stats.expired_reflog_entries > 0) {
        msg = std.fmt.bufPrint(&buf, "  Expired reflog entries: {d}\n", .{stats.expired_reflog_entries}) catch return;
        try stdout_file.writeAll(msg);
    }

    if (stats.packed_refs > 0) {
        msg = std.fmt.bufPrint(&buf, "  Packed refs: {d}\n", .{stats.packed_refs}) catch return;
        try stdout_file.writeAll(msg);
    }

    if (stats.commit_graph_commits > 0) {
        msg = std.fmt.bufPrint(&buf, "  Commit-graph: {d} commits\n", .{stats.commit_graph_commits}) catch return;
        try stdout_file.writeAll(msg);
    }

    if (stats.temp_files_cleaned > 0) {
        msg = std.fmt.bufPrint(&buf, "  Temp files cleaned: {d}\n", .{stats.temp_files_cleaned}) catch return;
        try stdout_file.writeAll(msg);
    }

    try stdout_file.writeAll("Done.\n");
}

fn getCurrentTimestamp() ?i64 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return null;
    return ts.sec;
}

test "GcOptions defaults" {
    const opts = GcOptions{};
    try std.testing.expect(!opts.aggressive);
    try std.testing.expect(!opts.auto);
    try std.testing.expect(!opts.quiet);
    try std.testing.expect(opts.prune_expire == null);
}

test "auto thresholds" {
    try std.testing.expectEqual(@as(u32, 6700), AUTO_LOOSE_THRESHOLD);
    try std.testing.expectEqual(@as(u32, 50), AUTO_PACK_THRESHOLD);
}
