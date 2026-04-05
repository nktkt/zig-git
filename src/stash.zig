const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");
const loose = @import("loose.zig");
const hash_mod = @import("hash.zig");
const tree_diff = @import("tree_diff.zig");
const checkout_mod = @import("checkout.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Get the working directory from git_dir.
fn getWorkDir(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    if (std.fs.path.dirname(git_dir)) |parent| {
        return parent;
    }
    return git_dir;
}

/// Get commit tree OID from commit data.
fn getCommitTreeOid(commit_data: []const u8) !types.ObjectId {
    return tree_diff.getCommitTreeOid(commit_data);
}

/// Get the index path for the repo.
fn getIndexPath(git_dir: []const u8, buf: []u8) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.writeAll(git_dir) catch return "";
    writer.writeAll("/index") catch return "";
    return buf[0..stream.pos];
}

fn getTimestamp(buf: []u8) []const u8 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return "0";
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{d}", .{ts.sec}) catch return "0";
    return buf[0..stream.pos];
}

/// Create a tree object from the current working tree state by reading the index
/// and scanning the working directory for modified files.
fn createWorkTreeTree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
) !types.ObjectId {
    const work_dir = getWorkDir(repo.git_dir);

    // Load the index
    var idx_path_buf: [4096]u8 = undefined;
    const idx_path = getIndexPath(repo.git_dir, &idx_path_buf);

    var idx = try index_mod.Index.readFromFile(allocator, idx_path);
    defer idx.deinit();

    // For each index entry, check if the working tree has a modified version
    // If so, write the modified content as a blob and use that OID
    var entries = std.array_list.Managed(checkout_mod.FlatTreeEntry).init(allocator);
    defer entries.deinit();
    var owned_paths = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (owned_paths.items) |p| allocator.free(p);
        owned_paths.deinit();
    }

    for (idx.entries.items) |*entry| {
        var file_path_buf: [4096]u8 = undefined;
        var fp_stream = std.io.fixedBufferStream(&file_path_buf);
        const fp_writer = fp_stream.writer();
        try fp_writer.writeAll(work_dir);
        try fp_writer.writeByte('/');
        try fp_writer.writeAll(entry.name);
        const full_path = file_path_buf[0..fp_stream.pos];

        // Try to read the working tree file
        var oid = entry.oid;
        const file = std.fs.openFileAbsolute(full_path, .{}) catch {
            // File doesn't exist in worktree; skip (deleted)
            continue;
        };
        defer file.close();

        const stat = file.stat() catch continue;
        if (stat.size <= 1024 * 1024) {
            const content = allocator.alloc(u8, @intCast(stat.size)) catch continue;
            defer allocator.free(content);
            const n = file.readAll(content) catch continue;
            const data = content[0..n];

            // Write as blob
            oid = loose.writeLooseObject(allocator, repo.git_dir, .blob, data) catch entry.oid;
        }

        const path_copy = try allocator.alloc(u8, entry.name.len);
        @memcpy(path_copy, entry.name);
        try owned_paths.append(path_copy);

        try entries.append(.{
            .path = path_copy,
            .mode = entry.mode,
            .oid = oid,
        });
    }

    // Build tree from the flat entries
    return createTreeFromFlat(allocator, repo.git_dir, entries.items);
}

/// Create a tree object from flat entries. Groups by directory and recurses.
fn createTreeFromFlat(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    entries: []const checkout_mod.FlatTreeEntry,
) !types.ObjectId {
    const TreeItem = struct {
        name: []const u8,
        mode: u32,
        oid: types.ObjectId,
        is_tree: bool,
    };

    var items = std.array_list.Managed(TreeItem).init(allocator);
    defer items.deinit();

    var sub_entries = std.StringHashMap(std.array_list.Managed(checkout_mod.FlatTreeEntry)).init(allocator);
    defer {
        var iter = sub_entries.valueIterator();
        while (iter.next()) |v| {
            v.deinit();
        }
        sub_entries.deinit();
    }

    for (entries) |entry| {
        const slash_pos = std.mem.indexOfScalar(u8, entry.path, '/');
        if (slash_pos) |sp| {
            const dir_name = entry.path[0..sp];
            const rest = entry.path[sp + 1 ..];
            const gop = try sub_entries.getOrPut(dir_name);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.array_list.Managed(checkout_mod.FlatTreeEntry).init(allocator);
            }
            try gop.value_ptr.append(.{
                .path = rest,
                .mode = entry.mode,
                .oid = entry.oid,
            });
        } else {
            try items.append(.{
                .name = entry.path,
                .mode = entry.mode,
                .oid = entry.oid,
                .is_tree = false,
            });
        }
    }

    var sub_iter = sub_entries.iterator();
    while (sub_iter.next()) |kv| {
        const sub_tree_oid = try createTreeFromFlat(allocator, git_dir, kv.value_ptr.items);
        try items.append(.{
            .name = kv.key_ptr.*,
            .mode = 0o40000,
            .oid = sub_tree_oid,
            .is_tree = true,
        });
    }

    // Sort items by name
    std.mem.sort(TreeItem, items.items, {}, struct {
        fn lessThan(_: void, a: TreeItem, b: TreeItem) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    // Serialize tree
    var tree_data = std.array_list.Managed(u8).init(allocator);
    defer tree_data.deinit();

    for (items.items) |*item| {
        var mode_buf: [16]u8 = undefined;
        var mode_stream = std.io.fixedBufferStream(&mode_buf);
        const mode_writer = mode_stream.writer();
        if (item.is_tree) {
            try mode_writer.writeAll("40000");
        } else {
            try mode_writer.print("{o}", .{item.mode});
        }
        try tree_data.appendSlice(mode_buf[0..mode_stream.pos]);
        try tree_data.append(' ');
        try tree_data.appendSlice(item.name);
        try tree_data.append(0);
        try tree_data.appendSlice(&item.oid.bytes);
    }

    return loose.writeLooseObject(allocator, git_dir, .tree, tree_data.items);
}

/// Create a commit object.
fn createCommitObject(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    tree_oid: types.ObjectId,
    parents: []const types.ObjectId,
    message: []const u8,
) !types.ObjectId {
    var commit_data = std.array_list.Managed(u8).init(allocator);
    defer commit_data.deinit();

    const tree_hex = tree_oid.toHex();
    try commit_data.appendSlice("tree ");
    try commit_data.appendSlice(&tree_hex);
    try commit_data.append('\n');

    for (parents) |parent| {
        const parent_hex = parent.toHex();
        try commit_data.appendSlice("parent ");
        try commit_data.appendSlice(&parent_hex);
        try commit_data.append('\n');
    }

    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    try commit_data.appendSlice("author zig-git <zig-git@localhost> ");
    try commit_data.appendSlice(timestamp);
    try commit_data.appendSlice(" +0000\n");
    try commit_data.appendSlice("committer zig-git <zig-git@localhost> ");
    try commit_data.appendSlice(timestamp);
    try commit_data.appendSlice(" +0000\n");
    try commit_data.append('\n');
    try commit_data.appendSlice(message);
    try commit_data.append('\n');

    return loose.writeLooseObject(allocator, git_dir, .commit, commit_data.items);
}

/// Write a blob to the working tree.
fn writeBlobToWorkTree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    work_dir: []const u8,
    rel_path: []const u8,
    oid: *const types.ObjectId,
    mode: u32,
) !void {
    var obj = try repo.readObject(allocator, oid);
    defer obj.deinit();

    if (obj.obj_type != .blob) return error.NotABlob;

    var path_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&path_buf);
    const writer = stream.writer();
    try writer.writeAll(work_dir);
    try writer.writeByte('/');
    try writer.writeAll(rel_path);
    const full_path = path_buf[0..stream.pos];

    const dir_end = std.mem.lastIndexOfScalar(u8, full_path, '/') orelse return error.InvalidPath;
    mkdirRecursive(full_path[0..dir_end]) catch {};

    const file = try std.fs.createFileAbsolute(full_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(obj.data);

    if (mode & 0o111 != 0) {
        const stat = try file.stat();
        const new_mode = stat.mode | 0o111;
        try file.chmod(new_mode);
    }
}

/// Build an index from a flat tree result.
fn buildIndexFromTree(
    allocator: std.mem.Allocator,
    flat: *const checkout_mod.FlatTreeResult,
) !index_mod.Index {
    var idx = index_mod.Index.init(allocator);
    errdefer idx.deinit();

    for (flat.entries.items) |*entry| {
        const name_copy = try allocator.alloc(u8, entry.path.len);
        @memcpy(name_copy, entry.path);

        try idx.addEntry(.{
            .ctime_s = 0,
            .ctime_ns = 0,
            .mtime_s = 0,
            .mtime_ns = 0,
            .dev = 0,
            .ino = 0,
            .mode = entry.mode,
            .uid = 0,
            .gid = 0,
            .file_size = 0,
            .oid = entry.oid,
            .flags = 0,
            .name = name_copy,
            .owned = true,
        });
    }

    return idx;
}

/// Main stash entry point.
pub fn runStash(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    // Parse subcommand
    if (args.len == 0 or std.mem.eql(u8, args[0], "push")) {
        return stashPush(repo, allocator);
    }

    if (std.mem.eql(u8, args[0], "list")) {
        return stashList(repo, allocator);
    }

    if (std.mem.eql(u8, args[0], "pop")) {
        const stash_index: usize = if (args.len > 1) parseStashIndex(args[1]) else 0;
        return stashPop(repo, allocator, stash_index);
    }

    if (std.mem.eql(u8, args[0], "apply")) {
        const stash_index: usize = if (args.len > 1) parseStashIndex(args[1]) else 0;
        return stashApply(repo, allocator, stash_index);
    }

    if (std.mem.eql(u8, args[0], "drop")) {
        const stash_index: usize = if (args.len > 1) parseStashIndex(args[1]) else 0;
        return stashDrop(repo, allocator, stash_index);
    }

    // If none of the above, treat as "push" (bare `stash` is the same as `stash push`)
    // But first check if it's an unrecognized subcommand
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "fatal: unknown stash subcommand: '{s}'\n", .{args[0]}) catch
        "fatal: unknown stash subcommand\n";
    try stderr_file.writeAll(msg);
    std.process.exit(1);
}

fn parseStashIndex(arg: []const u8) usize {
    // Accept "stash@{N}" or just "N"
    if (std.mem.startsWith(u8, arg, "stash@{")) {
        const end = std.mem.indexOfScalar(u8, arg, '}') orelse return 0;
        const num_str = arg[7..end];
        return std.fmt.parseInt(usize, num_str, 10) catch 0;
    }
    return std.fmt.parseInt(usize, arg, 10) catch 0;
}

/// Save working tree changes to stash.
fn stashPush(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    // Check that HEAD exists
    const head_oid = repo.resolveRef(allocator, "HEAD") catch {
        try stderr_file.writeAll("fatal: you do not have the initial commit yet\n");
        std.process.exit(128);
    };

    // Create a tree from the current working tree state
    const worktree_tree_oid = createWorkTreeTree(allocator, repo) catch {
        try stderr_file.writeAll("fatal: failed to create stash tree\n");
        std.process.exit(128);
    };

    // Check if there's anything to stash by comparing with HEAD tree
    var head_commit = try repo.readObject(allocator, &head_oid);
    defer head_commit.deinit();
    const head_tree_oid = try getCommitTreeOid(head_commit.data);

    if (std.mem.eql(u8, &worktree_tree_oid.bytes, &head_tree_oid.bytes)) {
        try stdout_file.writeAll("No local changes to save\n");
        return;
    }

    // Create a stash commit with HEAD as parent
    const parents = [_]types.ObjectId{head_oid};
    const stash_commit_oid = try createCommitObject(
        allocator,
        repo.git_dir,
        worktree_tree_oid,
        &parents,
        "WIP on stash",
    );

    // Update refs/stash
    const old_stash_oid = ref_mod.readRef(allocator, repo.git_dir, "refs/stash") catch types.ObjectId.ZERO;
    ref_mod.createRef(allocator, repo.git_dir, "refs/stash", stash_commit_oid, null) catch {
        try stderr_file.writeAll("fatal: failed to write stash ref\n");
        std.process.exit(128);
    };

    // Append reflog entry for refs/stash
    reflog_mod.appendReflog(repo.git_dir, "refs/stash", old_stash_oid, stash_commit_oid, "WIP on stash") catch {};

    // Reset working tree to HEAD
    const work_dir = getWorkDir(repo.git_dir);

    var head_flat = try checkout_mod.flattenTree(allocator, repo, &head_tree_oid);
    defer head_flat.deinit();

    // Write HEAD files to working tree
    for (head_flat.entries.items) |*entry| {
        writeBlobToWorkTree(allocator, repo, work_dir, entry.path, &entry.oid, entry.mode) catch {};
    }

    // Rebuild index from HEAD tree
    var new_idx = try buildIndexFromTree(allocator, &head_flat);
    defer new_idx.deinit();

    var idx_path_buf: [4096]u8 = undefined;
    const idx_path = getIndexPath(repo.git_dir, &idx_path_buf);
    try new_idx.writeToFile(idx_path);

    const hex = stash_commit_oid.toHex();
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Saved working directory and index state WIP on stash: {s}\n", .{hex[0..7]}) catch
        "Saved working directory state\n";
    try stdout_file.writeAll(msg);
}

/// List stash entries.
fn stashList(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    var result = reflog_mod.readReflog(allocator, repo.git_dir, "refs/stash") catch {
        // No stash reflog - nothing to show
        return;
    };
    defer result.deinit();

    if (result.entries.len == 0) return;

    // Print entries in reverse order (newest first)
    var i: usize = result.entries.len;
    while (i > 0) {
        i -= 1;
        const entry = result.entries[i];
        const idx = result.entries.len - 1 - i;
        const new_hex = entry.new_oid.toHex();

        var line_buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "stash@{{{d}}}: {s} {s}\n", .{
            idx,
            new_hex[0..7],
            entry.message,
        }) catch continue;
        try stdout_file.writeAll(line);
    }
}

/// Apply the most recent stash (or stash at given index) and drop it.
fn stashPop(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    stash_index: usize,
) !void {
    // Apply first
    try stashApply(repo, allocator, stash_index);
    // Then drop
    stashDrop(repo, allocator, stash_index) catch {};
}

/// Apply stash without dropping.
fn stashApply(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    stash_index: usize,
) !void {
    // Read the stash reflog to find the commit at the given index
    var result = reflog_mod.readReflog(allocator, repo.git_dir, "refs/stash") catch {
        try stderr_file.writeAll("fatal: no stash entries found\n");
        std.process.exit(128);
    };
    defer result.deinit();

    if (result.entries.len == 0) {
        try stderr_file.writeAll("fatal: no stash entries found\n");
        std.process.exit(128);
    }

    // Entries are in chronological order; index 0 = newest = last entry
    if (stash_index >= result.entries.len) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: stash@{{{d}}} is not a valid reference\n", .{stash_index}) catch
            "fatal: invalid stash reference\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    }

    const entry_idx = result.entries.len - 1 - stash_index;
    const stash_oid = result.entries[entry_idx].new_oid;

    // Read the stash commit
    var stash_commit = repo.readObject(allocator, &stash_oid) catch {
        try stderr_file.writeAll("fatal: failed to read stash commit\n");
        std.process.exit(128);
    };
    defer stash_commit.deinit();

    if (stash_commit.obj_type != .commit) {
        try stderr_file.writeAll("fatal: stash ref does not point to a commit\n");
        std.process.exit(128);
    }

    const stash_tree_oid = try getCommitTreeOid(stash_commit.data);
    const work_dir = getWorkDir(repo.git_dir);

    // Flatten stash tree and apply to working directory
    var stash_flat = try checkout_mod.flattenTree(allocator, repo, &stash_tree_oid);
    defer stash_flat.deinit();

    for (stash_flat.entries.items) |*entry| {
        writeBlobToWorkTree(allocator, repo, work_dir, entry.path, &entry.oid, entry.mode) catch {};
    }

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Applied stash@{{{d}}}\n", .{stash_index}) catch "Applied stash\n";
    try stdout_file.writeAll(msg);
}

/// Drop a stash entry.
fn stashDrop(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    stash_index: usize,
) !void {
    // Read existing reflog
    var result = reflog_mod.readReflog(allocator, repo.git_dir, "refs/stash") catch {
        try stderr_file.writeAll("fatal: no stash entries found\n");
        std.process.exit(128);
    };
    defer result.deinit();

    if (result.entries.len == 0) {
        try stderr_file.writeAll("fatal: no stash entries found\n");
        std.process.exit(128);
    }

    if (stash_index >= result.entries.len) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: stash@{{{d}}} is not a valid reference\n", .{stash_index}) catch
            "fatal: invalid stash reference\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    }

    // Entry to drop (index 0 = newest = last in array)
    const entry_idx = result.entries.len - 1 - stash_index;

    // Rewrite the reflog without the dropped entry
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..repo.git_dir.len], repo.git_dir);
    pos += repo.git_dir.len;
    const logs_suffix = "/logs/refs/stash";
    @memcpy(path_buf[pos..][0..logs_suffix.len], logs_suffix);
    pos += logs_suffix.len;
    const log_path = path_buf[0..pos];

    // Build new reflog content
    var new_content = std.array_list.Managed(u8).init(allocator);
    defer new_content.deinit();

    for (result.entries, 0..) |entry, i| {
        if (i == entry_idx) continue;

        const old_hex = entry.old_oid.toHex();
        const new_hex = entry.new_oid.toHex();

        try new_content.appendSlice(&old_hex);
        try new_content.append(' ');
        try new_content.appendSlice(&new_hex);
        try new_content.append(' ');
        try new_content.appendSlice(entry.name);
        try new_content.appendSlice(" <");
        try new_content.appendSlice(entry.email);
        try new_content.appendSlice("> ");
        try new_content.appendSlice(entry.timestamp);
        try new_content.append(' ');
        try new_content.appendSlice(entry.timezone);
        try new_content.append('\t');
        try new_content.appendSlice(entry.message);
        try new_content.append('\n');
    }

    // Write the reflog
    const dir_end = std.mem.lastIndexOfScalar(u8, log_path, '/') orelse return error.InvalidRefName;
    mkdirRecursive(log_path[0..dir_end]) catch {};

    const file = std.fs.createFileAbsolute(log_path, .{ .truncate = true }) catch {
        try stderr_file.writeAll("fatal: failed to rewrite stash reflog\n");
        std.process.exit(128);
    };
    defer file.close();
    try file.writeAll(new_content.items);

    // If no entries remain, delete refs/stash
    if (result.entries.len <= 1) {
        ref_mod.deleteRef(repo.git_dir, "refs/stash") catch {};
        // Also delete the reflog file
        std.fs.deleteFileAbsolute(log_path) catch {};
    } else {
        // Update refs/stash to point to the new top entry
        // The new top is the last remaining entry
        var new_top_oid = types.ObjectId.ZERO;
        var found = false;
        // Walk from the end to find the newest remaining entry
        var idx: usize = result.entries.len;
        while (idx > 0) {
            idx -= 1;
            if (idx != entry_idx) {
                new_top_oid = result.entries[idx].new_oid;
                found = true;
                break;
            }
        }
        if (found) {
            ref_mod.createRef(allocator, repo.git_dir, "refs/stash", new_top_oid, null) catch {};
        }
    }

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Dropped stash@{{{d}}}\n", .{stash_index}) catch "Dropped stash\n";
    try stdout_file.writeAll(msg);
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
