const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const ignore_mod = @import("ignore.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const clean_usage =
    \\usage: zig-git clean [-f] [-n] [-d] [-x] [-X] [--] [<pathspec>...]
    \\
    \\  -f, --force      Force removal of untracked files
    \\  -n, --dry-run    Don't actually remove anything, just show what would be done
    \\  -d               Also remove untracked directories
    \\  -x               Also remove ignored files
    \\  -X               Remove only ignored files
    \\  -q, --quiet      Only report errors, not removed files
    \\
;

/// Options parsed from command line arguments.
const CleanOptions = struct {
    /// Whether to actually delete files (requires -f or -n).
    force: bool = false,
    /// Dry run: just print what would be removed.
    dry_run: bool = false,
    /// Also remove untracked directories.
    remove_dirs: bool = false,
    /// Also remove ignored files (overrides .gitignore).
    remove_ignored: bool = false,
    /// Remove ONLY ignored files (keep untracked non-ignored).
    remove_only_ignored: bool = false,
    /// Quiet mode: don't report removed files.
    quiet: bool = false,
    /// Pathspecs to limit cleaning scope.
    pathspecs: std.array_list.Managed([]const u8),
};

/// Entry point for the clean command.
pub fn runClean(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = CleanOptions{
        .pathspecs = std.array_list.Managed([]const u8).init(allocator),
    };
    defer opts.pathspecs.deinit();

    // Parse arguments
    var i: usize = 0;
    var past_separator = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (past_separator) {
            try opts.pathspecs.append(arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            past_separator = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "-d")) {
            opts.remove_dirs = true;
        } else if (std.mem.eql(u8, arg, "-x")) {
            opts.remove_ignored = true;
        } else if (std.mem.eql(u8, arg, "-X")) {
            opts.remove_only_ignored = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, arg, "-fd") or std.mem.eql(u8, arg, "-df")) {
            opts.force = true;
            opts.remove_dirs = true;
        } else if (std.mem.eql(u8, arg, "-fx") or std.mem.eql(u8, arg, "-xf")) {
            opts.force = true;
            opts.remove_ignored = true;
        } else if (std.mem.eql(u8, arg, "-fdx") or std.mem.eql(u8, arg, "-fxd") or
            std.mem.eql(u8, arg, "-dfx") or std.mem.eql(u8, arg, "-dxf") or
            std.mem.eql(u8, arg, "-xdf") or std.mem.eql(u8, arg, "-xfd"))
        {
            opts.force = true;
            opts.remove_dirs = true;
            opts.remove_ignored = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: unknown option '{s}'\n", .{arg}) catch "fatal: unknown option\n";
            try stderr_file.writeAll(msg);
            std.process.exit(1);
        } else {
            try opts.pathspecs.append(arg);
        }
    }

    // Safety check: refuse to run without -f or -n
    if (!opts.force and !opts.dry_run) {
        try stderr_file.writeAll("fatal: clean.requireForce defaults to true and neither -i, -n, nor -f given; refusing to clean\n");
        std.process.exit(128);
    }

    // Get working directory
    const work_dir = getWorkDir(repo.git_dir);

    // Load the index
    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPath(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    // Load ignore rules (unless -x is specified)
    var ignore = ignore_mod.IgnoreRules.init(allocator);
    defer ignore.deinit();
    if (!opts.remove_ignored) {
        ignore.loadExclude(repo.git_dir) catch {};
        ignore.loadGitignore(work_dir) catch {};
    }

    // Collect files and directories to clean
    var files_to_clean = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (files_to_clean.items) |p| allocator.free(p);
        files_to_clean.deinit();
    }

    var dirs_to_clean = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (dirs_to_clean.items) |p| allocator.free(p);
        dirs_to_clean.deinit();
    }

    // Walk the working tree to find candidates
    try findCleanCandidates(
        allocator,
        work_dir,
        &idx,
        &ignore,
        &opts,
        &files_to_clean,
        &dirs_to_clean,
        "",
    );

    // Sort results for consistent output
    sortStrings(files_to_clean.items);
    sortStrings(dirs_to_clean.items);

    // Track counts for summary
    var removed_count: usize = 0;

    // Process files
    for (files_to_clean.items) |rel_path| {
        // Check pathspec filter
        if (opts.pathspecs.items.len > 0) {
            if (!matchesAnyPathspec(rel_path, opts.pathspecs.items)) continue;
        }

        if (opts.dry_run) {
            var buf: [4096]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Would remove {s}\n", .{rel_path}) catch continue;
            try stdout_file.writeAll(msg);
            removed_count += 1;
        } else {
            // Actually remove the file
            var abs_buf: [4096]u8 = undefined;
            const abs_path = buildPath2(&abs_buf, work_dir, "/", rel_path);

            std.fs.deleteFileAbsolute(abs_path) catch |err| {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "warning: could not remove '{s}': {s}\n", .{ rel_path, @errorName(err) }) catch "warning: could not remove file\n";
                stderr_file.writeAll(msg) catch {};
                continue;
            };

            if (!opts.quiet) {
                var buf: [4096]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Removing {s}\n", .{rel_path}) catch continue;
                try stdout_file.writeAll(msg);
            }
            removed_count += 1;
        }
    }

    // Process directories (only if -d is specified)
    if (opts.remove_dirs) {
        for (dirs_to_clean.items) |rel_path| {
            // Check pathspec filter
            if (opts.pathspecs.items.len > 0) {
                if (!matchesAnyPathspec(rel_path, opts.pathspecs.items)) continue;
            }

            if (opts.dry_run) {
                var buf: [4096]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Would remove {s}/\n", .{rel_path}) catch continue;
                try stdout_file.writeAll(msg);
                removed_count += 1;
            } else {
                var abs_buf: [4096]u8 = undefined;
                const abs_path = buildPath2(&abs_buf, work_dir, "/", rel_path);

                deleteDirectoryRecursive(abs_path) catch |err| {
                    var buf: [512]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "warning: could not remove '{s}/': {s}\n", .{ rel_path, @errorName(err) }) catch "warning: could not remove directory\n";
                    stderr_file.writeAll(msg) catch {};
                    continue;
                };

                if (!opts.quiet) {
                    var buf: [4096]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "Removing {s}/\n", .{rel_path}) catch continue;
                    try stdout_file.writeAll(msg);
                }
                removed_count += 1;
            }
        }
    }

    // If nothing was found to clean, print a message
    if (removed_count == 0 and !opts.quiet) {
        if (opts.dry_run) {
            // Nothing to clean is fine for dry run - no output needed
        } else {
            // Nothing was cleaned
        }
    }
}

/// Recursively find untracked files and directories that should be cleaned.
fn findCleanCandidates(
    allocator: std.mem.Allocator,
    work_dir: []const u8,
    idx: *const index_mod.Index,
    ignore: *const ignore_mod.IgnoreRules,
    opts: *const CleanOptions,
    files: *std.array_list.Managed([]const u8),
    dirs: *std.array_list.Managed([]const u8),
    prefix: []const u8,
) !void {
    var dir_path_buf: [4096]u8 = undefined;
    const dir_path = if (prefix.len == 0)
        buildPath(&dir_path_buf, work_dir, "")
    else
        buildPath2(&dir_path_buf, work_dir, "/", prefix);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip .git directory
        if (std.mem.eql(u8, entry.name, ".git")) continue;

        // Build relative path
        var rel_path_buf: [4096]u8 = undefined;
        const rel_path = if (prefix.len == 0)
            buildPath(&rel_path_buf, entry.name, "")
        else
            buildPath2(&rel_path_buf, prefix, "/", entry.name);

        const is_dir = entry.kind == .directory;

        // Handle -X: only clean ignored files
        if (opts.remove_only_ignored) {
            if (is_dir) {
                // Recurse into directories to find ignored files within
                try findCleanCandidates(allocator, work_dir, idx, ignore, opts, files, dirs, rel_path);
            } else {
                // Only remove if the file is ignored
                if (ignore.isIgnored(rel_path, false)) {
                    const owned = try allocator.alloc(u8, rel_path.len);
                    @memcpy(owned, rel_path);
                    try files.append(owned);
                }
            }
            continue;
        }

        // Check ignore rules (when not using -x)
        if (!opts.remove_ignored and ignore.isIgnored(rel_path, is_dir)) continue;

        if (is_dir) {
            // Check if any tracked files exist under this directory
            var has_tracked = false;
            var dir_prefix_buf: [4096]u8 = undefined;
            var dps = std.io.fixedBufferStream(&dir_prefix_buf);
            const dpw = dps.writer();
            dpw.writeAll(rel_path) catch continue;
            dpw.writeByte('/') catch continue;
            const dir_prefix = dir_prefix_buf[0..dps.pos];

            for (idx.entries.items) |*ie| {
                if (std.mem.startsWith(u8, ie.name, dir_prefix)) {
                    has_tracked = true;
                    break;
                }
            }

            if (has_tracked) {
                // Has tracked files, recurse to find untracked ones inside
                try findCleanCandidates(allocator, work_dir, idx, ignore, opts, files, dirs, rel_path);
            } else {
                // Entirely untracked directory
                if (opts.remove_dirs) {
                    const owned = try allocator.alloc(u8, rel_path.len);
                    @memcpy(owned, rel_path);
                    try dirs.append(owned);
                }
            }
        } else {
            // Check if file is tracked (in index)
            if (idx.findEntry(rel_path) == null) {
                const owned = try allocator.alloc(u8, rel_path.len);
                @memcpy(owned, rel_path);
                try files.append(owned);
            }
        }
    }
}

/// Check if a path matches any of the given pathspecs.
fn matchesAnyPathspec(path: []const u8, pathspecs: []const []const u8) bool {
    for (pathspecs) |spec| {
        if (matchPathspec(path, spec)) return true;
    }
    return false;
}

/// Match a path against a pathspec.
/// Supports simple prefix matching and exact matching.
fn matchPathspec(path: []const u8, spec: []const u8) bool {
    // Exact match
    if (std.mem.eql(u8, path, spec)) return true;

    // "." matches everything
    if (std.mem.eql(u8, spec, ".")) return true;

    // Prefix match (spec is a directory prefix)
    if (std.mem.startsWith(u8, path, spec)) {
        if (spec.len < path.len and path[spec.len] == '/') return true;
    }

    // The spec could also be a directory without trailing slash
    var spec_dir_buf: [4096]u8 = undefined;
    if (spec.len + 1 <= spec_dir_buf.len) {
        @memcpy(spec_dir_buf[0..spec.len], spec);
        spec_dir_buf[spec.len] = '/';
        const spec_dir = spec_dir_buf[0 .. spec.len + 1];
        if (std.mem.startsWith(u8, path, spec_dir)) return true;
    }

    return false;
}

/// Recursively delete a directory and all its contents.
fn deleteDirectoryRecursive(path: []const u8) !void {
    // First, remove all contents
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        var child_buf: [4096]u8 = undefined;
        const child_path = buildPath2(&child_buf, path, "/", entry.name);

        if (entry.kind == .directory) {
            deleteDirectoryRecursive(child_path) catch {};
        } else {
            std.fs.deleteFileAbsolute(child_path) catch {};
        }
    }

    // Now remove the empty directory
    // Close the directory handle first - we already deferred that
    dir.close();
    // Reopen as we need the handle closed to delete on some platforms
    std.fs.deleteDirAbsolute(path) catch {};
}

/// Sort a slice of strings alphabetically.
fn sortStrings(items: [][]const u8) void {
    for (items, 0..) |_, i_idx| {
        if (i_idx == 0) continue;
        var j = i_idx;
        while (j > 0 and std.mem.order(u8, items[j], items[j - 1]) == .lt) {
            const tmp = items[j];
            items[j] = items[j - 1];
            items[j - 1] = tmp;
            j -= 1;
        }
    }
}

// ── Utility functions ──────────────────────────────────────────────────────

fn buildPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn buildPath2(buf: []u8, a: []const u8, sep: []const u8, b: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..a.len], a);
    pos += a.len;
    @memcpy(buf[pos..][0..sep.len], sep);
    pos += sep.len;
    @memcpy(buf[pos..][0..b.len], b);
    pos += b.len;
    return buf[0..pos];
}

fn getWorkDir(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    if (std.fs.path.dirname(git_dir)) |parent| {
        return parent;
    }
    return git_dir;
}

test "matchPathspec" {
    try std.testing.expect(matchPathspec("src/main.zig", "src"));
    try std.testing.expect(matchPathspec("src/main.zig", "src/main.zig"));
    try std.testing.expect(matchPathspec("src/main.zig", "."));
    try std.testing.expect(!matchPathspec("src/main.zig", "lib"));
    try std.testing.expect(!matchPathspec("src/main.zig", "main.zig"));
}

test "matchesAnyPathspec" {
    const specs = [_][]const u8{ "src", "lib" };
    try std.testing.expect(matchesAnyPathspec("src/main.zig", &specs));
    try std.testing.expect(matchesAnyPathspec("lib/util.zig", &specs));
    try std.testing.expect(!matchesAnyPathspec("test/foo.zig", &specs));
}
