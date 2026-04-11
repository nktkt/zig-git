const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");
const loose = @import("loose.zig");
const tree_diff = @import("tree_diff.zig");
const checkout_mod = @import("checkout.zig");
const config_mod = @import("config.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Find the merge base (common ancestor) of two commits using BFS.
/// Returns null if no common ancestor is found.
pub fn findMergeBase(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    oid1: *const types.ObjectId,
    oid2: *const types.ObjectId,
) !?types.ObjectId {
    if (oid1.eql(oid2)) return oid1.*;

    // BFS from both commits simultaneously
    // We use two sets: ancestors reachable from oid1, ancestors reachable from oid2
    // When we find a commit that's in both sets, that's the merge base.

    const OidKey = [types.OID_RAW_LEN]u8;

    var visited1 = std.AutoHashMap(OidKey, void).init(allocator);
    defer visited1.deinit();
    var visited2 = std.AutoHashMap(OidKey, void).init(allocator);
    defer visited2.deinit();

    var queue1 = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue1.deinit();
    var queue2 = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue2.deinit();

    try queue1.append(oid1.*);
    try visited1.put(oid1.bytes, {});
    try queue2.append(oid2.*);
    try visited2.put(oid2.bytes, {});

    // Alternate BFS steps between both queues
    const max_iterations: usize = 10000;
    var iteration: usize = 0;

    while ((queue1.items.len > 0 or queue2.items.len > 0) and iteration < max_iterations) {
        iteration += 1;

        // Step from queue1
        if (queue1.items.len > 0) {
            const current = queue1.orderedRemove(0);
            // Check if this commit is also reachable from oid2
            if (visited2.contains(current.bytes)) {
                return current;
            }
            // Add parents to queue
            try addParentsToQueue(allocator, repo, &current, &queue1, &visited1);
        }

        // Step from queue2
        if (queue2.items.len > 0) {
            const current = queue2.orderedRemove(0);
            // Check if this commit is also reachable from oid1
            if (visited1.contains(current.bytes)) {
                return current;
            }
            try addParentsToQueue(allocator, repo, &current, &queue2, &visited2);
        }
    }

    return null;
}

fn addParentsToQueue(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    oid: *const types.ObjectId,
    queue: *std.array_list.Managed(types.ObjectId),
    visited: *std.AutoHashMap([types.OID_RAW_LEN]u8, void),
) !void {
    var obj = repo.readObject(allocator, oid) catch return;
    defer obj.deinit();

    if (obj.obj_type != .commit) return;

    var parents = try tree_diff.getCommitParents(allocator, obj.data);
    defer parents.deinit();

    for (parents.items) |parent_oid| {
        if (!visited.contains(parent_oid.bytes)) {
            try visited.put(parent_oid.bytes, {});
            try queue.append(parent_oid);
        }
    }
}

/// Check if ancestor_oid is an ancestor of descendant_oid.
fn isAncestor(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    ancestor_oid: *const types.ObjectId,
    descendant_oid: *const types.ObjectId,
) !bool {
    if (ancestor_oid.eql(descendant_oid)) return true;

    const OidKey = [types.OID_RAW_LEN]u8;
    var visited = std.AutoHashMap(OidKey, void).init(allocator);
    defer visited.deinit();

    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();

    try queue.append(descendant_oid.*);
    try visited.put(descendant_oid.bytes, {});

    const max_iterations: usize = 10000;
    var iteration: usize = 0;

    while (queue.items.len > 0 and iteration < max_iterations) {
        iteration += 1;
        const current = queue.orderedRemove(0);

        var obj = repo.readObject(allocator, &current) catch continue;
        defer obj.deinit();

        if (obj.obj_type != .commit) continue;

        var parents = tree_diff.getCommitParents(allocator, obj.data) catch continue;
        defer parents.deinit();

        for (parents.items) |parent_oid| {
            if (parent_oid.eql(ancestor_oid)) return true;
            if (!visited.contains(parent_oid.bytes)) {
                try visited.put(parent_oid.bytes, {});
                try queue.append(parent_oid);
            }
        }
    }

    return false;
}

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

/// Get the commit tree OID from commit data.
fn getCommitTreeOid(commit_data: []const u8) !types.ObjectId {
    return tree_diff.getCommitTreeOid(commit_data);
}

/// Create a tree object from a flat list of entries.
/// This builds proper nested tree objects in the object database.
fn createTreeFromFlat(
    allocator: std.mem.Allocator,
    repo_git_dir: []const u8,
    entries: []const checkout_mod.FlatTreeEntry,
) !types.ObjectId {
    // Group entries by top-level directory component
    // Build tree objects bottom-up.
    // For simplicity, we group by the first path component.

    const TreeItem = struct {
        name: []const u8,
        mode: u32,
        oid: types.ObjectId,
        is_tree: bool,
    };

    var items = std.array_list.Managed(TreeItem).init(allocator);
    defer items.deinit();

    // Collect top-level entries and recursively handle subdirectories
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
            // Top-level file
            try items.append(.{
                .name = entry.path,
                .mode = entry.mode,
                .oid = entry.oid,
                .is_tree = false,
            });
        }
    }

    // Recursively create tree objects for subdirectories
    var sub_iter = sub_entries.iterator();
    while (sub_iter.next()) |kv| {
        const sub_tree_oid = try createTreeFromFlat(allocator, repo_git_dir, kv.value_ptr.items);
        try items.append(.{
            .name = kv.key_ptr.*,
            .mode = 0o40000,
            .oid = sub_tree_oid,
            .is_tree = true,
        });
    }

    // Sort items by name (with trees getting trailing / for sorting, matching git convention)
    std.mem.sort(TreeItem, items.items, {}, struct {
        fn lessThan(_: void, a: TreeItem, b: TreeItem) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    // Serialize the tree object
    var tree_data = std.array_list.Managed(u8).init(allocator);
    defer tree_data.deinit();

    for (items.items) |*item| {
        // mode as octal string
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

    // Write the tree object
    return loose.writeLooseObject(allocator, repo_git_dir, .tree, tree_data.items) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Object already exists - compute the OID
            var header_buf: [64]u8 = undefined;
            var hstream = std.io.fixedBufferStream(&header_buf);
            const hwriter = hstream.writer();
            hwriter.writeAll("tree ") catch unreachable;
            hwriter.print("{d}", .{tree_data.items.len}) catch unreachable;
            hwriter.writeByte(0) catch unreachable;
            const header = header_buf[0..hstream.pos];

            const hash_mod = @import("hash.zig");
            var hasher = hash_mod.Sha1.init(.{});
            hasher.update(header);
            hasher.update(tree_data.items);
            return types.ObjectId{ .bytes = hasher.finalResult() };
        },
        else => return err,
    };
}

/// Create a commit object in the object database.
fn createCommitObject(
    allocator: std.mem.Allocator,
    repo_git_dir: []const u8,
    tree_oid: types.ObjectId,
    parents: []const types.ObjectId,
    message: []const u8,
) !types.ObjectId {
    var commit_data = std.array_list.Managed(u8).init(allocator);
    defer commit_data.deinit();

    // tree line
    const tree_hex = tree_oid.toHex();
    try commit_data.appendSlice("tree ");
    try commit_data.appendSlice(&tree_hex);
    try commit_data.append('\n');

    // parent lines
    for (parents) |parent| {
        const parent_hex = parent.toHex();
        try commit_data.appendSlice("parent ");
        try commit_data.appendSlice(&parent_hex);
        try commit_data.append('\n');
    }

    // Read author info from config
    var name_buf: [256]u8 = undefined;
    var email_buf: [256]u8 = undefined;
    var author_name: []const u8 = "zig-git";
    var author_email: []const u8 = "zig-git@localhost";
    {
        var cfg_path_buf: [4096]u8 = undefined;
        @memcpy(cfg_path_buf[0..repo_git_dir.len], repo_git_dir);
        const cfg_suffix = "/config";
        @memcpy(cfg_path_buf[repo_git_dir.len..][0..cfg_suffix.len], cfg_suffix);
        const cfg_path = cfg_path_buf[0 .. repo_git_dir.len + cfg_suffix.len];

        var cfg = config_mod.Config.loadFile(allocator, cfg_path) catch config_mod.Config.init(allocator);
        defer cfg.deinit();

        if (cfg.get("user.name")) |n| {
            if (n.len <= name_buf.len) {
                @memcpy(name_buf[0..n.len], n);
                author_name = name_buf[0..n.len];
            }
        }
        if (cfg.get("user.email")) |e| {
            if (e.len <= email_buf.len) {
                @memcpy(email_buf[0..e.len], e);
                author_email = email_buf[0..e.len];
            }
        }
    }

    // author and committer
    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    try commit_data.appendSlice("author ");
    try commit_data.appendSlice(author_name);
    try commit_data.appendSlice(" <");
    try commit_data.appendSlice(author_email);
    try commit_data.appendSlice("> ");
    try commit_data.appendSlice(timestamp);
    try commit_data.appendSlice(" +0000\n");
    try commit_data.appendSlice("committer ");
    try commit_data.appendSlice(author_name);
    try commit_data.appendSlice(" <");
    try commit_data.appendSlice(author_email);
    try commit_data.appendSlice("> ");
    try commit_data.appendSlice(timestamp);
    try commit_data.appendSlice(" +0000\n");
    try commit_data.append('\n');
    try commit_data.appendSlice(message);
    try commit_data.append('\n');

    const oid = loose.writeLooseObject(allocator, repo_git_dir, .commit, commit_data.items) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Object already exists - compute the OID
            var header_buf2: [64]u8 = undefined;
            var hstream2 = std.io.fixedBufferStream(&header_buf2);
            const hwriter2 = hstream2.writer();
            hwriter2.writeAll("commit ") catch unreachable;
            hwriter2.print("{d}", .{commit_data.items.len}) catch unreachable;
            hwriter2.writeByte(0) catch unreachable;
            const header2 = header_buf2[0..hstream2.pos];

            const hash_mod = @import("hash.zig");
            var hasher2 = hash_mod.Sha1.init(.{});
            hasher2.update(header2);
            hasher2.update(commit_data.items);
            return types.ObjectId{ .bytes = hasher2.finalResult() };
        },
        else => return err,
    };
    return oid;
}

fn getTimestamp(buf: []u8) []const u8 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return "0";
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{d}", .{ts.sec}) catch return "0";
    return buf[0..stream.pos];
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

/// Delete a file from the working tree.
fn deleteFromWorkTree(work_dir: []const u8, rel_path: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&path_buf);
    const writer = stream.writer();
    writer.writeAll(work_dir) catch return;
    writer.writeByte('/') catch return;
    writer.writeAll(rel_path) catch return;
    const full_path = path_buf[0..stream.pos];

    std.fs.deleteFileAbsolute(full_path) catch {};
    removeEmptyParents(work_dir, full_path);
}

fn removeEmptyParents(work_dir: []const u8, path: []const u8) void {
    var current = path;
    while (true) {
        const parent = std.fs.path.dirname(current) orelse return;
        if (parent.len <= work_dir.len) return;
        std.fs.deleteDirAbsolute(parent) catch return;
        current = parent;
    }
}

/// Perform line-by-line three-way merge. Returns merged content and whether there were conflicts.
fn threeWayMergeContent(
    allocator: std.mem.Allocator,
    base_data: []const u8,
    ours_data: []const u8,
    theirs_data: []const u8,
    target_name: []const u8,
) !struct { content: []u8, has_conflict: bool } {
    // Split all three into lines
    var base_lines = std.array_list.Managed([]const u8).init(allocator);
    defer base_lines.deinit();
    var ours_lines = std.array_list.Managed([]const u8).init(allocator);
    defer ours_lines.deinit();
    var theirs_lines = std.array_list.Managed([]const u8).init(allocator);
    defer theirs_lines.deinit();

    splitIntoLines(base_data, &base_lines) catch {};
    splitIntoLines(ours_data, &ours_lines) catch {};
    splitIntoLines(theirs_data, &theirs_lines) catch {};

    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    var has_conflict = false;

    // Simple line-by-line merge: walk all three in lockstep
    const max_len = @max(base_lines.items.len, @max(ours_lines.items.len, theirs_lines.items.len));
    var i: usize = 0;

    while (i < max_len) : (i += 1) {
        const base_line: ?[]const u8 = if (i < base_lines.items.len) base_lines.items[i] else null;
        const ours_line: ?[]const u8 = if (i < ours_lines.items.len) ours_lines.items[i] else null;
        const theirs_line: ?[]const u8 = if (i < theirs_lines.items.len) theirs_lines.items[i] else null;

        const base_eq_ours = strEql(base_line, ours_line);
        const base_eq_theirs = strEql(base_line, theirs_line);
        const ours_eq_theirs = strEql(ours_line, theirs_line);

        if (base_eq_ours and base_eq_theirs) {
            // All same - emit
            if (ours_line) |l| {
                try result.appendSlice(l);
                try result.append('\n');
            }
        } else if (base_eq_ours and !base_eq_theirs) {
            // Changed only in theirs - take theirs
            if (theirs_line) |l| {
                try result.appendSlice(l);
                try result.append('\n');
            }
            // theirs_line == null means deleted in theirs, don't emit
        } else if (!base_eq_ours and base_eq_theirs) {
            // Changed only in ours - take ours
            if (ours_line) |l| {
                try result.appendSlice(l);
                try result.append('\n');
            }
            // ours_line == null means deleted in ours, don't emit
        } else if (ours_eq_theirs) {
            // Both changed same way - take either
            if (ours_line) |l| {
                try result.appendSlice(l);
                try result.append('\n');
            }
        } else {
            // Conflict: both sides changed differently
            has_conflict = true;
            try result.appendSlice("<<<<<<< HEAD\n");
            if (ours_line) |l| {
                try result.appendSlice(l);
                try result.append('\n');
            }
            try result.appendSlice("=======\n");
            if (theirs_line) |l| {
                try result.appendSlice(l);
                try result.append('\n');
            }
            var marker_buf: [256]u8 = undefined;
            const marker = std.fmt.bufPrint(&marker_buf, ">>>>>>> {s}\n", .{target_name}) catch ">>>>>>> merge\n";
            try result.appendSlice(marker);
        }
    }

    return .{ .content = try result.toOwnedSlice(), .has_conflict = has_conflict };
}

fn splitIntoLines(text: []const u8, lines: *std.array_list.Managed([]const u8)) !void {
    if (text.len == 0) return;
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        if (iter.peek() == null and line.len == 0) break;
        try lines.append(line);
    }
}

fn strEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Write conflict markers for a file with proper branch name.
fn writeConflictFile(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    work_dir: []const u8,
    rel_path: []const u8,
    base_oid: ?*const types.ObjectId,
    ours_oid: ?*const types.ObjectId,
    theirs_oid: ?*const types.ObjectId,
    target_name: []const u8,
) !void {
    var base_data: []const u8 = "";
    var base_obj: ?types.Object = null;
    defer if (base_obj) |*o| o.deinit();

    if (base_oid) |oid| {
        const obj = repo.readObject(allocator, oid) catch null;
        if (obj) |o| {
            base_obj = o;
            base_data = o.data;
        }
    }

    var ours_data: []const u8 = "";
    var ours_obj: ?types.Object = null;
    defer if (ours_obj) |*o| o.deinit();

    if (ours_oid) |oid| {
        const obj = try repo.readObject(allocator, oid);
        ours_obj = obj;
        ours_data = obj.data;
    }

    var theirs_data: []const u8 = "";
    var theirs_obj: ?types.Object = null;
    defer if (theirs_obj) |*o| o.deinit();

    if (theirs_oid) |oid| {
        const obj = try repo.readObject(allocator, oid);
        theirs_obj = obj;
        theirs_data = obj.data;
    }

    // Try line-by-line 3-way merge
    const merge_result = threeWayMergeContent(allocator, base_data, ours_data, theirs_data, target_name) catch {
        // Fallback to simple conflict markers
        var content = std.array_list.Managed(u8).init(allocator);
        defer content.deinit();

        try content.appendSlice("<<<<<<< HEAD\n");
        try content.appendSlice(ours_data);
        if (ours_data.len > 0 and ours_data[ours_data.len - 1] != '\n') {
            try content.append('\n');
        }
        try content.appendSlice("=======\n");
        try content.appendSlice(theirs_data);
        if (theirs_data.len > 0 and theirs_data[theirs_data.len - 1] != '\n') {
            try content.append('\n');
        }
        var marker_buf2: [256]u8 = undefined;
        const marker2 = std.fmt.bufPrint(&marker_buf2, ">>>>>>> {s}\n", .{target_name}) catch ">>>>>>> merge\n";
        try content.appendSlice(marker2);

        try writeToPath(work_dir, rel_path, content.items);
        return;
    };
    defer allocator.free(merge_result.content);

    try writeToPath(work_dir, rel_path, merge_result.content);
}

fn writeToPath(work_dir: []const u8, rel_path: []const u8, content: []const u8) !void {
    // Write to working tree
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
    try file.writeAll(content);
}

/// Write MERGE_HEAD file.
fn writeMergeHead(git_dir: []const u8, oid: types.ObjectId) !void {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    const suffix = "/MERGE_HEAD";
    @memcpy(path_buf[git_dir.len..][0..suffix.len], suffix);
    const path = path_buf[0 .. git_dir.len + suffix.len];

    const hex = oid.toHex();
    var content_buf: [types.OID_HEX_LEN + 1]u8 = undefined;
    @memcpy(content_buf[0..types.OID_HEX_LEN], &hex);
    content_buf[types.OID_HEX_LEN] = '\n';

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(&content_buf);
}

/// Write MERGE_MSG file.
fn writeMergeMsg(git_dir: []const u8, message: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    const suffix = "/MERGE_MSG";
    @memcpy(path_buf[git_dir.len..][0..suffix.len], suffix);
    const path = path_buf[0 .. git_dir.len + suffix.len];

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(message);
    try file.writeAll("\n");
}

/// Remove MERGE_HEAD and MERGE_MSG files.
fn removeMergeState(git_dir: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);

    const mh_suffix = "/MERGE_HEAD";
    @memcpy(path_buf[git_dir.len..][0..mh_suffix.len], mh_suffix);
    std.fs.deleteFileAbsolute(path_buf[0 .. git_dir.len + mh_suffix.len]) catch {};

    const mm_suffix = "/MERGE_MSG";
    @memcpy(path_buf[git_dir.len..][0..mm_suffix.len], mm_suffix);
    std.fs.deleteFileAbsolute(path_buf[0 .. git_dir.len + mm_suffix.len]) catch {};
}

/// Check if a merge is in progress.
fn mergeInProgress(git_dir: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    const suffix = "/MERGE_HEAD";
    @memcpy(path_buf[git_dir.len..][0..suffix.len], suffix);
    const path = path_buf[0 .. git_dir.len + suffix.len];

    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

/// Build an index from a flattened tree.
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

/// Main merge entry point.
pub fn runMerge(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    // Parse args
    var abort = false;
    var no_commit = false;
    var squash = false;
    var target_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--abort")) {
            abort = true;
        } else if (std.mem.eql(u8, arg, "--no-commit")) {
            no_commit = true;
        } else if (std.mem.eql(u8, arg, "--squash")) {
            squash = true;
            no_commit = true; // squash implies no-commit
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (target_name == null) {
                target_name = arg;
            }
        }
    }

    if (abort) {
        return mergeAbort(repo, allocator);
    }

    if (target_name == null) {
        try stderr_file.writeAll("fatal: you must specify a branch to merge\n");
        std.process.exit(1);
    }

    // Check if merge already in progress
    if (mergeInProgress(repo.git_dir)) {
        try stderr_file.writeAll("fatal: you have not concluded your merge (MERGE_HEAD exists).\nPlease, commit your changes before you merge.\n");
        std.process.exit(128);
    }

    // Resolve HEAD
    const head_oid = repo.resolveRef(allocator, "HEAD") catch {
        try stderr_file.writeAll("fatal: not a valid object name: 'HEAD'\n");
        std.process.exit(128);
    };

    // Resolve target
    const target_oid = repo.resolveRef(allocator, target_name.?) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: '{s}' - not something we can merge\n", .{target_name.?}) catch
            "fatal: not something we can merge\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    };

    // Same commit?
    if (head_oid.eql(&target_oid)) {
        try stdout_file.writeAll("Already up to date.\n");
        return;
    }

    // Check for fast-forward: is HEAD an ancestor of target?
    if (try isAncestor(allocator, repo, &head_oid, &target_oid)) {
        return fastForwardMerge(repo, allocator, head_oid, target_oid, target_name.?);
    }

    // Check if target is an ancestor of HEAD (already merged)
    if (try isAncestor(allocator, repo, &target_oid, &head_oid)) {
        try stdout_file.writeAll("Already up to date.\n");
        return;
    }

    // Three-way merge
    return threeWayMerge(repo, allocator, head_oid, target_oid, target_name.?, no_commit, squash);
}

/// Fast-forward merge: just update HEAD to target.
fn fastForwardMerge(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    head_oid: types.ObjectId,
    target_oid: types.ObjectId,
    target_name: []const u8,
) !void {
    // Read target commit to get tree
    var target_commit = try repo.readObject(allocator, &target_oid);
    defer target_commit.deinit();

    if (target_commit.obj_type != .commit) {
        try stderr_file.writeAll("error: target is not a commit\n");
        std.process.exit(1);
    }

    const target_tree_oid = try getCommitTreeOid(target_commit.data);
    const work_dir = getWorkDir(repo.git_dir);

    // Flatten target tree
    var target_flat = try checkout_mod.flattenTree(allocator, repo, &target_tree_oid);
    defer target_flat.deinit();

    // Get current tree for diffing
    var head_commit_obj = try repo.readObject(allocator, &head_oid);
    defer head_commit_obj.deinit();
    const head_tree_oid = try getCommitTreeOid(head_commit_obj.data);

    var current_flat = try checkout_mod.flattenTree(allocator, repo, &head_tree_oid);
    defer current_flat.deinit();

    // Delete files not in target
    for (current_flat.entries.items) |*entry| {
        if (target_flat.findByPath(entry.path) == null) {
            deleteFromWorkTree(work_dir, entry.path);
        }
    }

    // Write all target files
    for (target_flat.entries.items) |*entry| {
        writeBlobToWorkTree(allocator, repo, work_dir, entry.path, &entry.oid, entry.mode) catch {};
    }

    // Build and write index
    var new_idx = try buildIndexFromTree(allocator, &target_flat);
    defer new_idx.deinit();

    var idx_path_buf: [4096]u8 = undefined;
    var idx_stream = std.io.fixedBufferStream(&idx_path_buf);
    const idx_writer = idx_stream.writer();
    try idx_writer.writeAll(repo.git_dir);
    try idx_writer.writeAll("/index");
    const idx_path = idx_path_buf[0..idx_stream.pos];
    try new_idx.writeToFile(idx_path);

    // Update the current branch ref
    const head_ref = ref_mod.readHead(allocator, repo.git_dir) catch null;
    defer if (head_ref) |h| allocator.free(h);

    if (head_ref) |branch_ref| {
        try ref_mod.createRef(allocator, repo.git_dir, branch_ref, target_oid, null);
    } else {
        // Detached HEAD
        writeDetachedHead(repo.git_dir, target_oid) catch {};
    }

    // Reflog
    var reflog_msg_buf: [256]u8 = undefined;
    const reflog_msg = std.fmt.bufPrint(&reflog_msg_buf, "merge {s}: Fast-forward", .{target_name}) catch "merge: Fast-forward";
    reflog_mod.appendReflog(repo.git_dir, "HEAD", head_oid, target_oid, reflog_msg) catch {};

    const head_hex = head_oid.toHex();
    const target_hex = target_oid.toHex();
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Updating {s}..{s}\nFast-forward\n", .{ head_hex[0..7], target_hex[0..7] }) catch "Fast-forward\n";
    try stdout_file.writeAll(msg);
}

/// Three-way merge.
fn threeWayMerge(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    head_oid: types.ObjectId,
    target_oid: types.ObjectId,
    target_name: []const u8,
    no_commit: bool,
    squash: bool,
) !void {
    // Find merge base
    const base_oid = try findMergeBase(allocator, repo, &head_oid, &target_oid) orelse {
        try stderr_file.writeAll("fatal: refusing to merge unrelated histories\n");
        std.process.exit(128);
    };

    // Get tree OIDs
    var base_commit = try repo.readObject(allocator, &base_oid);
    defer base_commit.deinit();
    const base_tree_oid = try getCommitTreeOid(base_commit.data);

    var ours_commit = try repo.readObject(allocator, &head_oid);
    defer ours_commit.deinit();
    const ours_tree_oid = try getCommitTreeOid(ours_commit.data);

    var theirs_commit = try repo.readObject(allocator, &target_oid);
    defer theirs_commit.deinit();
    const theirs_tree_oid = try getCommitTreeOid(theirs_commit.data);

    // Flatten all three trees
    var base_flat = try checkout_mod.flattenTree(allocator, repo, &base_tree_oid);
    defer base_flat.deinit();
    var ours_flat = try checkout_mod.flattenTree(allocator, repo, &ours_tree_oid);
    defer ours_flat.deinit();
    var theirs_flat = try checkout_mod.flattenTree(allocator, repo, &theirs_tree_oid);
    defer theirs_flat.deinit();

    // Collect all unique paths
    var all_paths = std.StringHashMap(void).init(allocator);
    defer all_paths.deinit();

    for (base_flat.entries.items) |*e| try all_paths.put(e.path, {});
    for (ours_flat.entries.items) |*e| try all_paths.put(e.path, {});
    for (theirs_flat.entries.items) |*e| try all_paths.put(e.path, {});

    // Result entries and conflict tracking
    var result_entries = std.array_list.Managed(checkout_mod.FlatTreeEntry).init(allocator);
    defer result_entries.deinit();
    var result_strings = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (result_strings.items) |s| allocator.free(s);
        result_strings.deinit();
    }

    var conflicts = std.array_list.Managed([]const u8).init(allocator);
    defer conflicts.deinit();
    var conflict_strings = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (conflict_strings.items) |s| allocator.free(s);
        conflict_strings.deinit();
    }

    const work_dir = getWorkDir(repo.git_dir);

    var path_iter = all_paths.keyIterator();
    while (path_iter.next()) |path_ptr| {
        const path = path_ptr.*;

        const base_entry = base_flat.findByPath(path);
        const ours_entry = ours_flat.findByPath(path);
        const theirs_entry = theirs_flat.findByPath(path);

        const base_oid_val: ?types.ObjectId = if (base_entry) |e| e.oid else null;
        const ours_oid_val: ?types.ObjectId = if (ours_entry) |e| e.oid else null;
        const theirs_oid_val: ?types.ObjectId = if (theirs_entry) |e| e.oid else null;

        const base_eq_ours = oidsEqual(base_oid_val, ours_oid_val);
        const base_eq_theirs = oidsEqual(base_oid_val, theirs_oid_val);
        const ours_eq_theirs = oidsEqual(ours_oid_val, theirs_oid_val);

        if (base_eq_ours and base_eq_theirs) {
            // Same in all three - keep as-is
            if (ours_entry) |e| {
                try result_entries.append(e.*);
            }
        } else if (base_eq_ours and !base_eq_theirs) {
            // Changed only in theirs - take theirs
            if (theirs_entry) |e| {
                try result_entries.append(e.*);
                writeBlobToWorkTree(allocator, repo, work_dir, e.path, &e.oid, e.mode) catch {};
            } else {
                // Deleted in theirs
                deleteFromWorkTree(work_dir, path);
            }
        } else if (!base_eq_ours and base_eq_theirs) {
            // Changed only in ours - keep ours
            if (ours_entry) |e| {
                try result_entries.append(e.*);
            } else {
                // Deleted in ours - already not present
                deleteFromWorkTree(work_dir, path);
            }
        } else if (ours_eq_theirs) {
            // Changed in both the same way - keep either
            if (ours_entry) |e| {
                try result_entries.append(e.*);
            }
        } else {
            // CONFLICT: changed in both differently
            const path_copy = try allocator.alloc(u8, path.len);
            @memcpy(path_copy, path);
            try conflict_strings.append(path_copy);
            try conflicts.append(path_copy);

            // Write conflict markers to working tree with line-level 3-way merge
            const base_oid_ptr: ?*const types.ObjectId = if (base_entry) |e| &e.oid else null;
            const ours_oid_ptr: ?*const types.ObjectId = if (ours_entry) |e| &e.oid else null;
            const theirs_oid_ptr: ?*const types.ObjectId = if (theirs_entry) |e| &e.oid else null;
            writeConflictFile(allocator, repo, work_dir, path, base_oid_ptr, ours_oid_ptr, theirs_oid_ptr, target_name) catch {};

            // Add ours version to result (for index) if it exists
            if (ours_entry) |e| {
                try result_entries.append(e.*);
            }
        }
    }

    if (conflicts.items.len > 0) {
        // Conflicts exist - write merge state files
        try writeMergeHead(repo.git_dir, target_oid);

        var merge_msg_buf: [256]u8 = undefined;
        const merge_msg = std.fmt.bufPrint(&merge_msg_buf, "Merge branch '{s}'", .{target_name}) catch "Merge";
        writeMergeMsg(repo.git_dir, merge_msg) catch {};

        // Update index with the result entries
        var new_idx = index_mod.Index.init(allocator);
        defer new_idx.deinit();

        for (result_entries.items) |*entry| {
            const name_copy = try allocator.alloc(u8, entry.path.len);
            @memcpy(name_copy, entry.path);
            try new_idx.addEntry(.{
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

        var idx_path_buf: [4096]u8 = undefined;
        var idx_stream = std.io.fixedBufferStream(&idx_path_buf);
        const idx_w = idx_stream.writer();
        try idx_w.writeAll(repo.git_dir);
        try idx_w.writeAll("/index");
        const idx_path = idx_path_buf[0..idx_stream.pos];
        try new_idx.writeToFile(idx_path);

        // Print conflict info
        try stderr_file.writeAll("Auto-merging failed; fix conflicts and then commit the result.\n");
        // Sort and print conflicting files
        sortStrings(conflicts.items);
        for (conflicts.items) |conflict_path| {
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "CONFLICT (content): Merge conflict in {s}\n", .{conflict_path}) catch continue;
            try stderr_file.writeAll(line);
        }

        std.process.exit(1);
    }

    // No conflicts - build the merged tree from result_entries
    const merged_tree_oid = try createTreeFromFlat(allocator, repo.git_dir, result_entries.items);

    // Update working tree with merged result
    var merged_flat = try checkout_mod.flattenTree(allocator, repo, &merged_tree_oid);
    defer merged_flat.deinit();

    for (merged_flat.entries.items) |*entry| {
        writeBlobToWorkTree(allocator, repo, work_dir, entry.path, &entry.oid, entry.mode) catch {};
    }

    // Build and write index
    var new_idx = try buildIndexFromTree(allocator, &merged_flat);
    defer new_idx.deinit();

    var idx_path_buf: [4096]u8 = undefined;
    var idx_stream = std.io.fixedBufferStream(&idx_path_buf);
    const idx_w = idx_stream.writer();
    try idx_w.writeAll(repo.git_dir);
    try idx_w.writeAll("/index");
    const idx_path = idx_path_buf[0..idx_stream.pos];
    try new_idx.writeToFile(idx_path);

    if (squash) {
        // Squash merge: apply changes but don't create merge commit
        // Write MERGE_MSG for the user to commit manually
        var merge_msg_buf2: [256]u8 = undefined;
        const merge_msg2 = std.fmt.bufPrint(&merge_msg_buf2, "Squashed commit of the following:\n\nMerge branch '{s}'", .{target_name}) catch "Squashed commit";
        writeMergeMsg(repo.git_dir, merge_msg2) catch {};
        try stdout_file.writeAll("Squash commit -- not updating HEAD\n");
        return;
    }

    if (no_commit) {
        // Merge but don't auto-commit - write MERGE_HEAD and MERGE_MSG
        try writeMergeHead(repo.git_dir, target_oid);
        var merge_msg_buf3: [256]u8 = undefined;
        const merge_msg3 = std.fmt.bufPrint(&merge_msg_buf3, "Merge branch '{s}'", .{target_name}) catch "Merge";
        writeMergeMsg(repo.git_dir, merge_msg3) catch {};
        try stdout_file.writeAll("Automatic merge went well; stopped before committing as requested\n");
        return;
    }

    // Create merge commit with two parents
    var merge_msg_buf: [256]u8 = undefined;
    const merge_msg = std.fmt.bufPrint(&merge_msg_buf, "Merge branch '{s}'", .{target_name}) catch "Merge";

    const parents = [_]types.ObjectId{ head_oid, target_oid };
    const merge_commit_oid = try createCommitObject(allocator, repo.git_dir, merged_tree_oid, &parents, merge_msg);

    // Update current branch ref
    const head_ref = ref_mod.readHead(allocator, repo.git_dir) catch null;
    defer if (head_ref) |h| allocator.free(h);

    if (head_ref) |branch_ref| {
        try ref_mod.createRef(allocator, repo.git_dir, branch_ref, merge_commit_oid, null);
    } else {
        writeDetachedHead(repo.git_dir, merge_commit_oid) catch {};
    }

    // Reflog
    var reflog_msg_buf: [256]u8 = undefined;
    const reflog_msg = std.fmt.bufPrint(&reflog_msg_buf, "merge {s}: Merge made by the 'ort' strategy.", .{target_name}) catch "merge";
    reflog_mod.appendReflog(repo.git_dir, "HEAD", head_oid, merge_commit_oid, reflog_msg) catch {};

    try stdout_file.writeAll("Merge made by the 'ort' strategy.\n");
}

/// Abort an in-progress merge.
fn mergeAbort(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    if (!mergeInProgress(repo.git_dir)) {
        try stderr_file.writeAll("fatal: there is no merge to abort (MERGE_HEAD missing)\n");
        std.process.exit(128);
    }

    // Reset to HEAD
    const head_oid = repo.resolveRef(allocator, "HEAD") catch {
        try stderr_file.writeAll("fatal: failed to resolve HEAD\n");
        std.process.exit(128);
    };

    var head_commit = try repo.readObject(allocator, &head_oid);
    defer head_commit.deinit();

    if (head_commit.obj_type != .commit) {
        try stderr_file.writeAll("fatal: HEAD is not a commit\n");
        std.process.exit(128);
    }

    const tree_oid = try getCommitTreeOid(head_commit.data);
    const work_dir = getWorkDir(repo.git_dir);

    // Flatten HEAD tree
    var head_flat = try checkout_mod.flattenTree(allocator, repo, &tree_oid);
    defer head_flat.deinit();

    // Write all files from HEAD tree
    for (head_flat.entries.items) |*entry| {
        writeBlobToWorkTree(allocator, repo, work_dir, entry.path, &entry.oid, entry.mode) catch {};
    }

    // Rebuild index
    var new_idx = try buildIndexFromTree(allocator, &head_flat);
    defer new_idx.deinit();

    var idx_path_buf: [4096]u8 = undefined;
    var idx_stream = std.io.fixedBufferStream(&idx_path_buf);
    const idx_w = idx_stream.writer();
    try idx_w.writeAll(repo.git_dir);
    try idx_w.writeAll("/index");
    const idx_path = idx_path_buf[0..idx_stream.pos];
    try new_idx.writeToFile(idx_path);

    // Remove merge state
    removeMergeState(repo.git_dir);

    try stderr_file.writeAll("Merge aborted.\n");
}

fn oidsEqual(a: ?types.ObjectId, b: ?types.ObjectId) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, &a.?.bytes, &b.?.bytes);
}

fn writeDetachedHead(git_dir: []const u8, oid: types.ObjectId) !void {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    const suffix = "/HEAD";
    @memcpy(path_buf[git_dir.len..][0..suffix.len], suffix);
    const head_path = path_buf[0 .. git_dir.len + suffix.len];

    const hex = oid.toHex();
    var content_buf: [types.OID_HEX_LEN + 1]u8 = undefined;
    @memcpy(content_buf[0..types.OID_HEX_LEN], &hex);
    content_buf[types.OID_HEX_LEN] = '\n';

    const file = try std.fs.createFileAbsolute(head_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(&content_buf);
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
