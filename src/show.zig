const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_diff = @import("tree_diff.zig");
const diff = @import("diff.zig");
const log_mod = @import("log.zig");

// ANSI color codes
const COLOR_YELLOW = "\x1b[33m";
const COLOR_RESET = "\x1b[0m";

/// Run the show command.
pub fn runShow(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    ref_str: []const u8,
    stdout: std.fs.File,
) !void {
    // Resolve the reference
    const oid = try repo.resolveRef(allocator, ref_str);

    // Read the object to determine its type
    var obj = try repo.readObject(allocator, &oid);
    defer obj.deinit();

    switch (obj.obj_type) {
        .commit => try showCommit(repo, allocator, &oid, obj.data, stdout),
        .tag => try showTag(repo, allocator, obj.data, stdout),
        .blob => {
            // Just show the blob content
            try stdout.writeAll(obj.data);
        },
        .tree => {
            // Show tree listing
            try showTreeListing(obj.data, stdout);
        },
    }
}

// ---------------------------------------------------------------------------
// Show commit
// ---------------------------------------------------------------------------

/// Show a commit: header info + diff against parent.
fn showCommit(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    commit_oid: *const types.ObjectId,
    commit_data: []const u8,
    stdout: std.fs.File,
) !void {
    // Parse the commit info using the log module's parser
    // We do a lightweight parse here to avoid double-reading the object
    var buf: [4096]u8 = undefined;

    // Write commit header
    const hex = commit_oid.toHex();
    const msg = std.fmt.bufPrint(&buf, "{s}commit {s}{s}\n", .{ COLOR_YELLOW, &hex, COLOR_RESET }) catch return;
    try stdout.writeAll(msg);

    // Parse and display author, committer, message
    try writeCommitHeader(commit_data, stdout);

    // Get the tree OID for this commit
    const new_tree_oid = tree_diff.getCommitTreeOid(commit_data) catch return;

    // Get parent(s)
    var parents = tree_diff.getCommitParents(allocator, commit_data) catch return;
    defer parents.deinit();

    // Diff against parent (or empty tree for initial commit)
    if (parents.items.len == 0) {
        // Initial commit: diff null tree against this commit's tree
        var td = tree_diff.diffTrees(repo, allocator, null, &new_tree_oid) catch return;
        defer td.deinit();
        diff.writeTreeDiff(repo, allocator, td.changes.items, stdout) catch {};
    } else {
        // Diff first parent against this commit
        const parent_oid = parents.items[0];
        var parent_obj = repo.readObject(allocator, &parent_oid) catch return;
        defer parent_obj.deinit();
        if (parent_obj.obj_type != .commit) return;

        const old_tree_oid = tree_diff.getCommitTreeOid(parent_obj.data) catch return;

        var td = tree_diff.diffTrees(repo, allocator, &old_tree_oid, &new_tree_oid) catch return;
        defer td.deinit();
        diff.writeTreeDiff(repo, allocator, td.changes.items, stdout) catch {};
    }
}

/// Write commit header (author, date, message) in a format similar to `git show`.
fn writeCommitHeader(data: []const u8, stdout: std.fs.File) !void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var in_headers = true;

    while (pos < data.len) {
        const line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        const line = data[pos..line_end];
        pos = line_end + 1;

        if (in_headers) {
            if (line.len == 0) {
                in_headers = false;
                try stdout.writeAll("\n");
                continue;
            }

            if (std.mem.startsWith(u8, line, "author ")) {
                var name: []const u8 = "";
                var email: []const u8 = "";
                var ts: i64 = 0;
                var tz: []const u8 = "";
                parseAuthorLineSlice(line[7..], &name, &email, &ts, &tz);

                var msg = std.fmt.bufPrint(&buf, "Author: {s} <{s}>\n", .{ name, email }) catch continue;
                try stdout.writeAll(msg);

                const date_str = formatTimestampBuf(ts, tz);
                msg = std.fmt.bufPrint(&buf, "Date:   {s}\n", .{&date_str}) catch continue;
                try stdout.writeAll(msg);
            } else if (std.mem.startsWith(u8, line, "Merge: ") or std.mem.startsWith(u8, line, "merge ")) {
                // Show merge parents
                const msg = std.fmt.bufPrint(&buf, "{s}\n", .{line}) catch continue;
                try stdout.writeAll(msg);
            }
            // Skip tree and parent lines (already shown via commit hash)
        } else {
            // Message body: indent with 4 spaces
            const msg = std.fmt.bufPrint(&buf, "    {s}\n", .{line}) catch continue;
            try stdout.writeAll(msg);
        }
    }

    try stdout.writeAll("\n");
}

// ---------------------------------------------------------------------------
// Show tag
// ---------------------------------------------------------------------------

/// Show a tag object and then show the tagged object.
fn showTag(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    tag_data: []const u8,
    stdout: std.fs.File,
) !void {
    var buf: [4096]u8 = undefined;

    // Parse tag object
    var target_oid: ?types.ObjectId = null;
    var target_type: ?[]const u8 = null;
    var tag_name: ?[]const u8 = null;
    var pos: usize = 0;
    var in_headers = true;

    while (pos < tag_data.len) {
        const line_end = std.mem.indexOfScalarPos(u8, tag_data, pos, '\n') orelse tag_data.len;
        const line = tag_data[pos..line_end];
        pos = line_end + 1;

        if (in_headers) {
            if (line.len == 0) {
                in_headers = false;
                continue;
            }

            if (std.mem.startsWith(u8, line, "object ")) {
                if (line.len >= 7 + types.OID_HEX_LEN) {
                    target_oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch null;
                }
            } else if (std.mem.startsWith(u8, line, "type ")) {
                target_type = line[5..];
            } else if (std.mem.startsWith(u8, line, "tag ")) {
                tag_name = line[4..];
            } else if (std.mem.startsWith(u8, line, "tagger ")) {
                var name: []const u8 = "";
                var email: []const u8 = "";
                var ts: i64 = 0;
                var tz: []const u8 = "";
                parseAuthorLineSlice(line[7..], &name, &email, &ts, &tz);

                if (tag_name) |tn| {
                    const tag_msg = std.fmt.bufPrint(&buf, "tag {s}\n", .{tn}) catch continue;
                    try stdout.writeAll(tag_msg);
                }
                if (target_type) |tt| {
                    const tagger_msg = std.fmt.bufPrint(&buf, "Tagger: {s} <{s}>\n", .{ name, email }) catch continue;
                    try stdout.writeAll(tagger_msg);
                    _ = tt;
                }
                const date_str = formatTimestampBuf(ts, tz);
                const date_msg = std.fmt.bufPrint(&buf, "Date:   {s}\n", .{&date_str}) catch continue;
                try stdout.writeAll(date_msg);
            }
        } else {
            // Tag message
            const tag_line = std.fmt.bufPrint(&buf, "\n    {s}", .{line}) catch continue;
            try stdout.writeAll(tag_line);
        }
    }
    try stdout.writeAll("\n\n");

    // Now show the tagged object
    if (target_oid) |toid| {
        // Check if it's a commit
        if (target_type) |tt| {
            if (std.mem.eql(u8, tt, "commit")) {
                var obj = repo.readObject(allocator, &toid) catch return;
                defer obj.deinit();
                try showCommit(repo, allocator, &toid, obj.data, stdout);
                return;
            }
        }
        // For other types, just show the object
        var obj = repo.readObject(allocator, &toid) catch return;
        defer obj.deinit();
        try stdout.writeAll(obj.data);
    }
}

// ---------------------------------------------------------------------------
// Show tree listing
// ---------------------------------------------------------------------------

fn showTreeListing(data: []const u8, stdout: std.fs.File) !void {
    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    while (pos < data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse return;
        const mode = data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, data, space_pos + 1, 0) orelse return;
        const name = data[space_pos + 1 .. null_pos];

        if (null_pos + 1 + types.OID_RAW_LEN > data.len) return;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, data[null_pos + 1 ..][0..types.OID_RAW_LEN]);
        pos = null_pos + 1 + types.OID_RAW_LEN;

        const hex = oid.toHex();
        const obj_type_str = modeToType(mode);
        const msg = std.fmt.bufPrint(&buf, "{s:0>6} {s} {s}\t{s}\n", .{ mode, obj_type_str, &hex, name }) catch continue;
        try stdout.writeAll(msg);
    }
}

fn modeToType(mode: []const u8) []const u8 {
    if (std.mem.eql(u8, mode, "40000")) return "tree";
    if (std.mem.startsWith(u8, mode, "1")) {
        if (std.mem.eql(u8, mode, "160000")) return "commit";
        return "blob";
    }
    return "blob";
}

// ---------------------------------------------------------------------------
// Helper: author line parsing (reused from log.zig's logic, but self-contained)
// ---------------------------------------------------------------------------

fn parseAuthorLineSlice(
    line: []const u8,
    name_out: *[]const u8,
    email_out: *[]const u8,
    timestamp_out: *i64,
    timezone_out: *[]const u8,
) void {
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

/// Format a Unix timestamp + timezone string into a human-readable date.
fn formatTimestampBuf(timestamp: i64, timezone: []const u8) [64]u8 {
    var result: [64]u8 = undefined;
    @memset(&result, 0);

    var tz_offset_minutes: i64 = 0;
    if (timezone.len >= 5) {
        const sign: i64 = if (timezone[0] == '-') -1 else 1;
        const hours = std.fmt.parseInt(i64, timezone[1..3], 10) catch 0;
        const minutes = std.fmt.parseInt(i64, timezone[3..5], 10) catch 0;
        tz_offset_minutes = sign * (hours * 60 + minutes);
    }

    const adjusted = timestamp + tz_offset_minutes * 60;

    // Guard against negative timestamps
    if (adjusted < 0) {
        var stream = std.io.fixedBufferStream(&result);
        const writer = stream.writer();
        writer.print("Thu Jan 01 00:00:00 1970 {s}", .{timezone}) catch {};
        return result;
    }

    const epoch_days = @divFloor(adjusted, 86400);
    const day_seconds = @mod(adjusted, 86400);
    const hours: u8 = @intCast(@divFloor(day_seconds, 3600));
    const rem_after_hours = @mod(day_seconds, 3600);
    const minutes: u8 = @intCast(@divFloor(rem_after_hours, 60));
    const seconds: u8 = @intCast(@mod(rem_after_hours, 60));

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
    const day_val: u8 = @intCast(d);

    const raw_dow = @mod(epoch_days + 4, 7);
    const dow_idx: usize = if (raw_dow >= 0) @intCast(raw_dow) else @intCast(raw_dow + 7);
    const dow_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mon_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const dow_name = if (dow_idx < 7) dow_names[dow_idx] else "???";
    const mon_name = if (month >= 1 and month <= 12) mon_names[month - 1] else "???";

    var stream = std.io.fixedBufferStream(&result);
    const writer = stream.writer();
    writer.print("{s} {s} {d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {d} {s}", .{
        dow_name,
        mon_name,
        day_val,
        hours,
        minutes,
        seconds,
        year,
        timezone,
    }) catch {};

    return result;
}
