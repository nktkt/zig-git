const std = @import("std");
const types = @import("types.zig");
const ref_mod = @import("ref.zig");
const repository = @import("repository.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

pub fn runTag(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var delete_name: ?[]const u8 = null;
    var create_name: ?[]const u8 = null;
    var target: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delete")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("fatal: tag name required\n");
                std.process.exit(1);
            }
            delete_name = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (create_name == null) {
                create_name = arg;
            } else if (target == null) {
                target = arg;
            }
        }
    }

    if (delete_name) |name| {
        try deleteTag(repo, allocator, name);
        return;
    }

    if (create_name) |name| {
        try createTag(repo, allocator, name, target);
        return;
    }

    // List tags
    try listTags(repo, allocator);
}

fn listTags(repo: *repository.Repository, allocator: std.mem.Allocator) !void {
    const entries = try ref_mod.listRefs(allocator, repo.git_dir, "refs/tags/");
    defer ref_mod.freeRefEntries(allocator, entries);

    for (entries) |entry| {
        const prefix_str = "refs/tags/";
        const tag_name = if (std.mem.startsWith(u8, entry.name, prefix_str))
            entry.name[prefix_str.len..]
        else
            entry.name;

        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s}\n", .{tag_name}) catch continue;
        try stdout_file.writeAll(line);
    }
}

fn createTag(repo: *repository.Repository, allocator: std.mem.Allocator, name: []const u8, target_ref: ?[]const u8) !void {
    // Resolve the target commit
    const oid = if (target_ref) |tr|
        repo.resolveRef(allocator, tr) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: not a valid object name: '{s}'\n", .{tr}) catch
                "fatal: not a valid object name\n";
            try stderr_file.writeAll(msg);
            std.process.exit(128);
        }
    else
        repo.resolveRef(allocator, "HEAD") catch {
            try stderr_file.writeAll("fatal: not a valid object name: 'HEAD'\n");
            std.process.exit(128);
        };

    // Build ref name
    const ref_name_prefix = "refs/tags/";
    var ref_name_buf: [512]u8 = undefined;
    if (ref_name_prefix.len + name.len > ref_name_buf.len) {
        try stderr_file.writeAll("fatal: tag name too long\n");
        std.process.exit(128);
    }
    @memcpy(ref_name_buf[0..ref_name_prefix.len], ref_name_prefix);
    @memcpy(ref_name_buf[ref_name_prefix.len..][0..name.len], name);
    const ref_name = ref_name_buf[0 .. ref_name_prefix.len + name.len];

    // Check if tag already exists
    if (ref_mod.readRef(allocator, repo.git_dir, ref_name)) |_| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: tag '{s}' already exists\n", .{name}) catch
            "fatal: tag already exists\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    } else |_| {}

    // Create the ref
    ref_mod.createRef(allocator, repo.git_dir, ref_name, oid, null) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: cannot create tag '{s}': {s}\n", .{ name, @errorName(err) }) catch
            "fatal: cannot create tag\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };
}

fn deleteTag(repo: *repository.Repository, allocator: std.mem.Allocator, name: []const u8) !void {
    const ref_name_prefix = "refs/tags/";
    var ref_name_buf: [512]u8 = undefined;
    if (ref_name_prefix.len + name.len > ref_name_buf.len) {
        try stderr_file.writeAll("error: tag name too long\n");
        std.process.exit(1);
    }
    @memcpy(ref_name_buf[0..ref_name_prefix.len], ref_name_prefix);
    @memcpy(ref_name_buf[ref_name_prefix.len..][0..name.len], name);
    const ref_name = ref_name_buf[0 .. ref_name_prefix.len + name.len];

    // Read the OID before deleting
    const oid = ref_mod.readRef(allocator, repo.git_dir, ref_name) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: tag '{s}' not found\n", .{name}) catch
            "error: tag not found\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    };

    ref_mod.deleteRef(repo.git_dir, ref_name) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: could not delete tag '{s}'\n", .{name}) catch
            "error: could not delete tag\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    };

    const hex = oid.toHex();
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Deleted tag '{s}' (was {s})\n", .{ name, hex[0..7] }) catch
        "Deleted tag.\n";
    try stdout_file.writeAll(msg);
}
