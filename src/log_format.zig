const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const log_mod = @import("log.zig");
const ref_mod = @import("ref.zig");

// ANSI color codes
const COLOR_RED = "\x1b[31m";
const COLOR_GREEN = "\x1b[32m";
const COLOR_BLUE = "\x1b[34m";
const COLOR_YELLOW = "\x1b[33m";
const COLOR_CYAN = "\x1b[36m";
const COLOR_MAGENTA = "\x1b[35m";
const COLOR_BOLD = "\x1b[1m";
const COLOR_RESET = "\x1b[0m";

/// Predefined log format types.
pub const FormatType = enum {
    oneline,
    short,
    medium,
    full,
    fuller,
    email,
    raw,
    custom,
};

/// Date display format.
pub const DateFormat = enum {
    default,
    relative,
    local,
    iso,
    rfc,
    short_date,
    human,
};

/// Options for advanced log formatting.
pub const LogFormatOptions = struct {
    format_type: FormatType = .medium,
    custom_format: []const u8 = "",
    date_format: DateFormat = .default,
    show_decorations: bool = true,
};

/// Ref decoration info for a commit.
pub const RefDecoration = struct {
    names: [16][]const u8,
    count: usize,

    pub fn init() RefDecoration {
        return .{
            .names = undefined,
            .count = 0,
        };
    }

    pub fn add(self: *RefDecoration, name: []const u8) void {
        if (self.count < 16) {
            self.names[self.count] = name;
            self.count += 1;
        }
    }
};

/// Decoration map: maps commit OID hex to ref names.
pub const DecorationMap = struct {
    allocator: std.mem.Allocator,
    entries: std.array_list.Managed(DecoEntry),

    const DecoEntry = struct {
        hex: [types.OID_HEX_LEN]u8,
        name: []u8,
    };

    pub fn init(allocator: std.mem.Allocator) DecorationMap {
        return .{
            .allocator = allocator,
            .entries = std.array_list.Managed(DecoEntry).init(allocator),
        };
    }

    pub fn deinit(self: *DecorationMap) void {
        for (self.entries.items) |*e| {
            self.allocator.free(e.name);
        }
        self.entries.deinit();
    }

    pub fn addEntry(self: *DecorationMap, oid: *const types.ObjectId, name: []const u8) !void {
        const hex = oid.toHex();
        const owned_name = try self.allocator.alloc(u8, name.len);
        @memcpy(owned_name, name);
        try self.entries.append(.{ .hex = hex, .name = owned_name });
    }

    pub fn getDecorations(self: *const DecorationMap, oid: *const types.ObjectId) RefDecoration {
        var deco = RefDecoration.init();
        const hex = oid.toHex();
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, &e.hex, &hex)) {
                deco.add(e.name);
            }
        }
        return deco;
    }
};

/// Build a decoration map from all refs in the repository.
pub fn buildDecorationMap(allocator: std.mem.Allocator, repo: *repository.Repository) !DecorationMap {
    var dmap = DecorationMap.init(allocator);
    errdefer dmap.deinit();

    // Load branches
    const branches = ref_mod.listRefs(allocator, repo.git_dir, "refs/heads/") catch &[_]ref_mod.RefEntry{};
    defer ref_mod.freeRefEntries(allocator, @constCast(branches));

    for (branches) |entry| {
        const prefix_str = "refs/heads/";
        const short_name = if (std.mem.startsWith(u8, entry.name, prefix_str))
            entry.name[prefix_str.len..]
        else
            entry.name;
        var buf: [256]u8 = undefined;
        const decorated = std.fmt.bufPrint(&buf, "HEAD -> {s}", .{short_name}) catch short_name;
        _ = decorated;
        try dmap.addEntry(&entry.oid, short_name);
    }

    // Load tags
    const tags = ref_mod.listRefs(allocator, repo.git_dir, "refs/tags/") catch &[_]ref_mod.RefEntry{};
    defer ref_mod.freeRefEntries(allocator, @constCast(tags));

    for (tags) |entry| {
        const prefix_str = "refs/tags/";
        const short_name = if (std.mem.startsWith(u8, entry.name, prefix_str))
            entry.name[prefix_str.len..]
        else
            entry.name;
        var tag_buf: [280]u8 = undefined;
        const tag_name = std.fmt.bufPrint(&tag_buf, "tag: {s}", .{short_name}) catch short_name;
        try dmap.addEntry(&entry.oid, tag_name);
    }

    return dmap;
}

/// Format a commit using advanced format options and write to stdout.
pub fn formatCommit(
    stdout: std.fs.File,
    commit: *log_mod.CommitInfo,
    opts: *const LogFormatOptions,
    dmap: ?*const DecorationMap,
    index: usize,
) !void {
    switch (opts.format_type) {
        .oneline => try formatOneline(stdout, commit, dmap),
        .short => try formatShort(stdout, commit, dmap, index),
        .medium => try formatMedium(stdout, commit, opts, dmap, index),
        .full => try formatFull(stdout, commit, dmap, index),
        .fuller => try formatFuller(stdout, commit, opts, dmap, index),
        .email => try formatEmail(stdout, commit, opts, index),
        .raw => try formatRaw(stdout, commit, index),
        .custom => try formatCustom(stdout, commit, opts, dmap),
    }
}

/// Oneline: "<short-hash> <subject>"
fn formatOneline(stdout: std.fs.File, commit: *log_mod.CommitInfo, dmap: ?*const DecorationMap) !void {
    var buf: [4096]u8 = undefined;

    const hex = commit.oid.toHex();
    const short_hash = hex[0..7];
    const subject = getSubject(commit.message);

    // Decorations
    var deco_str: [512]u8 = undefined;
    const deco = formatDecorationString(&deco_str, commit, dmap);

    const msg = std.fmt.bufPrint(&buf, "{s}{s}{s}{s} {s}\n", .{
        COLOR_YELLOW,
        short_hash,
        COLOR_RESET,
        deco,
        subject,
    }) catch return;
    try stdout.writeAll(msg);
}

/// Short: commit hash, Author, subject
fn formatShort(stdout: std.fs.File, commit: *log_mod.CommitInfo, dmap: ?*const DecorationMap, index: usize) !void {
    var buf: [4096]u8 = undefined;

    if (index > 0) try stdout.writeAll("\n");

    const hex = commit.oid.toHex();
    var deco_str: [512]u8 = undefined;
    const deco = formatDecorationString(&deco_str, commit, dmap);

    var msg = std.fmt.bufPrint(&buf, "{s}commit {s}{s}{s}\n", .{ COLOR_YELLOW, &hex, COLOR_RESET, deco }) catch return;
    try stdout.writeAll(msg);

    msg = std.fmt.bufPrint(&buf, "Author: {s} <{s}>\n", .{ commit.author_name, commit.author_email }) catch return;
    try stdout.writeAll(msg);

    try stdout.writeAll("\n");
    const subject = getSubject(commit.message);
    msg = std.fmt.bufPrint(&buf, "    {s}\n", .{subject}) catch return;
    try stdout.writeAll(msg);
}

/// Medium (default): commit hash, Author, Date, full message
fn formatMedium(stdout: std.fs.File, commit: *log_mod.CommitInfo, opts: *const LogFormatOptions, dmap: ?*const DecorationMap, index: usize) !void {
    var buf: [4096]u8 = undefined;

    if (index > 0) try stdout.writeAll("\n");

    const hex = commit.oid.toHex();
    var deco_str: [512]u8 = undefined;
    const deco = formatDecorationString(&deco_str, commit, dmap);

    var msg = std.fmt.bufPrint(&buf, "{s}commit {s}{s}{s}\n", .{ COLOR_YELLOW, &hex, COLOR_RESET, deco }) catch return;
    try stdout.writeAll(msg);

    msg = std.fmt.bufPrint(&buf, "Author: {s} <{s}>\n", .{ commit.author_name, commit.author_email }) catch return;
    try stdout.writeAll(msg);

    var date_buf: [128]u8 = undefined;
    const date_str = formatDate(&date_buf, commit.author_timestamp, commit.author_timezone, opts.date_format);
    msg = std.fmt.bufPrint(&buf, "Date:   {s}\n", .{date_str}) catch return;
    try stdout.writeAll(msg);

    try stdout.writeAll("\n");
    const trimmed_msg = std.mem.trimRight(u8, commit.message, "\n\r ");
    var line_iter = std.mem.splitScalar(u8, trimmed_msg, '\n');
    while (line_iter.next()) |line| {
        msg = std.fmt.bufPrint(&buf, "    {s}\n", .{line}) catch continue;
        try stdout.writeAll(msg);
    }
}

/// Full: commit, Author, Commit (committer), message
fn formatFull(stdout: std.fs.File, commit: *log_mod.CommitInfo, dmap: ?*const DecorationMap, index: usize) !void {
    var buf: [4096]u8 = undefined;

    if (index > 0) try stdout.writeAll("\n");

    const hex = commit.oid.toHex();
    var deco_str: [512]u8 = undefined;
    const deco = formatDecorationString(&deco_str, commit, dmap);

    var msg = std.fmt.bufPrint(&buf, "{s}commit {s}{s}{s}\n", .{ COLOR_YELLOW, &hex, COLOR_RESET, deco }) catch return;
    try stdout.writeAll(msg);

    msg = std.fmt.bufPrint(&buf, "Author: {s} <{s}>\n", .{ commit.author_name, commit.author_email }) catch return;
    try stdout.writeAll(msg);

    msg = std.fmt.bufPrint(&buf, "Commit: {s} <{s}>\n", .{ commit.committer_name, commit.committer_email }) catch return;
    try stdout.writeAll(msg);

    try stdout.writeAll("\n");
    const trimmed_msg = std.mem.trimRight(u8, commit.message, "\n\r ");
    var line_iter = std.mem.splitScalar(u8, trimmed_msg, '\n');
    while (line_iter.next()) |line| {
        msg = std.fmt.bufPrint(&buf, "    {s}\n", .{line}) catch continue;
        try stdout.writeAll(msg);
    }
}

/// Fuller: commit, Author, AuthorDate, Commit, CommitDate, message
fn formatFuller(stdout: std.fs.File, commit: *log_mod.CommitInfo, opts: *const LogFormatOptions, dmap: ?*const DecorationMap, index: usize) !void {
    var buf: [4096]u8 = undefined;

    if (index > 0) try stdout.writeAll("\n");

    const hex = commit.oid.toHex();
    var deco_str: [512]u8 = undefined;
    const deco = formatDecorationString(&deco_str, commit, dmap);

    var msg = std.fmt.bufPrint(&buf, "{s}commit {s}{s}{s}\n", .{ COLOR_YELLOW, &hex, COLOR_RESET, deco }) catch return;
    try stdout.writeAll(msg);

    msg = std.fmt.bufPrint(&buf, "Author:     {s} <{s}>\n", .{ commit.author_name, commit.author_email }) catch return;
    try stdout.writeAll(msg);

    var date_buf: [128]u8 = undefined;
    var date_str = formatDate(&date_buf, commit.author_timestamp, commit.author_timezone, opts.date_format);
    msg = std.fmt.bufPrint(&buf, "AuthorDate: {s}\n", .{date_str}) catch return;
    try stdout.writeAll(msg);

    msg = std.fmt.bufPrint(&buf, "Commit:     {s} <{s}>\n", .{ commit.committer_name, commit.committer_email }) catch return;
    try stdout.writeAll(msg);

    var cdate_buf: [128]u8 = undefined;
    date_str = formatDate(&cdate_buf, commit.committer_timestamp, commit.committer_timezone, opts.date_format);
    msg = std.fmt.bufPrint(&buf, "CommitDate: {s}\n", .{date_str}) catch return;
    try stdout.writeAll(msg);

    try stdout.writeAll("\n");
    const trimmed_msg = std.mem.trimRight(u8, commit.message, "\n\r ");
    var line_iter = std.mem.splitScalar(u8, trimmed_msg, '\n');
    while (line_iter.next()) |line| {
        msg = std.fmt.bufPrint(&buf, "    {s}\n", .{line}) catch continue;
        try stdout.writeAll(msg);
    }
}

/// Email format (for format-patch style output).
fn formatEmail(stdout: std.fs.File, commit: *log_mod.CommitInfo, opts: *const LogFormatOptions, index: usize) !void {
    var buf: [4096]u8 = undefined;

    if (index > 0) try stdout.writeAll("\n");

    const subject = getSubject(commit.message);

    var msg = std.fmt.bufPrint(&buf, "From {s} Mon Sep 17 00:00:00 2001\n", .{commit.oid.toHex()}) catch return;
    try stdout.writeAll(msg);

    msg = std.fmt.bufPrint(&buf, "From: {s} <{s}>\n", .{ commit.author_name, commit.author_email }) catch return;
    try stdout.writeAll(msg);

    var date_buf: [128]u8 = undefined;
    const date_str = formatDate(&date_buf, commit.author_timestamp, commit.author_timezone, opts.date_format);
    msg = std.fmt.bufPrint(&buf, "Date: {s}\n", .{date_str}) catch return;
    try stdout.writeAll(msg);

    msg = std.fmt.bufPrint(&buf, "Subject: [PATCH] {s}\n", .{subject}) catch return;
    try stdout.writeAll(msg);

    try stdout.writeAll("\n");
    const body = getBody(commit.message);
    if (body.len > 0) {
        try stdout.writeAll(body);
        try stdout.writeAll("\n");
    }
    try stdout.writeAll("---\n");
}

/// Raw format: shows the raw commit object data.
fn formatRaw(stdout: std.fs.File, commit: *log_mod.CommitInfo, index: usize) !void {
    var buf: [4096]u8 = undefined;

    if (index > 0) try stdout.writeAll("\n");

    const hex = commit.oid.toHex();
    var msg = std.fmt.bufPrint(&buf, "{s}commit {s}{s}\n", .{ COLOR_YELLOW, &hex, COLOR_RESET }) catch return;
    try stdout.writeAll(msg);

    // Tree
    const tree_hex = commit.tree_oid.toHex();
    msg = std.fmt.bufPrint(&buf, "tree {s}\n", .{&tree_hex}) catch return;
    try stdout.writeAll(msg);

    // Parents
    for (commit.parents.items) |parent_oid| {
        const parent_hex = parent_oid.toHex();
        msg = std.fmt.bufPrint(&buf, "parent {s}\n", .{&parent_hex}) catch return;
        try stdout.writeAll(msg);
    }

    // Author
    msg = std.fmt.bufPrint(&buf, "author {s} <{s}> {d} {s}\n", .{
        commit.author_name,
        commit.author_email,
        commit.author_timestamp,
        commit.author_timezone,
    }) catch return;
    try stdout.writeAll(msg);

    // Committer
    msg = std.fmt.bufPrint(&buf, "committer {s} <{s}> {d} {s}\n", .{
        commit.committer_name,
        commit.committer_email,
        commit.committer_timestamp,
        commit.committer_timezone,
    }) catch return;
    try stdout.writeAll(msg);

    try stdout.writeAll("\n");
    const trimmed_msg = std.mem.trimRight(u8, commit.message, "\n\r ");
    var line_iter = std.mem.splitScalar(u8, trimmed_msg, '\n');
    while (line_iter.next()) |line| {
        msg = std.fmt.bufPrint(&buf, "    {s}\n", .{line}) catch continue;
        try stdout.writeAll(msg);
    }
}

/// Custom format with placeholders.
fn formatCustom(stdout: std.fs.File, commit: *log_mod.CommitInfo, opts: *const LogFormatOptions, dmap: ?*const DecorationMap) !void {
    const fmt_str = opts.custom_format;
    var i: usize = 0;

    while (i < fmt_str.len) {
        if (fmt_str[i] == '%' and i + 1 < fmt_str.len) {
            const next = fmt_str[i + 1];
            switch (next) {
                'H' => {
                    // Full hash
                    const hex = commit.oid.toHex();
                    try stdout.writeAll(&hex);
                    i += 2;
                },
                'h' => {
                    // Short hash
                    const hex = commit.oid.toHex();
                    try stdout.writeAll(hex[0..7]);
                    i += 2;
                },
                'T' => {
                    // Full tree hash
                    const hex = commit.tree_oid.toHex();
                    try stdout.writeAll(&hex);
                    i += 2;
                },
                't' => {
                    // Short tree hash
                    const hex = commit.tree_oid.toHex();
                    try stdout.writeAll(hex[0..7]);
                    i += 2;
                },
                'P' => {
                    // Parent hashes (space-separated)
                    for (commit.parents.items, 0..) |parent_oid, pi| {
                        if (pi > 0) try stdout.writeAll(" ");
                        const hex = parent_oid.toHex();
                        try stdout.writeAll(&hex);
                    }
                    i += 2;
                },
                'p' => {
                    // Short parent hashes
                    for (commit.parents.items, 0..) |parent_oid, pi| {
                        if (pi > 0) try stdout.writeAll(" ");
                        const hex = parent_oid.toHex();
                        try stdout.writeAll(hex[0..7]);
                    }
                    i += 2;
                },
                'a' => {
                    // Author fields: %an, %ae, %ad, %ar
                    if (i + 2 < fmt_str.len) {
                        const sub = fmt_str[i + 2];
                        switch (sub) {
                            'n' => {
                                try stdout.writeAll(commit.author_name);
                                i += 3;
                            },
                            'e' => {
                                try stdout.writeAll(commit.author_email);
                                i += 3;
                            },
                            'd' => {
                                var date_buf: [128]u8 = undefined;
                                const date_str = formatDate(&date_buf, commit.author_timestamp, commit.author_timezone, opts.date_format);
                                try stdout.writeAll(date_str);
                                i += 3;
                            },
                            'r' => {
                                var rel_buf: [128]u8 = undefined;
                                const rel = formatRelativeDate(&rel_buf, commit.author_timestamp);
                                try stdout.writeAll(rel);
                                i += 3;
                            },
                            else => {
                                try stdout.writeAll("%a");
                                i += 2;
                            },
                        }
                    } else {
                        try stdout.writeAll("%a");
                        i += 2;
                    }
                },
                'c' => {
                    // Committer fields: %cn, %ce, %cd, %cr
                    if (i + 2 < fmt_str.len) {
                        const sub = fmt_str[i + 2];
                        switch (sub) {
                            'n' => {
                                try stdout.writeAll(commit.committer_name);
                                i += 3;
                            },
                            'e' => {
                                try stdout.writeAll(commit.committer_email);
                                i += 3;
                            },
                            'd' => {
                                var date_buf: [128]u8 = undefined;
                                const date_str = formatDate(&date_buf, commit.committer_timestamp, commit.committer_timezone, opts.date_format);
                                try stdout.writeAll(date_str);
                                i += 3;
                            },
                            'r' => {
                                var rel_buf: [128]u8 = undefined;
                                const rel = formatRelativeDate(&rel_buf, commit.committer_timestamp);
                                try stdout.writeAll(rel);
                                i += 3;
                            },
                            else => {
                                try stdout.writeAll("%c");
                                i += 2;
                            },
                        }
                    } else {
                        try stdout.writeAll("%c");
                        i += 2;
                    }
                },
                's' => {
                    // Subject (first line)
                    const subject = getSubject(commit.message);
                    try stdout.writeAll(subject);
                    i += 2;
                },
                'b' => {
                    // Body (everything after first blank line after subject)
                    const body = getBody(commit.message);
                    try stdout.writeAll(body);
                    i += 2;
                },
                'B' => {
                    // Raw body (full message)
                    const trimmed = std.mem.trimRight(u8, commit.message, "\n\r ");
                    try stdout.writeAll(trimmed);
                    i += 2;
                },
                'n' => {
                    try stdout.writeAll("\n");
                    i += 2;
                },
                'C' => {
                    // Color codes: %Cred, %Cgreen, %Cblue, %Creset, %Cyellow, %Ccyan, %Cbold
                    const rest = fmt_str[i + 2 ..];
                    if (std.mem.startsWith(u8, rest, "red")) {
                        try stdout.writeAll(COLOR_RED);
                        i += 5;
                    } else if (std.mem.startsWith(u8, rest, "green")) {
                        try stdout.writeAll(COLOR_GREEN);
                        i += 7;
                    } else if (std.mem.startsWith(u8, rest, "blue")) {
                        try stdout.writeAll(COLOR_BLUE);
                        i += 6;
                    } else if (std.mem.startsWith(u8, rest, "yellow")) {
                        try stdout.writeAll(COLOR_YELLOW);
                        i += 8;
                    } else if (std.mem.startsWith(u8, rest, "cyan")) {
                        try stdout.writeAll(COLOR_CYAN);
                        i += 6;
                    } else if (std.mem.startsWith(u8, rest, "bold")) {
                        try stdout.writeAll(COLOR_BOLD);
                        i += 6;
                    } else if (std.mem.startsWith(u8, rest, "reset")) {
                        try stdout.writeAll(COLOR_RESET);
                        i += 7;
                    } else {
                        try stdout.writeAll("%C");
                        i += 2;
                    }
                },
                'd' => {
                    // Ref decorations with wrapping: " (ref1, ref2)"
                    var dec_buf: [512]u8 = undefined;
                    const dec = formatDecorationStringWrapped(&dec_buf, commit, dmap);
                    try stdout.writeAll(dec);
                    i += 2;
                },
                'D' => {
                    // Ref decorations without wrapping: "ref1, ref2"
                    var dec_buf: [512]u8 = undefined;
                    const dec = formatDecorationStringBare(&dec_buf, commit, dmap);
                    try stdout.writeAll(dec);
                    i += 2;
                },
                '%' => {
                    try stdout.writeAll("%");
                    i += 2;
                },
                else => {
                    try stdout.writeAll("%");
                    var one: [1]u8 = .{next};
                    try stdout.writeAll(&one);
                    i += 2;
                },
            }
        } else {
            var one: [1]u8 = .{fmt_str[i]};
            try stdout.writeAll(&one);
            i += 1;
        }
    }
    try stdout.writeAll("\n");
}

// ---------------------------------------------------------------------------
// Date formatting
// ---------------------------------------------------------------------------

/// Format a timestamp according to the specified date format.
pub fn formatDate(buf: []u8, timestamp: i64, timezone: []const u8, fmt: DateFormat) []const u8 {
    switch (fmt) {
        .default => return formatDefaultDate(buf, timestamp, timezone),
        .relative => return formatRelativeDate(buf, timestamp),
        .local => return formatLocalDate(buf, timestamp),
        .iso => return formatIsoDate(buf, timestamp, timezone),
        .rfc => return formatRfcDate(buf, timestamp, timezone),
        .short_date => return formatShortDate(buf, timestamp, timezone),
        .human => return formatHumanDate(buf, timestamp, timezone),
    }
}

/// Default git date format: "Tue Mar 15 12:34:56 2022 +0100"
fn formatDefaultDate(buf: []u8, timestamp: i64, timezone: []const u8) []const u8 {
    var tz_offset_minutes: i64 = 0;
    if (timezone.len >= 5) {
        const sign: i64 = if (timezone[0] == '-') -1 else 1;
        const hours = std.fmt.parseInt(i64, timezone[1..3], 10) catch 0;
        const minutes = std.fmt.parseInt(i64, timezone[3..5], 10) catch 0;
        tz_offset_minutes = sign * (hours * 60 + minutes);
    }

    const adjusted = timestamp + tz_offset_minutes * 60;
    const dc = dateComponents(adjusted);

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{s} {s} {d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {d} {s}", .{
        dc.dow_name,
        dc.mon_name,
        dc.day,
        dc.hours,
        dc.minutes,
        dc.seconds,
        dc.year,
        timezone,
    }) catch return buf[0..0];

    return buf[0..stream.pos];
}

/// Relative date: "2 hours ago", "3 days ago", etc.
pub fn formatRelativeDate(buf: []u8, timestamp: i64) []const u8 {
    const now_ts = getCurrentTimestamp();
    const diff = now_ts - timestamp;

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    if (diff < 0) {
        writer.writeAll("in the future") catch {};
        return buf[0..stream.pos];
    }

    const udiff: u64 = @intCast(diff);

    if (udiff < 60) {
        writer.print("{d} seconds ago", .{udiff}) catch {};
    } else if (udiff < 3600) {
        const mins = udiff / 60;
        if (mins == 1) {
            writer.writeAll("1 minute ago") catch {};
        } else {
            writer.print("{d} minutes ago", .{mins}) catch {};
        }
    } else if (udiff < 86400) {
        const hrs = udiff / 3600;
        if (hrs == 1) {
            writer.writeAll("1 hour ago") catch {};
        } else {
            writer.print("{d} hours ago", .{hrs}) catch {};
        }
    } else if (udiff < 86400 * 30) {
        const days = udiff / 86400;
        if (days == 1) {
            writer.writeAll("1 day ago") catch {};
        } else {
            writer.print("{d} days ago", .{days}) catch {};
        }
    } else if (udiff < 86400 * 365) {
        const months = udiff / (86400 * 30);
        if (months == 1) {
            writer.writeAll("1 month ago") catch {};
        } else {
            writer.print("{d} months ago", .{months}) catch {};
        }
    } else {
        const years = udiff / (86400 * 365);
        if (years == 1) {
            writer.writeAll("1 year ago") catch {};
        } else {
            writer.print("{d} years ago", .{years}) catch {};
        }
    }

    return buf[0..stream.pos];
}

/// Local date (UTC, no timezone offset applied).
fn formatLocalDate(buf: []u8, timestamp: i64) []const u8 {
    const dc = dateComponents(timestamp);

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{s} {s} {d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{
        dc.dow_name,
        dc.mon_name,
        dc.day,
        dc.hours,
        dc.minutes,
        dc.seconds,
        dc.year,
    }) catch return buf[0..0];

    return buf[0..stream.pos];
}

/// ISO 8601 date: "2022-03-15 12:34:56 +0100"
fn formatIsoDate(buf: []u8, timestamp: i64, timezone: []const u8) []const u8 {
    var tz_offset_minutes: i64 = 0;
    if (timezone.len >= 5) {
        const sign: i64 = if (timezone[0] == '-') -1 else 1;
        const hours = std.fmt.parseInt(i64, timezone[1..3], 10) catch 0;
        const minutes = std.fmt.parseInt(i64, timezone[3..5], 10) catch 0;
        tz_offset_minutes = sign * (hours * 60 + minutes);
    }

    const adjusted = timestamp + tz_offset_minutes * 60;
    const dc = dateComponents(adjusted);

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{
        dc.year,
        dc.month,
        dc.day,
        dc.hours,
        dc.minutes,
        dc.seconds,
        timezone,
    }) catch return buf[0..0];

    return buf[0..stream.pos];
}

/// RFC 2822 date: "Tue, 15 Mar 2022 12:34:56 +0100"
fn formatRfcDate(buf: []u8, timestamp: i64, timezone: []const u8) []const u8 {
    var tz_offset_minutes: i64 = 0;
    if (timezone.len >= 5) {
        const sign: i64 = if (timezone[0] == '-') -1 else 1;
        const hours = std.fmt.parseInt(i64, timezone[1..3], 10) catch 0;
        const minutes = std.fmt.parseInt(i64, timezone[3..5], 10) catch 0;
        tz_offset_minutes = sign * (hours * 60 + minutes);
    }

    const adjusted = timestamp + tz_offset_minutes * 60;
    const dc = dateComponents(adjusted);

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{s}, {d} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{
        dc.dow_name,
        dc.day,
        dc.mon_name,
        dc.year,
        dc.hours,
        dc.minutes,
        dc.seconds,
        timezone,
    }) catch return buf[0..0];

    return buf[0..stream.pos];
}

/// Short date: "2022-03-15"
fn formatShortDate(buf: []u8, timestamp: i64, timezone: []const u8) []const u8 {
    var tz_offset_minutes: i64 = 0;
    if (timezone.len >= 5) {
        const sign: i64 = if (timezone[0] == '-') -1 else 1;
        const hours = std.fmt.parseInt(i64, timezone[1..3], 10) catch 0;
        const minutes = std.fmt.parseInt(i64, timezone[3..5], 10) catch 0;
        tz_offset_minutes = sign * (hours * 60 + minutes);
    }

    const adjusted = timestamp + tz_offset_minutes * 60;
    const dc = dateComponents(adjusted);

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{d}-{d:0>2}-{d:0>2}", .{ dc.year, dc.month, dc.day }) catch return buf[0..0];

    return buf[0..stream.pos];
}

/// Human-readable date: uses relative for recent, otherwise short.
fn formatHumanDate(buf: []u8, timestamp: i64, timezone: []const u8) []const u8 {
    const now_ts = getCurrentTimestamp();
    const diff = now_ts - timestamp;

    if (diff >= 0 and diff < 86400 * 7) {
        return formatRelativeDate(buf, timestamp);
    }
    return formatShortDate(buf, timestamp, timezone);
}

// ---------------------------------------------------------------------------
// Decoration formatting helpers
// ---------------------------------------------------------------------------

fn formatDecorationString(buf: []u8, commit: *log_mod.CommitInfo, dmap: ?*const DecorationMap) []const u8 {
    const dm = dmap orelse return buf[0..0];
    const deco = dm.getDecorations(&commit.oid);
    if (deco.count == 0) return buf[0..0];

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.writeAll(" (") catch return buf[0..0];
    var ci: usize = 0;
    while (ci < deco.count) : (ci += 1) {
        if (ci > 0) writer.writeAll(", ") catch {};
        writer.writeAll(COLOR_GREEN) catch {};
        writer.writeAll(deco.names[ci]) catch {};
        writer.writeAll(COLOR_RESET) catch {};
    }
    writer.writeAll(")") catch {};
    return buf[0..stream.pos];
}

fn formatDecorationStringWrapped(buf: []u8, commit: *log_mod.CommitInfo, dmap: ?*const DecorationMap) []const u8 {
    return formatDecorationString(buf, commit, dmap);
}

fn formatDecorationStringBare(buf: []u8, commit: *log_mod.CommitInfo, dmap: ?*const DecorationMap) []const u8 {
    const dm = dmap orelse return buf[0..0];
    const deco = dm.getDecorations(&commit.oid);
    if (deco.count == 0) return buf[0..0];

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    var ci: usize = 0;
    while (ci < deco.count) : (ci += 1) {
        if (ci > 0) writer.writeAll(", ") catch {};
        writer.writeAll(deco.names[ci]) catch {};
    }
    return buf[0..stream.pos];
}

// ---------------------------------------------------------------------------
// Message parsing helpers
// ---------------------------------------------------------------------------

/// Get the subject (first non-empty line) of a commit message.
fn getSubject(message: []const u8) []const u8 {
    const trimmed = std.mem.trimLeft(u8, message, "\n\r ");
    const nl = std.mem.indexOfScalar(u8, trimmed, '\n');
    if (nl) |n| {
        return std.mem.trimRight(u8, trimmed[0..n], " \r");
    }
    return std.mem.trimRight(u8, trimmed, " \r\n");
}

/// Get the body (everything after the first blank line after subject).
fn getBody(message: []const u8) []const u8 {
    const trimmed = std.mem.trimLeft(u8, message, "\n\r ");
    // Find end of subject line
    const nl = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return "";
    // Skip blank line(s) after subject
    var pos = nl + 1;
    while (pos < trimmed.len and (trimmed[pos] == '\n' or trimmed[pos] == '\r')) {
        pos += 1;
    }
    if (pos >= trimmed.len) return "";
    return std.mem.trimRight(u8, trimmed[pos..], "\n\r ");
}

// ---------------------------------------------------------------------------
// Parse format/pretty option from command line
// ---------------------------------------------------------------------------

/// Parse a --format= or --pretty= argument into LogFormatOptions.
pub fn parseFormatOption(arg: []const u8) LogFormatOptions {
    var opts = LogFormatOptions{};

    const value = if (std.mem.startsWith(u8, arg, "--format="))
        arg["--format=".len..]
    else if (std.mem.startsWith(u8, arg, "--pretty="))
        arg["--pretty=".len..]
    else
        return opts;

    if (std.mem.eql(u8, value, "oneline")) {
        opts.format_type = .oneline;
    } else if (std.mem.eql(u8, value, "short")) {
        opts.format_type = .short;
    } else if (std.mem.eql(u8, value, "medium")) {
        opts.format_type = .medium;
    } else if (std.mem.eql(u8, value, "full")) {
        opts.format_type = .full;
    } else if (std.mem.eql(u8, value, "fuller")) {
        opts.format_type = .fuller;
    } else if (std.mem.eql(u8, value, "email")) {
        opts.format_type = .email;
    } else if (std.mem.eql(u8, value, "raw")) {
        opts.format_type = .raw;
    } else if (std.mem.startsWith(u8, value, "format:")) {
        opts.format_type = .custom;
        opts.custom_format = value["format:".len..];
    } else if (std.mem.startsWith(u8, value, "tformat:")) {
        opts.format_type = .custom;
        opts.custom_format = value["tformat:".len..];
    } else {
        // Treat as custom format string directly
        opts.format_type = .custom;
        opts.custom_format = value;
    }

    return opts;
}

/// Parse a --date= argument.
pub fn parseDateOption(arg: []const u8) DateFormat {
    const value = if (std.mem.startsWith(u8, arg, "--date="))
        arg["--date=".len..]
    else
        return .default;

    if (std.mem.eql(u8, value, "relative")) return .relative;
    if (std.mem.eql(u8, value, "local")) return .local;
    if (std.mem.eql(u8, value, "iso") or std.mem.eql(u8, value, "iso8601")) return .iso;
    if (std.mem.eql(u8, value, "rfc") or std.mem.eql(u8, value, "rfc2822")) return .rfc;
    if (std.mem.eql(u8, value, "short")) return .short_date;
    if (std.mem.eql(u8, value, "human")) return .human;
    return .default;
}

// ---------------------------------------------------------------------------
// Date computation helpers
// ---------------------------------------------------------------------------

const DateComponents = struct {
    year: i64,
    month: u8,
    day: u8,
    hours: u8,
    minutes: u8,
    seconds: u8,
    dow_name: []const u8,
    mon_name: []const u8,
};

fn dateComponents(adjusted: i64) DateComponents {
    const epoch_days = @divFloor(adjusted, 86400);
    const day_seconds = @mod(adjusted, 86400);
    const hours: u8 = @intCast(@divFloor(day_seconds, 3600));
    const rem_after_hours = @mod(day_seconds, 3600);
    const minutes: u8 = @intCast(@divFloor(rem_after_hours, 60));
    const seconds: u8 = @intCast(@mod(rem_after_hours, 60));

    // Civil date from epoch days (Howard Hinnant algorithm)
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

    const dow_idx: usize = @intCast(@mod(epoch_days + 4, 7));
    const dow_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mon_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    return .{
        .year = year,
        .month = month,
        .day = day,
        .hours = hours,
        .minutes = minutes,
        .seconds = seconds,
        .dow_name = if (dow_idx < 7) dow_names[dow_idx] else "???",
        .mon_name = if (month >= 1 and month <= 12) mon_names[month - 1] else "???",
    };
}

fn getCurrentTimestamp() i64 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "getSubject" {
    try std.testing.expectEqualStrings("hello world", getSubject("hello world\nmore stuff\n"));
    try std.testing.expectEqualStrings("single", getSubject("single"));
    try std.testing.expectEqualStrings("after blank", getSubject("\n\nafter blank\n"));
}

test "getBody" {
    try std.testing.expectEqualStrings("body text", getBody("subject\n\nbody text\n"));
    try std.testing.expectEqualStrings("", getBody("subject only"));
    try std.testing.expectEqualStrings("line1\nline2", getBody("subject\n\nline1\nline2\n"));
}

test "parseFormatOption" {
    const opt1 = parseFormatOption("--format=oneline");
    try std.testing.expectEqual(FormatType.oneline, opt1.format_type);

    const opt2 = parseFormatOption("--pretty=full");
    try std.testing.expectEqual(FormatType.full, opt2.format_type);

    const opt3 = parseFormatOption("--format=format:%H %s");
    try std.testing.expectEqual(FormatType.custom, opt3.format_type);
    try std.testing.expectEqualStrings("%H %s", opt3.custom_format);
}

test "parseDateOption" {
    try std.testing.expectEqual(DateFormat.relative, parseDateOption("--date=relative"));
    try std.testing.expectEqual(DateFormat.iso, parseDateOption("--date=iso"));
    try std.testing.expectEqual(DateFormat.short_date, parseDateOption("--date=short"));
    try std.testing.expectEqual(DateFormat.default, parseDateOption("--date=unknown"));
}
