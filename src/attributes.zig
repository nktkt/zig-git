const std = @import("std");
const ignore = @import("ignore.zig");

/// A single attribute value.
pub const AttrValue = union(enum) {
    /// Attribute is set (true).
    set,
    /// Attribute is unset (false, prefixed with -).
    unset,
    /// Attribute has a string value (attr=value).
    string: []const u8,
    /// Attribute is unspecified (not mentioned for this path).
    unspecified,
};

/// A single attribute assignment from an attributes file.
pub const AttrRule = struct {
    name: []const u8,
    value: AttrValue,
};

/// A pattern line from a .gitattributes file.
pub const AttrPattern = struct {
    pattern: []const u8,
    attrs: []const AttrRule,
    is_macro: bool,
    macro_name: ?[]const u8,
};

/// Built-in attribute names.
pub const ATTR_TEXT = "text";
pub const ATTR_BINARY = "binary";
pub const ATTR_DIFF = "diff";
pub const ATTR_MERGE = "merge";
pub const ATTR_EOL = "eol";
pub const ATTR_ENCODING = "encoding";
pub const ATTR_FILTER = "filter";
pub const ATTR_WHITESPACE = "whitespace";
pub const ATTR_EXPORT_IGNORE = "export-ignore";
pub const ATTR_EXPORT_SUBST = "export-subst";
pub const ATTR_DELTA = "delta";
pub const ATTR_LINGUIST_LANGUAGE = "linguist-language";
pub const ATTR_LINGUIST_GENERATED = "linguist-generated";

/// Built-in macro: binary = -diff -merge -text
const BINARY_MACRO_ATTRS = [_]AttrRule{
    .{ .name = ATTR_DIFF, .value = .unset },
    .{ .name = ATTR_MERGE, .value = .unset },
    .{ .name = ATTR_TEXT, .value = .unset },
};

/// Gitattributes file parser and attribute checker.
pub const Attributes = struct {
    allocator: std.mem.Allocator,
    patterns: std.array_list.Managed(OwnedPattern),
    /// Macro definitions: macro_name -> list of attr rules
    macros: std.StringHashMap(std.array_list.Managed(AttrRule)),
    /// Owned data buffers
    owned_data: std.array_list.Managed([]u8),

    const OwnedPattern = struct {
        pattern: []const u8,
        attrs: std.array_list.Managed(AttrRule),
    };

    pub fn init(allocator: std.mem.Allocator) Attributes {
        var attrs = Attributes{
            .allocator = allocator,
            .patterns = std.array_list.Managed(OwnedPattern).init(allocator),
            .macros = std.StringHashMap(std.array_list.Managed(AttrRule)).init(allocator),
            .owned_data = std.array_list.Managed([]u8).init(allocator),
        };
        // Register built-in macros
        attrs.registerBuiltinMacros() catch {};
        return attrs;
    }

    pub fn deinit(self: *Attributes) void {
        for (self.patterns.items) |*p| {
            p.attrs.deinit();
        }
        self.patterns.deinit();

        var macro_iter = self.macros.valueIterator();
        while (macro_iter.next()) |v| {
            v.deinit();
        }
        self.macros.deinit();

        for (self.owned_data.items) |d| {
            self.allocator.free(d);
        }
        self.owned_data.deinit();
    }

    fn registerBuiltinMacros(self: *Attributes) !void {
        // binary macro
        var binary_rules = std.array_list.Managed(AttrRule).init(self.allocator);
        for (BINARY_MACRO_ATTRS) |rule| {
            try binary_rules.append(rule);
        }
        try self.macros.put("binary", binary_rules);
    }

    /// Load attributes from a file.
    pub fn loadFile(self: *Attributes, path: []const u8) !void {
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

        try self.parseData(data[0..n]);
    }

    /// Load .gitattributes from a directory.
    pub fn loadGitattributes(self: *Attributes, dir_path: []const u8) !void {
        var path_buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&path_buf);
        const writer = stream.writer();
        try writer.writeAll(dir_path);
        try writer.writeAll("/.gitattributes");
        const path = path_buf[0..stream.pos];
        try self.loadFile(path);
    }

    /// Load .git/info/attributes.
    pub fn loadInfoAttributes(self: *Attributes, git_dir: []const u8) !void {
        var path_buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&path_buf);
        const writer = stream.writer();
        try writer.writeAll(git_dir);
        try writer.writeAll("/info/attributes");
        const path = path_buf[0..stream.pos];
        try self.loadFile(path);
    }

    /// Parse attribute data from a buffer.
    fn parseData(self: *Attributes, data: []const u8) !void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r \t");
            if (line.len == 0) continue;
            if (line[0] == '#') continue;

            // Check for macro definition: [attr]name value...
            if (std.mem.startsWith(u8, line, "[attr]")) {
                self.parseMacroLine(line[6..]) catch continue;
                continue;
            }

            self.parsePatternLine(line) catch continue;
        }
    }

    /// Parse a macro definition line.
    fn parseMacroLine(self: *Attributes, line: []const u8) !void {
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const macro_name = parts.next() orelse return;

        var rules = std.array_list.Managed(AttrRule).init(self.allocator);
        errdefer rules.deinit();

        while (parts.next()) |attr_str| {
            if (parseAttrStr(attr_str)) |rule| {
                try rules.append(rule);
            }
        }

        try self.macros.put(macro_name, rules);
    }

    /// Parse a pattern + attributes line.
    fn parsePatternLine(self: *Attributes, line: []const u8) !void {
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const pattern = parts.next() orelse return;

        var attrs = std.array_list.Managed(AttrRule).init(self.allocator);
        errdefer attrs.deinit();

        while (parts.next()) |attr_str| {
            if (parseAttrStr(attr_str)) |rule| {
                // Check if this is a macro reference
                if (rule.value == .set) {
                    if (self.macros.get(rule.name)) |macro_rules| {
                        for (macro_rules.items) |macro_rule| {
                            try attrs.append(macro_rule);
                        }
                        continue;
                    }
                }
                try attrs.append(rule);
            }
        }

        try self.patterns.append(.{
            .pattern = pattern,
            .attrs = attrs,
        });
    }

    /// Check an attribute for a given path.
    /// Returns the attribute value for the path.
    pub fn check(self: *const Attributes, path: []const u8, attr_name: []const u8) AttrValue {
        var value: AttrValue = .unspecified;

        for (self.patterns.items) |*pat| {
            if (matchPath(pat.pattern, path)) {
                for (pat.attrs.items) |*rule| {
                    if (std.mem.eql(u8, rule.name, attr_name)) {
                        value = rule.value;
                    }
                }
            }
        }

        return value;
    }

    /// Get all attributes for a given path.
    pub fn checkAll(self: *const Attributes, allocator: std.mem.Allocator, path: []const u8) !std.array_list.Managed(NamedAttr) {
        var result = std.array_list.Managed(NamedAttr).init(allocator);
        errdefer result.deinit();

        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();

        // Iterate patterns in reverse order (last match wins)
        var i = self.patterns.items.len;
        while (i > 0) {
            i -= 1;
            const pat = &self.patterns.items[i];
            if (matchPath(pat.pattern, path)) {
                for (pat.attrs.items) |*rule| {
                    if (seen.get(rule.name) == null) {
                        try seen.put(rule.name, {});
                        try result.append(.{
                            .name = rule.name,
                            .value = rule.value,
                        });
                    }
                }
            }
        }

        return result;
    }
};

/// Named attribute result for checkAll.
pub const NamedAttr = struct {
    name: []const u8,
    value: AttrValue,
};

/// Parse a single attribute string from a pattern line.
/// Formats: "attr" (set), "-attr" (unset), "attr=value" (string), "!attr" (unspecified)
fn parseAttrStr(s: []const u8) ?AttrRule {
    if (s.len == 0) return null;

    if (s[0] == '-') {
        if (s.len < 2) return null;
        return .{ .name = s[1..], .value = .unset };
    }

    if (s[0] == '!') {
        if (s.len < 2) return null;
        return .{ .name = s[1..], .value = .unspecified };
    }

    if (std.mem.indexOfScalar(u8, s, '=')) |eq_pos| {
        if (eq_pos == 0 or eq_pos + 1 >= s.len) return null;
        return .{
            .name = s[0..eq_pos],
            .value = .{ .string = s[eq_pos + 1 ..] },
        };
    }

    return .{ .name = s, .value = .set };
}

/// Match a gitattributes pattern against a path.
/// Uses the same glob matching as .gitignore patterns.
fn matchPath(pattern: []const u8, path: []const u8) bool {
    // If pattern contains '/', match against full path
    if (std.mem.indexOfScalar(u8, pattern, '/') != null) {
        return globMatch(pattern, path);
    }

    // Otherwise, match against basename
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
        path[idx + 1 ..]
    else
        path;

    return globMatch(pattern, basename);
}

/// Simple glob matching supporting *, ?, and [].
fn globMatch(pattern: []const u8, text: []const u8) bool {
    return globMatchInner(pattern, text, 0);
}

fn globMatchInner(pattern: []const u8, text: []const u8, depth: usize) bool {
    if (depth > 100) return false;

    var pi: usize = 0;
    var ti: usize = 0;

    while (pi < pattern.len) {
        if (pattern[pi] == '*') {
            while (pi < pattern.len and pattern[pi] == '*') {
                pi += 1;
            }
            if (pi == pattern.len) {
                // Trailing * matches rest
                return true;
            }
            while (ti <= text.len) {
                if (globMatchInner(pattern[pi..], text[ti..], depth + 1)) return true;
                if (ti >= text.len) break;
                ti += 1;
            }
            return false;
        } else if (pattern[pi] == '?') {
            if (ti >= text.len) return false;
            pi += 1;
            ti += 1;
        } else if (pattern[pi] == '[') {
            if (ti >= text.len) return false;
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
                    if (text[ti] >= pattern[pi] and text[ti] <= pattern[pi + 2]) matched = true;
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
            if (ti >= text.len) return false;
            if (pattern[pi] != text[ti]) return false;
            pi += 1;
            ti += 1;
        }
    }

    return ti == text.len;
}

/// Format attribute value as string for display.
pub fn formatAttrValue(buf: []u8, value: AttrValue) []const u8 {
    return switch (value) {
        .set => "set",
        .unset => "false",
        .unspecified => "unspecified",
        .string => |s| std.fmt.bufPrint(buf, "{s}", .{s}) catch "?",
    };
}

/// Run the check-attr command.
pub fn runCheckAttr(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    args: []const []const u8,
) !void {
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };

    var show_all = false;
    var attr_name: ?[]const u8 = null;
    var paths = std.array_list.Managed([]const u8).init(allocator);
    defer paths.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            show_all = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            // Remaining args are paths
            i += 1;
            while (i < args.len) : (i += 1) {
                try paths.append(args[i]);
            }
            break;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (attr_name == null and !show_all) {
                attr_name = arg;
            } else {
                try paths.append(arg);
            }
        }
    }

    if (!show_all and attr_name == null) {
        try stderr.writeAll("usage: zig-git check-attr [-a | <attr>] <path>...\n");
        std.process.exit(1);
    }

    // Load attributes
    var attrs = Attributes.init(allocator);
    defer attrs.deinit();

    // Determine work dir from git_dir
    const work_dir = if (std.mem.endsWith(u8, git_dir, "/.git"))
        git_dir[0 .. git_dir.len - 5]
    else
        git_dir;

    attrs.loadGitattributes(work_dir) catch {};
    attrs.loadInfoAttributes(git_dir) catch {};

    var buf: [4096]u8 = undefined;

    for (paths.items) |path| {
        if (show_all) {
            var all_attrs = try attrs.checkAll(allocator, path);
            defer all_attrs.deinit();

            for (all_attrs.items) |*na| {
                const val_str = formatAttrValue(&buf, na.value);
                var line_buf: [4096]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "{s}: {s}: {s}\n", .{ path, na.name, val_str }) catch continue;
                try stdout.writeAll(line);
            }
        } else {
            const value = attrs.check(path, attr_name.?);
            const val_str = formatAttrValue(&buf, value);
            var line_buf: [4096]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "{s}: {s}: {s}\n", .{ path, attr_name.?, val_str }) catch continue;
            try stdout.writeAll(line);
        }
    }
}

test "parseAttrStr basic" {
    {
        const rule = parseAttrStr("text").?;
        try std.testing.expectEqualStrings("text", rule.name);
        try std.testing.expect(rule.value == .set);
    }
    {
        const rule = parseAttrStr("-diff").?;
        try std.testing.expectEqualStrings("diff", rule.name);
        try std.testing.expect(rule.value == .unset);
    }
    {
        const rule = parseAttrStr("eol=lf").?;
        try std.testing.expectEqualStrings("eol", rule.name);
        try std.testing.expectEqualStrings("lf", rule.value.string);
    }
    {
        const rule = parseAttrStr("!merge").?;
        try std.testing.expectEqualStrings("merge", rule.name);
        try std.testing.expect(rule.value == .unspecified);
    }
}

test "Attributes init and deinit" {
    var attrs = Attributes.init(std.testing.allocator);
    defer attrs.deinit();

    // Binary macro should be registered
    try std.testing.expect(attrs.macros.get("binary") != null);
}

test "matchPath basic" {
    try std.testing.expect(matchPath("*.txt", "hello.txt"));
    try std.testing.expect(!matchPath("*.txt", "hello.zig"));
    try std.testing.expect(matchPath("src/*.zig", "src/main.zig"));
    try std.testing.expect(!matchPath("src/*.zig", "lib/main.zig"));
}

test "globMatch" {
    try std.testing.expect(globMatch("hello", "hello"));
    try std.testing.expect(!globMatch("hello", "world"));
    try std.testing.expect(globMatch("*", "anything"));
    try std.testing.expect(globMatch("*.txt", "file.txt"));
    try std.testing.expect(globMatch("h?llo", "hello"));
    try std.testing.expect(!globMatch("h?llo", "hllo"));
}
