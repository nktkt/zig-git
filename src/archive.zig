const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_diff = @import("tree_diff.zig");
const checkout_mod = @import("checkout.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// TAR block size is always 512 bytes.
const TAR_BLOCK_SIZE = 512;

/// TAR header offsets and sizes.
const TAR_NAME_OFFSET = 0;
const TAR_NAME_SIZE = 100;
const TAR_MODE_OFFSET = 100;
const TAR_MODE_SIZE = 8;
const TAR_UID_OFFSET = 108;
const TAR_UID_SIZE = 8;
const TAR_GID_OFFSET = 116;
const TAR_GID_SIZE = 8;
const TAR_SIZE_OFFSET = 124;
const TAR_SIZE_SIZE = 12;
const TAR_MTIME_OFFSET = 136;
const TAR_MTIME_SIZE = 12;
const TAR_CHECKSUM_OFFSET = 148;
const TAR_CHECKSUM_SIZE = 8;
const TAR_TYPEFLAG_OFFSET = 156;
const TAR_LINKNAME_OFFSET = 157;
const TAR_LINKNAME_SIZE = 100;
const TAR_MAGIC_OFFSET = 257;
const TAR_MAGIC_SIZE = 6;
const TAR_VERSION_OFFSET = 263;
const TAR_VERSION_SIZE = 2;
const TAR_UNAME_OFFSET = 265;
const TAR_UNAME_SIZE = 32;
const TAR_GNAME_OFFSET = 297;
const TAR_GNAME_SIZE = 32;
const TAR_PREFIX_OFFSET = 345;
const TAR_PREFIX_SIZE = 155;

/// Options for the archive command.
pub const ArchiveOptions = struct {
    tree_ish: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    output: ?[]const u8 = null,
    format: ArchiveFormat = .tar,
    verbose: bool = false,
};

/// Supported archive formats.
pub const ArchiveFormat = enum {
    tar,
};

/// A file to be archived.
const ArchiveEntry = struct {
    path: []const u8,
    mode: u32,
    oid: types.ObjectId,
    size: u64,
};

/// Entry point for the archive command.
pub fn runArchive(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = ArchiveOptions{};

    // Parse arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.startsWith(u8, arg, "--prefix=")) {
            opts.prefix = arg["--prefix=".len..];
        } else if (std.mem.eql(u8, arg, "--prefix")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("error: --prefix requires a value\n");
                std.process.exit(1);
            }
            opts.prefix = args[i];
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            opts.output = arg["--output=".len..];
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("error: --output requires a file path\n");
                std.process.exit(1);
            }
            opts.output = args[i];
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            const fmt = arg["--format=".len..];
            if (!std.mem.eql(u8, fmt, "tar")) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "error: unsupported format '{s}' (only 'tar' is supported)\n", .{fmt}) catch
                    "error: unsupported format\n";
                try stderr_file.writeAll(msg);
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            try stdout_file.writeAll("tar\n");
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            opts.tree_ish = arg;
        }
    }

    if (opts.tree_ish == null) {
        opts.tree_ish = "HEAD";
    }

    // Resolve the tree
    const ref_str = opts.tree_ish.?;
    const oid = repo.resolveRef(allocator, ref_str) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: not a valid object name '{s}'\n", .{ref_str}) catch
            "fatal: not a valid object name\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    // Resolve to a tree
    const tree_oid = try resolveToTree(repo, allocator, &oid);

    // Flatten the tree to get all files
    var flat = try checkout_mod.flattenTree(allocator, repo, &tree_oid);
    defer flat.deinit();

    // Get commit timestamp for mtime (if we resolved from a commit)
    const mtime = getCommitTimestamp(repo, allocator, &oid);

    // Determine output target
    var output_file: std.fs.File = stdout_file;
    var close_output = false;

    if (opts.output) |output_path| {
        output_file = std.fs.createFileAbsolute(output_path, .{ .truncate = true }) catch blk: {
            // Try relative path
            break :blk std.fs.cwd().createFile(output_path, .{ .truncate = true }) catch {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: cannot open output file '{s}'\n", .{output_path}) catch
                    "fatal: cannot open output file\n";
                try stderr_file.writeAll(msg);
                std.process.exit(128);
            };
        };
        close_output = true;
    }
    defer if (close_output) output_file.close();

    // Write tar archive
    try writeTarArchive(allocator, repo, &flat, output_file, opts.prefix, mtime, opts.verbose);
}

/// Resolve an OID to a tree OID (handles commits and tags).
fn resolveToTree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    oid: *const types.ObjectId,
) !types.ObjectId {
    var obj = try repo.readObject(allocator, oid);
    defer obj.deinit();

    switch (obj.obj_type) {
        .tree => return oid.*,
        .commit => return tree_diff.getCommitTreeOid(obj.data),
        .tag => {
            // Parse tag to find the target object
            const target_oid = parseTagTarget(obj.data) orelse return error.InvalidTag;
            return resolveToTree(repo, allocator, &target_oid);
        },
        .blob => return error.NotATree,
    }
}

/// Get the commit timestamp (for file modification times in the archive).
fn getCommitTimestamp(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    oid: *const types.ObjectId,
) u64 {
    var obj = repo.readObject(allocator, oid) catch return 0;
    defer obj.deinit();

    if (obj.obj_type != .commit) return 0;

    // Parse committer timestamp
    var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "committer ")) {
            const gt_pos = std.mem.indexOfScalar(u8, line, '>') orelse continue;
            if (gt_pos + 2 < line.len) {
                const after = line[gt_pos + 2 ..];
                const space_pos = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
                return std.fmt.parseInt(u64, after[0..space_pos], 10) catch 0;
            }
        }
    }

    return 0;
}

/// Parse a tag object to find the target OID.
fn parseTagTarget(data: []const u8) ?types.ObjectId {
    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "object ")) {
            if (line.len >= 7 + types.OID_HEX_LEN) {
                return types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch null;
            }
        }
    }
    return null;
}

/// Write a TAR archive to the output file.
fn writeTarArchive(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    flat: *const checkout_mod.FlatTreeResult,
    output: std.fs.File,
    prefix: ?[]const u8,
    mtime: u64,
    verbose: bool,
) !void {
    // If prefix is set and ends with '/', add a directory entry for it
    if (prefix) |pfx| {
        if (pfx.len > 0) {
            try writeTarDirectoryEntry(output, pfx, mtime);

            if (verbose) {
                try stderr_file.writeAll(pfx);
                try stderr_file.writeAll("\n");
            }
        }
    }

    // Track directories we've already written entries for
    var written_dirs = std.StringHashMap(void).init(allocator);
    defer {
        var it = written_dirs.keyIterator();
        while (it.next()) |key| {
            allocator.free(key.*);
        }
        written_dirs.deinit();
    }

    // Write file entries
    for (flat.entries.items) |*entry| {
        // Read the blob
        var obj = repo.readObject(allocator, &entry.oid) catch continue;
        defer obj.deinit();

        if (obj.obj_type != .blob) continue;

        // Build the full path with prefix
        var path_buf: [4096]u8 = undefined;
        const full_path = buildArchivePath(&path_buf, prefix, entry.path);

        // Ensure parent directories have been written
        try writeParentDirs(output, full_path, mtime, &written_dirs, allocator);

        // Write the file entry
        try writeTarFileEntry(output, full_path, obj.data, entry.mode, mtime);

        if (verbose) {
            try stderr_file.writeAll(full_path);
            try stderr_file.writeAll("\n");
        }
    }

    // Write two zero blocks to mark end of archive
    const zero_block = [_]u8{0} ** TAR_BLOCK_SIZE;
    try output.writeAll(&zero_block);
    try output.writeAll(&zero_block);
}

/// Write parent directory entries that haven't been written yet.
fn writeParentDirs(
    output: std.fs.File,
    full_path: []const u8,
    mtime: u64,
    written_dirs: *std.StringHashMap(void),
    allocator: std.mem.Allocator,
) !void {
    var dir_path = full_path;
    while (true) {
        const parent = std.fs.path.dirname(dir_path);
        if (parent == null) break;
        dir_path = parent.?;
        if (dir_path.len == 0) break;

        // Check if we've already written this directory
        if (written_dirs.contains(dir_path)) break;

        // Build directory name with trailing /
        var dir_buf: [4096]u8 = undefined;
        @memcpy(dir_buf[0..dir_path.len], dir_path);
        dir_buf[dir_path.len] = '/';
        const dir_name = dir_buf[0 .. dir_path.len + 1];

        try writeTarDirectoryEntry(output, dir_name, mtime);

        // Mark as written (key is freed when written_dirs is cleaned up)
        const key = try allocator.alloc(u8, dir_path.len);
        @memcpy(key, dir_path);
        try written_dirs.put(key, {});
    }
}

/// Write a TAR header for a directory entry.
fn writeTarDirectoryEntry(output: std.fs.File, name: []const u8, mtime: u64) !void {
    var header: [TAR_BLOCK_SIZE]u8 = undefined;
    @memset(&header, 0);

    // Name (ensure trailing /)
    const name_len = @min(name.len, TAR_NAME_SIZE);
    @memcpy(header[TAR_NAME_OFFSET..][0..name_len], name[0..name_len]);

    // Mode: 0755 for directories
    writeOctal(header[TAR_MODE_OFFSET..][0..TAR_MODE_SIZE], 0o755, TAR_MODE_SIZE);

    // UID and GID: 0
    writeOctal(header[TAR_UID_OFFSET..][0..TAR_UID_SIZE], 0, TAR_UID_SIZE);
    writeOctal(header[TAR_GID_OFFSET..][0..TAR_GID_SIZE], 0, TAR_GID_SIZE);

    // Size: 0 for directories
    writeOctal(header[TAR_SIZE_OFFSET..][0..TAR_SIZE_SIZE], 0, TAR_SIZE_SIZE);

    // Modification time
    writeOctal(header[TAR_MTIME_OFFSET..][0..TAR_MTIME_SIZE], mtime, TAR_MTIME_SIZE);

    // Type flag: '5' for directory
    header[TAR_TYPEFLAG_OFFSET] = '5';

    // USTAR magic
    @memcpy(header[TAR_MAGIC_OFFSET..][0..5], "ustar");
    header[TAR_MAGIC_OFFSET + 5] = 0;

    // Version
    header[TAR_VERSION_OFFSET] = '0';
    header[TAR_VERSION_OFFSET + 1] = '0';

    // User and group names
    @memcpy(header[TAR_UNAME_OFFSET..][0..6], "zig-git"[0..6]);
    @memcpy(header[TAR_GNAME_OFFSET..][0..6], "zig-git"[0..6]);

    // Calculate and write checksum
    computeAndWriteChecksum(&header);

    try output.writeAll(&header);
}

/// Write a TAR header and content for a file entry.
fn writeTarFileEntry(
    output: std.fs.File,
    name: []const u8,
    data: []const u8,
    mode: u32,
    mtime: u64,
) !void {
    var header: [TAR_BLOCK_SIZE]u8 = undefined;
    @memset(&header, 0);

    // Handle long names using prefix field
    if (name.len > TAR_NAME_SIZE) {
        // Try to split at a '/' boundary
        const split = findPrefixSplit(name);
        if (split) |sp| {
            const prefix_part = name[0..sp];
            const name_part = name[sp + 1 ..];

            if (prefix_part.len <= TAR_PREFIX_SIZE and name_part.len <= TAR_NAME_SIZE) {
                @memcpy(header[TAR_PREFIX_OFFSET..][0..prefix_part.len], prefix_part);
                @memcpy(header[TAR_NAME_OFFSET..][0..name_part.len], name_part);
            } else {
                // Truncate if name is too long
                const trunc_len = @min(name.len, TAR_NAME_SIZE);
                @memcpy(header[TAR_NAME_OFFSET..][0..trunc_len], name[0..trunc_len]);
            }
        } else {
            const trunc_len = @min(name.len, TAR_NAME_SIZE);
            @memcpy(header[TAR_NAME_OFFSET..][0..trunc_len], name[0..trunc_len]);
        }
    } else {
        @memcpy(header[TAR_NAME_OFFSET..][0..name.len], name);
    }

    // Mode: use the git mode (but ensure it's a valid tar mode)
    const tar_mode = if (mode & 0o111 != 0) @as(u64, 0o755) else @as(u64, 0o644);
    writeOctal(header[TAR_MODE_OFFSET..][0..TAR_MODE_SIZE], tar_mode, TAR_MODE_SIZE);

    // UID and GID
    writeOctal(header[TAR_UID_OFFSET..][0..TAR_UID_SIZE], 0, TAR_UID_SIZE);
    writeOctal(header[TAR_GID_OFFSET..][0..TAR_GID_SIZE], 0, TAR_GID_SIZE);

    // Size
    writeOctal(header[TAR_SIZE_OFFSET..][0..TAR_SIZE_SIZE], data.len, TAR_SIZE_SIZE);

    // Modification time
    writeOctal(header[TAR_MTIME_OFFSET..][0..TAR_MTIME_SIZE], mtime, TAR_MTIME_SIZE);

    // Type flag: '0' for regular file
    header[TAR_TYPEFLAG_OFFSET] = '0';

    // USTAR magic
    @memcpy(header[TAR_MAGIC_OFFSET..][0..5], "ustar");
    header[TAR_MAGIC_OFFSET + 5] = 0;

    // Version
    header[TAR_VERSION_OFFSET] = '0';
    header[TAR_VERSION_OFFSET + 1] = '0';

    // User/group names
    @memcpy(header[TAR_UNAME_OFFSET..][0..6], "zig-git"[0..6]);
    @memcpy(header[TAR_GNAME_OFFSET..][0..6], "zig-git"[0..6]);

    // Calculate checksum
    computeAndWriteChecksum(&header);

    // Write header
    try output.writeAll(&header);

    // Write file content
    try output.writeAll(data);

    // Pad to block boundary
    const remainder = data.len % TAR_BLOCK_SIZE;
    if (remainder > 0) {
        const padding_size = TAR_BLOCK_SIZE - remainder;
        const zero_padding = [_]u8{0} ** TAR_BLOCK_SIZE;
        try output.writeAll(zero_padding[0..padding_size]);
    }
}

/// Write an octal value into a tar header field.
fn writeOctal(buf: []u8, value: u64, field_size: usize) void {
    // Format as octal string, right-aligned with leading zeros
    const digits = field_size - 1; // Leave room for NUL terminator

    // Manual octal formatting
    var val = value;
    var oct_buf: [22]u8 = undefined;
    var oct_len: usize = 0;

    if (val == 0) {
        oct_buf[0] = '0';
        oct_len = 1;
    } else {
        while (val > 0) : (oct_len += 1) {
            oct_buf[oct_len] = @intCast((val % 8) + '0');
            val /= 8;
        }
        // Reverse
        std.mem.reverse(u8, oct_buf[0..oct_len]);
    }

    // Pad with leading zeros
    @memset(buf[0..field_size], 0);
    if (oct_len >= digits) {
        @memcpy(buf[0..digits], oct_buf[oct_len - digits .. oct_len]);
    } else {
        const pad = digits - oct_len;
        @memset(buf[0..pad], '0');
        @memcpy(buf[pad..][0..oct_len], oct_buf[0..oct_len]);
    }
    // NUL terminator
    if (field_size > 0) {
        buf[field_size - 1] = 0;
    }
}

/// Compute the tar header checksum and write it into the checksum field.
fn computeAndWriteChecksum(header: *[TAR_BLOCK_SIZE]u8) void {
    // First, treat checksum field as spaces
    @memset(header[TAR_CHECKSUM_OFFSET..][0..TAR_CHECKSUM_SIZE], ' ');

    // Sum all bytes
    var checksum: u64 = 0;
    for (header) |byte| {
        checksum += byte;
    }

    // Write checksum as octal
    writeOctal(header[TAR_CHECKSUM_OFFSET..][0..TAR_CHECKSUM_SIZE], checksum, 7);
    header[TAR_CHECKSUM_OFFSET + 7] = ' ';
}

/// Find a suitable split point for prefix/name in a long path.
fn findPrefixSplit(name: []const u8) ?usize {
    // Find the last '/' that would make both parts fit
    var best_split: ?usize = null;
    for (name, 0..) |c, idx| {
        if (c == '/') {
            if (idx <= TAR_PREFIX_SIZE and name.len - idx - 1 <= TAR_NAME_SIZE) {
                best_split = idx;
            }
        }
    }
    return best_split;
}

/// Build the archive path with prefix.
fn buildArchivePath(buf: []u8, prefix: ?[]const u8, path: []const u8) []const u8 {
    if (prefix) |pfx| {
        if (pfx.len > 0) {
            @memcpy(buf[0..pfx.len], pfx);
            // Ensure prefix ends with /
            var pos = pfx.len;
            if (pfx[pfx.len - 1] != '/') {
                buf[pos] = '/';
                pos += 1;
            }
            @memcpy(buf[pos..][0..path.len], path);
            return buf[0 .. pos + path.len];
        }
    }
    @memcpy(buf[0..path.len], path);
    return buf[0..path.len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writeOctal zero" {
    var buf: [8]u8 = undefined;
    writeOctal(&buf, 0, 8);
    try std.testing.expectEqualStrings("0000000", buf[0..7]);
    try std.testing.expectEqual(@as(u8, 0), buf[7]);
}

test "writeOctal value" {
    var buf: [8]u8 = undefined;
    writeOctal(&buf, 0o755, 8);
    // 755 octal = "0000755"
    try std.testing.expectEqualStrings("0000755", buf[0..7]);
}

test "writeOctal large" {
    var buf: [12]u8 = undefined;
    writeOctal(&buf, 1024, 12);
    // 1024 = 0o2000
    try std.testing.expectEqualStrings("00000002000", buf[0..11]);
}

test "computeAndWriteChecksum" {
    var header: [TAR_BLOCK_SIZE]u8 = undefined;
    @memset(&header, 0);
    header[0] = 'a';
    header[1] = 'b';
    computeAndWriteChecksum(&header);
    // After checksum, field should be non-zero
    var all_zero = true;
    for (header[TAR_CHECKSUM_OFFSET..][0..TAR_CHECKSUM_SIZE]) |b| {
        if (b != 0 and b != ' ') {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

test "buildArchivePath no prefix" {
    var buf: [256]u8 = undefined;
    const result = buildArchivePath(&buf, null, "src/main.zig");
    try std.testing.expectEqualStrings("src/main.zig", result);
}

test "buildArchivePath with prefix" {
    var buf: [256]u8 = undefined;
    const result = buildArchivePath(&buf, "myproject/", "src/main.zig");
    try std.testing.expectEqualStrings("myproject/src/main.zig", result);
}

test "buildArchivePath prefix without slash" {
    var buf: [256]u8 = undefined;
    const result = buildArchivePath(&buf, "myproject", "src/main.zig");
    try std.testing.expectEqualStrings("myproject/src/main.zig", result);
}

test "findPrefixSplit" {
    // Short path: no split needed
    const result1 = findPrefixSplit("short.txt");
    try std.testing.expect(result1 == null);

    // Path with slash
    const result2 = findPrefixSplit("dir/file.txt");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(usize, 3), result2.?);
}

test "parseTagTarget" {
    const data = "object e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\ntype commit\ntag v1.0\n\nmessage\n";
    const oid = parseTagTarget(data);
    try std.testing.expect(oid != null);
    const hex = oid.?.toHex();
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &hex);
}
