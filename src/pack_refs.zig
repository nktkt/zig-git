const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const ref_mod = @import("ref.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Options for pack-refs.
pub const PackRefsOptions = struct {
    all: bool = false, // --all: pack all refs including tags
    no_prune: bool = false, // don't delete loose refs after packing
};

/// A packed ref entry.
const PackedRef = struct {
    name: []const u8,
    oid: types.ObjectId,
    peeled_oid: ?types.ObjectId,
};

/// Run the pack-refs command.
pub fn runPackRefs(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = PackRefsOptions{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            opts.all = true;
        } else if (std.mem.eql(u8, arg, "--no-prune")) {
            opts.no_prune = true;
        }
    }

    const count = try packRefs(allocator, repo, opts);

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Packed {d} refs.\n", .{count}) catch return;
    try stdout_file.writeAll(msg);
}

/// Core pack-refs logic. Returns the number of packed refs.
pub fn packRefs(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    opts: PackRefsOptions,
) !u32 {
    // Collect all refs to pack
    var refs_to_pack = std.array_list.Managed(PackedRef).init(allocator);
    defer {
        for (refs_to_pack.items) |e| allocator.free(@constCast(e.name));
        refs_to_pack.deinit();
    }

    // Always pack branches
    {
        const branch_refs = try ref_mod.listRefs(allocator, repo.git_dir, "refs/heads/");
        defer allocator.free(branch_refs);
        for (branch_refs) |entry| {
            try refs_to_pack.append(.{
                .name = entry.name, // take ownership
                .oid = entry.oid,
                .peeled_oid = null,
            });
        }
    }

    // Always pack remote tracking refs
    {
        const remote_refs = try ref_mod.listRefs(allocator, repo.git_dir, "refs/remotes/");
        defer allocator.free(remote_refs);
        for (remote_refs) |entry| {
            try refs_to_pack.append(.{
                .name = entry.name,
                .oid = entry.oid,
                .peeled_oid = null,
            });
        }
    }

    // Pack tags if --all is specified
    if (opts.all) {
        const tag_refs = try ref_mod.listRefs(allocator, repo.git_dir, "refs/tags/");
        defer allocator.free(tag_refs);
        for (tag_refs) |entry| {
            // Try to peel annotated tags
            var peeled: ?types.ObjectId = null;
            var obj = repo.readObject(allocator, &entry.oid) catch null;
            if (obj) |*o| {
                if (o.obj_type == .tag) {
                    // Parse the target from the tag object
                    peeled = parseTagTarget(o.data);
                }
                o.deinit();
            }

            try refs_to_pack.append(.{
                .name = entry.name,
                .oid = entry.oid,
                .peeled_oid = peeled,
            });
        }
    }

    if (refs_to_pack.items.len == 0) return 0;

    // Read existing packed-refs (to merge with)
    var existing_packed = std.array_list.Managed(PackedRef).init(allocator);
    defer {
        for (existing_packed.items) |e| allocator.free(@constCast(e.name));
        existing_packed.deinit();
    }
    try readExistingPackedRefs(allocator, repo.git_dir, &existing_packed);

    // Merge: new refs override existing
    var merged = std.StringHashMap(PackedRef).init(allocator);
    defer merged.deinit();

    for (existing_packed.items) |entry| {
        try merged.put(entry.name, entry);
    }
    for (refs_to_pack.items) |entry| {
        if (merged.getPtr(entry.name)) |existing| {
            allocator.free(@constCast(existing.name));
        }
        try merged.put(entry.name, entry);
    }

    // Collect and sort
    var sorted_refs = std.array_list.Managed(PackedRef).init(allocator);
    defer sorted_refs.deinit();
    var mit = merged.valueIterator();
    while (mit.next()) |val| {
        try sorted_refs.append(val.*);
    }
    std.mem.sort(PackedRef, sorted_refs.items, {}, struct {
        fn lessThan(_: void, a: PackedRef, b: PackedRef) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    // Write packed-refs file
    try writePackedRefs(allocator, repo.git_dir, sorted_refs.items);

    // Delete loose refs (unless --no-prune)
    if (!opts.no_prune) {
        for (refs_to_pack.items) |entry| {
            _ = deleteLooseRef(repo.git_dir, entry.name);
        }
    }

    return @intCast(refs_to_pack.items.len);
}

/// Write the packed-refs file.
fn writePackedRefs(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    refs: []const PackedRef,
) !void {
    var content = std.array_list.Managed(u8).init(allocator);
    defer content.deinit();

    // Header
    try content.appendSlice("# pack-refs with: peeled fully-peeled sorted \n");

    for (refs) |entry| {
        const hex = entry.oid.toHex();
        try content.appendSlice(&hex);
        try content.append(' ');
        try content.appendSlice(entry.name);
        try content.append('\n');

        // Write peeled line for annotated tags
        if (entry.peeled_oid) |peeled| {
            const peeled_hex = peeled.toHex();
            try content.append('^');
            try content.appendSlice(&peeled_hex);
            try content.append('\n');
        }
    }

    // Write to temp file, then atomic rename
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    const suffix = "/packed-refs";
    @memcpy(path_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    const packed_path = path_buf[0..pos];

    var tmp_buf: [4096]u8 = undefined;
    @memcpy(tmp_buf[0..pos], packed_path);
    const tmp_suffix = ".new";
    @memcpy(tmp_buf[pos..][0..tmp_suffix.len], tmp_suffix);
    const tmp_path = tmp_buf[0 .. pos + tmp_suffix.len];

    const file = try std.fs.createFileAbsolute(tmp_path, .{});
    defer file.close();
    try file.writeAll(content.items);

    std.fs.renameAbsolute(tmp_path, packed_path) catch {
        // If rename fails, try direct write
        const direct = std.fs.createFileAbsolute(packed_path, .{}) catch return error.PackedRefsWriteFailed;
        defer direct.close();
        direct.writeAll(content.items) catch return error.PackedRefsWriteFailed;
    };
}

/// Read existing packed-refs file.
fn readExistingPackedRefs(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    refs: *std.array_list.Managed(PackedRef),
) !void {
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    const suffix = "/packed-refs";
    @memcpy(path_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    const packed_path = path_buf[0..pos];

    const content = readFileContents(allocator, packed_path) catch return;
    defer allocator.free(content);

    var last_ref: ?*PackedRef = null;
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '^') {
            // Peeled line
            if (last_ref) |ref_ptr| {
                if (line.len >= 1 + types.OID_HEX_LEN) {
                    ref_ptr.peeled_oid = types.ObjectId.fromHex(line[1..][0..types.OID_HEX_LEN]) catch null;
                }
            }
            continue;
        }

        if (line.len < types.OID_HEX_LEN + 1) continue;
        const oid = types.ObjectId.fromHex(line[0..types.OID_HEX_LEN]) catch continue;
        const name_str = std.mem.trimRight(u8, line[types.OID_HEX_LEN + 1 ..], " \r");

        const name = allocator.alloc(u8, name_str.len) catch continue;
        @memcpy(name, name_str);

        try refs.append(.{
            .name = name,
            .oid = oid,
            .peeled_oid = null,
        });
        last_ref = &refs.items[refs.items.len - 1];
    }
}

/// Delete a loose ref file. Returns true if deleted.
fn deleteLooseRef(git_dir: []const u8, ref_name: []const u8) bool {
    // Don't delete HEAD or symbolic refs
    if (std.mem.eql(u8, ref_name, "HEAD")) return false;

    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    path_buf[pos] = '/';
    pos += 1;
    @memcpy(path_buf[pos..][0..ref_name.len], ref_name);
    pos += ref_name.len;
    const ref_path = path_buf[0..pos];

    // Check if it's a symbolic ref before deleting
    const content = readFileContents(std.heap.page_allocator, ref_path) catch return false;
    defer std.heap.page_allocator.free(content);
    if (std.mem.startsWith(u8, content, "ref: ")) return false;

    std.fs.deleteFileAbsolute(ref_path) catch return false;
    return true;
}

/// Parse the target OID from a tag object.
fn parseTagTarget(data: []const u8) ?types.ObjectId {
    if (data.len < 7 + types.OID_HEX_LEN) return null;
    if (!std.mem.startsWith(u8, data, "object ")) return null;
    return types.ObjectId.fromHex(data[7..][0..types.OID_HEX_LEN]) catch null;
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

test "PackRefsOptions defaults" {
    const opts = PackRefsOptions{};
    try std.testing.expect(!opts.all);
    try std.testing.expect(!opts.no_prune);
}
