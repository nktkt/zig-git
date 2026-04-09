const std = @import("std");

/// Git refspec parsing and matching.
///
/// A refspec has the format: [+]<src>:<dst>
///   - Optional '+' prefix means force update (allow non-fast-forward)
///   - src: source ref pattern (may contain '*' wildcard)
///   - dst: destination ref pattern (may contain '*' wildcard)
///
/// Special cases:
///   - `:refs/heads/foo` — delete the remote ref (empty src)
///   - `refs/heads/foo:` — just fetch, don't store (empty dst)
///   - `refs/heads/foo` — shorthand for `refs/heads/foo:` (no colon)
///
/// Wildcards: `refs/heads/*:refs/remotes/origin/*`
///   The '*' in src matches any path component(s), and the matched
///   portion is substituted into dst.

/// A parsed refspec.
pub const Refspec = struct {
    src: []const u8,
    dst: []const u8,
    force: bool,
    /// Whether this refspec contains a wildcard ('*').
    is_glob: bool,
    /// Whether this is a delete refspec (empty src).
    is_delete: bool,
    /// Whether this is a fetch-only refspec (empty dst and had colon).
    is_fetch_only: bool,

    /// Check if a reference name matches this refspec's source pattern.
    /// Returns the mapped destination name if it matches, or null otherwise.
    /// The caller owns the returned memory (allocated from `allocator`).
    pub fn match(self: *const Refspec, allocator: std.mem.Allocator, ref_name: []const u8) !?[]u8 {
        if (self.is_delete) return null;

        if (self.is_glob) {
            // Wildcard matching
            const captured = matchWildcard(self.src, ref_name) orelse return null;

            if (self.dst.len == 0) {
                // fetch-only: return a copy of the ref name itself
                const result = try allocator.alloc(u8, ref_name.len);
                @memcpy(result, ref_name);
                return result;
            }

            return try expandWildcard(allocator, self.dst, captured);
        } else {
            // Exact match
            if (!std.mem.eql(u8, self.src, ref_name)) return null;

            if (self.dst.len == 0) {
                const result = try allocator.alloc(u8, ref_name.len);
                @memcpy(result, ref_name);
                return result;
            }

            const result = try allocator.alloc(u8, self.dst.len);
            @memcpy(result, self.dst);
            return result;
        }
    }

    /// Expand a reference name through this refspec.
    /// For glob refspecs, replaces the wildcard in dst with the matched portion.
    /// For exact refspecs, returns dst if ref_name matches src exactly.
    pub fn expand(self: *const Refspec, allocator: std.mem.Allocator, ref_name: []const u8) !?[]u8 {
        return self.match(allocator, ref_name);
    }

    /// Reverse-match: given a destination ref, find the source ref.
    /// Used for push refspecs where we need to go dst -> src.
    pub fn reverseMatch(self: *const Refspec, allocator: std.mem.Allocator, dst_name: []const u8) !?[]u8 {
        if (self.dst.len == 0) return null;

        if (self.is_glob) {
            const captured = matchWildcard(self.dst, dst_name) orelse return null;
            return try expandWildcard(allocator, self.src, captured);
        } else {
            if (!std.mem.eql(u8, self.dst, dst_name)) return null;
            const result = try allocator.alloc(u8, self.src.len);
            @memcpy(result, self.src);
            return result;
        }
    }

    /// Check if a reference name matches the source pattern (without allocating).
    pub fn matches(self: *const Refspec, ref_name: []const u8) bool {
        if (self.is_delete) return false;
        if (self.is_glob) {
            return matchWildcard(self.src, ref_name) != null;
        }
        return std.mem.eql(u8, self.src, ref_name);
    }

    /// Check if a reference name matches the destination pattern (without allocating).
    pub fn matchesDst(self: *const Refspec, ref_name: []const u8) bool {
        if (self.dst.len == 0) return false;
        if (self.is_glob) {
            return matchWildcard(self.dst, ref_name) != null;
        }
        return std.mem.eql(u8, self.dst, ref_name);
    }

    /// Format the refspec back into a string.
    /// Returns the number of bytes written.
    pub fn format(self: *const Refspec, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        if (self.force) {
            try writer.writeByte('+');
        }
        try writer.writeAll(self.src);
        try writer.writeByte(':');
        try writer.writeAll(self.dst);

        return buf[0..fbs.pos];
    }
};

/// Parse a single refspec string.
///
/// Format: [+]<src>:<dst>
/// Examples:
///   "refs/heads/*:refs/remotes/origin/*"
///   "+refs/heads/main:refs/remotes/origin/main"
///   ":refs/heads/foo"  (delete)
///   "refs/heads/foo"   (fetch only, no colon)
pub fn parseRefspec(spec: []const u8) RefspecParseError!Refspec {
    if (spec.len == 0) return RefspecParseError.EmptyRefspec;

    var s = spec;
    var force = false;

    // Check for '+' prefix
    if (s[0] == '+') {
        force = true;
        s = s[1..];
    }

    // Find the colon separator
    if (std.mem.indexOfScalar(u8, s, ':')) |colon_pos| {
        const src = s[0..colon_pos];
        const dst = s[colon_pos + 1 ..];

        // Validate wildcard usage
        const src_has_glob = std.mem.indexOfScalar(u8, src, '*') != null;
        const dst_has_glob = std.mem.indexOfScalar(u8, dst, '*') != null;

        // If one side has a glob, both must (unless one side is empty)
        if (src_has_glob != dst_has_glob) {
            if (src.len > 0 and dst.len > 0) {
                return RefspecParseError.MismatchedWildcard;
            }
        }

        // Validate at most one wildcard per side
        if (src_has_glob and countChar(src, '*') > 1) {
            return RefspecParseError.MultipleWildcards;
        }
        if (dst_has_glob and countChar(dst, '*') > 1) {
            return RefspecParseError.MultipleWildcards;
        }

        const is_delete = src.len == 0;
        const is_fetch_only = dst.len == 0;

        return Refspec{
            .src = src,
            .dst = dst,
            .force = force,
            .is_glob = src_has_glob or dst_has_glob,
            .is_delete = is_delete,
            .is_fetch_only = is_fetch_only,
        };
    } else {
        // No colon: treat as fetch-only (src only)
        const src_has_glob = std.mem.indexOfScalar(u8, s, '*') != null;

        return Refspec{
            .src = s,
            .dst = "",
            .force = force,
            .is_glob = src_has_glob,
            .is_delete = false,
            .is_fetch_only = true,
        };
    }
}

/// Parse multiple refspecs from config lines.
/// Config lines are in the format: `fetch = +refs/heads/*:refs/remotes/origin/*`
/// Returns a list of parsed refspecs.
pub fn parseRefspecs(allocator: std.mem.Allocator, config_lines: []const u8) !RefspecList {
    var list = RefspecList.init(allocator);
    errdefer list.deinit();

    var line_iter = std.mem.splitScalar(u8, config_lines, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Handle config format: "fetch = <refspec>" or "push = <refspec>"
        const spec_str = extractRefspecValue(trimmed) orelse trimmed;

        const refspec = parseRefspec(spec_str) catch continue;
        try list.append(refspec);
    }

    return list;
}

/// Parse refspec values from an array of argument strings.
pub fn parseRefspecArgs(allocator: std.mem.Allocator, args: []const []const u8) !RefspecList {
    var list = RefspecList.init(allocator);
    errdefer list.deinit();

    for (args) |arg| {
        const refspec = try parseRefspec(arg);
        try list.append(refspec);
    }

    return list;
}

/// Apply a list of refspecs to a reference name.
/// Returns the first matching destination, or null if no refspec matches.
pub fn applyRefspecs(allocator: std.mem.Allocator, refspecs: []const Refspec, ref_name: []const u8) !?[]u8 {
    for (refspecs) |*spec| {
        if (try spec.match(allocator, ref_name)) |result| {
            return result;
        }
    }
    return null;
}

/// Apply refspecs in reverse (dst -> src).
pub fn applyRefspecsReverse(allocator: std.mem.Allocator, refspecs: []const Refspec, dst_name: []const u8) !?[]u8 {
    for (refspecs) |*spec| {
        if (try spec.reverseMatch(allocator, dst_name)) |result| {
            return result;
        }
    }
    return null;
}

/// Default fetch refspec for a remote named `origin`.
pub fn defaultFetchRefspec(buf: []u8, remote_name: []const u8) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try writer.writeAll("+refs/heads/*:refs/remotes/");
    try writer.writeAll(remote_name);
    try writer.writeAll("/*");
    return buf[0..fbs.pos];
}

/// Default push refspec (matching branches).
pub fn defaultPushRefspec() Refspec {
    return Refspec{
        .src = "refs/heads/*",
        .dst = "refs/heads/*",
        .force = false,
        .is_glob = true,
        .is_delete = false,
        .is_fetch_only = false,
    };
}

/// Check if a refspec is a "matching" refspec (empty or `:` only).
pub fn isMatchingRefspec(spec: []const u8) bool {
    if (spec.len == 0) return true;
    if (std.mem.eql(u8, spec, ":")) return true;
    return false;
}

/// Determine the fetch mode from a list of refspecs.
pub const FetchMode = enum {
    /// Fetch all branches with default refspec
    all_branches,
    /// Fetch specific refs
    specific,
    /// Fetch tags only
    tags_only,
};

pub fn determineFetchMode(refspecs: []const Refspec) FetchMode {
    if (refspecs.len == 0) return .all_branches;

    for (refspecs) |*spec| {
        if (std.mem.startsWith(u8, spec.src, "refs/tags/")) {
            return .tags_only;
        }
    }

    return .specific;
}

/// Generate the FETCH_HEAD line for a fetched ref.
pub fn formatFetchHead(
    buf: []u8,
    oid_hex: []const u8,
    is_merge: bool,
    description: []const u8,
    remote_url: []const u8,
) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll(oid_hex);
    try writer.writeByte('\t');
    if (is_merge) {
        try writer.writeAll("");
    } else {
        try writer.writeAll("not-for-merge");
    }
    try writer.writeByte('\t');
    try writer.writeAll(description);
    try writer.writeAll(" of ");
    try writer.writeAll(remote_url);
    try writer.writeByte('\n');

    return buf[0..fbs.pos];
}

/// Map a remote ref to a tracking branch name.
/// E.g., "refs/heads/main" with remote "origin" -> "refs/remotes/origin/main"
pub fn mapToTrackingBranch(
    buf: []u8,
    ref_name: []const u8,
    remote_name: []const u8,
) !?[]const u8 {
    const prefix = "refs/heads/";
    if (!std.mem.startsWith(u8, ref_name, prefix)) return null;

    const branch = ref_name[prefix.len..];
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll("refs/remotes/");
    try writer.writeAll(remote_name);
    try writer.writeByte('/');
    try writer.writeAll(branch);

    return buf[0..fbs.pos];
}

/// Classify a refspec for display purposes.
pub const RefspecKind = enum {
    branch,
    tag,
    note,
    head,
    other,
};

pub fn classifyRef(ref_name: []const u8) RefspecKind {
    if (std.mem.startsWith(u8, ref_name, "refs/heads/")) return .branch;
    if (std.mem.startsWith(u8, ref_name, "refs/tags/")) return .tag;
    if (std.mem.startsWith(u8, ref_name, "refs/notes/")) return .note;
    if (std.mem.eql(u8, ref_name, "HEAD")) return .head;
    return .other;
}

/// Short name for a ref (strip the standard prefix).
pub fn shortRefName(ref_name: []const u8) []const u8 {
    const prefixes = [_][]const u8{
        "refs/heads/",
        "refs/tags/",
        "refs/remotes/",
        "refs/notes/",
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, ref_name, prefix)) {
            return ref_name[prefix.len..];
        }
    }
    return ref_name;
}

// --- List type ---

pub const RefspecList = std.array_list.Managed(Refspec);

// --- Error set ---

pub const RefspecParseError = error{
    EmptyRefspec,
    MismatchedWildcard,
    MultipleWildcards,
    InvalidRefspec,
};

// --- Internal helpers ---

/// Match a wildcard pattern against a string.
/// The pattern contains exactly one '*'. Returns the substring matched by '*'.
fn matchWildcard(pattern: []const u8, name: []const u8) ?[]const u8 {
    const star_pos = std.mem.indexOfScalar(u8, pattern, '*') orelse {
        // No wildcard: exact match only
        if (std.mem.eql(u8, pattern, name)) return "" else return null;
    };

    const prefix = pattern[0..star_pos];
    const suffix = pattern[star_pos + 1 ..];

    if (!std.mem.startsWith(u8, name, prefix)) return null;
    if (!std.mem.endsWith(u8, name, suffix)) return null;

    // The captured portion is what the '*' matched
    const captured_start = prefix.len;
    const captured_end = name.len - suffix.len;
    if (captured_start > captured_end) return null;

    return name[captured_start..captured_end];
}

/// Expand a wildcard pattern by replacing '*' with the captured string.
fn expandWildcard(allocator: std.mem.Allocator, pattern: []const u8, captured: []const u8) ![]u8 {
    const star_pos = std.mem.indexOfScalar(u8, pattern, '*') orelse {
        // No wildcard in destination: return as-is
        const result = try allocator.alloc(u8, pattern.len);
        @memcpy(result, pattern);
        return result;
    };

    const prefix = pattern[0..star_pos];
    const suffix = pattern[star_pos + 1 ..];

    const result = try allocator.alloc(u8, prefix.len + captured.len + suffix.len);
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len..][0..captured.len], captured);
    @memcpy(result[prefix.len + captured.len ..][0..suffix.len], suffix);

    return result;
}

/// Extract the refspec value from a config line like "fetch = +refs/heads/*:..."
fn extractRefspecValue(line: []const u8) ?[]const u8 {
    // Look for "= " separator
    if (std.mem.indexOf(u8, line, "= ")) |eq_pos| {
        const after = line[eq_pos + 2 ..];
        return std.mem.trim(u8, after, " \t");
    }
    // Also try just "=" without space
    if (std.mem.indexOfScalar(u8, line, '=')) |eq_pos| {
        if (eq_pos + 1 < line.len) {
            const after = line[eq_pos + 1 ..];
            return std.mem.trim(u8, after, " \t");
        }
    }
    return null;
}

/// Count occurrences of a character in a string.
fn countChar(s: []const u8, c: u8) usize {
    var count: usize = 0;
    for (s) |ch| {
        if (ch == c) count += 1;
    }
    return count;
}

// --- Tests ---

test "parseRefspec basic" {
    const spec = try parseRefspec("refs/heads/main:refs/remotes/origin/main");
    try std.testing.expectEqualStrings("refs/heads/main", spec.src);
    try std.testing.expectEqualStrings("refs/remotes/origin/main", spec.dst);
    try std.testing.expect(!spec.force);
    try std.testing.expect(!spec.is_glob);
    try std.testing.expect(!spec.is_delete);
    try std.testing.expect(!spec.is_fetch_only);
}

test "parseRefspec force" {
    const spec = try parseRefspec("+refs/heads/*:refs/remotes/origin/*");
    try std.testing.expectEqualStrings("refs/heads/*", spec.src);
    try std.testing.expectEqualStrings("refs/remotes/origin/*", spec.dst);
    try std.testing.expect(spec.force);
    try std.testing.expect(spec.is_glob);
}

test "parseRefspec delete" {
    const spec = try parseRefspec(":refs/heads/foo");
    try std.testing.expectEqualStrings("", spec.src);
    try std.testing.expectEqualStrings("refs/heads/foo", spec.dst);
    try std.testing.expect(spec.is_delete);
}

test "parseRefspec fetch only (no colon)" {
    const spec = try parseRefspec("refs/heads/main");
    try std.testing.expectEqualStrings("refs/heads/main", spec.src);
    try std.testing.expectEqualStrings("", spec.dst);
    try std.testing.expect(spec.is_fetch_only);
}

test "parseRefspec fetch only (empty dst)" {
    const spec = try parseRefspec("refs/heads/main:");
    try std.testing.expectEqualStrings("refs/heads/main", spec.src);
    try std.testing.expectEqualStrings("", spec.dst);
    try std.testing.expect(spec.is_fetch_only);
}

test "parseRefspec mismatched wildcard" {
    const result = parseRefspec("refs/heads/*:refs/remotes/origin/main");
    try std.testing.expectError(RefspecParseError.MismatchedWildcard, result);
}

test "parseRefspec multiple wildcards" {
    const result = parseRefspec("refs/heads/*/*:refs/remotes/*/*");
    try std.testing.expectError(RefspecParseError.MultipleWildcards, result);
}

test "Refspec match exact" {
    const spec = try parseRefspec("refs/heads/main:refs/remotes/origin/main");
    const result = try spec.match(std.testing.allocator, "refs/heads/main");
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("refs/remotes/origin/main", result.?);
}

test "Refspec match no match" {
    const spec = try parseRefspec("refs/heads/main:refs/remotes/origin/main");
    const result = try spec.match(std.testing.allocator, "refs/heads/develop");
    try std.testing.expect(result == null);
}

test "Refspec match wildcard" {
    const spec = try parseRefspec("+refs/heads/*:refs/remotes/origin/*");
    const result = try spec.match(std.testing.allocator, "refs/heads/feature/foo");
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("refs/remotes/origin/feature/foo", result.?);
}

test "Refspec match wildcard no match" {
    const spec = try parseRefspec("+refs/heads/*:refs/remotes/origin/*");
    const result = try spec.match(std.testing.allocator, "refs/tags/v1.0");
    try std.testing.expect(result == null);
}

test "Refspec reverseMatch" {
    const spec = try parseRefspec("+refs/heads/*:refs/remotes/origin/*");
    const result = try spec.reverseMatch(std.testing.allocator, "refs/remotes/origin/main");
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("refs/heads/main", result.?);
}

test "Refspec matches" {
    const spec = try parseRefspec("+refs/heads/*:refs/remotes/origin/*");
    try std.testing.expect(spec.matches("refs/heads/main"));
    try std.testing.expect(spec.matches("refs/heads/feature/bar"));
    try std.testing.expect(!spec.matches("refs/tags/v1.0"));
}

test "matchWildcard" {
    const result = matchWildcard("refs/heads/*", "refs/heads/main");
    try std.testing.expectEqualStrings("main", result.?);

    const result2 = matchWildcard("refs/heads/*", "refs/tags/v1");
    try std.testing.expect(result2 == null);

    const result3 = matchWildcard("refs/heads/*", "refs/heads/feature/deep");
    try std.testing.expectEqualStrings("feature/deep", result3.?);
}

test "expandWildcard" {
    const result = try expandWildcard(std.testing.allocator, "refs/remotes/origin/*", "main");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("refs/remotes/origin/main", result);
}

test "defaultFetchRefspec" {
    var buf: [256]u8 = undefined;
    const spec = try defaultFetchRefspec(&buf, "origin");
    try std.testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", spec);
}

test "mapToTrackingBranch" {
    var buf: [256]u8 = undefined;
    const result = try mapToTrackingBranch(&buf, "refs/heads/main", "origin");
    try std.testing.expectEqualStrings("refs/remotes/origin/main", result.?);

    const result2 = try mapToTrackingBranch(&buf, "refs/tags/v1.0", "origin");
    try std.testing.expect(result2 == null);
}

test "shortRefName" {
    try std.testing.expectEqualStrings("main", shortRefName("refs/heads/main"));
    try std.testing.expectEqualStrings("v1.0", shortRefName("refs/tags/v1.0"));
    try std.testing.expectEqualStrings("origin/main", shortRefName("refs/remotes/origin/main"));
    try std.testing.expectEqualStrings("HEAD", shortRefName("HEAD"));
}

test "classifyRef" {
    try std.testing.expectEqual(RefspecKind.branch, classifyRef("refs/heads/main"));
    try std.testing.expectEqual(RefspecKind.tag, classifyRef("refs/tags/v1.0"));
    try std.testing.expectEqual(RefspecKind.head, classifyRef("HEAD"));
    try std.testing.expectEqual(RefspecKind.other, classifyRef("refs/stash"));
}

test "parseRefspecs from config" {
    const config =
        \\fetch = +refs/heads/*:refs/remotes/origin/*
        \\fetch = +refs/tags/*:refs/tags/*
        \\
    ;
    var list = try parseRefspecs(std.testing.allocator, config);
    defer list.deinit();

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expect(list.items[0].force);
    try std.testing.expect(list.items[0].is_glob);
    try std.testing.expectEqualStrings("refs/heads/*", list.items[0].src);
    try std.testing.expectEqualStrings("refs/tags/*", list.items[1].src);
}

test "Refspec format" {
    const spec = try parseRefspec("+refs/heads/*:refs/remotes/origin/*");
    var buf: [256]u8 = undefined;
    const formatted = try spec.format(&buf);
    try std.testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", formatted);
}

test "isMatchingRefspec" {
    try std.testing.expect(isMatchingRefspec(""));
    try std.testing.expect(isMatchingRefspec(":"));
    try std.testing.expect(!isMatchingRefspec("refs/heads/main"));
}

test "formatFetchHead" {
    var buf: [512]u8 = undefined;
    const line = try formatFetchHead(
        &buf,
        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        false,
        "branch 'main'",
        "https://github.com/example/repo",
    );
    try std.testing.expect(std.mem.indexOf(u8, line, "not-for-merge") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391") != null);
}
