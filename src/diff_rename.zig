const std = @import("std");
const tree_diff = @import("tree_diff.zig");

/// A detected rename/copy between files.
pub const RenameEntry = struct {
    old_path: []const u8,
    new_path: []const u8,
    similarity: usize, // 0-100
    is_copy: bool,
};

/// Result of rename/copy detection.
pub const RenameResult = struct {
    allocator: std.mem.Allocator,
    renames: std.array_list.Managed(RenameEntry),
    /// Remaining added files (not matched as renames)
    remaining_added: std.array_list.Managed([]const u8),
    /// Remaining deleted files (not matched as renames)
    remaining_deleted: std.array_list.Managed([]const u8),
    /// Owned strings
    strings: std.array_list.Managed([]u8),

    pub fn init(allocator: std.mem.Allocator) RenameResult {
        return .{
            .allocator = allocator,
            .renames = std.array_list.Managed(RenameEntry).init(allocator),
            .remaining_added = std.array_list.Managed([]const u8).init(allocator),
            .remaining_deleted = std.array_list.Managed([]const u8).init(allocator),
            .strings = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *RenameResult) void {
        self.renames.deinit();
        self.remaining_added.deinit();
        self.remaining_deleted.deinit();
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit();
    }
};

/// Options for rename/copy detection.
pub const RenameOptions = struct {
    /// Minimum similarity percentage (0-100) to consider a rename.
    threshold: usize = 50,
    /// Also detect copies (where old file still exists).
    detect_copies: bool = false,
    /// Maximum number of source/destination pairs to check.
    max_pairs: usize = 1000,
};

/// Hash value for a line of text.
const LineHash = u64;

/// Compute a hash for a line of text using FNV-1a.
fn hashLine(line: []const u8) LineHash {
    var h: u64 = 14695981039346656037;
    for (line) |byte| {
        h ^= @as(u64, byte);
        h *%= 1099511628211;
    }
    return h;
}

/// Compute similarity between two text contents using Jaccard similarity on line hashes.
/// Returns a value 0-100 representing percentage similarity.
pub fn computeSimilarity(allocator: std.mem.Allocator, old_content: []const u8, new_content: []const u8) !usize {
    if (old_content.len == 0 and new_content.len == 0) return 100;
    if (old_content.len == 0 or new_content.len == 0) return 0;

    // Hash lines from old content
    var old_hashes = std.AutoHashMap(LineHash, usize).init(allocator);
    defer old_hashes.deinit();

    var old_line_count: usize = 0;
    {
        var iter = std.mem.splitScalar(u8, old_content, '\n');
        while (iter.next()) |line| {
            if (iter.peek() == null and line.len == 0) break;
            const h = hashLine(line);
            const entry = old_hashes.getOrPutValue(h, 0) catch continue;
            entry.value_ptr.* += 1;
            old_line_count += 1;
        }
    }

    // Count matching lines from new content
    var matching: usize = 0;
    var new_line_count: usize = 0;
    {
        var iter = std.mem.splitScalar(u8, new_content, '\n');
        while (iter.next()) |line| {
            if (iter.peek() == null and line.len == 0) break;
            const h = hashLine(line);
            if (old_hashes.getPtr(h)) |count_ptr| {
                if (count_ptr.* > 0) {
                    matching += 1;
                    count_ptr.* -= 1;
                }
            }
            new_line_count += 1;
        }
    }

    // Jaccard similarity: matching / (old + new - matching)
    const union_size = old_line_count + new_line_count - matching;
    if (union_size == 0) return 100;

    return (matching * 100) / union_size;
}

/// Detect renames and optionally copies from a list of tree changes.
/// The content_fn callback is used to fetch file content by path.
pub fn detectRenames(
    allocator: std.mem.Allocator,
    changes: []const tree_diff.TreeChange,
    options: RenameOptions,
    /// Function to read blob content: fn(oid) -> ?[]const u8
    /// Caller is responsible for lifetime of returned data.
    content_reader: anytype,
) !RenameResult {
    var result = RenameResult.init(allocator);
    errdefer result.deinit();

    // Collect added and deleted files
    var added = std.array_list.Managed(usize).init(allocator);
    defer added.deinit();
    var deleted = std.array_list.Managed(usize).init(allocator);
    defer deleted.deinit();

    for (changes, 0..) |*change, idx| {
        switch (change.kind) {
            .added => try added.append(idx),
            .deleted => try deleted.append(idx),
            .modified => {},
        }
    }

    // Track which files have been matched
    var matched_added = std.AutoHashMap(usize, bool).init(allocator);
    defer matched_added.deinit();
    var matched_deleted = std.AutoHashMap(usize, bool).init(allocator);
    defer matched_deleted.deinit();

    // Compare each deleted file with each added file
    var pairs_checked: usize = 0;
    for (deleted.items) |del_idx| {
        if (matched_deleted.get(del_idx) != null) continue;
        const del_change = &changes[del_idx];

        // Read deleted file content
        const old_oid = del_change.old_oid orelse continue;
        const old_content = content_reader.readContent(&old_oid) orelse continue;
        defer content_reader.freeContent(old_content);

        var best_sim: usize = 0;
        var best_add_idx: ?usize = null;

        for (added.items) |add_idx| {
            if (matched_added.get(add_idx) != null) continue;
            const add_change = &changes[add_idx];

            pairs_checked += 1;
            if (pairs_checked > options.max_pairs) break;

            // Quick check: if sizes differ dramatically, skip
            const new_oid = add_change.new_oid orelse continue;
            const new_content = content_reader.readContent(&new_oid) orelse continue;
            defer content_reader.freeContent(new_content);

            // Size-based pre-filter
            const size_ratio = if (old_content.len > 0 and new_content.len > 0) blk: {
                const larger = @max(old_content.len, new_content.len);
                const smaller = @min(old_content.len, new_content.len);
                break :blk (smaller * 100) / larger;
            } else 0;

            // If size ratio is too low, similarity can't meet threshold
            if (size_ratio < options.threshold / 2) continue;

            const sim = computeSimilarity(allocator, old_content, new_content) catch continue;
            if (sim > best_sim) {
                best_sim = sim;
                best_add_idx = add_idx;
            }
        }

        if (best_sim >= options.threshold) {
            if (best_add_idx) |add_idx| {
                const add_change = &changes[add_idx];

                const old_path = try dupeStr(allocator, del_change.path);
                try result.strings.append(old_path);
                const new_path = try dupeStr(allocator, add_change.path);
                try result.strings.append(new_path);

                try result.renames.append(.{
                    .old_path = old_path,
                    .new_path = new_path,
                    .similarity = best_sim,
                    .is_copy = false,
                });

                try matched_added.put(add_idx, true);
                try matched_deleted.put(del_idx, true);
            }
        }
    }

    // Collect remaining unmatched files
    for (added.items) |add_idx| {
        if (matched_added.get(add_idx) == null) {
            try result.remaining_added.append(changes[add_idx].path);
        }
    }
    for (deleted.items) |del_idx| {
        if (matched_deleted.get(del_idx) == null) {
            try result.remaining_deleted.append(changes[del_idx].path);
        }
    }

    return result;
}

/// Format rename detection output in raw mode: "R<sim>\told\tnew"
pub fn formatRenameRaw(buf: []u8, entry: *const RenameEntry) []const u8 {
    const prefix: []const u8 = if (entry.is_copy) "C" else "R";
    const result = std.fmt.bufPrint(buf, "{s}{d:0>3}\t{s}\t{s}\n", .{
        prefix,
        entry.similarity,
        entry.old_path,
        entry.new_path,
    }) catch return "";
    return result;
}

/// Format unified diff headers for a rename.
pub fn formatRenameHeaders(buf: []u8, entry: *const RenameEntry) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    writer.print("diff --git a/{s} b/{s}\n", .{ entry.old_path, entry.new_path }) catch return "";
    writer.print("similarity index {d}%\n", .{entry.similarity}) catch return "";
    if (entry.is_copy) {
        writer.print("copy from {s}\n", .{entry.old_path}) catch return "";
        writer.print("copy to {s}\n", .{entry.new_path}) catch return "";
    } else {
        writer.print("rename from {s}\n", .{entry.old_path}) catch return "";
        writer.print("rename to {s}\n", .{entry.new_path}) catch return "";
    }

    return buf[0..stream.pos];
}

/// Parse -M[<n>] option for rename detection threshold.
pub fn parseRenameArg(arg: []const u8) ?RenameOptions {
    if (std.mem.eql(u8, arg, "-M") or std.mem.eql(u8, arg, "--find-renames")) {
        return .{ .threshold = 50 };
    }
    if (std.mem.startsWith(u8, arg, "-M")) {
        const val = arg[2..];
        const threshold = std.fmt.parseInt(usize, val, 10) catch return null;
        if (threshold > 100) return null;
        return .{ .threshold = threshold };
    }
    if (std.mem.startsWith(u8, arg, "--find-renames=")) {
        const val = arg["--find-renames=".len..];
        const threshold = std.fmt.parseInt(usize, val, 10) catch return null;
        if (threshold > 100) return null;
        return .{ .threshold = threshold };
    }
    return null;
}

/// Parse -C[<n>] option for copy detection.
pub fn parseCopyArg(arg: []const u8) ?RenameOptions {
    if (std.mem.eql(u8, arg, "-C")) {
        return .{ .threshold = 50, .detect_copies = true };
    }
    if (std.mem.startsWith(u8, arg, "-C")) {
        const val = arg[2..];
        const threshold = std.fmt.parseInt(usize, val, 10) catch return null;
        if (threshold > 100) return null;
        return .{ .threshold = threshold, .detect_copies = true };
    }
    return null;
}

/// Compute the common prefix and suffix of two paths.
/// Used for display: "dir/{old => new}"
pub fn formatRenamePath(buf: []u8, old_path: []const u8, new_path: []const u8) []const u8 {
    // Find common prefix up to the last '/'
    var common_prefix_len: usize = 0;
    var last_slash: usize = 0;
    const min_len = @min(old_path.len, new_path.len);

    for (0..min_len) |i| {
        if (old_path[i] != new_path[i]) break;
        if (old_path[i] == '/') last_slash = i + 1;
        common_prefix_len = i + 1;
    }

    // Find common suffix
    var common_suffix_len: usize = 0;
    {
        var oi = old_path.len;
        var ni = new_path.len;
        while (oi > common_prefix_len and ni > common_prefix_len) {
            oi -= 1;
            ni -= 1;
            if (old_path[oi] != new_path[ni]) break;
            common_suffix_len += 1;
        }
    }

    // If paths are identical (shouldn't happen but be safe)
    if (std.mem.eql(u8, old_path, new_path)) {
        const result = std.fmt.bufPrint(buf, "{s}", .{old_path}) catch return old_path;
        return result;
    }

    // Use last_slash as prefix boundary for cleaner output
    const prefix = old_path[0..last_slash];
    const old_unique = old_path[last_slash .. old_path.len - common_suffix_len];
    const new_unique = new_path[last_slash .. new_path.len - common_suffix_len];
    const suffix = old_path[old_path.len - common_suffix_len ..];

    if (prefix.len > 0 or suffix.len > 0) {
        const result = std.fmt.bufPrint(buf, "{s}{{{s} => {s}}}{s}", .{
            prefix,
            old_unique,
            new_unique,
            suffix,
        }) catch return old_path;
        return result;
    }

    const result = std.fmt.bufPrint(buf, "{s} => {s}", .{ old_path, new_path }) catch return old_path;
    return result;
}

fn dupeStr(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const copy = try allocator.alloc(u8, s.len);
    @memcpy(copy, s);
    return copy;
}

test "hashLine consistency" {
    const h1 = hashLine("hello world");
    const h2 = hashLine("hello world");
    const h3 = hashLine("different line");
    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != h3);
}

test "computeSimilarity identical" {
    const sim = try computeSimilarity(std.testing.allocator, "line1\nline2\nline3\n", "line1\nline2\nline3\n");
    try std.testing.expectEqual(@as(usize, 100), sim);
}

test "computeSimilarity completely different" {
    const sim = try computeSimilarity(std.testing.allocator, "aaa\nbbb\nccc\n", "xxx\nyyy\nzzz\n");
    try std.testing.expectEqual(@as(usize, 0), sim);
}

test "computeSimilarity partial" {
    const sim = try computeSimilarity(std.testing.allocator, "line1\nline2\nline3\nline4\n", "line1\nline2\nnew3\nnew4\n");
    try std.testing.expect(sim > 0);
    try std.testing.expect(sim < 100);
}

test "computeSimilarity empty" {
    const sim1 = try computeSimilarity(std.testing.allocator, "", "");
    try std.testing.expectEqual(@as(usize, 100), sim1);

    const sim2 = try computeSimilarity(std.testing.allocator, "", "hello\n");
    try std.testing.expectEqual(@as(usize, 0), sim2);
}

test "parseRenameArg" {
    {
        const opts = parseRenameArg("-M").?;
        try std.testing.expectEqual(@as(usize, 50), opts.threshold);
    }
    {
        const opts = parseRenameArg("-M75").?;
        try std.testing.expectEqual(@as(usize, 75), opts.threshold);
    }
    {
        const opts = parseRenameArg("--find-renames=80").?;
        try std.testing.expectEqual(@as(usize, 80), opts.threshold);
    }
    try std.testing.expect(parseRenameArg("--verbose") == null);
}

test "formatRenamePath simple" {
    var buf: [256]u8 = undefined;
    const result = formatRenamePath(&buf, "src/old.zig", "src/new.zig");
    try std.testing.expect(std.mem.indexOf(u8, result, "=>") != null);
}

test "formatRenameRaw" {
    var buf: [256]u8 = undefined;
    const entry = RenameEntry{
        .old_path = "old.txt",
        .new_path = "new.txt",
        .similarity = 95,
        .is_copy = false,
    };
    const result = formatRenameRaw(&buf, &entry);
    try std.testing.expect(std.mem.startsWith(u8, result, "R095"));
}
