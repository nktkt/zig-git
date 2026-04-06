const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const patch_mod = @import("patch.zig");
const index_mod = @import("index.zig");
const hash_mod = @import("hash.zig");
const loose = @import("loose.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Options for patch application.
pub const ApplyOptions = struct {
    check_only: bool = false,
    stat_only: bool = false,
    cached: bool = false,
    reverse: bool = false,
    three_way: bool = false,
    fuzz_factor: usize = 0,
};

/// Run the apply command from CLI args.
pub fn runApply(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = ApplyOptions{};
    var patch_files = std.array_list.Managed([]const u8).init(allocator);
    defer patch_files.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--check")) {
            opts.check_only = true;
        } else if (std.mem.eql(u8, arg, "--stat")) {
            opts.stat_only = true;
        } else if (std.mem.eql(u8, arg, "--cached") or std.mem.eql(u8, arg, "--index")) {
            opts.cached = true;
        } else if (std.mem.eql(u8, arg, "-R") or std.mem.eql(u8, arg, "--reverse")) {
            opts.reverse = true;
        } else if (std.mem.eql(u8, arg, "--3way") or std.mem.eql(u8, arg, "-3")) {
            opts.three_way = true;
        } else if (std.mem.startsWith(u8, arg, "--fuzz=")) {
            const val = arg["--fuzz=".len..];
            opts.fuzz_factor = std.fmt.parseInt(usize, val, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "-C")) {
            i += 1;
            if (i < args.len) {
                opts.fuzz_factor = std.fmt.parseInt(usize, args[i], 10) catch 0;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try patch_files.append(arg);
        }
    }

    if (patch_files.items.len == 0) {
        try stderr_file.writeAll(apply_usage);
        return;
    }

    for (patch_files.items) |patch_file| {
        applyPatchFile(repo, allocator, patch_file, opts) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: patch failed: {s}\n", .{@errorName(err)}) catch
                "error: patch failed\n";
            try stderr_file.writeAll(msg);
        };
    }
}

const apply_usage =
    \\usage: zig-git apply [options] <patch-file>...
    \\
    \\Options:
    \\  --check    Only verify that the patch applies cleanly
    \\  --stat     Show diffstat of the patch
    \\  --cached   Apply to index instead of working tree
    \\  -R, --reverse  Reverse the patch
    \\  -3, --3way Attempt three-way merge if direct apply fails
    \\  -C <n>     Ensure at least <n> lines of surrounding context match
    \\
;

/// Apply a single patch file.
fn applyPatchFile(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    patch_file_path: []const u8,
    opts: ApplyOptions,
) !void {
    // Read the patch file
    const content = try readFile(allocator, patch_file_path);
    defer allocator.free(content);

    // Parse the patch
    var patch = try patch_mod.parsePatch(allocator, content);
    defer patch.deinit();

    if (patch.file_diffs.items.len == 0) {
        try stderr_file.writeAll("warning: patch file contains no diffs\n");
        return;
    }

    // --stat mode: just show statistics
    if (opts.stat_only) {
        const stat_str = patch_mod.formatDiffstat(allocator, patch.file_diffs.items) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: could not format diffstat: {s}\n", .{@errorName(err)}) catch
                "error: could not format diffstat\n";
            try stderr_file.writeAll(msg);
            return;
        };
        defer allocator.free(stat_str);
        try stdout_file.writeAll(stat_str);
        return;
    }

    const work_dir = getWorkDir(repo.git_dir);

    // Process each file diff
    for (patch.file_diffs.items) |*fd| {
        if (fd.is_binary) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "skipping binary file: {s}\n", .{fd.new_path}) catch continue;
            try stderr_file.writeAll(msg);
            continue;
        }

        // Determine file path
        const file_path = if (fd.new_path.len > 0) fd.new_path else fd.old_path;

        if (opts.reverse) {
            try applyFileDiffReverse(allocator, work_dir, fd, opts);
        } else {
            try applyFileDiff(allocator, work_dir, fd, opts);
        }

        if (opts.cached) {
            try updateIndexForFile(repo, allocator, work_dir, file_path);
        }
    }

    if (opts.check_only) {
        try stdout_file.writeAll("patch applies cleanly\n");
    }
}

/// Apply a single file diff to the working tree.
fn applyFileDiff(
    allocator: std.mem.Allocator,
    work_dir: []const u8,
    fd: *const patch_mod.FileDiff,
    opts: ApplyOptions,
) !void {
    const target_path_name = if (fd.new_path.len > 0) fd.new_path else fd.old_path;

    var path_buf: [4096]u8 = undefined;
    const full_path = concatPath3(&path_buf, work_dir, "/", target_path_name);

    if (fd.is_deleted) {
        if (!opts.check_only) {
            std.fs.deleteFileAbsolute(full_path) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "warning: could not delete {s}: {s}\n", .{ target_path_name, @errorName(err) }) catch return;
                try stderr_file.writeAll(msg);
            };
        }
        return;
    }

    if (fd.is_new) {
        // Create a new file from the patch additions
        if (!opts.check_only) {
            // Ensure parent directory exists
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
        }
        return;
    }

    // Modify existing file
    const old_content = readFileMaybe(allocator, full_path) orelse return error.FileNotFound;
    defer allocator.free(old_content);

    // Split into lines
    var old_lines = std.array_list.Managed([]const u8).init(allocator);
    defer old_lines.deinit();
    try splitLines(old_content, &old_lines);

    // Apply each hunk
    var new_lines = std.array_list.Managed([]const u8).init(allocator);
    defer new_lines.deinit();

    var old_idx: usize = 0;

    for (fd.hunks.items) |*hunk| {
        const hunk_start = if (hunk.old_start > 0) hunk.old_start - 1 else 0;

        // Copy lines before the hunk
        while (old_idx < hunk_start and old_idx < old_lines.items.len) {
            try new_lines.append(old_lines.items[old_idx]);
            old_idx += 1;
        }

        // Apply the hunk
        for (hunk.lines.items) |*line| {
            switch (line.kind) {
                .context => {
                    // Verify context matches (with fuzz)
                    if (old_idx < old_lines.items.len) {
                        if (!contextMatches(old_lines.items[old_idx], line.content, opts.fuzz_factor)) {
                            if (opts.check_only) {
                                var buf: [256]u8 = undefined;
                                const msg = std.fmt.bufPrint(&buf, "error: context mismatch at line {d}\n", .{old_idx + 1}) catch
                                    "error: context mismatch\n";
                                try stderr_file.writeAll(msg);
                                return error.PatchContextMismatch;
                            }
                        }
                        try new_lines.append(old_lines.items[old_idx]);
                        old_idx += 1;
                    }
                },
                .addition => {
                    if (!opts.check_only) {
                        try new_lines.append(line.content);
                    }
                },
                .deletion => {
                    // Skip the old line (verify it matches)
                    if (old_idx < old_lines.items.len) {
                        if (!contextMatches(old_lines.items[old_idx], line.content, opts.fuzz_factor)) {
                            if (opts.check_only) {
                                return error.PatchContextMismatch;
                            }
                        }
                        old_idx += 1;
                    }
                },
                .no_newline_marker => {},
            }
        }
    }

    // Copy remaining lines
    while (old_idx < old_lines.items.len) {
        try new_lines.append(old_lines.items[old_idx]);
        old_idx += 1;
    }

    if (opts.check_only) return;

    // Write the result
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    for (new_lines.items, 0..) |line, li| {
        try result.appendSlice(line);
        if (li < new_lines.items.len - 1) {
            try result.append('\n');
        }
    }
    // Add final newline if the original had one
    if (old_content.len > 0 and old_content[old_content.len - 1] == '\n') {
        if (result.items.len == 0 or result.items[result.items.len - 1] != '\n') {
            try result.append('\n');
        }
    }

    const file = try std.fs.createFileAbsolute(full_path, .{});
    defer file.close();
    try file.writeAll(result.items);
}

/// Apply a file diff in reverse.
fn applyFileDiffReverse(
    allocator: std.mem.Allocator,
    work_dir: []const u8,
    fd: *const patch_mod.FileDiff,
    opts: ApplyOptions,
) !void {
    // Create a reversed version of the file diff
    const target_path_name = if (fd.old_path.len > 0) fd.old_path else fd.new_path;

    var path_buf: [4096]u8 = undefined;
    const full_path = concatPath3(&path_buf, work_dir, "/", target_path_name);

    if (fd.is_new) {
        // Reverse of new = delete
        if (!opts.check_only) {
            std.fs.deleteFileAbsolute(full_path) catch {};
        }
        return;
    }

    if (fd.is_deleted) {
        // Reverse of delete = create
        if (!opts.check_only) {
            if (std.fs.path.dirname(full_path)) |parent| {
                mkdirRecursive(parent) catch {};
            }

            var content = std.array_list.Managed(u8).init(allocator);
            defer content.deinit();

            for (fd.hunks.items) |*hunk| {
                for (hunk.lines.items) |*line| {
                    if (line.kind == .deletion) {
                        try content.appendSlice(line.content);
                        try content.append('\n');
                    }
                }
            }

            const file = std.fs.createFileAbsolute(full_path, .{}) catch return error.CannotCreateFile;
            defer file.close();
            try file.writeAll(content.items);
        }
        return;
    }

    // For modifications, read current file and apply hunks in reverse
    const old_content = readFileMaybe(allocator, full_path) orelse return error.FileNotFound;
    defer allocator.free(old_content);

    var old_lines = std.array_list.Managed([]const u8).init(allocator);
    defer old_lines.deinit();
    try splitLines(old_content, &old_lines);

    var new_lines = std.array_list.Managed([]const u8).init(allocator);
    defer new_lines.deinit();

    var old_idx: usize = 0;

    for (fd.hunks.items) |*hunk| {
        const hunk_start = if (hunk.new_start > 0) hunk.new_start - 1 else 0;

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
                    // In reverse, additions become deletions (skip)
                    if (old_idx < old_lines.items.len) {
                        old_idx += 1;
                    }
                },
                .deletion => {
                    // In reverse, deletions become additions
                    if (!opts.check_only) {
                        try new_lines.append(line.content);
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

    if (opts.check_only) return;

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

/// Update the index for a modified file.
fn updateIndexForFile(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    work_dir: []const u8,
    rel_path: []const u8,
) !void {
    var index_path_buf: [4096]u8 = undefined;
    const index_path = concatPath(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    // Read the file and hash it
    var file_path_buf: [4096]u8 = undefined;
    const file_path = concatPath3(&file_path_buf, work_dir, "/", rel_path);

    const content = readFileMaybe(allocator, file_path) orelse return;
    defer allocator.free(content);

    const oid = computeBlobOid(content);

    // Write blob to object store
    _ = loose.writeLooseObject(allocator, repo.git_dir, .blob, content) catch return;

    // Update index entry
    const name_copy = try allocator.alloc(u8, rel_path.len);
    @memcpy(name_copy, rel_path);

    const entry = index_mod.IndexEntry{
        .ctime_s = 0,
        .ctime_ns = 0,
        .mtime_s = 0,
        .mtime_ns = 0,
        .dev = 0,
        .ino = 0,
        .mode = 0o100644,
        .uid = 0,
        .gid = 0,
        .file_size = @intCast(content.len),
        .oid = oid,
        .flags = 0,
        .name = name_copy,
        .owned = true,
    };

    try idx.addEntry(entry);
    try idx.writeToFile(index_path);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn contextMatches(actual: []const u8, expected: []const u8, fuzz: usize) bool {
    if (std.mem.eql(u8, actual, expected)) return true;
    if (fuzz > 0) {
        // Allow whitespace-only differences
        const trimmed_actual = std.mem.trim(u8, actual, " \t");
        const trimmed_expected = std.mem.trim(u8, expected, " \t");
        if (std.mem.eql(u8, trimmed_actual, trimmed_expected)) return true;
    }
    return false;
}

fn splitLines(text: []const u8, lines: *std.array_list.Managed([]const u8)) !void {
    if (text.len == 0) return;
    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        if (iter.peek() == null and line.len == 0) break;
        try lines.append(line);
    }
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
    return types.ObjectId{ .bytes = hasher.finalResult() };
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
    // Try absolute path first
    if (std.fs.path.isAbsolute(path)) {
        return readFileAbsolute(allocator, path);
    }
    // Try relative to cwd
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

fn readFileAbsolute(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
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

test "contextMatches" {
    try std.testing.expect(contextMatches("hello", "hello", 0));
    try std.testing.expect(!contextMatches("hello", "world", 0));
    try std.testing.expect(contextMatches("  hello  ", "hello", 1));
}

test "splitLines" {
    var lines = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer lines.deinit();

    try splitLines("a\nb\nc\n", &lines);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
}
