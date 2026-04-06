const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const ref_mod = @import("ref.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

pub fn runSymbolicRef(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var short_format = false;
    var delete_mode = false;
    var quiet = false;
    var ref_name: ?[]const u8 = null;
    var target: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--short")) {
            short_format = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delete")) {
            delete_mode = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (ref_name == null) {
                ref_name = arg;
            } else if (target == null) {
                target = arg;
            }
        }
    }

    if (ref_name == null) {
        try stderr_file.writeAll("usage: zig-git symbolic-ref [--short] [--quiet] [-d] <name> [<ref>]\n");
        std.process.exit(1);
    }

    if (delete_mode) {
        try deleteSymbolicRef(repo, ref_name.?, quiet);
        return;
    }

    if (target) |tgt| {
        // Set symbolic ref
        try setSymbolicRef(repo, allocator, ref_name.?, tgt);
    } else {
        // Show symbolic ref
        try showSymbolicRef(repo, allocator, ref_name.?, short_format, quiet);
    }
}

fn showSymbolicRef(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    name: []const u8,
    short_format: bool,
    quiet: bool,
) !void {
    // Read the ref file
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..repo.git_dir.len], repo.git_dir);
    pos += repo.git_dir.len;
    path_buf[pos] = '/';
    pos += 1;
    @memcpy(path_buf[pos..][0..name.len], name);
    pos += name.len;
    const ref_path = path_buf[0..pos];

    const content = readFileContents(allocator, ref_path) catch {
        if (!quiet) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: ref {s} is not a symbolic ref\n", .{name}) catch "fatal: not a symbolic ref\n";
            try stderr_file.writeAll(msg);
        }
        std.process.exit(1);
    };
    defer allocator.free(content);

    const trimmed = std.mem.trimRight(u8, content, "\n\r ");

    if (!std.mem.startsWith(u8, trimmed, "ref: ")) {
        if (!quiet) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: ref {s} is not a symbolic ref\n", .{name}) catch "fatal: not a symbolic ref\n";
            try stderr_file.writeAll(msg);
        }
        std.process.exit(1);
    }

    const sym_target = trimmed[5..];

    if (short_format) {
        const short_name = shortenRefName(sym_target);
        try stdout_file.writeAll(short_name);
        try stdout_file.writeAll("\n");
    } else {
        try stdout_file.writeAll(sym_target);
        try stdout_file.writeAll("\n");
    }
}

fn setSymbolicRef(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    name: []const u8,
    target_ref: []const u8,
) !void {
    _ = allocator;

    // Validate that target looks like a ref
    if (!std.mem.startsWith(u8, target_ref, "refs/")) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "warning: refusing to point HEAD outside of refs/: {s}\n", .{target_ref}) catch "warning: invalid ref target\n";
        try stderr_file.writeAll(msg);
        // Still proceed (git gives a warning but does it)
    }

    ref_mod.updateSymRef(repo.git_dir, name, target_ref) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: cannot update symbolic ref {s}: {s}\n", .{ name, @errorName(err) }) catch "fatal: cannot update symbolic ref\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };
}

fn deleteSymbolicRef(
    repo: *repository.Repository,
    name: []const u8,
    quiet: bool,
) !void {
    // First verify it IS a symbolic ref
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..repo.git_dir.len], repo.git_dir);
    pos += repo.git_dir.len;
    path_buf[pos] = '/';
    pos += 1;
    @memcpy(path_buf[pos..][0..name.len], name);
    pos += name.len;
    const ref_path = path_buf[0..pos];

    // Check if it's a symbolic ref
    const gpa = std.heap.page_allocator;
    const content = readFileContents(gpa, ref_path) catch {
        if (!quiet) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: Cannot delete {s}, not a symbolic ref\n", .{name}) catch "fatal: Cannot delete, not a symbolic ref\n";
            try stderr_file.writeAll(msg);
        }
        std.process.exit(1);
    };
    defer gpa.free(content);

    const trimmed = std.mem.trimRight(u8, content, "\n\r ");
    if (!std.mem.startsWith(u8, trimmed, "ref: ")) {
        if (!quiet) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: Cannot delete {s}, not a symbolic ref\n", .{name}) catch "fatal: Cannot delete, not a symbolic ref\n";
            try stderr_file.writeAll(msg);
        }
        std.process.exit(1);
    }

    // Delete the file
    std.fs.deleteFileAbsolute(ref_path) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: Cannot delete {s}: {s}\n", .{ name, @errorName(err) }) catch "fatal: Cannot delete symbolic ref\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };
}

fn shortenRefName(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "refs/heads/")) {
        return name["refs/heads/".len..];
    } else if (std.mem.startsWith(u8, name, "refs/tags/")) {
        return name["refs/tags/".len..];
    } else if (std.mem.startsWith(u8, name, "refs/remotes/")) {
        return name["refs/remotes/".len..];
    }
    return name;
}

fn readFileContents(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.size > 1024 * 1024) return error.FileTooLarge;
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
