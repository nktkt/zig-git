const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const ignore_mod = @import("ignore.zig");
const hash_mod = @import("hash.zig");

/// Status codes for the two-column format (index vs HEAD, worktree vs index).
const StatusEntry = struct {
    index_status: u8, // ' ', 'A', 'M', 'D'
    worktree_status: u8, // ' ', 'M', 'D', '?'
    path: []const u8,
};

pub fn runStatus(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    stderr: std.fs.File,
) !void {
    // Load the index
    var index_path_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&index_path_buf);
    var writer = stream.writer();
    try writer.writeAll(repo.git_dir);
    try writer.writeAll("/index");
    const index_path = index_path_buf[0..stream.pos];

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    // Load HEAD tree entries (flattened)
    var head_entries = std.StringHashMap(types.ObjectId).init(allocator);
    defer {
        var ki = head_entries.keyIterator();
        while (ki.next()) |key| {
            allocator.free(key.*);
        }
        head_entries.deinit();
    }
    try loadHeadTree(repo, allocator, &head_entries);

    // Load ignore rules
    var ignore = ignore_mod.IgnoreRules.init(allocator);
    defer ignore.deinit();

    // Load .git/info/exclude
    ignore.loadExclude(repo.git_dir) catch {};

    // Load .gitignore from working directory root
    const work_dir = getWorkDir(repo.git_dir);
    ignore.loadGitignore(work_dir) catch {};

    // Always ignore .git directory
    // (we handle this specially in the untracked file scan)

    // Collect results
    var results = std.array_list.Managed(StatusEntry).init(allocator);
    defer results.deinit();

    // 1) Compare HEAD vs index -> staged changes
    // Check each index entry against HEAD
    for (idx.entries.items) |*entry| {
        if (head_entries.get(entry.name)) |head_oid| {
            if (!head_oid.eql(&entry.oid)) {
                // Modified in index compared to HEAD
                try results.append(.{ .index_status = 'M', .worktree_status = ' ', .path = entry.name });
            }
            // Remove from head_entries so we can find deletions; free the owned key
            if (head_entries.fetchRemove(entry.name)) |kv| {
                allocator.free(kv.key);
            }
        } else {
            // New file in index (not in HEAD)
            try results.append(.{ .index_status = 'A', .worktree_status = ' ', .path = entry.name });
        }
    }

    // Remaining head_entries are files deleted from index
    var head_iter = head_entries.iterator();
    while (head_iter.next()) |kv| {
        try results.append(.{ .index_status = 'D', .worktree_status = ' ', .path = kv.key_ptr.* });
    }

    // 2) Compare index vs working tree -> unstaged changes
    for (idx.entries.items) |*entry| {
        const wt_status = checkWorktreeStatus(work_dir, entry);
        if (wt_status != ' ') {
            // Check if we already have a staged entry for this path
            var found = false;
            for (results.items) |*r| {
                if (std.mem.eql(u8, r.path, entry.name)) {
                    r.worktree_status = wt_status;
                    found = true;
                    break;
                }
            }
            if (!found) {
                try results.append(.{ .index_status = ' ', .worktree_status = wt_status, .path = entry.name });
            }
        }
    }

    // 3) Find untracked files
    var untracked = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (untracked.items) |p| allocator.free(p);
        untracked.deinit();
    }
    try findUntrackedFiles(allocator, work_dir, &idx, &ignore, &untracked, "");

    // Sort results by path
    sortResults(results.items);

    // Print staged + unstaged
    var buf: [4096]u8 = undefined;
    for (results.items) |*r| {
        const line = std.fmt.bufPrint(&buf, "{c}{c} {s}\n", .{ r.index_status, r.worktree_status, r.path }) catch continue;
        try stdout.writeAll(line);
    }

    // Print untracked
    // Sort untracked
    sortStrings(untracked.items);
    for (untracked.items) |path| {
        const line = std.fmt.bufPrint(&buf, "?? {s}\n", .{path}) catch continue;
        try stdout.writeAll(line);
    }

    _ = stderr;
}

fn sortResults(items: []StatusEntry) void {
    // Simple insertion sort (sufficient for typical repo sizes)
    for (items, 0..) |_, i| {
        if (i == 0) continue;
        var j = i;
        while (j > 0 and std.mem.order(u8, items[j].path, items[j - 1].path) == .lt) {
            const tmp = items[j];
            items[j] = items[j - 1];
            items[j - 1] = tmp;
            j -= 1;
        }
    }
}

fn sortStrings(items: [][]const u8) void {
    for (items, 0..) |_, i| {
        if (i == 0) continue;
        var j = i;
        while (j > 0 and std.mem.order(u8, items[j], items[j - 1]) == .lt) {
            const tmp = items[j];
            items[j] = items[j - 1];
            items[j - 1] = tmp;
            j -= 1;
        }
    }
}

/// Load the tree from HEAD commit, returning a flat map of path -> oid.
fn loadHeadTree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    entries: *std.StringHashMap(types.ObjectId),
) !void {
    // Read HEAD ref
    var head_path_buf: [4096]u8 = undefined;
    var s = std.io.fixedBufferStream(&head_path_buf);
    var w = s.writer();
    try w.writeAll(repo.git_dir);
    try w.writeAll("/HEAD");
    const head_path = head_path_buf[0..s.pos];

    const head_content = readFileContents(allocator, head_path) catch return;
    defer allocator.free(head_content);

    const trimmed = std.mem.trimRight(u8, head_content, "\n\r ");

    var commit_oid: types.ObjectId = undefined;

    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        // Resolve the ref
        const ref_name = trimmed[5..];
        var ref_path_buf: [4096]u8 = undefined;
        var rs = std.io.fixedBufferStream(&ref_path_buf);
        var rw = rs.writer();
        try rw.writeAll(repo.git_dir);
        try rw.writeByte('/');
        try rw.writeAll(ref_name);
        const ref_path = ref_path_buf[0..rs.pos];

        const ref_content = readFileContents(allocator, ref_path) catch return;
        defer allocator.free(ref_content);
        const ref_trimmed = std.mem.trimRight(u8, ref_content, "\n\r ");
        if (ref_trimmed.len < types.OID_HEX_LEN) return;
        commit_oid = types.ObjectId.fromHex(ref_trimmed[0..types.OID_HEX_LEN]) catch return;
    } else {
        if (trimmed.len < types.OID_HEX_LEN) return;
        commit_oid = types.ObjectId.fromHex(trimmed[0..types.OID_HEX_LEN]) catch return;
    }

    // Read commit object to get tree
    var commit_obj = repo.readObject(allocator, &commit_oid) catch return;
    defer commit_obj.deinit();

    if (commit_obj.obj_type != .commit) return;

    // Parse tree OID from commit
    const tree_prefix = "tree ";
    if (!std.mem.startsWith(u8, commit_obj.data, tree_prefix)) return;
    const newline = std.mem.indexOfScalar(u8, commit_obj.data, '\n') orelse return;
    if (newline < tree_prefix.len + types.OID_HEX_LEN) return;
    const tree_hex = commit_obj.data[tree_prefix.len..][0..types.OID_HEX_LEN];
    const tree_oid = types.ObjectId.fromHex(tree_hex) catch return;

    // Recursively walk the tree
    try walkTree(repo, allocator, &tree_oid, entries, "");
}

fn walkTree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    tree_oid: *const types.ObjectId,
    entries: *std.StringHashMap(types.ObjectId),
    prefix: []const u8,
) !void {
    var tree_obj = repo.readObject(allocator, tree_oid) catch return;
    defer tree_obj.deinit();

    if (tree_obj.obj_type != .tree) return;

    var pos: usize = 0;
    const data = tree_obj.data;

    while (pos < data.len) {
        // Format: "mode name\0sha1"
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse return;
        const mode = data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, data, space_pos + 1, 0) orelse return;
        const name = data[space_pos + 1 .. null_pos];

        if (null_pos + 1 + types.OID_RAW_LEN > data.len) return;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, data[null_pos + 1 ..][0..types.OID_RAW_LEN]);
        pos = null_pos + 1 + types.OID_RAW_LEN;

        // Build full path
        var full_path_buf: [4096]u8 = undefined;
        var fp_stream = std.io.fixedBufferStream(&full_path_buf);
        const fp_writer = fp_stream.writer();
        if (prefix.len > 0) {
            fp_writer.writeAll(prefix) catch continue;
            fp_writer.writeByte('/') catch continue;
        }
        fp_writer.writeAll(name) catch continue;
        const full_path_slice = full_path_buf[0..fp_stream.pos];

        if (std.mem.eql(u8, mode, "40000")) {
            // Recurse into subdirectory
            try walkTree(repo, allocator, &oid, entries, full_path_slice);
        } else {
            // It's a blob (or submodule, etc.) - store the entry
            const owned_path = try allocator.alloc(u8, full_path_slice.len);
            @memcpy(owned_path, full_path_slice);
            try entries.put(owned_path, oid);
        }
    }
}

/// Check if a working tree file differs from the index entry.
fn checkWorktreeStatus(work_dir: []const u8, entry: *const index_mod.IndexEntry) u8 {
    var path_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&path_buf);
    const writer = stream.writer();
    writer.writeAll(work_dir) catch return ' ';
    writer.writeByte('/') catch return ' ';
    writer.writeAll(entry.name) catch return ' ';
    const full_path = path_buf[0..stream.pos];

    const file = std.fs.openFileAbsolute(full_path, .{}) catch {
        return 'D'; // File missing from worktree
    };
    defer file.close();

    const stat = file.stat() catch return ' ';

    // Quick check: if size differs, it's modified
    if (@as(u32, @intCast(stat.size)) != entry.file_size) return 'M';

    // Check mtime - if same, assume unchanged
    const mtime_s: u32 = if (stat.mtime >= 0) @intCast(@as(u64, @intCast(@divFloor(stat.mtime, 1_000_000_000)))) else 0;
    const mtime_ns: u32 = if (stat.mtime >= 0) @intCast(@as(u64, @intCast(@mod(stat.mtime, 1_000_000_000)))) else 0;
    if (mtime_s == entry.mtime_s and mtime_ns == entry.mtime_ns) return ' ';

    // mtime changed - need to compare content hash
    // Read file and compute SHA-1 of "blob SIZE\0CONTENT"
    // If file is larger than 1MB, assume modified to avoid huge stack allocation
    if (stat.size > 1024 * 1024) return 'M';
    var content_buf: [1024 * 1024]u8 = undefined;
    const file_size: usize = @intCast(stat.size);
    const n = file.readAll(content_buf[0..file_size]) catch return 'M';
    const content = content_buf[0..n];

    var header_buf: [64]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    hwriter.writeAll("blob ") catch return 'M';
    hwriter.print("{d}", .{n}) catch return 'M';
    hwriter.writeByte(0) catch return 'M';
    const header = header_buf[0..hstream.pos];

    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(header);
    hasher.update(content);
    const digest = hasher.finalResult();
    const computed_oid = types.ObjectId{ .bytes = digest };

    if (computed_oid.eql(&entry.oid)) return ' ';
    return 'M';
}

/// Find untracked files in the working tree.
fn findUntrackedFiles(
    allocator: std.mem.Allocator,
    work_dir: []const u8,
    idx: *const index_mod.Index,
    ignore: *const ignore_mod.IgnoreRules,
    results: *std.array_list.Managed([]const u8),
    prefix: []const u8,
) !void {
    var dir_path_buf: [4096]u8 = undefined;
    var ds = std.io.fixedBufferStream(&dir_path_buf);
    const dw = ds.writer();
    try dw.writeAll(work_dir);
    if (prefix.len > 0) {
        try dw.writeByte('/');
        try dw.writeAll(prefix);
    }
    const dir_path = dir_path_buf[0..ds.pos];

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip .git directory
        if (std.mem.eql(u8, entry.name, ".git")) continue;

        // Build relative path
        var rel_path_buf: [4096]u8 = undefined;
        var rs = std.io.fixedBufferStream(&rel_path_buf);
        const rw = rs.writer();
        if (prefix.len > 0) {
            try rw.writeAll(prefix);
            try rw.writeByte('/');
        }
        try rw.writeAll(entry.name);
        const rel_path = rel_path_buf[0..rs.pos];

        const is_dir = entry.kind == .directory;

        // Check ignore rules
        if (ignore.isIgnored(rel_path, is_dir)) continue;

        if (is_dir) {
            // Check if any index entries have this directory as a prefix
            var has_tracked = false;
            var dir_prefix_buf: [4096]u8 = undefined;
            var dps = std.io.fixedBufferStream(&dir_prefix_buf);
            const dpw = dps.writer();
            try dpw.writeAll(rel_path);
            try dpw.writeByte('/');
            const dir_prefix = dir_prefix_buf[0..dps.pos];

            for (idx.entries.items) |*ie| {
                if (std.mem.startsWith(u8, ie.name, dir_prefix)) {
                    has_tracked = true;
                    break;
                }
            }

            if (has_tracked) {
                // Recurse into directory
                try findUntrackedFiles(allocator, work_dir, idx, ignore, results, rel_path);
            } else {
                // Show directory as untracked (with trailing /)
                var display_buf: [4096]u8 = undefined;
                var dbs = std.io.fixedBufferStream(&display_buf);
                const dbw = dbs.writer();
                try dbw.writeAll(rel_path);
                try dbw.writeByte('/');
                const display = display_buf[0..dbs.pos];
                const owned = try allocator.alloc(u8, display.len);
                @memcpy(owned, display);
                try results.append(owned);
            }
        } else {
            // Check if file is in index
            if (idx.findEntry(rel_path) == null) {
                const owned = try allocator.alloc(u8, rel_path.len);
                @memcpy(owned, rel_path);
                try results.append(owned);
            }
        }
    }
}

/// Extract the working directory from git_dir (strip /.git suffix).
fn getWorkDir(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    // Bare repo or unusual layout - return git_dir parent
    if (std.fs.path.dirname(git_dir)) |parent| {
        return parent;
    }
    return git_dir;
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
