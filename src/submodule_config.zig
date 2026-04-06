const std = @import("std");
const config_mod = @import("config.zig");

/// Configuration for a single submodule.
pub const SubmoduleConfig = struct {
    name: []const u8,
    path: []const u8,
    url: []const u8,
    branch: []const u8,
    update_strategy: UpdateStrategy,
    fetch_recurse: bool,
    ignore: IgnoreMode,
    shallow: bool,
};

/// How submodule updates are performed.
pub const UpdateStrategy = enum {
    checkout,
    rebase,
    merge,
    none,

    pub fn fromString(s: []const u8) UpdateStrategy {
        if (std.mem.eql(u8, s, "rebase")) return .rebase;
        if (std.mem.eql(u8, s, "merge")) return .merge;
        if (std.mem.eql(u8, s, "none")) return .none;
        return .checkout;
    }

    pub fn toString(self: UpdateStrategy) []const u8 {
        return switch (self) {
            .checkout => "checkout",
            .rebase => "rebase",
            .merge => "merge",
            .none => "none",
        };
    }
};

/// How changes in a submodule are reported.
pub const IgnoreMode = enum {
    none,
    untracked,
    dirty,
    all,

    pub fn fromString(s: []const u8) IgnoreMode {
        if (std.mem.eql(u8, s, "untracked")) return .untracked;
        if (std.mem.eql(u8, s, "dirty")) return .dirty;
        if (std.mem.eql(u8, s, "all")) return .all;
        return .none;
    }

    pub fn toString(self: IgnoreMode) []const u8 {
        return switch (self) {
            .none => "none",
            .untracked => "untracked",
            .dirty => "dirty",
            .all => "all",
        };
    }
};

/// Parsed .gitmodules file containing all submodule configurations.
pub const GitModules = struct {
    allocator: std.mem.Allocator,
    submodules: std.array_list.Managed(OwnedSubmoduleConfig),
    /// Map from submodule name to index in submodules list.
    name_map: std.StringHashMap(usize),
    /// Map from submodule path to index in submodules list.
    path_map: std.StringHashMap(usize),

    const OwnedSubmoduleConfig = struct {
        name: []u8,
        path: []u8,
        url: []u8,
        branch: []u8,
        update_strategy: UpdateStrategy,
        fetch_recurse: bool,
        ignore: IgnoreMode,
        shallow: bool,

        pub fn deinit(self: *OwnedSubmoduleConfig, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.path);
            allocator.free(self.url);
            if (self.branch.len > 0) allocator.free(self.branch);
        }

        pub fn toView(self: *const OwnedSubmoduleConfig) SubmoduleConfig {
            return .{
                .name = self.name,
                .path = self.path,
                .url = self.url,
                .branch = self.branch,
                .update_strategy = self.update_strategy,
                .fetch_recurse = self.fetch_recurse,
                .ignore = self.ignore,
                .shallow = self.shallow,
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator) GitModules {
        return .{
            .allocator = allocator,
            .submodules = std.array_list.Managed(OwnedSubmoduleConfig).init(allocator),
            .name_map = std.StringHashMap(usize).init(allocator),
            .path_map = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *GitModules) void {
        for (self.submodules.items) |*sm| {
            sm.deinit(self.allocator);
        }
        self.submodules.deinit();
        self.name_map.deinit();
        self.path_map.deinit();
    }

    /// Load and parse a .gitmodules file from the given path.
    pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !GitModules {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return GitModules.init(allocator),
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size > 1024 * 1024) return error.FileTooLarge;
        const content = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(content);
        const n = try file.readAll(content);

        return parseGitModules(allocator, content[0..n]);
    }

    /// Parse .gitmodules content.
    pub fn parseGitModules(allocator: std.mem.Allocator, data: []const u8) !GitModules {
        // Use Config parser as .gitmodules is INI format
        var cfg = try config_mod.Config.parse(allocator, data);
        defer cfg.deinit();

        var modules = GitModules.init(allocator);
        errdefer modules.deinit();

        // Collect all submodule names
        var seen_names = std.StringHashMap(void).init(allocator);
        defer seen_names.deinit();

        for (cfg.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.section, "submodule")) {
                if (entry.subsection) |name| {
                    if (seen_names.get(name) == null) {
                        try seen_names.put(name, {});
                    }
                }
            }
        }

        // For each submodule name, extract config
        var name_iter = seen_names.keyIterator();
        while (name_iter.next()) |name_ptr| {
            const name = name_ptr.*;
            var sm = OwnedSubmoduleConfig{
                .name = try dupeString(allocator, name),
                .path = try dupeString(allocator, ""),
                .url = try dupeString(allocator, ""),
                .branch = "",
                .update_strategy = .checkout,
                .fetch_recurse = false,
                .ignore = .none,
                .shallow = false,
            };
            errdefer sm.deinit(allocator);

            // Find matching entries
            for (cfg.entries.items) |*entry| {
                if (!std.mem.eql(u8, entry.section, "submodule")) continue;
                const subsection = entry.subsection orelse continue;
                if (!std.mem.eql(u8, subsection, name)) continue;

                if (std.mem.eql(u8, entry.key, "path")) {
                    allocator.free(sm.path);
                    sm.path = try dupeString(allocator, entry.value);
                } else if (std.mem.eql(u8, entry.key, "url")) {
                    allocator.free(sm.url);
                    sm.url = try dupeString(allocator, entry.value);
                } else if (std.mem.eql(u8, entry.key, "branch")) {
                    if (sm.branch.len > 0) allocator.free(sm.branch);
                    sm.branch = try dupeString(allocator, entry.value);
                } else if (std.mem.eql(u8, entry.key, "update")) {
                    sm.update_strategy = UpdateStrategy.fromString(entry.value);
                } else if (std.mem.eql(u8, entry.key, "fetchrecursesubmodules")) {
                    sm.fetch_recurse = std.mem.eql(u8, entry.value, "true");
                } else if (std.mem.eql(u8, entry.key, "ignore")) {
                    sm.ignore = IgnoreMode.fromString(entry.value);
                } else if (std.mem.eql(u8, entry.key, "shallow")) {
                    sm.shallow = std.mem.eql(u8, entry.value, "true");
                }
            }

            const idx = modules.submodules.items.len;
            try modules.submodules.append(sm);
            try modules.name_map.put(modules.submodules.items[idx].name, idx);
            if (modules.submodules.items[idx].path.len > 0) {
                try modules.path_map.put(modules.submodules.items[idx].path, idx);
            }
        }

        return modules;
    }

    /// Look up a submodule config by name.
    pub fn getByName(self: *const GitModules, name: []const u8) ?SubmoduleConfig {
        const idx = self.name_map.get(name) orelse return null;
        return self.submodules.items[idx].toView();
    }

    /// Look up a submodule config by path.
    pub fn getByPath(self: *const GitModules, path: []const u8) ?SubmoduleConfig {
        const idx = self.path_map.get(path) orelse return null;
        return self.submodules.items[idx].toView();
    }

    /// Serialize .gitmodules content to a string.
    pub fn serialize(self: *const GitModules, allocator: std.mem.Allocator) ![]u8 {
        var output = std.array_list.Managed(u8).init(allocator);
        errdefer output.deinit();

        var buf: [4096]u8 = undefined;
        for (self.submodules.items) |*sm| {
            const header = std.fmt.bufPrint(&buf, "[submodule \"{s}\"]\n", .{sm.name}) catch continue;
            try output.appendSlice(header);

            if (sm.path.len > 0) {
                const line = std.fmt.bufPrint(&buf, "\tpath = {s}\n", .{sm.path}) catch continue;
                try output.appendSlice(line);
            }
            if (sm.url.len > 0) {
                const line = std.fmt.bufPrint(&buf, "\turl = {s}\n", .{sm.url}) catch continue;
                try output.appendSlice(line);
            }
            if (sm.branch.len > 0) {
                const line = std.fmt.bufPrint(&buf, "\tbranch = {s}\n", .{sm.branch}) catch continue;
                try output.appendSlice(line);
            }
            if (sm.update_strategy != .checkout) {
                const line = std.fmt.bufPrint(&buf, "\tupdate = {s}\n", .{sm.update_strategy.toString()}) catch continue;
                try output.appendSlice(line);
            }
            if (sm.fetch_recurse) {
                try output.appendSlice("\tfetchRecurseSubmodules = true\n");
            }
            if (sm.ignore != .none) {
                const line = std.fmt.bufPrint(&buf, "\tignore = {s}\n", .{sm.ignore.toString()}) catch continue;
                try output.appendSlice(line);
            }
            if (sm.shallow) {
                try output.appendSlice("\tshallow = true\n");
            }
        }

        return output.toOwnedSlice();
    }

    /// Write .gitmodules content to a file.
    pub fn writeFile(self: *const GitModules, allocator: std.mem.Allocator, path: []const u8) !void {
        const content = try self.serialize(allocator);
        defer allocator.free(content);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(content);
    }

    /// Add a new submodule configuration.
    pub fn addSubmodule(self: *GitModules, name: []const u8, path: []const u8, url: []const u8) !void {
        if (self.name_map.get(name) != null) return error.SubmoduleAlreadyExists;

        var sm = OwnedSubmoduleConfig{
            .name = try dupeString(self.allocator, name),
            .path = try dupeString(self.allocator, path),
            .url = try dupeString(self.allocator, url),
            .branch = "",
            .update_strategy = .checkout,
            .fetch_recurse = false,
            .ignore = .none,
            .shallow = false,
        };
        errdefer sm.deinit(self.allocator);

        const idx = self.submodules.items.len;
        try self.submodules.append(sm);
        try self.name_map.put(self.submodules.items[idx].name, idx);
        try self.path_map.put(self.submodules.items[idx].path, idx);
    }

    /// Remove a submodule by name.
    pub fn removeSubmodule(self: *GitModules, name: []const u8) bool {
        const idx = self.name_map.get(name) orelse return false;
        _ = self.name_map.remove(name);
        const path = self.submodules.items[idx].path;
        if (path.len > 0) {
            _ = self.path_map.remove(path);
        }
        self.submodules.items[idx].deinit(self.allocator);
        _ = self.submodules.orderedRemove(idx);

        // Rebuild maps after removal since indices shifted
        self.name_map.clearRetainingCapacity();
        self.path_map.clearRetainingCapacity();
        for (self.submodules.items, 0..) |*sm, i| {
            self.name_map.put(sm.name, i) catch {};
            if (sm.path.len > 0) {
                self.path_map.put(sm.path, i) catch {};
            }
        }
        return true;
    }
};

fn dupeString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len == 0) {
        const empty = try allocator.alloc(u8, 0);
        return empty;
    }
    const copy = try allocator.alloc(u8, s.len);
    @memcpy(copy, s);
    return copy;
}

test "parse simple gitmodules" {
    const data =
        \\[submodule "lib"]
        \\    path = lib
        \\    url = https://example.com/lib.git
        \\[submodule "vendor/dep"]
        \\    path = vendor/dep
        \\    url = ../dep.git
        \\    branch = main
    ;

    var modules = try GitModules.parseGitModules(std.testing.allocator, data);
    defer modules.deinit();

    try std.testing.expectEqual(@as(usize, 2), modules.submodules.items.len);
}

test "UpdateStrategy fromString" {
    try std.testing.expectEqual(UpdateStrategy.rebase, UpdateStrategy.fromString("rebase"));
    try std.testing.expectEqual(UpdateStrategy.checkout, UpdateStrategy.fromString("unknown"));
}
