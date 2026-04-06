const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const object_walk = @import("object_walk.zig");
const pack_writer = @import("pack_writer.zig");
const hash_mod = @import("hash.zig");
const ref_mod = @import("ref.zig");
const loose = @import("loose.zig");
const compress = @import("compress.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const BUNDLE_V2_HEADER = "# v2 git bundle\n";

/// A reference entry in the bundle header.
pub const BundleRef = struct {
    oid: types.ObjectId,
    name: []const u8,
};

/// A prerequisite commit in the bundle header.
pub const BundlePrerequisite = struct {
    oid: types.ObjectId,
};

/// Parsed bundle header information.
pub const BundleHeader = struct {
    allocator: std.mem.Allocator,
    prerequisites: std.array_list.Managed(BundlePrerequisite),
    refs: std.array_list.Managed(BundleRef),
    ref_names: std.array_list.Managed([]u8),
    pack_data_offset: usize,

    pub fn init(allocator: std.mem.Allocator) BundleHeader {
        return .{
            .allocator = allocator,
            .prerequisites = std.array_list.Managed(BundlePrerequisite).init(allocator),
            .refs = std.array_list.Managed(BundleRef).init(allocator),
            .ref_names = std.array_list.Managed([]u8).init(allocator),
            .pack_data_offset = 0,
        };
    }

    pub fn deinit(self: *BundleHeader) void {
        self.prerequisites.deinit();
        self.refs.deinit();
        for (self.ref_names.items) |name| {
            self.allocator.free(name);
        }
        self.ref_names.deinit();
    }
};

/// Parse a bundle file header. Returns header info with pack data offset.
pub fn parseBundleHeader(allocator: std.mem.Allocator, data: []const u8) !BundleHeader {
    var header = BundleHeader.init(allocator);
    errdefer header.deinit();

    // Check magic header
    if (data.len < BUNDLE_V2_HEADER.len) return error.InvalidBundleFormat;
    if (!std.mem.startsWith(u8, data, BUNDLE_V2_HEADER)) return error.InvalidBundleFormat;

    var pos: usize = BUNDLE_V2_HEADER.len;
    var line_start = pos;

    while (pos < data.len) {
        if (data[pos] == '\n') {
            const line = data[line_start..pos];

            // Empty line marks end of header
            if (line.len == 0) {
                header.pack_data_offset = pos + 1;
                return header;
            }

            // Prerequisite line: -<hex SHA>
            if (line.len > 0 and line[0] == '-') {
                if (line.len >= 1 + types.OID_HEX_LEN) {
                    const oid = try types.ObjectId.fromHex(line[1..][0..types.OID_HEX_LEN]);
                    try header.prerequisites.append(.{ .oid = oid });
                } else {
                    return error.InvalidBundleFormat;
                }
            } else {
                // Ref line: <hex SHA> <refname>
                if (line.len >= types.OID_HEX_LEN + 1) {
                    const oid = try types.ObjectId.fromHex(line[0..types.OID_HEX_LEN]);
                    const ref_name_src = line[types.OID_HEX_LEN + 1 ..];
                    const ref_name = try allocator.alloc(u8, ref_name_src.len);
                    @memcpy(ref_name, ref_name_src);
                    try header.ref_names.append(ref_name);
                    try header.refs.append(.{
                        .oid = oid,
                        .name = ref_name,
                    });
                } else {
                    return error.InvalidBundleFormat;
                }
            }

            line_start = pos + 1;
        }
        pos += 1;
    }

    // If we reach here without an empty line, treat remaining as pack data
    header.pack_data_offset = data.len;
    return header;
}

/// Read a bundle file from disk, returning its raw content.
fn readBundleFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Try as absolute path first, then relative
    const file = std.fs.openFileAbsolute(path, .{}) catch blk: {
        break :blk std.fs.cwd().openFile(path, .{}) catch return error.BundleFileNotFound;
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.size > 256 * 1024 * 1024) return error.BundleFileTooLarge;
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    const n = try file.readAll(buf);
    if (n < buf.len) {
        const trimmed = try allocator.alloc(u8, n);
        @memcpy(trimmed, buf[0..n]);
        allocator.free(buf);
        return trimmed;
    }
    return buf;
}

/// Create a bundle file containing objects reachable from tips but not from exclude set.
/// Format: v2 bundle header + pack data.
pub fn createBundle(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    bundle_path: []const u8,
    rev_args: []const []const u8,
) !void {
    // Parse rev-list arguments into tips and excludes
    var tips = std.array_list.Managed(types.ObjectId).init(allocator);
    defer tips.deinit();
    var excludes = std.array_list.Managed(types.ObjectId).init(allocator);
    defer excludes.deinit();

    // Collect ref names for refs we want to include
    var tip_ref_names = std.array_list.Managed([]const u8).init(allocator);
    defer tip_ref_names.deinit();

    for (rev_args) |arg| {
        if (std.mem.startsWith(u8, arg, "^")) {
            // Exclude
            const ref_str = arg[1..];
            const oid = repo.resolveRef(allocator, ref_str) catch {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: bad revision '{s}'\n", .{ref_str}) catch "fatal: bad revision\n";
                try stderr_file.writeAll(msg);
                std.process.exit(1);
            };
            try excludes.append(oid);
        } else if (std.mem.indexOf(u8, arg, "..")) |dot_pos| {
            // Range notation: exclude..include
            const exclude_ref = arg[0..dot_pos];
            const include_ref = arg[dot_pos + 2 ..];

            if (exclude_ref.len > 0) {
                const exc_oid = repo.resolveRef(allocator, exclude_ref) catch {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "fatal: bad revision '{s}'\n", .{exclude_ref}) catch "fatal: bad revision\n";
                    try stderr_file.writeAll(msg);
                    std.process.exit(1);
                };
                try excludes.append(exc_oid);
            }

            const inc_oid = repo.resolveRef(allocator, include_ref) catch {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: bad revision '{s}'\n", .{include_ref}) catch "fatal: bad revision\n";
                try stderr_file.writeAll(msg);
                std.process.exit(1);
            };
            try tips.append(inc_oid);
            try tip_ref_names.append(include_ref);
        } else {
            // Tip
            const oid = repo.resolveRef(allocator, arg) catch {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: bad revision '{s}'\n", .{arg}) catch "fatal: bad revision\n";
                try stderr_file.writeAll(msg);
                std.process.exit(1);
            };
            try tips.append(oid);
            try tip_ref_names.append(arg);
        }
    }

    if (tips.items.len == 0) {
        // Default: include HEAD
        const head_oid = repo.resolveRef(allocator, "HEAD") catch {
            try stderr_file.writeAll("fatal: cannot resolve HEAD\n");
            std.process.exit(1);
        };
        try tips.append(head_oid);
        try tip_ref_names.append("HEAD");
    }

    // Walk objects
    const objects = try object_walk.walkObjects(allocator, repo, tips.items, excludes.items);
    defer allocator.free(objects);

    // Build pack data
    var tmp_path_buf: [4096]u8 = undefined;
    const tmp_base = bufPrint(&tmp_path_buf, "/tmp/zig-git-bundle-{d}", .{std.time.milliTimestamp()});
    var pw = pack_writer.PackWriter.init(allocator, tmp_base);
    defer pw.deinit();

    for (objects) |oid| {
        var obj = repo.readObject(allocator, &oid) catch continue;
        defer obj.deinit();
        try pw.addObjectWithOid(obj.obj_type, obj.data, oid);
    }

    const pack_hash = try pw.finish();
    _ = pack_hash;

    // Read pack file data
    var pack_path_buf: [4096]u8 = undefined;
    const pack_path = concatStr(&pack_path_buf, tmp_base, ".pack");
    const pack_data = readFileContent(allocator, pack_path) catch {
        try stderr_file.writeAll("fatal: failed to read pack data\n");
        std.process.exit(128);
    };
    defer allocator.free(pack_data);

    // Build bundle content
    var bundle_data = std.array_list.Managed(u8).init(allocator);
    defer bundle_data.deinit();

    // Header
    try bundle_data.appendSlice(BUNDLE_V2_HEADER);

    // Prerequisites
    for (excludes.items) |exc_oid| {
        try bundle_data.append('-');
        const hex = exc_oid.toHex();
        try bundle_data.appendSlice(&hex);
        try bundle_data.append('\n');
    }

    // Refs
    for (tips.items, 0..) |tip_oid, i| {
        const hex = tip_oid.toHex();
        try bundle_data.appendSlice(&hex);
        try bundle_data.append(' ');
        const ref_name = if (i < tip_ref_names.items.len) tip_ref_names.items[i] else "HEAD";
        // Ensure we write a proper ref path
        if (std.mem.startsWith(u8, ref_name, "refs/")) {
            try bundle_data.appendSlice(ref_name);
        } else if (std.mem.eql(u8, ref_name, "HEAD")) {
            try bundle_data.appendSlice("HEAD");
        } else {
            try bundle_data.appendSlice("refs/heads/");
            try bundle_data.appendSlice(ref_name);
        }
        try bundle_data.append('\n');
    }

    // Blank line
    try bundle_data.append('\n');

    // Pack data
    try bundle_data.appendSlice(pack_data);

    // Write bundle file
    const bundle_file = std.fs.cwd().createFile(bundle_path, .{}) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: cannot create bundle file: {s}\n", .{@errorName(err)}) catch "fatal: cannot create bundle file\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };
    defer bundle_file.close();
    try bundle_file.writeAll(bundle_data.items);

    // Clean up temp files
    cleanupTempFile(pack_path);
    var idx_path_buf: [4096]u8 = undefined;
    const idx_path = concatStr(&idx_path_buf, tmp_base, ".idx");
    cleanupTempFile(idx_path);

    // Report
    var out_buf: [256]u8 = undefined;
    const out_msg = std.fmt.bufPrint(&out_buf, "Created bundle with {d} objects.\n", .{objects.len}) catch "Created bundle.\n";
    try stdout_file.writeAll(out_msg);
}

/// Verify a bundle file: check that all prerequisites exist in the repo.
pub fn verifyBundle(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    bundle_path: []const u8,
) !void {
    const data = try readBundleFile(allocator, bundle_path);
    defer allocator.free(data);

    var header = try parseBundleHeader(allocator, data);
    defer header.deinit();

    var missing_count: usize = 0;

    for (header.prerequisites.items) |prereq| {
        if (!repo.objectExists(&prereq.oid)) {
            const hex = prereq.oid.toHex();
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: prerequisite {s} not found\n", .{&hex}) catch "error: prerequisite not found\n";
            try stderr_file.writeAll(msg);
            missing_count += 1;
        }
    }

    if (missing_count > 0) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: {d} prerequisite commit(s) not found\n", .{missing_count}) catch "error: prerequisites not found\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    }

    // Report bundle info
    try stdout_file.writeAll("The bundle contains:\n");

    for (header.refs.items) |bref| {
        const hex = bref.oid.toHex();
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "  {s} {s}\n", .{ hex[0..7], bref.name }) catch continue;
        try stdout_file.writeAll(msg);
    }

    if (header.prerequisites.items.len > 0) {
        try stdout_file.writeAll("The bundle requires these commits:\n");
        for (header.prerequisites.items) |prereq| {
            const hex = prereq.oid.toHex();
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "  {s}\n", .{hex[0..7]}) catch continue;
            try stdout_file.writeAll(msg);
        }
    }

    try stdout_file.writeAll("The bundle is valid.\n");
}

/// List the refs (heads) contained in a bundle file.
pub fn listHeads(
    allocator: std.mem.Allocator,
    bundle_path: []const u8,
) !void {
    const data = try readBundleFile(allocator, bundle_path);
    defer allocator.free(data);

    var header = try parseBundleHeader(allocator, data);
    defer header.deinit();

    for (header.refs.items) |bref| {
        const hex = bref.oid.toHex();
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s} {s}\n", .{ &hex, bref.name }) catch continue;
        try stdout_file.writeAll(msg);
    }
}

/// Extract objects from a bundle into the repository and update refs.
pub fn unbundle(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    bundle_path: []const u8,
) !void {
    const data = try readBundleFile(allocator, bundle_path);
    defer allocator.free(data);

    var header = try parseBundleHeader(allocator, data);
    defer header.deinit();

    // Verify prerequisites first
    for (header.prerequisites.items) |prereq| {
        if (!repo.objectExists(&prereq.oid)) {
            const hex = prereq.oid.toHex();
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: prerequisite {s} not found\n", .{&hex}) catch "error: prerequisite not found\n";
            try stderr_file.writeAll(msg);
            std.process.exit(1);
        }
    }

    // Extract pack data
    if (header.pack_data_offset >= data.len) {
        try stderr_file.writeAll("warning: bundle contains no pack data\n");
    } else {
        const pack_data = data[header.pack_data_offset..];

        // Write pack data to a temp file in the pack directory
        var pack_dir_buf: [4096]u8 = undefined;
        const pack_dir = concatStr(&pack_dir_buf, repo.git_dir, "/objects/pack");

        // Ensure pack directory exists
        std.fs.makeDirAbsolute(pack_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Compute SHA of pack data for naming
        const pack_sha = hash_mod.sha1Digest(pack_data);
        var sha_hex: [types.OID_HEX_LEN]u8 = undefined;
        hash_mod.bytesToHex(&pack_sha, &sha_hex);

        var dest_path_buf: [4096]u8 = undefined;
        var dpos: usize = 0;
        @memcpy(dest_path_buf[dpos..][0..pack_dir.len], pack_dir);
        dpos += pack_dir.len;
        const pack_prefix = "/pack-";
        @memcpy(dest_path_buf[dpos..][0..pack_prefix.len], pack_prefix);
        dpos += pack_prefix.len;
        @memcpy(dest_path_buf[dpos..][0..sha_hex.len], &sha_hex);
        dpos += sha_hex.len;
        const pack_ext = ".pack";
        @memcpy(dest_path_buf[dpos..][0..pack_ext.len], pack_ext);
        dpos += pack_ext.len;
        const dest_pack_path = dest_path_buf[0..dpos];

        const pack_file = std.fs.createFileAbsolute(dest_pack_path, .{}) catch {
            try stderr_file.writeAll("fatal: cannot write pack file\n");
            std.process.exit(128);
        };
        defer pack_file.close();
        try pack_file.writeAll(pack_data);

        var out_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&out_buf, "Unpacked {d} bytes of pack data.\n", .{pack_data.len}) catch "Unpacked pack data.\n";
        try stdout_file.writeAll(msg);
    }

    // Update refs
    var refs_updated: usize = 0;
    for (header.refs.items) |bref| {
        writeRef(repo.git_dir, bref.name, &bref.oid) catch continue;
        refs_updated += 1;
    }

    var out_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&out_buf, "Updated {d} ref(s).\n", .{refs_updated}) catch "Updated refs.\n";
    try stdout_file.writeAll(msg);
}

/// Write a ref to the repository.
fn writeRef(git_dir: []const u8, ref_name: []const u8, oid: *const types.ObjectId) !void {
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    path_buf[pos] = '/';
    pos += 1;
    @memcpy(path_buf[pos..][0..ref_name.len], ref_name);
    pos += ref_name.len;
    const ref_path = path_buf[0..pos];

    // Ensure parent directory exists
    if (std.fs.path.dirname(ref_path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const hex = oid.toHex();
    const file = std.fs.createFileAbsolute(ref_path, .{}) catch return error.CannotWriteRef;
    defer file.close();
    file.writeAll(&hex) catch return error.CannotWriteRef;
    file.writeAll("\n") catch return error.CannotWriteRef;
}

/// Run the bundle command.
pub fn runBundle(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        try stderr_file.writeAll(bundle_usage);
        std.process.exit(1);
    }

    const subcmd = args[0];
    const sub_args = if (args.len > 1) args[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, subcmd, "create")) {
        if (sub_args.len < 1) {
            try stderr_file.writeAll("usage: zig-git bundle create <file> [<rev-list>]\n");
            std.process.exit(1);
        }
        const bundle_path = sub_args[0];
        const rev_args = if (sub_args.len > 1) sub_args[1..] else &[_][]const u8{};
        try createBundle(allocator, repo, bundle_path, rev_args);
    } else if (std.mem.eql(u8, subcmd, "verify")) {
        if (sub_args.len < 1) {
            try stderr_file.writeAll("usage: zig-git bundle verify <file>\n");
            std.process.exit(1);
        }
        try verifyBundle(allocator, repo, sub_args[0]);
    } else if (std.mem.eql(u8, subcmd, "list-heads")) {
        if (sub_args.len < 1) {
            try stderr_file.writeAll("usage: zig-git bundle list-heads <file>\n");
            std.process.exit(1);
        }
        try listHeads(allocator, sub_args[0]);
    } else if (std.mem.eql(u8, subcmd, "unbundle")) {
        if (sub_args.len < 1) {
            try stderr_file.writeAll("usage: zig-git bundle unbundle <file>\n");
            std.process.exit(1);
        }
        try unbundle(allocator, repo, sub_args[0]);
    } else {
        try stderr_file.writeAll(bundle_usage);
        std.process.exit(1);
    }
}

const bundle_usage =
    \\usage: zig-git bundle <command> [<args>]
    \\
    \\Commands:
    \\  create <file> [<rev-list>]  Create a bundle file
    \\  verify <file>               Verify a bundle file
    \\  list-heads <file>           List refs in a bundle
    \\  unbundle <file>             Extract objects from a bundle
    \\
;

// --- Helpers ---

fn readFileContent(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return error.FileNotFound;
    defer file.close();
    const stat = try file.stat();
    if (stat.size > 256 * 1024 * 1024) return error.FileTooLarge;
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    const n = try file.readAll(buf);
    if (n < buf.len) {
        const trimmed = try allocator.alloc(u8, n);
        @memcpy(trimmed, buf[0..n]);
        allocator.free(buf);
        return trimmed;
    }
    return buf;
}

fn cleanupTempFile(path: []const u8) void {
    std.fs.deleteFileAbsolute(path) catch {};
}

fn concatStr(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn bufPrint(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch buf[0..0];
}

test "parseBundleHeader" {
    const bundle_data = "# v2 git bundle\n-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/heads/main\n\nPACK";
    var header = try parseBundleHeader(std.testing.allocator, bundle_data);
    defer header.deinit();

    try std.testing.expectEqual(@as(usize, 1), header.prerequisites.items.len);
    try std.testing.expectEqual(@as(usize, 1), header.refs.items.len);
    try std.testing.expectEqualStrings("refs/heads/main", header.refs.items[0].name);
}

test "parseBundleHeader no prereqs" {
    const bundle_data = "# v2 git bundle\ncccccccccccccccccccccccccccccccccccccccc HEAD\n\nPACK";
    var header = try parseBundleHeader(std.testing.allocator, bundle_data);
    defer header.deinit();

    try std.testing.expectEqual(@as(usize, 0), header.prerequisites.items.len);
    try std.testing.expectEqual(@as(usize, 1), header.refs.items.len);
    try std.testing.expectEqualStrings("HEAD", header.refs.items[0].name);
}
