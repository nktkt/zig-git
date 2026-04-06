const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const object_walk = @import("object_walk.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Options for the prune command.
pub const PruneOptions = struct {
    dry_run: bool = false,
    verbose: bool = false,
    expire_time: ?i64 = null, // Unix timestamp; objects newer than this are kept
};

/// Result of a prune operation.
pub const PruneResult = struct {
    deleted_count: u32 = 0,
    freed_bytes: u64 = 0,
    skipped_count: u32 = 0,
};

/// Run the prune command.
pub fn runPrune(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = PruneOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.startsWith(u8, arg, "--expire=")) {
            const time_str = arg["--expire=".len..];
            opts.expire_time = parseTimeExpression(time_str);
        } else if (std.mem.eql(u8, arg, "--expire")) {
            i += 1;
            if (i < args.len) {
                opts.expire_time = parseTimeExpression(args[i]);
            }
        }
    }

    const result = try pruneObjects(allocator, repo, opts);

    var buf: [256]u8 = undefined;
    if (opts.dry_run) {
        const msg = std.fmt.bufPrint(&buf, "Would remove {d} unreachable objects ({d} bytes)\n", .{ result.deleted_count, result.freed_bytes }) catch return;
        try stdout_file.writeAll(msg);
    } else {
        const msg = std.fmt.bufPrint(&buf, "Removed {d} unreachable objects ({d} bytes freed)\n", .{ result.deleted_count, result.freed_bytes }) catch return;
        try stdout_file.writeAll(msg);
    }
    if (result.skipped_count > 0) {
        const msg2 = std.fmt.bufPrint(&buf, "Skipped {d} objects (not yet expired)\n", .{result.skipped_count}) catch return;
        try stdout_file.writeAll(msg2);
    }
}

/// Core prune logic: find and remove unreachable loose objects.
pub fn pruneObjects(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    opts: PruneOptions,
) !PruneResult {
    var result = PruneResult{};

    // Step 1: Build the reachable set
    var reachable = std.AutoHashMap([types.OID_RAW_LEN]u8, void).init(allocator);
    defer reachable.deinit();

    try collectReachableObjects(allocator, repo, &reachable);

    // Step 2: Walk loose objects
    var dir_path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(dir_path_buf[pos..][0..repo.git_dir.len], repo.git_dir);
    pos += repo.git_dir.len;
    const obj_suffix = "/objects";
    @memcpy(dir_path_buf[pos..][0..obj_suffix.len], obj_suffix);
    pos += obj_suffix.len;
    const objects_dir = dir_path_buf[0..pos];

    var dir = std.fs.openDirAbsolute(objects_dir, .{ .iterate = true }) catch return result;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len != 2) continue;
        if (!isHexStr(entry.name)) continue;

        var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
        defer sub_dir.close();
        var sub_iter = sub_dir.iterate();

        while (try sub_iter.next()) |sub_entry| {
            if (sub_entry.kind != .file) continue;
            if (sub_entry.name.len != types.OID_HEX_LEN - 2) continue;

            // Reconstruct OID
            var hex_buf: [types.OID_HEX_LEN]u8 = undefined;
            hex_buf[0] = entry.name[0];
            hex_buf[1] = entry.name[1];
            @memcpy(hex_buf[2..], sub_entry.name[0 .. types.OID_HEX_LEN - 2]);
            const oid = types.ObjectId.fromHex(&hex_buf) catch continue;

            // Check if reachable
            if (reachable.contains(oid.bytes)) continue;

            // Check expiry time
            if (opts.expire_time) |expire| {
                // Build full path to check mtime
                var full_path_buf: [4096]u8 = undefined;
                var fpos: usize = 0;
                @memcpy(full_path_buf[fpos..][0..objects_dir.len], objects_dir);
                fpos += objects_dir.len;
                full_path_buf[fpos] = '/';
                fpos += 1;
                @memcpy(full_path_buf[fpos..][0..entry.name.len], entry.name);
                fpos += entry.name.len;
                full_path_buf[fpos] = '/';
                fpos += 1;
                @memcpy(full_path_buf[fpos..][0..sub_entry.name.len], sub_entry.name);
                fpos += sub_entry.name.len;
                const full_path = full_path_buf[0..fpos];

                const file = std.fs.openFileAbsolute(full_path, .{}) catch continue;
                defer file.close();
                const stat = file.stat() catch continue;
                const mtime_sec: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
                if (mtime_sec > expire) {
                    result.skipped_count += 1;
                    continue;
                }
            }

            // Get file size for statistics
            var full_path_buf2: [4096]u8 = undefined;
            var fpos2: usize = 0;
            @memcpy(full_path_buf2[fpos2..][0..objects_dir.len], objects_dir);
            fpos2 += objects_dir.len;
            full_path_buf2[fpos2] = '/';
            fpos2 += 1;
            @memcpy(full_path_buf2[fpos2..][0..entry.name.len], entry.name);
            fpos2 += entry.name.len;
            full_path_buf2[fpos2] = '/';
            fpos2 += 1;
            @memcpy(full_path_buf2[fpos2..][0..sub_entry.name.len], sub_entry.name);
            fpos2 += sub_entry.name.len;
            const full_path2 = full_path_buf2[0..fpos2];

            var file_size: u64 = 0;
            if (std.fs.openFileAbsolute(full_path2, .{})) |f| {
                const st = f.stat() catch {
                    f.close();
                    continue;
                };
                file_size = st.size;
                f.close();
            } else |_| continue;

            if (opts.verbose) {
                var msg_buf: [256]u8 = undefined;
                const hex = oid.toHex();
                const msg = std.fmt.bufPrint(&msg_buf, "Removing {s}\n", .{&hex}) catch continue;
                stdout_file.writeAll(msg) catch {};
            }

            if (!opts.dry_run) {
                std.fs.deleteFileAbsolute(full_path2) catch continue;
            }

            result.deleted_count += 1;
            result.freed_bytes += file_size;
        }
    }

    return result;
}

/// Collect all reachable objects from refs, reflog, index, MERGE_HEAD, etc.
fn collectReachableObjects(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    reachable: *std.AutoHashMap([types.OID_RAW_LEN]u8, void),
) !void {
    var tips = std.array_list.Managed(types.ObjectId).init(allocator);
    defer tips.deinit();

    // Collect tips from all refs
    const ref_prefixes = [_][]const u8{ "refs/heads/", "refs/tags/", "refs/remotes/" };
    for (ref_prefixes) |prefix| {
        const refs = ref_mod.listRefs(allocator, repo.git_dir, prefix) catch continue;
        defer {
            for (refs) |e| allocator.free(@constCast(e.name));
            allocator.free(refs);
        }
        for (refs) |entry| {
            try tips.append(entry.oid);
        }
    }

    // HEAD
    if (repo.resolveRef(allocator, "HEAD")) |head_oid| {
        try tips.append(head_oid);
    } else |_| {}

    // MERGE_HEAD
    {
        var path_buf: [4096]u8 = undefined;
        var p: usize = 0;
        @memcpy(path_buf[p..][0..repo.git_dir.len], repo.git_dir);
        p += repo.git_dir.len;
        const mh = "/MERGE_HEAD";
        @memcpy(path_buf[p..][0..mh.len], mh);
        p += mh.len;
        const merge_path = path_buf[0..p];
        if (readFileContents(allocator, merge_path)) |content| {
            defer allocator.free(content);
            var line_iter = std.mem.splitScalar(u8, content, '\n');
            while (line_iter.next()) |line| {
                if (line.len >= types.OID_HEX_LEN) {
                    const oid = types.ObjectId.fromHex(line[0..types.OID_HEX_LEN]) catch continue;
                    try tips.append(oid);
                }
            }
        } else |_| {}
    }

    // Reflog entries (these reference objects that should be kept)
    const reflog_refs = [_][]const u8{ "HEAD", "refs/heads/main", "refs/heads/master" };
    for (reflog_refs) |ref_name| {
        var rlog = reflog_mod.readReflog(allocator, repo.git_dir, ref_name) catch continue;
        defer rlog.deinit();
        for (rlog.entries) |entry| {
            if (!entry.old_oid.eql(&types.ObjectId.ZERO)) {
                try tips.append(entry.old_oid);
            }
            if (!entry.new_oid.eql(&types.ObjectId.ZERO)) {
                try tips.append(entry.new_oid);
            }
        }
    }

    // Also walk reflog for all branch refs
    {
        const branch_refs = ref_mod.listRefs(allocator, repo.git_dir, "refs/heads/") catch &[_]ref_mod.RefEntry{};
        defer {
            for (branch_refs) |e| allocator.free(@constCast(e.name));
            allocator.free(branch_refs);
        }
        for (branch_refs) |bref| {
            var rlog = reflog_mod.readReflog(allocator, repo.git_dir, bref.name) catch continue;
            defer rlog.deinit();
            for (rlog.entries) |entry| {
                if (!entry.old_oid.eql(&types.ObjectId.ZERO)) {
                    try tips.append(entry.old_oid);
                }
                if (!entry.new_oid.eql(&types.ObjectId.ZERO)) {
                    try tips.append(entry.new_oid);
                }
            }
        }
    }

    // Walk from all tips to find all reachable objects
    const empty: []const types.ObjectId = &.{};
    const all_reachable = object_walk.walkObjects(allocator, repo, tips.items, empty) catch return;
    defer allocator.free(all_reachable);

    for (all_reachable) |oid| {
        try reachable.put(oid.bytes, {});
    }

    // Also mark the tips themselves as reachable
    for (tips.items) |oid| {
        try reachable.put(oid.bytes, {});
    }
}

/// Parse time expressions like "2.weeks.ago", "now", "90.days.ago", ISO dates.
/// Returns a Unix timestamp.
pub fn parseTimeExpression(expr: []const u8) ?i64 {
    if (std.mem.eql(u8, expr, "now")) {
        return getCurrentTimestamp();
    }

    if (std.mem.eql(u8, expr, "never")) {
        return null;
    }

    // Try parsing as "N.unit.ago"
    if (std.mem.endsWith(u8, expr, ".ago")) {
        const without_ago = expr[0 .. expr.len - 4];
        // Find the last dot
        const dot_pos = std.mem.lastIndexOfScalar(u8, without_ago, '.') orelse return null;
        const num_str = without_ago[0..dot_pos];
        const unit = without_ago[dot_pos + 1 ..];

        const num = std.fmt.parseInt(i64, num_str, 10) catch return null;
        const seconds_per_unit: i64 = if (std.mem.eql(u8, unit, "seconds") or std.mem.eql(u8, unit, "second"))
            1
        else if (std.mem.eql(u8, unit, "minutes") or std.mem.eql(u8, unit, "minute"))
            60
        else if (std.mem.eql(u8, unit, "hours") or std.mem.eql(u8, unit, "hour"))
            3600
        else if (std.mem.eql(u8, unit, "days") or std.mem.eql(u8, unit, "day"))
            86400
        else if (std.mem.eql(u8, unit, "weeks") or std.mem.eql(u8, unit, "week"))
            604800
        else if (std.mem.eql(u8, unit, "months") or std.mem.eql(u8, unit, "month"))
            2592000 // 30 days
        else if (std.mem.eql(u8, unit, "years") or std.mem.eql(u8, unit, "year"))
            31536000 // 365 days
        else
            return null;

        const now = getCurrentTimestamp() orelse return null;
        return now - num * seconds_per_unit;
    }

    // Try as ISO date: YYYY-MM-DD
    if (expr.len >= 10 and expr[4] == '-' and expr[7] == '-') {
        // Simple approximation: parse year/month/day and compute rough timestamp
        const year = std.fmt.parseInt(i64, expr[0..4], 10) catch return null;
        const month = std.fmt.parseInt(i64, expr[5..7], 10) catch return null;
        const day = std.fmt.parseInt(i64, expr[8..10], 10) catch return null;

        // Rough calculation (not accounting for leap years precisely)
        const days_since_epoch = (year - 1970) * 365 + @divFloor((year - 1969), 4) + monthToDays(month) + day - 1;
        return days_since_epoch * 86400;
    }

    // Try as Unix timestamp
    return std.fmt.parseInt(i64, expr, 10) catch null;
}

fn monthToDays(month: i64) i64 {
    const cumulative = [_]i64{ 0, 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    if (month >= 1 and month <= 12) return cumulative[@intCast(month)];
    return 0;
}

fn getCurrentTimestamp() ?i64 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return null;
    return ts.sec;
}

fn isHexStr(s: []const u8) bool {
    for (s) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

fn readFileContents(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
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

test "parseTimeExpression" {
    // "now" should return current time (just check it's non-null)
    const now = parseTimeExpression("now");
    try std.testing.expect(now != null);

    // "never" should return null
    const never = parseTimeExpression("never");
    try std.testing.expect(never == null);

    // "2.weeks.ago" should return a timestamp before now
    const two_weeks = parseTimeExpression("2.weeks.ago");
    try std.testing.expect(two_weeks != null);
    if (now) |n| {
        if (two_weeks) |tw| {
            try std.testing.expect(tw < n);
        }
    }
}
