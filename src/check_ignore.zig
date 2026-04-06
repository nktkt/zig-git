const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const ignore_mod = @import("ignore.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const IgnoreSource = struct {
    file_path: []const u8,
    line_number: usize,
    pattern: []const u8,
};

pub fn runCheckIgnore(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var verbose = false;
    var non_matching = false;
    var use_stdin = false;
    var nul_terminated = false;
    var paths = std.array_list.Managed([]const u8).init(allocator);
    defer paths.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--non-matching")) {
            non_matching = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            use_stdin = true;
        } else if (std.mem.eql(u8, arg, "-z")) {
            nul_terminated = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try paths.append(arg);
        }
    }

    if (!use_stdin and paths.items.len == 0) {
        try stderr_file.writeAll("fatal: no path specified\n");
        std.process.exit(128);
    }

    // Compute work directory
    const work_dir = getWorkDir(repo.git_dir);

    // Load ignore rules with source tracking
    var rules = std.array_list.Managed(IgnoreRule).init(allocator);
    defer {
        for (rules.items) |*r| {
            if (r.source_file_owned) allocator.free(r.source_file);
        }
        rules.deinit();
    }

    // Load .git/info/exclude
    try loadRulesFromFile(allocator, &rules, repo.git_dir, "/info/exclude");

    // Load .gitignore from work dir root
    try loadRulesFromGitignore(allocator, &rules, work_dir);

    // Also load standard ignore rules
    var standard_ignore = ignore_mod.IgnoreRules.init(allocator);
    defer standard_ignore.deinit();
    standard_ignore.loadExclude(repo.git_dir) catch {};
    if (work_dir.len > 0) {
        standard_ignore.loadGitignore(work_dir) catch {};
    }

    const terminator: u8 = if (nul_terminated) 0 else '\n';

    if (use_stdin) {
        // Read paths from stdin
        const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
        var read_buf: [4096]u8 = undefined;
        var line_buf: [4096]u8 = undefined;
        var line_pos: usize = 0;

        while (true) {
            const n = stdin_file.readAll(&read_buf) catch break;
            if (n == 0) break;

            var j: usize = 0;
            while (j < n) : (j += 1) {
                const separator: u8 = if (nul_terminated) 0 else '\n';
                if (read_buf[j] == separator) {
                    if (line_pos > 0) {
                        const path = line_buf[0..line_pos];
                        try checkPath(path, &standard_ignore, &rules, verbose, non_matching, terminator);
                    }
                    line_pos = 0;
                } else {
                    if (line_pos < line_buf.len) {
                        line_buf[line_pos] = read_buf[j];
                        line_pos += 1;
                    }
                }
            }

            if (n < read_buf.len) break;
        }

        // Handle last line without terminator
        if (line_pos > 0) {
            const path = line_buf[0..line_pos];
            try checkPath(path, &standard_ignore, &rules, verbose, non_matching, terminator);
        }
    } else {
        for (paths.items) |path| {
            try checkPath(path, &standard_ignore, &rules, verbose, non_matching, terminator);
        }
    }
}

fn checkPath(
    path: []const u8,
    ignore: *const ignore_mod.IgnoreRules,
    rules: *const std.array_list.Managed(IgnoreRule),
    verbose: bool,
    non_matching: bool,
    terminator: u8,
) !void {
    // Check if it's a directory
    const is_dir = blk: {
        var path_buf: [4096]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        // Try to stat the path
        break :blk false; // Simplified: treat all as files
    };

    const is_ignored = ignore.isIgnored(path, is_dir);

    if (verbose) {
        // Find matching rule
        const match = findMatchingRule(rules, path, is_dir);
        if (is_ignored) {
            if (match) |m| {
                var buf: [1024]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "{s}:{d}:{s}\t", .{
                    m.source_file,
                    m.line_number,
                    m.pattern,
                }) catch {
                    try stdout_file.writeAll("::\t");
                    try stdout_file.writeAll(path);
                    var term: [1]u8 = .{terminator};
                    try stdout_file.writeAll(&term);
                    return;
                };
                try stdout_file.writeAll(line);
            } else {
                try stdout_file.writeAll("::\t");
            }
            try stdout_file.writeAll(path);
            var term: [1]u8 = .{terminator};
            try stdout_file.writeAll(&term);
        } else if (non_matching) {
            try stdout_file.writeAll("::\t");
            try stdout_file.writeAll(path);
            var term: [1]u8 = .{terminator};
            try stdout_file.writeAll(&term);
        }
    } else {
        if (is_ignored) {
            try stdout_file.writeAll(path);
            var term: [1]u8 = .{terminator};
            try stdout_file.writeAll(&term);
        } else if (non_matching) {
            // In non-matching mode with no verbose, git still outputs only ignored files
            // by default. -n with -v shows non-matching.
        }
    }
}

const IgnoreRule = struct {
    pattern: []const u8,
    negated: bool,
    dir_only: bool,
    anchored: bool,
    source_file: []const u8,
    source_file_owned: bool,
    line_number: usize,
};

fn loadRulesFromFile(
    allocator: std.mem.Allocator,
    rules: *std.array_list.Managed(IgnoreRule),
    git_dir: []const u8,
    suffix: []const u8,
) !void {
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    @memcpy(path_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    const file_path = path_buf[0..pos];

    const owned_path = try allocator.alloc(u8, file_path.len);
    @memcpy(owned_path, file_path);

    loadRulesFromPath(allocator, rules, file_path, owned_path) catch {
        allocator.free(owned_path);
    };
}

fn loadRulesFromGitignore(
    allocator: std.mem.Allocator,
    rules: *std.array_list.Managed(IgnoreRule),
    work_dir: []const u8,
) !void {
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..work_dir.len], work_dir);
    pos += work_dir.len;
    const suffix = "/.gitignore";
    @memcpy(path_buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    const file_path = path_buf[0..pos];

    const owned_path = try allocator.alloc(u8, file_path.len);
    @memcpy(owned_path, file_path);

    loadRulesFromPath(allocator, rules, file_path, owned_path) catch {
        allocator.free(owned_path);
    };
}

fn loadRulesFromPath(
    allocator: std.mem.Allocator,
    rules: *std.array_list.Managed(IgnoreRule),
    file_path: []const u8,
    source_display: []const u8,
) !void {
    const file = std.fs.openFileAbsolute(file_path, .{}) catch return;
    defer file.close();

    const stat = try file.stat();
    if (stat.size == 0 or stat.size > 1024 * 1024) return;

    const data = try allocator.alloc(u8, stat.size);
    defer allocator.free(data);
    const n = try file.readAll(data);

    var line_num: usize = 0;
    var lines = std.mem.splitScalar(u8, data[0..n], '\n');
    while (lines.next()) |raw_line| {
        line_num += 1;
        var line = std.mem.trimRight(u8, raw_line, "\r ");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        var negated = false;
        if (line[0] == '!') {
            negated = true;
            line = line[1..];
            if (line.len == 0) continue;
        }

        var dir_only = false;
        if (line.len > 0 and line[line.len - 1] == '/') {
            dir_only = true;
            line = line[0 .. line.len - 1];
            if (line.len == 0) continue;
        }

        var anchored = false;
        if (line[0] == '/') {
            anchored = true;
            line = line[1..];
            if (line.len == 0) continue;
        } else if (std.mem.indexOfScalar(u8, line, '/') != null) {
            anchored = true;
        }

        try rules.append(.{
            .pattern = line,
            .negated = negated,
            .dir_only = dir_only,
            .anchored = anchored,
            .source_file = source_display,
            .source_file_owned = false, // The display path is managed by the first caller
            .line_number = line_num,
        });
    }
}

fn findMatchingRule(
    rules: *const std.array_list.Managed(IgnoreRule),
    path: []const u8,
    is_dir: bool,
) ?*const IgnoreRule {
    var last_match: ?*const IgnoreRule = null;

    for (rules.items) |*rule| {
        if (rule.dir_only and !is_dir) continue;
        // Simple pattern matching
        if (matchesRule(rule.pattern, path, rule.anchored)) {
            if (!rule.negated) {
                last_match = rule;
            } else {
                last_match = null;
            }
        }
    }

    return last_match;
}

fn matchesRule(pattern: []const u8, path: []const u8, anchored: bool) bool {
    if (anchored) {
        return simpleGlobMatch(pattern, path);
    }

    // Unanchored: match against full path or basename
    if (simpleGlobMatch(pattern, path)) return true;

    // Try basename
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |last_slash| {
        return simpleGlobMatch(pattern, path[last_slash + 1 ..]);
    }

    return false;
}

fn simpleGlobMatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;

    while (pi < pattern.len) {
        if (pattern[pi] == '*') {
            pi += 1;
            if (pi == pattern.len) {
                // Trailing * matches rest (except /)
                while (ti < text.len) {
                    if (text[ti] == '/') return false;
                    ti += 1;
                }
                return true;
            }
            while (ti <= text.len) {
                if (simpleGlobMatch(pattern[pi..], text[ti..])) return true;
                if (ti >= text.len) break;
                if (text[ti] == '/') break;
                ti += 1;
            }
            return false;
        } else if (pattern[pi] == '?') {
            if (ti >= text.len or text[ti] == '/') return false;
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

fn getWorkDir(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    return git_dir;
}
