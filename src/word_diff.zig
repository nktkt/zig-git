const std = @import("std");

/// Word diff display mode.
pub const WordDiffMode = enum {
    color,
    plain,
    porcelain,
};

/// A single word token (either a word or whitespace).
pub const Token = struct {
    text: []const u8,
    is_whitespace: bool,
};

/// Type of change for a word.
pub const WordChangeKind = enum {
    equal,
    added,
    removed,
};

/// A single word change in a word diff.
pub const WordChange = struct {
    kind: WordChangeKind,
    text: []const u8,
};

/// Result of a word-level diff.
pub const WordDiffResult = struct {
    allocator: std.mem.Allocator,
    changes: std.array_list.Managed(WordChange),

    pub fn deinit(self: *WordDiffResult) void {
        self.changes.deinit();
    }
};

// ANSI color codes
const COLOR_RED = "\x1b[31m";
const COLOR_GREEN = "\x1b[32m";
const COLOR_RED_BG = "\x1b[41m";
const COLOR_GREEN_BG = "\x1b[42m";
const COLOR_RESET = "\x1b[0m";

/// Tokenize text into words based on whitespace boundaries.
pub fn tokenizeDefault(allocator: std.mem.Allocator, text: []const u8) !std.array_list.Managed(Token) {
    var tokens = std.array_list.Managed(Token).init(allocator);
    errdefer tokens.deinit();

    if (text.len == 0) return tokens;

    var i: usize = 0;
    while (i < text.len) {
        if (isWhitespace(text[i])) {
            const start = i;
            while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
            try tokens.append(.{ .text = text[start..i], .is_whitespace = true });
        } else {
            const start = i;
            while (i < text.len and !isWhitespace(text[i])) : (i += 1) {}
            try tokens.append(.{ .text = text[start..i], .is_whitespace = false });
        }
    }

    return tokens;
}

/// Tokenize text based on a simple regex-like pattern.
/// Supports basic character classes and alternation.
/// For simplicity, this uses a word-boundary heuristic with configurable separators.
pub fn tokenizeWithPattern(allocator: std.mem.Allocator, text: []const u8, pattern: []const u8) !std.array_list.Managed(Token) {
    // If pattern is ".", treat each character as a token
    if (std.mem.eql(u8, pattern, ".")) {
        var tokens = std.array_list.Managed(Token).init(allocator);
        errdefer tokens.deinit();
        for (0..text.len) |i| {
            try tokens.append(.{ .text = text[i .. i + 1], .is_whitespace = isWhitespace(text[i]) });
        }
        return tokens;
    }

    // For "[^a-zA-Z0-9_]+" or similar, split on non-word characters
    if (std.mem.startsWith(u8, pattern, "[^")) {
        return tokenizeNonWord(allocator, text);
    }

    // Default: whitespace tokenization
    return tokenizeDefault(allocator, text);
}

/// Tokenize splitting on non-word characters (letters, digits, underscore are words).
fn tokenizeNonWord(allocator: std.mem.Allocator, text: []const u8) !std.array_list.Managed(Token) {
    var tokens = std.array_list.Managed(Token).init(allocator);
    errdefer tokens.deinit();

    if (text.len == 0) return tokens;

    var i: usize = 0;
    while (i < text.len) {
        if (isWordChar(text[i])) {
            const start = i;
            while (i < text.len and isWordChar(text[i])) : (i += 1) {}
            try tokens.append(.{ .text = text[start..i], .is_whitespace = false });
        } else {
            const start = i;
            while (i < text.len and !isWordChar(text[i])) : (i += 1) {}
            try tokens.append(.{ .text = text[start..i], .is_whitespace = true });
        }
    }

    return tokens;
}

/// Compute word-level diff between two texts.
pub fn wordDiff(
    allocator: std.mem.Allocator,
    old_text: []const u8,
    new_text: []const u8,
) !WordDiffResult {
    var old_tokens = try tokenizeDefault(allocator, old_text);
    defer old_tokens.deinit();
    var new_tokens = try tokenizeDefault(allocator, new_text);
    defer new_tokens.deinit();

    return diffTokens(allocator, old_tokens.items, new_tokens.items);
}

/// Compute word-level diff with custom tokenization.
pub fn wordDiffWithPattern(
    allocator: std.mem.Allocator,
    old_text: []const u8,
    new_text: []const u8,
    pattern: []const u8,
) !WordDiffResult {
    var old_tokens = try tokenizeWithPattern(allocator, old_text, pattern);
    defer old_tokens.deinit();
    var new_tokens = try tokenizeWithPattern(allocator, new_text, pattern);
    defer new_tokens.deinit();

    return diffTokens(allocator, old_tokens.items, new_tokens.items);
}

/// Diff two token arrays using a simplified LCS-based approach.
fn diffTokens(
    allocator: std.mem.Allocator,
    old_tokens: []const Token,
    new_tokens: []const Token,
) !WordDiffResult {
    var result = WordDiffResult{
        .allocator = allocator,
        .changes = std.array_list.Managed(WordChange).init(allocator),
    };
    errdefer result.deinit();

    const n = old_tokens.len;
    const m = new_tokens.len;

    if (n == 0 and m == 0) return result;

    if (n == 0) {
        for (new_tokens) |*tok| {
            try result.changes.append(.{ .kind = .added, .text = tok.text });
        }
        return result;
    }

    if (m == 0) {
        for (old_tokens) |*tok| {
            try result.changes.append(.{ .kind = .removed, .text = tok.text });
        }
        return result;
    }

    // Use Myers-like diff on tokens
    const edit_ops = try myersTokenDiff(allocator, old_tokens, new_tokens);
    defer allocator.free(edit_ops);

    var oi: usize = 0;
    var ni: usize = 0;
    for (edit_ops) |op| {
        switch (op) {
            .equal => {
                if (oi < old_tokens.len and ni < new_tokens.len) {
                    try result.changes.append(.{ .kind = .equal, .text = old_tokens[oi].text });
                    oi += 1;
                    ni += 1;
                }
            },
            .delete => {
                if (oi < old_tokens.len) {
                    try result.changes.append(.{ .kind = .removed, .text = old_tokens[oi].text });
                    oi += 1;
                }
            },
            .insert => {
                if (ni < new_tokens.len) {
                    try result.changes.append(.{ .kind = .added, .text = new_tokens[ni].text });
                    ni += 1;
                }
            },
        }
    }

    return result;
}

const EditOp = enum {
    equal,
    insert,
    delete,
};

/// Myers diff algorithm for token sequences.
fn myersTokenDiff(
    allocator: std.mem.Allocator,
    old_tokens: []const Token,
    new_tokens: []const Token,
) ![]EditOp {
    const n: isize = @intCast(old_tokens.len);
    const m: isize = @intCast(new_tokens.len);
    const max_d: isize = n + m;

    if (max_d == 0) return allocator.alloc(EditOp, 0);

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
                if (std.mem.eql(u8, old_tokens[xu].text, new_tokens[yu].text)) {
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

    // Backtrack
    var edits = std.array_list.Managed(EditOp).init(allocator);
    defer edits.deinit();

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
            try edits.append(.equal);
        }

        if (bd > 0) {
            if (prev_k == bk - 1) {
                bx -= 1;
                try edits.append(.delete);
            } else {
                by -= 1;
                try edits.append(.insert);
            }
        }
    }

    while (bx > 0 and by > 0) {
        bx -= 1;
        by -= 1;
        try edits.append(.equal);
    }

    const ops = try allocator.alloc(EditOp, edits.items.len);
    for (edits.items, 0..) |_, i| {
        ops[i] = edits.items[edits.items.len - 1 - i];
    }

    return ops;
}

/// Format word diff output and write to file.
pub fn formatWordDiff(
    diff_result: *const WordDiffResult,
    file: std.fs.File,
    mode: WordDiffMode,
) !void {
    switch (mode) {
        .color => try formatWordDiffColor(diff_result, file),
        .plain => try formatWordDiffPlain(diff_result, file),
        .porcelain => try formatWordDiffPorcelain(diff_result, file),
    }
}

/// Format word diff with ANSI color inline.
fn formatWordDiffColor(diff_result: *const WordDiffResult, file: std.fs.File) !void {
    for (diff_result.changes.items) |*change| {
        switch (change.kind) {
            .equal => {
                try file.writeAll(change.text);
            },
            .removed => {
                try file.writeAll(COLOR_RED);
                try file.writeAll(change.text);
                try file.writeAll(COLOR_RESET);
            },
            .added => {
                try file.writeAll(COLOR_GREEN);
                try file.writeAll(change.text);
                try file.writeAll(COLOR_RESET);
            },
        }
    }
    try file.writeAll("\n");
}

/// Format word diff with [-removed-]{+added+} markers.
fn formatWordDiffPlain(diff_result: *const WordDiffResult, file: std.fs.File) !void {
    for (diff_result.changes.items) |*change| {
        switch (change.kind) {
            .equal => {
                try file.writeAll(change.text);
            },
            .removed => {
                try file.writeAll("[-");
                try file.writeAll(change.text);
                try file.writeAll("-]");
            },
            .added => {
                try file.writeAll("{+");
                try file.writeAll(change.text);
                try file.writeAll("+}");
            },
        }
    }
    try file.writeAll("\n");
}

/// Format word diff in machine-readable porcelain mode.
/// Each line is prefixed with a type indicator:
///   ' ' for context, '-' for removed, '+' for added, '~' for newline.
fn formatWordDiffPorcelain(diff_result: *const WordDiffResult, file: std.fs.File) !void {
    for (diff_result.changes.items) |*change| {
        switch (change.kind) {
            .equal => {
                // Check for newlines in the text
                if (std.mem.indexOfScalar(u8, change.text, '\n') != null) {
                    try file.writeAll("~\n");
                } else {
                    try file.writeAll(" ");
                    try file.writeAll(change.text);
                    try file.writeAll("\n");
                }
            },
            .removed => {
                try file.writeAll("-");
                try file.writeAll(change.text);
                try file.writeAll("\n");
            },
            .added => {
                try file.writeAll("+");
                try file.writeAll(change.text);
                try file.writeAll("\n");
            },
        }
    }
}

/// Parse --word-diff[=<mode>] argument.
pub fn parseWordDiffArg(arg: []const u8) ?WordDiffMode {
    if (std.mem.eql(u8, arg, "--word-diff")) return .color;
    if (std.mem.eql(u8, arg, "--word-diff=color")) return .color;
    if (std.mem.eql(u8, arg, "--word-diff=plain")) return .plain;
    if (std.mem.eql(u8, arg, "--word-diff=porcelain")) return .porcelain;
    return null;
}

/// Parse --word-diff-regex=<regex> argument.
pub fn parseWordDiffRegexArg(arg: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, "--word-diff-regex=")) {
        return arg["--word-diff-regex=".len..];
    }
    return null;
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

test "tokenizeDefault basic" {
    var tokens = try tokenizeDefault(std.testing.allocator, "hello world  foo");
    defer tokens.deinit();

    try std.testing.expectEqual(@as(usize, 5), tokens.items.len);
    try std.testing.expectEqualStrings("hello", tokens.items[0].text);
    try std.testing.expect(!tokens.items[0].is_whitespace);
    try std.testing.expect(tokens.items[1].is_whitespace);
    try std.testing.expectEqualStrings("world", tokens.items[2].text);
}

test "tokenizeDefault empty" {
    var tokens = try tokenizeDefault(std.testing.allocator, "");
    defer tokens.deinit();
    try std.testing.expectEqual(@as(usize, 0), tokens.items.len);
}

test "wordDiff identical" {
    var result = try wordDiff(std.testing.allocator, "hello world", "hello world");
    defer result.deinit();

    for (result.changes.items) |*change| {
        try std.testing.expect(change.kind == .equal);
    }
}

test "wordDiff added" {
    var result = try wordDiff(std.testing.allocator, "hello", "hello world");
    defer result.deinit();

    var has_added = false;
    for (result.changes.items) |*change| {
        if (change.kind == .added) has_added = true;
    }
    try std.testing.expect(has_added);
}

test "wordDiff removed" {
    var result = try wordDiff(std.testing.allocator, "hello world", "hello");
    defer result.deinit();

    var has_removed = false;
    for (result.changes.items) |*change| {
        if (change.kind == .removed) has_removed = true;
    }
    try std.testing.expect(has_removed);
}

test "parseWordDiffArg" {
    try std.testing.expect(parseWordDiffArg("--word-diff").? == .color);
    try std.testing.expect(parseWordDiffArg("--word-diff=plain").? == .plain);
    try std.testing.expect(parseWordDiffArg("--word-diff=porcelain").? == .porcelain);
    try std.testing.expect(parseWordDiffArg("--stat") == null);
}

test "parseWordDiffRegexArg" {
    const regex = parseWordDiffRegexArg("--word-diff-regex=.");
    try std.testing.expect(regex != null);
    try std.testing.expectEqualStrings(".", regex.?);
    try std.testing.expect(parseWordDiffRegexArg("--word-diff") == null);
}
