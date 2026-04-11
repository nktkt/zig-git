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
const pack_index_writer = @import("pack_index_writer.zig");
const hash_mod = @import("hash.zig");

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

    // Detect URL type
    const parsed = url_mod.parse(url) catch {
        try stderr_file.writeAll("fatal: unable to parse remote URL\n");
        return error.InvalidUrl;
    };

    if (parsed.isHttp()) {
        return fetchHttp(allocator, git_dir, url, remote_name);
    }

    if (parsed.isSsh()) {
        return fetchSsh(allocator, git_dir, url, remote_name);
    }

    if (parsed.isLocal()) {
        return fetchLocal(allocator, git_dir, url, remote_name);
    }

    try stderr_file.writeAll("fatal: unsupported protocol for fetch\n");
    return error.UnsupportedProtocol;
}

// -----------------------------------------------------------------------
// HTTP(S) Fetch
// -----------------------------------------------------------------------

fn fetchHttp(allocator: std.mem.Allocator, git_dir: []const u8, url: []const u8, remote_name: []const u8) !void {
    {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "From {s}\n", .{url}) catch "From remote\n";
        try stderr_file.writeAll(msg);
    }

    // Discover remote refs
    var discovery = try smart_http.discoverRefsHttp(allocator, url, "git-upload-pack");
    defer discovery.deinit();

    // Determine what we want (remote refs) vs what we have (local tracking refs)
    var wants = std.array_list.Managed(types.ObjectId).init(allocator);
    defer wants.deinit();

    var haves = std.array_list.Managed(types.ObjectId).init(allocator);
    defer haves.deinit();

    var seen_wants = std.AutoHashMap([types.OID_RAW_LEN]u8, void).init(allocator);
    defer seen_wants.deinit();

    for (discovery.refs) |ref| {
        if (std.mem.eql(u8, ref.name, "HEAD")) continue;

        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            const branch_name = ref.name["refs/heads/".len..];
            var tracking_buf: [512]u8 = undefined;
            const tracking_ref = buildTrackingRefName(&tracking_buf, remote_name, branch_name);

            // Check what we already have
            const current_oid = ref_mod.readRef(allocator, git_dir, tracking_ref) catch {
                // Don't have this ref yet
                if (!seen_wants.contains(ref.oid.bytes)) {
                    try seen_wants.put(ref.oid.bytes, {});
                    try wants.append(ref.oid);
                }
                continue;
            };

            if (!current_oid.eql(&ref.oid)) {
                // Ref has changed
                if (!seen_wants.contains(ref.oid.bytes)) {
                    try seen_wants.put(ref.oid.bytes, {});
                    try wants.append(ref.oid);
                }
                try haves.append(current_oid);
            }
        }

        // Also fetch tags
        if (std.mem.startsWith(u8, ref.name, "refs/tags/")) {
            const current_oid = ref_mod.readRef(allocator, git_dir, ref.name) catch {
                if (!seen_wants.contains(ref.oid.bytes)) {
                    try seen_wants.put(ref.oid.bytes, {});
                    try wants.append(ref.oid);
                }
                continue;
            };
            if (!current_oid.eql(&ref.oid)) {
                if (!seen_wants.contains(ref.oid.bytes)) {
                    try seen_wants.put(ref.oid.bytes, {});
                    try wants.append(ref.oid);
                }
            }
        }
    }

    if (wants.items.len == 0) {
        try stderr_file.writeAll("Already up to date.\n");
        return;
    }

    // Fetch pack
    const pack_data = try smart_http.fetchPackHttp(
        allocator,
        url,
        wants.items,
        haves.items,
        discovery.capabilities_str,
    );
    defer allocator.free(pack_data);

    // Install the pack
    try installPackData(allocator, git_dir, pack_data);

    // Update tracking refs
    for (discovery.refs) |ref| {
        if (std.mem.eql(u8, ref.name, "HEAD")) continue;

        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            const branch_name = ref.name["refs/heads/".len..];
            var tracking_buf: [512]u8 = undefined;
            const tracking_ref = buildTrackingRefName(&tracking_buf, remote_name, branch_name);

            const old_oid = ref_mod.readRef(allocator, git_dir, tracking_ref) catch {
                ref_mod.createRef(allocator, git_dir, tracking_ref, ref.oid, null) catch continue;

                printRefUpdate(remote_name, branch_name, null, &ref.oid);
                continue;
            };

            if (!old_oid.eql(&ref.oid)) {
                ref_mod.createRef(allocator, git_dir, tracking_ref, ref.oid, null) catch continue;

                printRefUpdate(remote_name, branch_name, &old_oid, &ref.oid);
            }
        }

        if (std.mem.startsWith(u8, ref.name, "refs/tags/")) {
            ref_mod.createRef(allocator, git_dir, ref.name, ref.oid, null) catch continue;
        }
    }
}

// -----------------------------------------------------------------------
// SSH Fetch
// -----------------------------------------------------------------------

fn fetchSsh(allocator: std.mem.Allocator, git_dir: []const u8, url: []const u8, remote_name: []const u8) !void {
    {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "From {s}\n", .{url}) catch "From remote\n";
        try stderr_file.writeAll(msg);
    }

    var discovery = try smart_ssh.discoverRefsSsh(allocator, url, "git-upload-pack");
    defer discovery.deinit();

    var wants = std.array_list.Managed(types.ObjectId).init(allocator);
    defer wants.deinit();

    var haves = std.array_list.Managed(types.ObjectId).init(allocator);
    defer haves.deinit();

    var seen_wants = std.AutoHashMap([types.OID_RAW_LEN]u8, void).init(allocator);
    defer seen_wants.deinit();

    for (discovery.refs) |ref| {
        if (std.mem.eql(u8, ref.name, "HEAD")) continue;

        if (std.mem.startsWith(u8, ref.name, "refs/heads/") or
            std.mem.startsWith(u8, ref.name, "refs/tags/"))
        {
            // tracking_buf must outlive the tracking_name slice
            var tracking_buf: [512]u8 = undefined;
            const tracking_name = if (std.mem.startsWith(u8, ref.name, "refs/heads/")) blk: {
                const branch_name = ref.name["refs/heads/".len..];
                break :blk buildTrackingRefName(&tracking_buf, remote_name, branch_name);
            } else ref.name;

            const current_oid = ref_mod.readRef(allocator, git_dir, tracking_name) catch {
                if (!seen_wants.contains(ref.oid.bytes)) {
                    try seen_wants.put(ref.oid.bytes, {});
                    try wants.append(ref.oid);
                }
                continue;
            };

            if (!current_oid.eql(&ref.oid)) {
                if (!seen_wants.contains(ref.oid.bytes)) {
                    try seen_wants.put(ref.oid.bytes, {});
                    try wants.append(ref.oid);
                }
                try haves.append(current_oid);
            }
        }
    }

    if (wants.items.len == 0) {
        try stderr_file.writeAll("Already up to date.\n");
        return;
    }

    const pack_data = try smart_ssh.fetchPackSsh(
        allocator,
        url,
        wants.items,
        haves.items,
        discovery.capabilities_str,
    );
    defer allocator.free(pack_data);

    try installPackData(allocator, git_dir, pack_data);

    // Update refs
    for (discovery.refs) |ref| {
        if (std.mem.eql(u8, ref.name, "HEAD")) continue;

        if (std.mem.startsWith(u8, ref.name, "refs/heads/")) {
            const branch_name = ref.name["refs/heads/".len..];
            var tracking_buf: [512]u8 = undefined;
            const tracking_ref = buildTrackingRefName(&tracking_buf, remote_name, branch_name);

            const old_oid = ref_mod.readRef(allocator, git_dir, tracking_ref) catch {
                ref_mod.createRef(allocator, git_dir, tracking_ref, ref.oid, null) catch continue;
                printRefUpdate(remote_name, branch_name, null, &ref.oid);
                continue;
            };

            if (!old_oid.eql(&ref.oid)) {
                ref_mod.createRef(allocator, git_dir, tracking_ref, ref.oid, null) catch continue;
                printRefUpdate(remote_name, branch_name, &old_oid, &ref.oid);
            }
        }

        if (std.mem.startsWith(u8, ref.name, "refs/tags/")) {
            ref_mod.createRef(allocator, git_dir, ref.name, ref.oid, null) catch continue;
        }
    }
}

// -----------------------------------------------------------------------
// Local Fetch (original implementation)
// -----------------------------------------------------------------------

fn fetchLocal(allocator: std.mem.Allocator, git_dir: []const u8, url: []const u8, remote_name: []const u8) !void {
    const local_path = remote_mod.resolveLocalUrl(url) orelse {
        try stderr_file.writeAll("fatal: not a local path\n");
        return error.UnsupportedProtocol;
    };

    var abs_path_buf: [4096]u8 = undefined;
    const abs_path = try resolveAbsolutePath(allocator, local_path, &abs_path_buf);

    var source_git_dir_buf: [4096]u8 = undefined;
    const source_git_dir = findGitDir(abs_path, &source_git_dir_buf) orelse {
        try stderr_file.writeAll("fatal: remote repository not found\n");
        return error.RepositoryNotFound;
    };

    {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "From {s}\n", .{url}) catch "From remote\n";
        try stderr_file.writeAll(msg);
    }

    const source_refs = try ref_mod.listRefs(allocator, source_git_dir, "refs/heads/");
    defer ref_mod.freeRefEntries(allocator, source_refs);

    var source_repo = repository.Repository.discover(allocator, source_git_dir) catch {
        try stderr_file.writeAll("fatal: cannot open remote repository\n");
        return error.RepositoryNotFound;
    };
    defer source_repo.deinit();

    var our_repo = repository.Repository.discover(allocator, git_dir) catch {
        try stderr_file.writeAll("fatal: cannot open local repository\n");
        return error.RepositoryNotFound;
    };
    defer our_repo.deinit();

    var source_tips = std.array_list.Managed(types.ObjectId).init(allocator);
    defer source_tips.deinit();

    var our_have = std.array_list.Managed(types.ObjectId).init(allocator);
    defer our_have.deinit();

    for (source_refs) |entry| {
        try source_tips.append(entry.oid);

        if (std.mem.startsWith(u8, entry.name, "refs/heads/")) {
            const branch_name = entry.name["refs/heads/".len..];
            var tracking_ref_buf: [512]u8 = undefined;
            const tracking_ref = buildTrackingRefName(&tracking_ref_buf, remote_name, branch_name);
            if (ref_mod.readRef(allocator, git_dir, tracking_ref)) |oid| {
                try our_have.append(oid);
            } else |_| {}
        }
    }

    if (source_tips.items.len > 0) {
        const missing = object_walk.findMissingObjects(
            allocator,
            &source_repo,
            &our_repo,
            source_tips.items,
            our_have.items,
        ) catch {
            try copyObjectsForRefs(allocator, &source_repo, git_dir, source_refs);
            try updateTrackingRefs(allocator, git_dir, remote_name, source_refs);
            return;
        };
        defer allocator.free(missing);

        for (missing) |oid| {
            var obj = source_repo.readObject(allocator, &oid) catch continue;
            defer obj.deinit();

            _ = loose.writeLooseObject(allocator, git_dir, obj.obj_type, obj.data) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => continue,
            };
        }
    }

    for (source_refs) |entry| {
        if (std.mem.startsWith(u8, entry.name, "refs/heads/")) {
            const branch_name = entry.name["refs/heads/".len..];
            var tracking_ref_buf: [512]u8 = undefined;
            const tracking_ref = buildTrackingRefName(&tracking_ref_buf, remote_name, branch_name);

            const current_oid = ref_mod.readRef(allocator, git_dir, tracking_ref) catch {
                ref_mod.createRef(allocator, git_dir, tracking_ref, entry.oid, null) catch continue;

                printRefUpdate(remote_name, branch_name, null, &entry.oid);
                continue;
            };

            if (!current_oid.eql(&entry.oid)) {
                ref_mod.createRef(allocator, git_dir, tracking_ref, entry.oid, null) catch continue;

                printRefUpdate(remote_name, branch_name, &current_oid, &entry.oid);
            }
        }
    }

    const source_tags = try ref_mod.listRefs(allocator, source_git_dir, "refs/tags/");
    defer ref_mod.freeRefEntries(allocator, source_tags);

    for (source_tags) |entry| {
        if (!our_repo.objectExists(&entry.oid)) {
            var obj = source_repo.readObject(allocator, &entry.oid) catch continue;
            defer obj.deinit();
            _ = loose.writeLooseObject(allocator, git_dir, obj.obj_type, obj.data) catch continue;
        }
        ref_mod.createRef(allocator, git_dir, entry.name, entry.oid, null) catch continue;
    }
}

// -----------------------------------------------------------------------
// Shared helpers
// -----------------------------------------------------------------------

/// Install pack data into the repository (same as in clone.zig).
fn installPackData(allocator: std.mem.Allocator, git_dir: []const u8, pack_data: []const u8) !void {
    if (pack_data.len < 12) return error.InvalidPackData;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return error.InvalidPackData;

    var pack_hash: [20]u8 = undefined;
    if (pack_data.len >= 20) {
        @memcpy(&pack_hash, pack_data[pack_data.len - 20 ..][0..20]);
    } else {
        var hasher = hash_mod.Sha1.init(.{});
        hasher.update(pack_data);
        pack_hash = hasher.finalResult();
    }

    var hex_buf: [40]u8 = undefined;
    hash_mod.bytesToHex(&pack_hash, &hex_buf);

    var pack_dir_buf: [4096]u8 = undefined;
    var pdpos: usize = 0;
    @memcpy(pack_dir_buf[pdpos..][0..git_dir.len], git_dir);
    pdpos += git_dir.len;
    const pack_dir_suffix = "/objects/pack";
    @memcpy(pack_dir_buf[pdpos..][0..pack_dir_suffix.len], pack_dir_suffix);
    pdpos += pack_dir_suffix.len;
    const pack_dir = pack_dir_buf[0..pdpos];

    std.fs.makeDirAbsolute(pack_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var pack_path_buf: [4096]u8 = undefined;
    var pppos: usize = 0;
    @memcpy(pack_path_buf[pppos..][0..pack_dir.len], pack_dir);
    pppos += pack_dir.len;
    @memcpy(pack_path_buf[pppos..][0.."/pack-".len], "/pack-");
    pppos += "/pack-".len;
    @memcpy(pack_path_buf[pppos..][0..40], &hex_buf);
    pppos += 40;
    @memcpy(pack_path_buf[pppos..][0..".pack".len], ".pack");
    pppos += ".pack".len;
    const pack_path = pack_path_buf[0..pppos];

    const pack_file = try std.fs.createFileAbsolute(pack_path, .{});
    defer pack_file.close();
    try pack_file.writeAll(pack_data);

    // Index the pack
    pack_index_writer.indexPackFileWithGit(allocator, pack_path) catch {
        var idx_path_buf: [4096]u8 = undefined;
        var ippos: usize = 0;
        @memcpy(idx_path_buf[ippos..][0..pack_dir.len], pack_dir);
        ippos += pack_dir.len;
        @memcpy(idx_path_buf[ippos..][0.."/pack-".len], "/pack-");
        ippos += "/pack-".len;
        @memcpy(idx_path_buf[ippos..][0..40], &hex_buf);
        ippos += 40;
        @memcpy(idx_path_buf[ippos..][0..".idx".len], ".idx");
        ippos += ".idx".len;
        const idx_path = idx_path_buf[0..ippos];

        pack_index_writer.indexPackFile(allocator, pack_path, idx_path) catch |idx_err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "warning: failed to index pack: {s}\n", .{@errorName(idx_err)}) catch
                "warning: failed to index pack\n";
            stderr_file.writeAll(msg) catch {};
        };
    };
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
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

fn isFile(path: []const u8) bool {
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}
