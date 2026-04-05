const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const hash_mod = @import("hash.zig");
const tree_diff = @import("tree_diff.zig");

// ANSI color codes
const COLOR_RED = "\x1b[31m";
const COLOR_GREEN = "\x1b[32m";
const COLOR_CYAN = "\x1b[36m";
const COLOR_BOLD = "\x1b[1m";
const COLOR_RESET = "\x1b[0m";

/// Type of a diff line.
pub const DiffLineKind = enum {
    context,
    addition,
    deletion,
};

/// A single line in a diff hunk.
pub const DiffLine = struct {
    kind: DiffLineKind,
    content: []const u8,
};

/// A contiguous hunk of changes.
pub const DiffHunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    lines: std.array_list.Managed(DiffLine),

    pub fn deinit(self: *DiffHunk) void {
        self.lines.deinit();
    }
};

/// Result of a diff operation. Owns all hunk memory.
pub const DiffResult = struct {
    hunks: std.array_list.Managed(DiffHunk),

    pub fn deinit(self: *DiffResult) void {
        for (self.hunks.items) |*h| {
            h.deinit();
        }
        self.hunks.deinit();
    }
};

/// Mode of the diff command.
pub const DiffMode = enum {
    /// Working tree vs index
    worktree_vs_index,
    /// Index vs HEAD (--cached / --staged)
    index_vs_head,
    /// Working tree vs a specific commit
    worktree_vs_commit,
};

/// Run the diff command and write output to stdout.
pub fn runDiff(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    mode: DiffMode,
    commit_ref: ?[]const u8,
    stdout: std.fs.File,
) !void {
    switch (mode) {
        .worktree_vs_index => try diffWorktreeVsIndex(repo, allocator, stdout),
        .index_vs_head => try diffIndexVsHead(repo, allocator, stdout),
        .worktree_vs_commit => try diffWorktreeVsCommit(repo, allocator, commit_ref.?, stdout),
    }
}

// ---------------------------------------------------------------------------
// Working tree vs index
// ---------------------------------------------------------------------------

fn diffWorktreeVsIndex(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
) !void {
    const work_dir = getWorkDir(repo.git_dir);

    // Load the index
    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPathBuf(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    // For each index entry, compare with working tree file
    for (idx.entries.items) |*entry| {
        var file_path_buf: [4096]u8 = undefined;
        const file_path = buildPathBuf2(&file_path_buf, work_dir, "/", entry.name);

        const wt_content = readFileContentsMaybe(allocator, file_path);
        defer if (wt_content) |c| allocator.free(c);

        if (wt_content == null) {
            // File deleted from working tree
            const old_content = readBlobContent(repo, allocator, &entry.oid);
            defer if (old_content) |c| allocator.free(c);
            const old_data = old_content orelse "";

            try writeUnifiedDiff(allocator, stdout, entry.name, old_data, "", true, false);
            continue;
        }

        const wt_data = wt_content.?;

        // Compute the blob OID for working tree content
        const wt_oid = computeBlobOid(wt_data);
        if (wt_oid.eql(&entry.oid)) continue; // No change

        // Read the index blob content
        const old_content = readBlobContent(repo, allocator, &entry.oid);
        defer if (old_content) |c| allocator.free(c);
        const old_data = old_content orelse "";

        try writeUnifiedDiff(allocator, stdout, entry.name, old_data, wt_data, false, false);
    }
}

// ---------------------------------------------------------------------------
// Index vs HEAD (--cached)
// ---------------------------------------------------------------------------

fn diffIndexVsHead(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
) !void {
    // Load the index
    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPathBuf(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    // Load HEAD tree
    var head_entries = std.StringHashMap(types.ObjectId).init(allocator);
    defer {
        var ki = head_entries.keyIterator();
        while (ki.next()) |key| {
            allocator.free(key.*);
        }
        head_entries.deinit();
    }
    loadHeadTree(repo, allocator, &head_entries) catch {};

    // Check each index entry against HEAD
    for (idx.entries.items) |*entry| {
        if (head_entries.get(entry.name)) |head_oid| {
            if (!head_oid.eql(&entry.oid)) {
                // Modified
                const old_content = readBlobContent(repo, allocator, &head_oid);
                defer if (old_content) |c| allocator.free(c);
                const new_content = readBlobContent(repo, allocator, &entry.oid);
                defer if (new_content) |c| allocator.free(c);

                try writeUnifiedDiff(
                    allocator,
                    stdout,
                    entry.name,
                    old_content orelse "",
                    new_content orelse "",
                    false,
                    false,
                );
            }
            // Remove so we can detect deletions
            if (head_entries.fetchRemove(entry.name)) |kv| {
                allocator.free(kv.key);
            }
        } else {
            // New file
            const new_content = readBlobContent(repo, allocator, &entry.oid);
            defer if (new_content) |c| allocator.free(c);

            try writeUnifiedDiff(
                allocator,
                stdout,
                entry.name,
                "",
                new_content orelse "",
                false,
                true,
            );
        }
    }

    // Files deleted from index but present in HEAD
    var head_iter = head_entries.iterator();
    while (head_iter.next()) |kv| {
        const old_content = readBlobContent(repo, allocator, &kv.value_ptr.*);
        defer if (old_content) |c| allocator.free(c);

        try writeUnifiedDiff(
            allocator,
            stdout,
            kv.key_ptr.*,
            old_content orelse "",
            "",
            true,
            false,
        );
    }
}

// ---------------------------------------------------------------------------
// Working tree vs a specific commit
// ---------------------------------------------------------------------------

fn diffWorktreeVsCommit(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    commit_ref: []const u8,
    stdout: std.fs.File,
) !void {
    const work_dir = getWorkDir(repo.git_dir);

    // Resolve the commit
    const commit_oid = try repo.resolveRef(allocator, commit_ref);
    var commit_obj = try repo.readObject(allocator, &commit_oid);
    defer commit_obj.deinit();
    if (commit_obj.obj_type != .commit) return error.NotACommit;

    const tree_oid = try tree_diff.getCommitTreeOid(commit_obj.data);

    // Load the commit's tree as flat map
    var commit_entries = std.StringHashMap(types.ObjectId).init(allocator);
    defer {
        var ki = commit_entries.keyIterator();
        while (ki.next()) |key| {
            allocator.free(key.*);
        }
        commit_entries.deinit();
    }
    try walkTree(repo, allocator, &tree_oid, &commit_entries, "");

    // Compare with working tree
    // First, iterate commit entries and compare with working tree files
    var iter = commit_entries.iterator();
    while (iter.next()) |kv| {
        const path = kv.key_ptr.*;
        const old_oid = kv.value_ptr.*;

        var file_path_buf: [4096]u8 = undefined;
        const file_path = buildPathBuf2(&file_path_buf, work_dir, "/", path);

        const wt_content = readFileContentsMaybe(allocator, file_path);
        defer if (wt_content) |c| allocator.free(c);

        if (wt_content == null) {
            // Deleted
            const old_content = readBlobContent(repo, allocator, &old_oid);
            defer if (old_content) |c| allocator.free(c);
            try writeUnifiedDiff(allocator, stdout, path, old_content orelse "", "", true, false);
            continue;
        }

        const wt_data = wt_content.?;
        const wt_oid = computeBlobOid(wt_data);
        if (wt_oid.eql(&old_oid)) continue;

        const old_content = readBlobContent(repo, allocator, &old_oid);
        defer if (old_content) |c| allocator.free(c);
        try writeUnifiedDiff(allocator, stdout, path, old_content orelse "", wt_data, false, false);
    }

    // TODO: also find files in working tree that are not in the commit (new files).
    // For simplicity, this is omitted here; a full implementation would scan the working tree.
}

// ---------------------------------------------------------------------------
// Myers diff algorithm
// ---------------------------------------------------------------------------

/// Compute the diff hunks between two text contents split into lines.
pub fn diffLines(
    allocator: std.mem.Allocator,
    old_text: []const u8,
    new_text: []const u8,
) !DiffResult {
    // Split into lines
    var old_lines_list = std.array_list.Managed([]const u8).init(allocator);
    defer old_lines_list.deinit();
    var new_lines_list = std.array_list.Managed([]const u8).init(allocator);
    defer new_lines_list.deinit();

    try splitLines(old_text, &old_lines_list);
    try splitLines(new_text, &new_lines_list);

    const old_lines = old_lines_list.items;
    const new_lines = new_lines_list.items;

    // Compute edit script using Myers algorithm
    const edit_script = try myersDiff(allocator, old_lines, new_lines);
    defer allocator.free(edit_script);

    // Convert edit script to hunks with context
    return buildHunks(allocator, old_lines, new_lines, edit_script);
}

/// Edit operation type.
const EditOp = enum {
    equal,
    insert,
    delete,
};

/// Compute edit script using the Myers diff algorithm.
/// Returns a list of EditOp values.
fn myersDiff(
    allocator: std.mem.Allocator,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
) ![]EditOp {
    const n: isize = @intCast(old_lines.len);
    const m: isize = @intCast(new_lines.len);
    const max_d: isize = n + m;

    if (max_d == 0) {
        return allocator.alloc(EditOp, 0);
    }

    // V array: maps k -> x furthest reaching point
    // k ranges from -max_d to max_d, so we need 2*max_d+1 entries.
    // We store trace for backtracking.
    const v_size: usize = @intCast(2 * max_d + 1);
    const v_offset: usize = @intCast(max_d);

    // We need to save V for each d step for backtracking
    var trace = std.array_list.Managed([]isize).init(allocator);
    defer {
        for (trace.items) |t| allocator.free(t);
        trace.deinit();
    }

    var v = try allocator.alloc(isize, v_size);
    defer allocator.free(v);
    @memset(v, 0);
    v[v_offset + 1] = 0; // v[1] = 0

    var found = false;
    var final_d: isize = 0;

    var d: isize = 0;
    while (d <= max_d) : (d += 1) {
        // Save current V
        const v_copy = try allocator.alloc(isize, v_size);
        @memcpy(v_copy, v);
        try trace.append(v_copy);

        var k: isize = -d;
        while (k <= d) : (k += 2) {
            const k_idx: usize = @intCast(@as(isize, @intCast(v_offset)) + k);

            var x: isize = undefined;
            if (k == -d or (k != d and v[k_idx - 1] < v[k_idx + 1])) {
                x = v[k_idx + 1]; // move down
            } else {
                x = v[k_idx - 1] + 1; // move right
            }
            var y: isize = x - k;

            // Follow diagonal (equal lines)
            while (x < n and y < m) {
                const xu: usize = @intCast(x);
                const yu: usize = @intCast(y);
                if (std.mem.eql(u8, old_lines[xu], new_lines[yu])) {
                    x += 1;
                    y += 1;
                } else {
                    break;
                }
            }

            v[k_idx] = x;

            if (x >= n and y >= m) {
                found = true;
                final_d = d;
                break;
            }
        }
        if (found) break;
    }

    // Backtrack to build edit script
    var edits = std.array_list.Managed(EditOp).init(allocator);
    defer edits.deinit();

    var bx: isize = n;
    var by: isize = m;

    var bd: isize = final_d;
    while (bd > 0) : (bd -= 1) {
        const saved_v = trace.items[@intCast(bd)];
        const bk: isize = bx - by;

        const bk_idx: usize = @intCast(@as(isize, @intCast(v_offset)) + bk);

        var prev_k: isize = undefined;
        var prev_x: isize = undefined;
        var prev_y: isize = undefined;

        if (bk == -bd or (bk != bd and saved_v[bk_idx - 1] < saved_v[bk_idx + 1])) {
            prev_k = bk + 1;
        } else {
            prev_k = bk - 1;
        }

        const prev_k_idx: usize = @intCast(@as(isize, @intCast(v_offset)) + prev_k);
        const prev_saved = trace.items[@intCast(bd - 1)];
        prev_x = prev_saved[prev_k_idx];
        prev_y = prev_x - prev_k;

        // Add diagonal matches (equal)
        while (bx > prev_x + @as(isize, if (prev_k == bk - 1) 1 else 0) and by > prev_y + @as(isize, if (prev_k == bk + 1) 1 else 0)) {
            bx -= 1;
            by -= 1;
            try edits.append(.equal);
        }

        if (bd > 0) {
            if (prev_k == bk - 1) {
                // We moved right -> delete
                bx -= 1;
                try edits.append(.delete);
            } else {
                // We moved down -> insert
                by -= 1;
                try edits.append(.insert);
            }
        }
    }

    // Add remaining diagonal at the start
    while (bx > 0 and by > 0) {
        bx -= 1;
        by -= 1;
        try edits.append(.equal);
    }

    // Reverse the edit script
    const result = try allocator.alloc(EditOp, edits.items.len);
    for (edits.items, 0..) |_, i| {
        result[i] = edits.items[edits.items.len - 1 - i];
    }

    return result;
}

/// Build hunks from the edit script with context lines.
fn buildHunks(
    allocator: std.mem.Allocator,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    edit_script: []const EditOp,
) !DiffResult {
    var result = DiffResult{
        .hunks = std.array_list.Managed(DiffHunk).init(allocator),
    };
    errdefer result.deinit();

    const context_lines: usize = 3;

    // Convert edit script to a list of change regions
    var changes = std.array_list.Managed(ChangeRegion).init(allocator);
    defer changes.deinit();

    var oi: usize = 0; // position in old
    var ni: usize = 0; // position in new
    var region_start_oi: usize = 0;
    var region_start_ni: usize = 0;
    var in_change = false;

    for (edit_script) |op| {
        switch (op) {
            .equal => {
                if (in_change) {
                    try changes.append(.{
                        .old_start = region_start_oi,
                        .old_end = oi,
                        .new_start = region_start_ni,
                        .new_end = ni,
                    });
                    in_change = false;
                }
                oi += 1;
                ni += 1;
            },
            .delete => {
                if (!in_change) {
                    region_start_oi = oi;
                    region_start_ni = ni;
                    in_change = true;
                }
                oi += 1;
            },
            .insert => {
                if (!in_change) {
                    region_start_oi = oi;
                    region_start_ni = ni;
                    in_change = true;
                }
                ni += 1;
            },
        }
    }
    if (in_change) {
        try changes.append(.{
            .old_start = region_start_oi,
            .old_end = oi,
            .new_start = region_start_ni,
            .new_end = ni,
        });
    }

    if (changes.items.len == 0) return result;

    // Group change regions into hunks (merge regions within 2*context lines)
    var hunk_groups = std.array_list.Managed(HunkGroup).init(allocator);
    defer hunk_groups.deinit();

    var current_group = HunkGroup{
        .first_change = 0,
        .last_change = 0,
    };

    for (changes.items, 0..) |_, ci| {
        if (ci == 0) {
            current_group.first_change = 0;
            current_group.last_change = 0;
            continue;
        }
        const prev = changes.items[ci - 1];
        const curr = changes.items[ci];

        // If the gap between previous change end and current change start
        // is small enough, merge into same hunk
        const gap = if (curr.old_start > prev.old_end) curr.old_start - prev.old_end else 0;
        if (gap <= 2 * context_lines) {
            current_group.last_change = ci;
        } else {
            try hunk_groups.append(current_group);
            current_group = HunkGroup{
                .first_change = ci,
                .last_change = ci,
            };
        }
    }
    try hunk_groups.append(current_group);

    // Build each hunk
    for (hunk_groups.items) |group| {
        const first = changes.items[group.first_change];
        const last = changes.items[group.last_change];

        // Compute hunk range with context
        const ctx_old_start = if (first.old_start > context_lines) first.old_start - context_lines else 0;
        const ctx_old_end = @min(last.old_end + context_lines, old_lines.len);
        const ctx_new_start = if (first.new_start > context_lines) first.new_start - context_lines else 0;
        const ctx_new_end = @min(last.new_end + context_lines, new_lines.len);

        var hunk = DiffHunk{
            .old_start = ctx_old_start + 1, // 1-based
            .old_count = ctx_old_end - ctx_old_start,
            .new_start = ctx_new_start + 1, // 1-based
            .new_count = ctx_new_end - ctx_new_start,
            .lines = std.array_list.Managed(DiffLine).init(allocator),
        };
        errdefer hunk.deinit();

        // Replay the edit script for this hunk range
        var ho: usize = 0;
        var hn: usize = 0;
        for (edit_script) |op| {
            switch (op) {
                .equal => {
                    if (ho >= ctx_old_start and ho < ctx_old_end) {
                        try hunk.lines.append(.{
                            .kind = .context,
                            .content = old_lines[ho],
                        });
                    }
                    ho += 1;
                    hn += 1;
                },
                .delete => {
                    if (ho >= ctx_old_start and ho < ctx_old_end) {
                        try hunk.lines.append(.{
                            .kind = .deletion,
                            .content = old_lines[ho],
                        });
                    }
                    ho += 1;
                },
                .insert => {
                    if (hn >= ctx_new_start and hn < ctx_new_end) {
                        try hunk.lines.append(.{
                            .kind = .addition,
                            .content = new_lines[hn],
                        });
                    }
                    hn += 1;
                },
            }
        }

        try result.hunks.append(hunk);
    }

    return result;
}

const ChangeRegion = struct {
    old_start: usize,
    old_end: usize,
    new_start: usize,
    new_end: usize,
};

const HunkGroup = struct {
    first_change: usize,
    last_change: usize,
};

// ---------------------------------------------------------------------------
// Unified diff output
// ---------------------------------------------------------------------------

/// Write unified diff output for a single file.
fn writeUnifiedDiff(
    allocator: std.mem.Allocator,
    stdout: std.fs.File,
    path: []const u8,
    old_content: []const u8,
    new_content: []const u8,
    is_delete: bool,
    is_new: bool,
) !void {
    // Check if binary
    if (isBinary(old_content) or isBinary(new_content)) {
        try writeBinaryDiff(stdout, path);
        return;
    }

    var diff_result = try diffLines(allocator, old_content, new_content);
    defer diff_result.deinit();

    if (diff_result.hunks.items.len == 0) return;

    // Write header
    var buf: [4096]u8 = undefined;

    // diff --git a/file b/file
    var msg = std.fmt.bufPrint(&buf, "{s}diff --git a/{s} b/{s}{s}\n", .{ COLOR_BOLD, path, path, COLOR_RESET }) catch return;
    try stdout.writeAll(msg);

    if (is_new) {
        try stdout.writeAll("new file mode 100644\n");
    }
    if (is_delete) {
        try stdout.writeAll("deleted file mode 100644\n");
    }

    // --- a/file
    if (is_new) {
        try stdout.writeAll("--- /dev/null\n");
    } else {
        msg = std.fmt.bufPrint(&buf, "--- a/{s}\n", .{path}) catch return;
        try stdout.writeAll(msg);
    }

    // +++ b/file
    if (is_delete) {
        try stdout.writeAll("+++ /dev/null\n");
    } else {
        msg = std.fmt.bufPrint(&buf, "+++ b/{s}\n", .{path}) catch return;
        try stdout.writeAll(msg);
    }

    // Hunks
    for (diff_result.hunks.items) |*hunk| {
        // @@ -old_start,old_count +new_start,new_count @@
        msg = std.fmt.bufPrint(&buf, "{s}@@ -{d},{d} +{d},{d} @@{s}\n", .{
            COLOR_CYAN,
            hunk.old_start,
            hunk.old_count,
            hunk.new_start,
            hunk.new_count,
            COLOR_RESET,
        }) catch continue;
        try stdout.writeAll(msg);

        for (hunk.lines.items) |*line| {
            switch (line.kind) {
                .context => {
                    try stdout.writeAll(" ");
                    try stdout.writeAll(line.content);
                    try stdout.writeAll("\n");
                },
                .deletion => {
                    try stdout.writeAll(COLOR_RED);
                    try stdout.writeAll("-");
                    try stdout.writeAll(line.content);
                    try stdout.writeAll(COLOR_RESET);
                    try stdout.writeAll("\n");
                },
                .addition => {
                    try stdout.writeAll(COLOR_GREEN);
                    try stdout.writeAll("+");
                    try stdout.writeAll(line.content);
                    try stdout.writeAll(COLOR_RESET);
                    try stdout.writeAll("\n");
                },
            }
        }
    }
}

/// Write a binary file diff notice.
fn writeBinaryDiff(stdout: std.fs.File, path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var msg = std.fmt.bufPrint(&buf, "{s}diff --git a/{s} b/{s}{s}\n", .{ COLOR_BOLD, path, path, COLOR_RESET }) catch return;
    try stdout.writeAll(msg);
    msg = std.fmt.bufPrint(&buf, "Binary files a/{s} and b/{s} differ\n", .{ path, path }) catch return;
    try stdout.writeAll(msg);
}

/// Write unified diff for tree-level changes (used by show).
pub fn writeTreeDiff(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    changes: []const tree_diff.TreeChange,
    stdout: std.fs.File,
) !void {
    for (changes) |*change| {
        const old_content = if (change.old_oid) |oid| readBlobContent(repo, allocator, &oid) else null;
        defer if (old_content) |c| allocator.free(c);

        const new_content = if (change.new_oid) |oid| readBlobContent(repo, allocator, &oid) else null;
        defer if (new_content) |c| allocator.free(c);

        try writeUnifiedDiff(
            allocator,
            stdout,
            change.path,
            old_content orelse "",
            new_content orelse "",
            change.kind == .deleted,
            change.kind == .added,
        );
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Split text into lines (without trailing newline characters).
fn splitLines(text: []const u8, lines: *std.array_list.Managed([]const u8)) !void {
    if (text.len == 0) return;
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        // Don't add an empty trailing line if text ends with '\n'
        if (iter.peek() == null and line.len == 0) break;
        try lines.append(line);
    }
}

/// Check if content appears to be binary.
fn isBinary(content: []const u8) bool {
    const check_len = @min(content.len, 8000);
    for (content[0..check_len]) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

/// Compute the SHA-1 OID of blob content.
fn computeBlobOid(data: []const u8) types.ObjectId {
    var header_buf: [64]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    hwriter.writeAll("blob ") catch return types.ObjectId.ZERO;
    hwriter.print("{d}", .{data.len}) catch return types.ObjectId.ZERO;
    hwriter.writeByte(0) catch return types.ObjectId.ZERO;
    const header = header_buf[0..hstream.pos];

    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    return types.ObjectId{ .bytes = hasher.finalResult() };
}

/// Read the content of a blob object. Returns null on failure.
fn readBlobContent(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    oid: *const types.ObjectId,
) ?[]u8 {
    var obj = repo.readObject(allocator, oid) catch return null;
    if (obj.obj_type != .blob) {
        obj.deinit();
        return null;
    }
    // obj.data is owned by the Object; we need to dupe it
    const data = allocator.alloc(u8, obj.data.len) catch {
        obj.deinit();
        return null;
    };
    @memcpy(data, obj.data);
    obj.deinit();
    return data;
}

/// Read file contents from an absolute path. Returns null if the file doesn't exist.
fn readFileContentsMaybe(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    if (stat.size > 10 * 1024 * 1024) return null; // Skip very large files
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

/// Load the HEAD tree as a flat map.
fn loadHeadTree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    entries: *std.StringHashMap(types.ObjectId),
) !void {
    var head_path_buf: [4096]u8 = undefined;
    const head_path = buildPathBuf(&head_path_buf, repo.git_dir, "/HEAD");

    const head_content = readFileContentsMaybe(allocator, head_path) orelse return error.NoHead;
    defer allocator.free(head_content);

    const trimmed = std.mem.trimRight(u8, head_content, "\n\r ");
    var commit_oid: types.ObjectId = undefined;

    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const ref_name = trimmed[5..];
        var ref_path_buf: [4096]u8 = undefined;
        const ref_path = buildPathBuf2(&ref_path_buf, repo.git_dir, "/", ref_name);

        const ref_content = readFileContentsMaybe(allocator, ref_path) orelse return error.RefNotFound;
        defer allocator.free(ref_content);
        const ref_trimmed = std.mem.trimRight(u8, ref_content, "\n\r ");
        if (ref_trimmed.len < types.OID_HEX_LEN) return error.InvalidRef;
        commit_oid = try types.ObjectId.fromHex(ref_trimmed[0..types.OID_HEX_LEN]);
    } else {
        if (trimmed.len < types.OID_HEX_LEN) return error.InvalidRef;
        commit_oid = try types.ObjectId.fromHex(trimmed[0..types.OID_HEX_LEN]);
    }

    var commit_obj = try repo.readObject(allocator, &commit_oid);
    defer commit_obj.deinit();
    if (commit_obj.obj_type != .commit) return error.NotACommit;

    const tree_oid = try tree_diff.getCommitTreeOid(commit_obj.data);
    try walkTree(repo, allocator, &tree_oid, entries, "");
}

/// Recursively walk a tree object and populate a flat entry map.
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
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse return;
        const mode = data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, data, space_pos + 1, 0) orelse return;
        const name = data[space_pos + 1 .. null_pos];

        if (null_pos + 1 + types.OID_RAW_LEN > data.len) return;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, data[null_pos + 1 ..][0..types.OID_RAW_LEN]);
        pos = null_pos + 1 + types.OID_RAW_LEN;

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
            try walkTree(repo, allocator, &oid, entries, full_path_slice);
        } else {
            const owned_path = try allocator.alloc(u8, full_path_slice.len);
            @memcpy(owned_path, full_path_slice);
            try entries.put(owned_path, oid);
        }
    }
}

fn buildPathBuf(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn buildPathBuf2(buf: []u8, a: []const u8, b: []const u8, c: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    @memcpy(buf[a.len + b.len ..][0..c.len], c);
    return buf[0 .. a.len + b.len + c.len];
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

test "splitLines basic" {
    var lines = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer lines.deinit();

    try splitLines("hello\nworld\n", &lines);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("hello", lines.items[0]);
    try std.testing.expectEqualStrings("world", lines.items[1]);
}

test "splitLines empty" {
    var lines = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer lines.deinit();

    try splitLines("", &lines);
    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
}

test "isBinary" {
    try std.testing.expect(!isBinary("hello world"));
    try std.testing.expect(isBinary("hello\x00world"));
}
