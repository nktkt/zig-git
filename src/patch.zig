const std = @import("std");

/// Represents a single line in a hunk.
pub const PatchLineKind = enum {
    context,
    addition,
    deletion,
    no_newline_marker,
};

pub const PatchLine = struct {
    kind: PatchLineKind,
    content: []const u8,
};

/// A contiguous hunk of changes in a file diff.
pub const Hunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    header_suffix: []const u8, // text after @@ ... @@
    lines: std.array_list.Managed(PatchLine),

    pub fn deinit(self: *Hunk) void {
        self.lines.deinit();
    }
};

/// Represents the diff for a single file.
pub const FileDiff = struct {
    old_path: []const u8,
    new_path: []const u8,
    hunks: std.array_list.Managed(Hunk),
    is_new: bool,
    is_deleted: bool,
    is_rename: bool,
    is_binary: bool,
    old_mode: []const u8,
    new_mode: []const u8,
    rename_from: []const u8,
    rename_to: []const u8,

    pub fn deinit(self: *FileDiff) void {
        for (self.hunks.items) |*h| {
            h.deinit();
        }
        self.hunks.deinit();
    }

    /// Count insertions in this file diff.
    pub fn insertions(self: *const FileDiff) usize {
        var count: usize = 0;
        for (self.hunks.items) |*h| {
            for (h.lines.items) |*line| {
                if (line.kind == .addition) count += 1;
            }
        }
        return count;
    }

    /// Count deletions in this file diff.
    pub fn deletions(self: *const FileDiff) usize {
        var count: usize = 0;
        for (self.hunks.items) |*h| {
            for (h.lines.items) |*line| {
                if (line.kind == .deletion) count += 1;
            }
        }
        return count;
    }
};

/// A complete patch containing multiple file diffs.
pub const Patch = struct {
    allocator: std.mem.Allocator,
    file_diffs: std.array_list.Managed(FileDiff),
    /// Owned string storage
    strings: std.array_list.Managed([]u8),

    pub fn deinit(self: *Patch) void {
        for (self.file_diffs.items) |*fd| {
            fd.deinit();
        }
        self.file_diffs.deinit();
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit();
    }

    /// Total number of insertions across all files.
    pub fn totalInsertions(self: *const Patch) usize {
        var total: usize = 0;
        for (self.file_diffs.items) |*fd| {
            total += fd.insertions();
        }
        return total;
    }

    /// Total number of deletions across all files.
    pub fn totalDeletions(self: *const Patch) usize {
        var total: usize = 0;
        for (self.file_diffs.items) |*fd| {
            total += fd.deletions();
        }
        return total;
    }
};

/// Represents a single message extracted from mbox format.
pub const MboxMessage = struct {
    from: []const u8,
    date: []const u8,
    subject: []const u8,
    message_id: []const u8,
    body: []const u8,
    patch_text: []const u8,
};

/// Result of parsing mbox data.
pub const MboxResult = struct {
    allocator: std.mem.Allocator,
    messages: std.array_list.Managed(MboxMessage),
    strings: std.array_list.Managed([]u8),

    pub fn deinit(self: *MboxResult) void {
        self.messages.deinit();
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit();
    }
};

/// Parse a unified diff text into a structured Patch.
pub fn parsePatch(allocator: std.mem.Allocator, text: []const u8) !Patch {
    var patch = Patch{
        .allocator = allocator,
        .file_diffs = std.array_list.Managed(FileDiff).init(allocator),
        .strings = std.array_list.Managed([]u8).init(allocator),
    };
    errdefer patch.deinit();

    var line_iter = std.mem.splitScalar(u8, text, '\n');
    var current_diff: ?*FileDiff = null;
    var current_hunk: ?*Hunk = null;

    while (line_iter.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");

        // Detect start of a new file diff
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            // Parse "diff --git a/FILE b/FILE"
            const paths = parseDiffGitLine(line);
            const fd = FileDiff{
                .old_path = paths.old_path,
                .new_path = paths.new_path,
                .hunks = std.array_list.Managed(Hunk).init(allocator),
                .is_new = false,
                .is_deleted = false,
                .is_rename = false,
                .is_binary = false,
                .old_mode = "",
                .new_mode = "",
                .rename_from = "",
                .rename_to = "",
            };
            try patch.file_diffs.append(fd);
            current_diff = &patch.file_diffs.items[patch.file_diffs.items.len - 1];
            current_hunk = null;
            continue;
        }

        if (current_diff) |diff| {
            // Parse extended headers
            if (std.mem.startsWith(u8, line, "new file mode ")) {
                diff.is_new = true;
                diff.new_mode = line["new file mode ".len..];
                continue;
            }
            if (std.mem.startsWith(u8, line, "deleted file mode ")) {
                diff.is_deleted = true;
                diff.old_mode = line["deleted file mode ".len..];
                continue;
            }
            if (std.mem.startsWith(u8, line, "old mode ")) {
                diff.old_mode = line["old mode ".len..];
                continue;
            }
            if (std.mem.startsWith(u8, line, "new mode ")) {
                diff.new_mode = line["new mode ".len..];
                continue;
            }
            if (std.mem.startsWith(u8, line, "rename from ")) {
                diff.is_rename = true;
                diff.rename_from = line["rename from ".len..];
                continue;
            }
            if (std.mem.startsWith(u8, line, "rename to ")) {
                diff.rename_to = line["rename to ".len..];
                continue;
            }
            if (std.mem.startsWith(u8, line, "Binary files ")) {
                diff.is_binary = true;
                continue;
            }
            if (std.mem.startsWith(u8, line, "index ")) {
                continue;
            }
            if (std.mem.startsWith(u8, line, "--- ")) {
                if (std.mem.eql(u8, line, "--- /dev/null")) {
                    diff.is_new = true;
                } else if (line.len > 6 and std.mem.startsWith(u8, line[4..], "a/")) {
                    diff.old_path = line[6..];
                }
                continue;
            }
            if (std.mem.startsWith(u8, line, "+++ ")) {
                if (std.mem.eql(u8, line, "+++ /dev/null")) {
                    diff.is_deleted = true;
                } else if (line.len > 6 and std.mem.startsWith(u8, line[4..], "b/")) {
                    diff.new_path = line[6..];
                }
                continue;
            }

            // Parse hunk header
            if (std.mem.startsWith(u8, line, "@@ ")) {
                const hunk_info = parseHunkHeader(line) orelse continue;
                var hunk = Hunk{
                    .old_start = hunk_info.old_start,
                    .old_count = hunk_info.old_count,
                    .new_start = hunk_info.new_start,
                    .new_count = hunk_info.new_count,
                    .header_suffix = hunk_info.suffix,
                    .lines = std.array_list.Managed(PatchLine).init(allocator),
                };
                _ = &hunk;
                try diff.hunks.append(hunk);
                current_hunk = &diff.hunks.items[diff.hunks.items.len - 1];
                continue;
            }

            // Parse hunk content lines
            if (current_hunk) |hunk| {
                if (line.len > 0 and line[0] == ' ') {
                    try hunk.lines.append(.{
                        .kind = .context,
                        .content = if (line.len > 1) line[1..] else "",
                    });
                } else if (line.len > 0 and line[0] == '+') {
                    try hunk.lines.append(.{
                        .kind = .addition,
                        .content = if (line.len > 1) line[1..] else "",
                    });
                } else if (line.len > 0 and line[0] == '-') {
                    try hunk.lines.append(.{
                        .kind = .deletion,
                        .content = if (line.len > 1) line[1..] else "",
                    });
                } else if (std.mem.startsWith(u8, line, "\\ No newline at end of file")) {
                    try hunk.lines.append(.{
                        .kind = .no_newline_marker,
                        .content = line,
                    });
                }
            }
        }
    }

    return patch;
}

/// Parse mbox format into individual messages.
pub fn parseMbox(allocator: std.mem.Allocator, text: []const u8) !MboxResult {
    var result = MboxResult{
        .allocator = allocator,
        .messages = std.array_list.Managed(MboxMessage).init(allocator),
        .strings = std.array_list.Managed([]u8).init(allocator),
    };
    errdefer result.deinit();

    // Split by "From " lines at the start of lines
    var pos: usize = 0;
    var msg_starts = std.array_list.Managed(usize).init(allocator);
    defer msg_starts.deinit();

    // Find all message boundaries
    if (std.mem.startsWith(u8, text, "From ")) {
        try msg_starts.append(0);
    }
    while (pos < text.len) {
        if (std.mem.indexOfPos(u8, text, pos, "\nFrom ")) |found| {
            try msg_starts.append(found + 1);
            pos = found + 6;
        } else {
            break;
        }
    }

    if (msg_starts.items.len == 0) {
        // Try treating the whole thing as a single patch
        const msg = MboxMessage{
            .from = "",
            .date = "",
            .subject = "",
            .message_id = "",
            .body = "",
            .patch_text = text,
        };
        try result.messages.append(msg);
        return result;
    }

    for (msg_starts.items, 0..) |start, i| {
        const end = if (i + 1 < msg_starts.items.len) msg_starts.items[i + 1] else text.len;
        const msg_text = text[start..end];

        var msg = MboxMessage{
            .from = "",
            .date = "",
            .subject = "",
            .message_id = "",
            .body = "",
            .patch_text = "",
        };

        // Parse headers
        var line_iter = std.mem.splitScalar(u8, msg_text, '\n');
        _ = line_iter.next(); // Skip the "From HASH date" line

        var in_headers = true;
        var body_start: usize = 0;
        var consumed: usize = 0;

        while (line_iter.next()) |raw_line| {
            const line_len = raw_line.len + 1; // +1 for the newline
            consumed += line_len;

            const line = std.mem.trimRight(u8, raw_line, "\r");

            if (in_headers) {
                if (line.len == 0) {
                    in_headers = false;
                    body_start = consumed + (if (std.mem.startsWith(u8, msg_text, "From ")) blk: {
                        const first_nl = std.mem.indexOfScalar(u8, msg_text, '\n') orelse 0;
                        break :blk first_nl + 1;
                    } else 0);
                    continue;
                }
                if (std.mem.startsWith(u8, line, "From: ")) {
                    msg.from = line["From: ".len..];
                } else if (std.mem.startsWith(u8, line, "Date: ")) {
                    msg.date = line["Date: ".len..];
                } else if (std.mem.startsWith(u8, line, "Subject: ")) {
                    msg.subject = line["Subject: ".len..];
                } else if (std.mem.startsWith(u8, line, "Message-Id: ") or std.mem.startsWith(u8, line, "Message-ID: ")) {
                    const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                    msg.message_id = std.mem.trimLeft(u8, line[colon_pos + 1 ..], " ");
                }
            }
        }

        // Split body into commit message and patch
        if (body_start < msg_text.len) {
            const body_text = msg_text[body_start..];
            // Find the start of the diff
            if (std.mem.indexOf(u8, body_text, "\ndiff --git ")) |diff_start| {
                msg.body = body_text[0..diff_start];
                msg.patch_text = body_text[diff_start + 1 ..];
            } else if (std.mem.indexOf(u8, body_text, "diff --git ")) |diff_start| {
                if (diff_start == 0) {
                    msg.body = "";
                    msg.patch_text = body_text;
                } else {
                    msg.body = body_text[0..diff_start];
                    msg.patch_text = body_text[diff_start..];
                }
            } else {
                msg.body = body_text;
            }
        }

        try result.messages.append(msg);
    }

    return result;
}

/// Generate a diffstat summary string for a list of file diffs.
pub fn formatDiffstat(allocator: std.mem.Allocator, file_diffs: []const FileDiff) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var buf: [512]u8 = undefined;
    var total_ins: usize = 0;
    var total_del: usize = 0;
    var max_name_len: usize = 0;

    // First pass: compute max name length and totals
    for (file_diffs) |*fd| {
        const name = if (fd.new_path.len > 0) fd.new_path else fd.old_path;
        if (name.len > max_name_len) max_name_len = name.len;
        total_ins += fd.insertions();
        total_del += fd.deletions();
    }

    // Clamp max name length for display
    if (max_name_len > 50) max_name_len = 50;

    // Second pass: format each file
    for (file_diffs) |*fd| {
        const name = if (fd.new_path.len > 0) fd.new_path else fd.old_path;
        const ins = fd.insertions();
        const del = fd.deletions();
        const total_changes = ins + del;

        const bar_width: usize = 40;
        const bar_len = if (total_changes > bar_width) bar_width else total_changes;
        const plus_len = if (total_changes > 0) (ins * bar_len + total_changes - 1) / total_changes else 0;

        const line = std.fmt.bufPrint(&buf, " {s}", .{name}) catch continue;
        try output.appendSlice(line);

        // Pad to alignment
        var pad_count: usize = 0;
        if (name.len < max_name_len + 2) {
            pad_count = max_name_len + 2 - name.len;
        }
        var pad_idx: usize = 0;
        while (pad_idx < pad_count) : (pad_idx += 1) {
            try output.append(' ');
        }

        const change_line = std.fmt.bufPrint(&buf, "| {d: >4} ", .{total_changes}) catch continue;
        try output.appendSlice(change_line);

        // Draw the bar
        var bi: usize = 0;
        while (bi < bar_len) : (bi += 1) {
            if (bi < plus_len) {
                try output.append('+');
            } else {
                try output.append('-');
            }
        }
        try output.append('\n');
    }

    // Summary line
    const files_count = file_diffs.len;
    const summary = std.fmt.bufPrint(&buf, " {d} file{s} changed", .{
        files_count,
        if (files_count != 1) "s" else "",
    }) catch "";
    try output.appendSlice(summary);

    if (total_ins > 0) {
        const ins_str = std.fmt.bufPrint(&buf, ", {d} insertion{s}(+)", .{
            total_ins,
            if (total_ins != 1) "s" else "",
        }) catch "";
        try output.appendSlice(ins_str);
    }
    if (total_del > 0) {
        const del_str = std.fmt.bufPrint(&buf, ", {d} deletion{s}(-)", .{
            total_del,
            if (total_del != 1) "s" else "",
        }) catch "";
        try output.appendSlice(del_str);
    }
    try output.append('\n');

    return output.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

const DiffGitPaths = struct {
    old_path: []const u8,
    new_path: []const u8,
};

fn parseDiffGitLine(line: []const u8) DiffGitPaths {
    // "diff --git a/FILE b/FILE"
    const prefix = "diff --git ";
    if (!std.mem.startsWith(u8, line, prefix)) {
        return .{ .old_path = "", .new_path = "" };
    }
    const rest = line[prefix.len..];

    // Find "a/" and "b/" markers
    if (rest.len < 4) return .{ .old_path = "", .new_path = "" };
    if (!std.mem.startsWith(u8, rest, "a/")) return .{ .old_path = "", .new_path = "" };

    // Find " b/" separator
    if (std.mem.indexOf(u8, rest, " b/")) |sep| {
        return .{
            .old_path = rest[2..sep],
            .new_path = rest[sep + 3 ..],
        };
    }

    return .{ .old_path = "", .new_path = "" };
}

const HunkInfo = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    suffix: []const u8,
};

fn parseHunkHeader(line: []const u8) ?HunkInfo {
    // "@@ -OLD_START,OLD_COUNT +NEW_START,NEW_COUNT @@ optional text"
    if (!std.mem.startsWith(u8, line, "@@ ")) return null;

    const after_at = line[3..];
    const minus_pos = std.mem.indexOfScalar(u8, after_at, '-') orelse return null;
    const plus_pos = std.mem.indexOfScalar(u8, after_at, '+') orelse return null;
    const end_at = std.mem.indexOf(u8, after_at, " @@") orelse return null;

    const old_range = after_at[minus_pos + 1 .. plus_pos];
    const old_range_trimmed = std.mem.trimRight(u8, old_range, " ");
    const new_range = after_at[plus_pos + 1 .. end_at];

    var old_start: usize = 0;
    var old_count: usize = 1;
    var new_start: usize = 0;
    var new_count: usize = 1;

    if (std.mem.indexOfScalar(u8, old_range_trimmed, ',')) |comma| {
        old_start = std.fmt.parseInt(usize, old_range_trimmed[0..comma], 10) catch return null;
        old_count = std.fmt.parseInt(usize, old_range_trimmed[comma + 1 ..], 10) catch return null;
    } else {
        old_start = std.fmt.parseInt(usize, old_range_trimmed, 10) catch return null;
    }

    if (std.mem.indexOfScalar(u8, new_range, ',')) |comma| {
        new_start = std.fmt.parseInt(usize, new_range[0..comma], 10) catch return null;
        new_count = std.fmt.parseInt(usize, new_range[comma + 1 ..], 10) catch return null;
    } else {
        new_start = std.fmt.parseInt(usize, new_range, 10) catch return null;
    }

    const suffix_start = end_at + 3; // past " @@"
    const suffix = if (suffix_start < after_at.len) after_at[suffix_start..] else "";

    return HunkInfo{
        .old_start = old_start,
        .old_count = old_count,
        .new_start = new_start,
        .new_count = new_count,
        .suffix = suffix,
    };
}

test "parseDiffGitLine" {
    const result = parseDiffGitLine("diff --git a/foo.txt b/foo.txt");
    try std.testing.expectEqualStrings("foo.txt", result.old_path);
    try std.testing.expectEqualStrings("foo.txt", result.new_path);
}

test "parseHunkHeader" {
    const info = parseHunkHeader("@@ -1,3 +1,5 @@ function") orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), info.old_start);
    try std.testing.expectEqual(@as(usize, 3), info.old_count);
    try std.testing.expectEqual(@as(usize, 1), info.new_start);
    try std.testing.expectEqual(@as(usize, 5), info.new_count);
}

test "parsePatch basic" {
    const text =
        \\diff --git a/hello.txt b/hello.txt
        \\--- a/hello.txt
        \\+++ b/hello.txt
        \\@@ -1,3 +1,4 @@
        \\ line1
        \\-line2
        \\+line2modified
        \\+line2b
        \\ line3
    ;

    var patch = try parsePatch(std.testing.allocator, text);
    defer patch.deinit();

    try std.testing.expectEqual(@as(usize, 1), patch.file_diffs.items.len);
    try std.testing.expectEqualStrings("hello.txt", patch.file_diffs.items[0].old_path);
    try std.testing.expectEqual(@as(usize, 1), patch.file_diffs.items[0].hunks.items.len);
}
