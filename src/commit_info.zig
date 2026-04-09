const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");

/// Parsed author/committer information.
pub const Author = struct {
    name: []const u8,
    email: []const u8,
    timestamp: i64,
    timezone: []const u8,
};

/// Full commit information extracted from a commit object.
pub const CommitInfo = struct {
    tree: types.ObjectId,
    parents: std.array_list.Managed(types.ObjectId),
    author: Author,
    committer: Author,
    message: []const u8,
    gpgsig: ?[]const u8,
    /// Backing data for all string slices.
    raw_data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CommitInfo) void {
        self.parents.deinit();
        self.allocator.free(self.raw_data);
    }
};

/// Parse all fields from a commit object's raw data.
/// The caller must have read the object; `data` is the raw commit content (after the header).
/// Ownership of `data` is transferred to the returned CommitInfo.
pub fn parseCommitFull(allocator: std.mem.Allocator, data: []u8) !CommitInfo {
    var info = CommitInfo{
        .tree = types.ObjectId.ZERO,
        .parents = std.array_list.Managed(types.ObjectId).init(allocator),
        .author = .{ .name = "", .email = "", .timestamp = 0, .timezone = "" },
        .committer = .{ .name = "", .email = "", .timestamp = 0, .timezone = "" },
        .message = "",
        .gpgsig = null,
        .raw_data = data,
        .allocator = allocator,
    };
    errdefer {
        info.parents.deinit();
        allocator.free(data);
    }

    var pos: usize = 0;
    var in_gpgsig = false;
    var gpgsig_start: usize = 0;
    var gpgsig_end: usize = 0;

    while (pos < data.len) {
        const line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        const line = data[pos..line_end];

        if (in_gpgsig) {
            if (std.mem.startsWith(u8, line, " -----END PGP SIGNATURE-----") or
                std.mem.startsWith(u8, line, " -----END SSH SIGNATURE-----"))
            {
                gpgsig_end = line_end;
                in_gpgsig = false;
                info.gpgsig = data[gpgsig_start..gpgsig_end];
            }
            pos = line_end + 1;
            continue;
        }

        if (line.len == 0) {
            // End of headers, rest is message
            pos = line_end + 1;
            info.message = if (pos < data.len) data[pos..] else "";
            break;
        }

        if (std.mem.startsWith(u8, line, "tree ")) {
            if (line.len >= 5 + types.OID_HEX_LEN) {
                info.tree = types.ObjectId.fromHex(line[5..][0..types.OID_HEX_LEN]) catch types.ObjectId.ZERO;
            }
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            if (line.len >= 7 + types.OID_HEX_LEN) {
                const parent_oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch {
                    pos = line_end + 1;
                    continue;
                };
                try info.parents.append(parent_oid);
            }
        } else if (std.mem.startsWith(u8, line, "author ")) {
            info.author = parseAuthor(line[7..]);
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            info.committer = parseAuthor(line[10..]);
        } else if (std.mem.startsWith(u8, line, "gpgsig ")) {
            gpgsig_start = pos + 7; // after "gpgsig "
            in_gpgsig = true;
        }

        pos = line_end + 1;
    }

    return info;
}

/// Parse an author/committer line: "Name <email> timestamp timezone"
pub fn parseAuthor(line: []const u8) Author {
    var result = Author{ .name = "", .email = "", .timestamp = 0, .timezone = "" };

    const lt_pos = std.mem.indexOfScalar(u8, line, '<') orelse return result;
    const gt_pos = std.mem.indexOfScalar(u8, line, '>') orelse return result;

    if (lt_pos > 0) {
        result.name = std.mem.trimRight(u8, line[0 .. lt_pos - 1], " ");
    }

    if (gt_pos > lt_pos + 1) {
        result.email = line[lt_pos + 1 .. gt_pos];
    }

    if (gt_pos + 2 < line.len) {
        const after = line[gt_pos + 2 ..];
        const space_pos = std.mem.indexOfScalar(u8, after, ' ');
        if (space_pos) |sp| {
            result.timestamp = std.fmt.parseInt(i64, after[0..sp], 10) catch 0;
            if (sp + 1 < after.len) {
                result.timezone = after[sp + 1 ..];
            }
        } else {
            result.timestamp = std.fmt.parseInt(i64, after, 10) catch 0;
        }
    }

    return result;
}

/// Format an author date in the given style.
/// Supported styles: "default", "iso", "short", "raw", "unix", "relative".
pub fn formatAuthorDate(author: Author, style: []const u8, buf: *[128]u8) []const u8 {
    if (std.mem.eql(u8, style, "raw") or std.mem.eql(u8, style, "unix")) {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();
        if (std.mem.eql(u8, style, "raw")) {
            writer.print("{d} {s}", .{ author.timestamp, author.timezone }) catch {};
        } else {
            writer.print("{d}", .{author.timestamp}) catch {};
        }
        return buf[0..stream.pos];
    }

    if (std.mem.eql(u8, style, "short")) {
        return formatDateShort(author.timestamp, author.timezone, buf);
    }

    if (std.mem.eql(u8, style, "iso")) {
        return formatDateIso(author.timestamp, author.timezone, buf);
    }

    // default
    return formatDateDefault(author.timestamp, author.timezone, buf);
}

/// Get the first line (subject) of a commit message.
pub fn getCommitSubject(message: []const u8) []const u8 {
    const trimmed = std.mem.trimLeft(u8, message, "\n\r ");
    const nl = std.mem.indexOfScalar(u8, trimmed, '\n');
    if (nl) |n| {
        return std.mem.trimRight(u8, trimmed[0..n], " \r");
    }
    return std.mem.trimRight(u8, trimmed, " \r\n");
}

/// Get the body of a commit message (everything after the first blank line following the subject).
pub fn getCommitBody(message: []const u8) []const u8 {
    const trimmed = std.mem.trimLeft(u8, message, "\n\r ");
    // Find the end of the subject line
    const first_nl = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return "";
    // Find the blank line separator
    const rest = trimmed[first_nl + 1 ..];
    if (rest.len == 0) return "";
    if (rest[0] == '\n') {
        return if (rest.len > 1) rest[1..] else "";
    }
    // No blank line separator => no body
    return "";
}

/// Check if a commit object has a GPG/SSH signature.
pub fn isSignedCommit(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "-----BEGIN PGP SIGNATURE-----") != null or
        std.mem.indexOf(u8, data, "-----BEGIN SSH SIGNATURE-----") != null;
}

/// Extract the GPG signature block from commit data, if present.
pub fn extractSignature(data: []const u8) ?[]const u8 {
    const begin_pgp = "-----BEGIN PGP SIGNATURE-----";
    const end_pgp = "-----END PGP SIGNATURE-----";
    const begin_ssh = "-----BEGIN SSH SIGNATURE-----";
    const end_ssh = "-----END SSH SIGNATURE-----";

    if (std.mem.indexOf(u8, data, begin_pgp)) |start| {
        if (std.mem.indexOfPos(u8, data, start, end_pgp)) |end| {
            return data[start .. end + end_pgp.len];
        }
    }
    if (std.mem.indexOf(u8, data, begin_ssh)) |start| {
        if (std.mem.indexOfPos(u8, data, start, end_ssh)) |end| {
            return data[start .. end + end_ssh.len];
        }
    }
    return null;
}

/// Strip the signature from commit data, returning the signed payload.
pub fn stripSignature(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Find "gpgsig " header and remove it plus continuation lines
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var in_sig = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            try result.append('\n');
        }
        first = false;

        if (in_sig) {
            // Continuation lines start with space
            if (line.len > 0 and line[0] == ' ') {
                if (std.mem.indexOf(u8, line, "-----END PGP SIGNATURE-----") != null or
                    std.mem.indexOf(u8, line, "-----END SSH SIGNATURE-----") != null)
                {
                    in_sig = false;
                }
                continue;
            } else {
                in_sig = false;
                try result.appendSlice(line);
            }
        } else if (std.mem.startsWith(u8, line, "gpgsig ")) {
            in_sig = true;
            continue;
        } else {
            try result.appendSlice(line);
        }
    }

    return result.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Date formatting helpers
// ---------------------------------------------------------------------------

const DateComponents = struct {
    year: i64,
    month: u8,
    day: u8,
    hours: u8,
    minutes: u8,
    seconds: u8,
    dow_idx: usize,
};

fn timestampToComponents(timestamp: i64, timezone: []const u8) DateComponents {
    var tz_offset_minutes: i64 = 0;
    if (timezone.len >= 5) {
        const sign: i64 = if (timezone[0] == '-') -1 else 1;
        const h = std.fmt.parseInt(i64, timezone[1..3], 10) catch 0;
        const m = std.fmt.parseInt(i64, timezone[3..5], 10) catch 0;
        tz_offset_minutes = sign * (h * 60 + m);
    }

    const adjusted = timestamp + tz_offset_minutes * 60;
    const epoch_days = @divFloor(adjusted, 86400);
    const day_seconds = @mod(adjusted, 86400);

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

    return .{
        .year = year,
        .month = @intCast(m_raw),
        .day = @intCast(d),
        .hours = @intCast(@divFloor(day_seconds, 3600)),
        .minutes = @intCast(@divFloor(@mod(day_seconds, 3600), 60)),
        .seconds = @intCast(@mod(day_seconds, 60)),
        .dow_idx = @intCast(@mod(epoch_days + 4, 7)),
    };
}

fn formatDateDefault(timestamp: i64, timezone: []const u8, buf: *[128]u8) []const u8 {
    const c = timestampToComponents(timestamp, timezone);
    const dow_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mon_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const dow = if (c.dow_idx < 7) dow_names[c.dow_idx] else "???";
    const mon = if (c.month >= 1 and c.month <= 12) mon_names[c.month - 1] else "???";

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{s} {s} {d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {d} {s}", .{
        dow, mon, c.day, c.hours, c.minutes, c.seconds, c.year, timezone,
    }) catch {};
    return buf[0..stream.pos];
}

fn formatDateShort(timestamp: i64, timezone: []const u8, buf: *[128]u8) []const u8 {
    const c = timestampToComponents(timestamp, timezone);
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{d}-{d:0>2}-{d:0>2}", .{ c.year, c.month, c.day }) catch {};
    return buf[0..stream.pos];
}

fn formatDateIso(timestamp: i64, timezone: []const u8, buf: *[128]u8) []const u8 {
    const c = timestampToComponents(timestamp, timezone);
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{
        c.year, c.month, c.day, c.hours, c.minutes, c.seconds, timezone,
    }) catch {};
    return buf[0..stream.pos];
}

/// Parse a date string like "2024-01-15" or "2024-01-15T10:30:00" to a Unix timestamp.
/// Returns 0 on parse failure.
pub fn parseDateToTimestamp(date_str: []const u8) i64 {
    // Try "YYYY-MM-DD" format
    if (date_str.len >= 10 and date_str[4] == '-' and date_str[7] == '-') {
        const year = std.fmt.parseInt(i64, date_str[0..4], 10) catch return 0;
        const month = std.fmt.parseInt(i64, date_str[5..7], 10) catch return 0;
        const day = std.fmt.parseInt(i64, date_str[8..10], 10) catch return 0;

        // Simple conversion: days since epoch
        var y = year;
        var m = month;
        if (m <= 2) {
            y -= 1;
            m += 12;
        }
        const era = @divFloor(if (y >= 0) y else y - 399, 400);
        const yoe = y - era * 400;
        const doy = @divFloor(153 * (m - 3) + 2, 5) + day - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        const epoch_days = era * 146097 + doe - 719468;

        return epoch_days * 86400;
    }

    // Try plain unix timestamp
    return std.fmt.parseInt(i64, date_str, 10) catch 0;
}

test "getCommitSubject" {
    try std.testing.expectEqualStrings("hello world", getCommitSubject("hello world\nmore stuff\n"));
    try std.testing.expectEqualStrings("single", getCommitSubject("single"));
    try std.testing.expectEqualStrings("after blank", getCommitSubject("\n\nafter blank\n"));
}

test "getCommitBody" {
    try std.testing.expectEqualStrings("body text\n", getCommitBody("subject\n\nbody text\n"));
    try std.testing.expectEqualStrings("", getCommitBody("subject only\n"));
    try std.testing.expectEqualStrings("", getCommitBody("subject\n"));
}

test "parseAuthor" {
    const a = parseAuthor("John Doe <john@example.com> 1678901234 +0100");
    try std.testing.expectEqualStrings("John Doe", a.name);
    try std.testing.expectEqualStrings("john@example.com", a.email);
    try std.testing.expectEqual(@as(i64, 1678901234), a.timestamp);
    try std.testing.expectEqualStrings("+0100", a.timezone);
}

test "isSignedCommit" {
    try std.testing.expect(isSignedCommit("gpgsig -----BEGIN PGP SIGNATURE-----\nabc\n-----END PGP SIGNATURE-----\n"));
    try std.testing.expect(!isSignedCommit("tree abc\nparent def\n"));
}

test "parseDateToTimestamp" {
    // 2024-01-01 should be a positive timestamp
    const ts = parseDateToTimestamp("2024-01-01");
    try std.testing.expect(ts > 0);
}
