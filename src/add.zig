const std = @import("std");
const types = @import("types.zig");
const loose = @import("loose.zig");
const index_mod = @import("index.zig");
const ignore_mod = @import("ignore.zig");
const repository = @import("repository.zig");
const hash_mod = @import("hash.zig");

const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Options for the add command.
pub const AddOptions = struct {
    /// Pathspecs provided on the command line.
    paths: []const []const u8,
    /// -A / --all: stage all changes including deletions.
    all: bool = false,
    /// --force: add ignored files.
    force: bool = false,
};

/// Run the "add" command.
pub fn runAdd(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = AddOptions{
        .paths = &[_][]const u8{},
        .all = false,
        .force = false,
    };

    // Parse arguments.
    var pathspecs = std.array_list.Managed([]const u8).init(allocator);
    defer pathspecs.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--all")) {
            opts.all = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            // Everything after -- is a pathspec.
            i += 1;
            while (i < args.len) : (i += 1) {
                try pathspecs.append(args[i]);
            }
            break;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: unknown option '{s}'\n", .{arg}) catch "fatal: unknown option\n";
            try stderr_file.writeAll(msg);
            std.process.exit(1);
        } else {
            try pathspecs.append(arg);
        }
    }

    if (pathspecs.items.len == 0 and !opts.all) {
        try stderr_file.writeAll("Nothing specified, nothing added.\nMaybe you wanted to say 'zig-git add .'?\n");
        std.process.exit(1);
    }

    // If -A with no pathspecs, treat as "add everything".
    if (opts.all and pathspecs.items.len == 0) {
        try pathspecs.append(".");
    }

    opts.paths = pathspecs.items;

    // Get working directory.
    const work_dir = getWorkDir(repo.git_dir);

    // Load existing index.
    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPath(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    // Load ignore rules (unless --force).
    var ignore = ignore_mod.IgnoreRules.init(allocator);
    defer ignore.deinit();
    if (!opts.force) {
        ignore.loadExclude(repo.git_dir) catch {};
        ignore.loadGitignore(work_dir) catch {};
    }

    // Process each pathspec.
    for (opts.paths) |pathspec| {
        try processPathspec(allocator, repo.git_dir, work_dir, pathspec, &idx, &ignore, opts);
    }

    // If -A or ".", also handle deletions: remove index entries whose files
    // no longer exist on disk.
    if (opts.all or hasDotPathspec(opts.paths)) {
        try removeDeletedEntries(allocator, work_dir, &idx);
    }

    // Write updated index.
    try idx.writeToFile(index_path);
}

/// Check whether "." is among the pathspecs.
fn hasDotPathspec(paths: []const []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, ".")) return true;
    }
    return false;
}

/// Process a single pathspec: it could be a file or directory.
fn processPathspec(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    work_dir: []const u8,
    pathspec: []const u8,
    idx: *index_mod.Index,
    ignore: *const ignore_mod.IgnoreRules,
    opts: AddOptions,
) !void {
    // Build the absolute path for the pathspec.
    var abs_buf: [4096]u8 = undefined;
    const abs_path = blk: {
        if (std.fs.path.isAbsolute(pathspec)) {
            if (pathspec.len > abs_buf.len) return error.PathTooLong;
            @memcpy(abs_buf[0..pathspec.len], pathspec);
            break :blk abs_buf[0..pathspec.len];
        } else {
            break :blk buildPath2(&abs_buf, work_dir, "/", pathspec);
        }
    };
    _ = abs_path;

    // Compute the relative path from work_dir.
    const rel_path = if (std.mem.eql(u8, pathspec, "."))
        ""
    else
        pathspec;

    // Check if it's a directory or file.
    var full_path_buf: [4096]u8 = undefined;
    const full_path = if (rel_path.len == 0)
        buildPath(&full_path_buf, work_dir, "")
    else
        buildPath2(&full_path_buf, work_dir, "/", rel_path);

    // Try to stat the path.
    if (isDirectory(full_path)) {
        // Recursively add all files in the directory.
        try addDirectory(allocator, git_dir, work_dir, rel_path, idx, ignore, opts);
    } else if (isFile(full_path)) {
        // Check ignore rules.
        if (!opts.force and rel_path.len > 0 and ignore.isIgnored(rel_path, false)) {
            var buf: [4096]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "The following paths are ignored by one of your .gitignore files:\n{s}\nUse -f if you really want to add them.\n", .{rel_path}) catch "warning: ignored file\n";
            try stderr_file.writeAll(msg);
            return;
        }
        try addSingleFile(allocator, git_dir, work_dir, rel_path, idx);
    } else {
        // File doesn't exist. If -A, this might be a deletion.
        if (opts.all) {
            _ = idx.removeEntry(rel_path);
        } else {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: pathspec '{s}' did not match any files\n", .{rel_path}) catch "fatal: pathspec did not match any files\n";
            try stderr_file.writeAll(msg);
            std.process.exit(128);
        }
    }
}

/// Recursively add all files in a directory.
fn addDirectory(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    work_dir: []const u8,
    prefix: []const u8,
    idx: *index_mod.Index,
    ignore: *const ignore_mod.IgnoreRules,
    opts: AddOptions,
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
        // Skip .git directory.
        if (std.mem.eql(u8, entry.name, ".git")) continue;

        // Build relative path.
        var rel_path_buf: [4096]u8 = undefined;
        const rel_path = if (prefix.len == 0)
            buildPath(&rel_path_buf, entry.name, "")
        else
            buildPath2(&rel_path_buf, prefix, "/", entry.name);

        const is_dir = entry.kind == .directory;

        // Check ignore rules.
        if (!opts.force and ignore.isIgnored(rel_path, is_dir)) continue;

        if (is_dir) {
            try addDirectory(allocator, git_dir, work_dir, rel_path, idx, ignore, opts);
        } else if (entry.kind == .file or entry.kind == .sym_link) {
            try addSingleFile(allocator, git_dir, work_dir, rel_path, idx);
        }
    }
}

/// Add a single file to the index.
fn addSingleFile(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    work_dir: []const u8,
    rel_path: []const u8,
    idx: *index_mod.Index,
) !void {
    // Build absolute path.
    var abs_buf: [4096]u8 = undefined;
    const abs_path = buildPath2(&abs_buf, work_dir, "/", rel_path);

    // Read file content.
    const file = std.fs.openFileAbsolute(abs_path, .{}) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: open('{s}'): {s}\n", .{ rel_path, @errorName(err) }) catch "error: could not open file\n";
        try stderr_file.writeAll(msg);
        return;
    };
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;
    if (file_size > 100 * 1024 * 1024) {
        try stderr_file.writeAll("error: file too large\n");
        return;
    }

    const content = try allocator.alloc(u8, @intCast(file_size));
    defer allocator.free(content);
    const n = try file.readAll(content);
    const data = content[0..n];

    // Write blob object.
    const oid = loose.writeLooseObject(allocator, git_dir, .blob, data) catch |err| switch (err) {
        error.PathAlreadyExists => blk: {
            // Object already exists, compute the OID.
            break :blk computeBlobOid(data);
        },
        else => return err,
    };

    // Build the index entry.
    // Determine file mode.
    const mode: u32 = blk: {
        if (stat.kind == .sym_link) break :blk 0o120000;
        // Check executable bit.
        const raw_mode = stat.mode;
        if (raw_mode & 0o111 != 0) break :blk 0o100755;
        break :blk 0o100644;
    };

    // Extract timestamps. Clamp negative values to 0 (pre-epoch files).
    const mtime_raw = stat.mtime;
    const ctime_raw = stat.ctime;
    const mtime_s: u32 = if (mtime_raw >= 0) @intCast(@as(u64, @intCast(@divFloor(mtime_raw, 1_000_000_000)))) else 0;
    const mtime_ns: u32 = if (mtime_raw >= 0) @intCast(@as(u64, @intCast(@mod(mtime_raw, 1_000_000_000)))) else 0;
    const ctime_s: u32 = if (ctime_raw >= 0) @intCast(@as(u64, @intCast(@divFloor(ctime_raw, 1_000_000_000)))) else 0;
    const ctime_ns: u32 = if (ctime_raw >= 0) @intCast(@as(u64, @intCast(@mod(ctime_raw, 1_000_000_000)))) else 0;

    // Make an owned copy of the name for the index entry.
    const owned_name = try allocator.alloc(u8, rel_path.len);
    errdefer allocator.free(owned_name);
    @memcpy(owned_name, rel_path);

    const entry = index_mod.IndexEntry{
        .ctime_s = ctime_s,
        .ctime_ns = ctime_ns,
        .mtime_s = mtime_s,
        .mtime_ns = mtime_ns,
        .dev = 0,
        .ino = 0,
        .mode = mode,
        .uid = 0,
        .gid = 0,
        .file_size = @intCast(n),
        .oid = oid,
        .flags = 0,
        .name = owned_name,
        .owned = true,
    };

    try idx.addEntry(entry);
}

/// Remove index entries whose files no longer exist on disk.
fn removeDeletedEntries(
    allocator: std.mem.Allocator,
    work_dir: []const u8,
    idx: *index_mod.Index,
) !void {
    // Collect names of entries to remove (we can't modify during iteration).
    var to_remove = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (to_remove.items) |name| allocator.free(name);
        to_remove.deinit();
    }

    for (idx.entries.items) |*entry| {
        var path_buf: [4096]u8 = undefined;
        const full_path = buildPath2(&path_buf, work_dir, "/", entry.name);

        if (!isFile(full_path) and !isSymlink(full_path)) {
            const name_copy = try allocator.alloc(u8, entry.name.len);
            @memcpy(name_copy, entry.name);
            try to_remove.append(name_copy);
        }
    }

    for (to_remove.items) |name| {
        _ = idx.removeEntry(name);
    }
}

/// Compute the blob OID without writing (for when the object already exists).
fn computeBlobOid(data: []const u8) types.ObjectId {
    var header_buf: [64]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    hwriter.writeAll("blob ") catch unreachable;
    hwriter.print("{d}", .{data.len}) catch unreachable;
    hwriter.writeByte(0) catch unreachable;
    const header = header_buf[0..hstream.pos];

    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    return types.ObjectId{ .bytes = hasher.finalResult() };
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
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

fn isFile(path: []const u8) bool {
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn isSymlink(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .sym_link;
}
