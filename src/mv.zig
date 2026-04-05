const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const mv_usage =
    \\usage: zig-git mv [options] <source>... <destination>
    \\
    \\  -f, --force      Force renaming even if the target exists
    \\  -k               Skip move/rename errors
    \\  -n, --dry-run    Don't actually move anything, just show what would happen
    \\  -v, --verbose    Report the names of files as they are moved
    \\
;

/// Options parsed from command line arguments.
const MvOptions = struct {
    /// Force renaming even if the target exists.
    force: bool = false,
    /// Skip move/rename errors instead of failing.
    skip_errors: bool = false,
    /// Dry run: just print what would happen.
    dry_run: bool = false,
    /// Verbose: report each rename.
    verbose: bool = false,
    /// Source and destination paths (last element is destination).
    paths: std.array_list.Managed([]const u8),
};

/// A single planned move operation.
const MoveOp = struct {
    source: []const u8,
    destination: []const u8,
};

/// Entry point for the mv command.
pub fn runMv(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = MvOptions{
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
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, arg, "-k")) {
            opts.skip_errors = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: unknown option '{s}'\n", .{arg}) catch "fatal: unknown option\n";
            try stderr_file.writeAll(msg);
            std.process.exit(1);
        } else {
            try opts.paths.append(arg);
        }
    }

    if (opts.paths.items.len < 2) {
        try stderr_file.writeAll(mv_usage);
        std.process.exit(1);
    }

    // Get working directory
    const work_dir = getWorkDir(repo.git_dir);

    // Load existing index
    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPath(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    // Determine sources and destination
    const paths = opts.paths.items;
    const destination = paths[paths.len - 1];
    const sources = paths[0 .. paths.len - 1];

    // Check if destination is a directory
    var dest_abs_buf: [4096]u8 = undefined;
    const dest_abs = buildPath2(&dest_abs_buf, work_dir, "/", destination);
    const dest_is_dir = isDirectory(dest_abs);

    // If multiple sources, destination must be a directory
    if (sources.len > 1 and !dest_is_dir) {
        try stderr_file.writeAll("fatal: destination is not a directory\n");
        std.process.exit(1);
    }

    // Build list of move operations
    var moves = std.array_list.Managed(MoveOp).init(allocator);
    defer moves.deinit();

    for (sources) |source| {
        // Normalize source path
        const clean_src = std.mem.trimRight(u8, source, "/");
        if (clean_src.len == 0) continue;

        // Check that source is tracked
        const src_is_dir = isDirectoryInIndex(&idx, clean_src);
        const src_in_index = idx.findEntry(clean_src) != null;

        if (!src_in_index and !src_is_dir) {
            if (opts.skip_errors) continue;
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: not under version control: '{s}'\n", .{clean_src}) catch "fatal: source not under version control\n";
            try stderr_file.writeAll(msg);
            std.process.exit(128);
        }

        // Determine the actual destination path
        var final_dest_buf: [4096]u8 = undefined;
        const final_dest = if (dest_is_dir) blk: {
            // Move into directory: dest/basename(source)
            const basename = std.fs.path.basename(clean_src);
            break :blk buildPath2(&final_dest_buf, destination, "/", basename);
        } else destination;

        if (src_is_dir) {
            // Moving a directory: collect all entries under it
            try collectDirMoves(allocator, &idx, clean_src, final_dest, &moves);
        } else {
            try moves.append(.{ .source = clean_src, .destination = final_dest });
        }
    }

    if (moves.items.len == 0) {
        try stderr_file.writeAll("fatal: no files to move\n");
        std.process.exit(1);
    }

    // Validate all moves
    for (moves.items) |*move| {
        // Check destination doesn't already exist in index (unless --force)
        if (!opts.force and idx.findEntry(move.destination) != null) {
            if (opts.skip_errors) continue;
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: destination exists: '{s}'\n", .{move.destination}) catch "fatal: destination already exists\n";
            try stderr_file.writeAll(msg);
            std.process.exit(128);
        }

        // Check destination file doesn't exist on disk (unless --force)
        if (!opts.force) {
            var abs_buf: [4096]u8 = undefined;
            const abs_dest = buildPath2(&abs_buf, work_dir, "/", move.destination);
            if (isFile(abs_dest)) {
                if (opts.skip_errors) continue;
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: destination exists: '{s}'\n", .{move.destination}) catch "fatal: destination already exists\n";
                try stderr_file.writeAll(msg);
                std.process.exit(128);
            }
        }
    }

    // Execute moves
    var moved_count: usize = 0;
    for (moves.items) |*move| {
        if (opts.dry_run) {
            var buf: [4096]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Renaming {s} to {s}\n", .{ move.source, move.destination }) catch continue;
            try stdout_file.writeAll(msg);
            moved_count += 1;
            continue;
        }

        // 1. Rename the file on disk
        var src_abs_buf: [4096]u8 = undefined;
        const src_abs = buildPath2(&src_abs_buf, work_dir, "/", move.source);
        var dst_abs_buf: [4096]u8 = undefined;
        const dst_abs = buildPath2(&dst_abs_buf, work_dir, "/", move.destination);

        // Ensure destination parent directory exists
        const dest_parent = std.fs.path.dirname(dst_abs) orelse work_dir;
        mkdirRecursive(dest_parent) catch {};

        renameFile(src_abs, dst_abs) catch |err| {
            if (opts.skip_errors) continue;
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: renaming '{s}' failed: {s}\n", .{ move.source, @errorName(err) }) catch "fatal: rename failed\n";
            try stderr_file.writeAll(msg);
            std.process.exit(128);
        };

        // 2. Update the index: get old entry data, remove old, add new
        if (idx.findEntry(move.source)) |entry_idx| {
            const old_entry = idx.entries.items[entry_idx];

            // Create owned name for the new entry
            const new_name = try allocator.alloc(u8, move.destination.len);
            @memcpy(new_name, move.destination);

            // Get stat of the moved file for updated timestamps
            var new_entry = old_entry;
            new_entry.name = new_name;
            new_entry.owned = true;

            // Update timestamps from the new file location
            const file = std.fs.openFileAbsolute(dst_abs, .{}) catch null;
            if (file) |f| {
                defer f.close();
                const stat = f.stat() catch null;
                if (stat) |s| {
                    new_entry.mtime_s = @intCast(@as(u64, @intCast(@divFloor(s.mtime, 1_000_000_000))));
                    new_entry.mtime_ns = @intCast(@as(u64, @intCast(@mod(s.mtime, 1_000_000_000))));
                    new_entry.ctime_s = @intCast(@as(u64, @intCast(@divFloor(s.ctime, 1_000_000_000))));
                    new_entry.ctime_ns = @intCast(@as(u64, @intCast(@mod(s.ctime, 1_000_000_000))));
                }
            }

            // Remove old entry
            _ = idx.removeEntry(move.source);

            // Add new entry
            try idx.addEntry(new_entry);
        }

        // Try to remove empty parent directories of source
        tryRemoveEmptyParents(work_dir, move.source);

        if (opts.verbose) {
            var buf: [4096]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Renaming {s} to {s}\n", .{ move.source, move.destination }) catch continue;
            try stdout_file.writeAll(msg);
        }
        moved_count += 1;
    }

    // Write updated index (unless dry run)
    if (!opts.dry_run and moved_count > 0) {
        try idx.writeToFile(index_path);
    }
}

/// Check if a given path represents a directory in the index.
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

/// Collect move operations for all entries under a directory.
fn collectDirMoves(
    allocator: std.mem.Allocator,
    idx: *const index_mod.Index,
    src_dir: []const u8,
    dest_dir: []const u8,
    moves: *std.array_list.Managed(MoveOp),
) !void {
    var prefix_buf: [4096]u8 = undefined;
    @memcpy(prefix_buf[0..src_dir.len], src_dir);
    prefix_buf[src_dir.len] = '/';
    const prefix = prefix_buf[0 .. src_dir.len + 1];

    for (idx.entries.items) |*entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) {
            // Compute destination by replacing the prefix
            const suffix = entry.name[prefix.len..];
            var dest_buf: [4096]u8 = undefined;
            const dest_path = buildPath2(&dest_buf, dest_dir, "/", suffix);

            // Allocate owned copies since the entry names come from index
            const owned_dest = try allocator.alloc(u8, dest_path.len);
            @memcpy(owned_dest, dest_path);

            try moves.append(.{
                .source = entry.name,
                .destination = owned_dest,
            });
        }
    }
}

/// Rename a file, handling cross-device moves.
fn renameFile(src: []const u8, dst: []const u8) !void {
    // Create null-terminated paths for the rename syscall
    var src_buf: [4097]u8 = undefined;
    var dst_buf: [4097]u8 = undefined;

    if (src.len >= src_buf.len or dst.len >= dst_buf.len) return error.PathTooLong;

    @memcpy(src_buf[0..src.len], src);
    src_buf[src.len] = 0;
    @memcpy(dst_buf[0..dst.len], dst);
    dst_buf[dst.len] = 0;

    const rc = std.c.rename(@ptrCast(&src_buf), @ptrCast(&dst_buf));
    if (rc != 0) return error.RenameFailed;
}

/// Try to remove empty parent directories up to the work_dir root.
fn tryRemoveEmptyParents(work_dir: []const u8, rel_path: []const u8) void {
    var current = rel_path;

    while (true) {
        const dir_name = std.fs.path.dirname(current) orelse break;
        if (dir_name.len == 0) break;

        var abs_buf: [4096]u8 = undefined;
        const abs_path = buildPath2(&abs_buf, work_dir, "/", dir_name);

        std.fs.deleteDirAbsolute(abs_path) catch break;

        current = dir_name;
    }
}

/// Recursively create directories.
fn mkdirRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
            try mkdirRecursive(parent);
            std.fs.makeDirAbsolute(path) catch |err2| switch (err2) {
                error.PathAlreadyExists => return,
                else => return err2,
            };
        },
        else => return err,
    };
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

fn isDirectory(path: []const u8) bool {
    const dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    @constCast(&dir).close();
    return true;
}

fn isFile(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    @constCast(&file).close();
    return true;
}

test "isDirectoryInIndex" {
    var idx = index_mod.Index.init(std.testing.allocator);
    defer idx.deinit();

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
    try std.testing.expect(!isDirectoryInIndex(&idx, "src/main.zig"));
}
