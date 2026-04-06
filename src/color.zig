const std = @import("std");
const config_mod = @import("config.zig");

/// ANSI color/style codes.
pub const Color = enum {
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bold,
    dim,
    reset,
    bold_red,
    bold_green,
    bold_yellow,
    bold_blue,
    bold_magenta,
    bold_cyan,

    /// Return the ANSI escape sequence for this color/style.
    pub fn code(self: Color) []const u8 {
        return switch (self) {
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .reset => "\x1b[0m",
            .bold_red => "\x1b[1;31m",
            .bold_green => "\x1b[1;32m",
            .bold_yellow => "\x1b[1;33m",
            .bold_blue => "\x1b[1;34m",
            .bold_magenta => "\x1b[1;35m",
            .bold_cyan => "\x1b[1;36m",
        };
    }
};

/// Color mode for output.
pub const ColorMode = enum {
    always,
    never,
    auto,
};

/// Colorize text by wrapping it in ANSI escape codes.
/// Writes the result into the provided buffer and returns the used slice.
pub fn colorize(buf: []u8, text: []const u8, clr: Color) []const u8 {
    const prefix = clr.code();
    const suffix = Color.reset.code();
    const total = prefix.len + text.len + suffix.len;
    if (total > buf.len) return text; // fallback: return uncolored
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..text.len], text);
    @memcpy(buf[prefix.len + text.len ..][0..suffix.len], suffix);
    return buf[0..total];
}

/// Write colorized text directly to a file.
pub fn writeColored(file: std.fs.File, text: []const u8, clr: Color) !void {
    try file.writeAll(clr.code());
    try file.writeAll(text);
    try file.writeAll(Color.reset.code());
}

/// Check if a file descriptor refers to a TTY.
pub fn isTty(file: std.fs.File) bool {
    return std.posix.isatty(file.handle);
}

/// Determine whether color output is enabled based on mode and file.
pub fn isEnabled(mode: ColorMode, file: std.fs.File) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => isTty(file),
    };
}

/// Check if color is enabled for a specific section using git config.
/// Checks color.<section> first, then falls back to color.ui.
/// Defaults to "auto" if not configured.
pub fn isColorEnabled(cfg: *const config_mod.Config, section: []const u8, file: std.fs.File) bool {
    // Check section-specific setting first
    var key_buf: [128]u8 = undefined;
    const section_key = std.fmt.bufPrint(&key_buf, "color.{s}", .{section}) catch return isEnabled(.auto, file);

    if (cfg.get(section_key)) |val| {
        const mode = parseColorMode(val);
        return isEnabled(mode, file);
    }

    // Fall back to color.ui
    if (cfg.get("color.ui")) |val| {
        const mode = parseColorMode(val);
        return isEnabled(mode, file);
    }

    return isEnabled(.auto, file);
}

/// Parse a color mode string from config.
pub fn parseColorMode(value: []const u8) ColorMode {
    if (std.mem.eql(u8, value, "always") or std.mem.eql(u8, value, "true")) {
        return .always;
    }
    if (std.mem.eql(u8, value, "never") or std.mem.eql(u8, value, "false")) {
        return .never;
    }
    return .auto;
}

/// Parse --color=<mode> from command line argument.
/// Returns null if the argument is not a --color flag.
pub fn parseColorArg(arg: []const u8) ?ColorMode {
    if (std.mem.eql(u8, arg, "--color=always")) return .always;
    if (std.mem.eql(u8, arg, "--color=never")) return .never;
    if (std.mem.eql(u8, arg, "--color=auto")) return .auto;
    if (std.mem.eql(u8, arg, "--color")) return .always;
    if (std.mem.eql(u8, arg, "--no-color")) return .never;
    return null;
}

/// Parse a color name string (e.g., from config values like color.diff.meta).
pub fn parseColorName(name: []const u8) ?Color {
    if (std.mem.eql(u8, name, "red")) return .red;
    if (std.mem.eql(u8, name, "green")) return .green;
    if (std.mem.eql(u8, name, "yellow")) return .yellow;
    if (std.mem.eql(u8, name, "blue")) return .blue;
    if (std.mem.eql(u8, name, "magenta")) return .magenta;
    if (std.mem.eql(u8, name, "cyan")) return .cyan;
    if (std.mem.eql(u8, name, "white")) return .white;
    if (std.mem.eql(u8, name, "bold")) return .bold;
    if (std.mem.eql(u8, name, "dim")) return .dim;
    if (std.mem.eql(u8, name, "reset")) return .reset;
    return null;
}

/// Predefined color schemes for diff output.
pub const DiffColors = struct {
    meta: Color,
    frag: Color,
    old: Color,
    new: Color,
    commit: Color,
    whitespace: Color,

    pub const default = DiffColors{
        .meta = .bold,
        .frag = .cyan,
        .old = .red,
        .new = .green,
        .commit = .bold_yellow,
        .whitespace = .bold_red,
    };
};

/// Predefined color schemes for status output.
pub const StatusColors = struct {
    header: Color,
    added: Color,
    changed: Color,
    untracked: Color,
    branch: Color,
    no_branch: Color,

    pub const default = StatusColors{
        .header = .bold,
        .added = .green,
        .changed = .red,
        .untracked = .red,
        .branch = .bold_green,
        .no_branch = .bold_red,
    };
};

/// Predefined color schemes for branch output.
pub const BranchColors = struct {
    current: Color,
    local: Color,
    remote: Color,
    upstream: Color,

    pub const default = BranchColors{
        .current = .bold_green,
        .local = .white,
        .remote = .red,
        .upstream = .bold_blue,
    };
};

/// Helper: generate an ANSI 256-color foreground code.
pub fn color256(buf: []u8, color_num: u8) []const u8 {
    const result = std.fmt.bufPrint(buf, "\x1b[38;5;{d}m", .{color_num}) catch return "";
    return result;
}

/// Helper: generate an ANSI 256-color background code.
pub fn bgColor256(buf: []u8, color_num: u8) []const u8 {
    const result = std.fmt.bufPrint(buf, "\x1b[48;5;{d}m", .{color_num}) catch return "";
    return result;
}

/// Strip all ANSI escape sequences from text.
pub fn stripAnsi(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\x1b' and i + 1 < text.len and text[i + 1] == '[') {
            // Skip until we find the terminating letter
            i += 2;
            while (i < text.len) {
                if ((text[i] >= 'A' and text[i] <= 'Z') or
                    (text[i] >= 'a' and text[i] <= 'z'))
                {
                    i += 1;
                    break;
                }
                i += 1;
            }
        } else {
            try result.append(text[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

/// Calculate visible (non-ANSI) length of text.
pub fn visibleLength(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\x1b' and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len) {
                if ((text[i] >= 'A' and text[i] <= 'Z') or
                    (text[i] >= 'a' and text[i] <= 'z'))
                {
                    i += 1;
                    break;
                }
                i += 1;
            }
        } else {
            count += 1;
            i += 1;
        }
    }
    return count;
}

test "colorize basic" {
    var buf: [256]u8 = undefined;
    const result = colorize(&buf, "hello", .red);
    try std.testing.expect(std.mem.startsWith(u8, result, "\x1b[31m"));
    try std.testing.expect(std.mem.endsWith(u8, result, "\x1b[0m"));
}

test "parseColorMode" {
    try std.testing.expect(parseColorMode("always") == .always);
    try std.testing.expect(parseColorMode("true") == .always);
    try std.testing.expect(parseColorMode("never") == .never);
    try std.testing.expect(parseColorMode("false") == .never);
    try std.testing.expect(parseColorMode("auto") == .auto);
    try std.testing.expect(parseColorMode("anything") == .auto);
}

test "parseColorArg" {
    try std.testing.expect(parseColorArg("--color=always").? == .always);
    try std.testing.expect(parseColorArg("--color=never").? == .never);
    try std.testing.expect(parseColorArg("--no-color").? == .never);
    try std.testing.expect(parseColorArg("--verbose") == null);
}

test "visibleLength" {
    try std.testing.expectEqual(@as(usize, 5), visibleLength("hello"));
    try std.testing.expectEqual(@as(usize, 5), visibleLength("\x1b[31mhello\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 0), visibleLength("\x1b[1m\x1b[0m"));
}

test "stripAnsi" {
    const result = try stripAnsi(std.testing.allocator, "\x1b[31mhello\x1b[0m world");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}
