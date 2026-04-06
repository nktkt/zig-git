const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_diff = @import("tree_diff.zig");
const tree_builder = @import("tree_builder.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

pub const DiffTreeOptions = struct {
    recursive: bool = false,
    name_only: bool = false,
    name_status: bool = false,
    use_stdin: bool = false,
};

pub fn runDiffTree(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = DiffTreeOptions{};
    var positionals = std.array_list.Managed([]const u8).init(allocator);
    defer positionals.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-r")) {
            opts.recursive = true;
        } else if (std.mem.eql(u8, arg, "--name-only")) {
            opts.name_only = true;
        } else if (std.mem.eql(u8, arg, "--name-status")) {
            opts.name_status = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            opts.use_stdin = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try positionals.append(arg);
        }
    }

    if (opts.use_stdin) {
        try processStdin(repo, allocator, &opts);
        return;
    }

    if (positionals.items.len == 1) {
        // Single commit: compare with its parent
        try diffCommitWithParent(repo, allocator, positionals.items[0], &opts);
    } else if (positionals.items.len >= 2) {
        // Two trees/commits
        try diffTwoTrees(repo, allocator, positionals.items[0], positionals.items[1], &opts);
    } else {
        try stderr_file.writeAll("usage: zig-git diff-tree [-r] [--name-only] [--name-status] [--stdin] <tree-ish> [<tree-ish>]\n");
        std.process.exit(1);
    }
}

fn resolveToTreeOid(repo: *repository.Repository, allocator: std.mem.Allocator, ref_str: []const u8) !types.ObjectId {
    const oid = try repo.resolveRef(allocator, ref_str);

    var obj = try repo.readObject(allocator, &oid);
    if (obj.obj_type == .commit) {
        const tree_oid = tree_diff.getCommitTreeOid(obj.data) catch {
            obj.deinit();
            return error.InvalidCommit;
        };
        obj.deinit();
        return tree_oid;
    } else if (obj.obj_type == .tree) {
        obj.deinit();
        return oid;
    } else {
        obj.deinit();
        return error.NotATree;
    }
}

fn diffCommitWithParent(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    commit_ref: []const u8,
    opts: *const DiffTreeOptions,
) !void {
    const oid = repo.resolveRef(allocator, commit_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: bad object {s}\n", .{commit_ref}) catch "fatal: bad object\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    var obj = repo.readObject(allocator, &oid) catch {
        try stderr_file.writeAll("fatal: bad object\n");
        std.process.exit(128);
    };
    defer obj.deinit();

    if (obj.obj_type != .commit) {
        try stderr_file.writeAll("fatal: not a commit\n");
        std.process.exit(128);
    }

    // Get the tree OID from this commit
    const tree_oid = tree_diff.getCommitTreeOid(obj.data) catch {
        try stderr_file.writeAll("fatal: cannot parse commit\n");
        std.process.exit(128);
    };

    // Get parent commit(s)
    var parents = tree_diff.getCommitParents(allocator, obj.data) catch {
        try stderr_file.writeAll("fatal: cannot parse commit parents\n");
        std.process.exit(128);
    };
    defer parents.deinit();

    // Print the commit OID first (like git does)
    const commit_hex = oid.toHex();
    try stdout_file.writeAll(&commit_hex);
    try stdout_file.writeAll("\n");

    if (parents.items.len == 0) {
        // Initial commit: diff against empty tree
        try diffAndPrint(repo, allocator, null, &tree_oid, opts);
    } else {
        // Diff against first parent
        const parent_oid = parents.items[0];
        var parent_obj = repo.readObject(allocator, &parent_oid) catch return;
        defer parent_obj.deinit();

        if (parent_obj.obj_type == .commit) {
            const parent_tree = tree_diff.getCommitTreeOid(parent_obj.data) catch return;
            try diffAndPrint(repo, allocator, &parent_tree, &tree_oid, opts);
        }
    }
}

fn diffTwoTrees(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    ref1: []const u8,
    ref2: []const u8,
    opts: *const DiffTreeOptions,
) !void {
    const tree1 = resolveToTreeOid(repo, allocator, ref1) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: bad object {s}\n", .{ref1}) catch "fatal: bad object\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    const tree2 = resolveToTreeOid(repo, allocator, ref2) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: bad object {s}\n", .{ref2}) catch "fatal: bad object\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    try diffAndPrint(repo, allocator, &tree1, &tree2, opts);
}

fn diffAndPrint(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    old_tree: ?*const types.ObjectId,
    new_tree: ?*const types.ObjectId,
    opts: *const DiffTreeOptions,
) !void {
    // Use existing tree_diff module
    var result = tree_diff.diffTrees(repo, allocator, old_tree, new_tree) catch return;
    defer result.deinit();

    for (result.changes.items) |*change| {
        if (opts.name_only) {
            try stdout_file.writeAll(change.path);
            try stdout_file.writeAll("\n");
        } else if (opts.name_status) {
            const status_char = changeKindToStatus(change.kind);
            var term: [1]u8 = .{status_char};
            try stdout_file.writeAll(&term);
            try stdout_file.writeAll("\t");
            try stdout_file.writeAll(change.path);
            try stdout_file.writeAll("\n");
        } else {
            // Full diff-tree output: ":old_mode new_mode old_sha new_sha status\tpath"
            try printRawDiffEntry(change);
        }
    }
}

fn printRawDiffEntry(change: *const tree_diff.TreeChange) !void {
    const zero_oid = types.ObjectId.ZERO;

    const old_mode = change.old_mode orelse "000000";
    const new_mode = change.new_mode orelse "000000";
    const old_oid = if (change.old_oid) |oid| oid else zero_oid;
    const new_oid = if (change.new_oid) |oid| oid else zero_oid;
    const status_char = changeKindToStatus(change.kind);

    const old_hex = old_oid.toHex();
    const new_hex = new_oid.toHex();

    // Pad modes to 6 characters
    var old_mode_buf: [6]u8 = undefined;
    const old_mode_padded = padMode(old_mode, &old_mode_buf);
    var new_mode_buf: [6]u8 = undefined;
    const new_mode_padded = padMode(new_mode, &new_mode_buf);

    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, ":{s} {s} {s} {s} {c}\t", .{
        old_mode_padded,
        new_mode_padded,
        &old_hex,
        &new_hex,
        status_char,
    }) catch return;

    try stdout_file.writeAll(line);
    try stdout_file.writeAll(change.path);
    try stdout_file.writeAll("\n");
}

fn changeKindToStatus(kind: tree_diff.ChangeKind) u8 {
    return switch (kind) {
        .added => 'A',
        .deleted => 'D',
        .modified => 'M',
    };
}

fn padMode(mode: []const u8, buf: *[6]u8) []const u8 {
    if (mode.len >= 6) return mode[0..6];
    const pad = 6 - mode.len;
    @memset(buf[0..pad], '0');
    @memcpy(buf[pad..][0..mode.len], mode);
    return buf[0..6];
}

fn processStdin(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    opts: *const DiffTreeOptions,
) !void {
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var read_buf: [4096]u8 = undefined;
    var line_buf: [4096]u8 = undefined;
    var line_pos: usize = 0;

    while (true) {
        const n = stdin_file.readAll(&read_buf) catch break;
        if (n == 0) break;

        var j: usize = 0;
        while (j < n) : (j += 1) {
            if (read_buf[j] == '\n') {
                if (line_pos > 0) {
                    const line = line_buf[0..line_pos];
                    processStdinLine(repo, allocator, line, opts) catch {};
                }
                line_pos = 0;
            } else {
                if (line_pos < line_buf.len) {
                    line_buf[line_pos] = read_buf[j];
                    line_pos += 1;
                }
            }
        }

        if (n < read_buf.len) break;
    }

    if (line_pos > 0) {
        const line = line_buf[0..line_pos];
        processStdinLine(repo, allocator, line, opts) catch {};
    }
}

fn processStdinLine(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    line: []const u8,
    opts: *const DiffTreeOptions,
) !void {
    // Each line is a commit OID
    const trimmed = std.mem.trimRight(u8, line, " \r");
    if (trimmed.len < types.OID_HEX_LEN) return;

    // Process as single commit (diff with parent)
    try diffCommitWithParent(repo, allocator, trimmed, opts);
}
