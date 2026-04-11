const std = @import("std");
const types = @import("types.zig");

pub const RefEntry = struct {
    name: []const u8,
    oid: types.ObjectId,
};

/// List all refs under a given prefix (e.g. "refs/heads/", "refs/tags/").
/// Returns a sorted list of {name, oid} pairs.
/// Caller owns the returned slice and all strings in it.
pub fn listRefs(allocator: std.mem.Allocator, git_dir: []const u8, prefix: []const u8) ![]RefEntry {
    var entries = std.array_list.Managed(RefEntry).init(allocator);
    defer {
        // Free any names still owned by entries that were not moved to deduped
        // (all names are freed either here via deinit or transferred to deduped)
        entries.deinit();
    }
    errdefer {
        for (entries.items) |e| allocator.free(@constCast(e.name));
    }

    // Scan loose refs
    try scanLooseRefs(allocator, git_dir, prefix, &entries);

    // Parse packed-refs
    try scanPackedRefs(allocator, git_dir, prefix, &entries);

    // Sort by name
    std.mem.sort(RefEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: RefEntry, b: RefEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    // Deduplicate (loose refs take priority over packed refs - they come first since we added them first,
    // but after sorting we just keep the first occurrence of each name)
    var deduped = std.array_list.Managed(RefEntry).init(allocator);
    errdefer {
        for (deduped.items) |e| allocator.free(@constCast(e.name));
        deduped.deinit();
    }

    for (entries.items, 0..) |entry, i| {
        if (i > 0 and std.mem.eql(u8, entry.name, entries.items[i - 1].name)) {
            // Duplicate - free the second one (packed ref)
            allocator.free(@constCast(entry.name));
            continue;
        }
        try deduped.append(entry);
    }

    return deduped.toOwnedSlice();
}

pub fn freeRefEntries(allocator: std.mem.Allocator, entries: []RefEntry) void {
    for (entries) |e| {
        allocator.free(@constCast(e.name));
    }
    allocator.free(entries);
}

fn scanLooseRefs(allocator: std.mem.Allocator, git_dir: []const u8, prefix: []const u8, entries: *std.array_list.Managed(RefEntry)) !void {
    var path_buf: [4096]u8 = undefined;
    const total_len = git_dir.len + 1 + prefix.len;
    if (total_len > path_buf.len) return;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    path_buf[pos] = '/';
    pos += 1;
    @memcpy(path_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    // Remove trailing slash for dir open
    if (pos > 0 and path_buf[pos - 1] == '/') {
        pos -= 1;
    }
    const dir_path = path_buf[0..pos];

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            // Recurse into subdirectory
            var sub_prefix_buf: [1024]u8 = undefined;
            @memcpy(sub_prefix_buf[0..prefix.len], prefix);
            @memcpy(sub_prefix_buf[prefix.len..][0..entry.name.len], entry.name);
            const next = prefix.len + entry.name.len;
            sub_prefix_buf[next] = '/';
            const sub_prefix = sub_prefix_buf[0 .. next + 1];
            try scanLooseRefs(allocator, git_dir, sub_prefix, entries);
            continue;
        }
        if (entry.kind != .file) continue;

        // Read the ref file
        var ref_path_buf: [4096]u8 = undefined;
        const ref_total = dir_path.len + 1 + entry.name.len;
        if (ref_total > ref_path_buf.len) continue;
        var rpos: usize = 0;
        @memcpy(ref_path_buf[rpos..][0..dir_path.len], dir_path);
        rpos += dir_path.len;
        ref_path_buf[rpos] = '/';
        rpos += 1;
        @memcpy(ref_path_buf[rpos..][0..entry.name.len], entry.name);
        rpos += entry.name.len;
        const ref_file_path = ref_path_buf[0..rpos];

        const content = readFileContents(allocator, ref_file_path) catch continue;
        defer allocator.free(content);
        const trimmed = std.mem.trimRight(u8, content, "\n\r ");

        if (trimmed.len < types.OID_HEX_LEN) continue;

        // If it's a symref, skip (it's not a direct ref)
        if (std.mem.startsWith(u8, trimmed, "ref: ")) continue;

        const oid = types.ObjectId.fromHex(trimmed[0..types.OID_HEX_LEN]) catch continue;

        // Build full ref name: prefix + entry.name
        const name_len = prefix.len + entry.name.len;
        const name = try allocator.alloc(u8, name_len);
        errdefer allocator.free(name);
        @memcpy(name[0..prefix.len], prefix);
        @memcpy(name[prefix.len..], entry.name);

        try entries.append(.{ .name = name, .oid = oid });
    }
}

fn scanPackedRefs(allocator: std.mem.Allocator, git_dir: []const u8, prefix: []const u8, entries: *std.array_list.Managed(RefEntry)) !void {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    const suffix = "/packed-refs";
    @memcpy(path_buf[git_dir.len..][0..suffix.len], suffix);
    const packed_path = path_buf[0 .. git_dir.len + suffix.len];

    const content = readFileContents(allocator, packed_path) catch return;
    defer allocator.free(content);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
        if (line.len < types.OID_HEX_LEN + 1) continue;

        const hex_part = line[0..types.OID_HEX_LEN];
        const ref_name = std.mem.trimRight(u8, line[types.OID_HEX_LEN + 1 ..], " \r");

        if (!std.mem.startsWith(u8, ref_name, prefix)) continue;

        const oid = types.ObjectId.fromHex(hex_part) catch continue;

        const name = try allocator.alloc(u8, ref_name.len);
        errdefer allocator.free(name);
        @memcpy(name, ref_name);

        try entries.append(.{ .name = name, .oid = oid });
    }
}

/// Create or update a ref file. If old_oid_check is non-null, verify the ref currently
/// points to that OID before updating (CAS).
pub fn createRef(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8, oid: types.ObjectId, old_oid_check: ?types.ObjectId) !void {
    var path_buf: [4096]u8 = undefined;
    const total_len = git_dir.len + 1 + name.len;
    if (total_len > path_buf.len) return error.InvalidRefName;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    path_buf[pos] = '/';
    pos += 1;
    @memcpy(path_buf[pos..][0..name.len], name);
    pos += name.len;
    const ref_path = path_buf[0..pos];

    // CAS check
    if (old_oid_check) |expected| {
        const content = readFileContents(allocator, ref_path) catch return error.RefNotFound;
        defer allocator.free(content);
        const trimmed = std.mem.trimRight(u8, content, "\n\r ");
        if (trimmed.len < types.OID_HEX_LEN) return error.RefNotFound;
        const current = types.ObjectId.fromHex(trimmed[0..types.OID_HEX_LEN]) catch return error.RefNotFound;
        if (!current.eql(&expected)) return error.RefCASFailed;
    }

    // Ensure parent directories exist
    const dir_end = std.mem.lastIndexOfScalar(u8, ref_path, '/') orelse return error.InvalidRefName;
    mkdirRecursive(ref_path[0..dir_end]) catch {};

    // Write the OID as hex + newline
    const hex = oid.toHex();
    var content_buf: [types.OID_HEX_LEN + 1]u8 = undefined;
    @memcpy(content_buf[0..types.OID_HEX_LEN], &hex);
    content_buf[types.OID_HEX_LEN] = '\n';

    const file = try std.fs.createFileAbsolute(ref_path, .{});
    defer file.close();
    try file.writeAll(&content_buf);
}

/// Delete a loose ref file.
pub fn deleteRef(git_dir: []const u8, name: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    const total_len = git_dir.len + 1 + name.len;
    if (total_len > path_buf.len) return error.InvalidRefName;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    path_buf[pos] = '/';
    pos += 1;
    @memcpy(path_buf[pos..][0..name.len], name);
    pos += name.len;
    const ref_path = path_buf[0..pos];

    std.fs.deleteFileAbsolute(ref_path) catch |err| switch (err) {
        error.FileNotFound => return error.RefNotFound,
        else => return err,
    };
}

/// Update a symbolic ref (e.g. HEAD -> refs/heads/main).
pub fn updateSymRef(git_dir: []const u8, name: []const u8, target: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    const total_len = git_dir.len + 1 + name.len;
    if (total_len > path_buf.len) return error.InvalidRefName;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    path_buf[pos] = '/';
    pos += 1;
    @memcpy(path_buf[pos..][0..name.len], name);
    pos += name.len;
    const ref_path = path_buf[0..pos];

    var content_buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&content_buf);
    const writer = stream.writer();
    try writer.writeAll("ref: ");
    try writer.writeAll(target);
    try writer.writeByte('\n');
    const content = content_buf[0..stream.pos];

    const file = try std.fs.createFileAbsolute(ref_path, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Read HEAD and return the symbolic target (e.g. "refs/heads/main") or null if detached.
pub fn readHead(allocator: std.mem.Allocator, git_dir: []const u8) !?[]const u8 {
    var path_buf: [4096]u8 = undefined;
    const suffix = "/HEAD";
    if (git_dir.len + suffix.len > path_buf.len) return error.RefNotFound;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    @memcpy(path_buf[git_dir.len..][0..suffix.len], suffix);
    const head_path = path_buf[0 .. git_dir.len + suffix.len];

    const content = try readFileContents(allocator, head_path);
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n\r ");

    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const target = trimmed[5..];
        const result = try allocator.alloc(u8, target.len);
        @memcpy(result, target);
        return result;
    }

    return null; // Detached HEAD
}

/// Read a direct ref file and return the OID it points to.
pub fn readRef(allocator: std.mem.Allocator, git_dir: []const u8, name: []const u8) !types.ObjectId {
    var path_buf: [4096]u8 = undefined;
    const total_len = git_dir.len + 1 + name.len;
    if (total_len > path_buf.len) return error.RefNotFound;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    path_buf[pos] = '/';
    pos += 1;
    @memcpy(path_buf[pos..][0..name.len], name);
    pos += name.len;
    const ref_path = path_buf[0..pos];

    const content = readFileContents(allocator, ref_path) catch return error.RefNotFound;
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n\r ");

    // Follow symrefs
    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        return readRef(allocator, git_dir, trimmed[5..]);
    }

    if (trimmed.len >= types.OID_HEX_LEN) {
        return types.ObjectId.fromHex(trimmed[0..types.OID_HEX_LEN]);
    }

    return error.RefNotFound;
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
