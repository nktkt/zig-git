const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const loose = @import("loose.zig");
const hash_mod = @import("hash.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const Action = enum {
    add,
    remove,
    refresh,
    really_refresh,
    assume_unchanged,
    no_assume_unchanged,
    chmod_plus_x,
    chmod_minus_x,
    cacheinfo,
    unresolve,
};

pub fn runUpdateIndex(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Load the index
    var index_path_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&index_path_buf);
    var writer = stream.writer();
    try writer.writeAll(repo.git_dir);
    try writer.writeAll("/index");
    const index_path = index_path_buf[0..stream.pos];

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    var modified = false;

    var current_action: ?Action = null;
    var cacheinfo_mode: ?u32 = null;
    var cacheinfo_sha: ?[]const u8 = null;
    var cacheinfo_state: enum { need_mode, need_sha, need_path } = .need_mode;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Handle --cacheinfo argument parsing
        if (current_action == .cacheinfo) {
            switch (cacheinfo_state) {
                .need_mode => {
                    cacheinfo_mode = parseOctalMode(arg);
                    if (cacheinfo_mode == null) {
                        // Try comma-separated format: --cacheinfo mode,sha,path
                        if (parseCacheinfoComma(arg)) |info| {
                            try applyCacheinfo(allocator, &idx, info.mode, info.sha, info.path);
                            modified = true;
                            current_action = null;
                            continue;
                        }
                        try stderr_file.writeAll("fatal: invalid mode for --cacheinfo\n");
                        std.process.exit(128);
                    }
                    cacheinfo_state = .need_sha;
                    continue;
                },
                .need_sha => {
                    cacheinfo_sha = arg;
                    cacheinfo_state = .need_path;
                    continue;
                },
                .need_path => {
                    if (cacheinfo_mode) |mode| {
                        if (cacheinfo_sha) |sha| {
                            try applyCacheinfo(allocator, &idx, mode, sha, arg);
                            modified = true;
                        }
                    }
                    current_action = null;
                    cacheinfo_mode = null;
                    cacheinfo_sha = null;
                    cacheinfo_state = .need_mode;
                    continue;
                },
            }
        }

        if (std.mem.eql(u8, arg, "--add")) {
            current_action = .add;
        } else if (std.mem.eql(u8, arg, "--remove")) {
            current_action = .remove;
        } else if (std.mem.eql(u8, arg, "--refresh")) {
            try doRefresh(allocator, &idx, getWorkDir(repo.git_dir), false);
            modified = true;
            current_action = null;
        } else if (std.mem.eql(u8, arg, "--really-refresh")) {
            try doRefresh(allocator, &idx, getWorkDir(repo.git_dir), true);
            modified = true;
            current_action = null;
        } else if (std.mem.eql(u8, arg, "--assume-unchanged")) {
            current_action = .assume_unchanged;
        } else if (std.mem.eql(u8, arg, "--no-assume-unchanged")) {
            current_action = .no_assume_unchanged;
        } else if (std.mem.eql(u8, arg, "--chmod=+x")) {
            current_action = .chmod_plus_x;
        } else if (std.mem.eql(u8, arg, "--chmod=-x")) {
            current_action = .chmod_minus_x;
        } else if (std.mem.eql(u8, arg, "--cacheinfo")) {
            current_action = .cacheinfo;
            cacheinfo_state = .need_mode;
            cacheinfo_mode = null;
            cacheinfo_sha = null;
        } else if (std.mem.eql(u8, arg, "--unresolve")) {
            current_action = .unresolve;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // This is a file path -- apply current action
            if (current_action) |action| {
                switch (action) {
                    .add => {
                        try doAdd(repo, allocator, &idx, arg);
                        modified = true;
                    },
                    .remove => {
                        if (idx.removeEntry(arg)) {
                            modified = true;
                        } else {
                            var buf: [256]u8 = undefined;
                            const msg = std.fmt.bufPrint(&buf, "fatal: Unable to process path {s}\n", .{arg}) catch "fatal: Unable to process path\n";
                            try stderr_file.writeAll(msg);
                        }
                    },
                    .assume_unchanged => {
                        if (setAssumeUnchanged(&idx, arg, true)) {
                            modified = true;
                        }
                    },
                    .no_assume_unchanged => {
                        if (setAssumeUnchanged(&idx, arg, false)) {
                            modified = true;
                        }
                    },
                    .chmod_plus_x => {
                        if (setChmodX(&idx, arg, true)) {
                            modified = true;
                        }
                    },
                    .chmod_minus_x => {
                        if (setChmodX(&idx, arg, false)) {
                            modified = true;
                        }
                    },
                    .unresolve => {
                        // unresolve is a no-op placeholder; real implementation needs
                        // merge base info which is complex
                        var buf: [256]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "warning: unresolve for '{s}' is not fully implemented\n", .{arg}) catch "warning: unresolve not fully implemented\n";
                        try stderr_file.writeAll(msg);
                    },
                    .cacheinfo => {
                        // Handled above
                    },
                    .refresh, .really_refresh => {
                        // Already handled inline
                    },
                }
            } else {
                // No action specified with path -- default is to add if --add isn't required
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "error: {s}: cannot add to the index - missing --add option?\n", .{arg}) catch "error: missing --add option\n";
                try stderr_file.writeAll(msg);
            }
        }
    }

    if (modified) {
        try idx.writeToFile(index_path);
    }
}

fn getWorkDir(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    return git_dir;
}

fn doAdd(repo: *repository.Repository, allocator: std.mem.Allocator, idx: *index_mod.Index, path: []const u8) !void {
    const work_dir = getWorkDir(repo.git_dir);

    // Build full path
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..work_dir.len], work_dir);
    pos += work_dir.len;
    path_buf[pos] = '/';
    pos += 1;
    @memcpy(path_buf[pos..][0..path.len], path);
    pos += path.len;
    const full_path = path_buf[0..pos];

    // Read file content
    const file = std.fs.openFileAbsolute(full_path, .{}) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: {s}: does not exist and --remove not passed\n", .{path}) catch "error: file does not exist\n";
        try stderr_file.writeAll(msg);
        return;
    };
    defer file.close();

    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);
    const n = try file.readAll(content);
    const data = content[0..n];

    // Write blob object
    const oid = try loose.writeLooseObject(allocator, repo.git_dir, .blob, data);

    // Build index entry
    const owned_name = try allocator.alloc(u8, path.len);
    @memcpy(owned_name, path);

    const mtime_s: u32 = @intCast(@as(u64, @intCast(@divFloor(stat.mtime, 1_000_000_000))));
    const mtime_ns: u32 = @intCast(@as(u64, @intCast(@mod(stat.mtime, 1_000_000_000))));
    const ctime_s: u32 = @intCast(@as(u64, @intCast(@divFloor(stat.ctime, 1_000_000_000))));
    const ctime_ns: u32 = @intCast(@as(u64, @intCast(@mod(stat.ctime, 1_000_000_000))));

    // Determine mode
    const mode: u32 = if (stat.mode & 0o111 != 0) 0o100755 else 0o100644;

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
        .file_size = @intCast(stat.size),
        .oid = oid,
        .flags = @as(u16, @intCast(@min(path.len, 0xFFF))),
        .name = owned_name,
        .owned = true,
    };

    try idx.addEntry(entry);
}

fn doRefresh(allocator: std.mem.Allocator, idx: *index_mod.Index, work_dir: []const u8, really: bool) !void {
    _ = allocator;

    for (idx.entries.items) |*entry| {
        const stage = (entry.flags >> 12) & 0x3;
        if (stage != 0) continue;

        // Build full path
        var path_buf: [4096]u8 = undefined;
        var pos: usize = 0;
        @memcpy(path_buf[pos..][0..work_dir.len], work_dir);
        pos += work_dir.len;
        path_buf[pos] = '/';
        pos += 1;
        @memcpy(path_buf[pos..][0..entry.name.len], entry.name);
        pos += entry.name.len;
        const full_path = path_buf[0..pos];

        const file = std.fs.openFileAbsolute(full_path, .{}) catch continue;
        defer file.close();

        const stat = file.stat() catch continue;
        const mtime_s: u32 = @intCast(@as(u64, @intCast(@divFloor(stat.mtime, 1_000_000_000))));
        const mtime_ns: u32 = @intCast(@as(u64, @intCast(@mod(stat.mtime, 1_000_000_000))));
        const ctime_s: u32 = @intCast(@as(u64, @intCast(@divFloor(stat.ctime, 1_000_000_000))));
        const ctime_ns: u32 = @intCast(@as(u64, @intCast(@mod(stat.ctime, 1_000_000_000))));

        if (really) {
            // Update all stat fields
            entry.ctime_s = ctime_s;
            entry.ctime_ns = ctime_ns;
            entry.mtime_s = mtime_s;
            entry.mtime_ns = mtime_ns;
            entry.file_size = @intCast(stat.size);
        } else {
            // Only update if stat info has changed
            if (mtime_s != entry.mtime_s or @as(u32, @intCast(stat.size)) != entry.file_size) {
                entry.ctime_s = ctime_s;
                entry.ctime_ns = ctime_ns;
                entry.mtime_s = mtime_s;
                entry.mtime_ns = mtime_ns;
                entry.file_size = @intCast(stat.size);
            }
        }
    }
}

fn setAssumeUnchanged(idx: *index_mod.Index, path: []const u8, set: bool) bool {
    if (idx.findEntry(path)) |entry_idx| {
        const ASSUME_VALID_BIT: u16 = 0x8000;
        if (set) {
            idx.entries.items[entry_idx].flags |= ASSUME_VALID_BIT;
        } else {
            idx.entries.items[entry_idx].flags &= ~ASSUME_VALID_BIT;
        }
        return true;
    }
    return false;
}

fn setChmodX(idx: *index_mod.Index, path: []const u8, executable: bool) bool {
    if (idx.findEntry(path)) |entry_idx| {
        if (executable) {
            idx.entries.items[entry_idx].mode = 0o100755;
        } else {
            idx.entries.items[entry_idx].mode = 0o100644;
        }
        return true;
    }
    return false;
}

const CacheinfoResult = struct {
    mode: u32,
    sha: []const u8,
    path: []const u8,
};

fn parseCacheinfoComma(arg: []const u8) ?CacheinfoResult {
    // Format: mode,sha,path
    const first_comma = std.mem.indexOfScalar(u8, arg, ',') orelse return null;
    const second_comma = std.mem.indexOfScalarPos(u8, arg, first_comma + 1, ',') orelse return null;

    const mode_str = arg[0..first_comma];
    const sha = arg[first_comma + 1 .. second_comma];
    const path = arg[second_comma + 1 ..];

    if (sha.len < types.OID_HEX_LEN) return null;
    if (path.len == 0) return null;

    const mode = parseOctalMode(mode_str) orelse return null;
    return CacheinfoResult{ .mode = mode, .sha = sha, .path = path };
}

fn applyCacheinfo(allocator: std.mem.Allocator, idx: *index_mod.Index, mode: u32, sha: []const u8, path: []const u8) !void {
    if (sha.len < types.OID_HEX_LEN) {
        try stderr_file.writeAll("fatal: invalid SHA1 for --cacheinfo\n");
        std.process.exit(128);
    }
    const oid = types.ObjectId.fromHex(sha[0..types.OID_HEX_LEN]) catch {
        try stderr_file.writeAll("fatal: invalid SHA1 for --cacheinfo\n");
        std.process.exit(128);
    };

    const owned_name = try allocator.alloc(u8, path.len);
    @memcpy(owned_name, path);

    const entry = index_mod.IndexEntry{
        .ctime_s = 0,
        .ctime_ns = 0,
        .mtime_s = 0,
        .mtime_ns = 0,
        .dev = 0,
        .ino = 0,
        .mode = mode,
        .uid = 0,
        .gid = 0,
        .file_size = 0,
        .oid = oid,
        .flags = @as(u16, @intCast(@min(path.len, 0xFFF))),
        .name = owned_name,
        .owned = true,
    };

    try idx.addEntry(entry);
}

fn parseOctalMode(s: []const u8) ?u32 {
    var result: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '7') return null;
        result = result * 8 + (c - '0');
    }
    return result;
}
