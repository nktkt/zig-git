const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_diff = @import("tree_diff.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

// ANSI color codes for output
const COLOR_RED = "\x1b[31m";
const COLOR_MAGENTA = "\x1b[35m";
const COLOR_GREEN = "\x1b[32m";
const COLOR_CYAN = "\x1b[36m";
const COLOR_BOLD = "\x1b[1m";
const COLOR_RESET = "\x1b[0m";
const COLOR_SEP = "\x1b[36m";

/// Options for the grep command.
pub const GrepOptions = struct {
    pattern: ?[]const u8 = null,
    commit_ref: ?[]const u8 = null,
    show_line_numbers: bool = true,
    case_insensitive: bool = false,
    count_only: bool = false,
    files_only: bool = false,
    color: bool = true,
    path_patterns: std.array_list.Managed([]const u8),
    invert_match: bool = false,
    max_count: usize = 0, // 0 = unlimited

    pub fn init(allocator: std.mem.Allocator) GrepOptions {
        return .{
            .path_patterns = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *GrepOptions) void {
        self.path_patterns.deinit();
    }
};

/// Result of a grep match on a single file.
pub const GrepFileResult = struct {
    path: []const u8,
    match_count: usize,
    lines: std.array_list.Managed(GrepMatchLine),

    pub fn deinit(self: *GrepFileResult) void {
        self.lines.deinit();
    }
};

/// A single matching line.
pub const GrepMatchLine = struct {
    line_number: usize,
    content: []const u8,
    match_start: usize,
    match_end: usize,
};

/// A match result with start and end positions.
pub const MatchResult = struct {
    start: usize,
    end: usize,
};

/// Compiled pattern for matching.
pub const CompiledPattern = struct {
    raw: []const u8,
    case_insensitive: bool,
    /// Pre-lowered version of the raw pattern (for case-insensitive matching).
    lowered: [512]u8 = undefined,
    lowered_len: usize = 0,
    /// Whether the pattern contains special characters (. or *).
    has_wildcards: bool = false,

    pub fn compile(pattern: []const u8, case_insensitive: bool) CompiledPattern {
        var cp = CompiledPattern{
            .raw = pattern,
            .case_insensitive = case_insensitive,
        };

        // Check for wildcards
        for (pattern) |c| {
            if (c == '.' or c == '*') {
                cp.has_wildcards = true;
                break;
            }
        }

        // Pre-lower the pattern for case-insensitive matching
        if (case_insensitive) {
            const len = @min(pattern.len, 512);
            for (pattern[0..len], 0..) |c, i| {
                cp.lowered[i] = toLower(c);
            }
            cp.lowered_len = len;
        }

        return cp;
    }

    /// Try to match the pattern against a line. Returns the start/end of the first match,
    /// or null if no match.
    pub fn findMatch(self: *const CompiledPattern, line: []const u8) ?MatchResult {
        if (self.has_wildcards) {
            return self.findWildcardMatch(line);
        }
        return self.findSimpleMatch(line);
    }

    /// Simple substring search.
    fn findSimpleMatch(self: *const CompiledPattern, line: []const u8) ?MatchResult {
        if (self.raw.len == 0) return .{ .start = 0, .end = 0 };
        if (line.len < self.raw.len) return null;

        const limit = line.len - self.raw.len + 1;
        var i: usize = 0;
        while (i < limit) : (i += 1) {
            if (self.matchAt(line, i)) {
                return .{ .start = i, .end = i + self.raw.len };
            }
        }
        return null;
    }

    /// Check if pattern matches at position in line.
    fn matchAt(self: *const CompiledPattern, line: []const u8, pos: usize) bool {
        if (pos + self.raw.len > line.len) return false;
        if (self.case_insensitive) {
            for (self.raw, 0..) |pc, i| {
                if (toLower(pc) != toLower(line[pos + i])) return false;
            }
        } else {
            for (self.raw, 0..) |pc, i| {
                if (pc != line[pos + i]) return false;
            }
        }
        return true;
    }

    /// Wildcard matching with '.' (any char) and '*' (zero or more of preceding).
    fn findWildcardMatch(self: *const CompiledPattern, line: []const u8) ?MatchResult {
        // Try matching the pattern starting at every position in the line
        var start: usize = 0;
        while (start <= line.len) : (start += 1) {
            if (self.wildcardMatchFrom(line, start)) |end| {
                return .{ .start = start, .end = end };
            }
        }
        return null;
    }

    /// Try to match the full pattern starting at `start` in `line`.
    /// Returns the end position of the match, or null if no match.
    fn wildcardMatchFrom(self: *const CompiledPattern, line: []const u8, start: usize) ?usize {
        var pi: usize = 0; // pattern index
        var li: usize = start; // line index

        while (pi < self.raw.len) {
            // Check for '*' modifier on next character
            if (pi + 1 < self.raw.len and self.raw[pi + 1] == '*') {
                const pat_char = self.raw[pi];
                pi += 2; // consume char and '*'

                // Try matching zero or more of pat_char
                // Greedy: try as many as possible, then backtrack
                var count: usize = 0;
                while (li + count < line.len and self.charMatches(pat_char, line[li + count])) {
                    count += 1;
                }

                // Try from longest match to shortest
                var c: usize = count + 1;
                while (c > 0) {
                    c -= 1;
                    // Try to match rest of pattern from here
                    const sub_pattern = CompiledPattern{
                        .raw = self.raw[pi..],
                        .case_insensitive = self.case_insensitive,
                        .has_wildcards = self.has_wildcards,
                    };
                    if (sub_pattern.wildcardMatchFrom(line, li + c)) |end| {
                        return end;
                    }
                }
                return null;
            }

            // No '*' modifier
            if (li >= line.len) return null;

            if (self.raw[pi] == '.') {
                // '.' matches any single character
                pi += 1;
                li += 1;
            } else if (self.charMatches(self.raw[pi], line[li])) {
                pi += 1;
                li += 1;
            } else {
                return null;
            }
        }

        return li;
    }

    fn charMatches(self: *const CompiledPattern, pat_char: u8, line_char: u8) bool {
        if (pat_char == '.') return true;
        if (self.case_insensitive) {
            return toLower(pat_char) == toLower(line_char);
        }
        return pat_char == line_char;
    }
};

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

/// Check if data is likely binary (contains null bytes in first 8000 bytes).
fn isBinaryData(data: []const u8) bool {
    const check_len = @min(data.len, 8000);
    for (data[0..check_len]) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

/// Check if a path matches the given path patterns.
fn pathMatchesPatterns(path: []const u8, patterns: []const []const u8) bool {
    if (patterns.len == 0) return true; // No patterns means match all

    for (patterns) |pattern| {
        if (pathMatchesGlob(path, pattern)) return true;
    }
    return false;
}

/// Simple glob matching for path patterns.
/// Supports '*' as a wildcard matching any characters within a path component.
fn pathMatchesGlob(path: []const u8, pattern: []const u8) bool {
    // Simple prefix/suffix matching
    if (pattern.len == 0) return true;

    // Check for simple prefix match
    if (std.mem.startsWith(u8, path, pattern)) return true;

    // Check if the filename part matches
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos|
        path[pos + 1 ..]
    else
        path;

    if (std.mem.eql(u8, basename, pattern)) return true;

    // Check for extension match (e.g., "*.zig")
    if (pattern.len > 1 and pattern[0] == '*') {
        if (std.mem.endsWith(u8, path, pattern[1..])) return true;
    }

    // Check directory match
    if (std.mem.endsWith(u8, pattern, "/")) {
        if (std.mem.startsWith(u8, path, pattern)) return true;
    }

    return false;
}

/// Entry point for the grep command.
pub fn runGrep(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = GrepOptions.init(allocator);
    defer opts.deinit();

    // Parse arguments
    var saw_dashdash = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (saw_dashdash) {
            try opts.path_patterns.append(arg);
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            saw_dashdash = true;
        } else if (std.mem.eql(u8, arg, "-n")) {
            opts.show_line_numbers = true;
        } else if (std.mem.eql(u8, arg, "-i")) {
            opts.case_insensitive = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            opts.count_only = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--files-with-matches")) {
            opts.files_only = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--invert-match")) {
            opts.invert_match = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.color = false;
        } else if (std.mem.eql(u8, arg, "--color")) {
            opts.color = true;
        } else if (std.mem.startsWith(u8, arg, "-m")) {
            const val = arg[2..];
            if (val.len > 0) {
                opts.max_count = std.fmt.parseInt(usize, val, 10) catch 0;
            } else {
                i += 1;
                if (i < args.len) {
                    opts.max_count = std.fmt.parseInt(usize, args[i], 10) catch 0;
                }
            }
        } else if (std.mem.startsWith(u8, arg, "--max-count=")) {
            opts.max_count = std.fmt.parseInt(usize, arg["--max-count=".len..], 10) catch 0;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (opts.pattern == null) {
                opts.pattern = arg;
            } else if (opts.commit_ref == null) {
                // Check if this looks like a commit ref or a path
                // Try resolving as a ref first
                if (repo.resolveRef(allocator, arg)) |_| {
                    opts.commit_ref = arg;
                } else |_| {
                    // Not a ref, treat as a path pattern
                    try opts.path_patterns.append(arg);
                }
            } else {
                try opts.path_patterns.append(arg);
            }
        }
    }

    if (opts.pattern == null) {
        try stderr_file.writeAll("fatal: no pattern given\n");
        try stderr_file.writeAll("usage: zig-git grep [<options>] <pattern> [<rev>] [-- <pathspec>...]\n");
        std.process.exit(1);
    }

    // Compile the pattern
    const compiled = CompiledPattern.compile(opts.pattern.?, opts.case_insensitive);

    // Determine the tree to search
    const ref_str = opts.commit_ref orelse "HEAD";
    const head_oid = repo.resolveRef(allocator, ref_str) catch |err| {
        switch (err) {
            error.ObjectNotFound => {
                if (opts.commit_ref != null) {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "fatal: ambiguous argument '{s}': unknown revision\n", .{ref_str}) catch
                        "fatal: unknown revision\n";
                    try stderr_file.writeAll(msg);
                    std.process.exit(128);
                }
                // Empty repo
                return;
            },
            else => return err,
        }
    };

    // Read the commit to get the tree
    var commit_obj = try repo.readObject(allocator, &head_oid);
    defer commit_obj.deinit();

    if (commit_obj.obj_type != .commit) {
        try stderr_file.writeAll("fatal: not a commit object\n");
        std.process.exit(128);
    }

    const tree_oid = try tree_diff.getCommitTreeOid(commit_obj.data);

    // Walk the tree and search each blob
    var total_matches: usize = 0;
    try searchTree(repo, allocator, &tree_oid, "", &compiled, &opts, &total_matches);

    if (total_matches == 0) {
        std.process.exit(1);
    }
}

/// Recursively search all blobs in a tree.
fn searchTree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    tree_oid: *const types.ObjectId,
    prefix: []const u8,
    pattern: *const CompiledPattern,
    opts: *const GrepOptions,
    total_matches: *usize,
) !void {
    var obj = try repo.readObject(allocator, tree_oid);
    defer obj.deinit();

    if (obj.obj_type != .tree) return error.NotATree;

    // Parse tree entries
    var pos: usize = 0;
    const data = obj.data;

    while (pos < data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse return error.InvalidTreeEntry;
        const mode = data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, data, space_pos + 1, 0) orelse return error.InvalidTreeEntry;
        const name = data[space_pos + 1 .. null_pos];

        if (null_pos + 1 + types.OID_RAW_LEN > data.len) return error.InvalidTreeEntry;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, data[null_pos + 1 ..][0..types.OID_RAW_LEN]);
        pos = null_pos + 1 + types.OID_RAW_LEN;

        // Build full path
        var path_buf: [4096]u8 = undefined;
        const full_path = buildPath(&path_buf, prefix, name);

        if (std.mem.eql(u8, mode, "40000")) {
            // Subdirectory: recurse
            try searchTree(repo, allocator, &oid, full_path, pattern, opts, total_matches);
        } else {
            // Check path filters
            if (!pathMatchesPatterns(full_path, opts.path_patterns.items)) continue;

            // Blob: read and search
            searchBlob(repo, allocator, &oid, full_path, pattern, opts, total_matches) catch continue;
        }
    }
}

/// Search a single blob for the pattern.
fn searchBlob(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    blob_oid: *const types.ObjectId,
    file_path: []const u8,
    pattern: *const CompiledPattern,
    opts: *const GrepOptions,
    total_matches: *usize,
) !void {
    var blob_obj = try repo.readObject(allocator, blob_oid);
    defer blob_obj.deinit();

    if (blob_obj.obj_type != .blob) return;

    const data = blob_obj.data;

    // Skip binary files
    if (isBinaryData(data)) return;

    // Search line by line
    var line_num: usize = 1;
    var file_match_count: usize = 0;
    var file_printed = false;

    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        defer line_num += 1;

        // Check max count
        if (opts.max_count > 0 and file_match_count >= opts.max_count) break;

        const match_result = pattern.findMatch(line);
        const is_match = if (opts.invert_match) match_result == null else match_result != null;

        if (is_match) {
            file_match_count += 1;
            total_matches.* += 1;

            if (opts.files_only) {
                if (!file_printed) {
                    file_printed = true;
                    writeGrepFilePath(file_path, opts.color) catch {};
                }
                break; // Only need one match per file for -l mode
            }

            if (opts.count_only) {
                // Don't print individual lines in count mode
                continue;
            }

            // Print the matching line
            writeGrepMatch(file_path, line_num, line, match_result, opts) catch {};
        }
    }

    if (opts.count_only and file_match_count > 0) {
        writeGrepCount(file_path, file_match_count, opts.color) catch {};
    }
}

/// Write a grep match line to stdout.
fn writeGrepMatch(
    file_path: []const u8,
    line_num: usize,
    line: []const u8,
    match_result: ?MatchResult,
    opts: *const GrepOptions,
) !void {
    var buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    // File path
    if (opts.color) {
        try writer.writeAll(COLOR_MAGENTA);
    }
    try writer.writeAll(file_path);
    if (opts.color) {
        try writer.writeAll(COLOR_RESET);
        try writer.writeAll(COLOR_SEP);
    }
    try writer.writeByte(':');
    if (opts.color) {
        try writer.writeAll(COLOR_RESET);
    }

    // Line number
    if (opts.show_line_numbers) {
        if (opts.color) {
            try writer.writeAll(COLOR_GREEN);
        }
        try writer.print("{d}", .{line_num});
        if (opts.color) {
            try writer.writeAll(COLOR_RESET);
            try writer.writeAll(COLOR_SEP);
        }
        try writer.writeByte(':');
        if (opts.color) {
            try writer.writeAll(COLOR_RESET);
        }
    }

    // Content with highlighting
    if (opts.color and match_result != null and !opts.invert_match) {
        const m = match_result.?;
        if (m.start <= line.len and m.end <= line.len) {
            try writer.writeAll(line[0..m.start]);
            try writer.writeAll(COLOR_RED);
            try writer.writeAll(COLOR_BOLD);
            try writer.writeAll(line[m.start..m.end]);
            try writer.writeAll(COLOR_RESET);
            try writer.writeAll(line[m.end..]);
        } else {
            try writer.writeAll(line);
        }
    } else {
        try writer.writeAll(line);
    }

    try writer.writeByte('\n');

    try stdout_file.writeAll(buf[0..stream.pos]);
}

/// Write a file path for -l mode.
fn writeGrepFilePath(file_path: []const u8, color: bool) !void {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    if (color) {
        try writer.writeAll(COLOR_MAGENTA);
    }
    try writer.writeAll(file_path);
    if (color) {
        try writer.writeAll(COLOR_RESET);
    }
    try writer.writeByte('\n');

    try stdout_file.writeAll(buf[0..stream.pos]);
}

/// Write a count line for -c mode.
fn writeGrepCount(file_path: []const u8, count: usize, color: bool) !void {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    if (color) {
        try writer.writeAll(COLOR_MAGENTA);
    }
    try writer.writeAll(file_path);
    if (color) {
        try writer.writeAll(COLOR_RESET);
        try writer.writeAll(COLOR_SEP);
    }
    try writer.writeByte(':');
    if (color) {
        try writer.writeAll(COLOR_RESET);
    }
    try writer.print("{d}", .{count});
    try writer.writeByte('\n');

    try stdout_file.writeAll(buf[0..stream.pos]);
}

/// Build a full path from prefix and name into a buffer.
fn buildPath(buf: []u8, prefix: []const u8, name: []const u8) []const u8 {
    if (prefix.len == 0) {
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    @memcpy(buf[0..prefix.len], prefix);
    buf[prefix.len] = '/';
    @memcpy(buf[prefix.len + 1 ..][0..name.len], name);
    return buf[0 .. prefix.len + 1 + name.len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "CompiledPattern simple match" {
    const cp = CompiledPattern.compile("hello", false);
    const m = cp.findMatch("say hello world");
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 4), m.?.start);
    try std.testing.expectEqual(@as(usize, 9), m.?.end);
}

test "CompiledPattern case insensitive" {
    const cp = CompiledPattern.compile("HELLO", true);
    const m = cp.findMatch("say hello world");
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 4), m.?.start);
}

test "CompiledPattern no match" {
    const cp = CompiledPattern.compile("xyz", false);
    const m = cp.findMatch("say hello world");
    try std.testing.expect(m == null);
}

test "CompiledPattern dot wildcard" {
    const cp = CompiledPattern.compile("h.llo", false);
    const m = cp.findMatch("say hello world");
    try std.testing.expect(m != null);
    try std.testing.expectEqual(@as(usize, 4), m.?.start);
}

test "CompiledPattern star wildcard" {
    const cp = CompiledPattern.compile("he.*o", false);
    const m = cp.findMatch("say hello world");
    try std.testing.expect(m != null);
}

test "isBinaryData" {
    try std.testing.expect(!isBinaryData("hello world"));
    try std.testing.expect(isBinaryData("hello\x00world"));
}

test "pathMatchesGlob" {
    try std.testing.expect(pathMatchesGlob("src/main.zig", "*.zig"));
    try std.testing.expect(pathMatchesGlob("src/main.zig", "main.zig"));
    try std.testing.expect(pathMatchesGlob("src/main.zig", "src/"));
    try std.testing.expect(!pathMatchesGlob("src/main.zig", "*.rs"));
}

test "buildPath empty prefix" {
    var buf: [256]u8 = undefined;
    const result = buildPath(&buf, "", "file.txt");
    try std.testing.expectEqualStrings("file.txt", result);
}

test "buildPath with prefix" {
    var buf: [256]u8 = undefined;
    const result = buildPath(&buf, "src", "file.txt");
    try std.testing.expectEqualStrings("src/file.txt", result);
}
