const std = @import("std");
const config_mod = @import("config.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Options for `git init`.
pub const InitOptions = struct {
    bare: bool = false,
    initial_branch: []const u8 = "master",
    directory: ?[]const u8 = null,
};

/// Initialize a new git repository.
/// Returns the absolute path to the git directory.
pub fn initRepository(allocator: std.mem.Allocator, opts: InitOptions) ![]u8 {
    // Resolve the target directory
    var target_buf: [4096]u8 = undefined;
    const target_dir: []const u8 = if (opts.directory) |dir| blk: {
        if (std.fs.path.isAbsolute(dir)) {
            break :blk dir;
        } else {
            // Make it absolute relative to cwd
            const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
            defer allocator.free(cwd);
            const len = cwd.len;
            @memcpy(target_buf[0..len], cwd);
            target_buf[len] = '/';
            @memcpy(target_buf[len + 1 ..][0..dir.len], dir);
            break :blk target_buf[0 .. len + 1 + dir.len];
        }
    } else blk: {
        const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd);
        @memcpy(target_buf[0..cwd.len], cwd);
        break :blk target_buf[0..cwd.len];
    };

    // Determine git_dir
    var git_dir_buf: [4096]u8 = undefined;
    const git_dir: []const u8 = if (opts.bare) blk: {
        @memcpy(git_dir_buf[0..target_dir.len], target_dir);
        break :blk git_dir_buf[0..target_dir.len];
    } else blk: {
        @memcpy(git_dir_buf[0..target_dir.len], target_dir);
        const suffix = "/.git";
        @memcpy(git_dir_buf[target_dir.len..][0..suffix.len], suffix);
        break :blk git_dir_buf[0 .. target_dir.len + suffix.len];
    };

    // Check if already initialized by looking for HEAD inside git_dir
    var head_check_buf: [4096]u8 = undefined;
    const head_check_path = concatPath(&head_check_buf, git_dir, "/HEAD");
    if (isFile(head_check_path)) {
        // Already exists - reinitialize message
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Reinitialized existing Git repository in {s}/\n", .{git_dir}) catch
            "Reinitialized existing Git repository\n";
        try stdout_file.writeAll(msg);

        const result = try allocator.alloc(u8, git_dir.len);
        @memcpy(result, git_dir);
        return result;
    }

    // Ensure the target directory exists
    std.fs.makeDirAbsolute(target_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Create directory structure
    try mkdirRecursive(git_dir);
    try mkdirRecursive(concatPath(&target_buf, git_dir, "/objects"));
    try mkdirRecursive(concatPath(&target_buf, git_dir, "/objects/info"));
    try mkdirRecursive(concatPath(&target_buf, git_dir, "/objects/pack"));
    try mkdirRecursive(concatPath(&target_buf, git_dir, "/refs"));
    try mkdirRecursive(concatPath(&target_buf, git_dir, "/refs/heads"));
    try mkdirRecursive(concatPath(&target_buf, git_dir, "/refs/tags"));

    // Write HEAD
    {
        var head_buf: [256]u8 = undefined;
        const head_content = std.fmt.bufPrint(&head_buf, "ref: refs/heads/{s}\n", .{opts.initial_branch}) catch
            "ref: refs/heads/master\n";
        const head_path = concatPath(&target_buf, git_dir, "/HEAD");
        const file = try std.fs.createFileAbsolute(head_path, .{});
        defer file.close();
        try file.writeAll(head_content);
    }

    // Write config
    {
        var cfg = config_mod.Config.init(allocator);
        defer cfg.deinit();

        try cfg.set("core.repositoryformatversion", "0");
        try cfg.set("core.filemode", "true");
        if (opts.bare) {
            try cfg.set("core.bare", "true");
        } else {
            try cfg.set("core.bare", "false");
            try cfg.set("core.logallrefupdates", "true");
        }

        const config_path = concatPath(&target_buf, git_dir, "/config");
        try cfg.writeFile(config_path);
    }

    // Write description
    {
        const desc_path = concatPath(&target_buf, git_dir, "/description");
        const file = try std.fs.createFileAbsolute(desc_path, .{});
        defer file.close();
        try file.writeAll("Unnamed repository; edit this file 'description' to name the repository.\n");
    }

    // Write info/exclude
    {
        try mkdirRecursive(concatPath(&target_buf, git_dir, "/info"));
        const exclude_path = concatPath(&target_buf, git_dir, "/info/exclude");
        const file = try std.fs.createFileAbsolute(exclude_path, .{});
        defer file.close();
        try file.writeAll("# git ls-files --others --exclude-from=.git/info/exclude\n");
        try file.writeAll("# Lines that start with '#' are comments.\n");
    }

    var msg_buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Initialized empty Git repository in {s}/\n", .{git_dir}) catch
        "Initialized empty Git repository\n";
    try stdout_file.writeAll(msg);

    const result = try allocator.alloc(u8, git_dir.len);
    @memcpy(result, git_dir);
    return result;
}

fn concatPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn mkdirRecursive(path: []const u8) !void {
    // Try to create the directory; if parent doesn't exist, create parents first
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            // Parent doesn't exist, create it first
            const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
            try mkdirRecursive(parent);
            std.fs.makeDirAbsolute(path) catch |err2| switch (err2) {
                error.PathAlreadyExists => return,
                else => return err2,
            };
        },
        else => return err,
    };
}

fn isDirectory(path: []const u8) bool {
    const dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    @constCast(&dir).close();
    return true;
}

fn isFile(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    @constCast(&file).close();
    return true;
}
