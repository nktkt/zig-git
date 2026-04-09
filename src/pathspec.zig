const std = @import("std");

/// Advanced pathspec matching for git commands.
///
/// Pathspecs are patterns used to limit paths in git commands.
/// They can have "magic" prefixes:
///   :(glob)pattern     — Use glob matching (default)
///   :(literal)pattern  — Match the pattern literally
///   :(icase)pattern    — Case-insensitive matching
///   :(top)pattern      — Match from repository root regardless of cwd
///   :(exclude)pattern  — Exclude matching files (also :! shorthand)
///   :(attr:text)pattern — Match files with attribute
///
/// Glob patterns:
///   *      — match any characters within a path component
///   ?      — match a single character
///   [abc]  — match character class
///   **     — match any number of path components (any directory depth)

/// Pathspec magic flags.
pub const Magic = packed struct {
    glob: bool = true,
    literal: bool = false,
    icase: bool = false,
    top: bool = false,
    exclude: bool = false,
    attr: bool = false,
    _pad: u2 = 0,
};

/// A parsed pathspec.
pub const Pathspec = struct {
    /// The raw pattern string (after magic prefix removal).
    pattern: []const u8,
    /// Magic flags.
    magic: Magic,
    /// Attribute value for :(attr:...) magic.
    attr_value: ?[]const u8,
    /// Original input string.
    original: []const u8,

    /// Check if a path matches this pathspec.
    pub fn matches(self: *const Pathspec, path: []const u8) bool {
        if (self.magic.exclude) {
            // Exclude patterns: match means the path should be excluded.
            // The caller inverts the result.
            return matchPattern(self.pattern, path, self.magic);
        }
        return matchPattern(self.pattern, path, self.magic);
    }

    /// Check if this pathspec is an exclude pattern.
    pub fn isExclude(self: *const Pathspec) bool {
        return self.magic.exclude;
    }

    /// Check if this pathspec is a prefix match (no glob characters).
    pub fn isPrefix(self: *const Pathspec) bool {
        if (self.magic.literal) return true;
        for (self.pattern) |c| {
            switch (c) {
                '*', '?', '[' => return false,
                else => {},
            }
        }
        return true;
    }

    /// Get the longest literal prefix of the pattern.
    /// This is useful for optimizing directory traversal.
    pub fn literalPrefix(self: *const Pathspec) []const u8 {
        if (self.magic.literal) return self.pattern;
        for (self.pattern, 0..) |c, i| {
            switch (c) {
                '*', '?', '[' => return self.pattern[0..i],
                else => {},
            }
        }
        return self.pattern;
    }
};

/// Parse a single pathspec string.
pub fn parsePathspec(spec: []const u8) Pathspec {
    if (spec.len == 0) {
        return .{
            .pattern = "",
            .magic = .{},
            .attr_value = null,
            .original = spec,
        };
    }

    // Check for :! or :^ shorthand (exclude)
    if (spec.len >= 2 and spec[0] == ':' and (spec[1] == '!' or spec[1] == '^')) {
        return .{
            .pattern = spec[2..],
            .magic = .{ .exclude = true },
            .attr_value = null,
            .original = spec,
        };
    }

    // Check for :(magic) long form
    if (spec.len >= 3 and spec[0] == ':' and spec[1] == '(') {
        if (std.mem.indexOfScalar(u8, spec[2..], ')')) |close_pos| {
            const magic_str = spec[2 .. 2 + close_pos];
            const pattern = spec[2 + close_pos + 1 ..];
            var magic = Magic{};
            var attr_val: ?[]const u8 = null;

            // Parse comma-separated magic words
            var magic_iter = std.mem.splitScalar(u8, magic_str, ',');
            while (magic_iter.next()) |word| {
                if (std.mem.eql(u8, word, "glob")) {
                    magic.glob = true;
                    magic.literal = false;
                } else if (std.mem.eql(u8, word, "literal")) {
                    magic.literal = true;
                    magic.glob = false;
                } else if (std.mem.eql(u8, word, "icase")) {
                    magic.icase = true;
                } else if (std.mem.eql(u8, word, "top")) {
                    magic.top = true;
                } else if (std.mem.eql(u8, word, "exclude")) {
                    magic.exclude = true;
                } else if (std.mem.startsWith(u8, word, "attr:")) {
                    magic.attr = true;
                    attr_val = word["attr:".len..];
                }
            }

            return .{
                .pattern = pattern,
                .magic = magic,
                .attr_value = attr_val,
                .original = spec,
            };
        }
    }

    // Plain pathspec
    return .{
        .pattern = spec,
        .magic = .{},
        .attr_value = null,
        .original = spec,
    };
}

/// Parse multiple pathspec strings.
pub fn parsePathspecs(allocator: std.mem.Allocator, args: []const []const u8) !PathspecList {
    var list = PathspecList.init(allocator);
    errdefer list.deinit();

    for (args) |arg| {
        try list.append(parsePathspec(arg));
    }

    return list;
}

/// Check if any pathspec in the list matches the given path.
/// Handles exclude patterns: returns true if path matches an include pattern
/// and does not match any exclude pattern.
pub fn matchesAny(pathspecs: []const Pathspec, path: []const u8) bool {
    if (pathspecs.len == 0) return true; // No pathspecs means match everything

    var matched = false;
    var has_includes = false;

    for (pathspecs) |*spec| {
        if (spec.isExclude()) {
            if (spec.matches(path)) return false; // Excluded
        } else {
            has_includes = true;
            if (spec.matches(path)) matched = true;
        }
    }

    // If there are only exclude patterns, default to matching
    if (!has_includes) return true;

    return matched;
}

/// Check if a path is under a pathspec's prefix.
/// Useful for pruning directory traversal.
pub fn isUnderPrefix(pathspecs: []const Pathspec, dir_path: []const u8) bool {
    if (pathspecs.len == 0) return true;

    for (pathspecs) |*spec| {
        if (spec.isExclude()) continue;

        const prefix = spec.literalPrefix();
        if (prefix.len == 0) return true;

        // Check if the directory is a prefix of the pattern's prefix
        // or the pattern's prefix is a prefix of the directory
        if (std.mem.startsWith(u8, prefix, dir_path)) return true;
        if (std.mem.startsWith(u8, dir_path, prefix)) return true;
    }

    return false;
}

/// Pathspec list type.
pub const PathspecList = std.array_list.Managed(Pathspec);

// --- Pattern matching ---

fn matchPattern(pattern: []const u8, path: []const u8, magic: Magic) bool {
    if (magic.literal) {
        return matchLiteral(pattern, path, magic.icase);
    }
    return matchGlob(pattern, path, magic.icase);
}

fn matchLiteral(pattern: []const u8, path: []const u8, icase: bool) bool {
    if (icase) {
        return eqlIgnoreCase(pattern, path);
    }
    // Exact match or prefix match (pattern matches directory prefix)
    if (std.mem.eql(u8, pattern, path)) return true;
    // Check if path starts with pattern as a directory prefix
    if (path.len > pattern.len and std.mem.startsWith(u8, path, pattern) and path[pattern.len] == '/') {
        return true;
    }
    return false;
}

fn matchGlob(pattern: []const u8, path: []const u8, icase: bool) bool {
    return globMatch(pattern, path, icase);
}

/// Glob pattern matcher with support for *, ?, [charset], and **.
fn globMatch(pattern: []const u8, name: []const u8, icase: bool) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: ?usize = null;

    while (ni < name.len or pi < pattern.len) {
        if (pi < pattern.len) {
            const pc = pattern[pi];
            switch (pc) {
                '*' => {
                    // Check for **
                    if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                        // ** matches any number of path components
                        return matchDoublestar(pattern, pi, name, ni, icase);
                    }
                    // Single * matches within a path component (not /)
                    star_pi = pi;
                    star_ni = ni;
                    pi += 1;
                    continue;
                },
                '?' => {
                    if (ni < name.len and name[ni] != '/') {
                        pi += 1;
                        ni += 1;
                        continue;
                    }
                },
                '[' => {
                    if (ni < name.len) {
                        if (matchCharClass(pattern, &pi, name[ni], icase)) {
                            ni += 1;
                            continue;
                        }
                    }
                },
                else => {
                    if (ni < name.len and charEql(pc, name[ni], icase)) {
                        pi += 1;
                        ni += 1;
                        continue;
                    }
                },
            }
        }

        // Backtrack to star
        if (star_pi) |spi| {
            pi = spi + 1;
            star_ni.? += 1;
            ni = star_ni.?;
            if (ni <= name.len and (ni == name.len or name[ni - 1] != '/')) {
                continue;
            }
        }

        return false;
    }

    return true;
}

/// Match ** (double star) which matches across directory boundaries.
fn matchDoublestar(pattern: []const u8, star_pos: usize, name: []const u8, name_pos: usize, icase: bool) bool {
    // Skip the **
    var pi = star_pos + 2;

    // If ** is followed by /, skip the slash too
    if (pi < pattern.len and pattern[pi] == '/') {
        pi += 1;
    }

    // If ** is at end of pattern, match everything
    if (pi >= pattern.len) return true;

    // Try matching the rest of the pattern at every position
    var ni = name_pos;
    while (ni <= name.len) {
        if (globMatch(pattern[pi..], name[ni..], icase)) {
            return true;
        }
        if (ni < name.len) {
            ni += 1;
        } else {
            break;
        }
    }

    return false;
}

/// Match a character class pattern like [abc], [a-z], [!abc].
fn matchCharClass(pattern: []const u8, pi: *usize, c: u8, icase: bool) bool {
    pi.* += 1; // skip [
    if (pi.* >= pattern.len) return false;

    var negate = false;
    if (pattern[pi.*] == '!' or pattern[pi.*] == '^') {
        negate = true;
        pi.* += 1;
    }

    var matched = false;
    var first = true;
    while (pi.* < pattern.len and (first or pattern[pi.*] != ']')) {
        first = false;
        const start_c = pattern[pi.*];
        pi.* += 1;

        if (pi.* + 1 < pattern.len and pattern[pi.*] == '-' and pattern[pi.* + 1] != ']') {
            // Range: a-z
            pi.* += 1; // skip -
            const end_c = pattern[pi.*];
            pi.* += 1;

            const lc = if (icase) toLower(c) else c;
            const ls = if (icase) toLower(start_c) else start_c;
            const le = if (icase) toLower(end_c) else end_c;

            if (lc >= ls and lc <= le) matched = true;
        } else {
            if (charEql(start_c, c, icase)) matched = true;
        }
    }

    // Skip closing ]
    if (pi.* < pattern.len and pattern[pi.*] == ']') {
        pi.* += 1;
    }

    return if (negate) !matched else matched;
}

fn charEql(a: u8, b: u8, icase: bool) bool {
    if (icase) return toLower(a) == toLower(b);
    return a == b;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

/// Check if a string has any glob metacharacters.
pub fn hasGlobChars(s: []const u8) bool {
    for (s) |c| {
        switch (c) {
            '*', '?', '[' => return true,
            else => {},
        }
    }
    return false;
}

/// Normalize a path for pathspec matching (remove trailing slash, etc.).
pub fn normalizePath(buf: []u8, path: []const u8) []const u8 {
    if (path.len == 0) return "";

    var len = path.len;
    // Remove trailing slashes
    while (len > 0 and path[len - 1] == '/') {
        len -= 1;
    }

    // Remove leading ./
    var start: usize = 0;
    if (len >= 2 and path[0] == '.' and path[1] == '/') {
        start = 2;
    }

    const result_len = len - start;
    if (result_len > buf.len) return path[start..len];

    @memcpy(buf[0..result_len], path[start..len]);
    return buf[0..result_len];
}

// --- Tests ---

test "parsePathspec plain" {
    const spec = parsePathspec("src/main.zig");
    try std.testing.expectEqualStrings("src/main.zig", spec.pattern);
    try std.testing.expect(spec.magic.glob);
    try std.testing.expect(!spec.magic.exclude);
    try std.testing.expect(!spec.magic.icase);
}

test "parsePathspec exclude shorthand" {
    const spec = parsePathspec(":!*.tmp");
    try std.testing.expectEqualStrings("*.tmp", spec.pattern);
    try std.testing.expect(spec.magic.exclude);
}

test "parsePathspec exclude caret" {
    const spec = parsePathspec(":^vendor/");
    try std.testing.expectEqualStrings("vendor/", spec.pattern);
    try std.testing.expect(spec.magic.exclude);
}

test "parsePathspec magic long form" {
    const spec = parsePathspec(":(icase,glob)*.TXT");
    try std.testing.expectEqualStrings("*.TXT", spec.pattern);
    try std.testing.expect(spec.magic.icase);
    try std.testing.expect(spec.magic.glob);
}

test "parsePathspec literal" {
    const spec = parsePathspec(":(literal)src/*.zig");
    try std.testing.expectEqualStrings("src/*.zig", spec.pattern);
    try std.testing.expect(spec.magic.literal);
    try std.testing.expect(!spec.magic.glob);
}

test "parsePathspec top" {
    const spec = parsePathspec(":(top)src/");
    try std.testing.expectEqualStrings("src/", spec.pattern);
    try std.testing.expect(spec.magic.top);
}

test "parsePathspec attr" {
    const spec = parsePathspec(":(attr:text)*.md");
    try std.testing.expectEqualStrings("*.md", spec.pattern);
    try std.testing.expect(spec.magic.attr);
    try std.testing.expectEqualStrings("text", spec.attr_value.?);
}

test "Pathspec matches exact" {
    const spec = parsePathspec("src/main.zig");
    try std.testing.expect(spec.matches("src/main.zig"));
    try std.testing.expect(!spec.matches("src/other.zig"));
}

test "Pathspec matches glob star" {
    const spec = parsePathspec("src/*.zig");
    try std.testing.expect(spec.matches("src/main.zig"));
    try std.testing.expect(spec.matches("src/types.zig"));
    try std.testing.expect(!spec.matches("src/sub/main.zig"));
    try std.testing.expect(!spec.matches("lib/main.zig"));
}

test "Pathspec matches glob question" {
    const spec = parsePathspec("src/?.zig");
    try std.testing.expect(spec.matches("src/a.zig"));
    try std.testing.expect(!spec.matches("src/ab.zig"));
}

test "Pathspec matches doublestar" {
    const spec = parsePathspec("src/**/*.zig");
    try std.testing.expect(spec.matches("src/main.zig"));
    try std.testing.expect(spec.matches("src/sub/main.zig"));
    try std.testing.expect(spec.matches("src/a/b/c.zig"));
    try std.testing.expect(!spec.matches("lib/main.zig"));
}

test "Pathspec matches charset" {
    const spec = parsePathspec("[abc].txt");
    try std.testing.expect(spec.matches("a.txt"));
    try std.testing.expect(spec.matches("b.txt"));
    try std.testing.expect(!spec.matches("d.txt"));
}

test "Pathspec matches icase" {
    const spec = parsePathspec(":(icase)readme.md");
    try std.testing.expect(spec.matches("readme.md"));
    try std.testing.expect(spec.matches("README.md"));
    try std.testing.expect(spec.matches("README.MD"));
}

test "Pathspec matches literal" {
    const spec = parsePathspec(":(literal)src/*.zig");
    try std.testing.expect(spec.matches("src/*.zig"));
    try std.testing.expect(!spec.matches("src/main.zig"));
}

test "Pathspec isPrefix" {
    const spec1 = parsePathspec("src/main.zig");
    try std.testing.expect(spec1.isPrefix());

    const spec2 = parsePathspec("src/*.zig");
    try std.testing.expect(!spec2.isPrefix());

    const spec3 = parsePathspec(":(literal)src/*.zig");
    try std.testing.expect(spec3.isPrefix());
}

test "Pathspec literalPrefix" {
    const spec = parsePathspec("src/*.zig");
    try std.testing.expectEqualStrings("src/", spec.literalPrefix());

    const spec2 = parsePathspec("*.zig");
    try std.testing.expectEqualStrings("", spec2.literalPrefix());

    const spec3 = parsePathspec("src/main.zig");
    try std.testing.expectEqualStrings("src/main.zig", spec3.literalPrefix());
}

test "matchesAny" {
    const specs = [_]Pathspec{
        parsePathspec("src/*.zig"),
        parsePathspec(":!src/test.zig"),
    };
    try std.testing.expect(matchesAny(&specs, "src/main.zig"));
    try std.testing.expect(!matchesAny(&specs, "src/test.zig"));
    try std.testing.expect(!matchesAny(&specs, "lib/main.zig"));
}

test "matchesAny empty" {
    const empty = [_]Pathspec{};
    try std.testing.expect(matchesAny(&empty, "anything"));
}

test "isUnderPrefix" {
    const specs = [_]Pathspec{
        parsePathspec("src/*.zig"),
    };
    try std.testing.expect(isUnderPrefix(&specs, "src/"));
    try std.testing.expect(isUnderPrefix(&specs, "src"));
}

test "hasGlobChars" {
    try std.testing.expect(hasGlobChars("*.zig"));
    try std.testing.expect(hasGlobChars("src/[abc].zig"));
    try std.testing.expect(hasGlobChars("src/?.zig"));
    try std.testing.expect(!hasGlobChars("src/main.zig"));
}

test "normalizePath" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("src/main.zig", normalizePath(&buf, "src/main.zig"));
    try std.testing.expectEqualStrings("src", normalizePath(&buf, "src/"));
    try std.testing.expectEqualStrings("src/main.zig", normalizePath(&buf, "./src/main.zig"));
}

test "globMatch doublestar at end" {
    try std.testing.expect(globMatch("src/**", "src/a/b/c", false));
    try std.testing.expect(globMatch("src/**", "src/file.txt", false));
}

test "globMatch charset range" {
    try std.testing.expect(globMatch("[a-z].txt", "m.txt", false));
    try std.testing.expect(!globMatch("[a-z].txt", "M.txt", false));
    try std.testing.expect(globMatch("[a-z].txt", "M.txt", true));
}

test "globMatch negate charset" {
    try std.testing.expect(globMatch("[!abc].txt", "d.txt", false));
    try std.testing.expect(!globMatch("[!abc].txt", "a.txt", false));
}

test "parsePathspecs" {
    const args = [_][]const u8{ "src/*.zig", ":!test.zig" };
    var list = try parsePathspecs(std.testing.allocator, &args);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expect(!list.items[0].isExclude());
    try std.testing.expect(list.items[1].isExclude());
}

test "Pathspec matches directory prefix" {
    const spec = parsePathspec("src");
    try std.testing.expect(spec.matches("src"));
    try std.testing.expect(spec.matches("src/main.zig"));
}

test "eqlIgnoreCase" {
    try std.testing.expect(eqlIgnoreCase("Hello", "hello"));
    try std.testing.expect(eqlIgnoreCase("ABC", "abc"));
    try std.testing.expect(!eqlIgnoreCase("abc", "abcd"));
}
