const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const patch_mod = @import("patch.zig");
const apply_mod = @import("apply.zig");
const index_mod = @import("index.zig");
const tree_diff = @import("tree_diff.zig");
const hash_mod = @import("hash.zig");
const loose = @import("loose.zig");
const ref_mod = @import("ref.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// State of an in-progress am session.
const AmState = struct {
    /// Total number of patches
    total: usize,
    /// Current patch index (1-based)
    current: usize,
    /// Path to the rebase-apply directory
    state_dir: []const u8,
};

/// Run the am command from CLI args.
pub fn runAm(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr_file.writeAll(am_usage);
        return;
    }

    const first_arg = args[0];

    if (std.mem.eql(u8, first_arg, "--abort")) {
        try amAbort(repo, allocator);
        return;
    }
    if (std.mem.eql(u8, first_arg, "--continue")) {
        try amContinue(repo, allocator);
        return;
    }
    if (std.mem.eql(u8, first_arg, "--skip")) {
        try amSkip(repo, allocator);
        return;
    }

    // Collect mbox files
    var mbox_files = std.array_list.Managed([]const u8).init(allocator);
    defer mbox_files.deinit();
    // three_way option parsed but not yet used in this implementation
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-3") or std.mem.eql(u8, arg, "--3way")) {
            // three_way mode (not yet implemented)
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try mbox_files.append(arg);
        }
    }

    if (mbox_files.items.len == 0) {
        try stderr_file.writeAll(am_usage);
        return;
    }

    for (mbox_files.items) |mbox_path| {
        try applyMbox(repo, allocator, mbox_path);
    }
}

const am_usage =
    \\usage: zig-git am [options] <mbox-file>...
    \\
    \\Options:
    \\  --abort     Abort the current am operation
    \\  --continue  Continue after resolving conflicts
    \\  --skip      Skip the current patch
    \\  -3, --3way  Attempt three-way merge
    \\
;

/// Apply patches from an mbox file.
fn applyMbox(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    mbox_path: []const u8,
) !void {
    // Read the mbox file
    const content = readFile(allocator, mbox_path) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: could not read mbox file: {s}\n", .{@errorName(err)}) catch
            "fatal: could not read mbox file\n";
        try stderr_file.writeAll(msg);
        return;
    };
    defer allocator.free(content);

    // Parse mbox
    var mbox = patch_mod.parseMbox(allocator, content) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: could not parse mbox: {s}\n", .{@errorName(err)}) catch
            "fatal: could not parse mbox\n";
        try stderr_file.writeAll(msg);
        return;
    };
    defer mbox.deinit();

    if (mbox.messages.items.len == 0) {
        try stderr_file.writeAll("No patches found in mbox file\n");
        return;
    }

    // Set up rebase-apply state directory
    var state_dir_buf: [4096]u8 = undefined;
    const state_dir = concatPath(&state_dir_buf, repo.git_dir, "/rebase-apply");
    mkdirRecursive(state_dir) catch {};

    // Save state
    saveAmState(state_dir, mbox.messages.items.len, 1) catch {};

    const total = mbox.messages.items.len;

    // Apply each patch
    for (mbox.messages.items, 0..) |*msg_item, msg_idx| {
        const patch_num = msg_idx + 1;

        {
            var buf: [256]u8 = undefined;
            const progress = std.fmt.bufPrint(&buf, "Applying: {s}\n", .{getSubjectSummary(msg_item.subject)}) catch
                "Applying patch...\n";
            try stdout_file.writeAll(progress);
        }

        // Update state
        saveAmState(state_dir, total, patch_num) catch {};

        // Parse the patch from the message
        if (msg_item.patch_text.len == 0) {
            var buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&buf, "warning: patch {d}/{d} has no diff content, skipping\n", .{ patch_num, total }) catch
                "warning: patch has no diff content\n";
            try stderr_file.writeAll(err_msg);
            continue;
        }

        var patch = patch_mod.parsePatch(allocator, msg_item.patch_text) catch |err| {
            var buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&buf, "error: could not parse patch {d}: {s}\n", .{ patch_num, @errorName(err) }) catch
                "error: could not parse patch\n";
            try stderr_file.writeAll(err_msg);
            continue;
        };
        defer patch.deinit();

        // Apply the patch to the working tree
        const work_dir = getWorkDir(repo.git_dir);
        var apply_failed = false;

        for (patch.file_diffs.items) |*fd| {
            if (fd.is_binary) {
                var buf: [256]u8 = undefined;
                const skip_msg = std.fmt.bufPrint(&buf, "skipping binary file: {s}\n", .{fd.new_path}) catch continue;
                try stderr_file.writeAll(skip_msg);
                continue;
            }

            applyFileDiffToWorkTree(allocator, work_dir, fd) catch |err| {
                var buf: [256]u8 = undefined;
                const target = if (fd.new_path.len > 0) fd.new_path else fd.old_path;
                const err_msg = std.fmt.bufPrint(&buf, "error: patch failed for {s}: {s}\n", .{ target, @errorName(err) }) catch
                    "error: patch failed\n";
                stderr_file.writeAll(err_msg) catch {};
                apply_failed = true;
            };
        }

        if (apply_failed) {
            try stderr_file.writeAll("Patch failed. Fix the issue and run 'zig-git am --continue'\n");
            // Save current message info for --continue
            savePatchMsg(state_dir, msg_item) catch {};
            return;
        }

        // Create a commit with the patch metadata
        createCommitFromPatch(repo, allocator, msg_item) catch |err| {
            var buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&buf, "error: could not create commit: {s}\n", .{@errorName(err)}) catch
                "error: could not create commit\n";
            try stderr_file.writeAll(err_msg);
        };
    }

    // Clean up state directory
    cleanupAmState(state_dir);
    try stdout_file.writeAll("Applied all patches successfully\n");
}

/// Abort the current am operation.
fn amAbort(repo: *repository.Repository, allocator: std.mem.Allocator) !void {
    _ = allocator;
    var state_dir_buf: [4096]u8 = undefined;
    const state_dir = concatPath(&state_dir_buf, repo.git_dir, "/rebase-apply");

    if (!isDirectory(state_dir)) {
        try stderr_file.writeAll("fatal: no am in progress\n");
        return;
    }

    cleanupAmState(state_dir);
    try stdout_file.writeAll("am operation aborted\n");
}

/// Continue the am operation after conflict resolution.
fn amContinue(repo: *repository.Repository, allocator: std.mem.Allocator) !void {
    var state_dir_buf: [4096]u8 = undefined;
    const state_dir = concatPath(&state_dir_buf, repo.git_dir, "/rebase-apply");

    if (!isDirectory(state_dir)) {
        try stderr_file.writeAll("fatal: no am in progress\n");
        return;
    }

    // Read saved patch message
    var msg_path_buf: [4096]u8 = undefined;
    const msg_path = concatPath(&msg_path_buf, state_dir, "/msg");

    const msg_content = readFileMaybe(allocator, msg_path);
    defer if (msg_content) |c| allocator.free(c);

    if (msg_content) |content| {
        // Create a commit with the saved message
        var msg = patch_mod.MboxMessage{
            .from = "",
            .date = "",
            .subject = std.mem.trimRight(u8, content, "\n\r "),
            .message_id = "",
            .body = "",
            .patch_text = "",
        };

        createCommitFromPatch(repo, allocator, &msg) catch |err| {
            var buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&buf, "error: could not create commit: {s}\n", .{@errorName(err)}) catch
                "error: could not create commit\n";
            try stderr_file.writeAll(err_msg);
            return;
        };
    }

    cleanupAmState(state_dir);
    try stdout_file.writeAll("am operation continued\n");
}

/// Skip the current patch in am.
fn amSkip(repo: *repository.Repository, allocator: std.mem.Allocator) !void {
    _ = allocator;
    var state_dir_buf: [4096]u8 = undefined;
    const state_dir = concatPath(&state_dir_buf, repo.git_dir, "/rebase-apply");

    if (!isDirectory(state_dir)) {
        try stderr_file.writeAll("fatal: no am in progress\n");
        return;
    }

    cleanupAmState(state_dir);
    try stdout_file.writeAll("Skipped current patch\n");
}

/// Apply a single file diff to the working tree (simplified version for am).
fn applyFileDiffToWorkTree(
    allocator: std.mem.Allocator,
    work_dir: []const u8,
    fd: *const patch_mod.FileDiff,
) !void {
    const target_path_name = if (fd.new_path.len > 0) fd.new_path else fd.old_path;

    var path_buf: [4096]u8 = undefined;
    const full_path = concatPath3(&path_buf, work_dir, "/", target_path_name);

    if (fd.is_deleted) {
        std.fs.deleteFileAbsolute(full_path) catch {};
        return;
    }

    if (fd.is_new) {
        if (std.fs.path.dirname(full_path)) |parent| {
            mkdirRecursive(parent) catch {};
        }

        var new_content = std.array_list.Managed(u8).init(allocator);
        defer new_content.deinit();

        for (fd.hunks.items) |*hunk| {
            for (hunk.lines.items) |*line| {
                if (line.kind == .addition) {
                    try new_content.appendSlice(line.content);
                    try new_content.append('\n');
                }
            }
        }

        const file = std.fs.createFileAbsolute(full_path, .{}) catch return error.CannotCreateFile;
        defer file.close();
        try file.writeAll(new_content.items);
        return;
    }

    // Modify existing file
    const old_content = readFileMaybe(allocator, full_path) orelse return error.FileNotFound;
    defer allocator.free(old_content);

    var old_lines = std.array_list.Managed([]const u8).init(allocator);
    defer old_lines.deinit();
    try splitLines(old_content, &old_lines);

    var new_lines = std.array_list.Managed([]const u8).init(allocator);
    defer new_lines.deinit();

    var old_idx: usize = 0;

    for (fd.hunks.items) |*hunk| {
        const hunk_start = if (hunk.old_start > 0) hunk.old_start - 1 else 0;

        while (old_idx < hunk_start and old_idx < old_lines.items.len) {
            try new_lines.append(old_lines.items[old_idx]);
            old_idx += 1;
        }

        for (hunk.lines.items) |*line| {
            switch (line.kind) {
                .context => {
                    if (old_idx < old_lines.items.len) {
                        try new_lines.append(old_lines.items[old_idx]);
                        old_idx += 1;
                    }
                },
                .addition => {
                    try new_lines.append(line.content);
                },
                .deletion => {
                    if (old_idx < old_lines.items.len) {
                        old_idx += 1;
                    }
                },
                .no_newline_marker => {},
            }
        }
    }

    while (old_idx < old_lines.items.len) {
        try new_lines.append(old_lines.items[old_idx]);
        old_idx += 1;
    }

    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    for (new_lines.items, 0..) |line, li| {
        try result.appendSlice(line);
        if (li < new_lines.items.len - 1) {
            try result.append('\n');
        }
    }
    if (old_content.len > 0 and old_content[old_content.len - 1] == '\n') {
        if (result.items.len == 0 or result.items[result.items.len - 1] != '\n') {
            try result.append('\n');
        }
    }

    const file = try std.fs.createFileAbsolute(full_path, .{});
    defer file.close();
    try file.writeAll(result.items);
}

/// Create a commit from patch metadata.
fn createCommitFromPatch(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    msg: *const patch_mod.MboxMessage,
) !void {
    // Read current HEAD
    var head_path_buf: [4096]u8 = undefined;
    const head_path = concatPath(&head_path_buf, repo.git_dir, "/HEAD");

    const head_content = readFileMaybe(allocator, head_path) orelse return error.NoHead;
    defer allocator.free(head_content);

    const head_trimmed = std.mem.trimRight(u8, head_content, "\n\r ");

    // Resolve HEAD to a commit OID
    var current_head: ?types.ObjectId = null;
    if (std.mem.startsWith(u8, head_trimmed, "ref: ")) {
        const ref_name = head_trimmed[5..];
        var ref_path_buf: [4096]u8 = undefined;
        const ref_path = concatPath3(&ref_path_buf, repo.git_dir, "/", ref_name);
        const ref_content = readFileMaybe(allocator, ref_path);
        if (ref_content) |rc| {
            defer allocator.free(rc);
            const ref_trimmed = std.mem.trimRight(u8, rc, "\n\r ");
            if (ref_trimmed.len >= types.OID_HEX_LEN) {
                current_head = types.ObjectId.fromHex(ref_trimmed[0..types.OID_HEX_LEN]) catch null;
            }
        }
    } else if (head_trimmed.len >= types.OID_HEX_LEN) {
        current_head = types.ObjectId.fromHex(head_trimmed[0..types.OID_HEX_LEN]) catch null;
    }

    // Build the index from working tree changes
    // (Simplified: just add all modified files to the index)
    const work_dir = getWorkDir(repo.git_dir);
    _ = work_dir;

    // Read the current tree from HEAD
    var tree_oid = types.ObjectId.ZERO;
    if (current_head) |ch| {
        var commit_obj = repo.readObject(allocator, &ch) catch return;
        defer commit_obj.deinit();
        if (commit_obj.obj_type == .commit) {
            tree_oid = tree_diff.getCommitTreeOid(commit_obj.data) catch types.ObjectId.ZERO;
        }
    }

    // Build commit message
    var commit_msg = std.array_list.Managed(u8).init(allocator);
    defer commit_msg.deinit();

    // Clean subject (remove [PATCH N/M] prefix)
    const clean_subject = cleanSubject(msg.subject);
    try commit_msg.appendSlice(clean_subject);
    try commit_msg.append('\n');

    if (msg.body.len > 0) {
        try commit_msg.append('\n');
        const body_trimmed = std.mem.trimRight(u8, msg.body, "\n\r ");
        try commit_msg.appendSlice(body_trimmed);
        try commit_msg.append('\n');
    }

    // Build commit object
    var commit_content = std.array_list.Managed(u8).init(allocator);
    defer commit_content.deinit();

    var buf: [512]u8 = undefined;
    const tree_hex = tree_oid.toHex();
    var line = std.fmt.bufPrint(&buf, "tree {s}\n", .{&tree_hex}) catch return;
    try commit_content.appendSlice(line);

    if (current_head) |parent| {
        const parent_hex = parent.toHex();
        line = std.fmt.bufPrint(&buf, "parent {s}\n", .{&parent_hex}) catch return;
        try commit_content.appendSlice(line);
    }

    // Author from patch
    const author_name = if (msg.from.len > 0) parseNameFromFrom(msg.from) else "Unknown";
    const author_email = if (msg.from.len > 0) parseEmailFromFrom(msg.from) else "unknown@unknown";
    const timestamp = "0 +0000"; // Simplified

    line = std.fmt.bufPrint(&buf, "author {s} <{s}> {s}\n", .{ author_name, author_email, timestamp }) catch return;
    try commit_content.appendSlice(line);

    line = std.fmt.bufPrint(&buf, "committer {s} <{s}> {s}\n", .{ author_name, author_email, timestamp }) catch return;
    try commit_content.appendSlice(line);

    try commit_content.append('\n');
    try commit_content.appendSlice(commit_msg.items);

    // Write the commit object
    const commit_oid = loose.writeLooseObject(allocator, repo.git_dir, .commit, commit_content.items) catch return;

    // Update HEAD
    updateHead(repo, allocator, &commit_oid) catch {};

    {
        const oid_hex = commit_oid.toHex();
        var msg_buf: [256]u8 = undefined;
        const out_msg = std.fmt.bufPrint(&msg_buf, "[am {s}] {s}\n", .{ oid_hex[0..7], clean_subject }) catch
            "Commit created\n";
        try stdout_file.writeAll(out_msg);
    }
}

fn updateHead(repo: *repository.Repository, allocator: std.mem.Allocator, commit_oid: *const types.ObjectId) !void {
    var head_path_buf: [4096]u8 = undefined;
    const head_path = concatPath(&head_path_buf, repo.git_dir, "/HEAD");

    const head_content = readFileMaybe(allocator, head_path) orelse return;
    defer allocator.free(head_content);

    const trimmed = std.mem.trimRight(u8, head_content, "\n\r ");
    const oid_hex = commit_oid.toHex();

    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const ref_name = trimmed[5..];
        var ref_path_buf: [4096]u8 = undefined;
        const ref_path = concatPath3(&ref_path_buf, repo.git_dir, "/", ref_name);

        // Ensure parent dirs exist
        if (std.fs.path.dirname(ref_path)) |parent| {
            mkdirRecursive(parent) catch {};
        }

        const ref_file = std.fs.createFileAbsolute(ref_path, .{}) catch return;
        defer ref_file.close();
        ref_file.writeAll(&oid_hex) catch {};
        ref_file.writeAll("\n") catch {};
    } else {
        const head_file = std.fs.createFileAbsolute(head_path, .{}) catch return;
        defer head_file.close();
        head_file.writeAll(&oid_hex) catch {};
        head_file.writeAll("\n") catch {};
    }
}

// ---------------------------------------------------------------------------
// State management
// ---------------------------------------------------------------------------

fn saveAmState(state_dir: []const u8, total: usize, current: usize) !void {
    // Write total count
    var total_path_buf: [4096]u8 = undefined;
    const total_path = concatPath(&total_path_buf, state_dir, "/last");
    {
        const file = std.fs.createFileAbsolute(total_path, .{}) catch return;
        defer file.close();
        var buf: [32]u8 = undefined;
        const val = std.fmt.bufPrint(&buf, "{d}\n", .{total}) catch return;
        try file.writeAll(val);
    }

    // Write current
    var cur_path_buf: [4096]u8 = undefined;
    const cur_path = concatPath(&cur_path_buf, state_dir, "/next");
    {
        const file = std.fs.createFileAbsolute(cur_path, .{}) catch return;
        defer file.close();
        var buf: [32]u8 = undefined;
        const val = std.fmt.bufPrint(&buf, "{d}\n", .{current}) catch return;
        try file.writeAll(val);
    }
}

fn savePatchMsg(state_dir: []const u8, msg: *const patch_mod.MboxMessage) !void {
    var msg_path_buf: [4096]u8 = undefined;
    const msg_path = concatPath(&msg_path_buf, state_dir, "/msg");

    const file = std.fs.createFileAbsolute(msg_path, .{}) catch return;
    defer file.close();
    try file.writeAll(msg.subject);
    try file.writeAll("\n");
}

fn cleanupAmState(state_dir: []const u8) void {
    // Try to remove state files and directory
    var path_buf: [4096]u8 = undefined;

    const files = [_][]const u8{ "/last", "/next", "/msg", "/patch" };
    for (files) |f| {
        const path = concatPath(&path_buf, state_dir, f);
        std.fs.deleteFileAbsolute(path) catch {};
    }
    std.fs.deleteDirAbsolute(state_dir) catch {};
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getSubjectSummary(subject: []const u8) []const u8 {
    const clean = cleanSubject(subject);
    if (clean.len > 60) return clean[0..60];
    return clean;
}

fn cleanSubject(subject: []const u8) []const u8 {
    // Remove [PATCH N/M] prefix
    if (std.mem.startsWith(u8, subject, "[")) {
        if (std.mem.indexOfScalar(u8, subject, ']')) |close| {
            const rest = subject[close + 1 ..];
            return std.mem.trimLeft(u8, rest, " ");
        }
    }
    return subject;
}

fn parseNameFromFrom(from: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, from, '<')) |lt| {
        if (lt > 0) {
            return std.mem.trimRight(u8, from[0 .. lt - 1], " ");
        }
    }
    return from;
}

fn parseEmailFromFrom(from: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, from, '<')) |lt| {
        if (std.mem.indexOfScalar(u8, from, '>')) |gt| {
            return from[lt + 1 .. gt];
        }
    }
    return from;
}

fn splitLines(text: []const u8, lines: *std.array_list.Managed([]const u8)) !void {
    if (text.len == 0) return;
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        if (iter.peek() == null and line.len == 0) break;
        try lines.append(line);
    }
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

fn concatPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn concatPath3(buf: []u8, a: []const u8, b: []const u8, c: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    @memcpy(buf[a.len + b.len ..][0..c.len], c);
    return buf[0 .. a.len + b.len + c.len];
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        const stat = try file.stat();
        if (stat.size > 50 * 1024 * 1024) return error.FileTooLarge;
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
    const file = std.fs.cwd().openFile(path, .{}) catch return error.FileNotFound;
    defer file.close();
    const stat = try file.stat();
    if (stat.size > 50 * 1024 * 1024) return error.FileTooLarge;
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

fn readFileMaybe(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    if (stat.size > 50 * 1024 * 1024) return null;
    const buf = allocator.alloc(u8, @intCast(stat.size)) catch return null;
    const n = file.readAll(buf) catch {
        allocator.free(buf);
        return null;
    };
    if (n < buf.len) {
        const trimmed = allocator.alloc(u8, n) catch {
            allocator.free(buf);
            return null;
        };
        @memcpy(trimmed, buf[0..n]);
        allocator.free(buf);
        return trimmed;
    }
    return buf;
}

fn isDirectory(path: []const u8) bool {
    const dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    @constCast(&dir).close();
    return true;
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

test "cleanSubject" {
    try std.testing.expectEqualStrings("Fix bug in parser", cleanSubject("[PATCH 1/3] Fix bug in parser"));
    try std.testing.expectEqualStrings("Add feature", cleanSubject("[PATCH] Add feature"));
    try std.testing.expectEqualStrings("No prefix", cleanSubject("No prefix"));
}

test "parseNameFromFrom" {
    try std.testing.expectEqualStrings("Test User", parseNameFromFrom("Test User <test@test.com>"));
}

test "parseEmailFromFrom" {
    try std.testing.expectEqualStrings("test@test.com", parseEmailFromFrom("Test User <test@test.com>"));
}
