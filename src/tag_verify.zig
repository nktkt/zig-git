const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const ref_mod = @import("ref.zig");
const loose = @import("loose.zig");
const config_mod = @import("config.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const COLOR_YELLOW = "\x1b[33m";
const COLOR_GREEN = "\x1b[32m";
const COLOR_RED = "\x1b[31m";
const COLOR_RESET = "\x1b[0m";
const COLOR_BOLD = "\x1b[1m";

/// Parsed annotated tag object.
pub const AnnotatedTag = struct {
    object_oid: types.ObjectId,
    obj_type: []const u8,
    tag_name: []const u8,
    tagger_name: []const u8,
    tagger_email: []const u8,
    tagger_timestamp: i64,
    tagger_timezone: []const u8,
    message: []const u8,
    has_signature: bool,
    signature: []const u8,
    raw_data: []u8,

    pub fn deinit(self: *AnnotatedTag, allocator: std.mem.Allocator) void {
        allocator.free(self.raw_data);
    }
};

/// Version tag for sorting.
pub const VersionTag = struct {
    name: []const u8,
    major: u32,
    minor: u32,
    patch: u32,
    has_version: bool,
};

/// Sort mode for tag listing.
pub const TagSortMode = enum {
    alpha,
    version,
    creation_date,
};

// ---------------------------------------------------------------------------
// Create annotated tag
// ---------------------------------------------------------------------------

/// Create an annotated tag object and its ref.
pub fn createAnnotatedTag(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    name: []const u8,
    target_ref: ?[]const u8,
    message: []const u8,
) !types.ObjectId {
    const target_oid = if (target_ref) |tr|
        try repo.resolveRef(allocator, tr)
    else
        try repo.resolveRef(allocator, "HEAD");

    var content = std.array_list.Managed(u8).init(allocator);
    defer content.deinit();

    const target_hex = target_oid.toHex();
    try content.appendSlice("object ");
    try content.appendSlice(&target_hex);
    try content.append('\n');

    try content.appendSlice("type commit\n");

    try content.appendSlice("tag ");
    try content.appendSlice(name);
    try content.append('\n');

    // Tagger info
    var tagger_name: []const u8 = "zig-git";
    var tagger_email: []const u8 = "zig-git@localhost";
    getUserInfo(allocator, repo, &tagger_name, &tagger_email);

    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    try content.appendSlice("tagger ");
    try content.appendSlice(tagger_name);
    try content.appendSlice(" <");
    try content.appendSlice(tagger_email);
    try content.appendSlice("> ");
    try content.appendSlice(timestamp);
    try content.appendSlice(" +0000\n");

    try content.append('\n');
    try content.appendSlice(message);
    if (message.len == 0 or message[message.len - 1] != '\n') {
        try content.append('\n');
    }

    // Write as tag object
    const tag_oid = try loose.writeLooseObject(allocator, repo.git_dir, .tag, content.items);

    // Create the ref
    const ref_prefix = "refs/tags/";
    var ref_name_buf: [512]u8 = undefined;
    @memcpy(ref_name_buf[0..ref_prefix.len], ref_prefix);
    @memcpy(ref_name_buf[ref_prefix.len..][0..name.len], name);
    const ref_name = ref_name_buf[0 .. ref_prefix.len + name.len];

    try ref_mod.createRef(allocator, repo.git_dir, ref_name, tag_oid, null);

    return tag_oid;
}

// ---------------------------------------------------------------------------
// Parse annotated tag
// ---------------------------------------------------------------------------

/// Parse an annotated tag object from raw data.
pub fn parseAnnotatedTag(data: []u8) AnnotatedTag {
    var tag = AnnotatedTag{
        .object_oid = types.ObjectId.ZERO,
        .obj_type = "",
        .tag_name = "",
        .tagger_name = "",
        .tagger_email = "",
        .tagger_timestamp = 0,
        .tagger_timezone = "",
        .message = "",
        .has_signature = false,
        .signature = "",
        .raw_data = data,
    };

    var pos: usize = 0;
    while (pos < data.len) {
        const line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        const line = data[pos..line_end];
        pos = line_end + 1;

        if (line.len == 0) {
            if (pos < data.len) {
                const rest = data[pos..];
                if (std.mem.indexOf(u8, rest, "-----BEGIN PGP SIGNATURE-----")) |sig_start| {
                    tag.message = rest[0..sig_start];
                    tag.has_signature = true;
                    tag.signature = rest[sig_start..];
                } else {
                    tag.message = rest;
                }
            }
            break;
        }

        if (std.mem.startsWith(u8, line, "object ") and line.len >= 7 + types.OID_HEX_LEN) {
            tag.object_oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch types.ObjectId.ZERO;
        } else if (std.mem.startsWith(u8, line, "type ")) {
            tag.obj_type = line[5..];
        } else if (std.mem.startsWith(u8, line, "tag ")) {
            tag.tag_name = line[4..];
        } else if (std.mem.startsWith(u8, line, "tagger ")) {
            parseTaggerLine(line[7..], &tag.tagger_name, &tag.tagger_email, &tag.tagger_timestamp, &tag.tagger_timezone);
        }
    }

    return tag;
}

fn parseTaggerLine(
    line: []const u8,
    name_out: *[]const u8,
    email_out: *[]const u8,
    timestamp_out: *i64,
    timezone_out: *[]const u8,
) void {
    const lt_pos = std.mem.indexOfScalar(u8, line, '<') orelse return;
    const gt_pos = std.mem.indexOfScalar(u8, line, '>') orelse return;

    if (lt_pos > 0) {
        name_out.* = std.mem.trimRight(u8, line[0 .. lt_pos - 1], " ");
    }
    if (gt_pos > lt_pos + 1) {
        email_out.* = line[lt_pos + 1 .. gt_pos];
    }
    if (gt_pos + 2 < line.len) {
        const after = line[gt_pos + 2 ..];
        const space_pos = std.mem.indexOfScalar(u8, after, ' ');
        if (space_pos) |sp| {
            timestamp_out.* = std.fmt.parseInt(i64, after[0..sp], 10) catch 0;
            if (sp + 1 < after.len) timezone_out.* = after[sp + 1 ..];
        } else {
            timestamp_out.* = std.fmt.parseInt(i64, after, 10) catch 0;
        }
    }
}

// ---------------------------------------------------------------------------
// Verify tag
// ---------------------------------------------------------------------------

/// Verify a tag signature (stub: checks if signature is present).
pub fn verifyTag(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    tag_name: []const u8,
) !void {
    const ref_prefix = "refs/tags/";
    var ref_name_buf: [512]u8 = undefined;
    @memcpy(ref_name_buf[0..ref_prefix.len], ref_prefix);
    @memcpy(ref_name_buf[ref_prefix.len..][0..tag_name.len], tag_name);
    const ref_name = ref_name_buf[0 .. ref_prefix.len + tag_name.len];

    const tag_oid = ref_mod.readRef(allocator, repo.git_dir, ref_name) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: tag '{s}' not found\n", .{tag_name}) catch "error: tag not found\n";
        try stderr_file.writeAll(msg);
        return error.TagNotFound;
    };

    var obj = try repo.readObject(allocator, &tag_oid);

    if (obj.obj_type != .tag) {
        obj.deinit();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: {s}: cannot verify a non-tag object\n", .{tag_name}) catch "error: cannot verify a non-tag object\n";
        try stderr_file.writeAll(msg);
        return error.NotAnAnnotatedTag;
    }

    var tag = parseAnnotatedTag(obj.data);
    defer tag.deinit(allocator);

    if (tag.has_signature) {
        try stdout_file.writeAll("gpg: Signature found\n");
        try stdout_file.writeAll("gpg: WARNING: Signature verification not implemented (stub)\n");
        try stdout_file.writeAll("gpg: Assuming good signature\n");

        var buf: [512]u8 = undefined;
        var msg = std.fmt.bufPrint(&buf, "tag {s}\n", .{tag.tag_name}) catch return;
        try stdout_file.writeAll(msg);
        msg = std.fmt.bufPrint(&buf, "tagger {s} <{s}>\n", .{ tag.tagger_name, tag.tagger_email }) catch return;
        try stdout_file.writeAll(msg);

        try stdout_file.writeAll("\n");
        const trimmed = std.mem.trimRight(u8, tag.message, "\n\r ");
        try stdout_file.writeAll(trimmed);
        try stdout_file.writeAll("\n");
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: no signature found in tag '{s}'\n", .{tag_name}) catch "error: no signature found\n";
        try stderr_file.writeAll(msg);
    }
}

// ---------------------------------------------------------------------------
// Tag listing with sort and filter
// ---------------------------------------------------------------------------

const TagInfo = struct {
    name: []const u8,
    oid: types.ObjectId,
    version: VersionTag,
};

/// List tags with sorting and optional pattern filter.
pub fn listTagsSorted(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    sort_mode: TagSortMode,
    pattern: ?[]const u8,
    format_str: ?[]const u8,
) !void {
    const entries = try ref_mod.listRefs(allocator, repo.git_dir, "refs/tags/");
    defer ref_mod.freeRefEntries(allocator, entries);

    var tag_infos = std.array_list.Managed(TagInfo).init(allocator);
    defer tag_infos.deinit();

    const prefix_str = "refs/tags/";
    for (entries) |entry| {
        const tag_name = if (std.mem.startsWith(u8, entry.name, prefix_str))
            entry.name[prefix_str.len..]
        else
            entry.name;

        if (pattern) |p| {
            if (!matchGlob(p, tag_name)) continue;
        }

        const ver = parseVersion(tag_name);
        try tag_infos.append(.{ .name = tag_name, .oid = entry.oid, .version = ver });
    }

    switch (sort_mode) {
        .alpha => {
            std.mem.sort(TagInfo, tag_infos.items, {}, struct {
                fn lt(_: void, a: TagInfo, b: TagInfo) bool {
                    return std.mem.order(u8, a.name, b.name) == .lt;
                }
            }.lt);
        },
        .version => {
            std.mem.sort(TagInfo, tag_infos.items, {}, struct {
                fn lt(_: void, a: TagInfo, b: TagInfo) bool {
                    return versionLessThan(a.version, b.version);
                }
            }.lt);
        },
        .creation_date => {
            // Already in ref order
        },
    }

    for (tag_infos.items) |*info| {
        if (format_str) |fmt| {
            try formatTagOutput(info, fmt);
        } else {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}\n", .{info.name}) catch continue;
            try stdout_file.writeAll(msg);
        }
    }
}

fn formatTagOutput(info: *const TagInfo, format: []const u8) !void {
    var output_buf: [4096]u8 = undefined;
    var out_pos: usize = 0;

    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '%' and i + 1 < format.len) {
            const rest = format[i + 1 ..];
            if (std.mem.startsWith(u8, rest, "(refname:short)")) {
                const nlen = info.name.len;
                if (out_pos + nlen < output_buf.len) {
                    @memcpy(output_buf[out_pos..][0..nlen], info.name);
                    out_pos += nlen;
                }
                i += "%(refname:short)".len;
                continue;
            } else if (std.mem.startsWith(u8, rest, "(refname)")) {
                const nlen = info.name.len;
                if (out_pos + nlen < output_buf.len) {
                    @memcpy(output_buf[out_pos..][0..nlen], info.name);
                    out_pos += nlen;
                }
                i += "%(refname)".len;
                continue;
            } else if (std.mem.startsWith(u8, rest, "(objectname:short)")) {
                const hex = info.oid.toHex();
                if (out_pos + 7 < output_buf.len) {
                    @memcpy(output_buf[out_pos..][0..7], hex[0..7]);
                    out_pos += 7;
                }
                i += "%(objectname:short)".len;
                continue;
            } else if (std.mem.startsWith(u8, rest, "(objectname)")) {
                const hex = info.oid.toHex();
                if (out_pos + types.OID_HEX_LEN < output_buf.len) {
                    @memcpy(output_buf[out_pos..][0..types.OID_HEX_LEN], &hex);
                    out_pos += types.OID_HEX_LEN;
                }
                i += "%(objectname)".len;
                continue;
            }
        }
        if (out_pos < output_buf.len) {
            output_buf[out_pos] = format[i];
            out_pos += 1;
        }
        i += 1;
    }

    if (out_pos > 0) try stdout_file.writeAll(output_buf[0..out_pos]);
    try stdout_file.writeAll("\n");
}

// ---------------------------------------------------------------------------
// Tag --contains and --merged
// ---------------------------------------------------------------------------

/// List tags that contain a given commit.
pub fn listTagsContaining(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    commit_ref: []const u8,
) !void {
    const target_oid = try repo.resolveRef(allocator, commit_ref);

    const entries = try ref_mod.listRefs(allocator, repo.git_dir, "refs/tags/");
    defer ref_mod.freeRefEntries(allocator, entries);

    const prefix_str = "refs/tags/";
    for (entries) |entry| {
        if (isAncestorOf(allocator, repo, &target_oid, &entry.oid)) {
            const tag_name = if (std.mem.startsWith(u8, entry.name, prefix_str))
                entry.name[prefix_str.len..]
            else
                entry.name;
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}\n", .{tag_name}) catch continue;
            try stdout_file.writeAll(msg);
        }
    }
}

/// List tags merged into a given commit.
pub fn listTagsMerged(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    commit_ref: []const u8,
) !void {
    const target_oid = try repo.resolveRef(allocator, commit_ref);

    const entries = try ref_mod.listRefs(allocator, repo.git_dir, "refs/tags/");
    defer ref_mod.freeRefEntries(allocator, entries);

    const prefix_str = "refs/tags/";
    for (entries) |entry| {
        if (isAncestorOf(allocator, repo, &entry.oid, &target_oid)) {
            const tag_name = if (std.mem.startsWith(u8, entry.name, prefix_str))
                entry.name[prefix_str.len..]
            else
                entry.name;
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}\n", .{tag_name}) catch continue;
            try stdout_file.writeAll(msg);
        }
    }
}

fn isAncestorOf(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    ancestor_oid: *const types.ObjectId,
    descendant_oid: *const types.ObjectId,
) bool {
    if (ancestor_oid.eql(descendant_oid)) return true;

    // Dereference tag objects to their target commits
    var actual_desc = descendant_oid.*;
    var tag_obj_holder: ?types.Object = null;
    defer if (tag_obj_holder) |*o| o.deinit();

    if (repo.readObject(allocator, descendant_oid)) |obj| {
        if (obj.obj_type == .tag) {
            // Parse tag to get target
            if (std.mem.indexOf(u8, obj.data, "\n")) |nl| {
                const first_line = obj.data[0..nl];
                if (std.mem.startsWith(u8, first_line, "object ") and first_line.len >= 7 + types.OID_HEX_LEN) {
                    actual_desc = types.ObjectId.fromHex(first_line[7..][0..types.OID_HEX_LEN]) catch descendant_oid.*;
                }
            }
            tag_obj_holder = obj;
        } else {
            obj.allocator.free(obj.data);
        }
    } else |_| {}

    const OidKey = [types.OID_RAW_LEN]u8;
    var visited = std.AutoHashMap(OidKey, void).init(allocator);
    defer visited.deinit();

    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();

    queue.append(actual_desc) catch return false;
    visited.put(actual_desc.bytes, {}) catch return false;

    var iterations: usize = 0;
    while (queue.items.len > 0 and iterations < 10000) {
        iterations += 1;
        const current = queue.orderedRemove(0);

        var obj = repo.readObject(allocator, &current) catch continue;
        defer obj.deinit();

        if (obj.obj_type != .commit) continue;

        var pos: usize = 0;
        while (pos < obj.data.len) {
            const line_end = std.mem.indexOfScalarPos(u8, obj.data, pos, '\n') orelse break;
            const line = obj.data[pos..line_end];
            pos = line_end + 1;
            if (line.len == 0) break;

            if (std.mem.startsWith(u8, line, "parent ") and line.len >= 7 + types.OID_HEX_LEN) {
                const parent_oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch continue;
                if (parent_oid.eql(ancestor_oid)) return true;
                if (!visited.contains(parent_oid.bytes)) {
                    visited.put(parent_oid.bytes, {}) catch continue;
                    queue.append(parent_oid) catch continue;
                }
            }
        }
    }

    return false;
}

// ---------------------------------------------------------------------------
// Version parsing and sorting
// ---------------------------------------------------------------------------

pub fn parseVersion(name: []const u8) VersionTag {
    var ver = VersionTag{
        .name = name,
        .major = 0,
        .minor = 0,
        .patch = 0,
        .has_version = false,
    };

    var s = name;
    if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];

    const dot1 = std.mem.indexOfScalar(u8, s, '.') orelse {
        ver.major = std.fmt.parseInt(u32, s, 10) catch return ver;
        ver.has_version = true;
        return ver;
    };

    ver.major = std.fmt.parseInt(u32, s[0..dot1], 10) catch return ver;

    const rest = s[dot1 + 1 ..];
    const dot2 = std.mem.indexOfScalar(u8, rest, '.') orelse {
        ver.minor = std.fmt.parseInt(u32, rest, 10) catch {
            ver.has_version = true;
            return ver;
        };
        ver.has_version = true;
        return ver;
    };

    ver.minor = std.fmt.parseInt(u32, rest[0..dot2], 10) catch {
        ver.has_version = true;
        return ver;
    };

    const patch_str = rest[dot2 + 1 ..];
    var end: usize = 0;
    while (end < patch_str.len and patch_str[end] >= '0' and patch_str[end] <= '9') end += 1;
    if (end > 0) {
        ver.patch = std.fmt.parseInt(u32, patch_str[0..end], 10) catch 0;
    }
    ver.has_version = true;
    return ver;
}

fn versionLessThan(a: VersionTag, b: VersionTag) bool {
    if (a.has_version and !b.has_version) return true;
    if (!a.has_version and b.has_version) return false;
    if (!a.has_version and !b.has_version) return std.mem.order(u8, a.name, b.name) == .lt;
    if (a.major != b.major) return a.major < b.major;
    if (a.minor != b.minor) return a.minor < b.minor;
    if (a.patch != b.patch) return a.patch < b.patch;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

// ---------------------------------------------------------------------------
// Glob matching (simplified)
// ---------------------------------------------------------------------------

fn matchGlob(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == text[ti] or pattern[pi] == '?')) {
            pi += 1;
            ti += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (star_pi != null) {
            pi = star_pi.? + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getTimestamp(buf: []u8) []const u8 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return "0";
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{d}", .{ts.sec}) catch return "0";
    return buf[0..stream.pos];
}

fn getUserInfo(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    name: *[]const u8,
    email: *[]const u8,
) void {
    var config_path_buf: [4096]u8 = undefined;
    @memcpy(config_path_buf[0..repo.git_dir.len], repo.git_dir);
    const suffix = "/config";
    @memcpy(config_path_buf[repo.git_dir.len..][0..suffix.len], suffix);
    const config_path = config_path_buf[0 .. repo.git_dir.len + suffix.len];

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch return;
    defer cfg.deinit();

    if (cfg.get("user.name")) |n| name.* = n;
    if (cfg.get("user.email")) |e| email.* = e;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseVersion" {
    const v1 = parseVersion("v1.2.3");
    try std.testing.expect(v1.has_version);
    try std.testing.expectEqual(@as(u32, 1), v1.major);
    try std.testing.expectEqual(@as(u32, 2), v1.minor);
    try std.testing.expectEqual(@as(u32, 3), v1.patch);

    const v2 = parseVersion("2.0");
    try std.testing.expect(v2.has_version);
    try std.testing.expectEqual(@as(u32, 2), v2.major);
    try std.testing.expectEqual(@as(u32, 0), v2.minor);
}

test "versionLessThan" {
    const v1 = parseVersion("v1.0.0");
    const v2 = parseVersion("v1.0.1");
    const v3 = parseVersion("v2.0.0");

    try std.testing.expect(versionLessThan(v1, v2));
    try std.testing.expect(versionLessThan(v2, v3));
    try std.testing.expect(!versionLessThan(v3, v1));
}

test "matchGlob" {
    try std.testing.expect(matchGlob("v*", "v1.0"));
    try std.testing.expect(matchGlob("v1.*", "v1.2.3"));
    try std.testing.expect(!matchGlob("v2.*", "v1.2.3"));
    try std.testing.expect(matchGlob("*", "anything"));
}
