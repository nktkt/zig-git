const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_diff = @import("tree_diff.zig");
const merge_mod = @import("merge.zig");
const cherry_pick_mod = @import("cherry_pick.zig");
const loose = @import("loose.zig");
const index_mod = @import("index.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");
const checkout_mod = @import("checkout.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// State directory for an in-progress rebase.
const REBASE_DIR = "/rebase-apply";
const REBASE_TODO = "/rebase-apply/todo";
const REBASE_DONE = "/rebase-apply/done";
const REBASE_HEAD_NAME = "/rebase-apply/head-name";
const REBASE_ONTO = "/rebase-apply/onto";
const REBASE_ORIG_HEAD = "/rebase-apply/orig-head";
const REBASE_MSG = "/rebase-apply/message";
const REBASE_CURRENT = "/rebase-apply/current";
const REBASE_TOTAL = "/rebase-apply/total";
const REBASE_NEXT = "/rebase-apply/next";

/// Options for the rebase command.
pub const RebaseOptions = struct {
    upstream: ?[]const u8 = null,
    abort: bool = false,
    continue_rebase: bool = false,
    skip: bool = false,
    onto: ?[]const u8 = null,
    interactive: bool = false,
};

/// A single commit to be rebased.
const RebaseTodo = struct {
    oid: types.ObjectId,
    message: []const u8,
};

/// Entry point for the rebase command.
pub fn runRebase(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = RebaseOptions{};

    // Parse arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--abort")) {
            opts.abort = true;
        } else if (std.mem.eql(u8, arg, "--continue")) {
            opts.continue_rebase = true;
        } else if (std.mem.eql(u8, arg, "--skip")) {
            opts.skip = true;
        } else if (std.mem.eql(u8, arg, "--onto")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("fatal: --onto requires a branch name\n");
                std.process.exit(1);
            }
            opts.onto = args[i];
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive")) {
            opts.interactive = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (opts.upstream == null) {
                opts.upstream = arg;
            }
        }
    }

    if (opts.abort) {
        return abortRebase(repo, allocator);
    }

    if (opts.continue_rebase) {
        return continueRebase(repo, allocator);
    }

    if (opts.skip) {
        return skipRebase(repo, allocator);
    }

    if (opts.upstream == null) {
        try stderr_file.writeAll("fatal: no upstream specified\n");
        try stderr_file.writeAll("usage: zig-git rebase [--abort | --continue | --skip] [--onto <newbase>] <upstream>\n");
        std.process.exit(1);
    }

    // Check if rebase is already in progress
    if (isRebaseInProgress(repo.git_dir)) {
        try stderr_file.writeAll("fatal: a rebase is already in progress\n");
        try stderr_file.writeAll("hint: use 'zig-git rebase --continue' to continue\n");
        try stderr_file.writeAll("hint: use 'zig-git rebase --abort' to abort\n");
        std.process.exit(1);
    }

    // Resolve upstream
    const upstream_oid = repo.resolveRef(allocator, opts.upstream.?) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: invalid upstream '{s}'\n", .{opts.upstream.?}) catch
            "fatal: invalid upstream\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    // Resolve onto (defaults to upstream)
    const onto_ref = opts.onto orelse opts.upstream.?;
    const onto_oid = repo.resolveRef(allocator, onto_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: invalid onto target '{s}'\n", .{onto_ref}) catch
            "fatal: invalid onto target\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    // Resolve HEAD
    const head_oid = repo.resolveRef(allocator, "HEAD") catch {
        try stderr_file.writeAll("fatal: HEAD is not valid\n");
        std.process.exit(128);
    };

    // Find merge base
    const merge_base = merge_mod.findMergeBase(allocator, repo, &upstream_oid, &head_oid) catch {
        try stderr_file.writeAll("fatal: cannot find merge base\n");
        std.process.exit(128);
    };

    if (merge_base == null) {
        try stderr_file.writeAll("fatal: no common ancestor found\n");
        std.process.exit(128);
    }

    const base = merge_base.?;

    // Check if HEAD is already on top of upstream (fast-forward case)
    if (base.eql(&head_oid)) {
        try stdout_file.writeAll("Current branch is up to date.\n");
        return;
    }

    // Check if upstream is already on top of HEAD
    if (base.eql(&upstream_oid)) {
        try stdout_file.writeAll("Current branch is already up to date with upstream.\n");
        return;
    }

    // Collect commits from merge base to HEAD (exclusive base, inclusive HEAD)
    var commits = try collectCommits(allocator, repo, &base, &head_oid);
    defer {
        for (commits.items) |*c| {
            allocator.free(c.message);
        }
        commits.deinit();
    }

    if (commits.items.len == 0) {
        try stdout_file.writeAll("Nothing to rebase.\n");
        return;
    }

    // Save current HEAD
    const head_ref = ref_mod.readHead(allocator, repo.git_dir) catch null;
    defer if (head_ref) |h| allocator.free(h);

    // Write ORIG_HEAD for abort
    try writeOrigHead(repo.git_dir, head_oid);

    // Create rebase state directory
    try createRebaseState(repo.git_dir, commits.items, onto_oid, head_oid, head_ref);

    // Move HEAD to onto
    try moveHeadTo(allocator, repo, onto_oid);

    // Apply commits one by one
    try applyRebaseCommits(allocator, repo, commits.items);
}

/// Collect commits between base (exclusive) and head (inclusive), in order from oldest to newest.
fn collectCommits(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    base_oid: *const types.ObjectId,
    head_oid: *const types.ObjectId,
) !std.array_list.Managed(RebaseTodo) {
    var all_commits = std.array_list.Managed(RebaseTodo).init(allocator);
    errdefer {
        for (all_commits.items) |*c| {
            allocator.free(c.message);
        }
        all_commits.deinit();
    }

    // Walk from HEAD back to base
    var current_oid = head_oid.*;
    var iterations: usize = 0;
    const max_iterations: usize = 10000;

    while (iterations < max_iterations) {
        iterations += 1;

        if (current_oid.eql(base_oid)) break;

        var obj = repo.readObject(allocator, &current_oid) catch break;
        defer obj.deinit();

        if (obj.obj_type != .commit) break;

        // Get the commit message
        const message = extractCommitMessage(obj.data);
        const msg_copy = try allocator.alloc(u8, message.len);
        @memcpy(msg_copy, message);

        try all_commits.append(.{
            .oid = current_oid,
            .message = msg_copy,
        });

        // Get the first parent
        var parents = tree_diff.getCommitParents(allocator, obj.data) catch break;
        defer parents.deinit();

        if (parents.items.len == 0) break;
        current_oid = parents.items[0];
    }

    // Reverse to get oldest first
    std.mem.reverse(RebaseTodo, all_commits.items);

    return all_commits;
}

/// Apply rebase commits.
fn applyRebaseCommits(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    commits: []const RebaseTodo,
) !void {
    var applied: usize = 0;
    for (commits, 0..) |*todo, idx| {
        // Update progress
        writeRebaseProgress(repo.git_dir, idx + 1, commits.len) catch {};

        // Print progress
        {
            var buf: [512]u8 = undefined;
            const hex = todo.oid.toHex();
            const msg = std.fmt.bufPrint(&buf, "Applying: {s} ({d}/{d})\n", .{
                firstLine(todo.message),
                idx + 1,
                commits.len,
            }) catch "Applying commit...\n";
            try stdout_file.writeAll(msg);
            _ = hex;
        }

        // Cherry-pick the commit
        const result = applyOneCommit(allocator, repo, todo);

        if (result) |_| {
            applied += 1;
            // Move DONE file
            appendDone(repo.git_dir, &todo.oid, todo.message) catch {};
        } else |err| {
            switch (err) {
                error.CherryPickConflict => {
                    // Conflict: stop rebase
                    writeCurrentCommit(repo.git_dir, &todo.oid) catch {};
                    try stderr_file.writeAll("CONFLICT: merge conflict in files\n");
                    try stderr_file.writeAll("hint: Resolve conflicts and use 'zig-git rebase --continue'\n");
                    try stderr_file.writeAll("hint: To abort, use 'zig-git rebase --abort'\n");
                    std.process.exit(1);
                },
                else => {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "error: failed to apply commit: {s}\n", .{@errorName(err)}) catch
                        "error: failed to apply commit\n";
                    try stderr_file.writeAll(msg);
                    std.process.exit(1);
                },
            }
        }
    }

    // Rebase complete: clean up
    cleanupRebaseState(repo.git_dir);

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Successfully rebased and updated refs. ({d} commits applied)\n", .{applied}) catch
        "Rebase complete.\n";
    try stdout_file.writeAll(msg);
}

/// Apply a single commit during rebase (simplified cherry-pick).
fn applyOneCommit(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    todo: *const RebaseTodo,
) !types.ObjectId {
    // Read the commit being applied
    var cherry_obj = try repo.readObject(allocator, &todo.oid);
    defer cherry_obj.deinit();

    if (cherry_obj.obj_type != .commit) return error.NotACommit;

    const cherry_tree_oid = try tree_diff.getCommitTreeOid(cherry_obj.data);

    var cherry_parents = try tree_diff.getCommitParents(allocator, cherry_obj.data);
    defer cherry_parents.deinit();

    if (cherry_parents.items.len == 0) return error.NoParent;
    const parent_oid = cherry_parents.items[0];

    // Resolve parent commit to its tree OID for diffing
    var parent_obj = try repo.readObject(allocator, &parent_oid);
    defer parent_obj.deinit();
    const parent_tree_oid = try tree_diff.getCommitTreeOid(parent_obj.data);

    // Diff: parent tree -> cherry tree
    var changes = try tree_diff.diffTrees(repo, allocator, &parent_tree_oid, &cherry_tree_oid);
    defer changes.deinit();

    // Get current HEAD
    const head_oid = try repo.resolveRef(allocator, "HEAD");
    var head_obj = try repo.readObject(allocator, &head_oid);
    defer head_obj.deinit();
    const head_tree_oid = try tree_diff.getCommitTreeOid(head_obj.data);

    const work_dir = getWorkDir(repo.git_dir);

    // Load index
    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPathBuf(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    var has_conflicts = false;

    // Apply changes
    for (changes.changes.items) |*change| {
        switch (change.kind) {
            .added => {
                if (change.new_oid) |new_oid| {
                    const noid = new_oid;
                    writeBlobToWorkTree(allocator, repo, work_dir, change.path, &noid) catch {
                        has_conflicts = true;
                        continue;
                    };
                    const name_copy = try allocator.alloc(u8, change.path.len);
                    @memcpy(name_copy, change.path);
                    const mode = parseModeStr(change.new_mode orelse "100644");
                    try idx.addEntry(.{
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
                        .oid = noid,
                        .flags = 0,
                        .name = name_copy,
                        .owned = true,
                    });
                }
            },
            .deleted => {
                deleteFromWorkTree(work_dir, change.path);
                _ = idx.removeEntry(change.path);
            },
            .modified => {
                if (change.new_oid) |new_oid| {
                    const noid = new_oid;
                    // Check for conflict
                    const head_file = getFileBlobOidFromTree(allocator, repo, &head_tree_oid, change.path);
                    if (head_file) |hf| {
                        if (change.old_oid) |old_oid| {
                            if (!hf.eql(&old_oid)) {
                                // Conflict
                                has_conflicts = true;
                                writeConflictMarkers(allocator, repo, work_dir, change.path, &hf, &noid) catch {};
                                continue;
                            }
                        }
                    }

                    writeBlobToWorkTree(allocator, repo, work_dir, change.path, &noid) catch {
                        has_conflicts = true;
                        continue;
                    };
                    const name_copy = try allocator.alloc(u8, change.path.len);
                    @memcpy(name_copy, change.path);
                    const mode = parseModeStr(change.new_mode orelse "100644");
                    try idx.addEntry(.{
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
                        .oid = noid,
                        .flags = 0,
                        .name = name_copy,
                        .owned = true,
                    });
                }
            },
        }
    }

    // Write index
    try idx.writeToFile(index_path);

    if (has_conflicts) return error.CherryPickConflict;

    // Create commit
    const tree_builder = @import("tree_builder.zig");
    const new_tree_oid = try tree_builder.buildTree(allocator, repo.git_dir, &idx);

    // Extract author from original commit
    const author_line = extractAuthorLine(cherry_obj.data) orelse "zig-git <zig-git@localhost> 0 +0000";

    var commit_data = std.array_list.Managed(u8).init(allocator);
    defer commit_data.deinit();

    const tree_hex = new_tree_oid.toHex();
    try commit_data.appendSlice("tree ");
    try commit_data.appendSlice(&tree_hex);
    try commit_data.append('\n');

    const parent_hex = head_oid.toHex();
    try commit_data.appendSlice("parent ");
    try commit_data.appendSlice(&parent_hex);
    try commit_data.append('\n');

    try commit_data.appendSlice("author ");
    try commit_data.appendSlice(author_line);
    try commit_data.append('\n');

    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);
    try commit_data.appendSlice("committer zig-git <zig-git@localhost> ");
    try commit_data.appendSlice(timestamp);
    try commit_data.appendSlice(" +0000\n");
    try commit_data.append('\n');
    try commit_data.appendSlice(todo.message);
    if (todo.message.len > 0 and todo.message[todo.message.len - 1] != '\n') {
        try commit_data.append('\n');
    }

    const commit_oid = try loose.writeLooseObject(allocator, repo.git_dir, .commit, commit_data.items);

    // Update HEAD
    try updateHead(allocator, repo, head_oid, commit_oid);

    return commit_oid;
}

/// Abort a rebase in progress.
fn abortRebase(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    if (!isRebaseInProgress(repo.git_dir)) {
        try stderr_file.writeAll("fatal: no rebase in progress\n");
        std.process.exit(128);
    }

    // Read original HEAD
    const orig_oid = readOrigHead(allocator, repo.git_dir) catch {
        try stderr_file.writeAll("fatal: cannot read original HEAD\n");
        std.process.exit(128);
    };

    // Read original branch name
    const head_name = readRebaseFile(allocator, repo.git_dir, REBASE_HEAD_NAME) catch null;
    defer if (head_name) |h| allocator.free(h);

    // Restore HEAD
    if (head_name) |name| {
        const trimmed = std.mem.trimRight(u8, name, "\n\r ");
        // Restore the symbolic ref
        ref_mod.updateSymRef(repo.git_dir, "HEAD", trimmed) catch {};
        ref_mod.createRef(allocator, repo.git_dir, trimmed, orig_oid, null) catch {};
    }

    // Reset working tree to original HEAD
    var orig_obj = repo.readObject(allocator, &orig_oid) catch {
        try stderr_file.writeAll("fatal: cannot read original commit\n");
        std.process.exit(128);
    };
    defer orig_obj.deinit();

    if (orig_obj.obj_type == .commit) {
        const tree_oid = tree_diff.getCommitTreeOid(orig_obj.data) catch {
            try stderr_file.writeAll("fatal: invalid commit\n");
            std.process.exit(128);
        };
        resetToTree(allocator, repo, &tree_oid) catch {};
    }

    // Clean up state
    cleanupRebaseState(repo.git_dir);

    try stdout_file.writeAll("rebase aborted\n");
}

/// Continue a rebase after conflict resolution.
fn continueRebase(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    if (!isRebaseInProgress(repo.git_dir)) {
        try stderr_file.writeAll("fatal: no rebase in progress\n");
        std.process.exit(128);
    }

    // Read current commit
    const current_data = readRebaseFile(allocator, repo.git_dir, REBASE_CURRENT) catch {
        try stderr_file.writeAll("fatal: cannot determine current commit\n");
        std.process.exit(128);
    };
    defer allocator.free(current_data);

    const current_hex = std.mem.trimRight(u8, current_data, "\n\r ");
    if (current_hex.len < types.OID_HEX_LEN) {
        try stderr_file.writeAll("fatal: invalid current commit\n");
        std.process.exit(128);
    }

    const current_oid = types.ObjectId.fromHex(current_hex[0..types.OID_HEX_LEN]) catch {
        try stderr_file.writeAll("fatal: invalid current commit OID\n");
        std.process.exit(128);
    };

    // Read the original commit
    var cherry_obj = repo.readObject(allocator, &current_oid) catch {
        try stderr_file.writeAll("fatal: cannot read commit\n");
        std.process.exit(128);
    };
    defer cherry_obj.deinit();

    const message = extractCommitMessage(cherry_obj.data);

    // Create a commit from the current index
    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPathBuf(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    const tree_builder = @import("tree_builder.zig");
    const new_tree_oid = try tree_builder.buildTree(allocator, repo.git_dir, &idx);

    const head_oid = try repo.resolveRef(allocator, "HEAD");
    const author_line = extractAuthorLine(cherry_obj.data) orelse "zig-git <zig-git@localhost> 0 +0000";

    var commit_data = std.array_list.Managed(u8).init(allocator);
    defer commit_data.deinit();

    const tree_hex = new_tree_oid.toHex();
    try commit_data.appendSlice("tree ");
    try commit_data.appendSlice(&tree_hex);
    try commit_data.append('\n');

    const parent_hex = head_oid.toHex();
    try commit_data.appendSlice("parent ");
    try commit_data.appendSlice(&parent_hex);
    try commit_data.append('\n');

    try commit_data.appendSlice("author ");
    try commit_data.appendSlice(author_line);
    try commit_data.append('\n');

    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);
    try commit_data.appendSlice("committer zig-git <zig-git@localhost> ");
    try commit_data.appendSlice(timestamp);
    try commit_data.appendSlice(" +0000\n");
    try commit_data.append('\n');
    try commit_data.appendSlice(message);
    if (message.len > 0 and message[message.len - 1] != '\n') {
        try commit_data.append('\n');
    }

    const commit_oid = try loose.writeLooseObject(allocator, repo.git_dir, .commit, commit_data.items);

    try updateHead(allocator, repo, head_oid, commit_oid);

    try stdout_file.writeAll("Applied and committed.\n");

    // Read remaining todo items
    const todo_data = readRebaseFile(allocator, repo.git_dir, REBASE_TODO) catch {
        // No more todo items, rebase complete
        cleanupRebaseState(repo.git_dir);
        try stdout_file.writeAll("Rebase complete.\n");
        return;
    };
    defer allocator.free(todo_data);

    // Parse remaining todo items
    var remaining_commits = std.array_list.Managed(RebaseTodo).init(allocator);
    defer {
        for (remaining_commits.items) |*c| {
            allocator.free(c.message);
        }
        remaining_commits.deinit();
    }

    var lines = std.mem.splitScalar(u8, todo_data, '\n');
    var found_current = false;
    while (lines.next()) |line| {
        if (line.len < types.OID_HEX_LEN) continue;
        const line_oid = types.ObjectId.fromHex(line[0..types.OID_HEX_LEN]) catch continue;

        if (!found_current) {
            if (line_oid.eql(&current_oid)) {
                found_current = true;
            }
            continue;
        }

        const msg_part = if (line.len > types.OID_HEX_LEN + 1) line[types.OID_HEX_LEN + 1 ..] else "";
        const msg_copy = try allocator.alloc(u8, msg_part.len);
        @memcpy(msg_copy, msg_part);

        try remaining_commits.append(.{
            .oid = line_oid,
            .message = msg_copy,
        });
    }

    if (remaining_commits.items.len > 0) {
        try applyRebaseCommits(allocator, repo, remaining_commits.items);
    } else {
        cleanupRebaseState(repo.git_dir);
        try stdout_file.writeAll("Rebase complete.\n");
    }
}

/// Skip the current commit and continue rebasing.
fn skipRebase(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    if (!isRebaseInProgress(repo.git_dir)) {
        try stderr_file.writeAll("fatal: no rebase in progress\n");
        std.process.exit(128);
    }

    // Reset working tree to HEAD
    const head_oid = repo.resolveRef(allocator, "HEAD") catch {
        try stderr_file.writeAll("fatal: cannot resolve HEAD\n");
        std.process.exit(128);
    };

    var head_obj = repo.readObject(allocator, &head_oid) catch {
        try stderr_file.writeAll("fatal: cannot read HEAD\n");
        std.process.exit(128);
    };
    defer head_obj.deinit();

    if (head_obj.obj_type == .commit) {
        const tree_oid = tree_diff.getCommitTreeOid(head_obj.data) catch {
            try stderr_file.writeAll("fatal: invalid commit\n");
            std.process.exit(128);
        };
        resetToTree(allocator, repo, &tree_oid) catch {};
    }

    try stdout_file.writeAll("Skipped current commit.\n");

    // Continue with remaining
    try continueRebase(repo, allocator);
}

/// Check if a rebase is in progress.
fn isRebaseInProgress(git_dir: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const dir_path = buildPathBuf(&path_buf, git_dir, REBASE_DIR);
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return false;
    dir.close();
    return true;
}

/// Create rebase state files.
fn createRebaseState(
    git_dir: []const u8,
    commits: []const RebaseTodo,
    onto_oid: types.ObjectId,
    orig_head: types.ObjectId,
    head_name: ?[]const u8,
) !void {
    // Create rebase-apply directory
    var dir_buf: [4096]u8 = undefined;
    const dir_path = buildPathBuf(&dir_buf, git_dir, REBASE_DIR);
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Write todo file
    {
        var todo_buf: [4096]u8 = undefined;
        const todo_path = buildPathBuf(&todo_buf, git_dir, REBASE_TODO);
        const file = try std.fs.createFileAbsolute(todo_path, .{ .truncate = true });
        defer file.close();

        for (commits) |*c| {
            const hex = c.oid.toHex();
            var line_buf: [512]u8 = undefined;
            var stream = std.io.fixedBufferStream(&line_buf);
            const writer = stream.writer();
            try writer.writeAll(&hex);
            try writer.writeByte(' ');
            try writer.writeAll(firstLine(c.message));
            try writer.writeByte('\n');
            try file.writeAll(line_buf[0..stream.pos]);
        }
    }

    // Write onto
    {
        var path_buf: [4096]u8 = undefined;
        const onto_path = buildPathBuf(&path_buf, git_dir, REBASE_ONTO);
        const hex = onto_oid.toHex();
        const file = try std.fs.createFileAbsolute(onto_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(&hex);
        try file.writeAll("\n");
    }

    // Write orig-head
    {
        var path_buf: [4096]u8 = undefined;
        const orig_path = buildPathBuf(&path_buf, git_dir, REBASE_ORIG_HEAD);
        const hex = orig_head.toHex();
        const file = try std.fs.createFileAbsolute(orig_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(&hex);
        try file.writeAll("\n");
    }

    // Also write ORIG_HEAD at the repo level
    try writeOrigHead(git_dir, orig_head);

    // Write head-name
    if (head_name) |name| {
        var path_buf: [4096]u8 = undefined;
        const name_path = buildPathBuf(&path_buf, git_dir, REBASE_HEAD_NAME);
        const file = try std.fs.createFileAbsolute(name_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(name);
        try file.writeAll("\n");
    }

    // Write total count
    {
        var path_buf: [4096]u8 = undefined;
        const total_path = buildPathBuf(&path_buf, git_dir, REBASE_TOTAL);
        const file = try std.fs.createFileAbsolute(total_path, .{ .truncate = true });
        defer file.close();
        var num_buf: [16]u8 = undefined;
        var stream = std.io.fixedBufferStream(&num_buf);
        stream.writer().print("{d}\n", .{commits.len}) catch {};
        try file.writeAll(num_buf[0..stream.pos]);
    }

    // Write done file (empty initially)
    {
        var path_buf: [4096]u8 = undefined;
        const done_path = buildPathBuf(&path_buf, git_dir, REBASE_DONE);
        const file = try std.fs.createFileAbsolute(done_path, .{ .truncate = true });
        file.close();
    }
}

/// Clean up rebase state.
fn cleanupRebaseState(git_dir: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    const dir_path = buildPathBuf(&path_buf, git_dir, REBASE_DIR);

    // Remove all files in the directory
    const files_to_remove = [_][]const u8{
        REBASE_TODO,
        REBASE_DONE,
        REBASE_HEAD_NAME,
        REBASE_ONTO,
        REBASE_ORIG_HEAD,
        REBASE_MSG,
        REBASE_CURRENT,
        REBASE_TOTAL,
        REBASE_NEXT,
    };

    for (files_to_remove) |suffix| {
        var file_buf: [4096]u8 = undefined;
        const file_path = buildPathBuf(&file_buf, git_dir, suffix);
        std.fs.deleteFileAbsolute(file_path) catch {};
    }

    // Remove the directory
    std.fs.deleteDirAbsolute(dir_path) catch {};

    // Remove ORIG_HEAD
    var orig_buf: [4096]u8 = undefined;
    const orig_path = buildPathBuf(&orig_buf, git_dir, "/ORIG_HEAD");
    std.fs.deleteFileAbsolute(orig_path) catch {};
}

/// Write the current commit being applied.
fn writeCurrentCommit(git_dir: []const u8, oid: *const types.ObjectId) !void {
    var path_buf: [4096]u8 = undefined;
    const path = buildPathBuf(&path_buf, git_dir, REBASE_CURRENT);
    const hex = oid.toHex();
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(&hex);
    try file.writeAll("\n");
}

/// Append a completed commit to the done file.
fn appendDone(git_dir: []const u8, oid: *const types.ObjectId, message: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    const path = buildPathBuf(&path_buf, git_dir, REBASE_DONE);

    const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch {
        const f = try std.fs.createFileAbsolute(path, .{});
        defer f.close();
        const hex = oid.toHex();
        try f.writeAll(&hex);
        try f.writeAll(" ");
        try f.writeAll(firstLine(message));
        try f.writeAll("\n");
        return;
    };
    defer file.close();

    const stat = try file.stat();
    try file.seekTo(stat.size);

    const hex = oid.toHex();
    try file.writeAll(&hex);
    try file.writeAll(" ");
    try file.writeAll(firstLine(message));
    try file.writeAll("\n");
}

/// Write progress to the next file.
fn writeRebaseProgress(git_dir: []const u8, current: usize, total: usize) !void {
    _ = total;
    var path_buf: [4096]u8 = undefined;
    const path = buildPathBuf(&path_buf, git_dir, REBASE_NEXT);
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    var num_buf: [16]u8 = undefined;
    var stream = std.io.fixedBufferStream(&num_buf);
    stream.writer().print("{d}\n", .{current}) catch {};
    try file.writeAll(num_buf[0..stream.pos]);
}

/// Move HEAD to a specific commit.
fn moveHeadTo(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    oid: types.ObjectId,
) !void {
    const head_ref = ref_mod.readHead(allocator, repo.git_dir) catch null;
    defer if (head_ref) |h| allocator.free(h);

    if (head_ref) |name| {
        try ref_mod.createRef(allocator, repo.git_dir, name, oid, null);
    } else {
        try writeDetachedHead(repo.git_dir, oid);
    }

    // Reset working tree
    var obj = try repo.readObject(allocator, &oid);
    defer obj.deinit();

    if (obj.obj_type == .commit) {
        const tree_oid = try tree_diff.getCommitTreeOid(obj.data);
        try resetToTree(allocator, repo, &tree_oid);
    }
}

/// Update HEAD to a new commit.
fn updateHead(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    old_oid: types.ObjectId,
    new_oid: types.ObjectId,
) !void {
    const head_ref = ref_mod.readHead(allocator, repo.git_dir) catch null;
    defer if (head_ref) |h| allocator.free(h);

    if (head_ref) |name| {
        try ref_mod.createRef(allocator, repo.git_dir, name, new_oid, null);
        reflog_mod.appendReflog(repo.git_dir, name, old_oid, new_oid, "rebase") catch {};
    } else {
        try writeDetachedHead(repo.git_dir, new_oid);
    }

    reflog_mod.appendReflog(repo.git_dir, "HEAD", old_oid, new_oid, "rebase") catch {};
}

/// Write ORIG_HEAD.
fn writeOrigHead(git_dir: []const u8, oid: types.ObjectId) !void {
    var path_buf: [4096]u8 = undefined;
    const path = buildPathBuf(&path_buf, git_dir, "/ORIG_HEAD");
    const hex = oid.toHex();
    var content_buf: [types.OID_HEX_LEN + 1]u8 = undefined;
    @memcpy(content_buf[0..types.OID_HEX_LEN], &hex);
    content_buf[types.OID_HEX_LEN] = '\n';
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(&content_buf);
}

/// Read ORIG_HEAD.
fn readOrigHead(allocator: std.mem.Allocator, git_dir: []const u8) !types.ObjectId {
    var path_buf: [4096]u8 = undefined;
    const path = buildPathBuf(&path_buf, git_dir, "/ORIG_HEAD");
    const content = try readFileContents(allocator, path);
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n\r ");
    if (trimmed.len < types.OID_HEX_LEN) return error.InvalidOrigHead;
    return types.ObjectId.fromHex(trimmed[0..types.OID_HEX_LEN]);
}

/// Read a rebase state file.
fn readRebaseFile(allocator: std.mem.Allocator, git_dir: []const u8, suffix: []const u8) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    const path = buildPathBuf(&path_buf, git_dir, suffix);
    return readFileContents(allocator, path);
}

/// Write conflict markers for a file.
fn writeConflictMarkers(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    work_dir: []const u8,
    rel_path: []const u8,
    ours_oid: *const types.ObjectId,
    theirs_oid: *const types.ObjectId,
) !void {
    var ours_data: []const u8 = "";
    var ours_obj: ?types.Object = null;
    defer if (ours_obj) |*o| o.deinit();

    {
        const obj = try repo.readObject(allocator, ours_oid);
        ours_obj = obj;
        ours_data = obj.data;
    }

    var theirs_data: []const u8 = "";
    var theirs_obj: ?types.Object = null;
    defer if (theirs_obj) |*o| o.deinit();

    {
        const obj = try repo.readObject(allocator, theirs_oid);
        theirs_obj = obj;
        theirs_data = obj.data;
    }

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
    try content.appendSlice(">>>>>>> rebase\n");

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
    try file.writeAll(content.items);
}

/// Get a file's blob OID from a tree.
fn getFileBlobOidFromTree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    tree_oid: *const types.ObjectId,
    file_path: []const u8,
) ?types.ObjectId {
    return getFileBlobOidFromTreeInner(allocator, repo, tree_oid, file_path) catch return null;
}

fn getFileBlobOidFromTreeInner(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    tree_oid: *const types.ObjectId,
    file_path: []const u8,
) !types.ObjectId {
    var current_tree_oid = tree_oid.*;
    var remaining = file_path;

    while (remaining.len > 0) {
        const slash_pos = std.mem.indexOfScalar(u8, remaining, '/');
        const component = if (slash_pos) |sp| remaining[0..sp] else remaining;
        const rest = if (slash_pos) |sp| remaining[sp + 1 ..] else "";

        var tree_obj = try repo.readObject(allocator, &current_tree_oid);
        defer tree_obj.deinit();

        if (tree_obj.obj_type != .tree) return error.NotATree;

        const entry_oid = findTreeEntry(tree_obj.data, component) orelse return error.ObjectNotFound;

        if (rest.len == 0) return entry_oid;
        current_tree_oid = entry_oid;
        remaining = rest;
    }

    return error.ObjectNotFound;
}

fn findTreeEntry(tree_data: []const u8, name: []const u8) ?types.ObjectId {
    var pos: usize = 0;
    while (pos < tree_data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, tree_data, pos, ' ') orelse return null;
        const null_pos = std.mem.indexOfScalarPos(u8, tree_data, space_pos + 1, 0) orelse return null;
        const entry_name = tree_data[space_pos + 1 .. null_pos];

        if (null_pos + 1 + types.OID_RAW_LEN > tree_data.len) return null;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, tree_data[null_pos + 1 ..][0..types.OID_RAW_LEN]);
        pos = null_pos + 1 + types.OID_RAW_LEN;

        if (std.mem.eql(u8, entry_name, name)) return oid;
    }
    return null;
}

/// Reset working tree and index to a tree.
fn resetToTree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    tree_oid: *const types.ObjectId,
) !void {
    const work_dir = getWorkDir(repo.git_dir);

    var flat = try checkout_mod.flattenTree(allocator, repo, tree_oid);
    defer flat.deinit();

    for (flat.entries.items) |*entry| {
        writeBlobToWorkTree(allocator, repo, work_dir, entry.path, &entry.oid) catch continue;
    }

    var idx = index_mod.Index.init(allocator);
    defer idx.deinit();

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

    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPathBuf(&index_path_buf, repo.git_dir, "/index");
    try idx.writeToFile(index_path);
}

// Helper functions

fn extractCommitMessage(data: []const u8) []const u8 {
    var i: usize = 0;
    while (i < data.len) {
        if (i + 1 < data.len and data[i] == '\n' and data[i + 1] == '\n') {
            const body_start = i + 2;
            if (body_start >= data.len) return "";
            return std.mem.trimRight(u8, data[body_start..], "\n\r ");
        }
        i += 1;
    }
    return "";
}

fn extractAuthorLine(data: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "author ")) return line[7..];
    }
    return null;
}

fn firstLine(message: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, message, '\n') orelse message.len;
    const truncated = if (end > 72) 72 else end;
    return message[0..truncated];
}

fn writeBlobToWorkTree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    work_dir: []const u8,
    rel_path: []const u8,
    oid: *const types.ObjectId,
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
}

fn deleteFromWorkTree(work_dir: []const u8, rel_path: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&path_buf);
    const writer = stream.writer();
    writer.writeAll(work_dir) catch return;
    writer.writeByte('/') catch return;
    writer.writeAll(rel_path) catch return;
    std.fs.deleteFileAbsolute(path_buf[0..stream.pos]) catch {};
}

fn writeDetachedHead(git_dir: []const u8, oid: types.ObjectId) !void {
    var path_buf: [4096]u8 = undefined;
    const path = buildPathBuf(&path_buf, git_dir, "/HEAD");
    const hex = oid.toHex();
    var content_buf: [types.OID_HEX_LEN + 1]u8 = undefined;
    @memcpy(content_buf[0..types.OID_HEX_LEN], &hex);
    content_buf[types.OID_HEX_LEN] = '\n';
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(&content_buf);
}

fn parseModeStr(mode_str: []const u8) u32 {
    var result: u32 = 0;
    for (mode_str) |c| {
        if (c < '0' or c > '7') break;
        result = result * 8 + @as(u32, c - '0');
    }
    return result;
}

fn getWorkDir(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    if (std.fs.path.dirname(git_dir)) |parent| return parent;
    return git_dir;
}

fn buildPathBuf(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
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

fn getTimestamp(buf: []u8) []const u8 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return "0";
    var stream = std.io.fixedBufferStream(buf);
    stream.writer().print("{d}", .{ts.sec}) catch return "0";
    return buf[0..stream.pos];
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "extractCommitMessage" {
    const data = "tree abc\nparent def\n\nHello world\n";
    const msg = extractCommitMessage(data);
    try std.testing.expectEqualStrings("Hello world", msg);
}

test "firstLine" {
    try std.testing.expectEqualStrings("first", firstLine("first\nsecond"));
    try std.testing.expectEqualStrings("only", firstLine("only"));
}

test "parseModeStr" {
    try std.testing.expectEqual(@as(u32, 0o100644), parseModeStr("100644"));
}

test "buildPathBuf" {
    var buf: [256]u8 = undefined;
    const result = buildPathBuf(&buf, "/foo", "/bar");
    try std.testing.expectEqualStrings("/foo/bar", result);
}
