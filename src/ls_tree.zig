const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_builder = @import("tree_builder.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

pub const LsTreeOptions = struct {
    recursive: bool = false,
    show_trees: bool = false,
    only_trees: bool = false,
    name_only: bool = false,
    long_format: bool = false,
    abbrev: ?usize = null,
    nul_terminated: bool = false,
    tree_ish: ?[]const u8 = null,
    pathspecs: std.array_list.Managed([]const u8),

    pub fn init(allocator: std.mem.Allocator) LsTreeOptions {
        return .{
            .pathspecs = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *LsTreeOptions) void {
        self.pathspecs.deinit();
    }
};

pub fn runLsTree(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = LsTreeOptions.init(allocator);
    defer opts.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-r")) {
            opts.recursive = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            opts.show_trees = true;
        } else if (std.mem.eql(u8, arg, "-d")) {
            opts.only_trees = true;
        } else if (std.mem.eql(u8, arg, "--name-only") or std.mem.eql(u8, arg, "--name-status")) {
            opts.name_only = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--long")) {
            opts.long_format = true;
        } else if (std.mem.eql(u8, arg, "--abbrev")) {
            opts.abbrev = 7;
        } else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
            const val = arg["--abbrev=".len..];
            opts.abbrev = std.fmt.parseInt(usize, val, 10) catch 7;
        } else if (std.mem.eql(u8, arg, "-z")) {
            opts.nul_terminated = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (opts.tree_ish == null) {
                opts.tree_ish = arg;
            } else {
                try opts.pathspecs.append(arg);
            }
        }
    }

    if (opts.tree_ish == null) {
        try stderr_file.writeAll("fatal: required argument '<tree-ish>' missing\n");
        std.process.exit(128);
    }

    // Resolve tree-ish to an OID
    const oid = repo.resolveRef(allocator, opts.tree_ish.?) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: Not a valid object name {s}\n", .{opts.tree_ish.?}) catch "fatal: Not a valid object name\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    // Read the object; if it's a commit, extract its tree
    var obj = repo.readObject(allocator, &oid) catch {
        try stderr_file.writeAll("fatal: not a tree object\n");
        std.process.exit(128);
    };

    var tree_oid = oid;
    if (obj.obj_type == .commit) {
        // Extract tree OID from commit data
        const tree_line_prefix = "tree ";
        if (std.mem.startsWith(u8, obj.data, tree_line_prefix)) {
            const nl = std.mem.indexOfScalar(u8, obj.data, '\n') orelse {
                obj.deinit();
                try stderr_file.writeAll("fatal: not a tree object\n");
                std.process.exit(128);
            };
            if (nl >= tree_line_prefix.len + types.OID_HEX_LEN) {
                tree_oid = types.ObjectId.fromHex(obj.data[tree_line_prefix.len..][0..types.OID_HEX_LEN]) catch {
                    obj.deinit();
                    try stderr_file.writeAll("fatal: not a tree object\n");
                    std.process.exit(128);
                };
            }
        }
        obj.deinit();
    } else if (obj.obj_type == .tree) {
        obj.deinit();
    } else {
        obj.deinit();
        try stderr_file.writeAll("fatal: not a tree object\n");
        std.process.exit(128);
    }

    try listTree(repo, allocator, &tree_oid, "", &opts);
}

fn listTree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    tree_oid: *const types.ObjectId,
    prefix: []const u8,
    opts: *const LsTreeOptions,
) !void {
    var obj = try repo.readObject(allocator, tree_oid);
    defer obj.deinit();

    if (obj.obj_type != .tree) return error.NotATree;

    const entries = try tree_builder.parseTreeEntries(allocator, obj.data);
    defer allocator.free(entries);

    for (entries) |*entry| {
        // Build full path
        var path_buf: [4096]u8 = undefined;
        var ppos: usize = 0;
        if (prefix.len > 0) {
            @memcpy(path_buf[ppos..][0..prefix.len], prefix);
            ppos += prefix.len;
            path_buf[ppos] = '/';
            ppos += 1;
        }
        @memcpy(path_buf[ppos..][0..entry.name.len], entry.name);
        ppos += entry.name.len;
        const full_path = path_buf[0..ppos];

        // Check pathspec
        if (opts.pathspecs.items.len > 0) {
            if (!matchesTreePathspec(full_path, opts.pathspecs.items)) {
                // If this is a tree and we're recursive, still descend (pathspec might match deeper)
                const is_tree = std.mem.eql(u8, entry.mode, "40000");
                if (is_tree and (opts.recursive or opts.show_trees)) {
                    listTree(repo, allocator, &entry.oid, full_path, opts) catch {};
                }
                continue;
            }
        }

        const is_tree = std.mem.eql(u8, entry.mode, "40000");

        if (opts.only_trees and !is_tree) continue;

        if (is_tree) {
            if (opts.recursive and !opts.only_trees) {
                // When -t is set, show tree entries while recursing
                if (opts.show_trees) {
                    try printTreeEntry(repo, allocator, entry, full_path, opts);
                }
                listTree(repo, allocator, &entry.oid, full_path, opts) catch {};
                continue;
            }
            // Show tree entry
            try printTreeEntry(repo, allocator, entry, full_path, opts);
        } else {
            try printTreeEntry(repo, allocator, entry, full_path, opts);
        }
    }
}

const TreeBuildEntry = @import("tree_builder.zig").TreeBuildEntry;

fn printTreeEntry(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    entry: *const TreeBuildEntry,
    full_path: []const u8,
    opts: *const LsTreeOptions,
) !void {
    _ = allocator;
    const terminator: u8 = if (opts.nul_terminated) 0 else '\n';
    const is_tree = std.mem.eql(u8, entry.mode, "40000");

    if (opts.name_only) {
        try stdout_file.writeAll(full_path);
        var term: [1]u8 = .{terminator};
        try stdout_file.writeAll(&term);
        return;
    }

    // Mode with proper padding for trees
    var mode_buf: [6]u8 = undefined;
    const mode_str = padMode(entry.mode, &mode_buf);

    // Object type
    const obj_type_str: []const u8 = if (is_tree) "tree" else "blob";

    // SHA
    const hex = entry.oid.toHex();
    const sha_len = if (opts.abbrev) |a| @min(a, types.OID_HEX_LEN) else types.OID_HEX_LEN;

    var buf: [512]u8 = undefined;
    if (opts.long_format and !is_tree) {
        // Long format: mode type sha size\tpath
        // Get object size
        const obj_size = getObjectSize(repo, &entry.oid);
        const line = std.fmt.bufPrint(&buf, "{s} {s} {s} {d:>7}\t", .{
            mode_str,
            obj_type_str,
            hex[0..sha_len],
            obj_size,
        }) catch return;
        try stdout_file.writeAll(line);
    } else if (opts.long_format and is_tree) {
        const line = std.fmt.bufPrint(&buf, "{s} {s} {s}       -\t", .{
            mode_str,
            obj_type_str,
            hex[0..sha_len],
        }) catch return;
        try stdout_file.writeAll(line);
    } else {
        const line = std.fmt.bufPrint(&buf, "{s} {s} {s}\t", .{
            mode_str,
            obj_type_str,
            hex[0..sha_len],
        }) catch return;
        try stdout_file.writeAll(line);
    }

    try stdout_file.writeAll(full_path);
    var term: [1]u8 = .{terminator};
    try stdout_file.writeAll(&term);
}

fn padMode(mode: []const u8, buf: *[6]u8) []const u8 {
    if (mode.len >= 6) return mode[0..6];
    // Pad with leading zeros
    const pad = 6 - mode.len;
    @memset(buf[0..pad], '0');
    @memcpy(buf[pad..][0..mode.len], mode);
    return buf[0..6];
}

fn getObjectSize(repo: *repository.Repository, oid: *const types.ObjectId) u64 {
    // Try to read object to get size
    var obj = repo.readObject(repo.allocator, oid) catch return 0;
    defer obj.deinit();
    return obj.data.len;
}

fn matchesTreePathspec(path: []const u8, pathspecs: []const []const u8) bool {
    for (pathspecs) |spec| {
        if (std.mem.startsWith(u8, path, spec)) return true;
        if (std.mem.eql(u8, path, spec)) return true;
        // Spec might be a parent directory of path
        if (spec.len > 0 and std.mem.startsWith(u8, spec, path)) {
            if (spec.len > path.len and spec[path.len] == '/') return true;
        }
    }
    return false;
}
