const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const hash_mod = @import("hash.zig");
const merge_mod = @import("merge.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// ANSI color codes.
const COLOR_RED = "\x1b[31m";
const COLOR_GREEN = "\x1b[32m";
const COLOR_YELLOW = "\x1b[33m";
const COLOR_CYAN = "\x1b[36m";
const COLOR_BOLD = "\x1b[1m";
const COLOR_RESET = "\x1b[0m";

/// Match status between patches in two ranges.
pub const PatchMatch = enum {
    /// Patch is identical (=)
    equal,
    /// Patch is modified (!)
    modified,
    /// Patch is new in range2 (>)
    added,
    /// Patch is dropped from range1 (<)
    dropped,
};

/// A commit's patch representation for comparison.
pub const PatchInfo = struct {
    oid: types.ObjectId,
    subject: []const u8,
    diff_hash: [hash_mod.SHA1_DIGEST_LENGTH]u8,
};

/// Result of matching two patch sets.
pub const RangeDiffEntry = struct {
    status: PatchMatch,
    idx1: ?usize, // index in range1 (null if added)
    idx2: ?usize, // index in range2 (null if dropped)
    oid1: ?types.ObjectId,
    oid2: ?types.ObjectId,
    subject: []const u8,
};

/// Get the list of commits in a range (base..tip), in topological order.
fn getCommitsInRange(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    base_oid: *const types.ObjectId,
    tip_oid: *const types.ObjectId,
) ![]types.ObjectId {
    var result = std.array_list.Managed(types.ObjectId).init(allocator);
    defer result.deinit();

    var visited = std.AutoHashMap([types.OID_RAW_LEN]u8, void).init(allocator);
    defer visited.deinit();

    // Walk from tip back to base
    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();

    try queue.append(tip_oid.*);
    try visited.put(tip_oid.bytes, {});

    // Mark base as visited so we stop there
    try visited.put(base_oid.bytes, {});

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);

        // Don't include the base commit itself
        if (std.mem.eql(u8, &current.bytes, &base_oid.bytes)) continue;

        try result.append(current);

        // Read commit to find parents
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

    // Reverse to get topological order (oldest first)
    const owned = try result.toOwnedSlice();
    std.mem.reverse(types.ObjectId, owned);
    return owned;
}

/// Compute a hash of the diff content for a commit (for similarity matching).
fn computeDiffHash(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    oid: *const types.ObjectId,
) ![hash_mod.SHA1_DIGEST_LENGTH]u8 {
    var obj = repo.readObject(allocator, oid) catch return hash_mod.sha1Digest("");

    defer obj.deinit();

    if (obj.obj_type != .commit) return hash_mod.sha1Digest("");

    // Extract the tree oid and parent tree oid, then hash the diff between them
    const tree_oid = parseCommitTree(obj.data) catch return hash_mod.sha1Digest("");

    const parents = parseCommitParents(allocator, obj.data) catch return hash_mod.sha1Digest("");
    defer allocator.free(parents);

    // Hash the tree oid and parent tree oids as a proxy for the diff
    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(&tree_oid.bytes);

    // Also include the commit message body (ignoring subject for better matching)
    const body = extractCommitBody(obj.data);
    hasher.update(body);

    // Include parent trees for context
    for (parents) |parent| {
        var parent_obj = repo.readObject(allocator, &parent) catch continue;
        defer parent_obj.deinit();
        const parent_tree = parseCommitTree(parent_obj.data) catch continue;
        hasher.update(&parent_tree.bytes);
    }

    return hasher.finalResult();
}

/// Extract commit subject line.
fn extractCommitSubject(data: []const u8) []const u8 {
    // Find the blank line separating headers from body
    if (std.mem.indexOf(u8, data, "\n\n")) |pos| {
        const body = data[pos + 2 ..];
        // Subject is first non-empty line
        var line_iter = std.mem.splitScalar(u8, body, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            if (trimmed.len > 0) return trimmed;
        }
    }
    return "(no subject)";
}

/// Extract commit body (everything after the subject line).
fn extractCommitBody(data: []const u8) []const u8 {
    if (std.mem.indexOf(u8, data, "\n\n")) |pos| {
        return data[pos + 2 ..];
    }
    return "";
}

/// Build patch info for each commit in a range.
fn buildPatchInfos(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    commits: []const types.ObjectId,
) ![]PatchInfo {
    var infos = try allocator.alloc(PatchInfo, commits.len);
    errdefer allocator.free(infos);

    for (commits, 0..) |oid, i| {
        var obj = repo.readObject(allocator, &oid) catch {
            infos[i] = .{
                .oid = oid,
                .subject = "(unreadable)",
                .diff_hash = std.mem.zeroes([hash_mod.SHA1_DIGEST_LENGTH]u8),
            };
            continue;
        };
        defer obj.deinit();

        infos[i] = .{
            .oid = oid,
            .subject = extractCommitSubject(obj.data),
            .diff_hash = computeDiffHash(allocator, repo, &oid) catch std.mem.zeroes([hash_mod.SHA1_DIGEST_LENGTH]u8),
        };
    }

    return infos;
}

/// Compute similarity score between two patches (0 = different, 100 = identical).
fn patchSimilarity(a: *const PatchInfo, b: *const PatchInfo) u32 {
    // If diff hashes are identical, patches are considered the same
    if (std.mem.eql(u8, &a.diff_hash, &b.diff_hash)) return 100;

    // Compare subjects as a rough similarity metric
    var matching_bytes: usize = 0;
    const min_len = @min(a.subject.len, b.subject.len);
    for (0..min_len) |i| {
        if (a.subject[i] == b.subject[i]) matching_bytes += 1;
    }

    const max_len = @max(a.subject.len, b.subject.len);
    if (max_len == 0) return 50;

    return @intCast((matching_bytes * 80) / max_len);
}

/// Match patches between two ranges using Hungarian-like greedy matching.
fn matchPatches(
    allocator: std.mem.Allocator,
    infos1: []const PatchInfo,
    infos2: []const PatchInfo,
) ![]RangeDiffEntry {
    var entries = std.array_list.Managed(RangeDiffEntry).init(allocator);
    defer entries.deinit();

    // Track which patches have been matched
    var matched1 = try allocator.alloc(bool, infos1.len);
    defer allocator.free(matched1);
    @memset(matched1, false);

    var matched2 = try allocator.alloc(bool, infos2.len);
    defer allocator.free(matched2);
    @memset(matched2, false);

    // Greedy matching: for each patch in range1, find best match in range2
    for (infos1, 0..) |*info1, i| {
        var best_j: ?usize = null;
        var best_score: u32 = 0;

        for (infos2, 0..) |*info2, j| {
            if (matched2[j]) continue;
            const score = patchSimilarity(info1, info2);
            if (score > best_score and score >= 30) {
                best_score = score;
                best_j = j;
            }
        }

        if (best_j) |j| {
            matched1[i] = true;
            matched2[j] = true;

            const status: PatchMatch = if (best_score >= 100) .equal else .modified;
            try entries.append(.{
                .status = status,
                .idx1 = i,
                .idx2 = j,
                .oid1 = info1.oid,
                .oid2 = infos2[j].oid,
                .subject = infos2[j].subject,
            });
        }
    }

    // Add dropped patches (in range1 but not matched)
    for (infos1, 0..) |*info1, i| {
        if (!matched1[i]) {
            try entries.append(.{
                .status = .dropped,
                .idx1 = i,
                .idx2 = null,
                .oid1 = info1.oid,
                .oid2 = null,
                .subject = info1.subject,
            });
        }
    }

    // Add new patches (in range2 but not matched)
    for (infos2, 0..) |*info2, j| {
        if (!matched2[j]) {
            try entries.append(.{
                .status = .added,
                .idx1 = null,
                .idx2 = j,
                .oid1 = null,
                .oid2 = info2.oid,
                .subject = info2.subject,
            });
        }
    }

    // Sort entries by position (range2 index for matched/new, range1 index for dropped)
    std.mem.sort(RangeDiffEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: RangeDiffEntry, b: RangeDiffEntry) bool {
            const a_key = a.idx2 orelse (a.idx1 orelse 0) + 10000;
            const b_key = b.idx2 orelse (b.idx1 orelse 0) + 10000;
            return a_key < b_key;
        }
    }.lessThan);

    return entries.toOwnedSlice();
}

/// Format and print range-diff output.
fn printRangeDiff(entries: []const RangeDiffEntry, color: bool) !void {
    for (entries) |entry| {
        var line_buf: [1024]u8 = undefined;

        const idx1_str = if (entry.idx1) |i| blk: {
            var ibuf: [16]u8 = undefined;
            break :blk std.fmt.bufPrint(&ibuf, "{d}", .{i + 1}) catch "-";
        } else "-";

        const oid1_str = if (entry.oid1) |oid| blk: {
            const h = oid.toHex();
            break :blk h[0..7];
        } else "-------";

        const idx2_str = if (entry.idx2) |i| blk: {
            var ibuf: [16]u8 = undefined;
            break :blk std.fmt.bufPrint(&ibuf, "{d}", .{i + 1}) catch "-";
        } else "-";

        const oid2_str = if (entry.oid2) |oid| blk: {
            const h = oid.toHex();
            break :blk h[0..7];
        } else "-------";

        const status_char: u8 = switch (entry.status) {
            .equal => '=',
            .modified => '!',
            .added => '>',
            .dropped => '<',
        };

        if (color) {
            const color_code: []const u8 = switch (entry.status) {
                .equal => COLOR_RESET,
                .modified => COLOR_YELLOW,
                .added => COLOR_GREEN,
                .dropped => COLOR_RED,
            };
            const line = std.fmt.bufPrint(&line_buf, "{s}{s}: {s} {c} {s}: {s} {s}{s}\n", .{
                color_code,
                idx1_str,
                oid1_str,
                status_char,
                idx2_str,
                oid2_str,
                entry.subject,
                COLOR_RESET,
            }) catch continue;
            try stdout_file.writeAll(line);
        } else {
            const line = std.fmt.bufPrint(&line_buf, "{s}: {s} {c} {s}: {s} {s}\n", .{
                idx1_str,
                oid1_str,
                status_char,
                idx2_str,
                oid2_str,
                entry.subject,
            }) catch continue;
            try stdout_file.writeAll(line);
        }
    }
}

/// Parse a range spec like "base..tip" or resolve a single rev.
fn parseRangeSpec(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    spec: []const u8,
) !struct { base: types.ObjectId, tip: types.ObjectId } {
    if (std.mem.indexOf(u8, spec, "..")) |dot_pos| {
        const base_ref = spec[0..dot_pos];
        const tip_ref = spec[dot_pos + 2 ..];
        const base_oid = try repo.resolveRef(allocator, base_ref);
        const tip_oid = try repo.resolveRef(allocator, tip_ref);
        return .{ .base = base_oid, .tip = tip_oid };
    }
    return error.InvalidRangeSpec;
}

/// Execute range-diff comparison.
pub fn rangeDiff(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    args: []const []const u8,
) !void {
    var color = true;
    var range_args = std.array_list.Managed([]const u8).init(allocator);
    defer range_args.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--no-color")) {
            color = false;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try range_args.append(arg);
        }
    }

    if (range_args.items.len == 1) {
        // Three-dot notation: rev1...rev2 (use merge base)
        const spec = range_args.items[0];
        if (std.mem.indexOf(u8, spec, "...")) |dot_pos| {
            const rev1_ref = spec[0..dot_pos];
            const rev2_ref = spec[dot_pos + 3 ..];

            const oid1 = repo.resolveRef(allocator, rev1_ref) catch {
                try stderr_file.writeAll("fatal: cannot resolve revision\n");
                std.process.exit(128);
            };
            const oid2 = repo.resolveRef(allocator, rev2_ref) catch {
                try stderr_file.writeAll("fatal: cannot resolve revision\n");
                std.process.exit(128);
            };

            // Find merge base
            const base = merge_mod.findMergeBase(allocator, repo, &oid1, &oid2) catch null;
            if (base == null) {
                try stderr_file.writeAll("fatal: no merge base found\n");
                std.process.exit(128);
            }

            var base_val = base.?;
            try executeRangeDiff(allocator, repo, &base_val, &oid1, &base_val, &oid2, color);
        } else {
            try stderr_file.writeAll("fatal: invalid range-diff arguments\n");
            std.process.exit(1);
        }
    } else if (range_args.items.len == 2) {
        // Two range specs: base1..rev1 base2..rev2
        const range1 = parseRangeSpec(allocator, repo, range_args.items[0]) catch {
            try stderr_file.writeAll("fatal: invalid range spec\n");
            std.process.exit(128);
        };
        const range2 = parseRangeSpec(allocator, repo, range_args.items[1]) catch {
            try stderr_file.writeAll("fatal: invalid range spec\n");
            std.process.exit(128);
        };

        var b1 = range1.base;
        var t1 = range1.tip;
        var b2 = range2.base;
        var t2 = range2.tip;
        try executeRangeDiff(allocator, repo, &b1, &t1, &b2, &t2, color);
    } else {
        try stderr_file.writeAll(range_diff_usage);
        std.process.exit(1);
    }
}

fn executeRangeDiff(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    base1: *const types.ObjectId,
    tip1: *const types.ObjectId,
    base2: *const types.ObjectId,
    tip2: *const types.ObjectId,
    color: bool,
) !void {
    // Get commits in each range
    const commits1 = try getCommitsInRange(allocator, repo, base1, tip1);
    defer allocator.free(commits1);

    const commits2 = try getCommitsInRange(allocator, repo, base2, tip2);
    defer allocator.free(commits2);

    // Build patch infos
    const infos1 = try buildPatchInfos(allocator, repo, commits1);
    defer allocator.free(infos1);

    const infos2 = try buildPatchInfos(allocator, repo, commits2);
    defer allocator.free(infos2);

    // Match patches
    const entries = try matchPatches(allocator, infos1, infos2);
    defer allocator.free(entries);

    // Print results
    try printRangeDiff(entries, color);
}

/// Run the range-diff command.
pub fn runRangeDiff(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        try stderr_file.writeAll(range_diff_usage);
        std.process.exit(1);
    }

    try rangeDiff(allocator, repo, args);
}

const range_diff_usage =
    \\usage: zig-git range-diff <base1>..<rev1> <base2>..<rev2>
    \\       zig-git range-diff <rev1>...<rev2>
    \\
    \\Compare two commit ranges.
    \\
    \\Options:
    \\  --no-color   Disable color output
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

test "extractCommitSubject" {
    const data = "tree aaaa\nparent bbbb\n\nFix the bug in parser\n\nDetailed description.";
    const subject = extractCommitSubject(data);
    try std.testing.expectEqualStrings("Fix the bug in parser", subject);
}

test "extractCommitSubject empty" {
    const data = "tree aaaa\n";
    const subject = extractCommitSubject(data);
    try std.testing.expectEqualStrings("(no subject)", subject);
}

test "patchSimilarity identical" {
    const a = PatchInfo{ .oid = types.ObjectId.ZERO, .subject = "hello", .diff_hash = [_]u8{1} ** 20 };
    const b = PatchInfo{ .oid = types.ObjectId.ZERO, .subject = "hello", .diff_hash = [_]u8{1} ** 20 };
    try std.testing.expectEqual(@as(u32, 100), patchSimilarity(&a, &b));
}

test "patchSimilarity different" {
    const a = PatchInfo{ .oid = types.ObjectId.ZERO, .subject = "hello", .diff_hash = [_]u8{1} ** 20 };
    const b = PatchInfo{ .oid = types.ObjectId.ZERO, .subject = "world", .diff_hash = [_]u8{2} ** 20 };
    const score = patchSimilarity(&a, &b);
    try std.testing.expect(score < 100);
}
