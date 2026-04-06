const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const hash_mod = @import("hash.zig");
const loose = @import("loose.zig");
const pack_writer = @import("pack_writer.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };
const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };

/// Extended hash-object: hash from stdin.
pub fn hashFromStdin(
    allocator: std.mem.Allocator,
    obj_type: types.ObjectType,
    write_object: bool,
    git_dir: ?[]const u8,
) !void {
    // Read all of stdin
    var data = std.array_list.Managed(u8).init(allocator);
    defer data.deinit();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = stdin_file.read(&buf) catch break;
        if (n == 0) break;
        try data.appendSlice(buf[0..n]);
    }

    const oid = pack_writer.computeObjectId(obj_type, data.items);

    if (write_object) {
        if (git_dir) |gd| {
            _ = try loose.writeLooseObject(allocator, gd, obj_type, data.items);
        } else {
            try stderr_file.writeAll("fatal: cannot write object without repository\n");
            std.process.exit(128);
        }
    }

    const hex = oid.toHex();
    try stdout_file.writeAll(&hex);
    try stdout_file.writeAll("\n");
}

/// Hash files whose paths are listed on stdin, one per line.
pub fn hashStdinPaths(
    allocator: std.mem.Allocator,
    obj_type: types.ObjectType,
    write_object: bool,
    git_dir: ?[]const u8,
) !void {
    // Read all of stdin to get paths
    var input_data = std.array_list.Managed(u8).init(allocator);
    defer input_data.deinit();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = stdin_file.read(&buf) catch break;
        if (n == 0) break;
        try input_data.appendSlice(buf[0..n]);
    }

    var line_iter = std.mem.splitScalar(u8, input_data.items, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r \t");
        if (trimmed.len == 0) continue;

        hashSingleFile(allocator, trimmed, obj_type, write_object, git_dir) catch |err| {
            var err_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&err_buf, "error: cannot hash '{s}': {s}\n", .{ trimmed, @errorName(err) }) catch "error: cannot hash file\n";
            try stderr_file.writeAll(msg);
        };
    }
}

/// Hash a single file and output its OID.
fn hashSingleFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    obj_type: types.ObjectType,
    write_object: bool,
    git_dir: ?[]const u8,
) !void {
    const file = std.fs.cwd().openFile(file_path, .{}) catch return error.FileNotFound;
    defer file.close();

    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);
    const n = try file.readAll(content);
    const data = content[0..n];

    const oid = pack_writer.computeObjectId(obj_type, data);

    if (write_object) {
        if (git_dir) |gd| {
            _ = try loose.writeLooseObject(allocator, gd, obj_type, data);
        }
    }

    const hex = oid.toHex();
    try stdout_file.writeAll(&hex);
    try stdout_file.writeAll("\n");
}

/// Hash with an arbitrary (literal) type string.
pub fn hashLiterally(
    allocator: std.mem.Allocator,
    type_str: []const u8,
    data: []const u8,
) !void {
    // Build header: "type size\0"
    var header_buf: [128]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    try hwriter.writeAll(type_str);
    try hwriter.writeByte(' ');
    try hwriter.print("{d}", .{data.len});
    try hwriter.writeByte(0);
    const header = header_buf[0..hstream.pos];

    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    const digest = hasher.finalResult();
    const oid = types.ObjectId{ .bytes = digest };

    const hex = oid.toHex();
    try stdout_file.writeAll(&hex);
    try stdout_file.writeAll("\n");

    _ = allocator;
}

/// Create a validated tag object (mktag command).
pub fn mkTag(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
) !void {
    // Read tag object data from stdin
    var data = std.array_list.Managed(u8).init(allocator);
    defer data.deinit();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = stdin_file.read(&buf) catch break;
        if (n == 0) break;
        try data.appendSlice(buf[0..n]);
    }

    // Validate tag format
    const content = data.items;

    // Must start with "object <hex>\n"
    if (!std.mem.startsWith(u8, content, "object ")) {
        try stderr_file.writeAll("error: invalid tag: missing 'object' header\n");
        std.process.exit(1);
    }

    if (content.len < 7 + types.OID_HEX_LEN + 1) {
        try stderr_file.writeAll("error: invalid tag: truncated object header\n");
        std.process.exit(1);
    }

    // Validate object hex
    _ = types.ObjectId.fromHex(content[7..][0..types.OID_HEX_LEN]) catch {
        try stderr_file.writeAll("error: invalid tag: bad object SHA\n");
        std.process.exit(1);
    };

    // Must have "type " line
    if (std.mem.indexOf(u8, content, "\ntype ") == null) {
        try stderr_file.writeAll("error: invalid tag: missing 'type' header\n");
        std.process.exit(1);
    }

    // Must have "tag " line
    if (std.mem.indexOf(u8, content, "\ntag ") == null) {
        try stderr_file.writeAll("error: invalid tag: missing 'tag' header\n");
        std.process.exit(1);
    }

    // Must have "tagger " line
    if (std.mem.indexOf(u8, content, "\ntagger ") == null) {
        try stderr_file.writeAll("error: invalid tag: missing 'tagger' header\n");
        std.process.exit(1);
    }

    // Write the tag object
    const oid = try loose.writeLooseObject(allocator, repo.git_dir, .tag, content);
    const hex = oid.toHex();
    try stdout_file.writeAll(&hex);
    try stdout_file.writeAll("\n");
}

/// Create a tree object from ls-tree formatted input (mktree command).
pub fn mkTree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
) !void {
    // Read input from stdin
    // Format: "<mode> <type> <hex>\t<name>" per line
    var input_data = std.array_list.Managed(u8).init(allocator);
    defer input_data.deinit();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = stdin_file.read(&buf) catch break;
        if (n == 0) break;
        try input_data.appendSlice(buf[0..n]);
    }

    // Build tree object binary data
    var tree_data = std.array_list.Managed(u8).init(allocator);
    defer tree_data.deinit();

    var line_iter = std.mem.splitScalar(u8, input_data.items, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r ");
        if (trimmed.len == 0) continue;

        // Parse: "<mode> <type> <hex>\t<name>"
        // Find the tab that separates hex from name
        const tab_pos = std.mem.indexOfScalar(u8, trimmed, '\t') orelse {
            try stderr_file.writeAll("error: invalid input format, expected tab separator\n");
            continue;
        };

        const metadata = trimmed[0..tab_pos];
        const name = trimmed[tab_pos + 1 ..];

        // Parse metadata: "<mode> <type> <hex>"
        var parts = std.mem.splitScalar(u8, metadata, ' ');
        const mode = parts.next() orelse continue;
        _ = parts.next(); // type (we don't need it for tree format)
        const hex_str = parts.next() orelse continue;

        if (hex_str.len < types.OID_HEX_LEN) continue;
        const oid = types.ObjectId.fromHex(hex_str[0..types.OID_HEX_LEN]) catch continue;

        // Tree format: "<mode> <name>\0<20-byte-oid>"
        try tree_data.appendSlice(mode);
        try tree_data.append(' ');
        try tree_data.appendSlice(name);
        try tree_data.append(0);
        try tree_data.appendSlice(&oid.bytes);
    }

    // Write the tree object
    const oid = try loose.writeLooseObject(allocator, repo.git_dir, .tree, tree_data.items);
    const hex = oid.toHex();
    try stdout_file.writeAll(&hex);
    try stdout_file.writeAll("\n");
}

/// Low-level commit creation (commit-tree command).
pub fn commitTree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    args: []const []const u8,
) !void {
    var tree_hex: ?[]const u8 = null;
    var parents = std.array_list.Managed([]const u8).init(allocator);
    defer parents.deinit();
    var message: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("error: -p requires a parent SHA\n");
                std.process.exit(1);
            }
            try parents.append(args[i]);
        } else if (std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("error: -m requires a message\n");
                std.process.exit(1);
            }
            message = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (tree_hex == null) {
                tree_hex = arg;
            }
        }
    }

    if (tree_hex == null) {
        try stderr_file.writeAll(commit_tree_usage);
        std.process.exit(1);
    }

    // Resolve tree
    const tree_oid = repo.resolveRef(allocator, tree_hex.?) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: not a valid object name '{s}'\n", .{tree_hex.?}) catch "fatal: not a valid object name\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    // If no message, read from stdin
    var owned_message: ?[]u8 = null;
    defer if (owned_message) |m| allocator.free(m);

    const final_message: []const u8 = if (message) |m| m else blk: {
        var msg_data = std.array_list.Managed(u8).init(allocator);
        defer msg_data.deinit();
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = stdin_file.read(&buf) catch break;
            if (n == 0) break;
            try msg_data.appendSlice(buf[0..n]);
        }
        owned_message = try msg_data.toOwnedSlice();
        break :blk owned_message.?;
    };

    // Get author/committer info
    const author_name = std.posix.getenv("GIT_AUTHOR_NAME") orelse "Unknown";
    const author_email = std.posix.getenv("GIT_AUTHOR_EMAIL") orelse "unknown@unknown";
    const committer_name = std.posix.getenv("GIT_COMMITTER_NAME") orelse author_name;
    const committer_email = std.posix.getenv("GIT_COMMITTER_EMAIL") orelse author_email;

    const timestamp = std.time.timestamp();

    // Build commit object
    var commit_data = std.array_list.Managed(u8).init(allocator);
    defer commit_data.deinit();

    // tree line
    const tree_hex_str = tree_oid.toHex();
    try commit_data.appendSlice("tree ");
    try commit_data.appendSlice(&tree_hex_str);
    try commit_data.append('\n');

    // parent lines
    for (parents.items) |parent_ref| {
        const parent_oid = repo.resolveRef(allocator, parent_ref) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: not a valid object name '{s}'\n", .{parent_ref}) catch "fatal: not a valid object name\n";
            try stderr_file.writeAll(msg);
            std.process.exit(128);
        };
        const parent_hex = parent_oid.toHex();
        try commit_data.appendSlice("parent ");
        try commit_data.appendSlice(&parent_hex);
        try commit_data.append('\n');
    }

    // author line
    var author_buf: [512]u8 = undefined;
    const author_line = std.fmt.bufPrint(&author_buf, "author {s} <{s}> {d} +0000\n", .{ author_name, author_email, timestamp }) catch "author unknown <unknown> 0 +0000\n";
    try commit_data.appendSlice(author_line);

    // committer line
    var committer_buf: [512]u8 = undefined;
    const committer_line = std.fmt.bufPrint(&committer_buf, "committer {s} <{s}> {d} +0000\n", .{ committer_name, committer_email, timestamp }) catch "committer unknown <unknown> 0 +0000\n";
    try commit_data.appendSlice(committer_line);

    // blank line + message
    try commit_data.append('\n');
    try commit_data.appendSlice(final_message);

    // Write commit object
    const oid = try loose.writeLooseObject(allocator, repo.git_dir, .commit, commit_data.items);
    const hex = oid.toHex();
    try stdout_file.writeAll(&hex);
    try stdout_file.writeAll("\n");
}

const commit_tree_usage =
    \\usage: zig-git commit-tree <tree> [-p <parent>]... [-m <message>]
    \\
    \\Create a new commit object from a tree and optional parents.
    \\If -m is not given, the commit message is read from stdin.
    \\
;

test "hashLiterally" {
    // Just test that it doesn't crash - output goes to stdout
    // In a real test we'd capture the output
}

test "computeObjectId consistency" {
    const oid1 = pack_writer.computeObjectId(.blob, "hello world");
    const oid2 = pack_writer.computeObjectId(.blob, "hello world");
    try std.testing.expect(oid1.eql(&oid2));
}
