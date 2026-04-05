const std = @import("std");
const types = @import("types.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");
const repository = @import("repository.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

pub fn runBranch(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var delete_name: ?[]const u8 = null;
    var create_name: ?[]const u8 = null;
    var start_point: ?[]const u8 = null;
    var verbose = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delete")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("fatal: branch name required\n");
                std.process.exit(1);
            }
            delete_name = args[i];
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (create_name == null) {
                create_name = arg;
            } else if (start_point == null) {
                start_point = arg;
            }
        }
    }

    if (delete_name) |name| {
        try deleteBranch(repo, allocator, name);
        return;
    }

    if (create_name) |name| {
        try createBranch(repo, allocator, name, start_point);
        return;
    }

    // List branches
    try listBranches(repo, allocator, verbose);
}

fn listBranches(repo: *repository.Repository, allocator: std.mem.Allocator, verbose: bool) !void {
    // Get current branch from HEAD
    const head_ref = ref_mod.readHead(allocator, repo.git_dir) catch null;
    defer if (head_ref) |h| allocator.free(h);

    const current_branch: ?[]const u8 = if (head_ref) |h| blk: {
        const prefix = "refs/heads/";
        if (std.mem.startsWith(u8, h, prefix)) {
            break :blk h[prefix.len..];
        }
        break :blk null;
    } else null;

    const entries = try ref_mod.listRefs(allocator, repo.git_dir, "refs/heads/");
    defer ref_mod.freeRefEntries(allocator, entries);

    if (entries.len == 0) {
        // No branches yet - show what HEAD points to if it's a symref
        if (current_branch) |cb| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "* {s}\n", .{cb}) catch return;
            try stdout_file.writeAll(msg);
        }
        return;
    }

    for (entries) |entry| {
        const prefix_str = "refs/heads/";
        const branch_name = if (std.mem.startsWith(u8, entry.name, prefix_str))
            entry.name[prefix_str.len..]
        else
            entry.name;

        const is_current = if (current_branch) |cb|
            std.mem.eql(u8, branch_name, cb)
        else
            false;

        if (verbose) {
            const hex = entry.oid.toHex();
            const short_sha = hex[0..7];

            // Try to get the commit subject
            var subject: []const u8 = "";
            var subject_buf_alloc: ?[]u8 = null;
            defer if (subject_buf_alloc) |sb| allocator.free(sb);

            if (repo.readObject(allocator, &entry.oid)) |obj_val| {
                var obj = obj_val;
                defer obj.deinit();
                if (obj.obj_type == .commit) {
                    subject = extractCommitSubject(obj.data);
                    // We need to copy because obj.data will be freed
                    if (subject.len > 0) {
                        const copy = allocator.alloc(u8, subject.len) catch null;
                        if (copy) |c| {
                            @memcpy(c, subject);
                            subject_buf_alloc = c;
                            subject = c;
                        }
                    }
                }
            } else |_| {}

            var line_buf: [512]u8 = undefined;
            if (is_current) {
                const line = std.fmt.bufPrint(&line_buf, "* {s} {s} {s}\n", .{ branch_name, short_sha, subject }) catch continue;
                try stdout_file.writeAll(line);
            } else {
                const line = std.fmt.bufPrint(&line_buf, "  {s} {s} {s}\n", .{ branch_name, short_sha, subject }) catch continue;
                try stdout_file.writeAll(line);
            }
        } else {
            var line_buf: [256]u8 = undefined;
            if (is_current) {
                const line = std.fmt.bufPrint(&line_buf, "* {s}\n", .{branch_name}) catch continue;
                try stdout_file.writeAll(line);
            } else {
                const line = std.fmt.bufPrint(&line_buf, "  {s}\n", .{branch_name}) catch continue;
                try stdout_file.writeAll(line);
            }
        }
    }
}

fn createBranch(repo: *repository.Repository, allocator: std.mem.Allocator, name: []const u8, start_point: ?[]const u8) !void {
    // Resolve the target commit
    const oid = if (start_point) |sp|
        repo.resolveRef(allocator, sp) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: not a valid object name: '{s}'\n", .{sp}) catch
                "fatal: not a valid object name\n";
            try stderr_file.writeAll(msg);
            std.process.exit(128);
        }
    else
        repo.resolveRef(allocator, "HEAD") catch {
            try stderr_file.writeAll("fatal: not a valid object name: 'HEAD'\n");
            std.process.exit(128);
        };

    // Check if branch already exists
    const ref_name_prefix = "refs/heads/";
    var ref_name_buf: [256]u8 = undefined;
    @memcpy(ref_name_buf[0..ref_name_prefix.len], ref_name_prefix);
    @memcpy(ref_name_buf[ref_name_prefix.len..][0..name.len], name);
    const ref_name = ref_name_buf[0 .. ref_name_prefix.len + name.len];

    // Check if it already exists
    if (ref_mod.readRef(allocator, repo.git_dir, ref_name)) |_| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: a branch named '{s}' already exists\n", .{name}) catch
            "fatal: branch already exists\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    } else |_| {}

    // Create the ref
    ref_mod.createRef(allocator, repo.git_dir, ref_name, oid, null) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: cannot create branch '{s}': {s}\n", .{ name, @errorName(err) }) catch
            "fatal: cannot create branch\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    // Append reflog
    reflog_mod.appendReflog(repo.git_dir, ref_name, types.ObjectId.ZERO, oid, "branch: Created from HEAD") catch {};
}

fn deleteBranch(repo: *repository.Repository, allocator: std.mem.Allocator, name: []const u8) !void {
    // Check if trying to delete current branch
    const head_ref = ref_mod.readHead(allocator, repo.git_dir) catch null;
    defer if (head_ref) |h| allocator.free(h);

    const ref_name_prefix = "refs/heads/";
    var ref_name_buf: [256]u8 = undefined;
    @memcpy(ref_name_buf[0..ref_name_prefix.len], ref_name_prefix);
    @memcpy(ref_name_buf[ref_name_prefix.len..][0..name.len], name);
    const ref_name = ref_name_buf[0 .. ref_name_prefix.len + name.len];

    if (head_ref) |h| {
        if (std.mem.eql(u8, h, ref_name)) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: cannot delete branch '{s}' checked out at current HEAD\n", .{name}) catch
                "error: cannot delete current branch\n";
            try stderr_file.writeAll(msg);
            std.process.exit(1);
        }
    }

    // Read the OID before deleting (for the output message)
    const oid = ref_mod.readRef(allocator, repo.git_dir, ref_name) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: branch '{s}' not found\n", .{name}) catch
            "error: branch not found\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    };

    ref_mod.deleteRef(repo.git_dir, ref_name) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: could not delete branch '{s}'\n", .{name}) catch
            "error: could not delete branch\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    };

    const hex = oid.toHex();
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Deleted branch {s} (was {s}).\n", .{ name, hex[0..7] }) catch
        "Deleted branch.\n";
    try stdout_file.writeAll(msg);
}

fn extractCommitSubject(data: []const u8) []const u8 {
    // Find the blank line that separates headers from body
    var i: usize = 0;
    while (i < data.len) {
        if (i + 1 < data.len and data[i] == '\n' and data[i + 1] == '\n') {
            // Found double newline - subject starts after it
            const body_start = i + 2;
            if (body_start >= data.len) return "";
            // Find end of first line
            const end = std.mem.indexOfScalar(u8, data[body_start..], '\n') orelse data.len - body_start;
            return data[body_start .. body_start + end];
        }
        i += 1;
    }
    return "";
}
