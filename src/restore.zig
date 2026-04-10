const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const ref_mod = @import("ref.zig");
const checkout_mod = @import("checkout.zig");
const tree_diff = @import("tree_diff.zig");
const loose = @import("loose.zig");
const hash_mod = @import("hash.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Run the restore command.
pub fn runRestore(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var staged = false;
    var worktree = true; // default: restore working tree
    var source: ?[]const u8 = null;
    var files = std.array_list.Managed([]const u8).init(allocator);
    defer files.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--staged") or std.mem.eql(u8, arg, "-S")) {
            staged = true;
            worktree = false; // --staged alone means only unstage
        } else if (std.mem.eql(u8, arg, "--worktree") or std.mem.eql(u8, arg, "-W")) {
            worktree = true;
        } else if (std.mem.startsWith(u8, arg, "--source=")) {
            source = arg["--source=".len..];
        } else if (std.mem.eql(u8, arg, "--source") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("fatal: --source requires a value\n");
                std.process.exit(1);
            }
            source = args[i];
        } else if (std.mem.eql(u8, arg, "--")) {
            // Everything after -- is file paths
            i += 1;
            while (i < args.len) : (i += 1) {
                try files.append(args[i]);
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try files.append(arg);
        }
    }

    // If --staged and --worktree both specified, restore both
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--worktree") or std.mem.eql(u8, arg, "-W")) {
            worktree = true;
            break;
        }
    }

    if (files.items.len == 0) {
        try stderr_file.writeAll("fatal: you must specify path(s) to restore\n");
        std.process.exit(1);
    }

    const work_dir = getWorkDir(repo.git_dir);

    // Load the index
    var idx_path_buf: [4096]u8 = undefined;
    var idx_stream = std.io.fixedBufferStream(&idx_path_buf);
    const idx_writer = idx_stream.writer();
    try idx_writer.writeAll(repo.git_dir);
    try idx_writer.writeAll("/index");
    const idx_path = idx_path_buf[0..idx_stream.pos];

    var idx = try index_mod.Index.readFromFile(allocator, idx_path);
    defer idx.deinit();

    // Load source tree entries if --source specified, or HEAD tree for --staged
    var source_entries: ?std.StringHashMap(SourceEntry) = null;
    defer if (source_entries) |*se| {
        var ki = se.keyIterator();
        while (ki.next()) |key| allocator.free(key.*);
        se.deinit();
    };

    if (source != null or staged) {
        const source_ref = source orelse "HEAD";
        var entries = std.StringHashMap(SourceEntry).init(allocator);
        loadTreeEntries(repo, allocator, source_ref, &entries) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: could not resolve '{s}'\n", .{source_ref}) catch
                "fatal: could not resolve source\n";
            try stderr_file.writeAll(msg);
            std.process.exit(128);
        };
        source_entries = entries;
    }

    var any_changed = false;

    for (files.items) |file_pattern| {
        // Handle "." to restore all files
        if (std.mem.eql(u8, file_pattern, ".")) {
            if (staged) {
                try restoreAllStaged(allocator, &idx, source_entries);
                any_changed = true;
            }
            if (worktree) {
                try restoreAllWorktree(allocator, repo, &idx, work_dir, source_entries);
                any_changed = true;
            }
            continue;
        }

        if (staged) {
            if (try restoreStaged(allocator, &idx, file_pattern, source_entries)) {
                any_changed = true;
            }
        }

        if (worktree) {
            if (source_entries) |*se| {
                // Restore from source commit
                if (try restoreFromSource(allocator, repo, se, work_dir, file_pattern)) {
                    any_changed = true;
                }
            } else {
                // Restore from index (default)
                if (try restoreFromIndex(allocator, repo, &idx, work_dir, file_pattern)) {
                    any_changed = true;
                }
            }
        }
    }

    // Write updated index if staged was modified
    if (any_changed and staged) {
        try idx.writeToFile(idx_path);
    }
}

const SourceEntry = struct {
    oid: types.ObjectId,
    mode: u32,
};

fn restoreFromIndex(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    idx: *index_mod.Index,
    work_dir: []const u8,
    file_path: []const u8,
) !bool {
    const entry_idx = idx.findEntry(file_path) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: pathspec '{s}' did not match any file(s) known to git\n", .{file_path}) catch
            "error: pathspec did not match\n";
        try stderr_file.writeAll(msg);
        return false;
    };

    const entry = &idx.entries.items[entry_idx];
    try writeBlobToWorkTree(allocator, repo, work_dir, entry.name, &entry.oid, entry.mode);
    return true;
}

fn restoreFromSource(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    source_entries: *std.StringHashMap(SourceEntry),
    work_dir: []const u8,
    file_path: []const u8,
) !bool {
    const se = source_entries.get(file_path) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: pathspec '{s}' did not match any file(s) known to git\n", .{file_path}) catch
            "error: pathspec did not match\n";
        try stderr_file.writeAll(msg);
        return false;
    };

    try writeBlobToWorkTree(allocator, repo, work_dir, file_path, &se.oid, se.mode);
    return true;
}

fn restoreStaged(
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    file_path: []const u8,
    source_entries: ?std.StringHashMap(SourceEntry),
) !bool {
    const entry_idx = idx.findEntry(file_path) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: pathspec '{s}' did not match any file(s) known to git\n", .{file_path}) catch
            "error: pathspec did not match\n";
        try stderr_file.writeAll(msg);
        return false;
    };

    if (source_entries) |se| {
        if (se.get(file_path)) |src| {
            idx.entries.items[entry_idx].oid = src.oid;
            idx.entries.items[entry_idx].mode = src.mode;
            return true;
        }
    }

    _ = allocator;
    return false;
}

fn restoreAllStaged(
    allocator: std.mem.Allocator,
    idx: *index_mod.Index,
    source_entries: ?std.StringHashMap(SourceEntry),
) !void {
    if (source_entries) |se| {
        for (idx.entries.items) |*entry| {
            if (se.get(entry.name)) |src| {
                entry.oid = src.oid;
                entry.mode = src.mode;
            }
        }
    }
    _ = allocator;
}

fn restoreAllWorktree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    idx: *index_mod.Index,
    work_dir: []const u8,
    source_entries: ?std.StringHashMap(SourceEntry),
) !void {
    if (source_entries) |se| {
        var iter = se.iterator();
        while (iter.next()) |kv| {
            writeBlobToWorkTree(allocator, repo, work_dir, kv.key_ptr.*, &kv.value_ptr.oid, kv.value_ptr.mode) catch continue;
        }
    } else {
        for (idx.entries.items) |*entry| {
            writeBlobToWorkTree(allocator, repo, work_dir, entry.name, &entry.oid, entry.mode) catch continue;
        }
    }
}

fn loadTreeEntries(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    ref_str: []const u8,
    entries: *std.StringHashMap(SourceEntry),
) !void {
    const commit_oid = try repo.resolveRef(allocator, ref_str);
    var commit_obj = try repo.readObject(allocator, &commit_oid);
    defer commit_obj.deinit();
    if (commit_obj.obj_type != .commit) return error.NotACommit;

    const tree_oid = try tree_diff.getCommitTreeOid(commit_obj.data);
    try walkTree(repo, allocator, &tree_oid, entries, "");
}

fn walkTree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    tree_oid: *const types.ObjectId,
    entries: *std.StringHashMap(SourceEntry),
    prefix: []const u8,
) !void {
    var obj = repo.readObject(allocator, tree_oid) catch return;
    defer obj.deinit();
    if (obj.obj_type != .tree) return;

    var pos: usize = 0;
    const data = obj.data;

    while (pos < data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse break;
        const mode_str = data[pos..space_pos];
        pos = space_pos + 1;

        const null_pos = std.mem.indexOfScalarPos(u8, data, pos, 0) orelse break;
        const name = data[pos..null_pos];
        pos = null_pos + 1;

        if (pos + 20 > data.len) break;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, data[pos..][0..20]);
        pos += 20;

        var path_buf: [4096]u8 = undefined;
        var path_pos: usize = 0;
        if (prefix.len > 0) {
            @memcpy(path_buf[0..prefix.len], prefix);
            path_pos += prefix.len;
            path_buf[path_pos] = '/';
            path_pos += 1;
        }
        @memcpy(path_buf[path_pos..][0..name.len], name);
        path_pos += name.len;

        const full_path = try allocator.alloc(u8, path_pos);
        @memcpy(full_path, path_buf[0..path_pos]);

        if (std.mem.eql(u8, mode_str, "40000")) {
            try walkTree(repo, allocator, &oid, entries, full_path);
            allocator.free(full_path);
        } else {
            const mode = parseModeString(mode_str);
            try entries.put(full_path, .{ .oid = oid, .mode = mode });
        }
    }
}

fn parseModeString(mode_str: []const u8) u32 {
    var result: u32 = 0;
    for (mode_str) |c| {
        if (c < '0' or c > '7') break;
        result = result * 8 + @as(u32, c - '0');
    }
    return result;
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

fn writeBlobToWorkTree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    work_dir: []const u8,
    rel_path: []const u8,
    oid: *const types.ObjectId,
    mode: u32,
) !void {
    var obj = try repo.readObject(allocator, oid);
    defer obj.deinit();
    if (obj.obj_type != .blob) return error.NotABlob;

    var path_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&path_buf);
    const writer = stream.writer();
    try writer.writeAll(work_dir);
    try writer.writeByte('/');
    try writer.writeAll(rel_path);
    const full_path = path_buf[0..stream.pos];

    const dir_end = std.mem.lastIndexOfScalar(u8, full_path, '/') orelse return error.InvalidPath;
    mkdirRecursive(full_path[0..dir_end]) catch {};

    const file = try std.fs.createFileAbsolute(full_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(obj.data);

    if (mode & 0o111 != 0) {
        const stat = try file.stat();
        const new_mode = stat.mode | 0o111;
        try file.chmod(new_mode);
    }
}

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
