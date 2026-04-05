const std = @import("std");
const repository = @import("repository.zig");
const cat_file = @import("cat_file.zig");
const hash_mod = @import("hash.zig");
const types = @import("types.zig");
const loose = @import("loose.zig");

comptime {
    _ = @import("hash.zig");
    _ = @import("types.zig");
    _ = @import("delta.zig");
    _ = @import("compress.zig");
    _ = @import("loose.zig");
    _ = @import("pack_index.zig");
    _ = @import("pack.zig");
    _ = @import("pack_bitmap.zig");
    _ = @import("commit_graph.zig");
    _ = @import("repository.zig");
    _ = @import("cat_file.zig");
}

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const usage =
    \\usage: zig-git <command> [<args>]
    \\
    \\Commands:
    \\  cat-file     Provide content or type and size information for repository objects
    \\  hash-object  Compute object ID and optionally creates a blob from a file
    \\  version      Display version information
    \\
;

const cat_file_usage =
    \\usage: zig-git cat-file (-t | -s | -p | -e) <object>
    \\
    \\  -p    Pretty-print the contents of <object>
    \\  -t    Show the object type
    \\  -s    Show the object size
    \\  -e    Check if <object> exists (exit code only)
    \\
;

const hash_object_usage =
    \\usage: zig-git hash-object [-t <type>] [-w] <file>
    \\
    \\  -t <type>   Object type (default: blob)
    \\  -w          Write the object into the object database
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try stderr_file.writeAll(usage);
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        try stdout_file.writeAll("zig-git version 0.1.0\n");
        return;
    }

    if (std.mem.eql(u8, command, "cat-file")) {
        return runCatFile(allocator, args[2..]);
    }

    if (std.mem.eql(u8, command, "hash-object")) {
        return runHashObject(allocator, args[2..]);
    }

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zig-git: '{s}' is not a zig-git command.\n\n", .{command}) catch {
        try stderr_file.writeAll("zig-git: unknown command\n");
        std.process.exit(1);
    };
    try stderr_file.writeAll(msg);
    try stderr_file.writeAll(usage);
    std.process.exit(1);
}

fn runCatFile(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        try stderr_file.writeAll(cat_file_usage);
        std.process.exit(1);
    }

    var mode: cat_file.Mode = .pretty;
    var object_ref: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-p")) {
            mode = .pretty;
        } else if (std.mem.eql(u8, arg, "-t")) {
            mode = .type_only;
        } else if (std.mem.eql(u8, arg, "-s")) {
            mode = .size_only;
        } else if (std.mem.eql(u8, arg, "-e")) {
            mode = .exists;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            object_ref = arg;
        }
    }

    if (object_ref == null) {
        try stderr_file.writeAll(cat_file_usage);
        std.process.exit(1);
    }

    var repo = repository.Repository.discover(allocator, null) catch {
        try stderr_file.writeAll("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer repo.deinit();

    cat_file.catFile(&repo, allocator, object_ref.?, mode, stdout_file) catch |err| {
        switch (err) {
            error.ObjectNotFound => {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: Not a valid object name {s}\n", .{object_ref.?}) catch "fatal: Not a valid object name\n";
                try stderr_file.writeAll(msg);
                std.process.exit(128);
            },
            error.AmbiguousObjectName => {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: ambiguous argument '{s}'\n", .{object_ref.?}) catch "fatal: ambiguous argument\n";
                try stderr_file.writeAll(msg);
                std.process.exit(128);
            },
            else => return err,
        }
    };
}

fn runHashObject(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var obj_type: types.ObjectType = .blob;
    var write_object = false;
    var file_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll(hash_object_usage);
                std.process.exit(1);
            }
            obj_type = types.ObjectType.fromString(args[i]) catch {
                try stderr_file.writeAll("fatal: invalid object type\n");
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-w")) {
            write_object = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            file_path = arg;
        }
    }

    if (file_path == null) {
        try stderr_file.writeAll(hash_object_usage);
        std.process.exit(1);
    }

    const file = std.fs.cwd().openFile(file_path.?, .{}) catch {
        try stderr_file.writeAll("fatal: could not open file\n");
        std.process.exit(128);
    };
    defer file.close();

    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);
    const n = try file.readAll(content);
    const data = content[0..n];

    // Compute hash
    var header_buf: [64]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    try hwriter.writeAll(obj_type.toString());
    try hwriter.writeByte(' ');
    try hwriter.print("{d}", .{data.len});
    try hwriter.writeByte(0);
    const header = header_buf[0..hstream.pos];

    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    const digest = hasher.finalResult();
    const oid = types.ObjectId{ .bytes = digest };

    if (write_object) {
        var repo = repository.Repository.discover(allocator, null) catch {
            try stderr_file.writeAll("fatal: not a git repository\n");
            std.process.exit(128);
        };
        defer repo.deinit();

        _ = try loose.writeLooseObject(allocator, repo.git_dir, obj_type, data);
    }

    const hex = oid.toHex();
    try stdout_file.writeAll(&hex);
    try stdout_file.writeAll("\n");
}
