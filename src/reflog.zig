const std = @import("std");
const types = @import("types.zig");

pub const ReflogEntry = struct {
    old_oid: types.ObjectId,
    new_oid: types.ObjectId,
    name: []const u8,
    email: []const u8,
    timestamp: []const u8,
    timezone: []const u8,
    message: []const u8,
};

pub const ReflogResult = struct {
    entries: []ReflogEntry,
    /// Raw content buffer that entry string fields point into. Must be freed.
    _content: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ReflogResult) void {
        self.allocator.free(self.entries);
        self.allocator.free(self._content);
    }
};

/// Append an entry to a reflog file.
/// Format: "OLD_SHA NEW_SHA NAME <EMAIL> TIMESTAMP TIMEZONE\tMESSAGE\n"
pub fn appendReflog(
    git_dir: []const u8,
    ref_name: []const u8,
    old_oid: types.ObjectId,
    new_oid: types.ObjectId,
    message: []const u8,
) !void {
    // Build path: .git/logs/<ref_name>
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    const logs_suffix = "/logs/";
    @memcpy(path_buf[pos..][0..logs_suffix.len], logs_suffix);
    pos += logs_suffix.len;
    @memcpy(path_buf[pos..][0..ref_name.len], ref_name);
    pos += ref_name.len;
    const log_path = path_buf[0..pos];

    // Ensure parent directory exists
    const dir_end = std.mem.lastIndexOfScalar(u8, log_path, '/') orelse return error.InvalidRefName;
    mkdirRecursive(log_path[0..dir_end]) catch {};

    // Build the entry line
    const old_hex = old_oid.toHex();
    const new_hex = new_oid.toHex();

    // Get a simple timestamp
    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    // Build output
    var line_buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&line_buf);
    const writer = stream.writer();
    try writer.writeAll(&old_hex);
    try writer.writeByte(' ');
    try writer.writeAll(&new_hex);
    try writer.writeAll(" zig-git <zig-git@localhost> ");
    try writer.writeAll(timestamp);
    try writer.writeAll(" +0000\t");
    try writer.writeAll(message);
    try writer.writeByte('\n');
    const line = line_buf[0..stream.pos];

    // Append to file
    const file = std.fs.openFileAbsolute(log_path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            break :blk try std.fs.createFileAbsolute(log_path, .{});
        },
        else => return err,
    };
    defer file.close();

    // Seek to end
    const stat = try file.stat();
    try file.seekTo(stat.size);
    try file.writeAll(line);
}

/// Read all reflog entries for a given ref.
/// Caller must call deinit() on the returned ReflogResult.
pub fn readReflog(allocator: std.mem.Allocator, git_dir: []const u8, ref_name: []const u8) !ReflogResult {
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    const logs_suffix = "/logs/";
    @memcpy(path_buf[pos..][0..logs_suffix.len], logs_suffix);
    pos += logs_suffix.len;
    @memcpy(path_buf[pos..][0..ref_name.len], ref_name);
    pos += ref_name.len;
    const log_path = path_buf[0..pos];

    const content = readFileContents(allocator, log_path) catch return error.ReflogNotFound;
    errdefer allocator.free(content);

    var entries = std.array_list.Managed(ReflogEntry).init(allocator);
    defer entries.deinit();

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len < types.OID_HEX_LEN * 2 + 2) continue;

        const entry = parseReflogLine(line) catch continue;
        try entries.append(entry);
    }

    const owned_entries = try entries.toOwnedSlice();

    return ReflogResult{
        .entries = owned_entries,
        ._content = content,
        .allocator = allocator,
    };
}

fn parseReflogLine(line: []const u8) !ReflogEntry {
    if (line.len < types.OID_HEX_LEN * 2 + 2) return error.InvalidReflogEntry;

    const old_hex = line[0..types.OID_HEX_LEN];
    const new_hex = line[types.OID_HEX_LEN + 1 ..][0..types.OID_HEX_LEN];

    const old_oid = try types.ObjectId.fromHex(old_hex);
    const new_oid = try types.ObjectId.fromHex(new_hex);

    // Rest after the two SHAs + spaces
    const rest = line[types.OID_HEX_LEN * 2 + 2 ..];

    // Find tab separator for message
    const tab_pos = std.mem.indexOfScalar(u8, rest, '\t');
    const message = if (tab_pos) |tp| rest[tp + 1 ..] else "";

    // Parse identity: "NAME <EMAIL> TIMESTAMP TIMEZONE"
    const identity_part = if (tab_pos) |tp| rest[0..tp] else rest;

    // Find email in angle brackets
    const email_start = std.mem.indexOfScalar(u8, identity_part, '<') orelse return error.InvalidReflogEntry;
    const email_end = std.mem.indexOfScalar(u8, identity_part, '>') orelse return error.InvalidReflogEntry;

    const name = if (email_start > 0) identity_part[0 .. email_start - 1] else "";
    const email = identity_part[email_start + 1 .. email_end];

    // After "> " comes "TIMESTAMP TIMEZONE"
    var ts_part = identity_part[email_end + 1 ..];
    if (ts_part.len > 0 and ts_part[0] == ' ') ts_part = ts_part[1..];

    const space_pos = std.mem.indexOfScalar(u8, ts_part, ' ');
    const timestamp = if (space_pos) |sp| ts_part[0..sp] else ts_part;
    const timezone = if (space_pos) |sp| ts_part[sp + 1 ..] else "";

    return ReflogEntry{
        .old_oid = old_oid,
        .new_oid = new_oid,
        .name = name,
        .email = email,
        .timestamp = timestamp,
        .timezone = timezone,
        .message = message,
    };
}

fn getTimestamp(buf: []u8) []const u8 {
    // Use posix clock to get seconds since epoch
    const ts = std.posix.clock_gettime(.REALTIME) catch return "0";
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{d}", .{ts.sec}) catch return "0";
    return buf[0..stream.pos];
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

fn mkdirRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
            try mkdirRecursive(parent);
            std.fs.makeDirAbsolute(path) catch |err2| switch (err2) {
                error.PathAlreadyExists => return,
                else => return err2,
            };
        },
        else => return err,
    };
}
