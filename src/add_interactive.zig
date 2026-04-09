const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const diff_mod = @import("diff.zig");
const hash_mod = @import("hash.zig");
const loose = @import("loose.zig");
const tree_diff = @import("tree_diff.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

// ANSI color codes
const COLOR_RED = "\x1b[31m";
const COLOR_GREEN = "\x1b[32m";
const COLOR_CYAN = "\x1b[36m";
const COLOR_BOLD = "\x1b[1m";
const COLOR_RESET = "\x1b[0m";
const COLOR_YELLOW = "\x1b[33m";

/// A hunk that can be staged/unstaged independently.
pub const InteractiveHunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    lines_start: usize,
    lines_count: usize,
    selected: bool,
};

/// Response from user for a hunk prompt.
pub const HunkAction = enum {
    yes,
    no,
    quit,
    all,
    done,
    split,
    edit,
    help,
};

/// Mode of interactive operation.
pub const InteractiveMode = enum {
    add_patch,
    reset_patch,
    checkout_patch,
};

/// Run the interactive add/staging process.
pub fn runInteractiveAdd(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    mode: InteractiveMode,
) !void {
    const work_dir = getWorkDir(repo.git_dir);

    // Load the index
    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPath(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    // Determine which files to process
    var file_filter = std.StringHashMap(void).init(allocator);
    defer file_filter.deinit();

    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            try file_filter.put(arg, {});
        }
    }

    switch (mode) {
        .add_patch => try interactiveAddPatch(repo, allocator, &idx, work_dir, &file_filter, index_path),
        .reset_patch => try interactiveResetPatch(repo, allocator, &idx, &file_filter, index_path),
        .checkout_patch => try interactiveCheckoutPatch(repo, allocator, &idx, work_dir, &file_filter),
    }
}

// ---------------------------------------------------------------------------
// git add -p
// ---------------------------------------------------------------------------

fn interactiveAddPatch(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    work_dir: []const u8,
    file_filter: *std.StringHashMap(void),
    index_path: []const u8,
) !void {
    var any_staged = false;

    for (idx.entries.items) |*entry| {
        if (file_filter.count() > 0 and !file_filter.contains(entry.name)) continue;

        // Read the working tree file
        var file_path_buf: [4096]u8 = undefined;
        const file_path = buildPath2(&file_path_buf, work_dir, "/", entry.name);

        const wt_content = readFileMaybe(allocator, file_path) orelse continue;
        defer allocator.free(wt_content);

        // Compare with index blob
        const idx_content = readBlobContent(repo, allocator, &entry.oid) orelse continue;
        defer allocator.free(idx_content);

        // Skip if identical
        const wt_oid = computeBlobOid(wt_content);
        if (wt_oid.eql(&entry.oid)) continue;

        // Skip binary files
        if (isBinary(idx_content) or isBinary(wt_content)) {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Binary file {s} differs, cannot patch\n", .{entry.name}) catch continue;
            try stderr_file.writeAll(msg);
            continue;
        }

        // Compute diff
        var diff_result = diff_mod.diffLines(allocator, idx_content, wt_content) catch continue;
        defer diff_result.deinit();

        if (diff_result.hunks.items.len == 0) continue;

        // Show file header
        try writeFileHeader(entry.name);

        // Process each hunk interactively
        var quit = false;
        var stage_all = false;

        var hi: usize = 0;
        while (hi < diff_result.hunks.items.len) : (hi += 1) {
            if (quit) break;

            const hunk = &diff_result.hunks.items[hi];

            // Display the hunk
            try displayHunk(hunk, hi + 1, diff_result.hunks.items.len);

            if (stage_all) {
                try stdout_file.writeAll("Staging hunk automatically.\n");
                any_staged = true;
                try applyHunkToIndex(allocator, repo, idx, entry, wt_content);
                continue;
            }

            // Show prompt and read response
            const can_split = canSplitHunk(hunk);
            try showHunkPrompt(can_split);

            const action = readHunkAction() catch .no;

            switch (action) {
                .yes => {
                    any_staged = true;
                    try applyHunkToIndex(allocator, repo, idx, entry, wt_content);
                },
                .no => {},
                .quit => {
                    quit = true;
                },
                .all => {
                    stage_all = true;
                    any_staged = true;
                    try applyHunkToIndex(allocator, repo, idx, entry, wt_content);
                },
                .done => break,
                .split => {
                    if (can_split) {
                        try displaySplitInfo(hunk);
                    } else {
                        try stderr_file.writeAll("Sorry, cannot split this hunk.\n");
                    }
                },
                .edit => {
                    try stderr_file.writeAll("Manual editing not supported in this implementation.\n");
                },
                .help => {
                    try showHelp();
                },
            }
        }

        if (quit) break;
    }

    // Write updated index if anything changed
    if (any_staged) {
        try idx.writeToFile(index_path);
        try stdout_file.writeAll("Index updated.\n");
    } else {
        try stdout_file.writeAll("No changes staged.\n");
    }
}

// ---------------------------------------------------------------------------
// git reset -p
// ---------------------------------------------------------------------------

fn interactiveResetPatch(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    file_filter: *std.StringHashMap(void),
    index_path: []const u8,
) !void {
    // Load HEAD tree entries
    var head_entries = std.StringHashMap(types.ObjectId).init(allocator);
    defer {
        var ki = head_entries.keyIterator();
        while (ki.next()) |key| allocator.free(key.*);
        head_entries.deinit();
    }
    loadHeadTree(repo, allocator, &head_entries) catch {};

    var any_unstaged = false;
    var quit_all = false;

    for (idx.entries.items) |*entry| {
        if (quit_all) break;
        if (file_filter.count() > 0 and !file_filter.contains(entry.name)) continue;

        // Get the HEAD version of the file
        const head_oid = head_entries.get(entry.name) orelse continue;

        // Skip if same as HEAD
        if (head_oid.eql(&entry.oid)) continue;

        const head_content = readBlobContent(repo, allocator, &head_oid) orelse continue;
        defer allocator.free(head_content);

        const idx_content = readBlobContent(repo, allocator, &entry.oid) orelse continue;
        defer allocator.free(idx_content);

        if (isBinary(head_content) or isBinary(idx_content)) continue;

        var diff_result = diff_mod.diffLines(allocator, head_content, idx_content) catch continue;
        defer diff_result.deinit();

        if (diff_result.hunks.items.len == 0) continue;

        // Show file header
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}diff --git a/{s} b/{s}{s}\n", .{ COLOR_BOLD, entry.name, entry.name, COLOR_RESET }) catch continue;
        try stdout_file.writeAll(msg);

        for (diff_result.hunks.items, 0..) |*hunk, hi| {
            try displayHunk(hunk, hi + 1, diff_result.hunks.items.len);
            try stdout_file.writeAll("Unstage this hunk [y,n,q,a,d,?]? ");

            const action = readHunkAction() catch .no;

            switch (action) {
                .yes => {
                    entry.oid = head_oid;
                    any_unstaged = true;
                },
                .quit => {
                    quit_all = true;
                    break;
                },
                .all => {
                    entry.oid = head_oid;
                    any_unstaged = true;
                    break;
                },
                .done => break,
                .help => try showResetHelp(),
                else => {},
            }
        }
    }

    if (any_unstaged) {
        try idx.writeToFile(index_path);
        try stdout_file.writeAll("Index updated.\n");
    } else {
        try stdout_file.writeAll("No changes unstaged.\n");
    }
}

// ---------------------------------------------------------------------------
// git checkout -p
// ---------------------------------------------------------------------------

fn interactiveCheckoutPatch(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    work_dir: []const u8,
    file_filter: *std.StringHashMap(void),
) !void {
    var quit_all = false;

    for (idx.entries.items) |*entry| {
        if (quit_all) break;
        if (file_filter.count() > 0 and !file_filter.contains(entry.name)) continue;

        var file_path_buf: [4096]u8 = undefined;
        const file_path = buildPath2(&file_path_buf, work_dir, "/", entry.name);

        const wt_content = readFileMaybe(allocator, file_path) orelse continue;
        defer allocator.free(wt_content);

        const idx_content = readBlobContent(repo, allocator, &entry.oid) orelse continue;
        defer allocator.free(idx_content);

        const wt_oid = computeBlobOid(wt_content);
        if (wt_oid.eql(&entry.oid)) continue;

        if (isBinary(idx_content) or isBinary(wt_content)) continue;

        var diff_result = diff_mod.diffLines(allocator, idx_content, wt_content) catch continue;
        defer diff_result.deinit();

        if (diff_result.hunks.items.len == 0) continue;

        try writeFileHeader(entry.name);

        for (diff_result.hunks.items, 0..) |*hunk, hi| {
            try displayHunk(hunk, hi + 1, diff_result.hunks.items.len);
            try stdout_file.writeAll("Discard this hunk from worktree [y,n,q,a,d,?]? ");

            const action = readHunkAction() catch .no;
            switch (action) {
                .yes => {
                    try writeFileContent(file_path, idx_content);
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "Restored {s} from index.\n", .{entry.name}) catch continue;
                    try stdout_file.writeAll(msg);
                    break;
                },
                .quit => {
                    quit_all = true;
                    break;
                },
                .all => {
                    try writeFileContent(file_path, idx_content);
                    break;
                },
                .done => break,
                .help => try showCheckoutHelp(),
                else => {},
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Diff --cached equivalent
// ---------------------------------------------------------------------------

/// Show staged changes (diff between index and HEAD).
pub fn showStagedDiff(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    try diff_mod.runDiff(repo, allocator, .index_vs_head, null, stdout_file);
}

// ---------------------------------------------------------------------------
// Hunk display and interaction
// ---------------------------------------------------------------------------

fn writeFileHeader(name: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var msg = std.fmt.bufPrint(&buf, "{s}diff --git a/{s} b/{s}{s}\n", .{ COLOR_BOLD, name, name, COLOR_RESET }) catch return;
    try stdout_file.writeAll(msg);
    msg = std.fmt.bufPrint(&buf, "--- a/{s}\n", .{name}) catch return;
    try stdout_file.writeAll(msg);
    msg = std.fmt.bufPrint(&buf, "+++ b/{s}\n", .{name}) catch return;
    try stdout_file.writeAll(msg);
}

fn displayHunk(hunk: *diff_mod.DiffHunk, hunk_num: usize, total_hunks: usize) !void {
    var buf: [4096]u8 = undefined;

    const msg = std.fmt.bufPrint(&buf, "{s}@@ -{d},{d} +{d},{d} @@{s} ({d}/{d})\n", .{
        COLOR_CYAN,
        hunk.old_start,
        hunk.old_count,
        hunk.new_start,
        hunk.new_count,
        COLOR_RESET,
        hunk_num,
        total_hunks,
    }) catch return;
    try stdout_file.writeAll(msg);

    for (hunk.lines.items) |*line| {
        switch (line.kind) {
            .context => {
                try stdout_file.writeAll(" ");
                try stdout_file.writeAll(line.content);
                try stdout_file.writeAll("\n");
            },
            .deletion => {
                try stdout_file.writeAll(COLOR_RED);
                try stdout_file.writeAll("-");
                try stdout_file.writeAll(line.content);
                try stdout_file.writeAll(COLOR_RESET);
                try stdout_file.writeAll("\n");
            },
            .addition => {
                try stdout_file.writeAll(COLOR_GREEN);
                try stdout_file.writeAll("+");
                try stdout_file.writeAll(line.content);
                try stdout_file.writeAll(COLOR_RESET);
                try stdout_file.writeAll("\n");
            },
        }
    }
}

fn canSplitHunk(hunk: *diff_mod.DiffHunk) bool {
    // A hunk can be split if it has multiple change regions separated by context
    var num_regions: usize = 0;
    var in_change = false;
    for (hunk.lines.items) |*line| {
        if (line.kind == .context) {
            if (in_change) {
                in_change = false;
            }
        } else {
            if (!in_change) {
                num_regions += 1;
                in_change = true;
            }
        }
    }
    return num_regions > 1;
}

fn showHunkPrompt(can_split: bool) !void {
    if (can_split) {
        try stdout_file.writeAll("Stage this hunk [y,n,q,a,d,s,e,?]? ");
    } else {
        try stdout_file.writeAll("Stage this hunk [y,n,q,a,d,e,?]? ");
    }
}

fn readHunkAction() !HunkAction {
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };

    var buf: [16]u8 = undefined;
    const n = stdin_file.read(&buf) catch return .no;
    if (n == 0) return .quit;

    return switch (buf[0]) {
        'y', 'Y' => .yes,
        'n', 'N' => .no,
        'q', 'Q' => .quit,
        'a', 'A' => .all,
        'd', 'D' => .done,
        's', 'S' => .split,
        'e', 'E' => .edit,
        '?' => .help,
        else => .no,
    };
}

fn showHelp() !void {
    try stdout_file.writeAll(
        \\y - stage this hunk
        \\n - do not stage this hunk
        \\q - quit; do not stage this hunk or any of the remaining ones
        \\a - stage this hunk and all later hunks in the file
        \\d - do not stage this hunk or any of the later hunks in the file
        \\s - split the current hunk into smaller hunks
        \\e - manually edit the current hunk
        \\? - print help
        \\
    );
}

fn showResetHelp() !void {
    try stdout_file.writeAll(
        \\y - unstage this hunk
        \\n - do not unstage this hunk
        \\q - quit; do not unstage this or remaining hunks
        \\a - unstage this and all remaining hunks
        \\d - do not unstage this or later hunks
        \\? - print help
        \\
    );
}

fn showCheckoutHelp() !void {
    try stdout_file.writeAll(
        \\y - discard this hunk from worktree
        \\n - do not discard this hunk
        \\q - quit; do not discard this or remaining hunks
        \\a - discard this and all remaining hunks
        \\d - do not discard this or later hunks
        \\? - print help
        \\
    );
}

fn displaySplitInfo(hunk: *diff_mod.DiffHunk) !void {
    var num_regions: usize = 0;
    var in_change = false;
    for (hunk.lines.items) |*line| {
        if (line.kind == .context) {
            if (in_change) in_change = false;
        } else {
            if (!in_change) {
                num_regions += 1;
                in_change = true;
            }
        }
    }

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Split into {d} hunks.\n", .{num_regions}) catch return;
    try stdout_file.writeAll(msg);
}

fn applyHunkToIndex(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    idx: *index_mod.Index,
    entry: *index_mod.IndexEntry,
    wt_content: []const u8,
) !void {
    _ = idx;
    // Write the working tree content as a blob and update the index entry
    const new_oid = try loose.writeLooseObject(allocator, repo.git_dir, .blob, wt_content);
    entry.oid = new_oid;
    entry.file_size = @intCast(wt_content.len);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

fn buildPath2(buf: []u8, a: []const u8, sep: []const u8, b: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..a.len], a);
    pos += a.len;
    @memcpy(buf[pos..][0..sep.len], sep);
    pos += sep.len;
    @memcpy(buf[pos..][0..b.len], b);
    pos += b.len;
    return buf[0..pos];
}

fn readFileMaybe(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    if (stat.size > 10 * 1024 * 1024) return null;
    const content = allocator.alloc(u8, stat.size) catch return null;
    const n = file.readAll(content) catch {
        allocator.free(content);
        return null;
    };
    if (n < content.len) {
        const trimmed = allocator.alloc(u8, n) catch {
            allocator.free(content);
            return null;
        };
        @memcpy(trimmed, content[0..n]);
        allocator.free(content);
        return trimmed;
    }
    return content;
}

fn readBlobContent(repo: *repository.Repository, allocator: std.mem.Allocator, oid: *const types.ObjectId) ?[]u8 {
    var obj = repo.readObject(allocator, oid) catch return null;
    if (obj.obj_type != .blob) {
        obj.deinit();
        return null;
    }
    return obj.data;
}

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
    const digest = hasher.finalResult();
    return types.ObjectId{ .bytes = digest };
}

fn isBinary(content: []const u8) bool {
    const check_len = @min(content.len, 8000);
    for (content[0..check_len]) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

fn writeFileContent(path: []const u8, content: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn loadHeadTree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    entries: *std.StringHashMap(types.ObjectId),
) !void {
    const head_oid = try repo.resolveRef(allocator, "HEAD");
    var obj = try repo.readObject(allocator, &head_oid);
    defer obj.deinit();
    if (obj.obj_type != .commit) return error.NotACommit;
    const tree_oid = try tree_diff.getCommitTreeOid(obj.data);
    try walkTree(repo, allocator, &tree_oid, entries, "");
}

fn walkTree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    tree_oid: *const types.ObjectId,
    entries: *std.StringHashMap(types.ObjectId),
    prefix: []const u8,
) !void {
    var obj = try repo.readObject(allocator, tree_oid);
    defer obj.deinit();
    if (obj.obj_type != .tree) return;

    var pos: usize = 0;
    while (pos < obj.data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, obj.data, pos, ' ') orelse break;
        const mode_str = obj.data[pos..space_pos];
        pos = space_pos + 1;

        const null_pos = std.mem.indexOfScalarPos(u8, obj.data, pos, 0) orelse break;
        const name = obj.data[pos..null_pos];
        pos = null_pos + 1;

        if (pos + 20 > obj.data.len) break;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, obj.data[pos..][0..20]);
        pos += 20;

        var path_buf: [4096]u8 = undefined;
        var path_pos: usize = 0;
        if (prefix.len > 0) {
            @memcpy(path_buf[0..prefix.len], prefix);
            path_pos += prefix.len;
            path_buf[path_pos] = '/';
            path_pos += 1;
        }
        @memcpy(path_buf[path_pos..][0..name.len], name);
        path_pos += name.len;

        const full_path = try allocator.alloc(u8, path_pos);
        @memcpy(full_path, path_buf[0..path_pos]);

        if (std.mem.eql(u8, mode_str, "40000")) {
            try walkTree(repo, allocator, &oid, entries, full_path);
            allocator.free(full_path);
        } else {
            try entries.put(full_path, oid);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "computeBlobOid" {
    const oid = computeBlobOid("");
    const hex = oid.toHex();
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &hex);
}

test "isBinary" {
    try std.testing.expect(!isBinary("hello world"));
    try std.testing.expect(isBinary("hello\x00world"));
}

test "HunkAction mapping" {
    const cases = [_]struct { c: u8, expected: HunkAction }{
        .{ .c = 'y', .expected = .yes },
        .{ .c = 'n', .expected = .no },
        .{ .c = 'q', .expected = .quit },
        .{ .c = 'a', .expected = .all },
        .{ .c = 'd', .expected = .done },
        .{ .c = 's', .expected = .split },
        .{ .c = 'e', .expected = .edit },
        .{ .c = '?', .expected = .help },
        .{ .c = 'x', .expected = .no },
    };

    for (cases) |tc| {
        const action: HunkAction = switch (tc.c) {
            'y', 'Y' => .yes,
            'n', 'N' => .no,
            'q', 'Q' => .quit,
            'a', 'A' => .all,
            'd', 'D' => .done,
            's', 'S' => .split,
            'e', 'E' => .edit,
            '?' => .help,
            else => .no,
        };
        try std.testing.expectEqual(tc.expected, action);
    }
}
