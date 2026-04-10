const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_diff = @import("tree_diff.zig");
const diff_mod = @import("diff.zig");
const ref_mod = @import("ref.zig");

/// Format for log output.
pub const LogFormat = enum {
    /// Full format: commit hash, author, date, message
    full,
    /// One-line: short hash + first line of message
    oneline,
};

/// Options for the log command.
pub const LogOptions = struct {
    /// Maximum number of commits to show (0 = unlimited)
    max_count: usize = 0,
    /// Output format
    format: LogFormat = .full,
    /// Whether to show ASCII graph
    graph: bool = false,
    /// Starting ref (default: HEAD)
    start_ref: []const u8 = "HEAD",
    /// Walk commits from ALL refs (branches + tags)
    all: bool = false,
    /// Show branch/tag decorations
    decorate: bool = true,
    /// Follow only first parent (useful for mainline history)
    first_parent: bool = false,
    /// Show patch (diff) for each commit
    patch: bool = false,
};

/// Parsed commit information.
pub const CommitInfo = struct {
    oid: types.ObjectId,
    tree_oid: types.ObjectId,
    parents: std.array_list.Managed(types.ObjectId),
    author_name: []const u8,
    author_email: []const u8,
    author_timestamp: i64,
    author_timezone: []const u8,
    committer_name: []const u8,
    committer_email: []const u8,
    committer_timestamp: i64,
    committer_timezone: []const u8,
    message: []const u8,
    /// Backing data for all string slices.
    raw_data: []u8,

    pub fn deinit(self: *CommitInfo) void {
        self.parents.deinit();
        self.parents.allocator.free(self.raw_data);
    }
};

// ANSI color codes
const COLOR_YELLOW = "\x1b[33m";
const COLOR_BOLD = "\x1b[1m";
const COLOR_RESET = "\x1b[0m";
const COLOR_GREEN = "\x1b[32m";
const COLOR_CYAN = "\x1b[36m";

/// Run the log command and write output to stdout.
pub fn runLog(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    opts: LogOptions,
    stdout: std.fs.File,
) !void {
    // Build decoration map for --decorate
    var deco_map: ?DecoMap = null;
    defer if (deco_map) |*dm| dm.deinit();

    if (opts.decorate) {
        deco_map = buildDecoMap(allocator, repo) catch null;
    }

    // Walk commit history
    var walker = CommitWalker.init(allocator, repo);
    defer walker.deinit();
    walker.first_parent = opts.first_parent;

    if (opts.all) {
        // Push all refs (branches + tags)
        pushAllRefs(allocator, repo, &walker) catch {};
    } else {
        // Resolve starting commit
        const start_oid = repo.resolveRef(allocator, opts.start_ref) catch |err| {
            switch (err) {
                error.ObjectNotFound => return, // Empty repo, no commits
                else => return err,
            }
        };
        try walker.push(start_oid);
    }

    // For graph mode with merge commits, track parent info
    var count: usize = 0;
    var prev_was_merge = false;
    var prev_at_merge_second = false;

    while (try walker.next()) |oid| {
        if (opts.max_count > 0 and count >= opts.max_count) break;

        var commit = parseCommit(allocator, repo, &oid) catch continue;
        defer commit.deinit();

        const deco_str = if (deco_map) |*dm| dm.getDecoString(&oid) else null;
        const is_merge = commit.parents.items.len > 1;

        switch (opts.format) {
            .full => try writeFullFormat(stdout, &commit, opts.graph, count, deco_str, is_merge, prev_was_merge, prev_at_merge_second),
            .oneline => try writeOnelineFormat(stdout, &commit, opts.graph, deco_str, is_merge, prev_was_merge, prev_at_merge_second),
        }

        // Show patch if requested
        if (opts.patch) {
            try writeCommitDiff(repo, allocator, &commit, stdout);
        }

        prev_at_merge_second = prev_was_merge;
        prev_was_merge = is_merge;
        count += 1;
    }
}

/// Push all branch and tag refs into the walker.
fn pushAllRefs(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    walker: *CommitWalker,
) !void {
    // Branches
    const branches = ref_mod.listRefs(allocator, repo.git_dir, "refs/heads/") catch &[_]ref_mod.RefEntry{};
    defer ref_mod.freeRefEntries(allocator, @constCast(branches));

    for (branches) |entry| {
        try walker.push(entry.oid);
    }

    // Tags
    const tags = ref_mod.listRefs(allocator, repo.git_dir, "refs/tags/") catch &[_]ref_mod.RefEntry{};
    defer ref_mod.freeRefEntries(allocator, @constCast(tags));

    for (tags) |entry| {
        try walker.push(entry.oid);
    }
}

/// Decoration map for showing branch/tag names next to commits.
const DecoMap = struct {
    allocator: std.mem.Allocator,
    entries: std.array_list.Managed(DecoEntry),

    const DecoEntry = struct {
        oid_hex: [types.OID_HEX_LEN]u8,
        name: []u8,
    };

    fn init(alloc: std.mem.Allocator) DecoMap {
        return .{
            .allocator = alloc,
            .entries = std.array_list.Managed(DecoEntry).init(alloc),
        };
    }

    fn deinit(self: *DecoMap) void {
        for (self.entries.items) |*e| {
            self.allocator.free(e.name);
        }
        self.entries.deinit();
    }

    fn addEntry(self: *DecoMap, oid: *const types.ObjectId, name: []const u8) !void {
        const owned = try self.allocator.alloc(u8, name.len);
        @memcpy(owned, name);
        try self.entries.append(.{ .oid_hex = oid.toHex(), .name = owned });
    }

    fn getDecoString(self: *DecoMap, oid: *const types.ObjectId) ?[]const u8 {
        const hex = oid.toHex();
        // Build a combined string of all matching decorations
        var found = false;
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, &e.oid_hex, &hex)) {
                found = true;
                break;
            }
        }
        if (!found) return null;

        // Return first match name for simplicity
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, &e.oid_hex, &hex)) {
                return e.name;
            }
        }
        return null;
    }
};

fn buildDecoMap(allocator: std.mem.Allocator, repo: *repository.Repository) !DecoMap {
    var dmap = DecoMap.init(allocator);
    errdefer dmap.deinit();

    const branches = ref_mod.listRefs(allocator, repo.git_dir, "refs/heads/") catch &[_]ref_mod.RefEntry{};
    defer ref_mod.freeRefEntries(allocator, @constCast(branches));
    for (branches) |entry| {
        const prefix = "refs/heads/";
        const short = if (std.mem.startsWith(u8, entry.name, prefix)) entry.name[prefix.len..] else entry.name;
        try dmap.addEntry(&entry.oid, short);
    }

    const tags = ref_mod.listRefs(allocator, repo.git_dir, "refs/tags/") catch &[_]ref_mod.RefEntry{};
    defer ref_mod.freeRefEntries(allocator, @constCast(tags));
    for (tags) |entry| {
        const prefix = "refs/tags/";
        const short = if (std.mem.startsWith(u8, entry.name, prefix)) entry.name[prefix.len..] else entry.name;
        var tag_buf: [280]u8 = undefined;
        const tag_name = std.fmt.bufPrint(&tag_buf, "tag: {s}", .{short}) catch short;
        try dmap.addEntry(&entry.oid, tag_name);
    }

    return dmap;
}

// ---------------------------------------------------------------------------
// Commit walker
// ---------------------------------------------------------------------------

/// Walks commit history in chronological order (newest first).
/// Supports topological ordering when walking from multiple starting points.
pub const CommitWalker = struct {
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    /// Queue of commit OIDs to visit (with timestamps for sorting).
    queue: std.array_list.Managed(QueueEntry),
    /// Set of already-visited OIDs to avoid duplicates.
    visited_list: std.array_list.Managed([types.OID_HEX_LEN]u8),
    /// Follow only first parent of merge commits.
    first_parent: bool = false,

    const QueueEntry = struct {
        oid: types.ObjectId,
        timestamp: i64,
    };

    pub fn init(allocator: std.mem.Allocator, repo: *repository.Repository) CommitWalker {
        return .{
            .allocator = allocator,
            .repo = repo,
            .queue = std.array_list.Managed(QueueEntry).init(allocator),
            .visited_list = std.array_list.Managed([types.OID_HEX_LEN]u8).init(allocator),
        };
    }

    pub fn deinit(self: *CommitWalker) void {
        self.queue.deinit();
        self.visited_list.deinit();
    }

    /// Add a starting commit OID to the walk queue.
    pub fn push(self: *CommitWalker, oid: types.ObjectId) !void {
        const ts = self.getCommitTimestamp(&oid);
        try self.queue.append(.{ .oid = oid, .timestamp = ts });
        // Sort by timestamp descending (newest first)
        sortQueue(self.queue.items);
    }

    /// Get the next commit OID in the walk. Returns null when done.
    pub fn next(self: *CommitWalker) !?types.ObjectId {
        while (self.queue.items.len > 0) {
            const entry = self.queue.orderedRemove(0);
            const oid = entry.oid;

            // Check if visited
            const hex = oid.toHex();
            var already_visited = false;
            for (self.visited_list.items) |*v| {
                if (std.mem.eql(u8, v, &hex)) {
                    already_visited = true;
                    break;
                }
            }
            if (already_visited) continue;

            try self.visited_list.append(hex);

            // Read commit to get parents and add them to queue
            var obj = self.repo.readObject(self.allocator, &oid) catch continue;
            defer obj.deinit();
            if (obj.obj_type != .commit) continue;

            // Parse parents
            var parents = tree_diff.getCommitParents(self.allocator, obj.data) catch continue;
            defer parents.deinit();

            // Add parents to queue
            if (self.first_parent) {
                // Only follow first parent
                if (parents.items.len > 0) {
                    const ts = self.getCommitTimestamp(&parents.items[0]);
                    try self.queue.append(.{ .oid = parents.items[0], .timestamp = ts });
                }
            } else {
                for (parents.items) |parent_oid| {
                    const ts = self.getCommitTimestamp(&parent_oid);
                    try self.queue.append(.{ .oid = parent_oid, .timestamp = ts });
                }
            }

            // Re-sort for topological ordering
            sortQueue(self.queue.items);

            return oid;
        }

        return null;
    }

    fn getCommitTimestamp(self: *CommitWalker, oid: *const types.ObjectId) i64 {
        var obj = self.repo.readObject(self.allocator, oid) catch return 0;
        defer obj.deinit();
        if (obj.obj_type != .commit) return 0;

        // Parse committer timestamp
        var pos: usize = 0;
        while (pos < obj.data.len) {
            const line_end = std.mem.indexOfScalarPos(u8, obj.data, pos, '\n') orelse obj.data.len;
            const line = obj.data[pos..line_end];
            pos = line_end + 1;
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "committer ")) {
                // Find timestamp after last '>'
                const gt = std.mem.lastIndexOfScalar(u8, line, '>') orelse continue;
                if (gt + 2 < line.len) {
                    const after = line[gt + 2 ..];
                    const space = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
                    return std.fmt.parseInt(i64, after[0..space], 10) catch 0;
                }
            }
        }
        return 0;
    }

    fn sortQueue(items: []QueueEntry) void {
        // Simple insertion sort by timestamp descending
        for (items, 0..) |_, i| {
            if (i == 0) continue;
            var j = i;
            while (j > 0 and items[j].timestamp > items[j - 1].timestamp) {
                const tmp = items[j];
                items[j] = items[j - 1];
                items[j - 1] = tmp;
                j -= 1;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Commit parsing
// ---------------------------------------------------------------------------

/// Parse a commit object into a structured CommitInfo.
pub fn parseCommit(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    oid: *const types.ObjectId,
) !CommitInfo {
    var obj = try repo.readObject(allocator, oid);
    // We transfer ownership of obj.data to CommitInfo
    if (obj.obj_type != .commit) {
        obj.deinit();
        return error.NotACommit;
    }

    const data = obj.data;
    // Don't free data here -- CommitInfo takes ownership

    var info = CommitInfo{
        .oid = oid.*,
        .tree_oid = types.ObjectId.ZERO,
        .parents = std.array_list.Managed(types.ObjectId).init(allocator),
        .author_name = "",
        .author_email = "",
        .author_timestamp = 0,
        .author_timezone = "",
        .committer_name = "",
        .committer_email = "",
        .committer_timestamp = 0,
        .committer_timezone = "",
        .message = "",
        .raw_data = data,
    };
    errdefer {
        info.parents.deinit();
        allocator.free(data);
    }

    var pos: usize = 0;

    // Parse headers
    while (pos < data.len) {
        const line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        const line = data[pos..line_end];
        pos = line_end + 1;

        if (line.len == 0) {
            // End of headers, rest is message
            info.message = if (pos < data.len) data[pos..] else "";
            break;
        }

        if (std.mem.startsWith(u8, line, "tree ")) {
            if (line.len >= 5 + types.OID_HEX_LEN) {
                info.tree_oid = types.ObjectId.fromHex(line[5..][0..types.OID_HEX_LEN]) catch types.ObjectId.ZERO;
            }
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            if (line.len >= 7 + types.OID_HEX_LEN) {
                const parent_oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch continue;
                try info.parents.append(parent_oid);
            }
        } else if (std.mem.startsWith(u8, line, "author ")) {
            parseAuthorLine(line[7..], &info.author_name, &info.author_email, &info.author_timestamp, &info.author_timezone);
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            parseAuthorLine(line[10..], &info.committer_name, &info.committer_email, &info.committer_timestamp, &info.committer_timezone);
        }
    }

    return info;
}

/// Parse an author/committer line: "Name <email> timestamp timezone"
fn parseAuthorLine(
    line: []const u8,
    name_out: *[]const u8,
    email_out: *[]const u8,
    timestamp_out: *i64,
    timezone_out: *[]const u8,
) void {
    // Find the email in angle brackets
    const lt_pos = std.mem.indexOfScalar(u8, line, '<') orelse return;
    const gt_pos = std.mem.indexOfScalar(u8, line, '>') orelse return;

    if (lt_pos == 0) {
        name_out.* = "";
    } else {
        name_out.* = std.mem.trimRight(u8, line[0 .. lt_pos - 1], " ");
    }

    if (gt_pos > lt_pos + 1) {
        email_out.* = line[lt_pos + 1 .. gt_pos];
    }

    // After '>': " timestamp timezone"
    if (gt_pos + 2 < line.len) {
        const after = line[gt_pos + 2 ..];
        const space_pos = std.mem.indexOfScalar(u8, after, ' ');
        if (space_pos) |sp| {
            const ts_str = after[0..sp];
            timestamp_out.* = std.fmt.parseInt(i64, ts_str, 10) catch 0;
            if (sp + 1 < after.len) {
                timezone_out.* = after[sp + 1 ..];
            }
        } else {
            timestamp_out.* = std.fmt.parseInt(i64, after, 10) catch 0;
        }
    }
}

// ---------------------------------------------------------------------------
// Output formatting
// ---------------------------------------------------------------------------

/// Write a commit in full format.
fn writeFullFormat(stdout: std.fs.File, commit: *CommitInfo, graph: bool, index: usize, deco: ?[]const u8, is_merge: bool, prev_was_merge: bool, prev_at_merge_second: bool) !void {
    var buf: [4096]u8 = undefined;

    // Separator (empty line before all but first commit)
    if (index > 0) {
        if (graph) {
            if (prev_was_merge) {
                try stdout.writeAll("|\\\n");
            } else if (prev_at_merge_second) {
                try stdout.writeAll("|/\n");
            } else {
                try stdout.writeAll("| \n");
            }
        } else {
            try stdout.writeAll("\n");
        }
    }

    _ = is_merge;
    const hex = commit.oid.toHex();

    // "commit <hash>" with optional decoration
    const graph_prefix: []const u8 = if (graph) "* " else "";
    if (deco) |d| {
        const msg = std.fmt.bufPrint(&buf, "{s}{s}commit {s}{s} ({s}{s}{s})\n", .{
            graph_prefix, COLOR_YELLOW, &hex, COLOR_RESET, COLOR_GREEN, d, COLOR_RESET,
        }) catch return;
        try stdout.writeAll(msg);
    } else {
        const msg = std.fmt.bufPrint(&buf, "{s}{s}commit {s}{s}\n", .{ graph_prefix, COLOR_YELLOW, &hex, COLOR_RESET }) catch return;
        try stdout.writeAll(msg);
    }

    // "Author: Name <email>"
    const author_prefix: []const u8 = if (graph) "| " else "";
    var msg = std.fmt.bufPrint(&buf, "{s}Author: {s} <{s}>\n", .{ author_prefix, commit.author_name, commit.author_email }) catch return;
    try stdout.writeAll(msg);

    // "Date:   <formatted date>"
    const date_str = formatTimestamp(commit.author_timestamp, commit.author_timezone);
    msg = std.fmt.bufPrint(&buf, "{s}Date:   {s}\n", .{ author_prefix, &date_str }) catch return;
    try stdout.writeAll(msg);

    // Empty line + message (indented)
    const message_prefix: []const u8 = if (graph) "| " else "";
    msg = std.fmt.bufPrint(&buf, "{s}\n", .{message_prefix}) catch return;
    try stdout.writeAll(msg);

    // Print each line of the message with indentation
    const trimmed_msg = std.mem.trimRight(u8, commit.message, "\n\r ");
    var line_iter = std.mem.splitScalar(u8, trimmed_msg, '\n');
    while (line_iter.next()) |line| {
        msg = std.fmt.bufPrint(&buf, "{s}    {s}\n", .{ message_prefix, line }) catch continue;
        try stdout.writeAll(msg);
    }
}

/// Write a commit in oneline format.
fn writeOnelineFormat(stdout: std.fs.File, commit: *CommitInfo, graph: bool, deco: ?[]const u8, is_merge: bool, prev_was_merge: bool, prev_at_merge_second: bool) !void {
    var buf: [4096]u8 = undefined;

    _ = is_merge;

    // Graph connector lines
    if (graph and prev_was_merge) {
        try stdout.writeAll("|\\ \n");
    } else if (graph and prev_at_merge_second) {
        try stdout.writeAll("|/ \n");
    }

    const hex = commit.oid.toHex();
    const short_hash = hex[0..7];

    // Get first line of message
    const first_line = getFirstLine(commit.message);

    const graph_prefix: []const u8 = if (graph) "* " else "";
    if (deco) |d| {
        const msg = std.fmt.bufPrint(&buf, "{s}{s}{s}{s} ({s}{s}{s}) {s}\n", .{
            graph_prefix,
            COLOR_YELLOW,
            short_hash,
            COLOR_RESET,
            COLOR_GREEN,
            d,
            COLOR_RESET,
            first_line,
        }) catch return;
        try stdout.writeAll(msg);
    } else {
        const msg = std.fmt.bufPrint(&buf, "{s}{s}{s}{s} {s}\n", .{
            graph_prefix,
            COLOR_YELLOW,
            short_hash,
            COLOR_RESET,
            first_line,
        }) catch return;
        try stdout.writeAll(msg);
    }
}

/// Get the first non-empty line from a message.
fn getFirstLine(message: []const u8) []const u8 {
    const trimmed = std.mem.trimLeft(u8, message, "\n\r ");
    const nl = std.mem.indexOfScalar(u8, trimmed, '\n');
    if (nl) |n| {
        return std.mem.trimRight(u8, trimmed[0..n], " \r");
    }
    return std.mem.trimRight(u8, trimmed, " \r\n");
}

// ---------------------------------------------------------------------------
// Timestamp formatting
// ---------------------------------------------------------------------------

/// Format a Unix timestamp + timezone string into a human-readable date.
/// Returns a fixed-size buffer with the formatted string.
fn formatTimestamp(timestamp: i64, timezone: []const u8) [64]u8 {
    var result: [64]u8 = undefined;
    @memset(&result, 0);

    // Parse timezone offset
    var tz_offset_minutes: i64 = 0;
    if (timezone.len >= 5) {
        const sign: i64 = if (timezone[0] == '-') -1 else 1;
        const hours = std.fmt.parseInt(i64, timezone[1..3], 10) catch 0;
        const minutes = std.fmt.parseInt(i64, timezone[3..5], 10) catch 0;
        tz_offset_minutes = sign * (hours * 60 + minutes);
    }

    // Apply timezone offset
    const adjusted = timestamp + tz_offset_minutes * 60;

    // Convert to date components
    const epoch_days = @divFloor(adjusted, 86400);
    const day_seconds = @mod(adjusted, 86400);
    const hours: u8 = @intCast(@divFloor(day_seconds, 3600));
    const rem_after_hours = @mod(day_seconds, 3600);
    const minutes: u8 = @intCast(@divFloor(rem_after_hours, 60));
    const seconds: u8 = @intCast(@mod(rem_after_hours, 60));

    // Civil date from epoch days (algorithm from Howard Hinnant)
    const z = epoch_days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe_calc = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe_calc + era * 400;
    const doy = doe - (365 * yoe_calc + @divFloor(yoe_calc, 4) - @divFloor(yoe_calc, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m_raw = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m_raw <= 2) y + 1 else y;
    const month: u8 = @intCast(m_raw);
    const day: u8 = @intCast(d);

    // Day of week
    const dow_idx: usize = @intCast(@mod(epoch_days + 4, 7)); // 0=Sunday (epoch was Thursday, +4)
    const dow_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mon_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const dow_name = if (dow_idx < 7) dow_names[dow_idx] else "???";
    const mon_name = if (month >= 1 and month <= 12) mon_names[month - 1] else "???";

    // Format: "Tue Mar 15 12:34:56 2022 +0100"
    var stream = std.io.fixedBufferStream(&result);
    const writer = stream.writer();
    writer.print("{s} {s} {d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {d} {s}", .{
        dow_name,
        mon_name,
        day,
        hours,
        minutes,
        seconds,
        year,
        timezone,
    }) catch {};

    return result;
}

/// Write the diff for a single commit (against its first parent, or empty tree for root commits).
fn writeCommitDiff(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    commit: *CommitInfo,
    stdout: std.fs.File,
) !void {
    const new_tree_oid = commit.tree_oid;

    if (commit.parents.items.len == 0) {
        // Root commit - diff against empty tree
        var diff_result = tree_diff.diffTrees(repo, allocator, null, &new_tree_oid) catch return;
        defer diff_result.deinit();
        diff_mod.writeTreeDiff(repo, allocator, diff_result.changes.items, stdout) catch return;
    } else {
        // Diff against first parent
        const parent_oid = commit.parents.items[0];
        var parent_obj = repo.readObject(allocator, &parent_oid) catch return;
        defer parent_obj.deinit();
        if (parent_obj.obj_type != .commit) return;
        const parent_tree_oid = tree_diff.getCommitTreeOid(parent_obj.data) catch return;

        var diff_result = tree_diff.diffTrees(repo, allocator, &parent_tree_oid, &new_tree_oid) catch return;
        defer diff_result.deinit();
        diff_mod.writeTreeDiff(repo, allocator, diff_result.changes.items, stdout) catch return;
    }
}

test "getFirstLine" {
    try std.testing.expectEqualStrings("hello world", getFirstLine("hello world\nmore stuff\n"));
    try std.testing.expectEqualStrings("single", getFirstLine("single"));
    try std.testing.expectEqualStrings("after blank", getFirstLine("\n\nafter blank\n"));
}

test "parseAuthorLine" {
    var name: []const u8 = "";
    var email: []const u8 = "";
    var ts: i64 = 0;
    var tz: []const u8 = "";

    parseAuthorLine("John Doe <john@example.com> 1678901234 +0100", &name, &email, &ts, &tz);
    try std.testing.expectEqualStrings("John Doe", name);
    try std.testing.expectEqualStrings("john@example.com", email);
    try std.testing.expectEqual(@as(i64, 1678901234), ts);
    try std.testing.expectEqualStrings("+0100", tz);
}
