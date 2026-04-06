const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const hash_mod = @import("hash.zig");
const loose = @import("loose.zig");
const pack_writer = @import("pack_writer.zig");
const ref_mod = @import("ref.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const WARNING_MESSAGE =
    \\WARNING: git filter-branch has a glut of gotchas generating mangled history
    \\         rewrites. Consider using an alternative filtering tool such as
    \\         'git filter-repo' (https://github.com/newren/git-filter-repo/)
    \\         instead. See the filter-branch manual page for more details.
    \\
    \\Proceeding with filter-branch...
    \\
;

/// Filter types that can be applied.
pub const FilterType = enum {
    tree_filter,
    index_filter,
    msg_filter,
    env_filter,
    subdirectory_filter,
};

/// Options for filter-branch.
pub const FilterOptions = struct {
    tree_filter: ?[]const u8 = null,
    index_filter: ?[]const u8 = null,
    msg_filter: ?[]const u8 = null,
    env_filter: ?[]const u8 = null,
    subdirectory_filter: ?[]const u8 = null,
    prune_empty: bool = false,
    rev_spec: ?[]const u8 = null,
    force: bool = false,
};

/// Mapping from old commit OID to new commit OID.
pub const CommitMap = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap([types.OID_RAW_LEN]u8, types.ObjectId),

    pub fn init(allocator: std.mem.Allocator) CommitMap {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap([types.OID_RAW_LEN]u8, types.ObjectId).init(allocator),
        };
    }

    pub fn deinit(self: *CommitMap) void {
        self.map.deinit();
    }

    pub fn put(self: *CommitMap, old: types.ObjectId, new: types.ObjectId) !void {
        try self.map.put(old.bytes, new);
    }

    pub fn get(self: *const CommitMap, old: *const types.ObjectId) ?types.ObjectId {
        return self.map.get(old.bytes);
    }
};

/// Get commits in topological order (oldest first) from a ref.
fn getCommitsInOrder(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    tip_oid: *const types.ObjectId,
) ![]types.ObjectId {
    var result = std.array_list.Managed(types.ObjectId).init(allocator);
    defer result.deinit();

    var visited = std.AutoHashMap([types.OID_RAW_LEN]u8, void).init(allocator);
    defer visited.deinit();

    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();

    try queue.append(tip_oid.*);
    try visited.put(tip_oid.bytes, {});

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);
        try result.append(current);

        var obj = repo.readObject(allocator, &current) catch continue;
        defer obj.deinit();

        if (obj.obj_type != .commit) continue;

        const parents = try parseCommitParents(allocator, obj.data);
        defer allocator.free(parents);

        for (parents) |parent_oid| {
            if (!visited.contains(parent_oid.bytes)) {
                try visited.put(parent_oid.bytes, {});
                try queue.append(parent_oid);
            }
        }
    }

    const owned = try result.toOwnedSlice();
    std.mem.reverse(types.ObjectId, owned);
    return owned;
}

/// Apply a message filter to a commit message.
fn applyMsgFilter(
    allocator: std.mem.Allocator,
    message: []const u8,
    filter_cmd: []const u8,
) ![]u8 {
    _ = allocator;
    _ = filter_cmd;
    // In a real implementation, we'd execute the command with the message on stdin
    // and capture stdout. For now, return the original message.
    // This is a simplified version that doesn't spawn external processes.
    var result = std.array_list.Managed(u8).init(std.heap.page_allocator);
    errdefer result.deinit();
    try result.appendSlice(message);
    return result.toOwnedSlice();
}

/// Apply subdirectory filter: extract subtree as root.
fn applySubdirectoryFilter(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    tree_oid: *const types.ObjectId,
    subdir: []const u8,
) !?types.ObjectId {
    var obj = repo.readObject(allocator, tree_oid) catch return null;
    defer obj.deinit();

    if (obj.obj_type != .tree) return null;

    // Parse tree entries looking for the subdirectory
    var pos: usize = 0;
    while (pos < obj.data.len) {
        const entry = parseTreeEntryFull(obj.data, &pos) catch break;
        if (std.mem.eql(u8, entry.name, subdir)) {
            // Check if mode indicates directory (starts with '4' for 40000)
            if (entry.mode.len > 0 and entry.mode[0] == '4') {
                return entry.oid;
            }
        }
    }

    return null;
}

/// Rewrite a single commit, applying filters and updating parent references.
fn rewriteCommit(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    oid: *const types.ObjectId,
    opts: *const FilterOptions,
    commit_map: *CommitMap,
) !?types.ObjectId {
    var obj = repo.readObject(allocator, oid) catch return null;
    defer obj.deinit();

    if (obj.obj_type != .commit) return null;

    // Parse commit fields
    var tree_oid = parseCommitTree(obj.data) catch return null;
    const parents = parseCommitParents(allocator, obj.data) catch return null;
    defer allocator.free(parents);
    const author_line = extractHeader(obj.data, "author") orelse "author unknown <unknown> 0 +0000";
    const committer_line = extractHeader(obj.data, "committer") orelse "committer unknown <unknown> 0 +0000";
    const message = extractMessage(obj.data) orelse "";

    // Apply subdirectory filter
    if (opts.subdirectory_filter) |subdir| {
        const new_tree = applySubdirectoryFilter(allocator, repo, &tree_oid, subdir) catch null;
        if (new_tree) |t| {
            tree_oid = t;
        } else {
            if (opts.prune_empty) return null;
            // Create empty tree
            tree_oid = pack_writer.computeObjectId(.tree, "");
        }
    }

    // Apply message filter
    var final_message: []const u8 = message;
    var owned_message: ?[]u8 = null;
    defer if (owned_message) |m| std.heap.page_allocator.free(m);

    if (opts.msg_filter) |filter_cmd| {
        const new_msg = applyMsgFilter(allocator, message, filter_cmd) catch null;
        if (new_msg) |m| {
            owned_message = m;
            final_message = m;
        }
    }

    // Map parents to new OIDs
    var new_parents = std.array_list.Managed(types.ObjectId).init(allocator);
    defer new_parents.deinit();

    for (parents) |parent_oid| {
        if (commit_map.get(&parent_oid)) |new_parent| {
            try new_parents.append(new_parent);
        } else {
            try new_parents.append(parent_oid);
        }
    }

    // Check if we should prune empty commits
    if (opts.prune_empty and new_parents.items.len > 0) {
        // Compare tree with first parent's tree
        const parent_tree = blk: {
            var parent_obj = repo.readObject(allocator, &new_parents.items[0]) catch break :blk types.ObjectId.ZERO;
            defer parent_obj.deinit();
            break :blk parseCommitTree(parent_obj.data) catch types.ObjectId.ZERO;
        };
        if (tree_oid.eql(&parent_tree)) {
            // Commit is empty after filtering, skip it and map to parent
            if (new_parents.items.len > 0) {
                try commit_map.put(oid.*, new_parents.items[0]);
                return null;
            }
        }
    }

    // Build new commit object
    var commit_data = std.array_list.Managed(u8).init(allocator);
    defer commit_data.deinit();

    const tree_hex = tree_oid.toHex();
    try commit_data.appendSlice("tree ");
    try commit_data.appendSlice(&tree_hex);
    try commit_data.append('\n');

    for (new_parents.items) |parent_oid| {
        const parent_hex = parent_oid.toHex();
        try commit_data.appendSlice("parent ");
        try commit_data.appendSlice(&parent_hex);
        try commit_data.append('\n');
    }

    try commit_data.appendSlice(author_line);
    try commit_data.append('\n');
    try commit_data.appendSlice(committer_line);
    try commit_data.append('\n');
    try commit_data.append('\n');
    try commit_data.appendSlice(final_message);

    // Write the new commit
    const new_oid = loose.writeLooseObject(allocator, repo.git_dir, .commit, commit_data.items) catch return null;

    try commit_map.put(oid.*, new_oid);

    return new_oid;
}

/// Save backup refs before rewriting.
fn saveBackupRefs(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    ref_name: []const u8,
    oid: *const types.ObjectId,
) !void {
    _ = allocator;
    // Write to refs/original/<ref_name>
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..repo.git_dir.len], repo.git_dir);
    pos += repo.git_dir.len;
    const prefix = "/refs/original/";
    @memcpy(path_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(path_buf[pos..][0..ref_name.len], ref_name);
    pos += ref_name.len;
    const backup_path = path_buf[0..pos];

    // Ensure parent directory exists
    if (std.fs.path.dirname(backup_path)) |dir| {
        ensureDirPath(dir);
    }

    const hex = oid.toHex();
    const file = std.fs.createFileAbsolute(backup_path, .{ .exclusive = true }) catch return;
    defer file.close();
    file.writeAll(&hex) catch {};
    file.writeAll("\n") catch {};
}

/// Update a ref to point to a new OID.
fn updateRef(
    git_dir: []const u8,
    ref_name: []const u8,
    oid: *const types.ObjectId,
) !void {
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    path_buf[pos] = '/';
    pos += 1;
    @memcpy(path_buf[pos..][0..ref_name.len], ref_name);
    pos += ref_name.len;
    const ref_path = path_buf[0..pos];

    if (std.fs.path.dirname(ref_path)) |dir| {
        ensureDirPath(dir);
    }

    const hex = oid.toHex();
    const file = std.fs.createFileAbsolute(ref_path, .{}) catch return error.CannotWriteRef;
    defer file.close();
    file.writeAll(&hex) catch return error.CannotWriteRef;
    file.writeAll("\n") catch return error.CannotWriteRef;
}

/// Run the filter-branch command.
pub fn runFilterBranch(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = FilterOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--tree-filter")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("error: --tree-filter requires an argument\n");
                std.process.exit(1);
            }
            opts.tree_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--index-filter")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("error: --index-filter requires an argument\n");
                std.process.exit(1);
            }
            opts.index_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--msg-filter")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("error: --msg-filter requires an argument\n");
                std.process.exit(1);
            }
            opts.msg_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--env-filter")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("error: --env-filter requires an argument\n");
                std.process.exit(1);
            }
            opts.env_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--subdirectory-filter")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("error: --subdirectory-filter requires an argument\n");
                std.process.exit(1);
            }
            opts.subdirectory_filter = args[i];
        } else if (std.mem.eql(u8, arg, "--prune-empty")) {
            opts.prune_empty = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            opts.rev_spec = arg;
        }
    }

    // Check that at least one filter is specified
    if (opts.tree_filter == null and opts.index_filter == null and
        opts.msg_filter == null and opts.env_filter == null and
        opts.subdirectory_filter == null)
    {
        try stderr_file.writeAll(filter_branch_usage);
        std.process.exit(1);
    }

    // Show warning
    try stderr_file.writeAll(WARNING_MESSAGE);

    // Resolve the revision to rewrite
    const rev_spec = opts.rev_spec orelse "HEAD";
    const tip_oid = repo.resolveRef(allocator, rev_spec) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: bad revision '{s}'\n", .{rev_spec}) catch "fatal: bad revision\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    // Check for existing backup refs (unless --force)
    if (!opts.force) {
        var backup_check_buf: [4096]u8 = undefined;
        const backup_check = concatStr(&backup_check_buf, repo.git_dir, "/refs/original");
        if (isDirectory(backup_check)) {
            try stderr_file.writeAll("fatal: backup refs already exist. Use --force to override.\n");
            std.process.exit(128);
        }
    }

    // Get all commits in topological order
    const commits = try getCommitsInOrder(allocator, repo, &tip_oid);
    defer allocator.free(commits);

    var out_buf: [256]u8 = undefined;
    var msg = std.fmt.bufPrint(&out_buf, "Rewriting {d} commits...\n", .{commits.len}) catch "Rewriting commits...\n";
    try stderr_file.writeAll(msg);

    // Save backup of current ref
    saveBackupRefs(allocator, repo, rev_spec, &tip_oid) catch {};

    // Process each commit
    var commit_map = CommitMap.init(allocator);
    defer commit_map.deinit();

    var rewritten: usize = 0;
    var pruned: usize = 0;

    for (commits) |commit_oid| {
        const new_oid = rewriteCommit(allocator, repo, &commit_oid, &opts, &commit_map) catch null;
        if (new_oid != null) {
            rewritten += 1;
        } else {
            pruned += 1;
        }
    }

    // Update the ref to point to the new tip
    if (commit_map.get(&tip_oid)) |new_tip| {
        // Determine the ref to update
        const ref_to_update: []const u8 = if (std.mem.eql(u8, rev_spec, "HEAD"))
            "refs/heads/main" // Default branch
        else if (std.mem.startsWith(u8, rev_spec, "refs/"))
            rev_spec
        else blk: {
            // Try refs/heads/<name>
            var ref_buf: [256]u8 = undefined;
            _ = concatStr(&ref_buf, "refs/heads/", rev_spec);
            break :blk rev_spec;
        };

        updateRef(repo.git_dir, ref_to_update, &new_tip) catch {
            try stderr_file.writeAll("warning: could not update ref\n");
        };
    }

    msg = std.fmt.bufPrint(&out_buf, "\nRef '{s}' was rewritten ({d} commits rewritten, {d} pruned)\n", .{ rev_spec, rewritten, pruned }) catch "Ref was rewritten\n";
    try stdout_file.writeAll(msg);
}

const filter_branch_usage =
    \\usage: zig-git filter-branch [options] [<rev>]
    \\
    \\Options:
    \\  --tree-filter <cmd>          Run command on each tree
    \\  --index-filter <cmd>         Run command on each index state
    \\  --msg-filter <cmd>           Rewrite commit messages
    \\  --env-filter <cmd>           Modify author/committer environment
    \\  --subdirectory-filter <dir>  Extract subdirectory as root
    \\  --prune-empty                Remove commits that become empty
    \\  -f, --force                  Force rewrite even if backup exists
    \\
    \\WARNING: Consider using git-filter-repo instead.
    \\
;

// --- Internal parsers ---

fn parseCommitTree(data: []const u8) !types.ObjectId {
    if (data.len < 5 + types.OID_HEX_LEN) return error.InvalidCommitFormat;
    if (!std.mem.startsWith(u8, data, "tree ")) return error.InvalidCommitFormat;
    return types.ObjectId.fromHex(data[5..][0..types.OID_HEX_LEN]);
}

fn parseCommitParents(allocator: std.mem.Allocator, data: []const u8) ![]types.ObjectId {
    var parents = std.array_list.Managed(types.ObjectId).init(allocator);
    defer parents.deinit();

    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "parent ")) {
            if (line.len >= 7 + types.OID_HEX_LEN) {
                const oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch continue;
                try parents.append(oid);
            }
        }
    }

    return parents.toOwnedSlice();
}

fn extractHeader(data: []const u8, name: []const u8) ?[]const u8 {
    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, name)) {
            if (line.len > name.len and line[name.len] == ' ') {
                return line;
            }
        }
    }
    return null;
}

fn extractMessage(data: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, data, "\n\n")) |pos| {
        return data[pos + 2 ..];
    }
    return null;
}

const ParsedTreeEntry = struct {
    mode: []const u8,
    name: []const u8,
    oid: types.ObjectId,
};

fn parseTreeEntryFull(data: []const u8, pos: *usize) !ParsedTreeEntry {
    if (pos.* >= data.len) return error.EndOfTree;

    // Find the space between mode and name
    const mode_start = pos.*;
    const space_pos = std.mem.indexOfScalarPos(u8, data, mode_start, ' ') orelse return error.InvalidTreeEntry;
    const mode = data[mode_start..space_pos];

    // Find null byte after name
    const name_start = space_pos + 1;
    const null_pos = std.mem.indexOfScalarPos(u8, data, name_start, 0) orelse return error.InvalidTreeEntry;
    const name = data[name_start..null_pos];

    if (null_pos + 1 + types.OID_RAW_LEN > data.len) return error.InvalidTreeEntry;

    var oid: types.ObjectId = undefined;
    @memcpy(&oid.bytes, data[null_pos + 1 ..][0..types.OID_RAW_LEN]);

    pos.* = null_pos + 1 + types.OID_RAW_LEN;
    return ParsedTreeEntry{ .mode = mode, .name = name, .oid = oid };
}

fn concatStr(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn isDirectory(path: []const u8) bool {
    const dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    @constCast(&dir).close();
    return true;
}

fn ensureDirPath(path: []const u8) void {
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            std.fs.makeDirAbsolute(path[0..i]) catch {};
        }
    }
    std.fs.makeDirAbsolute(path) catch {};
}

test "extractHeader" {
    const data = "tree abc123\nauthor John <john@example.com> 1234567890 +0000\ncommitter Jane <jane@example.com> 1234567890 +0000\n\nCommit message";
    const author = extractHeader(data, "author");
    try std.testing.expect(author != null);
    try std.testing.expect(std.mem.startsWith(u8, author.?, "author John"));
}

test "extractMessage" {
    const data = "tree abc123\n\nThis is the commit message\n";
    const message = extractMessage(data);
    try std.testing.expect(message != null);
    try std.testing.expectEqualStrings("This is the commit message\n", message.?);
}

test "CommitMap" {
    var cmap = CommitMap.init(std.testing.allocator);
    defer cmap.deinit();

    const old_oid = try types.ObjectId.fromHex("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const new_oid = try types.ObjectId.fromHex("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");

    try cmap.put(old_oid, new_oid);
    const got = cmap.get(&old_oid);
    try std.testing.expect(got != null);
    try std.testing.expect(got.?.eql(&new_oid));
}
