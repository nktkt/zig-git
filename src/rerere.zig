const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const hash_mod = @import("hash.zig");
const config_mod = @import("config.zig");
const diff_mod = @import("diff.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Default GC thresholds (in seconds).
const DEFAULT_RESOLVED_EXPIRY: i64 = 60 * 24 * 60 * 60; // 60 days
const DEFAULT_UNRESOLVED_EXPIRY: i64 = 15 * 24 * 60 * 60; // 15 days

/// Conflict marker strings.
const CONFLICT_START = "<<<<<<<";
const CONFLICT_SEPARATOR = "=======";
const CONFLICT_END = ">>>>>>>";

/// A recorded resolution entry.
pub const RerereEntry = struct {
    hash_hex: [types.OID_HEX_LEN]u8,
    has_preimage: bool,
    has_postimage: bool,
};

/// Check if rerere is enabled in the config.
pub fn isRerereEnabled(allocator: std.mem.Allocator, git_dir: []const u8) bool {
    var config_path_buf: [4096]u8 = undefined;
    const config_path = concatStr(&config_path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch return false;
    defer cfg.deinit();

    const val = cfg.get("rerere.enabled") orelse return false;
    return std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
}

/// Hash conflict markers in a file to produce a canonical conflict ID.
/// Normalizes conflicts by sorting the two sides to create a stable hash.
pub fn hashConflict(allocator: std.mem.Allocator, content: []const u8) ![hash_mod.SHA1_DIGEST_LENGTH]u8 {
    // Extract all conflict regions and hash them
    var hasher = hash_mod.Sha1.init(.{});

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var in_conflict = false;
    var ours_buf = std.array_list.Managed(u8).init(allocator);
    defer ours_buf.deinit();
    var theirs_buf = std.array_list.Managed(u8).init(allocator);
    defer theirs_buf.deinit();
    var in_ours = false;

    while (line_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, CONFLICT_START)) {
            in_conflict = true;
            in_ours = true;
            ours_buf.clearRetainingCapacity();
            theirs_buf.clearRetainingCapacity();
            continue;
        }

        if (in_conflict and std.mem.startsWith(u8, line, CONFLICT_SEPARATOR)) {
            in_ours = false;
            continue;
        }

        if (in_conflict and std.mem.startsWith(u8, line, CONFLICT_END)) {
            // Normalize: sort the two sides so conflict order doesn't matter
            const ours_data = ours_buf.items;
            const theirs_data = theirs_buf.items;
            if (std.mem.order(u8, ours_data, theirs_data) == .gt) {
                hasher.update(theirs_data);
                hasher.update(ours_data);
            } else {
                hasher.update(ours_data);
                hasher.update(theirs_data);
            }
            in_conflict = false;
            in_ours = false;
            continue;
        }

        if (in_conflict) {
            if (in_ours) {
                try ours_buf.appendSlice(line);
                try ours_buf.append('\n');
            } else {
                try theirs_buf.appendSlice(line);
                try theirs_buf.append('\n');
            }
        }
    }

    return hasher.finalResult();
}

/// Store a preimage (conflicted file content) in the rr-cache.
pub fn storePreimage(allocator: std.mem.Allocator, git_dir: []const u8, file_path: []const u8) !void {
    _ = allocator;

    // Read the conflicted file
    const file = std.fs.cwd().openFile(file_path, .{}) catch return error.FileNotFound;
    defer file.close();
    const stat = try file.stat();
    if (stat.size > 10 * 1024 * 1024) return error.FileTooLarge;

    var content_buf: [10 * 1024 * 1024]u8 = undefined;
    const n = try file.readAll(&content_buf);
    const content = content_buf[0..n];

    // Check if file has conflict markers
    if (!hasConflictMarkers(content)) return error.NoConflictMarkers;

    // Hash the conflict
    var hash_allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&hash_allocator_buf);
    const conflict_hash = hashConflict(fba.allocator(), content) catch return error.HashFailed;
    var hash_hex: [types.OID_HEX_LEN]u8 = undefined;
    hash_mod.bytesToHex(&conflict_hash, &hash_hex);

    // Create rr-cache directory
    var cache_dir_buf: [4096]u8 = undefined;
    var cpos: usize = 0;
    @memcpy(cache_dir_buf[cpos..][0..git_dir.len], git_dir);
    cpos += git_dir.len;
    const rr_suffix = "/rr-cache/";
    @memcpy(cache_dir_buf[cpos..][0..rr_suffix.len], rr_suffix);
    cpos += rr_suffix.len;
    @memcpy(cache_dir_buf[cpos..][0..hash_hex.len], &hash_hex);
    cpos += hash_hex.len;
    const cache_dir = cache_dir_buf[0..cpos];

    ensureDirPath(cache_dir);

    // Write preimage
    var preimage_path_buf: [4096]u8 = undefined;
    const preimage_path = concatStr(&preimage_path_buf, cache_dir, "/preimage");

    const preimage_file = std.fs.createFileAbsolute(preimage_path, .{}) catch return error.CannotWritePreimage;
    defer preimage_file.close();
    preimage_file.writeAll(content) catch return error.CannotWritePreimage;
}

/// Store a postimage (resolved file content) in the rr-cache.
pub fn storePostimage(allocator: std.mem.Allocator, git_dir: []const u8, file_path: []const u8, preimage_content: []const u8) !void {
    _ = allocator;

    // Hash the conflict from the preimage to find the cache entry
    var hash_allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&hash_allocator_buf);
    const conflict_hash = hashConflict(fba.allocator(), preimage_content) catch return error.HashFailed;
    var hash_hex: [types.OID_HEX_LEN]u8 = undefined;
    hash_mod.bytesToHex(&conflict_hash, &hash_hex);

    // Read the resolved file
    const file = std.fs.cwd().openFile(file_path, .{}) catch return error.FileNotFound;
    defer file.close();
    const stat = try file.stat();
    if (stat.size > 10 * 1024 * 1024) return error.FileTooLarge;
    var content_buf: [10 * 1024 * 1024]u8 = undefined;
    const n = try file.readAll(&content_buf);
    const content = content_buf[0..n];

    // Build cache path
    var cache_dir_buf: [4096]u8 = undefined;
    var cpos: usize = 0;
    @memcpy(cache_dir_buf[cpos..][0..git_dir.len], git_dir);
    cpos += git_dir.len;
    const rr_suffix = "/rr-cache/";
    @memcpy(cache_dir_buf[cpos..][0..rr_suffix.len], rr_suffix);
    cpos += rr_suffix.len;
    @memcpy(cache_dir_buf[cpos..][0..hash_hex.len], &hash_hex);
    cpos += hash_hex.len;
    const cache_dir = cache_dir_buf[0..cpos];

    // Write postimage
    var postimage_path_buf: [4096]u8 = undefined;
    const postimage_path = concatStr(&postimage_path_buf, cache_dir, "/postimage");

    const postimage_file = std.fs.createFileAbsolute(postimage_path, .{}) catch return error.CannotWritePostimage;
    defer postimage_file.close();
    postimage_file.writeAll(content) catch return error.CannotWritePostimage;
}

/// Try to auto-resolve a conflict using recorded resolution.
/// Returns true if resolution was applied.
pub fn tryAutoResolve(allocator: std.mem.Allocator, git_dir: []const u8, file_path: []const u8) !bool {
    // Read the conflicted file
    const file = std.fs.cwd().openFile(file_path, .{}) catch return false;
    defer file.close();
    const stat = try file.stat();
    if (stat.size > 10 * 1024 * 1024) return false;
    var content_buf: [10 * 1024 * 1024]u8 = undefined;
    const n = try file.readAll(&content_buf);
    const content = content_buf[0..n];

    if (!hasConflictMarkers(content)) return false;

    // Hash the conflict
    var hash_allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&hash_allocator_buf);
    const conflict_hash = hashConflict(fba.allocator(), content) catch return false;
    var hash_hex: [types.OID_HEX_LEN]u8 = undefined;
    hash_mod.bytesToHex(&conflict_hash, &hash_hex);

    // Check if we have a recorded postimage
    var postimage_path_buf: [4096]u8 = undefined;
    var ppos: usize = 0;
    @memcpy(postimage_path_buf[ppos..][0..git_dir.len], git_dir);
    ppos += git_dir.len;
    const rr_suffix = "/rr-cache/";
    @memcpy(postimage_path_buf[ppos..][0..rr_suffix.len], rr_suffix);
    ppos += rr_suffix.len;
    @memcpy(postimage_path_buf[ppos..][0..hash_hex.len], &hash_hex);
    ppos += hash_hex.len;
    const post_suffix = "/postimage";
    @memcpy(postimage_path_buf[ppos..][0..post_suffix.len], post_suffix);
    ppos += post_suffix.len;
    const postimage_path = postimage_path_buf[0..ppos];

    // Read postimage
    const postimage_file = std.fs.openFileAbsolute(postimage_path, .{}) catch return false;
    defer postimage_file.close();
    const pstat = try postimage_file.stat();
    const postimage = try allocator.alloc(u8, @intCast(pstat.size));
    defer allocator.free(postimage);
    _ = try postimage_file.readAll(postimage);

    // Write the resolved content
    const out_file = std.fs.cwd().createFile(file_path, .{}) catch return false;
    defer out_file.close();
    out_file.writeAll(postimage) catch return false;

    return true;
}

/// Forget a recorded resolution for a file.
pub fn forgetResolution(allocator: std.mem.Allocator, git_dir: []const u8, file_path: []const u8) !void {
    _ = allocator;

    // Read the file to compute conflict hash
    const file = std.fs.cwd().openFile(file_path, .{}) catch return error.FileNotFound;
    defer file.close();
    const stat = try file.stat();
    if (stat.size > 10 * 1024 * 1024) return error.FileTooLarge;
    var content_buf: [10 * 1024 * 1024]u8 = undefined;
    const n = try file.readAll(&content_buf);
    const content = content_buf[0..n];

    var hash_allocator_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&hash_allocator_buf);
    const conflict_hash = hashConflict(fba.allocator(), content) catch return error.HashFailed;
    var hash_hex: [types.OID_HEX_LEN]u8 = undefined;
    hash_mod.bytesToHex(&conflict_hash, &hash_hex);

    // Remove the cache directory
    var cache_dir_buf: [4096]u8 = undefined;
    var cpos: usize = 0;
    @memcpy(cache_dir_buf[cpos..][0..git_dir.len], git_dir);
    cpos += git_dir.len;
    const rr_suffix = "/rr-cache/";
    @memcpy(cache_dir_buf[cpos..][0..rr_suffix.len], rr_suffix);
    cpos += rr_suffix.len;
    @memcpy(cache_dir_buf[cpos..][0..hash_hex.len], &hash_hex);
    cpos += hash_hex.len;
    const cache_dir = cache_dir_buf[0..cpos];

    // Remove preimage and postimage
    var pre_buf: [4096]u8 = undefined;
    const pre_path = concatStr(&pre_buf, cache_dir, "/preimage");
    std.fs.deleteFileAbsolute(pre_path) catch {};

    var post_buf: [4096]u8 = undefined;
    const post_path = concatStr(&post_buf, cache_dir, "/postimage");
    std.fs.deleteFileAbsolute(post_path) catch {};

    // Try to remove directory
    std.fs.deleteDirAbsolute(cache_dir) catch {};

    var out_buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&out_buf, "Forgot resolution for '{s}'.\n", .{file_path}) catch "Forgot resolution.\n";
    try stdout_file.writeAll(msg);
}

/// List current recorded resolutions.
pub fn listRecordings(git_dir: []const u8) !void {
    var cache_dir_buf: [4096]u8 = undefined;
    const cache_dir = concatStr(&cache_dir_buf, git_dir, "/rr-cache");

    var dir = std.fs.openDirAbsolute(cache_dir, .{ .iterate = true }) catch {
        try stdout_file.writeAll("No rerere recordings found.\n");
        return;
    };
    defer dir.close();

    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len != types.OID_HEX_LEN) continue;

        // Check what images exist
        var sub_dir_buf: [4096]u8 = undefined;
        var spos: usize = 0;
        @memcpy(sub_dir_buf[spos..][0..cache_dir.len], cache_dir);
        spos += cache_dir.len;
        sub_dir_buf[spos] = '/';
        spos += 1;
        @memcpy(sub_dir_buf[spos..][0..entry.name.len], entry.name);
        spos += entry.name.len;
        const sub_dir = sub_dir_buf[0..spos];

        var pre_check_buf: [4096]u8 = undefined;
        const pre_check = concatStr(&pre_check_buf, sub_dir, "/preimage");
        const has_pre = isFile(pre_check);

        var post_check_buf: [4096]u8 = undefined;
        const post_check = concatStr(&post_check_buf, sub_dir, "/postimage");
        const has_post = isFile(post_check);

        const status_str: []const u8 = if (has_post) "resolved" else if (has_pre) "unresolved" else "empty";

        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s} ({s})\n", .{ entry.name[0..8], status_str }) catch continue;
        try stdout_file.writeAll(line);
        count += 1;
    }

    if (count == 0) {
        try stdout_file.writeAll("No rerere recordings found.\n");
    }
}

/// Show diff between current conflicted file and recorded resolution.
pub fn showDiff(allocator: std.mem.Allocator, git_dir: []const u8) !void {
    _ = allocator;
    var cache_dir_buf: [4096]u8 = undefined;
    const cache_dir = concatStr(&cache_dir_buf, git_dir, "/rr-cache");

    var dir = std.fs.openDirAbsolute(cache_dir, .{ .iterate = true }) catch {
        try stdout_file.writeAll("No rerere recordings found.\n");
        return;
    };
    defer dir.close();

    var found = false;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len != types.OID_HEX_LEN) continue;

        var sub_dir_buf: [4096]u8 = undefined;
        var spos: usize = 0;
        @memcpy(sub_dir_buf[spos..][0..cache_dir.len], cache_dir);
        spos += cache_dir.len;
        sub_dir_buf[spos] = '/';
        spos += 1;
        @memcpy(sub_dir_buf[spos..][0..entry.name.len], entry.name);
        spos += entry.name.len;
        const sub_dir = sub_dir_buf[0..spos];

        var pre_buf: [4096]u8 = undefined;
        const pre_path = concatStr(&pre_buf, sub_dir, "/preimage");
        var post_buf: [4096]u8 = undefined;
        const post_path = concatStr(&post_buf, sub_dir, "/postimage");

        if (isFile(pre_path) and isFile(post_path)) {
            var out: [256]u8 = undefined;
            const header = std.fmt.bufPrint(&out, "--- preimage ({s})\n+++ postimage\n", .{entry.name[0..8]}) catch continue;
            try stdout_file.writeAll(header);
            found = true;
        }
    }

    if (!found) {
        try stdout_file.writeAll("No rerere diff to show.\n");
    }
}

/// Garbage collect old rerere recordings.
pub fn gcRecordings(allocator: std.mem.Allocator, git_dir: []const u8) !void {
    // Read gc thresholds from config
    var config_path_buf: [4096]u8 = undefined;
    const config_path = concatStr(&config_path_buf, git_dir, "/config");
    var cfg = config_mod.Config.loadFile(allocator, config_path) catch {
        // Use defaults
        return gcWithThresholds(git_dir, DEFAULT_RESOLVED_EXPIRY, DEFAULT_UNRESOLVED_EXPIRY);
    };
    defer cfg.deinit();

    const resolved_expiry = parseExpiry(cfg.get("gc.rerereresolved")) orelse DEFAULT_RESOLVED_EXPIRY;
    const unresolved_expiry = parseExpiry(cfg.get("gc.rerereunresolved")) orelse DEFAULT_UNRESOLVED_EXPIRY;

    return gcWithThresholds(git_dir, resolved_expiry, unresolved_expiry);
}

fn gcWithThresholds(git_dir: []const u8, resolved_expiry: i64, unresolved_expiry: i64) !void {
    var cache_dir_buf: [4096]u8 = undefined;
    const cache_dir = concatStr(&cache_dir_buf, git_dir, "/rr-cache");

    var dir = std.fs.openDirAbsolute(cache_dir, .{ .iterate = true }) catch {
        try stdout_file.writeAll("No rerere cache to gc.\n");
        return;
    };
    defer dir.close();

    const now = std.time.timestamp();
    var removed: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len != types.OID_HEX_LEN) continue;

        var sub_dir_buf: [4096]u8 = undefined;
        var spos: usize = 0;
        @memcpy(sub_dir_buf[spos..][0..cache_dir.len], cache_dir);
        spos += cache_dir.len;
        sub_dir_buf[spos] = '/';
        spos += 1;
        @memcpy(sub_dir_buf[spos..][0..entry.name.len], entry.name);
        spos += entry.name.len;
        const sub_dir = sub_dir_buf[0..spos];

        var post_buf: [4096]u8 = undefined;
        const post_path = concatStr(&post_buf, sub_dir, "/postimage");
        const has_post = isFile(post_path);

        var pre_buf: [4096]u8 = undefined;
        const pre_path = concatStr(&pre_buf, sub_dir, "/preimage");

        // Get the modification time of the preimage
        const pre_file = std.fs.openFileAbsolute(pre_path, .{}) catch continue;
        const pre_stat = pre_file.stat() catch {
            pre_file.close();
            continue;
        };
        pre_file.close();

        const mtime: i64 = @intCast(@divTrunc(pre_stat.mtime, std.time.ns_per_s));
        const age = now - mtime;

        const expiry = if (has_post) resolved_expiry else unresolved_expiry;

        if (age > expiry) {
            // Remove the entry
            std.fs.deleteFileAbsolute(pre_path) catch {};
            std.fs.deleteFileAbsolute(post_path) catch {};
            std.fs.deleteDirAbsolute(sub_dir) catch {};
            removed += 1;
        }
    }

    var out_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&out_buf, "Removed {d} stale rerere recording(s).\n", .{removed}) catch "GC complete.\n";
    try stdout_file.writeAll(msg);
}

fn parseExpiry(value: ?[]const u8) ?i64 {
    const v = value orelse return null;
    const days = std.fmt.parseInt(i64, v, 10) catch return null;
    return days * 24 * 60 * 60;
}

/// Run the rerere command.
pub fn runRerere(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        try listRecordings(repo.git_dir);
        return;
    }

    const subcmd = args[0];

    if (std.mem.eql(u8, subcmd, "forget")) {
        if (args.len < 2) {
            try stderr_file.writeAll("usage: zig-git rerere forget <path>\n");
            std.process.exit(1);
        }
        forgetResolution(allocator, repo.git_dir, args[1]) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: {s}\n", .{@errorName(err)}) catch "error\n";
            try stderr_file.writeAll(msg);
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, subcmd, "diff")) {
        try showDiff(allocator, repo.git_dir);
    } else if (std.mem.eql(u8, subcmd, "gc")) {
        try gcRecordings(allocator, repo.git_dir);
    } else if (std.mem.eql(u8, subcmd, "status")) {
        try listRecordings(repo.git_dir);
    } else {
        try stderr_file.writeAll(rerere_usage);
        std.process.exit(1);
    }
}

const rerere_usage =
    \\usage: zig-git rerere [<command>]
    \\
    \\Commands:
    \\  (none)       Show current recordings
    \\  forget <path> Forget recorded resolution for a file
    \\  diff         Show diff between current and recorded resolution
    \\  gc           Clean old recordings
    \\  status       Show current recordings
    \\
;

// --- Helpers ---

fn hasConflictMarkers(content: []const u8) bool {
    return std.mem.indexOf(u8, content, CONFLICT_START) != null;
}

fn isFile(path: []const u8) bool {
    const f = std.fs.openFileAbsolute(path, .{}) catch return false;
    @constCast(&f).close();
    return true;
}

fn ensureDirPath(path: []const u8) void {
    // Create directories recursively
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            std.fs.makeDirAbsolute(path[0..i]) catch {};
        }
    }
    std.fs.makeDirAbsolute(path) catch {};
}

fn concatStr(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

test "hasConflictMarkers" {
    try std.testing.expect(hasConflictMarkers("<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\n"));
    try std.testing.expect(!hasConflictMarkers("no conflicts here\n"));
}

test "hashConflict deterministic" {
    const content = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\n";
    const h1 = try hashConflict(std.testing.allocator, content);
    const h2 = try hashConflict(std.testing.allocator, content);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "hashConflict normalized ordering" {
    const content1 = "<<<<<<< HEAD\naaa\n=======\nbbb\n>>>>>>> branch\n";
    const content2 = "<<<<<<< HEAD\nbbb\n=======\naaa\n>>>>>>> branch\n";
    const h1 = try hashConflict(std.testing.allocator, content1);
    const h2 = try hashConflict(std.testing.allocator, content2);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}
