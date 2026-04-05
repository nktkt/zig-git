const std = @import("std");
const repository = @import("repository.zig");
const cat_file = @import("cat_file.zig");
const hash_mod = @import("hash.zig");
const types = @import("types.zig");
const loose = @import("loose.zig");
const config_mod = @import("config.zig");
const init_mod = @import("init.zig");
const status_mod = @import("status.zig");
const branch_mod = @import("branch.zig");
const tag_mod = @import("tag.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");

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
    _ = @import("config.zig");
    _ = @import("init.zig");
    _ = @import("index.zig");
    _ = @import("ignore.zig");
    _ = @import("status.zig");
    _ = @import("branch.zig");
    _ = @import("tag.zig");
    _ = @import("ref.zig");
    _ = @import("reflog.zig");
}

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const usage =
    \\usage: zig-git <command> [<args>]
    \\
    \\Commands:
    \\  init         Create an empty Git repository
    \\  cat-file     Provide content or type and size information for repository objects
    \\  hash-object  Compute object ID and optionally creates a blob from a file
    \\  config       Get and set repository or global options
    \\  status       Show the working tree status
    \\  branch       List, create, or delete branches
    \\  tag          List, create, or delete tags
    \\  reflog       Show reference logs
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

const init_usage =
    \\usage: zig-git init [--bare] [-b <branch>] [<directory>]
    \\
    \\  --bare         Create a bare repository
    \\  -b <branch>    Use <branch> as initial branch name
    \\
;

const config_usage =
    \\usage: zig-git config [--get] [--set] <key> [<value>]
    \\
    \\  --get          Get the value of a config key
    \\  --list         List all config entries
    \\  <key> <value>  Set the value of a config key
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

    if (std.mem.eql(u8, command, "init")) {
        return runInit(allocator, args[2..]);
    }

    if (std.mem.eql(u8, command, "cat-file")) {
        return runCatFile(allocator, args[2..]);
    }

    if (std.mem.eql(u8, command, "hash-object")) {
        return runHashObject(allocator, args[2..]);
    }

    if (std.mem.eql(u8, command, "config")) {
        return runConfig(allocator, args[2..]);
    }

    if (std.mem.eql(u8, command, "status")) {
        return runStatusCmd(allocator);
    }

    if (std.mem.eql(u8, command, "branch")) {
        return runBranchCmd(allocator, args[2..]);
    }

    if (std.mem.eql(u8, command, "tag")) {
        return runTagCmd(allocator, args[2..]);
    }

    if (std.mem.eql(u8, command, "reflog")) {
        return runReflogCmd(allocator, args[2..]);
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

fn runInit(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = init_mod.InitOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--bare")) {
            opts.bare = true;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--initial-branch")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll(init_usage);
                std.process.exit(1);
            }
            opts.initial_branch = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout_file.writeAll(init_usage);
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            opts.directory = arg;
        } else {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: unknown option '{s}'\n", .{arg}) catch "error: unknown option\n";
            try stderr_file.writeAll(msg);
            try stderr_file.writeAll(init_usage);
            std.process.exit(1);
        }
    }

    const git_dir = init_mod.initRepository(allocator, opts) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: cannot create repository: {s}\n", .{@errorName(err)}) catch
            "fatal: cannot create repository\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };
    allocator.free(git_dir);
}

fn runConfig(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try stderr_file.writeAll(config_usage);
        std.process.exit(1);
    }

    // Find the repo config file
    var repo = repository.Repository.discover(allocator, null) catch {
        try stderr_file.writeAll("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer repo.deinit();

    var config_path_buf: [4096]u8 = undefined;
    @memcpy(config_path_buf[0..repo.git_dir.len], repo.git_dir);
    const suffix = "/config";
    @memcpy(config_path_buf[repo.git_dir.len..][0..suffix.len], suffix);
    const config_path = config_path_buf[0 .. repo.git_dir.len + suffix.len];

    var mode: enum { get, set, list } = .get;
    var key: ?[]const u8 = null;
    var value: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--get")) {
            mode = .get;
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            mode = .list;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout_file.writeAll(config_usage);
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (key == null) {
                key = arg;
            } else if (value == null) {
                value = arg;
                mode = .set;
            }
        }
    }

    switch (mode) {
        .list => {
            var cfg = config_mod.Config.loadFile(allocator, config_path) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: unable to read config file: {s}\n", .{@errorName(err)}) catch
                    "fatal: unable to read config file\n";
                try stderr_file.writeAll(msg);
                std.process.exit(128);
            };
            defer cfg.deinit();

            var buf: [1024]u8 = undefined;
            for (cfg.entries.items) |*entry| {
                if (entry.subsection) |ss| {
                    const line = std.fmt.bufPrint(&buf, "{s}.{s}.{s}={s}\n", .{ entry.section, ss, entry.key, entry.value }) catch continue;
                    try stdout_file.writeAll(line);
                } else {
                    const line = std.fmt.bufPrint(&buf, "{s}.{s}={s}\n", .{ entry.section, entry.key, entry.value }) catch continue;
                    try stdout_file.writeAll(line);
                }
            }
        },
        .get => {
            if (key == null) {
                try stderr_file.writeAll("error: key required\n");
                try stderr_file.writeAll(config_usage);
                std.process.exit(1);
            }

            var cfg = config_mod.Config.loadFile(allocator, config_path) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: unable to read config file: {s}\n", .{@errorName(err)}) catch
                    "fatal: unable to read config file\n";
                try stderr_file.writeAll(msg);
                std.process.exit(128);
            };
            defer cfg.deinit();

            if (cfg.get(key.?)) |val| {
                try stdout_file.writeAll(val);
                try stdout_file.writeAll("\n");
            } else {
                std.process.exit(1);
            }
        },
        .set => {
            if (key == null or value == null) {
                try stderr_file.writeAll(config_usage);
                std.process.exit(1);
            }

            var cfg = config_mod.Config.loadFile(allocator, config_path) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: unable to read config file: {s}\n", .{@errorName(err)}) catch
                    "fatal: unable to read config file\n";
                try stderr_file.writeAll(msg);
                std.process.exit(128);
            };
            defer cfg.deinit();

            cfg.set(key.?, value.?) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: unable to set config: {s}\n", .{@errorName(err)}) catch
                    "fatal: unable to set config\n";
                try stderr_file.writeAll(msg);
                std.process.exit(128);
            };

            cfg.writeFile(config_path) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: unable to write config file: {s}\n", .{@errorName(err)}) catch
                    "fatal: unable to write config file\n";
                try stderr_file.writeAll(msg);
                std.process.exit(128);
            };
        },
    }
}

fn runStatusCmd(allocator: std.mem.Allocator) !void {
    var repo = repository.Repository.discover(allocator, null) catch {
        try stderr_file.writeAll("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer repo.deinit();

    status_mod.runStatus(&repo, allocator, stdout_file, stderr_file) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: status failed: {s}\n", .{@errorName(err)}) catch
            "fatal: status failed\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };
}

fn runBranchCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = repository.Repository.discover(allocator, null) catch {
        try stderr_file.writeAll("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer repo.deinit();

    branch_mod.runBranch(&repo, allocator, args) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: branch failed: {s}\n", .{@errorName(err)}) catch
            "fatal: branch failed\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };
}

fn runTagCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = repository.Repository.discover(allocator, null) catch {
        try stderr_file.writeAll("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer repo.deinit();

    tag_mod.runTag(&repo, allocator, args) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: tag failed: {s}\n", .{@errorName(err)}) catch
            "fatal: tag failed\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };
}

fn runReflogCmd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var repo = repository.Repository.discover(allocator, null) catch {
        try stderr_file.writeAll("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer repo.deinit();

    // Default to showing HEAD reflog
    var ref_name: []const u8 = "HEAD";
    if (args.len > 0 and !std.mem.startsWith(u8, args[0], "-")) {
        ref_name = args[0];
    }

    var result = reflog_mod.readReflog(allocator, repo.git_dir, ref_name) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: reflog for '{s}' not found\n", .{ref_name}) catch
            "fatal: reflog not found\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };
    defer result.deinit();

    const entries = result.entries;

    // Print entries in reverse order (newest first), like git
    var i: usize = entries.len;
    while (i > 0) {
        i -= 1;
        const entry = entries[i];
        const new_hex = entry.new_oid.toHex();
        var line_buf: [1024]u8 = undefined;
        const idx = entries.len - 1 - i;
        const line = std.fmt.bufPrint(&line_buf, "{s} {s}@{{{d}}}: {s}\n", .{
            new_hex[0..7],
            ref_name,
            idx,
            entry.message,
        }) catch continue;
        try stdout_file.writeAll(line);
    }
}
