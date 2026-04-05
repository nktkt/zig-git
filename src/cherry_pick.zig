const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_diff = @import("tree_diff.zig");
const loose = @import("loose.zig");
const index_mod = @import("index.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");
const checkout_mod = @import("checkout.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// State for an in-progress cherry-pick.
pub const CherryPickState = struct {
    head_oid: types.ObjectId,
    cherry_oid: types.ObjectId,
    message: []const u8,
    has_conflicts: bool,
};

/// Options for cherry-pick command.
pub const CherryPickOptions = struct {
    commit_ref: ?[]const u8 = null,
    abort: bool = false,
    continue_pick: bool = false,
    no_commit: bool = false,
    edit: bool = false,
};

/// Entry point for the cherry-pick command.
pub fn runCherryPick(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = CherryPickOptions{};

    // Parse arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--abort")) {
            opts.abort = true;
        } else if (std.mem.eql(u8, arg, "--continue")) {
            opts.continue_pick = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--no-commit")) {
            opts.no_commit = true;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--edit")) {
            opts.edit = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            opts.commit_ref = arg;
        }
    }

    if (opts.abort) {
        return abortCherryPick(repo, allocator);
    }

    if (opts.continue_pick) {
        return continueCherryPick(repo, allocator);
    }

    if (opts.commit_ref == null) {
        try stderr_file.writeAll("fatal: no commit specified\n");
        try stderr_file.writeAll("usage: zig-git cherry-pick [--abort | --continue] <commit>\n");
        std.process.exit(1);
    }

    // Check if there's already a cherry-pick in progress
    if (isCherryPickInProgress(repo.git_dir)) {
        try stderr_file.writeAll("fatal: cherry-pick is already in progress\n");
        try stderr_file.writeAll("hint: use 'zig-git cherry-pick --continue' to continue\n");
        try stderr_file.writeAll("hint: use 'zig-git cherry-pick --abort' to cancel\n");
        std.process.exit(1);
    }

    // Resolve the commit to cherry-pick
    const cherry_oid = repo.resolveRef(allocator, opts.commit_ref.?) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: bad revision '{s}'\n", .{opts.commit_ref.?}) catch
            "fatal: bad revision\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    // Read the commit to cherry-pick
    var cherry_obj = try repo.readObject(allocator, &cherry_oid);
    defer cherry_obj.deinit();

    if (cherry_obj.obj_type != .commit) {
        try stderr_file.writeAll("fatal: not a commit object\n");
        std.process.exit(128);
    }

    // Parse the commit
    const cherry_tree_oid = try tree_diff.getCommitTreeOid(cherry_obj.data);
    var cherry_parents = try tree_diff.getCommitParents(allocator, cherry_obj.data);
    defer cherry_parents.deinit();

    if (cherry_parents.items.len == 0) {
        try stderr_file.writeAll("fatal: cannot cherry-pick a root commit\n");
        std.process.exit(128);
    }

    const parent_oid = cherry_parents.items[0]; // Use first parent

    // Get the commit message
    const cherry_message = extractCommitMessage(cherry_obj.data);

    // Resolve current HEAD
    const head_oid = repo.resolveRef(allocator, "HEAD") catch {
        try stderr_file.writeAll("fatal: HEAD does not point to a valid commit\n");
        std.process.exit(128);
    };

    // Get the trees for the three-way merge
    var head_obj = try repo.readObject(allocator, &head_oid);
    defer head_obj.deinit();
    const head_tree_oid = try tree_diff.getCommitTreeOid(head_obj.data);

    // Diff: parent -> cherry (the changes we want to apply)
    var changes = try tree_diff.diffTrees(repo, allocator, &parent_oid, &cherry_tree_oid);
    defer changes.deinit();

    // Read the parent tree for three-way merge base

    // Apply changes to HEAD tree
    const work_dir = getWorkDir(repo.git_dir);

    // Load the current index
    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPath(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    // Write CHERRY_PICK_HEAD before applying changes
    try writeCherryPickHead(repo.git_dir, cherry_oid);

    // Apply each change
    var has_conflicts = false;
    var applied_count: usize = 0;
    var conflict_count: usize = 0;

    for (changes.changes.items) |*change| {
        switch (change.kind) {
            .added => {
                // New file added: write it to working tree
                if (change.new_oid) |new_oid| {
                    const new_oid_const = new_oid;
                    writeBlobToWorkTree(allocator, repo, work_dir, change.path, &new_oid_const) catch |err| {
                        switch (err) {
                            error.ObjectNotFound => {
                                conflict_count += 1;
                                has_conflicts = true;
                                continue;
                            },
                            else => return err,
                        }
                    };

                    // Update index
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
                        .oid = new_oid_const,
                        .flags = 0,
                        .name = name_copy,
                        .owned = true,
                    });
                    applied_count += 1;
                }
            },
            .deleted => {
                // File removed: delete from working tree
                deleteFromWorkTree(work_dir, change.path);

                // Remove from index
                _ = idx.removeEntry(change.path);
                applied_count += 1;
            },
            .modified => {
                // File modified: check for conflicts
                if (change.new_oid) |new_oid| {
                    // Check if the file in HEAD matches what we expect (the parent's version)
                    const new_oid_const = new_oid;
                    const head_blob = getFileBlobOidFromTree(allocator, repo, &head_tree_oid, change.path);

                    if (head_blob) |head_blob_oid| {
                        // Check if HEAD has the same content as the cherry-pick parent
                        if (change.old_oid) |old_oid| {
                            if (head_blob_oid.eql(&old_oid)) {
                                // Clean apply: HEAD matches parent, just use cherry version
                                writeBlobToWorkTree(allocator, repo, work_dir, change.path, &new_oid_const) catch {
                                    conflict_count += 1;
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
                                    .oid = new_oid_const,
                                    .flags = 0,
                                    .name = name_copy,
                                    .owned = true,
                                });
                                applied_count += 1;
                            } else {
                                // HEAD has different content than parent: CONFLICT
                                has_conflicts = true;
                                conflict_count += 1;
                                try writeConflictFile(allocator, repo, work_dir, change.path, &head_blob_oid, &new_oid_const);
                            }
                        } else {
                            // No old OID (shouldn't happen for modified), treat as add
                            writeBlobToWorkTree(allocator, repo, work_dir, change.path, &new_oid_const) catch {
                                conflict_count += 1;
                                has_conflicts = true;
                                continue;
                            };
                            applied_count += 1;
                        }
                    } else {
                        // File doesn't exist in HEAD: conflict (delete/modify)
                        has_conflicts = true;
                        conflict_count += 1;
                        writeBlobToWorkTree(allocator, repo, work_dir, change.path, &new_oid_const) catch {
                            continue;
                        };
                    }
                }
            },
        }
    }

    // Write updated index
    try idx.writeToFile(index_path);

    if (has_conflicts) {
        // Write merge message for when the user resolves
        try writeCherryPickMsg(repo.git_dir, cherry_message);

        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: could not apply {s}... {s}\n", .{
            cherry_oid.toHex()[0..7],
            firstLine(cherry_message),
        }) catch "error: could not apply cherry-pick\n";
        try stderr_file.writeAll(msg);

        var cbuf: [128]u8 = undefined;
        const cmsg = std.fmt.bufPrint(&cbuf, "hint: {d} conflict(s) detected. Resolve and use 'cherry-pick --continue'\n", .{conflict_count}) catch "";
        try stderr_file.writeAll(cmsg);

        std.process.exit(1);
    }

    if (!opts.no_commit) {
        // Create the cherry-picked commit
        const commit_oid = try createCherryPickCommit(allocator, repo, cherry_message, cherry_obj.data);

        // Clean up state
        removeCherryPickHead(repo.git_dir);

        const new_hex = commit_oid.toHex();
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[detached HEAD {s}] {s}\n", .{
            new_hex[0..7],
            firstLine(cherry_message),
        }) catch "cherry-pick applied\n";
        try stdout_file.writeAll(msg);
    } else {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Changes applied (not committed). {d} files changed.\n", .{applied_count}) catch
            "Changes applied.\n";
        try stdout_file.writeAll(msg);
    }
}

/// Abort a cherry-pick in progress.
fn abortCherryPick(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    if (!isCherryPickInProgress(repo.git_dir)) {
        try stderr_file.writeAll("fatal: no cherry-pick in progress\n");
        std.process.exit(128);
    }

    // Restore HEAD to its state before cherry-pick
    const head_oid = repo.resolveRef(allocator, "HEAD") catch {
        try stderr_file.writeAll("fatal: cannot read HEAD\n");
        std.process.exit(128);
    };

    // Reset working tree to HEAD
    var head_obj = repo.readObject(allocator, &head_oid) catch {
        try stderr_file.writeAll("fatal: cannot read HEAD commit\n");
        std.process.exit(128);
    };
    defer head_obj.deinit();

    if (head_obj.obj_type == .commit) {
        const tree_oid = tree_diff.getCommitTreeOid(head_obj.data) catch {
            try stderr_file.writeAll("fatal: invalid commit\n");
            std.process.exit(128);
        };

        // Flatten tree and rebuild index + working tree
        resetToTree(allocator, repo, &tree_oid) catch {
            try stderr_file.writeAll("fatal: reset failed\n");
            std.process.exit(128);
        };
    }

    // Clean up state files
    removeCherryPickHead(repo.git_dir);
    removeCherryPickMsg(repo.git_dir);

    try stdout_file.writeAll("cherry-pick aborted\n");
}

/// Continue a cherry-pick after conflict resolution.
fn continueCherryPick(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    if (!isCherryPickInProgress(repo.git_dir)) {
        try stderr_file.writeAll("fatal: no cherry-pick in progress\n");
        std.process.exit(128);
    }

    // Read the cherry-pick message
    const message = readCherryPickMsg(allocator, repo.git_dir) catch {
        try stderr_file.writeAll("fatal: cannot read cherry-pick message\n");
        std.process.exit(128);
    };
    defer allocator.free(message);

    // Read CHERRY_PICK_HEAD to get original commit data
    const cherry_oid = readCherryPickHead(allocator, repo.git_dir) catch {
        try stderr_file.writeAll("fatal: cannot read CHERRY_PICK_HEAD\n");
        std.process.exit(128);
    };

    var cherry_obj = repo.readObject(allocator, &cherry_oid) catch {
        try stderr_file.writeAll("fatal: cannot read cherry-pick commit\n");
        std.process.exit(128);
    };
    defer cherry_obj.deinit();

    // Create the commit from the current index
    const commit_oid = try createCherryPickCommit(allocator, repo, message, cherry_obj.data);

    // Clean up state
    removeCherryPickHead(repo.git_dir);
    removeCherryPickMsg(repo.git_dir);

    const new_hex = commit_oid.toHex();
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[detached HEAD {s}] {s}\n", .{
        new_hex[0..7],
        firstLine(message),
    }) catch "cherry-pick continued\n";
    try stdout_file.writeAll(msg);
}

/// Create a cherry-pick commit using the current index.
fn createCherryPickCommit(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    message: []const u8,
    original_commit_data: []const u8,
) !types.ObjectId {
    // Load current index
    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPath(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    // Build tree from index
    const tree_builder = @import("tree_builder.zig");
    const tree_oid = try tree_builder.buildTree(allocator, repo.git_dir, &idx);

    // Get current HEAD as parent
    const head_oid = try repo.resolveRef(allocator, "HEAD");

    // Extract original author info
    const author_line = extractAuthorLine(original_commit_data) orelse "zig-git <zig-git@localhost> 0 +0000";

    // Build commit object
    var commit_data = std.array_list.Managed(u8).init(allocator);
    defer commit_data.deinit();

    const tree_hex = tree_oid.toHex();
    try commit_data.appendSlice("tree ");
    try commit_data.appendSlice(&tree_hex);
    try commit_data.append('\n');

    const parent_hex = head_oid.toHex();
    try commit_data.appendSlice("parent ");
    try commit_data.appendSlice(&parent_hex);
    try commit_data.append('\n');

    // Use original author
    try commit_data.appendSlice("author ");
    try commit_data.appendSlice(author_line);
    try commit_data.append('\n');

    // Committer is current user
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

    // Write commit object
    const commit_oid = try loose.writeLooseObject(allocator, repo.git_dir, .commit, commit_data.items);

    // Update HEAD
    if (ref_mod.readHead(allocator, repo.git_dir) catch null) |head_ref| {
        defer allocator.free(head_ref);
        try ref_mod.createRef(allocator, repo.git_dir, head_ref, commit_oid, null);

        // Update reflog
        reflog_mod.appendReflog(repo.git_dir, head_ref, head_oid, commit_oid, "cherry-pick") catch {};
    } else {
        // Detached HEAD
        try writeDetachedHead(repo.git_dir, commit_oid);
    }

    reflog_mod.appendReflog(repo.git_dir, "HEAD", head_oid, commit_oid, "cherry-pick") catch {};

    return commit_oid;
}

/// Check if a cherry-pick is in progress.
fn isCherryPickInProgress(git_dir: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    const suffix = "/CHERRY_PICK_HEAD";
    @memcpy(path_buf[git_dir.len..][0..suffix.len], suffix);
    const path = path_buf[0 .. git_dir.len + suffix.len];

    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

/// Write CHERRY_PICK_HEAD file.
fn writeCherryPickHead(git_dir: []const u8, oid: types.ObjectId) !void {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    const suffix = "/CHERRY_PICK_HEAD";
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

/// Read CHERRY_PICK_HEAD.
fn readCherryPickHead(allocator: std.mem.Allocator, git_dir: []const u8) !types.ObjectId {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    const suffix = "/CHERRY_PICK_HEAD";
    @memcpy(path_buf[git_dir.len..][0..suffix.len], suffix);
    const path = path_buf[0 .. git_dir.len + suffix.len];

    const content = try readFileContents(allocator, path);
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n\r ");
    if (trimmed.len < types.OID_HEX_LEN) return error.InvalidCherryPickHead;
    return types.ObjectId.fromHex(trimmed[0..types.OID_HEX_LEN]);
}

/// Remove CHERRY_PICK_HEAD.
fn removeCherryPickHead(git_dir: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    const suffix = "/CHERRY_PICK_HEAD";
    @memcpy(path_buf[git_dir.len..][0..suffix.len], suffix);
    const path = path_buf[0 .. git_dir.len + suffix.len];
    std.fs.deleteFileAbsolute(path) catch {};
}

/// Write CHERRY_PICK_MSG file.
fn writeCherryPickMsg(git_dir: []const u8, message: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    const suffix = "/MERGE_MSG";
    @memcpy(path_buf[git_dir.len..][0..suffix.len], suffix);
    const path = path_buf[0 .. git_dir.len + suffix.len];

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(message);
}

/// Read CHERRY_PICK_MSG (stored in MERGE_MSG).
fn readCherryPickMsg(allocator: std.mem.Allocator, git_dir: []const u8) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    const suffix = "/MERGE_MSG";
    @memcpy(path_buf[git_dir.len..][0..suffix.len], suffix);
    const path = path_buf[0 .. git_dir.len + suffix.len];

    return readFileContents(allocator, path);
}

/// Remove MERGE_MSG.
fn removeCherryPickMsg(git_dir: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..git_dir.len], git_dir);
    const suffix = "/MERGE_MSG";
    @memcpy(path_buf[git_dir.len..][0..suffix.len], suffix);
    const path = path_buf[0 .. git_dir.len + suffix.len];
    std.fs.deleteFileAbsolute(path) catch {};
}

/// Extract the commit message body from raw commit data.
fn extractCommitMessage(data: []const u8) []const u8 {
    // Find the double newline that separates headers from body
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

/// Extract the author line from commit data.
fn extractAuthorLine(data: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "author ")) {
            return line[7..];
        }
    }
    return null;
}

/// Get the first line of a message.
fn firstLine(message: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, message, '\n') orelse message.len;
    const truncated = if (end > 72) 72 else end;
    return message[0..truncated];
}

/// Write a blob to the working tree.
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
}

/// Write conflict markers for a file.
fn writeConflictFile(
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

    // Build conflict content
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
    try content.appendSlice(">>>>>>> cherry-pick\n");

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

/// Find an entry in a tree object by name.
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

/// Reset working tree and index to a specific tree.
fn resetToTree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    tree_oid: *const types.ObjectId,
) !void {
    const work_dir = getWorkDir(repo.git_dir);

    var flat = try checkout_mod.flattenTree(allocator, repo, tree_oid);
    defer flat.deinit();

    // Write all files
    for (flat.entries.items) |*entry| {
        writeBlobToWorkTree(allocator, repo, work_dir, entry.path, &entry.oid) catch continue;
    }

    // Rebuild index
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
    const index_path = buildPath(&index_path_buf, repo.git_dir, "/index");
    try idx.writeToFile(index_path);
}

/// Write a direct OID to HEAD for detached HEAD mode.
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

/// Parse a mode string (e.g., "100644") into a u32.
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
    if (std.fs.path.dirname(git_dir)) |parent| {
        return parent;
    }
    return git_dir;
}

fn buildPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
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
    const writer = stream.writer();
    writer.print("{d}", .{ts.sec}) catch return "0";
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
    const data = "tree abc\nparent def\nauthor foo\n\nThis is the message\n";
    const msg = extractCommitMessage(data);
    try std.testing.expectEqualStrings("This is the message", msg);
}

test "extractAuthorLine" {
    const data = "tree abc\nauthor John <john@test.com> 12345 +0000\n\nmessage";
    const line = extractAuthorLine(data);
    try std.testing.expect(line != null);
    try std.testing.expectEqualStrings("John <john@test.com> 12345 +0000", line.?);
}

test "firstLine" {
    try std.testing.expectEqualStrings("hello", firstLine("hello\nworld"));
    try std.testing.expectEqualStrings("single", firstLine("single"));
}

test "parseModeStr" {
    try std.testing.expectEqual(@as(u32, 0o100644), parseModeStr("100644"));
    try std.testing.expectEqual(@as(u32, 0o100755), parseModeStr("100755"));
    try std.testing.expectEqual(@as(u32, 0o40000), parseModeStr("40000"));
}

test "findTreeEntry empty" {
    const result = findTreeEntry("", "foo");
    try std.testing.expect(result == null);
}
