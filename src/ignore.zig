const std = @import("std");

pub const Pattern = struct {
    pattern: []const u8,
    negated: bool,
    dir_only: bool,
    anchored: bool,
    owned: bool,
};

pub const IgnoreRules = struct {
    allocator: std.mem.Allocator,
    patterns: std.array_list.Managed(Pattern),
    /// Owned strings for patterns loaded from files.
    owned_data: std.array_list.Managed([]u8),

    pub fn init(allocator: std.mem.Allocator) IgnoreRules {
        return .{
            .allocator = allocator,
            .patterns = std.array_list.Managed(Pattern).init(allocator),
            .owned_data = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *IgnoreRules) void {
        for (self.owned_data.items) |d| {
            self.allocator.free(d);
        }
        self.owned_data.deinit();
        self.patterns.deinit();
    }

    /// Load patterns from a file (e.g., .gitignore or .git/info/exclude).
    pub fn loadFile(self: *IgnoreRules, path: []const u8) !void {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size == 0) return;
        if (stat.size > 1024 * 1024) return error.FileTooLarge;

        const data = try self.allocator.alloc(u8, stat.size);
        errdefer self.allocator.free(data);
        const n = try file.readAll(data);
        if (n == 0) {
            self.allocator.free(data);
            return;
        }
        try self.owned_data.append(data);

        var lines = std.mem.splitScalar(u8, data[0..n], '\n');
        while (lines.next()) |line| {
            self.addPatternLine(line) catch continue;
        }
    }

    /// Load .gitignore from a directory path.
    pub fn loadGitignore(self: *IgnoreRules, dir_path: []const u8) !void {
        var path_buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&path_buf);
        const writer = stream.writer();
        try writer.writeAll(dir_path);
        try writer.writeAll("/.gitignore");
        const path = path_buf[0..stream.pos];
        try self.loadFile(path);
    }

    /// Load .git/info/exclude from a git_dir path.
    pub fn loadExclude(self: *IgnoreRules, git_dir: []const u8) !void {
        var path_buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&path_buf);
        const writer = stream.writer();
        try writer.writeAll(git_dir);
        try writer.writeAll("/info/exclude");
        const path = path_buf[0..stream.pos];
        try self.loadFile(path);
    }

    fn addPatternLine(self: *IgnoreRules, raw_line: []const u8) !void {
        var line = std.mem.trimRight(u8, raw_line, "\r ");

        // Skip empty lines and comments
        if (line.len == 0) return;
        if (line[0] == '#') return;

        var negated = false;
        if (line[0] == '!') {
            negated = true;
            line = line[1..];
            if (line.len == 0) return;
        }

        var dir_only = false;
        if (line.len > 0 and line[line.len - 1] == '/') {
            dir_only = true;
            line = line[0 .. line.len - 1];
            if (line.len == 0) return;
        }

        // Anchored if contains '/' (but not just trailing which we already removed)
        var anchored = false;
        if (line[0] == '/') {
            anchored = true;
            line = line[1..];
            if (line.len == 0) return;
        } else if (std.mem.indexOfScalar(u8, line, '/') != null) {
            anchored = true;
        }

        try self.patterns.append(.{
            .pattern = line,
            .negated = negated,
            .dir_only = dir_only,
            .anchored = anchored,
            .owned = false,
        });
    }

    /// Check if a given relative path should be ignored.
    /// `is_dir` indicates whether the path is a directory.
    pub fn isIgnored(self: *const IgnoreRules, path: []const u8, is_dir: bool) bool {
        var ignored = false;

        for (self.patterns.items) |*pat| {
            if (pat.dir_only and !is_dir) continue;

            if (matchPattern(pat.pattern, path, pat.anchored)) {
                ignored = !pat.negated;
            }
        }

        return ignored;
    }
};

/// Match a gitignore pattern against a path.
fn matchPattern(pattern: []const u8, path: []const u8, anchored: bool) bool {
    // Handle ** patterns
    if (std.mem.startsWith(u8, pattern, "**/")) {
        // Match in any directory
        const rest = pattern[3..];
        if (globMatch(rest, path)) return true;
        // Try matching after each '/' in path
        var i: usize = 0;
        while (i < path.len) {
            if (path[i] == '/') {
                if (globMatch(rest, path[i + 1 ..])) return true;
            }
            i += 1;
        }
        return false;
    }

    if (std.mem.endsWith(u8, pattern, "/**")) {
        const prefix = pattern[0 .. pattern.len - 3];
        // Match directory and everything under it
        if (std.mem.startsWith(u8, path, prefix)) {
            if (path.len == prefix.len) return true;
            if (path.len > prefix.len and path[prefix.len] == '/') return true;
        }
        return false;
    }

    if (std.mem.indexOf(u8, pattern, "/**/")) |pos| {
        const before = pattern[0..pos];
        const after = pattern[pos + 4 ..];
        if (!std.mem.startsWith(u8, path, before)) return false;
        const remaining = path[before.len..];
        if (remaining.len > 0 and remaining[0] == '/') {
            // Try matching after at different levels
            var i: usize = 1;
            while (i <= remaining.len) {
                if (i == remaining.len or remaining[i] == '/') {
                    if (globMatch(after, remaining[i..])) return true;
                    if (i < remaining.len) {
                        if (globMatch(after, remaining[i + 1 ..])) return true;
                    }
                }
                i += 1;
            }
        }
        // Also match zero intermediate directories
        if (globMatch(after, remaining)) return true;
        if (remaining.len > 0 and remaining[0] == '/') {
            if (globMatch(after, remaining[1..])) return true;
        }
        return false;
    }

    if (anchored) {
        return globMatch(pattern, path);
    }

    // Unanchored: match against basename or full path
    if (globMatch(pattern, path)) return true;

    // Try matching against the basename
    const basename = blk: {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |last_slash| {
            break :blk path[last_slash + 1 ..];
        }
        break :blk path;
    };

    return globMatch(pattern, basename);
}

/// Simple glob matching supporting *, ?, and [].
fn globMatch(pattern: []const u8, text: []const u8) bool {
    return globMatchInner(pattern, text, 0);
}

fn globMatchInner(pattern: []const u8, text: []const u8, depth: usize) bool {
    if (depth > 100) return false; // prevent infinite recursion

    var pi: usize = 0;
    var ti: usize = 0;

    while (pi < pattern.len) {
        if (pattern[pi] == '*') {
            // Skip consecutive stars
            while (pi < pattern.len and pattern[pi] == '*') {
                pi += 1;
            }
            if (pi == pattern.len) {
                // Trailing * matches everything except /
                while (ti < text.len) {
                    if (text[ti] == '/') return false;
                    ti += 1;
                }
                return true;
            }
            // Try matching rest of pattern at each position
            while (ti <= text.len) {
                if (globMatchInner(pattern[pi..], text[ti..], depth + 1)) return true;
                if (ti >= text.len) break;
                if (text[ti] == '/') break; // * doesn't match /
                ti += 1;
            }
            return false;
        } else if (pattern[pi] == '?') {
            if (ti >= text.len or text[ti] == '/') return false;
            pi += 1;
            ti += 1;
        } else if (pattern[pi] == '[') {
            if (ti >= text.len) return false;
            // Character class
            pi += 1;
            var negate = false;
            if (pi < pattern.len and (pattern[pi] == '!' or pattern[pi] == '^')) {
                negate = true;
                pi += 1;
            }
            var matched = false;
            var first = true;
            while (pi < pattern.len and (first or pattern[pi] != ']')) {
                first = false;
                if (pi + 2 < pattern.len and pattern[pi + 1] == '-') {
                    const lo = pattern[pi];
                    const hi = pattern[pi + 2];
                    if (text[ti] >= lo and text[ti] <= hi) matched = true;
                    pi += 3;
                } else {
                    if (text[ti] == pattern[pi]) matched = true;
                    pi += 1;
                }
            }
            if (pi < pattern.len and pattern[pi] == ']') pi += 1;
            if (negate) matched = !matched;
            if (!matched) return false;
            ti += 1;
        } else {
            // Literal character
            if (ti >= text.len) return false;
            if (pattern[pi] != text[ti]) return false;
            pi += 1;
            ti += 1;
        }
    }

    return ti == text.len;
}
