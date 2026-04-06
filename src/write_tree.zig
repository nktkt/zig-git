const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const index_mod = @import("index.zig");
const tree_builder = @import("tree_builder.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

pub fn runWriteTree(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var prefix: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--prefix=")) {
            prefix = arg["--prefix=".len..];
        }
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

    // Check for unmerged entries
    for (idx.entries.items) |*entry| {
        const stage = (entry.flags >> 12) & 0x3;
        if (stage != 0) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: {s} has unmerged entries\n", .{entry.name}) catch "error: unmerged entries in the index\n";
            try stderr_file.writeAll(msg);
            try stderr_file.writeAll("fatal: write-tree: not able to write tree\n");
            std.process.exit(128);
        }
    }

    if (prefix) |pfx| {
        // Write subtree for prefix
        const oid = try writeSubtree(allocator, repo.git_dir, &idx, pfx);
        const hex = oid.toHex();
        try stdout_file.writeAll(&hex);
        try stdout_file.writeAll("\n");
    } else {
        // Write full tree
        const oid = tree_builder.buildTree(allocator, repo.git_dir, &idx) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: write-tree: {s}\n", .{@errorName(err)}) catch "fatal: write-tree failed\n";
            try stderr_file.writeAll(msg);
            std.process.exit(128);
        };
        const hex = oid.toHex();
        try stdout_file.writeAll(&hex);
        try stdout_file.writeAll("\n");
    }
}

/// Write a subtree for entries matching a given prefix.
fn writeSubtree(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    idx: *const index_mod.Index,
    prefix: []const u8,
) !types.ObjectId {
    // Filter entries that start with prefix
    var filtered_entries = std.array_list.Managed(index_mod.IndexEntry).init(allocator);
    defer filtered_entries.deinit();

    // Ensure prefix ends with /
    var pfx_buf: [4096]u8 = undefined;
    var pfx_len = prefix.len;
    @memcpy(pfx_buf[0..prefix.len], prefix);
    if (prefix.len > 0 and prefix[prefix.len - 1] != '/') {
        pfx_buf[pfx_len] = '/';
        pfx_len += 1;
    }
    const normalized_prefix = pfx_buf[0..pfx_len];

    for (idx.entries.items) |entry| {
        if (std.mem.startsWith(u8, entry.name, normalized_prefix)) {
            // Create a new entry with the prefix stripped from the name
            var new_entry = entry;
            new_entry.name = entry.name[normalized_prefix.len..];
            new_entry.owned = false;
            try filtered_entries.append(new_entry);
        }
    }

    if (filtered_entries.items.len == 0) {
        try stderr_file.writeAll("fatal: write-tree: prefix does not match any files\n");
        std.process.exit(128);
    }

    // Build a temporary index from filtered entries
    var sub_idx = index_mod.Index.init(allocator);
    defer sub_idx.deinit();
    for (filtered_entries.items) |entry| {
        try sub_idx.entries.append(entry);
    }

    return tree_builder.buildTree(allocator, git_dir, &sub_idx);
}
