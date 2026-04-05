const std = @import("std");

/// A single entry in the config: section, optional subsection, key, and value.
pub const ConfigEntry = struct {
    section: []const u8,
    subsection: ?[]const u8,
    key: []const u8,
    value: []const u8,
};

/// Git config file parser and writer.
/// Supports INI-like format: [section], [section "subsection"], key = value
pub const Config = struct {
    allocator: std.mem.Allocator,
    entries: std.array_list.Managed(OwnedEntry),

    const OwnedEntry = struct {
        section: []u8,
        subsection: ?[]u8,
        key: []u8,
        value: []u8,

        fn deinit(self: *OwnedEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.section);
            if (self.subsection) |ss| allocator.free(ss);
            allocator.free(self.key);
            allocator.free(self.value);
        }
    };

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .allocator = allocator,
            .entries = std.array_list.Managed(OwnedEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    /// Load config from a file at the given absolute path.
    pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !Config {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return Config.init(allocator),
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size > 1024 * 1024) return error.FileTooLarge;
        const content = try allocator.alloc(u8, stat.size);
        defer allocator.free(content);
        const n = try file.readAll(content);

        return parse(allocator, content[0..n]);
    }

    /// Parse config from a byte slice.
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Config {
        var cfg = Config.init(allocator);
        errdefer cfg.deinit();

        var current_section: ?[]u8 = null;
        var current_subsection: ?[]u8 = null;

        var line_iter = std.mem.splitScalar(u8, data, '\n');
        while (line_iter.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r \t");
            const trimmed = std.mem.trimLeft(u8, line, " \t");

            // Skip empty lines and comments
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#' or trimmed[0] == ';') continue;

            // Section header
            if (trimmed[0] == '[') {
                const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse continue;
                const header = trimmed[1..close];

                // Free previous section/subsection tracking copies
                if (current_section) |s| allocator.free(s);
                if (current_subsection) |s| allocator.free(s);
                current_section = null;
                current_subsection = null;

                // Check for subsection: [section "subsection"]
                if (std.mem.indexOfScalar(u8, header, '"')) |q1| {
                    const section_part = std.mem.trimRight(u8, header[0..q1], " \t");
                    const after_q1 = header[q1 + 1 ..];
                    const q2 = std.mem.indexOfScalar(u8, after_q1, '"') orelse continue;
                    const subsection_part = after_q1[0..q2];

                    current_section = try allocator.alloc(u8, section_part.len);
                    @memcpy(current_section.?, section_part);
                    toLowerInPlace(current_section.?);

                    current_subsection = try allocator.alloc(u8, subsection_part.len);
                    @memcpy(current_subsection.?, subsection_part);
                } else {
                    current_section = try allocator.alloc(u8, header.len);
                    @memcpy(current_section.?, header);
                    toLowerInPlace(current_section.?);
                    current_subsection = null;
                }
                continue;
            }

            // Key = value line
            if (current_section) |section| {
                const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=');
                var key_str: []const u8 = undefined;
                var val_str: []const u8 = undefined;

                if (eq_pos) |eq| {
                    key_str = std.mem.trimRight(u8, trimmed[0..eq], " \t");
                    val_str = std.mem.trimLeft(u8, trimmed[eq + 1 ..], " \t");
                } else {
                    // Boolean key with no value (e.g., "bare" means bare=true)
                    key_str = trimmed;
                    val_str = "true";
                }

                const owned_section = try allocator.alloc(u8, section.len);
                @memcpy(owned_section, section);

                var owned_subsection: ?[]u8 = null;
                if (current_subsection) |ss| {
                    owned_subsection = try allocator.alloc(u8, ss.len);
                    @memcpy(owned_subsection.?, ss);
                }

                const owned_key = try allocator.alloc(u8, key_str.len);
                @memcpy(owned_key, key_str);
                toLowerInPlace(owned_key);

                const owned_value = try allocator.alloc(u8, val_str.len);
                @memcpy(owned_value, val_str);

                try cfg.entries.append(.{
                    .section = owned_section,
                    .subsection = owned_subsection,
                    .key = owned_key,
                    .value = owned_value,
                });
            }
        }

        // Free tracking copies
        if (current_section) |s| allocator.free(s);
        if (current_subsection) |s| allocator.free(s);

        return cfg;
    }

    /// Get the value of a config key.
    /// Key format: "section.key" or "section.subsection.key"
    pub fn get(self: *const Config, compound_key: []const u8) ?[]const u8 {
        const parsed = parseCompoundKey(compound_key) orelse return null;

        // Search backward to get the last (most recent) value
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = &self.entries.items[i];
            if (eqlLower(entry.section, parsed.section) and
                eqlSubsection(entry.subsection, parsed.subsection) and
                eqlLower(entry.key, parsed.key))
            {
                return entry.value;
            }
        }
        return null;
    }

    /// Set a config value. If the key already exists, update it. Otherwise, add it.
    pub fn set(self: *Config, compound_key: []const u8, value: []const u8) !void {
        const parsed = parseCompoundKey(compound_key) orelse return error.InvalidKey;

        // Search for existing entry
        for (self.entries.items) |*entry| {
            if (eqlLower(entry.section, parsed.section) and
                eqlSubsection(entry.subsection, parsed.subsection) and
                eqlLower(entry.key, parsed.key))
            {
                // Update value
                self.allocator.free(entry.value);
                entry.value = try self.allocator.alloc(u8, value.len);
                @memcpy(entry.value, value);
                return;
            }
        }

        // Add new entry
        const owned_section = try self.allocator.alloc(u8, parsed.section.len);
        @memcpy(owned_section, parsed.section);
        toLowerInPlace(owned_section);

        var owned_subsection: ?[]u8 = null;
        if (parsed.subsection) |ss| {
            owned_subsection = try self.allocator.alloc(u8, ss.len);
            @memcpy(owned_subsection.?, ss);
        }

        const owned_key = try self.allocator.alloc(u8, parsed.key.len);
        @memcpy(owned_key, parsed.key);
        toLowerInPlace(owned_key);

        const owned_value = try self.allocator.alloc(u8, value.len);
        @memcpy(owned_value, value);

        try self.entries.append(.{
            .section = owned_section,
            .subsection = owned_subsection,
            .key = owned_key,
            .value = owned_value,
        });
    }

    /// Write the config back to a file at the given absolute path.
    pub fn writeFile(self: *const Config, path: []const u8) !void {
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        var prev_section: ?[]const u8 = null;
        var prev_subsection: ?[]const u8 = null;

        for (self.entries.items) |*entry| {
            // Check if we need a new section header
            const need_header = blk: {
                if (prev_section == null) break :blk true;
                if (!std.mem.eql(u8, prev_section.?, entry.section)) break :blk true;
                if (!eqlOptional(prev_subsection, entry.subsection)) break :blk true;
                break :blk false;
            };

            if (need_header) {
                if (entry.subsection) |ss| {
                    const line = std.fmt.bufPrint(&buf, "[{s} \"{s}\"]\n", .{ entry.section, ss }) catch continue;
                    try file.writeAll(line);
                } else {
                    const line = std.fmt.bufPrint(&buf, "[{s}]\n", .{entry.section}) catch continue;
                    try file.writeAll(line);
                }
                prev_section = entry.section;
                prev_subsection = entry.subsection;
            }

            const line = std.fmt.bufPrint(&buf, "\t{s} = {s}\n", .{ entry.key, entry.value }) catch continue;
            try file.writeAll(line);
        }
    }

    /// Serialize config to a dynamically allocated string.
    pub fn serialize(self: *const Config, allocator: std.mem.Allocator) ![]u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        errdefer result.deinit();

        var buf: [4096]u8 = undefined;
        var prev_section: ?[]const u8 = null;
        var prev_subsection: ?[]const u8 = null;

        for (self.entries.items) |*entry| {
            const need_header = blk: {
                if (prev_section == null) break :blk true;
                if (!std.mem.eql(u8, prev_section.?, entry.section)) break :blk true;
                if (!eqlOptional(prev_subsection, entry.subsection)) break :blk true;
                break :blk false;
            };

            if (need_header) {
                if (entry.subsection) |ss| {
                    const line = std.fmt.bufPrint(&buf, "[{s} \"{s}\"]\n", .{ entry.section, ss }) catch continue;
                    try result.appendSlice(line);
                } else {
                    const line = std.fmt.bufPrint(&buf, "[{s}]\n", .{entry.section}) catch continue;
                    try result.appendSlice(line);
                }
                prev_section = entry.section;
                prev_subsection = entry.subsection;
            }

            const line = std.fmt.bufPrint(&buf, "\t{s} = {s}\n", .{ entry.key, entry.value }) catch continue;
            try result.appendSlice(line);
        }

        return result.toOwnedSlice();
    }
};

const ParsedKey = struct {
    section: []const u8,
    subsection: ?[]const u8,
    key: []const u8,
};

/// Parse "section.key" or "section.subsection.key" into components.
fn parseCompoundKey(compound: []const u8) ?ParsedKey {
    // Find the last dot - everything after it is the key
    const last_dot = std.mem.lastIndexOfScalar(u8, compound, '.') orelse return null;
    if (last_dot == 0 or last_dot == compound.len - 1) return null;

    const key = compound[last_dot + 1 ..];
    const prefix = compound[0..last_dot];

    // Check if prefix contains a dot (section.subsection)
    if (std.mem.indexOfScalar(u8, prefix, '.')) |dot| {
        return .{
            .section = prefix[0..dot],
            .subsection = prefix[dot + 1 ..],
            .key = key,
        };
    }

    return .{
        .section = prefix,
        .subsection = null,
        .key = key,
    };
}

fn toLowerInPlace(s: []u8) void {
    for (s) |*c| {
        if (c.* >= 'A' and c.* <= 'Z') {
            c.* = c.* + ('a' - 'A');
        }
    }
}

fn eqlLower(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la: u8 = if (ca >= 'A' and ca <= 'Z') ca + ('a' - 'A') else ca;
        const lb: u8 = if (cb >= 'A' and cb <= 'Z') cb + ('a' - 'A') else cb;
        if (la != lb) return false;
    }
    return true;
}

fn eqlSubsection(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn eqlOptional(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

test "parse simple config" {
    const data =
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = false
        \\[remote "origin"]
        \\    url = https://example.com/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
    ;

    var cfg = try Config.parse(std.testing.allocator, data);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("0", cfg.get("core.repositoryformatversion").?);
    try std.testing.expectEqualStrings("true", cfg.get("core.filemode").?);
    try std.testing.expectEqualStrings("false", cfg.get("core.bare").?);
    try std.testing.expectEqualStrings("https://example.com/repo.git", cfg.get("remote.origin.url").?);
    try std.testing.expect(cfg.get("nonexistent.key") == null);
}

test "set config value" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try cfg.set("core.bare", "false");
    try std.testing.expectEqualStrings("false", cfg.get("core.bare").?);

    // Update existing
    try cfg.set("core.bare", "true");
    try std.testing.expectEqualStrings("true", cfg.get("core.bare").?);
}

test "parse compound key" {
    const k1 = parseCompoundKey("core.bare").?;
    try std.testing.expectEqualStrings("core", k1.section);
    try std.testing.expect(k1.subsection == null);
    try std.testing.expectEqualStrings("bare", k1.key);

    const k2 = parseCompoundKey("remote.origin.url").?;
    try std.testing.expectEqualStrings("remote", k2.section);
    try std.testing.expectEqualStrings("origin", k2.subsection.?);
    try std.testing.expectEqualStrings("url", k2.key);
}
