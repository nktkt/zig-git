const std = @import("std");
const diff_mod = @import("diff.zig");

/// Statistics for a single file in a diff.
pub const FileStat = struct {
    path: []const u8,
    additions: usize,
    deletions: usize,
    is_binary: bool,
    is_rename: bool,
    old_path: ?[]const u8,
};

/// Accumulated diff statistics for a set of files.
pub const DiffStats = struct {
    allocator: std.mem.Allocator,
    files: std.array_list.Managed(FileStat),
    /// Owned copies of paths
    strings: std.array_list.Managed([]u8),

    pub fn init(allocator: std.mem.Allocator) DiffStats {
        return .{
            .allocator = allocator,
            .files = std.array_list.Managed(FileStat).init(allocator),
            .strings = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *DiffStats) void {
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit();
        self.files.deinit();
    }

    /// Add a file stat entry. Dupes the path string.
    pub fn addFile(self: *DiffStats, path: []const u8, additions: usize, deletions: usize, is_binary: bool) !void {
        const owned_path = try self.allocator.alloc(u8, path.len);
        @memcpy(owned_path, path);
        try self.strings.append(owned_path);

        try self.files.append(.{
            .path = owned_path,
            .additions = additions,
            .deletions = deletions,
            .is_binary = is_binary,
            .is_rename = false,
            .old_path = null,
        });
    }

    /// Add a file stat entry for a renamed file.
    pub fn addRename(self: *DiffStats, old_path: []const u8, new_path: []const u8, additions: usize, deletions: usize) !void {
        const owned_old = try self.allocator.alloc(u8, old_path.len);
        @memcpy(owned_old, old_path);
        try self.strings.append(owned_old);

        const owned_new = try self.allocator.alloc(u8, new_path.len);
        @memcpy(owned_new, new_path);
        try self.strings.append(owned_new);

        try self.files.append(.{
            .path = owned_new,
            .additions = additions,
            .deletions = deletions,
            .is_binary = false,
            .is_rename = true,
            .old_path = owned_old,
        });
    }

    /// Total additions across all files.
    pub fn totalAdditions(self: *const DiffStats) usize {
        var total: usize = 0;
        for (self.files.items) |f| {
            total += f.additions;
        }
        return total;
    }

    /// Total deletions across all files.
    pub fn totalDeletions(self: *const DiffStats) usize {
        var total: usize = 0;
        for (self.files.items) |f| {
            total += f.deletions;
        }
        return total;
    }

    /// Compute stats from diff hunks for a single file.
    pub fn computeFromHunks(hunks: []const diff_mod.DiffHunk) struct { additions: usize, deletions: usize } {
        var additions: usize = 0;
        var deletions: usize = 0;
        for (hunks) |*hunk| {
            for (hunk.lines.items) |*line| {
                switch (line.kind) {
                    .addition => additions += 1,
                    .deletion => deletions += 1,
                    .context => {},
                }
            }
        }
        return .{ .additions = additions, .deletions = deletions };
    }
};

/// Output mode for stat formatting.
pub const StatMode = enum {
    stat,
    shortstat,
    numstat,
    dirstat,
};

/// Format diff stats as `--stat` output and write to file.
pub fn formatDiffStat(
    allocator: std.mem.Allocator,
    stats: *const DiffStats,
    file: std.fs.File,
    max_width: usize,
) !void {
    if (stats.files.items.len == 0) return;

    const width = if (max_width > 0) max_width else 80;

    // Find the longest file path for alignment
    var max_path_len: usize = 0;
    var max_changes: usize = 0;
    for (stats.files.items) |*f| {
        const path_len = pathDisplayLen(f);
        if (path_len > max_path_len) max_path_len = path_len;
        const changes = f.additions + f.deletions;
        if (changes > max_changes) max_changes = changes;
    }

    // Limit path width to leave room for the bar graph
    // Layout: " path | N +++---"
    // Minimum: 3 (for " | ") + number_width + 1 (space) + some bar
    const num_width = digitCount(max_changes);
    const overhead = 3 + num_width + 1; // " | " + digits + space
    const min_bar_width: usize = 10;

    var path_col_width = max_path_len;
    if (path_col_width + overhead + min_bar_width > width) {
        if (width > overhead + min_bar_width) {
            path_col_width = width - overhead - min_bar_width;
        } else {
            path_col_width = 20;
        }
    }

    const bar_width = if (width > path_col_width + overhead) width - path_col_width - overhead else min_bar_width;

    // Compute scale factor for bar graph
    const scale: usize = if (max_changes > bar_width and bar_width > 0) max_changes / bar_width + 1 else 1;

    var buf: [4096]u8 = undefined;

    for (stats.files.items) |*f| {
        if (f.is_binary) {
            const line = formatBinaryStat(&buf, f, path_col_width);
            try file.writeAll(line);
            continue;
        }

        const changes = f.additions + f.deletions;
        const add_bars = if (scale > 0) f.additions / scale else 0;
        const del_bars = if (scale > 0) f.deletions / scale else 0;
        // Ensure at least 1 bar if there are changes
        const actual_add = if (f.additions > 0 and add_bars == 0) 1 else add_bars;
        const actual_del = if (f.deletions > 0 and del_bars == 0) 1 else del_bars;

        const line = formatFileStat(&buf, f, path_col_width, changes, actual_add, actual_del);
        try file.writeAll(line);
    }

    // Summary line
    const summary = formatSummary(allocator, stats) catch return;
    defer allocator.free(summary);
    try file.writeAll(summary);
}

/// Format a single file stat line.
fn formatFileStat(
    buf: []u8,
    f: *const FileStat,
    path_col_width: usize,
    changes: usize,
    add_bars: usize,
    del_bars: usize,
) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    // Write path (truncated or padded)
    writer.writeAll(" ") catch return "";
    const display_path = if (f.is_rename) blk: {
        if (f.old_path) |op| {
            writer.writeAll(op) catch return "";
            writer.writeAll(" => ") catch return "";
        }
        break :blk f.path;
    } else f.path;

    if (!f.is_rename) {
        const path_len = display_path.len;
        if (path_len <= path_col_width) {
            writer.writeAll(display_path) catch return "";
            // Pad with spaces
            var pad: usize = 0;
            while (pad < path_col_width - path_len) : (pad += 1) {
                writer.writeByte(' ') catch return "";
            }
        } else {
            // Truncate with "..."
            writer.writeAll("...") catch return "";
            const start = path_len - (path_col_width - 3);
            writer.writeAll(display_path[start..]) catch return "";
        }
    } else {
        writer.writeAll(display_path) catch return "";
    }

    writer.writeAll(" | ") catch return "";

    // Write change count
    writer.print("{d} ", .{changes}) catch return "";

    // Write bar graph
    var i: usize = 0;
    while (i < add_bars) : (i += 1) {
        writer.writeByte('+') catch return "";
    }
    i = 0;
    while (i < del_bars) : (i += 1) {
        writer.writeByte('-') catch return "";
    }

    writer.writeByte('\n') catch return "";

    return buf[0..stream.pos];
}

/// Format a binary file stat line.
fn formatBinaryStat(buf: []u8, f: *const FileStat, path_col_width: usize) []const u8 {
    _ = path_col_width;
    const result = std.fmt.bufPrint(buf, " {s} | Bin\n", .{f.path}) catch return "";
    return result;
}

/// Format the summary line.
fn formatSummary(allocator: std.mem.Allocator, stats: *const DiffStats) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var buf: [256]u8 = undefined;

    const num_files = stats.files.items.len;
    const total_add = stats.totalAdditions();
    const total_del = stats.totalDeletions();

    // " N file(s) changed"
    var line = std.fmt.bufPrint(&buf, " {d} file{s} changed", .{
        num_files,
        @as([]const u8, if (num_files != 1) "s" else ""),
    }) catch return error.OutOfMemory;
    try result.appendSlice(line);

    if (total_add > 0) {
        line = std.fmt.bufPrint(&buf, ", {d} insertion{s}(+)", .{
            total_add,
            @as([]const u8, if (total_add != 1) "s" else ""),
        }) catch return error.OutOfMemory;
        try result.appendSlice(line);
    }

    if (total_del > 0) {
        line = std.fmt.bufPrint(&buf, ", {d} deletion{s}(-)", .{
            total_del,
            @as([]const u8, if (total_del != 1) "s" else ""),
        }) catch return error.OutOfMemory;
        try result.appendSlice(line);
    }

    try result.append('\n');

    return result.toOwnedSlice();
}

/// Format `--shortstat` output: just the summary line.
pub fn formatShortStat(
    allocator: std.mem.Allocator,
    stats: *const DiffStats,
    file: std.fs.File,
) !void {
    if (stats.files.items.len == 0) return;
    const summary = try formatSummary(allocator, stats);
    defer allocator.free(summary);
    try file.writeAll(summary);
}

/// Format `--numstat` output: machine-readable ADD\tDEL\tFILE per line.
pub fn formatNumStat(
    stats: *const DiffStats,
    file: std.fs.File,
) !void {
    var buf: [4096]u8 = undefined;
    for (stats.files.items) |*f| {
        if (f.is_binary) {
            const line = std.fmt.bufPrint(&buf, "-\t-\t{s}\n", .{f.path}) catch continue;
            try file.writeAll(line);
        } else {
            const line = std.fmt.bufPrint(&buf, "{d}\t{d}\t{s}\n", .{ f.additions, f.deletions, f.path }) catch continue;
            try file.writeAll(line);
        }
    }
}

/// Format `--dirstat` output: show changed directories by percentage.
pub fn formatDirStat(
    allocator: std.mem.Allocator,
    stats: *const DiffStats,
    file: std.fs.File,
    threshold: usize,
) !void {
    if (stats.files.items.len == 0) return;

    // Aggregate changes by directory
    var dir_changes = std.StringHashMap(usize).init(allocator);
    defer dir_changes.deinit();

    var total_changes: usize = 0;
    for (stats.files.items) |*f| {
        const changes = f.additions + f.deletions;
        total_changes += changes;

        const dir = if (std.mem.lastIndexOfScalar(u8, f.path, '/')) |idx|
            f.path[0..idx]
        else
            ".";

        const existing = dir_changes.get(dir) orelse 0;
        dir_changes.put(dir, existing + changes) catch continue;
    }

    if (total_changes == 0) return;

    // Collect and sort by path
    var entries = std.array_list.Managed(DirEntry).init(allocator);
    defer entries.deinit();

    var iter = dir_changes.iterator();
    while (iter.next()) |kv| {
        const pct = (kv.value_ptr.* * 100) / total_changes;
        if (pct >= threshold) {
            try entries.append(.{
                .dir = kv.key_ptr.*,
                .pct = pct,
            });
        }
    }

    // Sort entries by directory path
    std.mem.sort(DirEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: DirEntry, b: DirEntry) bool {
            return std.mem.order(u8, a.dir, b.dir) == .lt;
        }
    }.lessThan);

    var buf: [4096]u8 = undefined;
    for (entries.items) |*entry| {
        const line = std.fmt.bufPrint(&buf, "{d:>5.1}% {s}/\n", .{
            entry.pct,
            entry.dir,
        }) catch continue;
        try file.writeAll(line);
    }
}

const DirEntry = struct {
    dir: []const u8,
    pct: usize,
};

/// Helper: compute the display length of a file path in the stat output.
fn pathDisplayLen(f: *const FileStat) usize {
    if (f.is_rename) {
        const old_len = if (f.old_path) |op| op.len + 4 else 0; // " => "
        return old_len + f.path.len;
    }
    return f.path.len;
}

/// Count the number of digits in a number.
fn digitCount(n: usize) usize {
    if (n == 0) return 1;
    var count: usize = 0;
    var val = n;
    while (val > 0) {
        val /= 10;
        count += 1;
    }
    return count;
}

/// Parse --stat[=<width>] argument. Returns the width or null if not a stat arg.
pub fn parseStatArg(arg: []const u8) ?usize {
    if (std.mem.eql(u8, arg, "--stat")) return 80;
    if (std.mem.startsWith(u8, arg, "--stat=")) {
        const val = arg["--stat=".len..];
        return std.fmt.parseInt(usize, val, 10) catch 80;
    }
    return null;
}

/// Check if arg is --shortstat.
pub fn isShortStat(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--shortstat");
}

/// Check if arg is --numstat.
pub fn isNumStat(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--numstat");
}

/// Check if arg is --dirstat.
pub fn isDirStat(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--dirstat") or std.mem.startsWith(u8, arg, "--dirstat=");
}

/// Parse --dirstat[=<threshold>] argument. Returns threshold percentage.
pub fn parseDirStatThreshold(arg: []const u8) usize {
    if (std.mem.startsWith(u8, arg, "--dirstat=")) {
        const val = arg["--dirstat=".len..];
        return std.fmt.parseInt(usize, val, 10) catch 3;
    }
    return 3; // default threshold
}

test "digitCount" {
    try std.testing.expectEqual(@as(usize, 1), digitCount(0));
    try std.testing.expectEqual(@as(usize, 1), digitCount(5));
    try std.testing.expectEqual(@as(usize, 2), digitCount(42));
    try std.testing.expectEqual(@as(usize, 3), digitCount(100));
}

test "parseStatArg" {
    try std.testing.expectEqual(@as(?usize, 80), parseStatArg("--stat"));
    try std.testing.expectEqual(@as(?usize, 120), parseStatArg("--stat=120"));
    try std.testing.expect(parseStatArg("--cached") == null);
}

test "DiffStats basic" {
    var stats = DiffStats.init(std.testing.allocator);
    defer stats.deinit();

    try stats.addFile("file1.txt", 5, 2, false);
    try stats.addFile("file2.txt", 3, 0, false);

    try std.testing.expectEqual(@as(usize, 2), stats.files.items.len);
    try std.testing.expectEqual(@as(usize, 8), stats.totalAdditions());
    try std.testing.expectEqual(@as(usize, 2), stats.totalDeletions());
}

test "formatSummary" {
    var stats = DiffStats.init(std.testing.allocator);
    defer stats.deinit();

    try stats.addFile("file1.txt", 5, 2, false);
    try stats.addFile("file2.txt", 3, 0, false);

    const summary = try formatSummary(std.testing.allocator, &stats);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "2 files changed") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "8 insertions(+)") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "2 deletions(-)") != null);
}
