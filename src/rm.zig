const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const rm_usage =
    \\usage: zig-git rm [--cached] [-f] [-r] [-q] [--] <file>...
    \\
    \\  --cached         Only remove from the index (unstage)
    \\  -f, --force      Override the up-to-date check
    \\  -r               Allow recursive removal
    \\  -q, --quiet      Do not list removed files
    \\  -n, --dry-run    Don't actually remove anything, just show what would be done
    \\
;

/// Options parsed from command line arguments.
const RmOptions = struct {
    /// Only remove from the index, keep the file on disk.
    cached: bool = false,
    /// Force removal even if the file has local modifications.
    force: bool = false,
    /// Allow recursive removal of directories.
    recursive: bool = false,
    /// Quiet mode: don't report removed files.
    quiet: bool = false,
    /// Dry run: just show what would be removed.
    dry_run: bool = false,
    /// Paths to remove.
    paths: std.array_list.Managed([]const u8),
};

/// Entry point for the rm command.
pub fn runRm(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = RmOptions{
        .paths = std.array_list.Managed([]const u8).init(allocator),
    };
    defer opts.paths.deinit();

    // Parse arguments
    var i: usize = 0;
    var past_separator = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (past_separator) {
            try opts.paths.append(arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            past_separator = true;
        } else if (std.mem.eql(u8, arg, "--cached")) {
            opts.cached = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, arg, "-r")) {
            opts.recursive = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "-rf") or std.mem.eql(u8, arg, "-fr")) {
            opts.recursive = true;
            opts.force = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: unknown option '{s}'\n", .{arg}) catch "fatal: unknown option\n";
            try stderr_file.writeAll(msg);
            std.process.exit(1);
        } else {
            try opts.paths.append(arg);
        }
    }

    if (opts.paths.items.len == 0) {
        try stderr_file.writeAll(rm_usage);
        std.process.exit(1);
    }

    // Get working directory
    const work_dir = getWorkDir(repo.git_dir);

    // Load existing index
    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPath(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    // Collect all entries to remove (expanding directories if -r)
    var entries_to_remove = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (entries_to_remove.items) |p| allocator.free(p);
        entries_to_remove.deinit();
    }

    for (opts.paths.items) |path| {
        // Normalize path: remove trailing slashes
        const clean_path = std.mem.trimRight(u8, path, "/");
        if (clean_path.len == 0) continue;

        // Check if this is a directory (prefix match in index)
        const is_dir_in_index = isDirectoryInIndex(&idx, clean_path);

        if (is_dir_in_index) {
            if (!opts.recursive) {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: not removing '{s}' recursively without -r\n", .{clean_path}) catch "fatal: not removing recursively without -r\n";
                try stderr_file.writeAll(msg);
                std.process.exit(1);
            }

            // Collect all index entries under this directory
            try collectDirEntries(allocator, &idx, clean_path, &entries_to_remove);
        } else {
            // Single file
            if (idx.findEntry(clean_path) == null) {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: pathspec '{s}' did not match any files\n", .{clean_path}) catch "fatal: pathspec did not match any files\n";
                try stderr_file.writeAll(msg);
                std.process.exit(1);
            }

            const owned = try allocator.alloc(u8, clean_path.len);
            @memcpy(owned, clean_path);
            try entries_to_remove.append(owned);
        }
    }

    if (entries_to_remove.items.len == 0) {
        try stderr_file.writeAll("fatal: no files specified for removal\n");
        std.process.exit(1);
    }

    // Safety check: verify files are not locally modified (unless --force or --cached)
    if (!opts.force and !opts.cached) {
        for (entries_to_remove.items) |entry_name| {
            if (isLocallyModified(work_dir, &idx, entry_name)) {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "error: the following file has local modifications:\n    {s}\n(use --cached to keep the file, or -f to force removal)\n", .{entry_name}) catch "error: file has local modifications\n";
                try stderr_file.writeAll(msg);
                std.process.exit(1);
            }
        }
    }

    // Sort entries for consistent output
    sortStrings(entries_to_remove.items);

    // Remove entries
    var removed_count: usize = 0;
    for (entries_to_remove.items) |entry_name| {
        if (opts.dry_run) {
            var buf: [4096]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "rm '{s}'\n", .{entry_name}) catch continue;
            try stdout_file.writeAll(msg);
            removed_count += 1;
            continue;
        }

        // Remove from index
        const did_remove = idx.removeEntry(entry_name);
        if (!did_remove) continue;

        // Remove from working tree (unless --cached)
        if (!opts.cached) {
            var abs_buf: [4096]u8 = undefined;
            const abs_path = buildPath2(&abs_buf, work_dir, "/", entry_name);

            std.fs.deleteFileAbsolute(abs_path) catch |err| {
                // File might already be deleted - that's OK
                switch (err) {
                    error.FileNotFound => {},
                    else => {
                        var buf: [512]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "warning: could not remove '{s}': {s}\n", .{ entry_name, @errorName(err) }) catch "warning: could not remove file\n";
                        stderr_file.writeAll(msg) catch {};
                    },
                }
            };

            // Try to remove empty parent directories
            tryRemoveEmptyParents(work_dir, entry_name);
        }

        if (!opts.quiet) {
            var buf: [4096]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "rm '{s}'\n", .{entry_name}) catch continue;
            try stdout_file.writeAll(msg);
        }
        removed_count += 1;
    }

    // Write updated index (unless dry run)
    if (!opts.dry_run and removed_count > 0) {
        try idx.writeToFile(index_path);
    }
}

/// Check if a given path represents a directory in the index
/// (i.e., there are entries with this path as a prefix).
fn isDirectoryInIndex(idx: *const index_mod.Index, path: []const u8) bool {
    var prefix_buf: [4096]u8 = undefined;
    @memcpy(prefix_buf[0..path.len], path);
    prefix_buf[path.len] = '/';
    const prefix = prefix_buf[0 .. path.len + 1];

    for (idx.entries.items) |*entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) return true;
    }
    return false;
}

/// Collect all index entries that are under the given directory path.
fn collectDirEntries(
    allocator: std.mem.Allocator,
    idx: *const index_mod.Index,
    dir_path: []const u8,
    result: *std.array_list.Managed([]const u8),
) !void {
    var prefix_buf: [4096]u8 = undefined;
    @memcpy(prefix_buf[0..dir_path.len], dir_path);
    prefix_buf[dir_path.len] = '/';
    const prefix = prefix_buf[0 .. dir_path.len + 1];

    for (idx.entries.items) |*entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) {
            const owned = try allocator.alloc(u8, entry.name.len);
            @memcpy(owned, entry.name);
            try result.append(owned);
        }
    }
}

/// Check if a file in the working tree has been modified compared to the index.
fn isLocallyModified(work_dir: []const u8, idx: *const index_mod.Index, name: []const u8) bool {
    const entry_idx = idx.findEntry(name) orelse return false;
    const entry = &idx.entries.items[entry_idx];

    var abs_buf: [4096]u8 = undefined;
    const abs_path = buildPath2(&abs_buf, work_dir, "/", name);

    const file = std.fs.openFileAbsolute(abs_path, .{}) catch {
        // File doesn't exist on disk - it's considered "modified" (deleted)
        return true;
    };
    defer file.close();

    const stat = file.stat() catch return true;

    // Quick size check
    if (@as(u32, @intCast(stat.size)) != entry.file_size) return true;

    // Check mtime
    const mtime_s: u32 = @intCast(@divFloor(stat.mtime, 1_000_000_000));
    const mtime_ns: u32 = @intCast(@mod(stat.mtime, 1_000_000_000));
    if (mtime_s == entry.mtime_s and mtime_ns == entry.mtime_ns) return false;

    // mtime changed, need to hash
    var content_buf: [1024 * 1024]u8 = undefined;
    const n = file.readAll(&content_buf) catch return true;
    const content = content_buf[0..n];

    const hash_mod = @import("hash.zig");
    var header_buf: [64]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    hwriter.writeAll("blob ") catch return true;
    hwriter.print("{d}", .{n}) catch return true;
    hwriter.writeByte(0) catch return true;
    const header = header_buf[0..hstream.pos];

    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(header);
    hasher.update(content);
    const digest = hasher.finalResult();
    const computed_oid = types.ObjectId{ .bytes = digest };

    return !computed_oid.eql(&entry.oid);
}

/// Try to remove empty parent directories up to the work_dir root.
fn tryRemoveEmptyParents(work_dir: []const u8, rel_path: []const u8) void {
    var parent_buf: [4096]u8 = undefined;
    var current = rel_path;

    while (true) {
        const dir_name = std.fs.path.dirname(current) orelse break;
        if (dir_name.len == 0) break;

        var abs_buf: [4096]u8 = undefined;
        const abs_path = buildPath2Mut(&abs_buf, work_dir, "/", dir_name);

        // Try to delete the directory (will fail if not empty)
        std.fs.deleteDirAbsolute(abs_path) catch break;

        // Move to parent
        if (dir_name.len >= parent_buf.len) break;
        @memcpy(parent_buf[0..dir_name.len], dir_name);
        current = parent_buf[0..dir_name.len];
    }
}

fn buildPath2Mut(buf: []u8, a: []const u8, sep: []const u8, b: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..a.len], a);
    pos += a.len;
    @memcpy(buf[pos..][0..sep.len], sep);
    pos += sep.len;
    @memcpy(buf[pos..][0..b.len], b);
    pos += b.len;
    return buf[0..pos];
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

test "isDirectoryInIndex" {
    var idx = index_mod.Index.init(std.testing.allocator);
    defer idx.deinit();

    // Add a sample entry
    const name = try std.testing.allocator.alloc(u8, "src/main.zig".len);
    @memcpy(name, "src/main.zig");

    try idx.addEntry(.{
        .ctime_s = 0,
        .ctime_ns = 0,
        .mtime_s = 0,
        .mtime_ns = 0,
        .dev = 0,
        .ino = 0,
        .mode = 0o100644,
        .uid = 0,
        .gid = 0,
        .file_size = 0,
        .oid = types.ObjectId.ZERO,
        .flags = 0,
        .name = name,
        .owned = true,
    });

    try std.testing.expect(isDirectoryInIndex(&idx, "src"));
    try std.testing.expect(!isDirectoryInIndex(&idx, "lib"));
}
