const std = @import("std");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");

/// Sparse checkout mode.
pub const SparseMode = enum {
    /// Full: traditional sparse-checkout with pattern file
    full,
    /// Cone: directory-based patterns (faster, more restricted)
    cone,
};

/// Sparse checkout state.
pub const SparseCheckout = struct {
    allocator: std.mem.Allocator,
    patterns: std.array_list.Managed(SparsePattern),
    mode: SparseMode,
    enabled: bool,
    /// Owned string data
    owned_data: std.array_list.Managed([]u8),

    pub fn init(allocator: std.mem.Allocator) SparseCheckout {
        return .{
            .allocator = allocator,
            .patterns = std.array_list.Managed(SparsePattern).init(allocator),
            .mode = .cone,
            .enabled = false,
            .owned_data = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *SparseCheckout) void {
        for (self.owned_data.items) |d| {
            self.allocator.free(d);
        }
        self.owned_data.deinit();
        self.patterns.deinit();
    }

    /// Load sparse-checkout patterns from .git/info/sparse-checkout.
    pub fn load(self: *SparseCheckout, git_dir: []const u8) !void {
        var path_buf: [4096]u8 = undefined;
        const path = buildPath(&path_buf, git_dir, "/info/sparse-checkout");

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

        self.enabled = true;

        var lines = std.mem.splitScalar(u8, data[0..n], '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r \t");
            if (line.len == 0) continue;
            if (line[0] == '#') continue;

            var negated = false;
            var pattern = line;
            if (pattern[0] == '!') {
                negated = true;
                pattern = pattern[1..];
                if (pattern.len == 0) continue;
            }

            try self.patterns.append(.{
                .pattern = pattern,
                .negated = negated,
            });
        }
    }

    /// Save sparse-checkout patterns to .git/info/sparse-checkout.
    pub fn save(self: *const SparseCheckout, git_dir: []const u8) !void {
        // Ensure info directory exists
        var info_path_buf: [4096]u8 = undefined;
        const info_path = buildPath(&info_path_buf, git_dir, "/info");
        std.fs.makeDirAbsolute(info_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var path_buf: [4096]u8 = undefined;
        const path = buildPath(&path_buf, git_dir, "/info/sparse-checkout");

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();

        for (self.patterns.items) |*pat| {
            if (pat.negated) {
                try file.writeAll("!");
            }
            try file.writeAll(pat.pattern);
            try file.writeAll("\n");
        }
    }

    /// Check if a path matches the sparse checkout patterns.
    /// Returns true if the path should be included in the working tree.
    pub fn matchesPath(self: *const SparseCheckout, path: []const u8) bool {
        if (!self.enabled) return true;
        if (self.patterns.items.len == 0) return true;

        var included = false;

        for (self.patterns.items) |*pat| {
            if (patternMatches(pat.pattern, path)) {
                included = !pat.negated;
            }
        }

        return included;
    }

    /// Set patterns, replacing all existing ones.
    pub fn setPatterns(self: *SparseCheckout, patterns: []const []const u8) !void {
        self.patterns.clearRetainingCapacity();
        // Free old owned data
        for (self.owned_data.items) |d| {
            self.allocator.free(d);
        }
        self.owned_data.clearRetainingCapacity();

        for (patterns) |pat| {
            const owned = try self.allocator.alloc(u8, pat.len);
            @memcpy(owned, pat);
            try self.owned_data.append(owned);
            try self.patterns.append(.{
                .pattern = owned,
                .negated = false,
            });
        }
        self.enabled = true;
    }

    /// Add patterns without removing existing ones.
    pub fn addPatterns(self: *SparseCheckout, patterns: []const []const u8) !void {
        for (patterns) |pat| {
            const owned = try self.allocator.alloc(u8, pat.len);
            @memcpy(owned, pat);
            try self.owned_data.append(owned);
            try self.patterns.append(.{
                .pattern = owned,
                .negated = false,
            });
        }
        if (!self.enabled and patterns.len > 0) self.enabled = true;
    }

    /// Disable sparse checkout.
    pub fn disable(self: *SparseCheckout) void {
        self.enabled = false;
        self.patterns.clearRetainingCapacity();
    }
};

/// A single sparse checkout pattern.
pub const SparsePattern = struct {
    pattern: []const u8,
    negated: bool,
};

/// Check if a pattern matches a path.
fn patternMatches(pattern: []const u8, path: []const u8) bool {
    // Handle directory patterns (ending with /)
    if (std.mem.endsWith(u8, pattern, "/")) {
        const dir_pattern = pattern[0 .. pattern.len - 1];
        // Match if path is under this directory
        if (std.mem.startsWith(u8, path, dir_pattern)) {
            if (path.len == dir_pattern.len) return true;
            if (path.len > dir_pattern.len and path[dir_pattern.len] == '/') return true;
        }
        return false;
    }

    // Handle leading /
    var actual_pattern = pattern;
    if (pattern.len > 0 and pattern[0] == '/') {
        actual_pattern = pattern[1..];
    }

    // Handle ** patterns
    if (std.mem.startsWith(u8, actual_pattern, "**/")) {
        const rest = actual_pattern[3..];
        if (globMatch(rest, path)) return true;
        // Try matching after each /
        var i: usize = 0;
        while (i < path.len) {
            if (path[i] == '/') {
                if (globMatch(rest, path[i + 1 ..])) return true;
            }
            i += 1;
        }
        return false;
    }

    // Simple glob match
    if (std.mem.indexOfScalar(u8, actual_pattern, '/') != null) {
        // Anchored pattern
        return globMatch(actual_pattern, path);
    }

    // Unanchored: match against basename
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
        path[idx + 1 ..]
    else
        path;

    return globMatch(actual_pattern, basename);
}

/// Simple glob matching supporting * and ?.
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
            if (pi == pattern.len) return true;
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
        } else {
            if (ti >= text.len) return false;
            if (pattern[pi] != text[ti]) return false;
            pi += 1;
            ti += 1;
        }
    }

    return ti == text.len;
}

/// Build path by concatenating two components.
fn buildPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

/// Run the sparse-checkout subcommand.
pub fn runSparseCheckout(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };

    if (args.len == 0) {
        try stderr.writeAll(
            \\usage: zig-git sparse-checkout <subcommand>
            \\
            \\  init      Enable sparse checkout
            \\  set       Set sparse checkout patterns
            \\  add       Add sparse checkout patterns
            \\  list      List sparse checkout patterns
            \\  disable   Disable sparse checkout
            \\
        );
        std.process.exit(1);
    }

    const subcmd = args[0];
    const sub_args = args[1..];

    if (std.mem.eql(u8, subcmd, "init")) {
        try sparseInit(repo, allocator);
        try stdout.writeAll("Sparse checkout initialized.\n");
    } else if (std.mem.eql(u8, subcmd, "set")) {
        try sparseSet(repo, allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "add")) {
        try sparseAdd(repo, allocator, sub_args);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try sparseList(repo, allocator, stdout);
    } else if (std.mem.eql(u8, subcmd, "disable")) {
        try sparseDisable(repo, allocator);
        try stdout.writeAll("Sparse checkout disabled.\n");
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: unknown subcommand: {s}\n", .{subcmd}) catch "error: unknown subcommand\n";
        try stderr.writeAll(msg);
        std.process.exit(1);
    }
}

fn sparseInit(repo: *repository.Repository, allocator: std.mem.Allocator) !void {
    var sc = SparseCheckout.init(allocator);
    defer sc.deinit();

    // Default cone mode: include everything at top level
    const default_patterns = [_][]const u8{"/*"};
    try sc.setPatterns(&default_patterns);
    try sc.save(repo.git_dir);
}

fn sparseSet(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };
        try stderr.writeAll("error: no patterns specified\n");
        std.process.exit(1);
    }

    var sc = SparseCheckout.init(allocator);
    defer sc.deinit();

    try sc.setPatterns(args);
    try sc.save(repo.git_dir);
}

fn sparseAdd(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };
        try stderr.writeAll("error: no patterns specified\n");
        std.process.exit(1);
    }

    var sc = SparseCheckout.init(allocator);
    defer sc.deinit();

    sc.load(repo.git_dir) catch {};
    try sc.addPatterns(args);
    try sc.save(repo.git_dir);
}

fn sparseList(repo: *repository.Repository, allocator: std.mem.Allocator, stdout: std.fs.File) !void {
    var sc = SparseCheckout.init(allocator);
    defer sc.deinit();

    sc.load(repo.git_dir) catch {
        try stdout.writeAll("Sparse checkout is not initialized.\n");
        return;
    };

    if (!sc.enabled or sc.patterns.items.len == 0) {
        try stdout.writeAll("Sparse checkout is not initialized.\n");
        return;
    }

    for (sc.patterns.items) |*pat| {
        if (pat.negated) {
            try stdout.writeAll("!");
        }
        try stdout.writeAll(pat.pattern);
        try stdout.writeAll("\n");
    }
}

fn sparseDisable(repo: *repository.Repository, allocator: std.mem.Allocator) !void {
    // Remove the sparse-checkout file
    var path_buf: [4096]u8 = undefined;
    const path = buildPath(&path_buf, repo.git_dir, "/info/sparse-checkout");

    std.fs.deleteFileAbsolute(path) catch {};
    _ = allocator;
}

test "SparseCheckout basic" {
    var sc = SparseCheckout.init(std.testing.allocator);
    defer sc.deinit();

    const patterns = [_][]const u8{ "src/", "docs/" };
    try sc.setPatterns(&patterns);

    try std.testing.expect(sc.enabled);
    try std.testing.expectEqual(@as(usize, 2), sc.patterns.items.len);
}

test "patternMatches directory" {
    try std.testing.expect(patternMatches("src/", "src/main.zig"));
    try std.testing.expect(patternMatches("src/", "src"));
    try std.testing.expect(!patternMatches("src/", "lib/main.zig"));
}

test "patternMatches glob" {
    try std.testing.expect(patternMatches("*.zig", "main.zig"));
    try std.testing.expect(patternMatches("*.zig", "src/main.zig"));
    try std.testing.expect(!patternMatches("*.zig", "main.rs"));
}

test "patternMatches anchored" {
    try std.testing.expect(patternMatches("/src/*.zig", "src/main.zig"));
    try std.testing.expect(!patternMatches("/src/*.zig", "lib/main.zig"));
}

test "SparseCheckout matchesPath" {
    var sc = SparseCheckout.init(std.testing.allocator);
    defer sc.deinit();

    const patterns = [_][]const u8{"src/"};
    try sc.setPatterns(&patterns);

    try std.testing.expect(sc.matchesPath("src/main.zig"));
    try std.testing.expect(!sc.matchesPath("lib/util.zig"));
}

test "SparseCheckout disabled matches everything" {
    var sc = SparseCheckout.init(std.testing.allocator);
    defer sc.deinit();

    try std.testing.expect(sc.matchesPath("anything"));
    try std.testing.expect(sc.matchesPath("src/file.zig"));
}

test "SparseCheckout addPatterns" {
    var sc = SparseCheckout.init(std.testing.allocator);
    defer sc.deinit();

    const initial = [_][]const u8{"src/"};
    try sc.setPatterns(&initial);

    const additional = [_][]const u8{"docs/"};
    try sc.addPatterns(&additional);

    try std.testing.expectEqual(@as(usize, 2), sc.patterns.items.len);
}
