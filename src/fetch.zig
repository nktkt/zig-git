const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const config_mod = @import("config.zig");
const remote_mod = @import("remote.zig");
const ref_mod = @import("ref.zig");
const loose = @import("loose.zig");
const object_walk = @import("object_walk.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Fetch from a remote repository.
pub fn fetch(allocator: std.mem.Allocator, git_dir: []const u8, remote_name: []const u8) !void {
    // Read remote URL from config
    const url = try remote_mod.getRemoteUrl(allocator, git_dir, remote_name) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: '{s}' does not appear to be a git repository\n", .{remote_name}) catch
            "fatal: remote not found\n";
        try stderr_file.writeAll(msg);
        return error.RemoteNotFound;
    };
    defer allocator.free(url);

    // Resolve to local path
    const local_path = remote_mod.resolveLocalUrl(url) orelse {
        try stderr_file.writeAll("fatal: only local remotes are supported for fetch\n");
        return error.UnsupportedProtocol;
    };

    // Resolve to absolute path
    var abs_path_buf: [4096]u8 = undefined;
    const abs_path = try resolveAbsolutePath(allocator, local_path, &abs_path_buf);

    // Find source git dir
    var source_git_dir_buf: [4096]u8 = undefined;
    const source_git_dir = findGitDir(abs_path, &source_git_dir_buf) orelse {
        try stderr_file.writeAll("fatal: remote repository not found\n");
        return error.RepositoryNotFound;
    };

    // Print fetching message
    {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "From {s}\n", .{url}) catch "From remote\n";
        try stderr_file.writeAll(msg);
    }

    // List source refs (branches)
    const source_refs = try ref_mod.listRefs(allocator, source_git_dir, "refs/heads/");
    defer ref_mod.freeRefEntries(allocator, source_refs);

    // Open source repository
    var source_repo = repository.Repository.discover(allocator, source_git_dir) catch {
        try stderr_file.writeAll("fatal: cannot open remote repository\n");
        return error.RepositoryNotFound;
    };
    defer source_repo.deinit();

    // Open our repository
    var our_repo = repository.Repository.discover(allocator, git_dir) catch {
        try stderr_file.writeAll("fatal: cannot open local repository\n");
        return error.RepositoryNotFound;
    };
    defer our_repo.deinit();

    // Gather source tip OIDs and our existing remote tracking OIDs
    var source_tips = std.array_list.Managed(types.ObjectId).init(allocator);
    defer source_tips.deinit();

    var our_have = std.array_list.Managed(types.ObjectId).init(allocator);
    defer our_have.deinit();

    for (source_refs) |entry| {
        try source_tips.append(entry.oid);

        // Check what we already have for this remote tracking ref
        if (std.mem.startsWith(u8, entry.name, "refs/heads/")) {
            const branch_name = entry.name["refs/heads/".len..];
            var tracking_ref_buf: [512]u8 = undefined;
            const tracking_ref = buildTrackingRefName(&tracking_ref_buf, remote_name, branch_name);
            if (ref_mod.readRef(allocator, git_dir, tracking_ref)) |oid| {
                try our_have.append(oid);
            } else |_| {}
        }
    }

    // Find missing objects
    var objects_copied: u32 = 0;
    if (source_tips.items.len > 0) {
        const missing = object_walk.findMissingObjects(
            allocator,
            &source_repo,
            &our_repo,
            source_tips.items,
            our_have.items,
        ) catch {
            // Fallback: copy objects ref by ref
            try copyObjectsForRefs(allocator, &source_repo, git_dir, source_refs);
            objects_copied = @intCast(source_refs.len);
            // Update refs and return
            try updateTrackingRefs(allocator, git_dir, remote_name, source_refs);
            return;
        };
        defer allocator.free(missing);

        // Copy each missing object
        for (missing) |oid| {
            var obj = source_repo.readObject(allocator, &oid) catch continue;
            defer obj.deinit();

            _ = loose.writeLooseObject(allocator, git_dir, obj.obj_type, obj.data) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => continue,
            };
            objects_copied += 1;
        }
    }

    // Update remote tracking refs
    var refs_updated: u32 = 0;
    for (source_refs) |entry| {
        if (std.mem.startsWith(u8, entry.name, "refs/heads/")) {
            const branch_name = entry.name["refs/heads/".len..];
            var tracking_ref_buf: [512]u8 = undefined;
            const tracking_ref = buildTrackingRefName(&tracking_ref_buf, remote_name, branch_name);

            // Check if the ref has changed
            const current_oid = ref_mod.readRef(allocator, git_dir, tracking_ref) catch {
                // Ref doesn't exist yet - create it
                ref_mod.createRef(allocator, git_dir, tracking_ref, entry.oid, null) catch continue;
                refs_updated += 1;
                printRefUpdate(remote_name, branch_name, null, &entry.oid);
                continue;
            };

            if (!current_oid.eql(&entry.oid)) {
                ref_mod.createRef(allocator, git_dir, tracking_ref, entry.oid, null) catch continue;
                refs_updated += 1;
                printRefUpdate(remote_name, branch_name, &current_oid, &entry.oid);
            }
        }
    }

    // Also fetch tags
    const source_tags = try ref_mod.listRefs(allocator, source_git_dir, "refs/tags/");
    defer ref_mod.freeRefEntries(allocator, source_tags);

    for (source_tags) |entry| {
        // Copy tag objects if missing
        if (!our_repo.objectExists(&entry.oid)) {
            var obj = source_repo.readObject(allocator, &entry.oid) catch continue;
            defer obj.deinit();
            _ = loose.writeLooseObject(allocator, git_dir, obj.obj_type, obj.data) catch continue;
        }
        // Create tag ref if missing
        ref_mod.createRef(allocator, git_dir, entry.name, entry.oid, null) catch continue;
    }
}

/// Run the fetch command from CLI args.
pub fn runFetch(allocator: std.mem.Allocator, git_dir: []const u8, args: []const []const u8) !void {
    var remote_name: []const u8 = "origin";

    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            remote_name = arg;
            break;
        }
    }

    fetch(allocator, git_dir, remote_name) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: fetch failed: {s}\n", .{@errorName(err)}) catch
            "fatal: fetch failed\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };
}

// --- Internal helpers ---

fn buildTrackingRefName(buf: []u8, remote_name: []const u8, branch_name: []const u8) []const u8 {
    const prefix = "refs/remotes/";
    var pos: usize = 0;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos..][0..remote_name.len], remote_name);
    pos += remote_name.len;
    buf[pos] = '/';
    pos += 1;
    @memcpy(buf[pos..][0..branch_name.len], branch_name);
    pos += branch_name.len;
    return buf[0..pos];
}

fn updateTrackingRefs(allocator: std.mem.Allocator, git_dir: []const u8, remote_name: []const u8, source_refs: []const ref_mod.RefEntry) !void {
    for (source_refs) |entry| {
        if (std.mem.startsWith(u8, entry.name, "refs/heads/")) {
            const branch_name = entry.name["refs/heads/".len..];
            var tracking_ref_buf: [512]u8 = undefined;
            const tracking_ref = buildTrackingRefName(&tracking_ref_buf, remote_name, branch_name);
            ref_mod.createRef(allocator, git_dir, tracking_ref, entry.oid, null) catch continue;
        }
    }
}

/// Fallback: copy objects for each ref by reading them from source.
fn copyObjectsForRefs(allocator: std.mem.Allocator, source_repo: *repository.Repository, target_git_dir: []const u8, refs: []const ref_mod.RefEntry) !void {
    for (refs) |entry| {
        var obj = source_repo.readObject(allocator, &entry.oid) catch continue;
        defer obj.deinit();
        _ = loose.writeLooseObject(allocator, target_git_dir, obj.obj_type, obj.data) catch continue;
    }
}

fn printRefUpdate(remote_name: []const u8, branch_name: []const u8, old_oid: ?*const types.ObjectId, new_oid: *const types.ObjectId) void {
    var buf: [512]u8 = undefined;
    const new_hex = new_oid.toHex();

    if (old_oid) |old| {
        const old_hex = old.toHex();
        const msg = std.fmt.bufPrint(&buf, "   {s}..{s}  {s} -> {s}/{s}\n", .{
            old_hex[0..7],
            new_hex[0..7],
            branch_name,
            remote_name,
            branch_name,
        }) catch return;
        stderr_file.writeAll(msg) catch {};
    } else {
        const msg = std.fmt.bufPrint(&buf, " * [new branch]      {s} -> {s}/{s}\n", .{
            branch_name,
            remote_name,
            branch_name,
        }) catch return;
        stderr_file.writeAll(msg) catch {};
    }
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

    // Bare repo check
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
