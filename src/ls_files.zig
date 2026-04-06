const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const ignore_mod = @import("ignore.zig");
const hash_mod = @import("hash.zig");
const tree_diff = @import("tree_diff.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

pub const LsFilesOptions = struct {
    show_cached: bool = false,
    show_deleted: bool = false,
    show_modified: bool = false,
    show_others: bool = false,
    show_ignored: bool = false,
    show_stage: bool = false,
    show_unmerged: bool = false,
    show_eol: bool = false,
    full_name: bool = false,
    abbrev: ?usize = null,
    nul_terminated: bool = false,
    pathspecs: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator) LsFilesOptions {
        return .{
            .pathspecs = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *LsFilesOptions) void {
        self.pathspecs.deinit();
    }

    pub fn anyModeSet(self: *const LsFilesOptions) bool {
        return self.show_cached or self.show_deleted or self.show_modified or
            self.show_others or self.show_ignored or self.show_stage or
            self.show_unmerged or self.show_eol;
    }
};

pub fn runLsFiles(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = LsFilesOptions.init(allocator);
    defer opts.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cached")) {
            opts.show_cached = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--deleted")) {
            opts.show_deleted = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--modified")) {
            opts.show_modified = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--others")) {
            opts.show_others = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignored")) {
            opts.show_ignored = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--stage")) {
            opts.show_stage = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--unmerged")) {
            opts.show_unmerged = true;
        } else if (std.mem.eql(u8, arg, "--eol")) {
            opts.show_eol = true;
        } else if (std.mem.eql(u8, arg, "--full-name")) {
            opts.full_name = true;
        } else if (std.mem.eql(u8, arg, "-z")) {
            opts.nul_terminated = true;
        } else if (std.mem.eql(u8, arg, "--abbrev")) {
            opts.abbrev = 7;
        } else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
            const val = arg["--abbrev=".len..];
            opts.abbrev = std.fmt.parseInt(usize, val, 10) catch 7;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try opts.pathspecs.append(arg);
        }
    }

    // Default to --cached if nothing is specified
    if (!opts.anyModeSet()) {
        opts.show_cached = true;
    }

    // Load the index
    var index_path_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&index_path_buf);
    var writer = stream.writer();
    try writer.writeAll(repo.git_dir);
    try writer.writeAll("/index");
    const index_path = index_path_buf[0..stream.pos];

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    // Compute working directory root
    const work_dir = getWorkDir(repo.git_dir);

    if (opts.show_cached or opts.show_stage) {
        try listCachedFiles(&idx, &opts);
    }

    if (opts.show_unmerged) {
        try listUnmergedFiles(&idx, &opts);
    }

    if (opts.show_deleted or opts.show_modified) {
        try listDeletedOrModified(allocator, &idx, work_dir, &opts);
    }

    if (opts.show_others or opts.show_ignored) {
        var ignore = ignore_mod.IgnoreRules.init(allocator);
        defer ignore.deinit();
        ignore.loadExclude(repo.git_dir) catch {};
        if (work_dir.len > 0) {
            ignore.loadGitignore(work_dir) catch {};
        }
        try listOthersOrIgnored(allocator, &idx, work_dir, &ignore, &opts);
    }

    if (opts.show_eol) {
        try listEolInfo(allocator, &idx, work_dir, &opts);
    }
}

fn getWorkDir(git_dir: []const u8) []const u8 {
    // If git_dir ends with "/.git", the work dir is the parent
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    // Bare repo: no work dir
    return git_dir;
}

fn matchesPathspec(name: []const u8, pathspecs: []const []const u8) bool {
    if (pathspecs.len == 0) return true;
    for (pathspecs) |spec| {
        if (std.mem.startsWith(u8, name, spec)) return true;
        // Also match if spec is a prefix dir
        if (spec.len > 0 and spec[spec.len - 1] == '/') {
            if (std.mem.startsWith(u8, name, spec)) return true;
        }
        if (std.mem.eql(u8, name, spec)) return true;
    }
    return false;
}

fn writeEntry(name: []const u8, terminator: u8) !void {
    try stdout_file.writeAll(name);
    var term: [1]u8 = .{terminator};
    try stdout_file.writeAll(&term);
}

fn formatOid(oid: *const types.ObjectId, abbrev: ?usize) []const u8 {
    const hex = oid.toHex();
    const len = if (abbrev) |a| @min(a, types.OID_HEX_LEN) else types.OID_HEX_LEN;
    // Return pointer into the hex array's stack storage -- caller must use immediately
    return hex[0..len];
}

fn listCachedFiles(idx: *const index_mod.Index, opts: *const LsFilesOptions) !void {
    const terminator: u8 = if (opts.nul_terminated) 0 else '\n';

    for (idx.entries.items) |*entry| {
        if (!matchesPathspec(entry.name, opts.pathspecs.items)) continue;

        const stage = (entry.flags >> 12) & 0x3;

        if (opts.show_stage) {
            // Format: mode sha stage\tname
            var buf: [256]u8 = undefined;
            const hex = entry.oid.toHex();
            const sha_len = if (opts.abbrev) |a| @min(a, types.OID_HEX_LEN) else types.OID_HEX_LEN;
            const line = std.fmt.bufPrint(&buf, "{o:0>6} {s} {d}\t", .{
                @as(u32, entry.mode),
                hex[0..sha_len],
                stage,
            }) catch continue;
            try stdout_file.writeAll(line);
            try stdout_file.writeAll(entry.name);
            var term: [1]u8 = .{terminator};
            try stdout_file.writeAll(&term);
        } else {
            // Only show stage 0 entries for --cached (not --stage)
            if (stage != 0) continue;
            try stdout_file.writeAll(entry.name);
            var term: [1]u8 = .{terminator};
            try stdout_file.writeAll(&term);
        }
    }
}

fn listUnmergedFiles(idx: *const index_mod.Index, opts: *const LsFilesOptions) !void {
    const terminator: u8 = if (opts.nul_terminated) 0 else '\n';

    for (idx.entries.items) |*entry| {
        const stage = (entry.flags >> 12) & 0x3;
        if (stage == 0) continue;

        if (!matchesPathspec(entry.name, opts.pathspecs.items)) continue;

        var buf: [256]u8 = undefined;
        const hex = entry.oid.toHex();
        const sha_len = if (opts.abbrev) |a| @min(a, types.OID_HEX_LEN) else types.OID_HEX_LEN;
        const line = std.fmt.bufPrint(&buf, "{o:0>6} {s} {d}\t", .{
            @as(u32, entry.mode),
            hex[0..sha_len],
            stage,
        }) catch continue;
        try stdout_file.writeAll(line);
        try stdout_file.writeAll(entry.name);
        var term: [1]u8 = .{terminator};
        try stdout_file.writeAll(&term);
    }
}

fn listDeletedOrModified(
    allocator: std.mem.Allocator,
    idx: *const index_mod.Index,
    work_dir: []const u8,
    opts: *const LsFilesOptions,
) !void {
    const terminator: u8 = if (opts.nul_terminated) 0 else '\n';
    _ = allocator;

    for (idx.entries.items) |*entry| {
        const stage = (entry.flags >> 12) & 0x3;
        if (stage != 0) continue;

        if (!matchesPathspec(entry.name, opts.pathspecs.items)) continue;

        // Build full path
        var path_buf: [4096]u8 = undefined;
        var pos: usize = 0;
        if (work_dir.len > 0) {
            @memcpy(path_buf[pos..][0..work_dir.len], work_dir);
            pos += work_dir.len;
            path_buf[pos] = '/';
            pos += 1;
        }
        @memcpy(path_buf[pos..][0..entry.name.len], entry.name);
        pos += entry.name.len;
        const full_path = path_buf[0..pos];

        const file = std.fs.openFileAbsolute(full_path, .{}) catch {
            // File deleted
            if (opts.show_deleted) {
                try stdout_file.writeAll(entry.name);
                var term: [1]u8 = .{terminator};
                try stdout_file.writeAll(&term);
            }
            continue;
        };
        file.close();

        // File exists -- check if modified
        if (opts.show_modified) {
            const stat = std.fs.openFileAbsolute(full_path, .{}) catch continue;
            defer stat.close();
            const fstat = stat.stat() catch continue;
            const mtime_s: u32 = @intCast(@as(u64, @intCast(@divFloor(fstat.mtime, 1_000_000_000))));
            const fsize: u32 = @intCast(@min(fstat.size, std.math.maxInt(u32)));

            // Quick check: size or mtime difference
            if (fsize != entry.file_size or mtime_s != entry.mtime_s) {
                try stdout_file.writeAll(entry.name);
                var term: [1]u8 = .{terminator};
                try stdout_file.writeAll(&term);
            }
        }
    }
}

fn listOthersOrIgnored(
    allocator: std.mem.Allocator,
    idx: *const index_mod.Index,
    work_dir: []const u8,
    ignore: *const ignore_mod.IgnoreRules,
    opts: *const LsFilesOptions,
) !void {
    // Build a set of tracked file names for quick lookup
    var tracked = std.StringHashMap(void).init(allocator);
    defer tracked.deinit();

    for (idx.entries.items) |*entry| {
        tracked.put(entry.name, {}) catch {};
    }

    // Walk the working directory
    try walkDirectory(allocator, work_dir, "", &tracked, ignore, opts);
}

fn walkDirectory(
    allocator: std.mem.Allocator,
    work_dir: []const u8,
    prefix: []const u8,
    tracked: *const std.StringHashMap(void),
    ignore: *const ignore_mod.IgnoreRules,
    opts: *const LsFilesOptions,
) !void {
    var dir_path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(dir_path_buf[pos..][0..work_dir.len], work_dir);
    pos += work_dir.len;
    if (prefix.len > 0) {
        dir_path_buf[pos] = '/';
        pos += 1;
        @memcpy(dir_path_buf[pos..][0..prefix.len], prefix);
        pos += prefix.len;
    }
    const dir_path = dir_path_buf[0..pos];

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    const terminator: u8 = if (opts.nul_terminated) 0 else '\n';

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip .git directory
        if (std.mem.eql(u8, entry.name, ".git")) continue;

        // Build relative path
        var rel_buf: [4096]u8 = undefined;
        var rpos: usize = 0;
        if (prefix.len > 0) {
            @memcpy(rel_buf[rpos..][0..prefix.len], prefix);
            rpos += prefix.len;
            rel_buf[rpos] = '/';
            rpos += 1;
        }
        @memcpy(rel_buf[rpos..][0..entry.name.len], entry.name);
        rpos += entry.name.len;
        const rel_path = rel_buf[0..rpos];

        const is_dir = entry.kind == .directory;
        const is_ignored = ignore.isIgnored(rel_path, is_dir);

        if (is_dir) {
            if (!is_ignored) {
                walkDirectory(allocator, work_dir, rel_path, tracked, ignore, opts) catch {};
            }
            continue;
        }

        // It's a file
        if (tracked.contains(rel_path)) continue;

        if (opts.show_ignored and is_ignored) {
            try stdout_file.writeAll(rel_path);
            var term: [1]u8 = .{terminator};
            try stdout_file.writeAll(&term);
        } else if (opts.show_others and !is_ignored) {
            try stdout_file.writeAll(rel_path);
            var term: [1]u8 = .{terminator};
            try stdout_file.writeAll(&term);
        }
    }
}

fn listEolInfo(
    allocator: std.mem.Allocator,
    idx: *const index_mod.Index,
    work_dir: []const u8,
    opts: *const LsFilesOptions,
) !void {
    _ = allocator;
    const terminator: u8 = if (opts.nul_terminated) 0 else '\n';

    for (idx.entries.items) |*entry| {
        const stage = (entry.flags >> 12) & 0x3;
        if (stage != 0) continue;

        if (!matchesPathspec(entry.name, opts.pathspecs.items)) continue;

        // Try to read file and detect line endings
        var path_buf: [4096]u8 = undefined;
        var pos: usize = 0;
        if (work_dir.len > 0) {
            @memcpy(path_buf[pos..][0..work_dir.len], work_dir);
            pos += work_dir.len;
            path_buf[pos] = '/';
            pos += 1;
        }
        @memcpy(path_buf[pos..][0..entry.name.len], entry.name);
        pos += entry.name.len;
        const full_path = path_buf[0..pos];

        var eol_info: []const u8 = "binary";
        const file = std.fs.openFileAbsolute(full_path, .{}) catch {
            eol_info = "                 ";
            var buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "i/lf    w/{s}\t", .{eol_info}) catch continue;
            try stdout_file.writeAll(line);
            try stdout_file.writeAll(entry.name);
            var term: [1]u8 = .{terminator};
            try stdout_file.writeAll(&term);
            continue;
        };
        defer file.close();

        // Read a small sample for EOL detection
        var sample: [8192]u8 = undefined;
        const n = file.readAll(&sample) catch 0;
        if (n == 0) {
            eol_info = "none";
        } else {
            const data = sample[0..n];
            var has_crlf = false;
            var has_lf = false;
            var has_cr = false;

            var j: usize = 0;
            while (j < data.len) : (j += 1) {
                if (data[j] == '\r') {
                    if (j + 1 < data.len and data[j + 1] == '\n') {
                        has_crlf = true;
                        j += 1;
                    } else {
                        has_cr = true;
                    }
                } else if (data[j] == '\n') {
                    has_lf = true;
                }
            }

            if (has_crlf and !has_lf and !has_cr) {
                eol_info = "crlf";
            } else if (has_lf and !has_crlf and !has_cr) {
                eol_info = "lf";
            } else if (has_cr and !has_lf and !has_crlf) {
                eol_info = "cr";
            } else if (has_crlf and has_lf) {
                eol_info = "mixed";
            } else {
                eol_info = "none";
            }
        }

        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "i/lf    w/{s}\t", .{eol_info}) catch continue;
        try stdout_file.writeAll(line);
        try stdout_file.writeAll(entry.name);
        var term: [1]u8 = .{terminator};
        try stdout_file.writeAll(&term);
    }
}
