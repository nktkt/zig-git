const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const pack_objects = @import("pack_objects.zig");
const hash_mod = @import("hash.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Options for the repack command.
pub const RepackOptions = struct {
    all: bool = false, // -a: pack all objects into a single pack
    delete_old: bool = false, // -d: delete old packs after repacking
    keep_unreachable_loose: bool = false, // -A: unreachable objects become loose
    window_size: usize = 10,
    depth_limit: usize = 50,
    quiet: bool = false,
};

/// Run the repack command.
pub fn runRepack(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = RepackOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-a")) {
            opts.all = true;
        } else if (std.mem.eql(u8, arg, "-d")) {
            opts.delete_old = true;
        } else if (std.mem.eql(u8, arg, "-A")) {
            opts.all = true;
            opts.keep_unreachable_loose = true;
        } else if (std.mem.eql(u8, arg, "-ad") or std.mem.eql(u8, arg, "-da")) {
            opts.all = true;
            opts.delete_old = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else if (std.mem.startsWith(u8, arg, "--window=")) {
            const val = arg["--window=".len..];
            opts.window_size = std.fmt.parseInt(usize, val, 10) catch 10;
        } else if (std.mem.startsWith(u8, arg, "--depth=")) {
            const val = arg["--depth=".len..];
            opts.depth_limit = std.fmt.parseInt(usize, val, 10) catch 50;
        }
    }

    try repackRepository(allocator, repo, opts);
}

/// Core repack logic.
pub fn repackRepository(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    opts: RepackOptions,
) !void {
    // Collect existing pack file paths (for later deletion)
    var old_pack_paths = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (old_pack_paths.items) |p| allocator.free(p);
        old_pack_paths.deinit();
    }

    if (opts.delete_old) {
        var pack_dir_buf: [4096]u8 = undefined;
        var pos: usize = 0;
        @memcpy(pack_dir_buf[pos..][0..repo.git_dir.len], repo.git_dir);
        pos += repo.git_dir.len;
        const pd = "/objects/pack";
        @memcpy(pack_dir_buf[pos..][0..pd.len], pd);
        pos += pd.len;
        const pack_dir = pack_dir_buf[0..pos];

        if (std.fs.openDirAbsolute(pack_dir, .{ .iterate = true })) |dir_handle| {
            var dir = dir_handle;
            defer dir.close();
            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".pack") and
                    !std.mem.endsWith(u8, entry.name, ".idx"))
                    continue;

                const full_len = pack_dir.len + 1 + entry.name.len;
                const full = try allocator.alloc(u8, full_len);
                @memcpy(full[0..pack_dir.len], pack_dir);
                full[pack_dir.len] = '/';
                @memcpy(full[pack_dir.len + 1 ..], entry.name);
                try old_pack_paths.append(full);
            }
        } else |_| {}
    }

    // Generate a unique pack name based on timestamp
    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    // Build output base path
    var output_buf: [4096]u8 = undefined;
    var opos: usize = 0;
    @memcpy(output_buf[opos..][0..repo.git_dir.len], repo.git_dir);
    opos += repo.git_dir.len;
    const pack_prefix = "/objects/pack/pack-";
    @memcpy(output_buf[opos..][0..pack_prefix.len], pack_prefix);
    opos += pack_prefix.len;
    @memcpy(output_buf[opos..][0..timestamp.len], timestamp);
    opos += timestamp.len;

    // Ensure pack directory exists
    var pack_dir_buf2: [4096]u8 = undefined;
    var pd2: usize = 0;
    @memcpy(pack_dir_buf2[pd2..][0..repo.git_dir.len], repo.git_dir);
    pd2 += repo.git_dir.len;
    const pdir = "/objects/pack";
    @memcpy(pack_dir_buf2[pd2..][0..pdir.len], pdir);
    pd2 += pdir.len;
    std.fs.makeDirAbsolute(pack_dir_buf2[0..pd2]) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const output_base = output_buf[0..opos];

    // Create the new pack with delta compression
    const config = pack_objects.PackObjectsConfig{
        .window_size = opts.window_size,
        .depth_limit = opts.depth_limit,
        .thin_pack = false,
        .reuse_deltas = true,
        .progress = !opts.quiet,
    };

    // Need to close existing packs before we can delete them
    // But first, let pack_objects read from them
    var pack_result = try pack_objects.packAllObjects(allocator, repo, config, output_base);
    defer pack_result.deinit();

    if (!opts.quiet) {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Created pack with {d} objects\n", .{pack_result.num_objects}) catch return;
        try stdout_file.writeAll(msg);
    }

    // Rename the pack files to include the actual hash
    const hash_hex = pack_result.pack_hash.toHex();
    var final_base_buf: [4096]u8 = undefined;
    var fb: usize = 0;
    @memcpy(final_base_buf[fb..][0..repo.git_dir.len], repo.git_dir);
    fb += repo.git_dir.len;
    @memcpy(final_base_buf[fb..][0..pack_prefix.len], pack_prefix);
    fb += pack_prefix.len;
    @memcpy(final_base_buf[fb..][0..hash_hex.len], &hash_hex);
    fb += hash_hex.len;

    // Rename .pack file
    var old_pack_name_buf: [4096]u8 = undefined;
    @memcpy(old_pack_name_buf[0..opos], output_base);
    const pack_ext = ".pack";
    @memcpy(old_pack_name_buf[opos..][0..pack_ext.len], pack_ext);
    const old_pack_name = old_pack_name_buf[0 .. opos + pack_ext.len];

    var new_pack_name_buf: [4096]u8 = undefined;
    @memcpy(new_pack_name_buf[0..fb], final_base_buf[0..fb]);
    @memcpy(new_pack_name_buf[fb..][0..pack_ext.len], pack_ext);
    const new_pack_name = new_pack_name_buf[0 .. fb + pack_ext.len];

    std.fs.renameAbsolute(old_pack_name, new_pack_name) catch {};

    // Rename .idx file
    var old_idx_name_buf: [4096]u8 = undefined;
    @memcpy(old_idx_name_buf[0..opos], output_base);
    const idx_ext = ".idx";
    @memcpy(old_idx_name_buf[opos..][0..idx_ext.len], idx_ext);
    const old_idx_name = old_idx_name_buf[0 .. opos + idx_ext.len];

    var new_idx_name_buf: [4096]u8 = undefined;
    @memcpy(new_idx_name_buf[0..fb], final_base_buf[0..fb]);
    @memcpy(new_idx_name_buf[fb..][0..idx_ext.len], idx_ext);
    const new_idx_name = new_idx_name_buf[0 .. fb + idx_ext.len];

    std.fs.renameAbsolute(old_idx_name, new_idx_name) catch {};

    // Delete old packs if requested
    if (opts.delete_old) {
        for (old_pack_paths.items) |old_path| {
            // Don't delete the pack we just created
            if (std.mem.eql(u8, old_path, new_pack_name) or
                std.mem.eql(u8, old_path, new_idx_name))
                continue;
            std.fs.deleteFileAbsolute(old_path) catch {};
        }

        // Delete loose objects that are now in the pack
        if (opts.all and !opts.keep_unreachable_loose) {
            try deletePackedLooseObjects(allocator, repo);
        }
    }

    if (!opts.quiet) {
        try stdout_file.writeAll("Repack complete.\n");
    }
}

/// Delete loose objects that exist in pack files.
fn deletePackedLooseObjects(allocator: std.mem.Allocator, repo: *repository.Repository) !void {
    // Build a set of all packed OIDs
    var packed_set = std.AutoHashMap([types.OID_RAW_LEN]u8, void).init(allocator);
    defer packed_set.deinit();

    for (repo.packs.items) |*pack_entry| {
        var idx_iter = pack_entry.pack.idx.iterator();
        while (idx_iter.next()) |item| {
            try packed_set.put(item.oid.bytes, {});
        }
    }

    // Scan loose objects and delete those in the packed set
    var dir_path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(dir_path_buf[pos..][0..repo.git_dir.len], repo.git_dir);
    pos += repo.git_dir.len;
    const obj_suffix = "/objects";
    @memcpy(dir_path_buf[pos..][0..obj_suffix.len], obj_suffix);
    pos += obj_suffix.len;
    const objects_dir = dir_path_buf[0..pos];

    var dir = std.fs.openDirAbsolute(objects_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len != 2) continue;
        if (!isHexStr(entry.name)) continue;

        var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
        defer sub_dir.close();
        var sub_iter = sub_dir.iterate();

        while (try sub_iter.next()) |sub_entry| {
            if (sub_entry.kind != .file) continue;
            if (sub_entry.name.len != types.OID_HEX_LEN - 2) continue;

            var hex_buf: [types.OID_HEX_LEN]u8 = undefined;
            hex_buf[0] = entry.name[0];
            hex_buf[1] = entry.name[1];
            @memcpy(hex_buf[2..], sub_entry.name[0 .. types.OID_HEX_LEN - 2]);
            const oid = types.ObjectId.fromHex(&hex_buf) catch continue;

            if (packed_set.contains(oid.bytes)) {
                // Build full path and delete
                var full_buf: [4096]u8 = undefined;
                var fp: usize = 0;
                @memcpy(full_buf[fp..][0..objects_dir.len], objects_dir);
                fp += objects_dir.len;
                full_buf[fp] = '/';
                fp += 1;
                @memcpy(full_buf[fp..][0..entry.name.len], entry.name);
                fp += entry.name.len;
                full_buf[fp] = '/';
                fp += 1;
                @memcpy(full_buf[fp..][0..sub_entry.name.len], sub_entry.name);
                fp += sub_entry.name.len;
                std.fs.deleteFileAbsolute(full_buf[0..fp]) catch {};
            }
        }
    }
}

/// Count the number of loose objects in the repository.
pub fn countLooseObjects(repo: *repository.Repository) u32 {
    var count: u32 = 0;
    var dir_path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(dir_path_buf[pos..][0..repo.git_dir.len], repo.git_dir);
    pos += repo.git_dir.len;
    const obj_suffix = "/objects";
    @memcpy(dir_path_buf[pos..][0..obj_suffix.len], obj_suffix);
    pos += obj_suffix.len;
    const objects_dir = dir_path_buf[0..pos];

    var dir = std.fs.openDirAbsolute(objects_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len != 2) continue;
        if (!isHexStr(entry.name)) continue;

        var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
        defer sub_dir.close();
        var sub_iter = sub_dir.iterate();
        while (sub_iter.next() catch null) |sub_entry| {
            if (sub_entry.kind != .file) continue;
            if (sub_entry.name.len != types.OID_HEX_LEN - 2) continue;
            count += 1;
        }
    }

    return count;
}

/// Count the number of pack files in the repository.
pub fn countPackFiles(repo: *repository.Repository) u32 {
    var count: u32 = 0;
    var dir_path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(dir_path_buf[pos..][0..repo.git_dir.len], repo.git_dir);
    pos += repo.git_dir.len;
    const pd = "/objects/pack";
    @memcpy(dir_path_buf[pos..][0..pd.len], pd);
    pos += pd.len;
    const pack_dir = dir_path_buf[0..pos];

    var dir = std.fs.openDirAbsolute(pack_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".pack")) count += 1;
    }

    return count;
}

fn isHexStr(s: []const u8) bool {
    for (s) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

fn getTimestamp(buf: []u8) []const u8 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return "0";
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{d}", .{ts.sec}) catch return "0";
    return buf[0..stream.pos];
}
