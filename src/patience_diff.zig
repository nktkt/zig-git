const std = @import("std");

/// Edit operation type (same as in diff.zig for compatibility).
pub const EditOp = enum {
    equal,
    insert,
    delete,
};

/// Diff algorithm selection.
pub const DiffAlgorithm = enum {
    myers,
    patience,
    histogram,
    minimal,
};

/// A line with its hash for efficient comparison.
const HashedLine = struct {
    text: []const u8,
    hash: u64,
};

/// Compute FNV-1a hash for a line.
fn hashLine(line: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (line) |byte| {
        h ^= @as(u64, byte);
        h *%= 1099511628211;
    }
    return h;
}

/// Patience diff algorithm.
/// Finds unique common lines as anchors, then recursively diffs between them.
pub fn patienceDiff(
    allocator: std.mem.Allocator,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
) ![]EditOp {
    var edits = std.array_list.Managed(EditOp).init(allocator);
    defer edits.deinit();

    try patienceDiffRecursive(allocator, old_lines, new_lines, 0, old_lines.len, 0, new_lines.len, &edits);

    const result = try allocator.alloc(EditOp, edits.items.len);
    @memcpy(result, edits.items);
    return result;
}

/// Recursive patience diff between old[old_start..old_end] and new[new_start..new_end].
fn patienceDiffRecursive(
    allocator: std.mem.Allocator,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    old_start: usize,
    old_end: usize,
    new_start: usize,
    new_end: usize,
    edits: *std.array_list.Managed(EditOp),
) !void {
    // Skip common prefix
    var prefix_len: usize = 0;
    while (old_start + prefix_len < old_end and
        new_start + prefix_len < new_end and
        std.mem.eql(u8, old_lines[old_start + prefix_len], new_lines[new_start + prefix_len]))
    {
        prefix_len += 1;
    }

    // Skip common suffix
    var suffix_len: usize = 0;
    while (old_start + prefix_len + suffix_len < old_end and
        new_start + prefix_len + suffix_len < new_end and
        std.mem.eql(u8, old_lines[old_end - 1 - suffix_len], new_lines[new_end - 1 - suffix_len]))
    {
        suffix_len += 1;
    }

    // Add prefix matches
    for (0..prefix_len) |_| {
        try edits.append(.equal);
    }

    const adj_old_start = old_start + prefix_len;
    const adj_old_end = old_end - suffix_len;
    const adj_new_start = new_start + prefix_len;
    const adj_new_end = new_end - suffix_len;

    if (adj_old_start >= adj_old_end and adj_new_start >= adj_new_end) {
        // No differences in the middle
    } else if (adj_old_start >= adj_old_end) {
        // Only insertions
        for (0..adj_new_end - adj_new_start) |_| {
            try edits.append(.insert);
        }
    } else if (adj_new_start >= adj_new_end) {
        // Only deletions
        for (0..adj_old_end - adj_old_start) |_| {
            try edits.append(.delete);
        }
    } else {
        // Find unique lines in both old and new within the range
        const anchors = try findAnchors(allocator, old_lines, new_lines, adj_old_start, adj_old_end, adj_new_start, adj_new_end);
        defer allocator.free(anchors);

        if (anchors.len == 0) {
            // No unique common lines found; fall back to Myers
            try fallbackMyersDiff(allocator, old_lines, new_lines, adj_old_start, adj_old_end, adj_new_start, adj_new_end, edits);
        } else {
            // Recursively diff between anchors
            var prev_old: usize = adj_old_start;
            var prev_new: usize = adj_new_start;

            for (anchors) |anchor| {
                // Diff the region before this anchor
                try patienceDiffRecursive(allocator, old_lines, new_lines, prev_old, anchor.old_idx, prev_new, anchor.new_idx, edits);

                // The anchor itself is an equal line
                try edits.append(.equal);

                prev_old = anchor.old_idx + 1;
                prev_new = anchor.new_idx + 1;
            }

            // Diff the region after the last anchor
            try patienceDiffRecursive(allocator, old_lines, new_lines, prev_old, adj_old_end, prev_new, adj_new_end, edits);
        }
    }

    // Add suffix matches
    for (0..suffix_len) |_| {
        try edits.append(.equal);
    }
}

/// An anchor point: a unique line that appears exactly once in both old and new.
const Anchor = struct {
    old_idx: usize,
    new_idx: usize,
};

/// Find anchor points using patience sorting.
/// 1. Find unique lines in old and new
/// 2. Find their longest common subsequence using patience sorting
fn findAnchors(
    allocator: std.mem.Allocator,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    old_start: usize,
    old_end: usize,
    new_start: usize,
    new_end: usize,
) ![]Anchor {
    // Count line occurrences in old
    var old_counts = std.StringHashMap(OccInfo).init(allocator);
    defer old_counts.deinit();

    for (old_start..old_end) |i| {
        const line = old_lines[i];
        if (old_counts.getPtr(line)) |info| {
            info.count += 1;
        } else {
            try old_counts.put(line, .{ .count = 1, .index = i });
        }
    }

    // Count line occurrences in new
    var new_counts = std.StringHashMap(OccInfo).init(allocator);
    defer new_counts.deinit();

    for (new_start..new_end) |i| {
        const line = new_lines[i];
        if (new_counts.getPtr(line)) |info| {
            info.count += 1;
        } else {
            try new_counts.put(line, .{ .count = 1, .index = i });
        }
    }

    // Find unique common lines (appear exactly once in both)
    var unique_pairs = std.array_list.Managed(Anchor).init(allocator);
    defer unique_pairs.deinit();

    // Iterate through new in order to build the sequence for LIS
    for (new_start..new_end) |ni| {
        const line = new_lines[ni];
        if (new_counts.get(line)) |new_info| {
            if (new_info.count != 1) continue;
            if (old_counts.get(line)) |old_info| {
                if (old_info.count != 1) continue;
                try unique_pairs.append(.{
                    .old_idx = old_info.index,
                    .new_idx = ni,
                });
            }
        }
    }

    if (unique_pairs.items.len == 0) {
        return allocator.alloc(Anchor, 0);
    }

    // Extract old_idx values for LIS (longest increasing subsequence via patience sorting)
    var old_indices = try allocator.alloc(usize, unique_pairs.items.len);
    defer allocator.free(old_indices);
    for (unique_pairs.items, 0..) |pair, i| {
        old_indices[i] = pair.old_idx;
    }

    const lis_indices = try longestIncreasingSubsequence(allocator, old_indices);
    defer allocator.free(lis_indices);

    // Build anchor list from LIS
    var anchors = try allocator.alloc(Anchor, lis_indices.len);
    for (lis_indices, 0..) |idx, i| {
        anchors[i] = unique_pairs.items[idx];
    }

    return anchors;
}

const OccInfo = struct {
    count: usize,
    index: usize,
};

/// Find the longest increasing subsequence using patience sorting.
/// Returns indices into the input array.
fn longestIncreasingSubsequence(allocator: std.mem.Allocator, values: []const usize) ![]usize {
    if (values.len == 0) return allocator.alloc(usize, 0);

    // Patience sorting: maintain piles
    var piles = std.array_list.Managed(usize).init(allocator); // top of each pile (value)
    defer piles.deinit();
    var pile_indices = std.array_list.Managed(usize).init(allocator); // index in values for top of pile
    defer pile_indices.deinit();
    var predecessors = try allocator.alloc(?usize, values.len);
    defer allocator.free(predecessors);
    @memset(predecessors, null);
    var pile_assignment = try allocator.alloc(usize, values.len); // which pile each value was placed on
    defer allocator.free(pile_assignment);

    for (values, 0..) |val, i| {
        // Binary search for the leftmost pile whose top >= val
        var lo: usize = 0;
        var hi: usize = piles.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (piles.items[mid] < val) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        if (lo == piles.items.len) {
            try piles.append(val);
            try pile_indices.append(i);
        } else {
            piles.items[lo] = val;
            pile_indices.items[lo] = i;
        }
        pile_assignment[i] = lo;

        // Set predecessor
        if (lo > 0) {
            predecessors[i] = pile_indices.items[lo - 1];
        }
    }

    // Reconstruct LIS by following predecessors
    const lis_len = piles.items.len;
    var result = try allocator.alloc(usize, lis_len);

    // Start from the last pile's top
    var curr: ?usize = pile_indices.items[lis_len - 1];
    var pos = lis_len;
    while (curr) |idx| {
        pos -= 1;
        result[pos] = idx;
        curr = predecessors[idx];
    }

    return result;
}

/// Fallback Myers diff for regions without unique anchors.
fn fallbackMyersDiff(
    allocator: std.mem.Allocator,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    old_start: usize,
    old_end: usize,
    new_start: usize,
    new_end: usize,
    edits: *std.array_list.Managed(EditOp),
) !void {
    const old_slice = old_lines[old_start..old_end];
    const new_slice = new_lines[new_start..new_end];

    const n: isize = @intCast(old_slice.len);
    const m: isize = @intCast(new_slice.len);
    const max_d: isize = n + m;

    if (max_d == 0) return;

    const v_size: usize = @intCast(2 * max_d + 1);
    const v_offset: usize = @intCast(max_d);

    var trace = std.array_list.Managed([]isize).init(allocator);
    defer {
        for (trace.items) |t| allocator.free(t);
        trace.deinit();
    }

    var v = try allocator.alloc(isize, v_size);
    defer allocator.free(v);
    @memset(v, 0);
    v[v_offset + 1] = 0;

    var found = false;
    var final_d: isize = 0;

    var d: isize = 0;
    while (d <= max_d) : (d += 1) {
        const v_copy = try allocator.alloc(isize, v_size);
        @memcpy(v_copy, v);
        try trace.append(v_copy);

        var k: isize = -d;
        while (k <= d) : (k += 2) {
            const k_idx: usize = @intCast(@as(isize, @intCast(v_offset)) + k);

            var x: isize = undefined;
            if (k == -d or (k != d and v[k_idx - 1] < v[k_idx + 1])) {
                x = v[k_idx + 1];
            } else {
                x = v[k_idx - 1] + 1;
            }
            var y: isize = x - k;

            while (x < n and y < m) {
                const xu: usize = @intCast(x);
                const yu: usize = @intCast(y);
                if (std.mem.eql(u8, old_slice[xu], new_slice[yu])) {
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
    var local_edits = std.array_list.Managed(EditOp).init(allocator);
    defer local_edits.deinit();

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

        while (bx > prev_x + @as(isize, if (prev_k == bk - 1) 1 else 0) and
            by > prev_y + @as(isize, if (prev_k == bk + 1) 1 else 0))
        {
            bx -= 1;
            by -= 1;
            try local_edits.append(.equal);
        }

        if (bd > 0) {
            if (prev_k == bk - 1) {
                bx -= 1;
                try local_edits.append(.delete);
            } else {
                by -= 1;
                try local_edits.append(.insert);
            }
        }
    }

    while (bx > 0 and by > 0) {
        bx -= 1;
        by -= 1;
        try local_edits.append(.equal);
    }

    // Reverse into edits
    var i = local_edits.items.len;
    while (i > 0) {
        i -= 1;
        try edits.append(local_edits.items[i]);
    }
}

/// Histogram diff: variation of patience that handles non-unique lines.
/// Uses occurrence counting to find low-frequency common lines as anchors.
pub fn histogramDiff(
    allocator: std.mem.Allocator,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
) ![]EditOp {
    var edits = std.array_list.Managed(EditOp).init(allocator);
    defer edits.deinit();

    try histogramDiffRecursive(allocator, old_lines, new_lines, 0, old_lines.len, 0, new_lines.len, &edits, 0);

    const result = try allocator.alloc(EditOp, edits.items.len);
    @memcpy(result, edits.items);
    return result;
}

fn histogramDiffRecursive(
    allocator: std.mem.Allocator,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    old_start: usize,
    old_end: usize,
    new_start: usize,
    new_end: usize,
    edits: *std.array_list.Managed(EditOp),
    depth: usize,
) !void {
    if (depth > 64) {
        // Prevent excessive recursion; fall back to simple edit
        try fallbackMyersDiff(allocator, old_lines, new_lines, old_start, old_end, new_start, new_end, edits);
        return;
    }

    // Skip common prefix and suffix
    var prefix_len: usize = 0;
    while (old_start + prefix_len < old_end and
        new_start + prefix_len < new_end and
        std.mem.eql(u8, old_lines[old_start + prefix_len], new_lines[new_start + prefix_len]))
    {
        prefix_len += 1;
    }

    var suffix_len: usize = 0;
    while (old_start + prefix_len + suffix_len < old_end and
        new_start + prefix_len + suffix_len < new_end and
        std.mem.eql(u8, old_lines[old_end - 1 - suffix_len], new_lines[new_end - 1 - suffix_len]))
    {
        suffix_len += 1;
    }

    for (0..prefix_len) |_| {
        try edits.append(.equal);
    }

    const adj_old_start = old_start + prefix_len;
    const adj_old_end = old_end - suffix_len;
    const adj_new_start = new_start + prefix_len;
    const adj_new_end = new_end - suffix_len;

    if (adj_old_start >= adj_old_end and adj_new_start >= adj_new_end) {
        // Done
    } else if (adj_old_start >= adj_old_end) {
        for (0..adj_new_end - adj_new_start) |_| {
            try edits.append(.insert);
        }
    } else if (adj_new_start >= adj_new_end) {
        for (0..adj_old_end - adj_old_start) |_| {
            try edits.append(.delete);
        }
    } else {
        // Count occurrences in old region
        var old_counts = std.StringHashMap(usize).init(allocator);
        defer old_counts.deinit();

        for (adj_old_start..adj_old_end) |i| {
            const entry = old_counts.getOrPutValue(old_lines[i], 0) catch continue;
            entry.value_ptr.* += 1;
        }

        // Find the lowest-occurrence line that also appears in new
        var best_line: ?[]const u8 = null;
        var best_count: usize = std.math.maxInt(usize);
        var best_old_idx: usize = 0;
        var best_new_idx: usize = 0;

        for (adj_new_start..adj_new_end) |ni| {
            if (old_counts.get(new_lines[ni])) |count| {
                if (count < best_count) {
                    best_count = count;
                    best_line = new_lines[ni];
                    best_new_idx = ni;
                    // Find the corresponding position in old
                    for (adj_old_start..adj_old_end) |oi| {
                        if (std.mem.eql(u8, old_lines[oi], new_lines[ni])) {
                            best_old_idx = oi;
                            break;
                        }
                    }
                }
            }
        }

        if (best_line != null) {
            // Recursively diff before the anchor
            try histogramDiffRecursive(allocator, old_lines, new_lines, adj_old_start, best_old_idx, adj_new_start, best_new_idx, edits, depth + 1);
            // The anchor
            try edits.append(.equal);
            // Recursively diff after the anchor
            try histogramDiffRecursive(allocator, old_lines, new_lines, best_old_idx + 1, adj_old_end, best_new_idx + 1, adj_new_end, edits, depth + 1);
        } else {
            // No common lines found, output all as delete then insert
            try fallbackMyersDiff(allocator, old_lines, new_lines, adj_old_start, adj_old_end, adj_new_start, adj_new_end, edits);
        }
    }

    for (0..suffix_len) |_| {
        try edits.append(.equal);
    }
}

/// Minimal Myers diff: same as standard Myers but guaranteed minimal edit script.
/// (Standard Myers is already optimal; this is an alias.)
pub fn minimalDiff(
    allocator: std.mem.Allocator,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
) ![]EditOp {
    var edits = std.array_list.Managed(EditOp).init(allocator);
    defer edits.deinit();

    try fallbackMyersDiff(allocator, old_lines, new_lines, 0, old_lines.len, 0, new_lines.len, &edits);

    const result = try allocator.alloc(EditOp, edits.items.len);
    @memcpy(result, edits.items);
    return result;
}

/// Parse --diff-algorithm=<name> argument.
pub fn parseDiffAlgorithm(arg: []const u8) ?DiffAlgorithm {
    if (std.mem.eql(u8, arg, "--diff-algorithm=patience")) return .patience;
    if (std.mem.eql(u8, arg, "--diff-algorithm=histogram")) return .histogram;
    if (std.mem.eql(u8, arg, "--diff-algorithm=minimal")) return .minimal;
    if (std.mem.eql(u8, arg, "--diff-algorithm=myers")) return .myers;
    if (std.mem.eql(u8, arg, "--patience")) return .patience;
    if (std.mem.eql(u8, arg, "--histogram")) return .histogram;
    return null;
}

test "patienceDiff identical" {
    const old_lines = [_][]const u8{ "a", "b", "c" };
    const new_lines = [_][]const u8{ "a", "b", "c" };

    const ops = try patienceDiff(std.testing.allocator, &old_lines, &new_lines);
    defer std.testing.allocator.free(ops);

    try std.testing.expectEqual(@as(usize, 3), ops.len);
    for (ops) |op| {
        try std.testing.expect(op == .equal);
    }
}

test "patienceDiff insertion" {
    const old_lines = [_][]const u8{ "a", "c" };
    const new_lines = [_][]const u8{ "a", "b", "c" };

    const ops = try patienceDiff(std.testing.allocator, &old_lines, &new_lines);
    defer std.testing.allocator.free(ops);

    var inserts: usize = 0;
    var equals: usize = 0;
    for (ops) |op| {
        if (op == .insert) inserts += 1;
        if (op == .equal) equals += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), inserts);
    try std.testing.expectEqual(@as(usize, 2), equals);
}

test "patienceDiff deletion" {
    const old_lines = [_][]const u8{ "a", "b", "c" };
    const new_lines = [_][]const u8{ "a", "c" };

    const ops = try patienceDiff(std.testing.allocator, &old_lines, &new_lines);
    defer std.testing.allocator.free(ops);

    var deletes: usize = 0;
    var equals: usize = 0;
    for (ops) |op| {
        if (op == .delete) deletes += 1;
        if (op == .equal) equals += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), deletes);
    try std.testing.expectEqual(@as(usize, 2), equals);
}

test "histogramDiff identical" {
    const old_lines = [_][]const u8{ "a", "b", "c" };
    const new_lines = [_][]const u8{ "a", "b", "c" };

    const ops = try histogramDiff(std.testing.allocator, &old_lines, &new_lines);
    defer std.testing.allocator.free(ops);

    for (ops) |op| {
        try std.testing.expect(op == .equal);
    }
}

test "longestIncreasingSubsequence basic" {
    const values = [_]usize{ 3, 1, 4, 1, 5, 9, 2, 6 };
    const result = try longestIncreasingSubsequence(std.testing.allocator, &values);
    defer std.testing.allocator.free(result);

    // LIS should have length 4 (e.g., 1,4,5,9 or 1,4,5,6)
    try std.testing.expect(result.len >= 4);
}

test "longestIncreasingSubsequence empty" {
    const values = [_]usize{};
    const result = try longestIncreasingSubsequence(std.testing.allocator, &values);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "parseDiffAlgorithm" {
    try std.testing.expect(parseDiffAlgorithm("--diff-algorithm=patience").? == .patience);
    try std.testing.expect(parseDiffAlgorithm("--diff-algorithm=histogram").? == .histogram);
    try std.testing.expect(parseDiffAlgorithm("--patience").? == .patience);
    try std.testing.expect(parseDiffAlgorithm("--verbose") == null);
}
