const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const tree_builder = @import("tree_builder.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

pub fn runReadTree(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var merge_mode = false;
    var update_worktree = false;
    var prefix: ?[]const u8 = null;
    var tree_args = std.array_list.Managed([]const u8).init(allocator);
    defer tree_args.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-m")) {
            merge_mode = true;
        } else if (std.mem.eql(u8, arg, "-u")) {
            update_worktree = true;
        } else if (std.mem.startsWith(u8, arg, "--prefix=")) {
            prefix = arg["--prefix=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try tree_args.append(arg);
        }
    }

    if (tree_args.items.len == 0) {
        try stderr_file.writeAll("fatal: required argument '<tree-ish>' missing\n");
        std.process.exit(128);
    }

    // Load or create index
    var index_path_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&index_path_buf);
    var writer = stream.writer();
    try writer.writeAll(repo.git_dir);
    try writer.writeAll("/index");
    const index_path = index_path_buf[0..stream.pos];

    if (merge_mode and tree_args.items.len == 3) {
        // Three-way merge: read-tree -m <base> <ours> <theirs>
        try threeWayMerge(repo, allocator, tree_args.items[0], tree_args.items[1], tree_args.items[2], index_path, prefix, update_worktree);
    } else if (merge_mode and tree_args.items.len == 1) {
        // Single tree merge
        try singleTreeMerge(repo, allocator, tree_args.items[0], index_path, prefix, update_worktree);
    } else {
        // Simple read-tree: replace index with tree contents
        try readTreeIntoIndex(repo, allocator, tree_args.items[0], index_path, prefix, update_worktree);
    }
}

fn resolveTreeOid(repo: *repository.Repository, allocator: std.mem.Allocator, ref_str: []const u8) !types.ObjectId {
    const oid = repo.resolveRef(allocator, ref_str) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: not a valid object name {s}\n", .{ref_str}) catch "fatal: not a valid object name\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    // If it's a commit, extract the tree OID
    var obj = repo.readObject(allocator, &oid) catch {
        try stderr_file.writeAll("fatal: failed to read object\n");
        std.process.exit(128);
    };

    if (obj.obj_type == .commit) {
        const tree_prefix = "tree ";
        if (std.mem.startsWith(u8, obj.data, tree_prefix)) {
            const nl = std.mem.indexOfScalar(u8, obj.data, '\n') orelse {
                obj.deinit();
                return error.InvalidCommit;
            };
            _ = nl;
            if (obj.data.len >= tree_prefix.len + types.OID_HEX_LEN) {
                const tree_oid = types.ObjectId.fromHex(obj.data[tree_prefix.len..][0..types.OID_HEX_LEN]) catch {
                    obj.deinit();
                    return error.InvalidCommit;
                };
                obj.deinit();
                return tree_oid;
            }
        }
        obj.deinit();
        return error.InvalidCommit;
    } else if (obj.obj_type == .tree) {
        obj.deinit();
        return oid;
    } else {
        obj.deinit();
        return error.NotATree;
    }
}

fn readTreeIntoIndex(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    tree_ref: []const u8,
    index_path: []const u8,
    prefix: ?[]const u8,
    update_worktree: bool,
) !void {
    const tree_oid = try resolveTreeOid(repo, allocator, tree_ref);

    var idx = index_mod.Index.init(allocator);
    defer idx.deinit();

    // Flatten the tree into index entries
    try flattenTree(repo, allocator, &tree_oid, prefix orelse "", &idx);

    try idx.writeToFile(index_path);

    if (update_worktree) {
        try updateWorkTree(repo, allocator, &idx);
    }
}

fn flattenTree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    tree_oid: *const types.ObjectId,
    prefix: []const u8,
    idx: *index_mod.Index,
) !void {
    var obj = try repo.readObject(allocator, tree_oid);
    defer obj.deinit();

    if (obj.obj_type != .tree) return error.NotATree;

    const entries = try tree_builder.parseTreeEntries(allocator, obj.data);
    defer allocator.free(entries);

    for (entries) |*entry| {
        const is_tree = std.mem.eql(u8, entry.mode, "40000");

        // Build full path
        var path_buf: [4096]u8 = undefined;
        var ppos: usize = 0;
        if (prefix.len > 0) {
            @memcpy(path_buf[ppos..][0..prefix.len], prefix);
            ppos += prefix.len;
            if (prefix[prefix.len - 1] != '/') {
                path_buf[ppos] = '/';
                ppos += 1;
            }
        }
        @memcpy(path_buf[ppos..][0..entry.name.len], entry.name);
        ppos += entry.name.len;
        const full_path = path_buf[0..ppos];

        if (is_tree) {
            try flattenTree(repo, allocator, &entry.oid, full_path, idx);
        } else {
            // Create index entry
            const owned_name = try allocator.alloc(u8, full_path.len);
            @memcpy(owned_name, full_path);

            const mode = parseModeOctal(entry.mode);

            const index_entry = index_mod.IndexEntry{
                .ctime_s = 0,
                .ctime_ns = 0,
                .mtime_s = 0,
                .mtime_ns = 0,
                .dev = 0,
                .ino = 0,
                .mode = mode,
                .uid = 0,
                .gid = 0,
                .file_size = 0,
                .oid = entry.oid,
                .flags = @as(u16, @intCast(@min(full_path.len, 0xFFF))),
                .name = owned_name,
                .owned = true,
            };

            try idx.addEntry(index_entry);
        }
    }
}

fn parseModeOctal(mode_str: []const u8) u32 {
    var result: u32 = 0;
    for (mode_str) |c| {
        if (c >= '0' and c <= '7') {
            result = result * 8 + (c - '0');
        }
    }
    return result;
}

fn singleTreeMerge(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    tree_ref: []const u8,
    index_path: []const u8,
    prefix: ?[]const u8,
    update_worktree: bool,
) !void {
    // For single tree merge, just replace index
    try readTreeIntoIndex(repo, allocator, tree_ref, index_path, prefix, update_worktree);
}

fn threeWayMerge(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    base_ref: []const u8,
    ours_ref: []const u8,
    theirs_ref: []const u8,
    index_path: []const u8,
    prefix: ?[]const u8,
    update_worktree: bool,
) !void {
    _ = prefix;

    const base_oid = try resolveTreeOid(repo, allocator, base_ref);
    const ours_oid = try resolveTreeOid(repo, allocator, ours_ref);
    const theirs_oid = try resolveTreeOid(repo, allocator, theirs_ref);

    // Flatten all three trees
    var base_idx = index_mod.Index.init(allocator);
    defer base_idx.deinit();
    try flattenTree(repo, allocator, &base_oid, "", &base_idx);

    var ours_idx = index_mod.Index.init(allocator);
    defer ours_idx.deinit();
    try flattenTree(repo, allocator, &ours_oid, "", &ours_idx);

    var theirs_idx = index_mod.Index.init(allocator);
    defer theirs_idx.deinit();
    try flattenTree(repo, allocator, &theirs_oid, "", &theirs_idx);

    // Build result index with three-way merge
    var result = index_mod.Index.init(allocator);
    defer result.deinit();

    // Collect all unique file paths
    var all_paths = std.StringHashMap(void).init(allocator);
    defer all_paths.deinit();

    for (base_idx.entries.items) |*e| {
        all_paths.put(e.name, {}) catch {};
    }
    for (ours_idx.entries.items) |*e| {
        all_paths.put(e.name, {}) catch {};
    }
    for (theirs_idx.entries.items) |*e| {
        all_paths.put(e.name, {}) catch {};
    }

    var key_iter = all_paths.keyIterator();
    while (key_iter.next()) |key_ptr| {
        const path = key_ptr.*;
        const base_entry = findEntryByName(&base_idx, path);
        const ours_entry = findEntryByName(&ours_idx, path);
        const theirs_entry = findEntryByName(&theirs_idx, path);

        if (ours_entry != null and theirs_entry != null) {
            const ours_e = ours_entry.?;
            const theirs_e = theirs_entry.?;

            if (ours_e.oid.eql(&theirs_e.oid)) {
                // Both sides agree -- use ours
                const owned_name = try allocator.alloc(u8, path.len);
                @memcpy(owned_name, path);
                var entry = ours_e.*;
                entry.name = owned_name;
                entry.owned = true;
                entry.flags = entry.flags & 0x0FFF; // stage 0
                try result.addEntry(entry);
            } else if (base_entry) |base_e| {
                if (base_e.oid.eql(&theirs_e.oid)) {
                    // Only ours changed
                    const owned_name = try allocator.alloc(u8, path.len);
                    @memcpy(owned_name, path);
                    var entry = ours_e.*;
                    entry.name = owned_name;
                    entry.owned = true;
                    entry.flags = entry.flags & 0x0FFF;
                    try result.addEntry(entry);
                } else if (base_e.oid.eql(&ours_e.oid)) {
                    // Only theirs changed
                    const owned_name = try allocator.alloc(u8, path.len);
                    @memcpy(owned_name, path);
                    var entry = theirs_e.*;
                    entry.name = owned_name;
                    entry.owned = true;
                    entry.flags = entry.flags & 0x0FFF;
                    try result.addEntry(entry);
                } else {
                    // Both changed differently -- conflict
                    // Add all three stages
                    try addStageEntry(allocator, &result, base_e, path, 1);
                    try addStageEntry(allocator, &result, ours_e, path, 2);
                    try addStageEntry(allocator, &result, theirs_e, path, 3);
                }
            } else {
                // No base -- both added
                try addStageEntry(allocator, &result, ours_e, path, 2);
                try addStageEntry(allocator, &result, theirs_e, path, 3);
            }
        } else if (ours_entry != null and theirs_entry == null) {
            const ours_e = ours_entry.?;
            if (base_entry) |base_e| {
                if (base_e.oid.eql(&ours_e.oid)) {
                    // Theirs deleted and ours didn't change -- delete
                    continue;
                } else {
                    // Theirs deleted, ours modified -- conflict
                    try addStageEntry(allocator, &result, base_e, path, 1);
                    try addStageEntry(allocator, &result, ours_e, path, 2);
                }
            } else {
                // Only in ours (new file)
                const owned_name = try allocator.alloc(u8, path.len);
                @memcpy(owned_name, path);
                var entry = ours_e.*;
                entry.name = owned_name;
                entry.owned = true;
                entry.flags = entry.flags & 0x0FFF;
                try result.addEntry(entry);
            }
        } else if (ours_entry == null and theirs_entry != null) {
            const theirs_e = theirs_entry.?;
            if (base_entry) |base_e| {
                if (base_e.oid.eql(&theirs_e.oid)) {
                    // Ours deleted and theirs didn't change -- delete
                    continue;
                } else {
                    // Ours deleted, theirs modified -- conflict
                    try addStageEntry(allocator, &result, base_e, path, 1);
                    try addStageEntry(allocator, &result, theirs_e, path, 3);
                }
            } else {
                // Only in theirs (new file)
                const owned_name = try allocator.alloc(u8, path.len);
                @memcpy(owned_name, path);
                var entry = theirs_e.*;
                entry.name = owned_name;
                entry.owned = true;
                entry.flags = entry.flags & 0x0FFF;
                try result.addEntry(entry);
            }
        }
        // else: deleted on both sides -- skip
    }

    try result.writeToFile(index_path);

    if (update_worktree) {
        try updateWorkTree(repo, allocator, &result);
    }
}

fn findEntryByName(idx: *const index_mod.Index, name: []const u8) ?*const index_mod.IndexEntry {
    for (idx.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn addStageEntry(
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    source: *const index_mod.IndexEntry,
    path: []const u8,
    stage: u2,
) !void {
    const owned_name = try allocator.alloc(u8, path.len);
    @memcpy(owned_name, path);

    var entry = source.*;
    entry.name = owned_name;
    entry.owned = true;
    // Set stage in flags (bits 12-13)
    entry.flags = (entry.flags & 0x0FFF) | (@as(u16, stage) << 12);
    try idx.entries.append(entry);
}

fn updateWorkTree(repo: *repository.Repository, allocator: std.mem.Allocator, idx: *const index_mod.Index) !void {
    const work_dir = getWorkDir(repo.git_dir);

    for (idx.entries.items) |*entry| {
        const stage = (entry.flags >> 12) & 0x3;
        if (stage != 0) continue;

        // Build full path
        var path_buf: [4096]u8 = undefined;
        var pos: usize = 0;
        @memcpy(path_buf[pos..][0..work_dir.len], work_dir);
        pos += work_dir.len;
        path_buf[pos] = '/';
        pos += 1;
        @memcpy(path_buf[pos..][0..entry.name.len], entry.name);
        pos += entry.name.len;
        const full_path = path_buf[0..pos];

        // Read blob object
        var obj = repo.readObject(allocator, &entry.oid) catch continue;
        defer obj.deinit();

        if (obj.obj_type != .blob) continue;

        // Ensure parent directory exists
        const dir_end = std.mem.lastIndexOfScalar(u8, full_path, '/') orelse continue;
        mkdirRecursive(full_path[0..dir_end]) catch {};

        // Write file
        const file = std.fs.createFileAbsolute(full_path, .{ .truncate = true }) catch continue;
        defer file.close();
        file.writeAll(obj.data) catch {};
    }
}

fn getWorkDir(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    return git_dir;
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
