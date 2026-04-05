const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const hash_mod = @import("hash.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const count_objects_usage =
    \\usage: zig-git count-objects [-v | --verbose] [-H | --human-readable]
    \\
    \\  -v, --verbose          Show detailed information
    \\  -H, --human-readable   Print sizes in human-readable format (e.g., 1.5 KiB)
    \\
;

/// Options for the count-objects command.
const CountObjectsOptions = struct {
    /// Show verbose output with detailed information.
    verbose: bool = false,
    /// Human-readable sizes.
    human_readable: bool = false,
};

/// Statistics collected about the object database.
const ObjectStats = struct {
    /// Number of loose objects.
    loose_count: usize = 0,
    /// Total size of loose objects in bytes.
    loose_size: u64 = 0,
    /// Number of pack files.
    pack_count: usize = 0,
    /// Number of objects in all packs.
    packed_objects: usize = 0,
    /// Total size of all pack files in bytes.
    pack_size: u64 = 0,
    /// Number of pack index files.
    pack_idx_count: usize = 0,
    /// Total size of all pack index files in bytes.
    pack_idx_size: u64 = 0,
    /// Number of garbage files (not recognized).
    garbage_count: usize = 0,
    /// Total size of garbage files in bytes.
    garbage_size: u64 = 0,
    /// Number of loose object directories (fan-out).
    loose_dirs: usize = 0,
    /// Number of alternates paths.
    alternates_count: usize = 0,
    /// Size of commit-graph if present.
    commit_graph_size: u64 = 0,
    /// Whether a commit-graph exists.
    has_commit_graph: bool = false,
    /// Number of bitmap files.
    bitmap_count: usize = 0,
    /// Total size of bitmap files.
    bitmap_size: u64 = 0,
};

/// Entry point for the count-objects command.
pub fn runCountObjects(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = CountObjectsOptions{};

    // Parse arguments
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--human-readable")) {
            opts.human_readable = true;
        } else if (std.mem.eql(u8, arg, "-vH") or std.mem.eql(u8, arg, "-Hv")) {
            opts.verbose = true;
            opts.human_readable = true;
        }
    }

    _ = allocator;

    // Collect statistics
    var stats = ObjectStats{};
    try collectLooseStats(repo.git_dir, &stats);
    try collectPackStats(repo.git_dir, &stats);
    try collectInfoStats(repo.git_dir, &stats);

    // Output results
    if (opts.verbose) {
        try printVerboseOutput(&stats, opts.human_readable);
    } else {
        try printBasicOutput(&stats, opts.human_readable);
    }
}

/// Count loose objects and their sizes by walking .git/objects/XX/ directories.
fn collectLooseStats(git_dir: []const u8, stats: *ObjectStats) !void {
    var objects_path_buf: [4096]u8 = undefined;
    const objects_path = buildPath(&objects_path_buf, git_dir, "/objects");

    var dir = std.fs.openDirAbsolute(objects_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Fan-out directories are 2 hex characters
        if (entry.name.len != 2) continue;

        // Validate hex characters
        if (!isHexChar(entry.name[0]) or !isHexChar(entry.name[1])) continue;

        stats.loose_dirs += 1;

        // Open the fan-out directory and count objects
        var fanout_path_buf: [4096]u8 = undefined;
        const fanout_path = buildPath2(&fanout_path_buf, objects_path, "/", entry.name);

        var fanout_dir = std.fs.openDirAbsolute(fanout_path, .{ .iterate = true }) catch continue;
        defer fanout_dir.close();

        var fanout_iter = fanout_dir.iterate();
        while (try fanout_iter.next()) |obj_entry| {
            if (obj_entry.kind != .file) continue;

            // Each file should be 38 hex characters (the remaining part of the SHA-1)
            if (obj_entry.name.len == types.OID_HEX_LEN - 2) {
                stats.loose_count += 1;

                // Get file size
                var obj_path_buf: [4096]u8 = undefined;
                const obj_path = buildPath2(&obj_path_buf, fanout_path, "/", obj_entry.name);

                const file = std.fs.openFileAbsolute(obj_path, .{}) catch continue;
                defer file.close();
                const stat = file.stat() catch continue;
                stats.loose_size += stat.size;
            }
        }
    }
}

/// Count pack files, their sizes, and the number of objects in each.
fn collectPackStats(git_dir: []const u8, stats: *ObjectStats) !void {
    var pack_path_buf: [4096]u8 = undefined;
    const pack_path = buildPath(&pack_path_buf, git_dir, "/objects/pack");

    var dir = std.fs.openDirAbsolute(pack_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        var file_path_buf: [4096]u8 = undefined;
        const file_path = buildPath2(&file_path_buf, pack_path, "/", entry.name);

        const file = std.fs.openFileAbsolute(file_path, .{}) catch continue;
        defer file.close();
        const stat = file.stat() catch continue;

        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            stats.pack_count += 1;
            stats.pack_size += stat.size;

            // Try to read the number of objects from the pack header
            var header: [12]u8 = undefined;
            const read = file.readAll(&header) catch 0;
            if (read >= 12 and std.mem.eql(u8, header[0..4], "PACK")) {
                const num_objects = std.mem.readInt(u32, header[8..12], .big);
                stats.packed_objects += num_objects;
            }
        } else if (std.mem.endsWith(u8, entry.name, ".idx")) {
            stats.pack_idx_count += 1;
            stats.pack_idx_size += stat.size;
        } else if (std.mem.endsWith(u8, entry.name, ".bitmap")) {
            stats.bitmap_count += 1;
            stats.bitmap_size += stat.size;
        } else if (std.mem.endsWith(u8, entry.name, ".keep") or
            std.mem.endsWith(u8, entry.name, ".rev") or
            std.mem.endsWith(u8, entry.name, ".mtimes"))
        {
            // Known ancillary files, not garbage
        } else {
            // Unknown file in pack directory
            stats.garbage_count += 1;
            stats.garbage_size += stat.size;
        }
    }
}

/// Check for commit-graph and other info directory contents.
fn collectInfoStats(git_dir: []const u8, stats: *ObjectStats) !void {
    // Check for commit-graph
    var cg_path_buf: [4096]u8 = undefined;
    const cg_path = buildPath(&cg_path_buf, git_dir, "/objects/info/commit-graph");

    const cg_file = std.fs.openFileAbsolute(cg_path, .{}) catch return;
    defer cg_file.close();
    const cg_stat = cg_file.stat() catch return;
    stats.has_commit_graph = true;
    stats.commit_graph_size = cg_stat.size;
}

/// Print basic output (non-verbose).
fn printBasicOutput(stats: *const ObjectStats, human_readable: bool) !void {
    var buf: [256]u8 = undefined;

    if (human_readable) {
        var size_buf: [32]u8 = undefined;
        const size_str = formatHumanSize(&size_buf, stats.loose_size);
        const msg = std.fmt.bufPrint(&buf, "{d} objects, {s}\n", .{ stats.loose_count, size_str }) catch return;
        try stdout_file.writeAll(msg);
    } else {
        // Size in KiB (like git)
        const size_kib = stats.loose_size / 1024;
        const msg = std.fmt.bufPrint(&buf, "{d} objects, {d} kilobytes\n", .{ stats.loose_count, size_kib }) catch return;
        try stdout_file.writeAll(msg);
    }
}

/// Print verbose output.
fn printVerboseOutput(stats: *const ObjectStats, human_readable: bool) !void {
    var buf: [512]u8 = undefined;
    var msg: []const u8 = undefined;

    // count: N
    msg = std.fmt.bufPrint(&buf, "count: {d}\n", .{stats.loose_count}) catch return;
    try stdout_file.writeAll(msg);

    // size: N (in KiB)
    if (human_readable) {
        var size_buf: [32]u8 = undefined;
        const size_str = formatHumanSize(&size_buf, stats.loose_size);
        msg = std.fmt.bufPrint(&buf, "size: {s}\n", .{size_str}) catch return;
    } else {
        const size_kib = stats.loose_size / 1024;
        msg = std.fmt.bufPrint(&buf, "size: {d}\n", .{size_kib}) catch return;
    }
    try stdout_file.writeAll(msg);

    // in-pack: N
    msg = std.fmt.bufPrint(&buf, "in-pack: {d}\n", .{stats.packed_objects}) catch return;
    try stdout_file.writeAll(msg);

    // packs: N
    msg = std.fmt.bufPrint(&buf, "packs: {d}\n", .{stats.pack_count}) catch return;
    try stdout_file.writeAll(msg);

    // size-pack: N (in KiB)
    if (human_readable) {
        var size_buf: [32]u8 = undefined;
        const size_str = formatHumanSize(&size_buf, stats.pack_size);
        msg = std.fmt.bufPrint(&buf, "size-pack: {s}\n", .{size_str}) catch return;
    } else {
        const size_kib = stats.pack_size / 1024;
        msg = std.fmt.bufPrint(&buf, "size-pack: {d}\n", .{size_kib}) catch return;
    }
    try stdout_file.writeAll(msg);

    // prune-packable: 0 (we don't track this yet)
    msg = std.fmt.bufPrint(&buf, "prune-packable: 0\n", .{}) catch return;
    try stdout_file.writeAll(msg);

    // garbage: N
    msg = std.fmt.bufPrint(&buf, "garbage: {d}\n", .{stats.garbage_count}) catch return;
    try stdout_file.writeAll(msg);

    // size-garbage: N (in KiB)
    if (human_readable) {
        var size_buf: [32]u8 = undefined;
        const size_str = formatHumanSize(&size_buf, stats.garbage_size);
        msg = std.fmt.bufPrint(&buf, "size-garbage: {s}\n", .{size_str}) catch return;
    } else {
        const size_kib = stats.garbage_size / 1024;
        msg = std.fmt.bufPrint(&buf, "size-garbage: {d}\n", .{size_kib}) catch return;
    }
    try stdout_file.writeAll(msg);

    // commit-graph info
    if (stats.has_commit_graph) {
        msg = std.fmt.bufPrint(&buf, "commit-graph: yes\n", .{}) catch return;
        try stdout_file.writeAll(msg);

        if (human_readable) {
            var size_buf: [32]u8 = undefined;
            const size_str = formatHumanSize(&size_buf, stats.commit_graph_size);
            msg = std.fmt.bufPrint(&buf, "commit-graph-size: {s}\n", .{size_str}) catch return;
        } else {
            const size_kib = stats.commit_graph_size / 1024;
            msg = std.fmt.bufPrint(&buf, "commit-graph-size: {d}\n", .{size_kib}) catch return;
        }
        try stdout_file.writeAll(msg);
    }

    // bitmap info
    if (stats.bitmap_count > 0) {
        msg = std.fmt.bufPrint(&buf, "bitmap-count: {d}\n", .{stats.bitmap_count}) catch return;
        try stdout_file.writeAll(msg);
    }
}

/// Format a byte count in human-readable form.
fn formatHumanSize(buf: []u8, bytes: u64) []const u8 {
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch "0 bytes";
    } else if (bytes < 1024 * 1024) {
        const kib = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return std.fmt.bufPrint(buf, "{d:.1} KiB", .{kib}) catch "0 KiB";
    } else if (bytes < 1024 * 1024 * 1024) {
        const mib = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1} MiB", .{mib}) catch "0 MiB";
    } else {
        const gib = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1} GiB", .{gib}) catch "0 GiB";
    }
}

/// Check if a character is a valid hexadecimal digit.
fn isHexChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

// ── Utility functions ──────────────────────────────────────────────────────

fn buildPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn buildPath2(buf: []u8, a: []const u8, sep: []const u8, b: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..a.len], a);
    pos += a.len;
    @memcpy(buf[pos..][0..sep.len], sep);
    pos += sep.len;
    @memcpy(buf[pos..][0..b.len], b);
    pos += b.len;
    return buf[0..pos];
}

test "isHexChar" {
    try std.testing.expect(isHexChar('0'));
    try std.testing.expect(isHexChar('9'));
    try std.testing.expect(isHexChar('a'));
    try std.testing.expect(isHexChar('f'));
    try std.testing.expect(isHexChar('A'));
    try std.testing.expect(isHexChar('F'));
    try std.testing.expect(!isHexChar('g'));
    try std.testing.expect(!isHexChar('z'));
    try std.testing.expect(!isHexChar('/'));
}

test "formatHumanSize" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 bytes", formatHumanSize(&buf, 512));
    // KiB range
    const kib_result = formatHumanSize(&buf, 2048);
    try std.testing.expect(kib_result.len > 0);
}
