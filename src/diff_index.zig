const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const tree_diff = @import("tree_diff.zig");
const hash_mod = @import("hash.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Output mode for diff-index.
pub const OutputMode = enum {
    /// Raw diff output: ":old_mode new_mode old_sha new_sha status\tpath"
    raw,
    /// Only file names.
    name_only,
    /// File names with status character.
    name_status,
};

/// Options for diff-index.
pub const DiffIndexOptions = struct {
    output_mode: OutputMode = .raw,
    /// Show unmerged entries.
    show_unmerged: bool = false,
    /// --cached is implied (always comparing tree vs index).
    cached: bool = true,
};

/// A single diff-index entry.
pub const DiffIndexEntry = struct {
    old_mode: u32,
    new_mode: u32,
    old_oid: types.ObjectId,
    new_oid: types.ObjectId,
    status: u8, // 'M', 'D', 'A', 'T', 'U'
    path: []const u8,
    unmerged: bool,
};

pub fn runDiffIndex(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = DiffIndexOptions{};
    var tree_ref: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--name-only")) {
            opts.output_mode = .name_only;
        } else if (std.mem.eql(u8, arg, "--name-status")) {
            opts.output_mode = .name_status;
        } else if (std.mem.eql(u8, arg, "--cached")) {
            opts.cached = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            opts.show_unmerged = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            tree_ref = arg;
        }
    }

    if (tree_ref == null) {
        try stderr_file.writeAll("usage: zig-git diff-index [--cached] [--name-only] [--name-status] [-m] <tree-ish>\n");
        std.process.exit(1);
    }

    var entries = try computeDiffIndex(repo, allocator, tree_ref.?, &opts);
    defer entries.deinit();

    for (entries.items) |*entry| {
        if (entry.unmerged and !opts.show_unmerged) continue;

        switch (opts.output_mode) {
            .raw => try writeRawEntry(entry),
            .name_only => {
                try stdout_file.writeAll(entry.path);
                try stdout_file.writeAll("\n");
            },
            .name_status => {
                var buf: [2]u8 = undefined;
                buf[0] = entry.status;
                buf[1] = '\t';
                try stdout_file.writeAll(buf[0..2]);
                try stdout_file.writeAll(entry.path);
                try stdout_file.writeAll("\n");
            },
        }
    }
}

/// Compute differences between a tree-ish and the index.
pub fn computeDiffIndex(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    tree_ref: []const u8,
    opts: *const DiffIndexOptions,
) !std.array_list.Managed(DiffIndexEntry) {
    _ = opts;
    var result = std.array_list.Managed(DiffIndexEntry).init(allocator);
    errdefer result.deinit();

    // Resolve tree-ish to a tree OID
    const tree_oid = try resolveToTree(repo, allocator, tree_ref);

    // Load tree entries into a map
    var tree_entries = std.StringHashMap(TreeEntryInfo).init(allocator);
    defer {
        var ki = tree_entries.keyIterator();
        while (ki.next()) |key| {
            allocator.free(key.*);
        }
        tree_entries.deinit();
    }
    try walkTreeFlat(repo, allocator, &tree_oid, &tree_entries, "");

    // Load the index
    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPath(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    // Compare each index entry with the tree
    for (idx.entries.items) |*entry| {
        // Check for unmerged entries
        const stage = (entry.flags >> 12) & 0x3;
        if (stage != 0) {
            try result.append(.{
                .old_mode = 0,
                .new_mode = entry.mode,
                .old_oid = types.ObjectId.ZERO,
                .new_oid = entry.oid,
                .status = 'U',
                .path = entry.name,
                .unmerged = true,
            });
            continue;
        }

        if (tree_entries.get(entry.name)) |tree_entry| {
            // Entry exists in both tree and index
            if (!tree_entry.oid.eql(&entry.oid) or tree_entry.mode != entry.mode) {
                // Modified
                const status: u8 = if (tree_entry.mode != entry.mode and tree_entry.oid.eql(&entry.oid)) 'T' else 'M';
                try result.append(.{
                    .old_mode = tree_entry.mode,
                    .new_mode = entry.mode,
                    .old_oid = tree_entry.oid,
                    .new_oid = entry.oid,
                    .status = status,
                    .path = entry.name,
                    .unmerged = false,
                });
            }
            // Remove from tree map so we can detect deletions
            if (tree_entries.fetchRemove(entry.name)) |kv| {
                allocator.free(kv.key);
            }
        } else {
            // New file (in index but not in tree)
            try result.append(.{
                .old_mode = 0,
                .new_mode = entry.mode,
                .old_oid = types.ObjectId.ZERO,
                .new_oid = entry.oid,
                .status = 'A',
                .path = entry.name,
                .unmerged = false,
            });
        }
    }

    // Files in tree but not in index = deleted
    var tree_iter = tree_entries.iterator();
    while (tree_iter.next()) |kv| {
        try result.append(.{
            .old_mode = kv.value_ptr.mode,
            .new_mode = 0,
            .old_oid = kv.value_ptr.oid,
            .new_oid = types.ObjectId.ZERO,
            .status = 'D',
            .path = kv.key_ptr.*,
            .unmerged = false,
        });
    }

    return result;
}

const TreeEntryInfo = struct {
    oid: types.ObjectId,
    mode: u32,
};

/// Resolve a ref to a tree OID (dereferences commits).
fn resolveToTree(repo: *repository.Repository, allocator: std.mem.Allocator, ref_str: []const u8) !types.ObjectId {
    const oid = try repo.resolveRef(allocator, ref_str);

    var obj = try repo.readObject(allocator, &oid);
    defer obj.deinit();

    if (obj.obj_type == .commit) {
        return tree_diff.getCommitTreeOid(obj.data);
    }
    if (obj.obj_type == .tree) {
        return oid;
    }
    return error.NotATreeOrCommit;
}

/// Walk a tree recursively and collect all blob entries into a flat map.
fn walkTreeFlat(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    tree_oid: *const types.ObjectId,
    map: *std.StringHashMap(TreeEntryInfo),
    prefix: []const u8,
) !void {
    var obj = try repo.readObject(allocator, tree_oid);
    defer obj.deinit();

    if (obj.obj_type != .tree) return;

    var pos: usize = 0;
    while (pos < obj.data.len) {
        // Format: "mode name\0<20-byte oid>"
        const space = std.mem.indexOfScalarPos(u8, obj.data, pos, ' ') orelse break;
        const null_byte = std.mem.indexOfScalarPos(u8, obj.data, space, 0) orelse break;
        if (null_byte + 1 + types.OID_RAW_LEN > obj.data.len) break;

        const mode_str = obj.data[pos..space];
        const name = obj.data[space + 1 .. null_byte];

        var entry_oid: types.ObjectId = undefined;
        @memcpy(&entry_oid.bytes, obj.data[null_byte + 1 ..][0..types.OID_RAW_LEN]);

        pos = null_byte + 1 + types.OID_RAW_LEN;

        // Parse mode
        const mode = std.fmt.parseInt(u32, mode_str, 8) catch continue;

        // Build full path
        var path_buf: [4096]u8 = undefined;
        var full_path: []const u8 = undefined;
        if (prefix.len > 0) {
            var pp: usize = 0;
            @memcpy(path_buf[pp..][0..prefix.len], prefix);
            pp += prefix.len;
            path_buf[pp] = '/';
            pp += 1;
            @memcpy(path_buf[pp..][0..name.len], name);
            pp += name.len;
            full_path = path_buf[0..pp];
        } else {
            @memcpy(path_buf[0..name.len], name);
            full_path = path_buf[0..name.len];
        }

        if (isTreeMode(mode)) {
            // Recurse into subtree
            try walkTreeFlat(repo, allocator, &entry_oid, map, full_path);
        } else {
            // Blob entry
            const path_copy = try allocator.alloc(u8, full_path.len);
            @memcpy(path_copy, full_path);
            try map.put(path_copy, .{ .oid = entry_oid, .mode = mode });
        }
    }
}

fn isTreeMode(mode: u32) bool {
    return (mode & 0o170000) == 0o040000;
}

fn writeRawEntry(entry: *const DiffIndexEntry) !void {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    const old_hex = entry.old_oid.toHex();
    const new_hex = entry.new_oid.toHex();

    try writer.print(":{d:0>6} {d:0>6} {s} {s} {c}\t", .{
        entry.old_mode,
        entry.new_mode,
        old_hex[0..7],
        new_hex[0..7],
        entry.status,
    });

    try stdout_file.writeAll(buf[0..stream.pos]);
    try stdout_file.writeAll(entry.path);
    try stdout_file.writeAll("\n");
}

fn buildPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

test "isTreeMode" {
    try std.testing.expect(isTreeMode(0o040000));
    try std.testing.expect(!isTreeMode(0o100644));
    try std.testing.expect(!isTreeMode(0o100755));
}

test "DiffIndexEntry status" {
    const entry = DiffIndexEntry{
        .old_mode = 0o100644,
        .new_mode = 0o100644,
        .old_oid = types.ObjectId.ZERO,
        .new_oid = types.ObjectId.ZERO,
        .status = 'A',
        .path = "test.txt",
        .unmerged = false,
    };
    try std.testing.expectEqual(@as(u8, 'A'), entry.status);
}
