const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_diff = @import("tree_diff.zig");
const diff_mod = @import("diff.zig");
const patch_mod = @import("patch.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Options for format-patch command.
pub const FormatPatchOptions = struct {
    output_dir: []const u8 = "",
    use_stdout: bool = false,
    start_number: usize = 1,
    subject_prefix: []const u8 = "PATCH",
    numbered: bool = true,
    cover_letter: bool = false,
};

/// Run the format-patch command from CLI args.
pub fn runFormatPatch(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = FormatPatchOptions{};
    var range_arg: ?[]const u8 = null;
    var last_n: ?usize = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--stdout")) {
            opts.use_stdout = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output-directory")) {
            i += 1;
            if (i < args.len) opts.output_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--subject-prefix")) {
            i += 1;
            if (i < args.len) opts.subject_prefix = args[i];
        } else if (std.mem.eql(u8, arg, "--cover-letter")) {
            opts.cover_letter = true;
        } else if (std.mem.eql(u8, arg, "-N") or std.mem.eql(u8, arg, "--no-numbered")) {
            opts.numbered = false;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and !std.mem.startsWith(u8, arg, "--")) {
            // Try to parse -N as "last N commits"
            last_n = std.fmt.parseInt(usize, arg[1..], 10) catch null;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            range_arg = arg;
        }
    }

    if (range_arg == null and last_n == null) {
        try stderr_file.writeAll(format_patch_usage);
        return;
    }

    // Collect commits to format
    var commits = std.array_list.Managed(CommitInfo).init(allocator);
    defer {
        for (commits.items) |*ci| {
            allocator.free(ci.data);
        }
        commits.deinit();
    }

    if (last_n) |n| {
        try collectLastNCommits(repo, allocator, n, &commits);
    } else if (range_arg) |range| {
        try collectRangeCommits(repo, allocator, range, &commits);
    }

    if (commits.items.len == 0) {
        try stderr_file.writeAll("No commits to format\n");
        return;
    }

    // Reverse so oldest commit is first
    std.mem.reverse(CommitInfo, commits.items);

    const total = commits.items.len;

    // Create output directory if needed
    if (opts.output_dir.len > 0 and !opts.use_stdout) {
        mkdirRecursive(opts.output_dir) catch {};
    }

    // Generate cover letter if requested
    if (opts.cover_letter and !opts.use_stdout) {
        try generateCoverLetter(allocator, &commits, opts);
    }

    // Format each commit as a patch
    for (commits.items, 0..) |*ci, idx| {
        const patch_num = opts.start_number + idx;

        if (opts.use_stdout) {
            try formatPatchToStdout(repo, allocator, ci, patch_num, total, opts);
        } else {
            try formatPatchToFile(repo, allocator, ci, patch_num, total, opts);
        }
    }
}

const format_patch_usage =
    \\usage: zig-git format-patch [options] <range>
    \\       zig-git format-patch [options] -<n>
    \\
    \\Options:
    \\  --stdout          Output patches to stdout instead of files
    \\  -o <dir>          Output directory for patch files
    \\  --subject-prefix  Subject prefix (default: PATCH)
    \\  --cover-letter    Generate a cover letter
    \\  -N                Do not number patches
    \\
;

const CommitInfo = struct {
    oid: types.ObjectId,
    data: []u8,
    author_name: []const u8,
    author_email: []const u8,
    author_date: []const u8,
    subject: []const u8,
    body: []const u8,
    tree_oid: types.ObjectId,
    parent_oid: ?types.ObjectId,
};

fn collectLastNCommits(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    count: usize,
    commits: *std.array_list.Managed(CommitInfo),
) !void {
    // Resolve HEAD
    const head_oid = repo.resolveRef(allocator, "HEAD") catch return;

    var current_oid = head_oid;
    var collected: usize = 0;

    while (collected < count) {
        var obj = repo.readObject(allocator, &current_oid) catch return;
        if (obj.obj_type != .commit) {
            obj.deinit();
            return;
        }

        const ci = parseCommitInfo(current_oid, obj.data);
        const data_copy = try allocator.alloc(u8, obj.data.len);
        @memcpy(data_copy, obj.data);
        obj.deinit();

        var info = ci;
        info.data = data_copy;
        // Re-parse pointers into owned data
        const ci2 = parseCommitInfo(current_oid, data_copy);
        info.author_name = ci2.author_name;
        info.author_email = ci2.author_email;
        info.author_date = ci2.author_date;
        info.subject = ci2.subject;
        info.body = ci2.body;
        info.tree_oid = ci2.tree_oid;
        info.parent_oid = ci2.parent_oid;

        try commits.append(info);
        collected += 1;

        if (info.parent_oid) |parent| {
            current_oid = parent;
        } else {
            break;
        }
    }
}

fn collectRangeCommits(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    range: []const u8,
    commits: *std.array_list.Managed(CommitInfo),
) !void {
    // Parse "A..B" range
    var base_ref: []const u8 = "";
    var tip_ref: []const u8 = "HEAD";

    if (std.mem.indexOf(u8, range, "..")) |sep| {
        base_ref = range[0..sep];
        tip_ref = range[sep + 2 ..];
        if (tip_ref.len == 0) tip_ref = "HEAD";
    } else {
        // Treat as "RANGE..HEAD"
        base_ref = range;
    }

    const base_oid = repo.resolveRef(allocator, base_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: bad revision '{s}'\n", .{base_ref}) catch
            "fatal: bad revision\n";
        try stderr_file.writeAll(msg);
        return;
    };

    const tip_oid = repo.resolveRef(allocator, tip_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: bad revision '{s}'\n", .{tip_ref}) catch
            "fatal: bad revision\n";
        try stderr_file.writeAll(msg);
        return;
    };

    // Walk from tip back to base
    var current_oid = tip_oid;
    while (!current_oid.eql(&base_oid)) {
        var obj = repo.readObject(allocator, &current_oid) catch return;
        if (obj.obj_type != .commit) {
            obj.deinit();
            return;
        }

        const data_copy = try allocator.alloc(u8, obj.data.len);
        @memcpy(data_copy, obj.data);
        obj.deinit();

        var info = parseCommitInfo(current_oid, data_copy);
        info.data = data_copy;

        try commits.append(info);

        if (info.parent_oid) |parent| {
            current_oid = parent;
        } else {
            break;
        }

        // Safety: don't collect more than 1000 commits
        if (commits.items.len > 1000) break;
    }
}

fn parseCommitInfo(oid: types.ObjectId, data: []const u8) CommitInfo {
    var info = CommitInfo{
        .oid = oid,
        .data = @constCast(data),
        .author_name = "Unknown",
        .author_email = "unknown@unknown",
        .author_date = "",
        .subject = "",
        .body = "",
        .tree_oid = types.ObjectId.ZERO,
        .parent_oid = null,
    };

    var lines = std.mem.splitScalar(u8, data, '\n');
    var in_headers = true;
    var subject_found = false;

    var pos: usize = 0;
    while (lines.next()) |line| {
        pos += line.len + 1;

        if (in_headers) {
            if (line.len == 0) {
                in_headers = false;
                continue;
            }

            if (std.mem.startsWith(u8, line, "tree ")) {
                if (line.len >= 5 + types.OID_HEX_LEN) {
                    info.tree_oid = types.ObjectId.fromHex(line[5..][0..types.OID_HEX_LEN]) catch types.ObjectId.ZERO;
                }
            } else if (std.mem.startsWith(u8, line, "parent ")) {
                if (line.len >= 7 + types.OID_HEX_LEN) {
                    info.parent_oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch null;
                }
            } else if (std.mem.startsWith(u8, line, "author ")) {
                parseAuthorLine(line[7..], &info);
            }
        } else {
            if (!subject_found) {
                info.subject = line;
                subject_found = true;
                if (pos < data.len) {
                    // Check for body after empty line following subject
                    if (lines.peek()) |next_line| {
                        if (next_line.len == 0) {
                            _ = lines.next();
                            pos += 1;
                            info.body = data[@min(pos, data.len)..];
                        } else {
                            info.body = data[@min(pos, data.len)..];
                        }
                    }
                }
                break;
            }
        }
    }

    return info;
}

fn parseAuthorLine(line: []const u8, info: *CommitInfo) void {
    // "Name <email> timestamp timezone"
    const lt_pos = std.mem.indexOfScalar(u8, line, '<') orelse return;
    const gt_pos = std.mem.indexOfScalar(u8, line, '>') orelse return;

    if (lt_pos > 0) {
        info.author_name = std.mem.trimRight(u8, line[0 .. lt_pos - 1], " ");
    }
    info.author_email = line[lt_pos + 1 .. gt_pos];
    if (gt_pos + 2 < line.len) {
        info.author_date = line[gt_pos + 2 ..];
    }
}

fn formatPatchToStdout(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    ci: *const CommitInfo,
    num: usize,
    total: usize,
    opts: FormatPatchOptions,
) !void {
    var buf: [4096]u8 = undefined;

    // From line
    const oid_hex = ci.oid.toHex();
    var line = std.fmt.bufPrint(&buf, "From {s} Mon Sep 17 00:00:00 2001\n", .{&oid_hex}) catch return;
    try stdout_file.writeAll(line);

    // From: header
    line = std.fmt.bufPrint(&buf, "From: {s} <{s}>\n", .{ ci.author_name, ci.author_email }) catch return;
    try stdout_file.writeAll(line);

    // Date: header
    const date_str = formatDate(allocator, ci.author_date);
    line = std.fmt.bufPrint(&buf, "Date: {s}\n", .{date_str}) catch return;
    try stdout_file.writeAll(line);

    // Subject: header
    if (opts.numbered and total > 1) {
        line = std.fmt.bufPrint(&buf, "Subject: [{s} {d}/{d}] {s}\n", .{ opts.subject_prefix, num, total, ci.subject }) catch return;
    } else {
        line = std.fmt.bufPrint(&buf, "Subject: [{s}] {s}\n", .{ opts.subject_prefix, ci.subject }) catch return;
    }
    try stdout_file.writeAll(line);

    try stdout_file.writeAll("\n");

    // Body
    if (ci.body.len > 0) {
        const body_trimmed = std.mem.trimRight(u8, ci.body, "\n\r ");
        try stdout_file.writeAll(body_trimmed);
        try stdout_file.writeAll("\n");
    }

    try stdout_file.writeAll("---\n");

    // Generate diff
    try writeDiffForCommit(repo, allocator, ci, stdout_file);

    try stdout_file.writeAll("--\nzig-git version 0.2.0\n\n");
}

fn formatPatchToFile(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    ci: *const CommitInfo,
    num: usize,
    total: usize,
    opts: FormatPatchOptions,
) !void {
    // Generate filename: NNNN-subject.patch
    var name_buf: [256]u8 = undefined;
    const subject_slug = slugify(&name_buf, ci.subject);

    var filename_buf: [512]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buf, "{d:0>4}-{s}.patch", .{ num, subject_slug }) catch return;

    var full_path_buf: [4096]u8 = undefined;
    var full_path: []const u8 = undefined;

    if (opts.output_dir.len > 0) {
        full_path = concatPath3(&full_path_buf, opts.output_dir, "/", filename);
    } else {
        // Get cwd
        const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return;
        defer allocator.free(cwd);
        full_path = concatPath3(&full_path_buf, cwd, "/", filename);
    }

    const file = std.fs.createFileAbsolute(full_path, .{}) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: could not create patch file: {s}\n", .{@errorName(err)}) catch
            "error: could not create patch file\n";
        try stderr_file.writeAll(msg);
        return;
    };
    defer file.close();

    var buf: [4096]u8 = undefined;

    // From line
    const oid_hex = ci.oid.toHex();
    var line = std.fmt.bufPrint(&buf, "From {s} Mon Sep 17 00:00:00 2001\n", .{&oid_hex}) catch return;
    try file.writeAll(line);

    // Headers
    line = std.fmt.bufPrint(&buf, "From: {s} <{s}>\n", .{ ci.author_name, ci.author_email }) catch return;
    try file.writeAll(line);

    const date_str = formatDate(allocator, ci.author_date);
    line = std.fmt.bufPrint(&buf, "Date: {s}\n", .{date_str}) catch return;
    try file.writeAll(line);

    if (opts.numbered and total > 1) {
        line = std.fmt.bufPrint(&buf, "Subject: [{s} {d}/{d}] {s}\n", .{ opts.subject_prefix, num, total, ci.subject }) catch return;
    } else {
        line = std.fmt.bufPrint(&buf, "Subject: [{s}] {s}\n", .{ opts.subject_prefix, ci.subject }) catch return;
    }
    try file.writeAll(line);

    try file.writeAll("\n");

    if (ci.body.len > 0) {
        const body_trimmed = std.mem.trimRight(u8, ci.body, "\n\r ");
        try file.writeAll(body_trimmed);
        try file.writeAll("\n");
    }

    try file.writeAll("---\n");

    // Write diff
    try writeDiffForCommit(repo, allocator, ci, file);

    try file.writeAll("--\nzig-git version 0.2.0\n");

    // Print the filename
    {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s}\n", .{filename}) catch return;
        try stdout_file.writeAll(msg);
    }
}

fn generateCoverLetter(
    allocator: std.mem.Allocator,
    commits: *const std.array_list.Managed(CommitInfo),
    opts: FormatPatchOptions,
) !void {
    var filename_buf: [512]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buf, "0000-cover-letter.patch", .{}) catch return;

    var full_path_buf: [4096]u8 = undefined;
    var full_path: []const u8 = undefined;

    if (opts.output_dir.len > 0) {
        full_path = concatPath3(&full_path_buf, opts.output_dir, "/", filename);
    } else {
        const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return;
        defer allocator.free(cwd);
        full_path = concatPath3(&full_path_buf, cwd, "/", filename);
    }

    const file = std.fs.createFileAbsolute(full_path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;

    try file.writeAll("From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001\n");

    const total = commits.items.len;
    var line = std.fmt.bufPrint(&buf, "Subject: [{s} 0/{d}] *** SUBJECT HERE ***\n", .{ opts.subject_prefix, total }) catch return;
    try file.writeAll(line);

    try file.writeAll("\n*** BLURB HERE ***\n\n");

    // List commits
    for (commits.items) |*ci| {
        const oid_hex = ci.oid.toHex();
        line = std.fmt.bufPrint(&buf, "{s} {s}\n", .{ oid_hex[0..7], ci.subject }) catch continue;
        try file.writeAll(line);
    }

    try file.writeAll("\n--\nzig-git version 0.2.0\n");

    {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{s}\n", .{filename}) catch return;
        try stdout_file.writeAll(msg);
    }
}

fn writeDiffForCommit(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    ci: *const CommitInfo,
    out_file: std.fs.File,
) !void {
    // Get the diff between parent tree and commit tree
    const parent_tree_oid: ?types.ObjectId = if (ci.parent_oid) |parent_oid| blk: {
        var parent_obj = repo.readObject(allocator, &parent_oid) catch break :blk null;
        defer parent_obj.deinit();
        if (parent_obj.obj_type != .commit) break :blk null;
        break :blk tree_diff.getCommitTreeOid(parent_obj.data) catch null;
    } else null;

    var parent_ptr: ?*const types.ObjectId = null;
    var parent_val: types.ObjectId = undefined;
    if (parent_tree_oid) |ptoid| {
        parent_val = ptoid;
        parent_ptr = &parent_val;
    }

    var tree_val = ci.tree_oid;
    var diff_result = tree_diff.diffTrees(repo, allocator, parent_ptr, &tree_val) catch return;
    defer diff_result.deinit();

    if (diff_result.changes.items.len == 0) return;

    // Write diffstat
    try writeDiffstat(allocator, repo, diff_result.changes.items, out_file);
    try out_file.writeAll("\n");

    // Write actual diffs
    try diff_mod.writeTreeDiff(repo, allocator, diff_result.changes.items, out_file);
}

fn writeDiffstat(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    changes: []const tree_diff.TreeChange,
    out_file: std.fs.File,
) !void {
    var buf: [512]u8 = undefined;
    var total_ins: usize = 0;
    var total_del: usize = 0;

    for (changes) |*change| {
        const ins = estimateChanges(repo, allocator, change, true);
        const del = estimateChanges(repo, allocator, change, false);
        total_ins += ins;
        total_del += del;

        const total_changes = ins + del;
        const line = std.fmt.bufPrint(&buf, " {s} | {d: >4} {s}\n", .{
            change.path,
            total_changes,
            if (change.kind == .added) "+" else if (change.kind == .deleted) "-" else "+-",
        }) catch continue;
        try out_file.writeAll(line);
    }

    const files_count = changes.len;
    const summary = std.fmt.bufPrint(&buf, " {d} file{s} changed", .{
        files_count,
        if (files_count != 1) "s" else "",
    }) catch return;
    try out_file.writeAll(summary);

    if (total_ins > 0) {
        const ins_str = std.fmt.bufPrint(&buf, ", {d} insertion{s}(+)", .{
            total_ins,
            if (total_ins != 1) "s" else "",
        }) catch "";
        try out_file.writeAll(ins_str);
    }
    if (total_del > 0) {
        const del_str = std.fmt.bufPrint(&buf, ", {d} deletion{s}(-)", .{
            total_del,
            if (total_del != 1) "s" else "",
        }) catch "";
        try out_file.writeAll(del_str);
    }
    try out_file.writeAll("\n");
}

fn estimateChanges(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    change: *const tree_diff.TreeChange,
    count_additions: bool,
) usize {
    if (change.kind == .added and count_additions) {
        if (change.new_oid) |oid| {
            var obj = repo.readObject(allocator, &oid) catch return 1;
            defer obj.deinit();
            return countLines(obj.data);
        }
        return 1;
    }
    if (change.kind == .deleted and !count_additions) {
        if (change.old_oid) |oid| {
            var obj = repo.readObject(allocator, &oid) catch return 1;
            defer obj.deinit();
            return countLines(obj.data);
        }
        return 1;
    }
    if (change.kind == .modified) {
        // Estimate: count lines as a rough estimate
        if (count_additions) {
            if (change.new_oid) |oid| {
                var obj = repo.readObject(allocator, &oid) catch return 1;
                defer obj.deinit();
                return @max(1, countLines(obj.data) / 4);
            }
        } else {
            if (change.old_oid) |oid| {
                var obj = repo.readObject(allocator, &oid) catch return 1;
                defer obj.deinit();
                return @max(1, countLines(obj.data) / 4);
            }
        }
    }
    return 0;
}

fn countLines(data: []const u8) usize {
    if (data.len == 0) return 0;
    var count: usize = 0;
    for (data) |c| {
        if (c == '\n') count += 1;
    }
    if (data[data.len - 1] != '\n') count += 1;
    return count;
}

fn slugify(buf: []u8, text: []const u8) []const u8 {
    var pos: usize = 0;
    for (text) |c| {
        if (pos >= buf.len - 1) break;
        if (c >= 'a' and c <= 'z') {
            buf[pos] = c;
            pos += 1;
        } else if (c >= 'A' and c <= 'Z') {
            buf[pos] = c + ('a' - 'A');
            pos += 1;
        } else if (c >= '0' and c <= '9') {
            buf[pos] = c;
            pos += 1;
        } else if (c == ' ' or c == '_' or c == '-') {
            if (pos > 0 and buf[pos - 1] != '-') {
                buf[pos] = '-';
                pos += 1;
            }
        }
    }
    // Trim trailing dash
    while (pos > 0 and buf[pos - 1] == '-') {
        pos -= 1;
    }
    if (pos == 0) {
        buf[0] = 'p';
        buf[1] = 'a';
        buf[2] = 't';
        buf[3] = 'c';
        buf[4] = 'h';
        pos = 5;
    }
    return buf[0..pos];
}

fn formatDate(allocator: std.mem.Allocator, timestamp_str: []const u8) []const u8 {
    // Parse Unix timestamp and timezone from "1234567890 +0000"
    _ = allocator;

    if (timestamp_str.len == 0) return "Thu, 1 Jan 1970 00:00:00 +0000";

    // Just return a simplified version for now
    // Real git would format as RFC 2822
    if (std.mem.indexOfScalar(u8, timestamp_str, ' ')) |_| {
        return timestamp_str;
    }
    return timestamp_str;
}

fn concatPath3(buf: []u8, a: []const u8, b: []const u8, c: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    @memcpy(buf[a.len + b.len ..][0..c.len], c);
    return buf[0 .. a.len + b.len + c.len];
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

test "slugify" {
    var buf: [256]u8 = undefined;
    const result = slugify(&buf, "Add feature for testing");
    try std.testing.expectEqualStrings("add-feature-for-testing", result);
}

test "parseCommitInfo basic" {
    const data = "tree 0000000000000000000000000000000000000000\nauthor Test User <test@test.com> 1234567890 +0000\n\nInitial commit\n";
    const oid = types.ObjectId.ZERO;
    const info = parseCommitInfo(oid, data);
    try std.testing.expectEqualStrings("Test User", info.author_name);
    try std.testing.expectEqualStrings("test@test.com", info.author_email);
}
