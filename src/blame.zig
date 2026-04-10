const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_diff = @import("tree_diff.zig");
const log_mod = @import("log.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

// ANSI color codes
const COLOR_YELLOW = "\x1b[33m";
const COLOR_CYAN = "\x1b[36m";
const COLOR_GREEN = "\x1b[32m";
const COLOR_RESET = "\x1b[0m";

/// Options for the blame command.
pub const BlameOptions = struct {
    file_path: ?[]const u8 = null,
    line_start: usize = 0, // 0 means from beginning
    line_end: usize = 0, // 0 means to end
    commit_ref: []const u8 = "HEAD",
    show_email: bool = false,
    color: bool = true,
};

/// A blame entry: information about who last changed a line.
pub const BlameEntry = struct {
    commit_oid: types.ObjectId,
    author_name: []const u8,
    author_time: i64,
    author_tz: []const u8,
    line_number: usize,
    content: []const u8,
    /// Whether this line was found in a commit (vs attributed to the working copy).
    is_committed: bool,
};

/// Parsed summary for a commit.
const CommitSummary = struct {
    oid: types.ObjectId,
    author_name: []const u8,
    author_time: i64,
    author_tz: []const u8,
    tree_oid: types.ObjectId,
    parent_oid: ?types.ObjectId,
    raw_data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CommitSummary) void {
        self.allocator.free(self.raw_data);
    }
};

/// Result of running blame on a file.
pub const BlameResult = struct {
    entries: std.array_list.Managed(BlameEntry),
    /// Pool of owned strings.
    strings: std.array_list.Managed([]u8),

    pub fn deinit(self: *BlameResult) void {
        self.entries.deinit();
        for (self.strings.items) |s| {
            self.entries.allocator.free(s);
        }
        self.strings.deinit();
    }
};

/// Entry point for the blame command.
pub fn runBlame(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = BlameOptions{};

    // Parse arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--show-email")) {
            opts.show_email = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.color = false;
        } else if (std.mem.startsWith(u8, arg, "-L")) {
            // Parse line range: -L start,end
            const range_str = if (arg.len > 2)
                arg[2..]
            else blk: {
                i += 1;
                if (i >= args.len) {
                    try stderr_file.writeAll("fatal: -L requires a range argument\n");
                    std.process.exit(1);
                }
                break :blk args[i];
            };
            parseLineRange(range_str, &opts.line_start, &opts.line_end);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (opts.file_path == null) {
                opts.file_path = arg;
            } else {
                // Could be a commit ref
                opts.commit_ref = arg;
            }
        }
    }

    if (opts.file_path == null) {
        try stderr_file.writeAll("fatal: no file specified\n");
        try stderr_file.writeAll("usage: zig-git blame [-L <range>] [<rev>] <file>\n");
        std.process.exit(1);
    }

    // Resolve the starting commit
    const head_oid = repo.resolveRef(allocator, opts.commit_ref) catch {
        try stderr_file.writeAll("fatal: no such ref\n");
        std.process.exit(128);
    };

    // Run blame
    var result = computeBlame(allocator, repo, &head_oid, opts.file_path.?) catch |err| {
        switch (err) {
            error.ObjectNotFound => {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: no such path '{s}' in HEAD\n", .{opts.file_path.?}) catch
                    "fatal: no such path\n";
                try stderr_file.writeAll(msg);
                std.process.exit(128);
            },
            else => return err,
        }
    };
    defer result.deinit();

    // Output the blame results
    try outputBlame(allocator, &result, &opts);
}

/// Parse a line range string like "10,20" or "10" or ",20".
fn parseLineRange(range_str: []const u8, start: *usize, end: *usize) void {
    const comma = std.mem.indexOfScalar(u8, range_str, ',');
    if (comma) |cp| {
        if (cp > 0) {
            start.* = std.fmt.parseInt(usize, range_str[0..cp], 10) catch 0;
        }
        if (cp + 1 < range_str.len) {
            end.* = std.fmt.parseInt(usize, range_str[cp + 1 ..], 10) catch 0;
        }
    } else {
        start.* = std.fmt.parseInt(usize, range_str, 10) catch 0;
        end.* = start.*;
    }
}

/// Compute blame for a file by walking history.
fn computeBlame(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    start_oid: *const types.ObjectId,
    file_path: []const u8,
) !BlameResult {
    var result = BlameResult{
        .entries = std.array_list.Managed(BlameEntry).init(allocator),
        .strings = std.array_list.Managed([]u8).init(allocator),
    };
    errdefer result.deinit();

    // Get the current file content at the starting commit
    // current_lines.data ownership transfers to result.strings (BlameEntry.content
    // holds slices into it, so it must outlive the entries)
    const current_lines = try getFileLines(allocator, repo, start_oid, file_path);
    try result.strings.append(current_lines.data);
    defer allocator.free(current_lines.lines);

    if (current_lines.lines.len == 0) return result;

    // Initialize: all lines are unblamed
    const num_lines = current_lines.lines.len;
    var blamed = try allocator.alloc(bool, num_lines);
    defer allocator.free(blamed);
    @memset(blamed, false);

    var blame_commits = try allocator.alloc(?types.ObjectId, num_lines);
    defer allocator.free(blame_commits);
    @memset(blame_commits, null);

    var blame_authors = try allocator.alloc([]const u8, num_lines);
    defer allocator.free(blame_authors);
    @memset(blame_authors, "");

    var blame_times = try allocator.alloc(i64, num_lines);
    defer allocator.free(blame_times);
    @memset(blame_times, 0);

    var blame_tzs = try allocator.alloc([]const u8, num_lines);
    defer allocator.free(blame_tzs);
    @memset(blame_tzs, "+0000");

    // Walk commit history
    var current_oid = start_oid.*;
    var iterations: usize = 0;
    const max_iterations: usize = 1000;

    while (iterations < max_iterations) {
        iterations += 1;

        // Parse the current commit
        var commit = parseCommitSummary(allocator, repo, &current_oid) catch break;
        defer commit.deinit();

        // Get the file at the current commit
        const current_file = getFileBlobOid(allocator, repo, &commit.tree_oid, file_path) catch break;

        if (commit.parent_oid == null) {
            // This is the root commit: all remaining unblamed lines belong here
            for (0..num_lines) |line_idx| {
                if (!blamed[line_idx]) {
                    blamed[line_idx] = true;
                    blame_commits[line_idx] = current_oid;
                    const name_copy = try dupeString(allocator, commit.author_name);
                    try result.strings.append(name_copy);
                    blame_authors[line_idx] = name_copy;
                    blame_times[line_idx] = commit.author_time;
                    const tz_copy = try dupeString(allocator, commit.author_tz);
                    try result.strings.append(tz_copy);
                    blame_tzs[line_idx] = tz_copy;
                }
            }
            break;
        }

        // Get the parent commit's tree
        var parent_commit = parseCommitSummary(allocator, repo, &commit.parent_oid.?) catch break;
        defer parent_commit.deinit();

        const parent_blob_oid = getFileBlobOid(allocator, repo, &parent_commit.tree_oid, file_path) catch {
            // File didn't exist in parent: all remaining lines added in this commit
            for (0..num_lines) |line_idx| {
                if (!blamed[line_idx]) {
                    blamed[line_idx] = true;
                    blame_commits[line_idx] = current_oid;
                    const name_copy = try dupeString(allocator, commit.author_name);
                    try result.strings.append(name_copy);
                    blame_authors[line_idx] = name_copy;
                    blame_times[line_idx] = commit.author_time;
                    const tz_copy = try dupeString(allocator, commit.author_tz);
                    try result.strings.append(tz_copy);
                    blame_tzs[line_idx] = tz_copy;
                }
            }
            break;
        };

        // If the file blob is the same in parent, skip this commit
        if (current_file.eql(&parent_blob_oid)) {
            current_oid = commit.parent_oid.?;
            continue;
        }

        // File changed: diff the two versions to find which lines changed
        const parent_lines = getFileLines(allocator, repo, &commit.parent_oid.?, file_path) catch break;
        defer allocator.free(parent_lines.data);
        defer allocator.free(parent_lines.lines);

        // Find lines in current that don't appear in parent (simple diff)
        // Use a LCS-based approach
        const lcs_map = try computeLineMapping(allocator, current_lines.lines, parent_lines.lines);
        defer allocator.free(lcs_map);

        // Lines that don't map to any parent line were added in this commit
        for (lcs_map, 0..) |mapped, line_idx| {
            if (!blamed[line_idx] and mapped == null) {
                // This line was added in the current commit
                blamed[line_idx] = true;
                blame_commits[line_idx] = current_oid;
                const name_copy = try dupeString(allocator, commit.author_name);
                try result.strings.append(name_copy);
                blame_authors[line_idx] = name_copy;
                blame_times[line_idx] = commit.author_time;
                const tz_copy = try dupeString(allocator, commit.author_tz);
                try result.strings.append(tz_copy);
                blame_tzs[line_idx] = tz_copy;
            }
        }

        // Check if all lines are blamed
        var all_blamed = true;
        for (blamed) |b| {
            if (!b) {
                all_blamed = false;
                break;
            }
        }
        if (all_blamed) break;

        current_oid = commit.parent_oid.?;
    }

    // Build the result entries
    for (0..num_lines) |line_idx| {
        const commit_oid = blame_commits[line_idx] orelse start_oid.*;
        try result.entries.append(.{
            .commit_oid = commit_oid,
            .author_name = blame_authors[line_idx],
            .author_time = blame_times[line_idx],
            .author_tz = blame_tzs[line_idx],
            .line_number = line_idx + 1,
            .content = current_lines.lines[line_idx],
            .is_committed = blamed[line_idx],
        });
    }

    return result;
}

/// Compute a mapping from new lines to old lines using a simplified LCS approach.
/// Returns an array of optional indices: for each line in `new`, the corresponding
/// line index in `old`, or null if the line is new.
fn computeLineMapping(
    allocator: std.mem.Allocator,
    new_lines: []const []const u8,
    old_lines: []const []const u8,
) ![]?usize {
    const n = new_lines.len;
    const m = old_lines.len;

    var mapping = try allocator.alloc(?usize, n);
    @memset(mapping, null);

    if (n == 0 or m == 0) return mapping;

    // Simple greedy matching: for each new line, find the first unmatched old line
    // that has the same content. This is O(n*m) but sufficient for blame.
    var old_used = try allocator.alloc(bool, m);
    defer allocator.free(old_used);
    @memset(old_used, false);

    // First pass: match lines that are identical
    // Use a two-pointer approach for efficiency with sorted-like sequences
    var old_idx: usize = 0;
    for (new_lines, 0..) |new_line, ni| {
        // Try to find a match starting from around old_idx
        var search_start: usize = 0;
        if (old_idx > 0 and old_idx < m) {
            // Prioritize looking near the expected position
            search_start = old_idx;
        }

        // Search forward from expected position
        var oi = search_start;
        var found = false;
        while (oi < m) : (oi += 1) {
            if (!old_used[oi] and std.mem.eql(u8, old_lines[oi], new_line)) {
                mapping[ni] = oi;
                old_used[oi] = true;
                old_idx = oi + 1;
                found = true;
                break;
            }
        }

        // If not found after expected, search from beginning
        if (!found and search_start > 0) {
            oi = 0;
            while (oi < search_start) : (oi += 1) {
                if (!old_used[oi] and std.mem.eql(u8, old_lines[oi], new_line)) {
                    mapping[ni] = oi;
                    old_used[oi] = true;
                    found = true;
                    break;
                }
            }
        }
    }

    return mapping;
}

/// File lines result.
const FileLines = struct {
    data: []u8,
    lines: [][]const u8,
};

/// Get the lines of a file at a specific commit.
fn getFileLines(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    commit_oid: *const types.ObjectId,
    file_path: []const u8,
) !FileLines {
    // Read the commit
    var commit_obj = try repo.readObject(allocator, commit_oid);
    defer commit_obj.deinit();

    if (commit_obj.obj_type != .commit) return error.NotACommit;

    const tree_oid = try tree_diff.getCommitTreeOid(commit_obj.data);
    const blob_oid = try getFileBlobOid(allocator, repo, &tree_oid, file_path);

    var blob_obj = try repo.readObject(allocator, &blob_oid);
    // Don't defer deinit - we transfer ownership of data

    if (blob_obj.obj_type != .blob) {
        blob_obj.deinit();
        return error.NotABlob;
    }

    const data = blob_obj.data;

    // Split into lines
    var line_list = std.array_list.Managed([]const u8).init(allocator);
    defer line_list.deinit();

    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        try line_list.append(line);
    }

    // Remove trailing empty line if present (from trailing newline)
    if (line_list.items.len > 0 and line_list.items[line_list.items.len - 1].len == 0) {
        _ = line_list.pop();
    }

    const lines = try line_list.toOwnedSlice();

    return .{ .data = data, .lines = lines };
}

/// Walk a tree to find the blob OID of a specific file path.
fn getFileBlobOid(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    tree_oid: *const types.ObjectId,
    file_path: []const u8,
) !types.ObjectId {
    // Split path into components
    var current_tree_oid = tree_oid.*;

    var remaining = file_path;

    while (remaining.len > 0) {
        const slash_pos = std.mem.indexOfScalar(u8, remaining, '/');
        const component = if (slash_pos) |sp| remaining[0..sp] else remaining;
        const rest = if (slash_pos) |sp| remaining[sp + 1 ..] else "";

        // Read the tree and find the entry
        var tree_obj = try repo.readObject(allocator, &current_tree_oid);
        defer tree_obj.deinit();

        if (tree_obj.obj_type != .tree) return error.NotATree;

        const entry_oid = findTreeEntry(tree_obj.data, component) orelse return error.ObjectNotFound;

        if (rest.len == 0) {
            // This is the final component
            return entry_oid;
        }

        // Continue into subtree
        current_tree_oid = entry_oid;
        remaining = rest;
    }

    return error.ObjectNotFound;
}

/// Find an entry in a tree object by name and return its OID.
fn findTreeEntry(tree_data: []const u8, name: []const u8) ?types.ObjectId {
    var pos: usize = 0;

    while (pos < tree_data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, tree_data, pos, ' ') orelse return null;
        const null_pos = std.mem.indexOfScalarPos(u8, tree_data, space_pos + 1, 0) orelse return null;
        const entry_name = tree_data[space_pos + 1 .. null_pos];

        if (null_pos + 1 + types.OID_RAW_LEN > tree_data.len) return null;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, tree_data[null_pos + 1 ..][0..types.OID_RAW_LEN]);
        pos = null_pos + 1 + types.OID_RAW_LEN;

        if (std.mem.eql(u8, entry_name, name)) {
            return oid;
        }
    }

    return null;
}

/// Parse a commit object into a summary.
fn parseCommitSummary(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    oid: *const types.ObjectId,
) !CommitSummary {
    var obj = try repo.readObject(allocator, oid);
    // Transfer ownership of data
    if (obj.obj_type != .commit) {
        obj.deinit();
        return error.NotACommit;
    }

    const data = obj.data;

    var summary = CommitSummary{
        .oid = oid.*,
        .author_name = "",
        .author_time = 0,
        .author_tz = "+0000",
        .tree_oid = types.ObjectId.ZERO,
        .parent_oid = null,
        .raw_data = data,
        .allocator = allocator,
    };

    // Parse headers
    var pos: usize = 0;
    while (pos < data.len) {
        const line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        const line = data[pos..line_end];
        pos = line_end + 1;

        if (line.len == 0) break;

        if (std.mem.startsWith(u8, line, "tree ")) {
            if (line.len >= 5 + types.OID_HEX_LEN) {
                summary.tree_oid = types.ObjectId.fromHex(line[5..][0..types.OID_HEX_LEN]) catch types.ObjectId.ZERO;
            }
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            if (line.len >= 7 + types.OID_HEX_LEN and summary.parent_oid == null) {
                summary.parent_oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch null;
            }
        } else if (std.mem.startsWith(u8, line, "author ")) {
            parseAuthorInfo(line[7..], &summary.author_name, &summary.author_time, &summary.author_tz);
        }
    }

    return summary;
}

/// Parse author info from a line: "Name <email> timestamp tz"
fn parseAuthorInfo(line: []const u8, name: *[]const u8, timestamp: *i64, tz: *[]const u8) void {
    const lt_pos = std.mem.indexOfScalar(u8, line, '<') orelse return;
    const gt_pos = std.mem.indexOfScalar(u8, line, '>') orelse return;

    if (lt_pos > 1) {
        name.* = std.mem.trimRight(u8, line[0 .. lt_pos - 1], " ");
    }

    if (gt_pos + 2 < line.len) {
        const after = line[gt_pos + 2 ..];
        const space_pos = std.mem.indexOfScalar(u8, after, ' ');
        if (space_pos) |sp| {
            timestamp.* = std.fmt.parseInt(i64, after[0..sp], 10) catch 0;
            if (sp + 1 < after.len) {
                tz.* = after[sp + 1 ..];
            }
        } else {
            timestamp.* = std.fmt.parseInt(i64, after, 10) catch 0;
        }
    }
}

/// Output blame results.
fn outputBlame(
    allocator: std.mem.Allocator,
    result: *const BlameResult,
    opts: *const BlameOptions,
) !void {
    _ = allocator;

    // Calculate column widths
    var max_author_len: usize = 1;
    for (result.entries.items) |*entry| {
        if (entry.author_name.len > max_author_len) {
            max_author_len = entry.author_name.len;
        }
    }
    // Cap at a reasonable width
    if (max_author_len > 30) max_author_len = 30;

    // Calculate max line number width
    const total_lines = result.entries.items.len;
    var line_num_width: usize = 1;
    {
        var n = total_lines;
        while (n >= 10) {
            n /= 10;
            line_num_width += 1;
        }
    }

    for (result.entries.items) |*entry| {
        // Apply line range filter
        if (opts.line_start > 0 and entry.line_number < opts.line_start) continue;
        if (opts.line_end > 0 and entry.line_number > opts.line_end) continue;

        try outputBlameLine(entry, opts, max_author_len, line_num_width);
    }
}

/// Output a single blame line.
fn outputBlameLine(
    entry: *const BlameEntry,
    opts: *const BlameOptions,
    max_author_len: usize,
    line_num_width: usize,
) !void {
    // Short SHA
    const hex = entry.commit_oid.toHex();
    if (opts.color) {
        try stdout_file.writeAll(COLOR_YELLOW);
    }
    try stdout_file.writeAll(hex[0..8]);
    if (opts.color) {
        try stdout_file.writeAll(COLOR_RESET);
    }
    try stdout_file.writeAll(" ");

    // Author name (padded)
    try stdout_file.writeAll("(");
    if (opts.color) {
        try stdout_file.writeAll(COLOR_GREEN);
    }

    const name_display = if (entry.author_name.len > max_author_len)
        entry.author_name[0..max_author_len]
    else
        entry.author_name;

    try stdout_file.writeAll(name_display);

    // Pad
    var padding = max_author_len - name_display.len;
    while (padding > 0) : (padding -= 1) {
        try stdout_file.writeAll(" ");
    }

    if (opts.color) {
        try stdout_file.writeAll(COLOR_RESET);
    }

    try stdout_file.writeAll(" ");

    // Date
    if (opts.color) {
        try stdout_file.writeAll(COLOR_CYAN);
    }
    const date_str = formatTimestamp(entry.author_time);
    try stdout_file.writeAll(&date_str);
    if (opts.color) {
        try stdout_file.writeAll(COLOR_RESET);
    }

    try stdout_file.writeAll(" ");

    // Line number (right-aligned)
    {
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{entry.line_number}) catch "?";
        var lpad = if (line_num_width > num_str.len) line_num_width - num_str.len else 0;
        while (lpad > 0) : (lpad -= 1) {
            try stdout_file.writeAll(" ");
        }
        try stdout_file.writeAll(num_str);
    }

    try stdout_file.writeAll(") ");

    // Content — written directly, no buffer size limit
    try stdout_file.writeAll(entry.content);
    try stdout_file.writeAll("\n");
}

/// Format a Unix timestamp into YYYY-MM-DD format, returned as a fixed buffer.
fn formatTimestamp(timestamp: i64) [10]u8 {
    if (timestamp <= 0) {
        return "0000-00-00".*;
    }

    // Simple date calculation from epoch
    const secs: u64 = @intCast(timestamp);
    const days = secs / 86400;

    // Algorithm to convert days since epoch to year-month-day
    var y: u64 = 1970;
    var remaining_days = days;

    while (true) {
        const year_days: u64 = if (isLeapYear(y)) 366 else 365;
        if (remaining_days < year_days) break;
        remaining_days -= year_days;
        y += 1;
    }

    const month_days_normal = [_]u64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const month_days_leap = [_]u64{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const month_days = if (isLeapYear(y)) &month_days_leap else &month_days_normal;

    var m: u64 = 0;
    while (m < 12) : (m += 1) {
        if (remaining_days < month_days[m]) break;
        remaining_days -= month_days[m];
    }

    const day = remaining_days + 1;
    const month = m + 1;

    var buf: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ y, month, day }) catch {
        return "0000-00-00".*;
    };
    return buf;
}

fn isLeapYear(year: u64) bool {
    if (year % 400 == 0) return true;
    if (year % 100 == 0) return false;
    if (year % 4 == 0) return true;
    return false;
}

fn dupeString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const copy = try allocator.alloc(u8, s.len);
    @memcpy(copy, s);
    return copy;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseLineRange comma" {
    var start: usize = 0;
    var end: usize = 0;
    parseLineRange("10,20", &start, &end);
    try std.testing.expectEqual(@as(usize, 10), start);
    try std.testing.expectEqual(@as(usize, 20), end);
}

test "parseLineRange single" {
    var start: usize = 0;
    var end: usize = 0;
    parseLineRange("5", &start, &end);
    try std.testing.expectEqual(@as(usize, 5), start);
    try std.testing.expectEqual(@as(usize, 5), end);
}

test "formatTimestamp" {
    const result = formatTimestamp(1609459200); // 2021-01-01 00:00:00 UTC
    try std.testing.expectEqualStrings("2021-01-01", &result);
}

test "isLeapYear" {
    try std.testing.expect(isLeapYear(2000));
    try std.testing.expect(!isLeapYear(1900));
    try std.testing.expect(isLeapYear(2024));
    try std.testing.expect(!isLeapYear(2023));
}

test "findTreeEntry null" {
    const result = findTreeEntry("", "foo");
    try std.testing.expect(result == null);
}

test "computeLineMapping empty" {
    const allocator = std.testing.allocator;
    const new_lines = [_][]const u8{};
    const old_lines = [_][]const u8{};
    const mapping = try computeLineMapping(allocator, &new_lines, &old_lines);
    defer allocator.free(mapping);
    try std.testing.expectEqual(@as(usize, 0), mapping.len);
}
