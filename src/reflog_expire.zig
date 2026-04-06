const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const reflog_mod = @import("reflog.zig");
const ref_mod = @import("ref.zig");
const prune_mod = @import("prune.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Default expiry: 90 days for reachable entries.
const DEFAULT_EXPIRE_DAYS: i64 = 90;
/// Default expiry: 30 days for unreachable entries.
const DEFAULT_EXPIRE_UNREACHABLE_DAYS: i64 = 30;

/// Options for reflog expire.
pub const ReflogExpireOptions = struct {
    expire_time: ?i64 = null, // Unix timestamp for reachable entries
    expire_unreachable_time: ?i64 = null, // Unix timestamp for unreachable entries
    all: bool = false, // Apply to all refs
    dry_run: bool = false,
    verbose: bool = false,
    ref_name: ?[]const u8 = null,
};

/// Result of a reflog expire operation.
pub const ReflogExpireResult = struct {
    expired_count: u32 = 0,
    kept_count: u32 = 0,
    refs_processed: u32 = 0,
};

/// Run the reflog expire command.
pub fn runReflogExpire(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = ReflogExpireOptions{};

    // Set defaults
    const now = getCurrentTimestamp() orelse 0;
    opts.expire_time = now - DEFAULT_EXPIRE_DAYS * 86400;
    opts.expire_unreachable_time = now - DEFAULT_EXPIRE_UNREACHABLE_DAYS * 86400;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--expire=")) {
            const time_str = arg["--expire=".len..];
            if (std.mem.eql(u8, time_str, "never")) {
                opts.expire_time = null;
            } else {
                opts.expire_time = prune_mod.parseTimeExpression(time_str);
            }
        } else if (std.mem.startsWith(u8, arg, "--expire-unreachable=")) {
            const time_str = arg["--expire-unreachable=".len..];
            if (std.mem.eql(u8, time_str, "never")) {
                opts.expire_unreachable_time = null;
            } else {
                opts.expire_unreachable_time = prune_mod.parseTimeExpression(time_str);
            }
        } else if (std.mem.eql(u8, arg, "--all")) {
            opts.all = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            opts.ref_name = arg;
        }
    }

    const result = try expireReflog(allocator, repo, opts);

    var buf: [256]u8 = undefined;
    if (opts.dry_run) {
        const msg = std.fmt.bufPrint(&buf, "Would expire {d} reflog entries across {d} refs (keeping {d})\n", .{ result.expired_count, result.refs_processed, result.kept_count }) catch return;
        try stdout_file.writeAll(msg);
    } else {
        const msg = std.fmt.bufPrint(&buf, "Expired {d} reflog entries across {d} refs (keeping {d})\n", .{ result.expired_count, result.refs_processed, result.kept_count }) catch return;
        try stdout_file.writeAll(msg);
    }
}

/// Run the reflog delete command (delete specific entry).
pub fn runReflogDelete(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len < 1) {
        try stderr_file.writeAll("usage: zig-git reflog delete <ref>@{<n>}\n");
        std.process.exit(1);
    }

    const spec = args[0];
    // Parse "ref@{n}"
    const at_pos = std.mem.indexOf(u8, spec, "@{") orelse {
        try stderr_file.writeAll("fatal: invalid reflog entry specifier\n");
        std.process.exit(1);
    };
    const close_pos = std.mem.indexOfScalar(u8, spec, '}') orelse {
        try stderr_file.writeAll("fatal: invalid reflog entry specifier\n");
        std.process.exit(1);
    };

    const ref_name = spec[0..at_pos];
    const idx_str = spec[at_pos + 2 .. close_pos];
    const idx = std.fmt.parseInt(usize, idx_str, 10) catch {
        try stderr_file.writeAll("fatal: invalid reflog entry index\n");
        std.process.exit(1);
    };

    try deleteReflogEntry(allocator, repo, ref_name, idx);
    try stdout_file.writeAll("Deleted reflog entry.\n");
}

/// Core logic for expiring reflog entries.
pub fn expireReflog(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    opts: ReflogExpireOptions,
) !ReflogExpireResult {
    var result = ReflogExpireResult{};

    if (opts.all) {
        // Process HEAD
        try expireRefForRef(allocator, repo, "HEAD", opts, &result);

        // Process all branch refs
        const refs = ref_mod.listRefs(allocator, repo.git_dir, "refs/heads/") catch &[_]ref_mod.RefEntry{};
        defer {
            for (refs) |e| allocator.free(@constCast(e.name));
            allocator.free(refs);
        }
        for (refs) |entry| {
            try expireRefForRef(allocator, repo, entry.name, opts, &result);
        }

        // Process tag refs
        const tag_refs = ref_mod.listRefs(allocator, repo.git_dir, "refs/tags/") catch &[_]ref_mod.RefEntry{};
        defer {
            for (tag_refs) |e| allocator.free(@constCast(e.name));
            allocator.free(tag_refs);
        }
        for (tag_refs) |entry| {
            try expireRefForRef(allocator, repo, entry.name, opts, &result);
        }
    } else {
        const ref_name = opts.ref_name orelse "HEAD";
        try expireRefForRef(allocator, repo, ref_name, opts, &result);
    }

    return result;
}

/// Expire entries for a single ref.
fn expireRefForRef(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    ref_name: []const u8,
    opts: ReflogExpireOptions,
    result: *ReflogExpireResult,
) !void {
    var rlog = reflog_mod.readReflog(allocator, repo.git_dir, ref_name) catch return;
    defer rlog.deinit();

    if (rlog.entries.len == 0) return;

    result.refs_processed += 1;

    // Determine which entries to keep
    var keep_flags = try allocator.alloc(bool, rlog.entries.len);
    defer allocator.free(keep_flags);

    for (rlog.entries, 0..) |entry, ei| {
        keep_flags[ei] = true;

        // Parse timestamp from entry
        const ts = std.fmt.parseInt(i64, entry.timestamp, 10) catch continue;

        // Check reachable expiry
        if (opts.expire_time) |expire| {
            if (ts < expire) {
                keep_flags[ei] = false;
                result.expired_count += 1;
                continue;
            }
        }

        // Check if the referenced object is reachable (simplified: check if it exists)
        if (opts.expire_unreachable_time) |expire_unreach| {
            if (!repo.objectExists(&entry.new_oid) and ts < expire_unreach) {
                keep_flags[ei] = false;
                result.expired_count += 1;
                continue;
            }
        }

        result.kept_count += 1;
    }

    // Rewrite the reflog file if not dry run
    if (!opts.dry_run) {
        try rewriteReflog(allocator, repo.git_dir, ref_name, rlog.entries, keep_flags);
    }
}

/// Delete a specific reflog entry by index.
fn deleteReflogEntry(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    ref_name: []const u8,
    entry_idx: usize,
) !void {
    var rlog = reflog_mod.readReflog(allocator, repo.git_dir, ref_name) catch {
        return error.ReflogNotFound;
    };
    defer rlog.deinit();

    if (rlog.entries.len == 0) return error.ReflogNotFound;

    // Entries are stored oldest-first, but displayed newest-first
    // Index 0 in display = last entry in storage
    if (entry_idx >= rlog.entries.len) return error.ReflogEntryNotFound;

    const storage_idx = rlog.entries.len - 1 - entry_idx;

    var keep_flags = try allocator.alloc(bool, rlog.entries.len);
    defer allocator.free(keep_flags);
    for (keep_flags) |*f| f.* = true;
    keep_flags[storage_idx] = false;

    try rewriteReflog(allocator, repo.git_dir, ref_name, rlog.entries, keep_flags);
}

/// Rewrite a reflog file keeping only entries where keep[i] is true.
fn rewriteReflog(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    ref_name: []const u8,
    entries: []const reflog_mod.ReflogEntry,
    keep_flags: []const bool,
) !void {
    // Build the new reflog content
    var content = std.array_list.Managed(u8).init(allocator);
    defer content.deinit();

    for (entries, 0..) |entry, ei| {
        if (!keep_flags[ei]) continue;

        const old_hex = entry.old_oid.toHex();
        const new_hex = entry.new_oid.toHex();

        try content.appendSlice(&old_hex);
        try content.append(' ');
        try content.appendSlice(&new_hex);
        try content.append(' ');
        try content.appendSlice(entry.name);
        try content.appendSlice(" <");
        try content.appendSlice(entry.email);
        try content.appendSlice("> ");
        try content.appendSlice(entry.timestamp);
        try content.append(' ');
        try content.appendSlice(entry.timezone);
        try content.append('\t');
        try content.appendSlice(entry.message);
        try content.append('\n');
    }

    // Build the reflog path
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    const logs_suffix = "/logs/";
    @memcpy(path_buf[pos..][0..logs_suffix.len], logs_suffix);
    pos += logs_suffix.len;
    @memcpy(path_buf[pos..][0..ref_name.len], ref_name);
    pos += ref_name.len;
    const log_path = path_buf[0..pos];

    // Write to temp file first, then rename (atomic)
    var tmp_path_buf: [4096]u8 = undefined;
    @memcpy(tmp_path_buf[0..pos], log_path);
    const tmp_suffix = ".tmp";
    @memcpy(tmp_path_buf[pos..][0..tmp_suffix.len], tmp_suffix);
    const tmp_path = tmp_path_buf[0 .. pos + tmp_suffix.len];

    const file = std.fs.createFileAbsolute(tmp_path, .{}) catch return error.ReflogWriteFailed;
    defer file.close();
    file.writeAll(content.items) catch return error.ReflogWriteFailed;

    std.fs.renameAbsolute(tmp_path, log_path) catch return error.ReflogWriteFailed;
}

fn getCurrentTimestamp() ?i64 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return null;
    return ts.sec;
}

test "ReflogExpireOptions defaults" {
    var opts = ReflogExpireOptions{};
    opts.expire_time = 0;
    try std.testing.expect(opts.expire_time != null);
    try std.testing.expect(!opts.all);
}
