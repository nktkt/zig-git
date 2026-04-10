const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const remote_mod = @import("remote.zig");
const ref_mod = @import("ref.zig");
const loose = @import("loose.zig");
const object_walk = @import("object_walk.zig");
const url_mod = @import("url.zig");
const smart_http = @import("smart_http.zig");
const smart_ssh = @import("smart_ssh.zig");
const transport_mod = @import("transport.zig");
const pack_writer = @import("pack_writer.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Push a branch to a remote repository.
pub fn push(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    remote_name: []const u8,
    branch_name: ?[]const u8,
    force: bool,
) !void {
    // Determine the branch to push
    const branch = if (branch_name) |b| b else blk: {
        const head = try ref_mod.readHead(allocator, git_dir) orelse {
            try stderr_file.writeAll("fatal: HEAD is detached, specify a branch to push\n");
            return error.DetachedHead;
        };
        defer allocator.free(head);
        // Extract branch name from refs/heads/X
        if (std.mem.startsWith(u8, head, "refs/heads/")) {
            const name = head["refs/heads/".len..];
            const result = try allocator.alloc(u8, name.len);
            @memcpy(result, name);
            break :blk result;
        }
        try stderr_file.writeAll("fatal: HEAD is not a branch\n");
        return error.NotABranch;
    };
    // We only need to free if we allocated it (when branch_name was null)
    const branch_allocated = branch_name == null;
    defer if (branch_allocated) allocator.free(branch);

    // Read our branch ref
    var local_ref_buf: [512]u8 = undefined;
    const local_ref = buildRefName(&local_ref_buf, "refs/heads/", branch);
    const local_oid = ref_mod.readRef(allocator, git_dir, local_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: src refspec '{s}' does not match any\n", .{branch}) catch
            "error: src refspec does not match any\n";
        try stderr_file.writeAll(msg);
        return error.RefNotFound;
    };

    // Read remote URL
    const url = try remote_mod.getRemoteUrl(allocator, git_dir, remote_name) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: '{s}' does not appear to be a git repository\n", .{remote_name}) catch
            "fatal: remote not found\n";
        try stderr_file.writeAll(msg);
        return error.RemoteNotFound;
    };
    defer allocator.free(url);

    // Detect URL type and route
    const parsed = url_mod.parse(url) catch {
        try stderr_file.writeAll("fatal: unable to parse remote URL\n");
        return error.InvalidUrl;
    };

    if (parsed.isHttp() or parsed.isSsh()) {
        // Network push not yet fully implemented - report this clearly
        try stderr_file.writeAll("fatal: network push is not yet implemented. Use local push or git.\n");
        return error.UnsupportedProtocol;
    }

    // Local push (original implementation)
    const local_path = remote_mod.resolveLocalUrl(url) orelse {
        try stderr_file.writeAll("fatal: only local remotes are supported for push\n");
        return error.UnsupportedProtocol;
    };

    // Resolve to absolute
    var abs_path_buf: [4096]u8 = undefined;
    const abs_path = try resolveAbsolutePath(allocator, local_path, &abs_path_buf);

    // Find remote git dir
    var remote_git_dir_buf: [4096]u8 = undefined;
    const remote_git_dir = findGitDir(abs_path, &remote_git_dir_buf) orelse {
        try stderr_file.writeAll("fatal: remote repository not found\n");
        return error.RepositoryNotFound;
    };

    // Print push info
    {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "To {s}\n", .{url}) catch "To remote\n";
        try stderr_file.writeAll(msg);
    }

    // Check what the remote has for this branch
    var remote_ref_buf: [512]u8 = undefined;
    const remote_ref = buildRefName(&remote_ref_buf, "refs/heads/", branch);
    const remote_has_ref = ref_mod.readRef(allocator, remote_git_dir, remote_ref);

    // Fast-forward check
    if (remote_has_ref) |remote_oid| {
        if (remote_oid.eql(&local_oid)) {
            try stderr_file.writeAll("Everything up-to-date\n");
            return;
        }

        if (!force) {
            // Check if remote_oid is an ancestor of local_oid
            const is_ff = try isAncestor(allocator, git_dir, &remote_oid, &local_oid);
            if (!is_ff) {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf,
                    \\error: failed to push some refs to '{s}'
                    \\hint: Updates were rejected because the tip of your current branch is behind
                    \\hint: its remote counterpart. Use --force to force the update.
                    \\
                , .{url}) catch "error: non-fast-forward push rejected\n";
                try stderr_file.writeAll(msg);
                return error.NonFastForward;
            }
        }
    } else |_| {}

    // Open both repositories
    var our_repo = repository.Repository.discover(allocator, git_dir) catch {
        try stderr_file.writeAll("fatal: cannot open local repository\n");
        return error.RepositoryNotFound;
    };
    defer our_repo.deinit();

    var remote_repo = repository.Repository.discover(allocator, remote_git_dir) catch {
        try stderr_file.writeAll("fatal: cannot open remote repository\n");
        return error.RepositoryNotFound;
    };
    defer remote_repo.deinit();

    // Find objects to push
    var tips = [_]types.ObjectId{local_oid};
    var exclude_list = std.array_list.Managed(types.ObjectId).init(allocator);
    defer exclude_list.deinit();

    if (remote_has_ref) |remote_oid| {
        try exclude_list.append(remote_oid);
    } else |_| {}

    const missing = object_walk.findMissingObjects(
        allocator,
        &our_repo,
        &remote_repo,
        &tips,
        exclude_list.items,
    ) catch {
        // Fallback: just push the commit object
        var obj = our_repo.readObject(allocator, &local_oid) catch return error.ObjectNotFound;
        defer obj.deinit();
        _ = loose.writeLooseObject(allocator, remote_git_dir, obj.obj_type, obj.data) catch {};
        try updateRemoteRef(allocator, remote_git_dir, git_dir, remote_name, branch, &local_oid);
        return;
    };
    defer allocator.free(missing);

    // Copy missing objects to remote
    var objects_pushed: u32 = 0;
    for (missing) |oid| {
        var obj = our_repo.readObject(allocator, &oid) catch continue;
        defer obj.deinit();

        _ = loose.writeLooseObject(allocator, remote_git_dir, obj.obj_type, obj.data) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => continue,
        };
        objects_pushed += 1;
    }

    // Update the remote's branch ref
    try updateRemoteRef(allocator, remote_git_dir, git_dir, remote_name, branch, &local_oid);

    // Print summary
    if (remote_has_ref) |remote_oid| {
        const old_hex = remote_oid.toHex();
        const new_hex = local_oid.toHex();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "   {s}..{s}  {s} -> {s}\n", .{
            old_hex[0..7],
            new_hex[0..7],
            branch,
            branch,
        }) catch return;
        try stderr_file.writeAll(msg);
    } else |_| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, " * [new branch]      {s} -> {s}\n", .{
            branch,
            branch,
        }) catch return;
        try stderr_file.writeAll(msg);
    }
}

/// Run the push command from CLI args.
pub fn runPush(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8) !void {
    var remote_name: []const u8 = "origin";
    var branch_name: ?[]const u8 = null;
    var force = false;

    var positional: u32 = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            force = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (positional == 0) {
                remote_name = arg;
            } else if (positional == 1) {
                branch_name = arg;
            }
            positional += 1;
        }
    }

    push(allocator, git_dir, remote_name, branch_name, force) catch |err| {
        if (err != error.NonFastForward and err != error.DetachedHead and err != error.NotABranch) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: push failed: {s}\n", .{@errorName(err)}) catch
                "fatal: push failed\n";
            try stderr_file.writeAll(msg);
        }
        std.process.exit(1);
    };
}

// --- Internal helpers ---

fn updateRemoteRef(
    allocator: std.mem.Allocator,
    remote_git_dir: []const u8,
    local_git_dir: []const u8,
    remote_name: []const u8,
    branch: []const u8,
    oid: *const types.ObjectId,
) !void {
    // Update the remote's branch ref
    var ref_buf: [512]u8 = undefined;
    const ref_name = buildRefName(&ref_buf, "refs/heads/", branch);
    try ref_mod.createRef(allocator, remote_git_dir, ref_name, oid.*, null);

    // Update our remote tracking ref
    var tracking_buf: [512]u8 = undefined;
    var pos: usize = 0;
    const prefix = "refs/remotes/";
    @memcpy(tracking_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(tracking_buf[pos..][0..remote_name.len], remote_name);
    pos += remote_name.len;
    tracking_buf[pos] = '/';
    pos += 1;
    @memcpy(tracking_buf[pos..][0..branch.len], branch);
    pos += branch.len;
    const tracking_ref = tracking_buf[0..pos];

    ref_mod.createRef(allocator, local_git_dir, tracking_ref, oid.*, null) catch {};
}

fn buildRefName(buf: []u8, prefix_str: []const u8, name: []const u8) []const u8 {
    @memcpy(buf[0..prefix_str.len], prefix_str);
    @memcpy(buf[prefix_str.len..][0..name.len], name);
    return buf[0 .. prefix_str.len + name.len];
}

/// Check if ancestor_oid is an ancestor of descendant_oid.
/// Uses a simple BFS over commit parents.
fn isAncestor(allocator: std.mem.Allocator, git_dir: []const u8, ancestor_oid: *const types.ObjectId, descendant_oid: *const types.ObjectId) !bool {
    if (ancestor_oid.eql(descendant_oid)) return true;

    var repo = repository.Repository.discover(allocator, git_dir) catch return false;
    defer repo.deinit();

    var visited = std.AutoHashMap([types.OID_RAW_LEN]u8, void).init(allocator);
    defer visited.deinit();

    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();

    try queue.append(descendant_oid.*);
    try visited.put(descendant_oid.bytes, {});

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);

        var obj = repo.readObject(allocator, &current) catch continue;
        defer obj.deinit();

        if (obj.obj_type != .commit) continue;

        // Parse parents
        var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "parent ")) {
                if (line.len >= 7 + types.OID_HEX_LEN) {
                    const parent_oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch continue;
                    if (parent_oid.eql(ancestor_oid)) return true;
                    if (!visited.contains(parent_oid.bytes)) {
                        try visited.put(parent_oid.bytes, {});
                        try queue.append(parent_oid);
                    }
                }
            }
        }
    }

    return false;
}

fn resolveAbsolutePath(allocator: std.mem.Allocator, path: []const u8, buf: []u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        @memcpy(buf[0..path.len], path);
        return buf[0..path.len];
    }
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    @memcpy(buf[0..cwd.len], cwd);
    buf[cwd.len] = '/';
    @memcpy(buf[cwd.len + 1 ..][0..path.len], path);
    return buf[0 .. cwd.len + 1 + path.len];
}

fn findGitDir(path: []const u8, buf: []u8) ?[]const u8 {
    const git_suffix = "/.git";
    if (path.len + git_suffix.len > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    @memcpy(buf[path.len..][0..git_suffix.len], git_suffix);
    const git_path = buf[0 .. path.len + git_suffix.len];
    if (isDirectory(git_path)) return git_path;

    var head_buf: [4096]u8 = undefined;
    @memcpy(head_buf[0..path.len], path);
    @memcpy(head_buf[path.len..][0.."/HEAD".len], "/HEAD");
    const head_path = head_buf[0 .. path.len + "/HEAD".len];
    if (isFile(head_path)) {
        @memcpy(buf[0..path.len], path);
        return buf[0..path.len];
    }

    return null;
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
