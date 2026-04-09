const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const hash_mod = @import("hash.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Output mode for diff-files.
pub const OutputMode = enum {
    /// Raw diff output: ":old_mode new_mode old_sha new_sha status\tpath"
    raw,
    /// Only file names.
    name_only,
    /// File names with status character.
    name_status,
};

/// Options for diff-files.
pub const DiffFilesOptions = struct {
    output_mode: OutputMode = .raw,
    /// Suppress output for unmerged entries.
    quiet_unmerged: bool = false,
    /// Only check specific paths (empty = all).
    paths: std.array_list.Managed([]const u8),

    fn deinit(self: *DiffFilesOptions) void {
        self.paths.deinit();
    }
};

/// A single diff-files entry.
pub const DiffFileEntry = struct {
    old_mode: u32,
    new_mode: u32,
    old_oid: types.ObjectId,
    new_oid: types.ObjectId,
    status: u8, // 'M', 'D', 'A', etc.
    path: []const u8,
    /// Whether this entry is unmerged.
    unmerged: bool,
};

pub fn runDiffFiles(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = DiffFilesOptions{
        .paths = std.array_list.Managed([]const u8).init(allocator),
    };
    defer opts.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--name-only")) {
            opts.output_mode = .name_only;
        } else if (std.mem.eql(u8, arg, "--name-status")) {
            opts.output_mode = .name_status;
        } else if (std.mem.eql(u8, arg, "-q")) {
            opts.quiet_unmerged = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try opts.paths.append(arg);
        }
    }

    var entries = try computeDiffFiles(repo, allocator, &opts);
    defer entries.deinit();

    for (entries.items) |*entry| {
        if (entry.unmerged and opts.quiet_unmerged) continue;

        switch (opts.output_mode) {
            .raw => try writeRawEntry(entry),
            .name_only => {
                try stdout_file.writeAll(entry.path);
                try stdout_file.writeAll("\n");
            },
            .name_status => {
                var buf: [2]u8 = undefined;
                buf[0] = entry.status;
                buf[1] = '\t';
                try stdout_file.writeAll(buf[0..2]);
                try stdout_file.writeAll(entry.path);
                try stdout_file.writeAll("\n");
            },
        }
    }
}

/// Compute differences between index and working tree.
pub fn computeDiffFiles(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    opts: *const DiffFilesOptions,
) !std.array_list.Managed(DiffFileEntry) {
    var result = std.array_list.Managed(DiffFileEntry).init(allocator);
    errdefer result.deinit();

    const work_dir = getWorkDir(repo.git_dir);

    // Load the index
    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPath(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    for (idx.entries.items) |*entry| {
        // If paths filter is set, check if this entry matches
        if (opts.paths.items.len > 0) {
            var matches = false;
            for (opts.paths.items) |p| {
                if (std.mem.eql(u8, entry.name, p) or std.mem.startsWith(u8, entry.name, p)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
        }

        // Check for unmerged entries (stage != 0)
        const stage = (entry.flags >> 12) & 0x3;
        if (stage != 0) {
            try result.append(.{
                .old_mode = entry.mode,
                .new_mode = entry.mode,
                .old_oid = entry.oid,
                .new_oid = types.ObjectId.ZERO,
                .status = 'U',
                .path = entry.name,
                .unmerged = true,
            });
            continue;
        }

        // Build working tree path
        var file_path_buf: [4096]u8 = undefined;
        const file_path = buildPath2(&file_path_buf, work_dir, "/", entry.name);

        // Try to stat the working tree file
        const file = std.fs.openFileAbsolute(file_path, .{}) catch {
            // File deleted from working tree
            try result.append(.{
                .old_mode = entry.mode,
                .new_mode = 0,
                .old_oid = entry.oid,
                .new_oid = types.ObjectId.ZERO,
                .status = 'D',
                .path = entry.name,
                .unmerged = false,
            });
            continue;
        };
        defer file.close();

        const stat = file.stat() catch continue;
        const file_size: u32 = @intCast(@min(stat.size, std.math.maxInt(u32)));

        // Quick check: if size matches and mtime matches, assume unchanged
        if (file_size == entry.file_size and entry.mtime_s != 0) {
            const mtime_s: u32 = @intCast(@divFloor(@as(i64, @intCast(stat.mtime)), 1_000_000_000));
            if (mtime_s == entry.mtime_s) continue;
        }

        // Read file and compute hash to check for actual changes
        if (stat.size > 10 * 1024 * 1024) {
            // File too large, just report as modified
            try result.append(.{
                .old_mode = entry.mode,
                .new_mode = entry.mode,
                .old_oid = entry.oid,
                .new_oid = types.ObjectId.ZERO,
                .status = 'M',
                .path = entry.name,
                .unmerged = false,
            });
            continue;
        }

        const content = allocator.alloc(u8, @intCast(stat.size)) catch continue;
        defer allocator.free(content);
        const n = file.readAll(content) catch continue;
        const data = content[0..n];

        // Compute blob OID
        const new_oid = computeBlobOid(data);
        if (new_oid.eql(&entry.oid)) continue; // No change

        // Determine new mode
        var new_mode = entry.mode;
        if (stat.mode & 0o111 != 0) {
            new_mode = 0o100755;
        } else {
            new_mode = 0o100644;
        }

        try result.append(.{
            .old_mode = entry.mode,
            .new_mode = new_mode,
            .old_oid = entry.oid,
            .new_oid = new_oid,
            .status = 'M',
            .path = entry.name,
            .unmerged = false,
        });
    }

    return result;
}

fn writeRawEntry(entry: *const DiffFileEntry) !void {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    const old_hex = entry.old_oid.toHex();
    const new_hex = entry.new_oid.toHex();

    try writer.print(":{d:0>6} {d:0>6} {s} {s} {c}\t", .{
        entry.old_mode,
        entry.new_mode,
        old_hex[0..7],
        new_hex[0..7],
        entry.status,
    });

    try stdout_file.writeAll(buf[0..stream.pos]);
    try stdout_file.writeAll(entry.path);
    try stdout_file.writeAll("\n");
}

fn computeBlobOid(data: []const u8) types.ObjectId {
    var header_buf: [64]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    hwriter.print("blob {d}", .{data.len}) catch return types.ObjectId.ZERO;
    hwriter.writeByte(0) catch return types.ObjectId.ZERO;
    const header = header_buf[0..hstream.pos];

    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    const digest = hasher.finalResult();
    return types.ObjectId{ .bytes = digest };
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

fn buildPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn buildPath2(buf: []u8, a: []const u8, sep: []const u8, c: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..a.len], a);
    pos += a.len;
    @memcpy(buf[pos..][0..sep.len], sep);
    pos += sep.len;
    @memcpy(buf[pos..][0..c.len], c);
    pos += c.len;
    return buf[0..pos];
}

test "computeBlobOid" {
    // Empty blob has a well-known SHA-1
    const empty_oid = computeBlobOid("");
    const hex = empty_oid.toHex();
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &hex);
}

test "DiffFileEntry status" {
    const entry = DiffFileEntry{
        .old_mode = 0o100644,
        .new_mode = 0o100644,
        .old_oid = types.ObjectId.ZERO,
        .new_oid = types.ObjectId.ZERO,
        .status = 'M',
        .path = "test.txt",
        .unmerged = false,
    };
    try std.testing.expectEqual(@as(u8, 'M'), entry.status);
}
