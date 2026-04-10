const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const config_mod = @import("config.zig");
const ref_mod = @import("ref.zig");
const fetch_mod = @import("fetch.zig");
const merge_mod = @import("merge.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Options for the pull command.
pub const PullOptions = struct {
    remote: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    rebase: bool = false,
    ff_only: bool = false,
};

/// Run the "pull" command.
pub fn runPull(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = PullOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--rebase")) {
            opts.rebase = true;
        } else if (std.mem.eql(u8, arg, "--ff-only")) {
            opts.ff_only = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (opts.remote == null) {
                opts.remote = arg;
            } else if (opts.branch == null) {
                opts.branch = arg;
            }
        }
    }

    // Use static buffers for remote and branch names so they outlive all operations
    var remote_buf: [256]u8 = undefined;
    var branch_buf: [256]u8 = undefined;
    var remote_len: usize = 0;
    var branch_len: usize = 0;

    // Resolve tracking information
    if (opts.remote != null and opts.branch != null) {
        // Both explicitly provided
        @memcpy(remote_buf[0..opts.remote.?.len], opts.remote.?);
        remote_len = opts.remote.?.len;
        @memcpy(branch_buf[0..opts.branch.?.len], opts.branch.?);
        branch_len = opts.branch.?.len;
    } else {
        // Need to figure out from config
        const resolved = resolveFromConfig(allocator, repo.git_dir, opts, &remote_buf, &remote_len, &branch_buf, &branch_len);
        if (!resolved) {
            try stderr_file.writeAll(
                \\There is no tracking information for the current branch.
                \\Please specify which branch you want to merge with.
                \\
                \\    zig-git pull <remote> <branch>
                \\
                \\If you wish to set tracking information for this branch you can do so with:
                \\
                \\    zig-git branch --set-upstream-to=<remote>/<branch>
                \\
            );
            std.process.exit(1);
        }
    }

    const remote_name = remote_buf[0..remote_len];
    const branch_name = branch_buf[0..branch_len];

    // Step 1: Fetch
    fetch_mod.fetch(allocator, repo.git_dir, remote_name) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: fetch from '{s}' failed: {s}\n", .{ remote_name, @errorName(err) }) catch
            "fatal: fetch failed\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    // Step 2: Determine the remote tracking ref
    var tracking_ref_buf: [512]u8 = undefined;
    const tracking_ref = buildTrackingRef(&tracking_ref_buf, remote_name, branch_name);

    // Try to resolve the tracking ref
    const remote_oid = ref_mod.readRef(allocator, repo.git_dir, tracking_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: couldn't find remote ref {s}\n", .{branch_name}) catch
            "fatal: couldn't find remote ref\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    // Resolve HEAD
    const head_oid = repo.resolveRef(allocator, "HEAD") catch {
        // No commits yet -- just set HEAD to the remote tracking ref
        try setHeadToRemote(allocator, repo.git_dir, remote_oid);
        try stdout_file.writeAll("Fast-forward (no commits yet)\n");
        return;
    };

    // Already up to date?
    if (head_oid.eql(&remote_oid)) {
        try stdout_file.writeAll("Already up to date.\n");
        return;
    }

    // Step 3: Merge or rebase
    if (opts.rebase) {
        if (try isAncestorOf(allocator, repo, &head_oid, &remote_oid)) {
            var merge_args = [_][]const u8{tracking_ref};
            try merge_mod.runMerge(repo, allocator, &merge_args);
        } else {
            try stderr_file.writeAll("fatal: Cannot rebase: you have unstaged changes.\n");
            try stderr_file.writeAll("hint: use 'zig-git pull --rebase' only when fast-forward is possible,\n");
            try stderr_file.writeAll("hint: or commit your changes first.\n");
            std.process.exit(1);
        }
    } else if (opts.ff_only) {
        if (try isAncestorOf(allocator, repo, &head_oid, &remote_oid)) {
            var merge_args = [_][]const u8{tracking_ref};
            try merge_mod.runMerge(repo, allocator, &merge_args);
        } else {
            try stderr_file.writeAll("fatal: Not possible to fast-forward, aborting.\n");
            std.process.exit(128);
        }
    } else {
        var merge_args = [_][]const u8{tracking_ref};
        try merge_mod.runMerge(repo, allocator, &merge_args);
    }
}

/// Resolve tracking information from config.
/// Copies remote and branch names into the provided buffers.
/// Returns false if no tracking info can be determined.
fn resolveFromConfig(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    opts: PullOptions,
    remote_buf: []u8,
    remote_len: *usize,
    branch_buf_out: []u8,
    branch_len: *usize,
) bool {
    // Get current branch name
    const head_ref_opt = ref_mod.readHead(allocator, git_dir) catch {
        // Error reading HEAD
        if (opts.remote) |r| {
            @memcpy(remote_buf[0..r.len], r);
            remote_len.* = r.len;
            const br = opts.branch orelse "main";
            @memcpy(branch_buf_out[0..br.len], br);
            branch_len.* = br.len;
            return true;
        }
        return false;
    };

    const head_ref = head_ref_opt orelse {
        // Detached HEAD
        if (opts.remote) |r| {
            @memcpy(remote_buf[0..r.len], r);
            remote_len.* = r.len;
            const br = opts.branch orelse "main";
            @memcpy(branch_buf_out[0..br.len], br);
            branch_len.* = br.len;
            return true;
        }
        return false;
    };
    defer allocator.free(head_ref);

    const current_branch = if (std.mem.startsWith(u8, head_ref, "refs/heads/"))
        head_ref["refs/heads/".len..]
    else
        head_ref;

    // Load config to check branch tracking info
    var config_path_buf: [4096]u8 = undefined;
    const config_path = buildPath(&config_path_buf, git_dir, "/config");

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch {
        // Can't load config, use defaults
        const r = if (opts.remote) |rm| rm else "origin";
        @memcpy(remote_buf[0..r.len], r);
        remote_len.* = r.len;
        const br = if (opts.branch) |b| b else current_branch;
        @memcpy(branch_buf_out[0..br.len], br);
        branch_len.* = br.len;
        return true;
    };
    defer cfg.deinit();

    // Look up branch.<name>.remote and branch.<name>.merge
    var remote_key_buf: [256]u8 = undefined;
    const remote_key = buildCompoundKey(&remote_key_buf, "branch.", current_branch, ".remote");

    var merge_key_buf: [256]u8 = undefined;
    const merge_key = buildCompoundKey(&merge_key_buf, "branch.", current_branch, ".merge");

    const cfg_remote = if (opts.remote) |r| r else (cfg.get(remote_key) orelse "origin");
    @memcpy(remote_buf[0..cfg_remote.len], cfg_remote);
    remote_len.* = cfg_remote.len;

    if (opts.branch) |b| {
        @memcpy(branch_buf_out[0..b.len], b);
        branch_len.* = b.len;
    } else {
        const merge_ref = cfg.get(merge_key) orelse current_branch;
        // Strip refs/heads/ prefix if present
        const actual_branch = if (std.mem.startsWith(u8, merge_ref, "refs/heads/"))
            merge_ref["refs/heads/".len..]
        else
            merge_ref;
        @memcpy(branch_buf_out[0..actual_branch.len], actual_branch);
        branch_len.* = actual_branch.len;
    }

    return true;
}

/// Check if ancestor_oid is an ancestor of descendant_oid (i.e. fast-forward is possible).
fn isAncestorOf(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    ancestor_oid: *const types.ObjectId,
    descendant_oid: *const types.ObjectId,
) !bool {
    if (ancestor_oid.eql(descendant_oid)) return true;

    const OidKey = [types.OID_RAW_LEN]u8;
    var visited = std.AutoHashMap(OidKey, void).init(allocator);
    defer visited.deinit();

    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();

    try queue.append(descendant_oid.*);
    try visited.put(descendant_oid.bytes, {});

    const max_iterations: usize = 10000;
    var iteration: usize = 0;

    while (queue.items.len > 0 and iteration < max_iterations) {
        iteration += 1;
        const current = queue.orderedRemove(0);

        var obj = repo.readObject(allocator, &current) catch continue;
        defer obj.deinit();

        if (obj.obj_type != .commit) continue;

        // Parse parents from commit data
        var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "parent ")) {
                if (line.len >= "parent ".len + types.OID_HEX_LEN) {
                    const parent_oid = types.ObjectId.fromHex(line["parent ".len..][0..types.OID_HEX_LEN]) catch continue;
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

/// Set HEAD to a specific OID when there are no commits yet.
fn setHeadToRemote(allocator: std.mem.Allocator, git_dir: []const u8, oid: types.ObjectId) !void {
    const head_ref_opt = ref_mod.readHead(allocator, git_dir) catch {
        // Write directly to HEAD
        try writeOidToHead(git_dir, oid);
        return;
    };
    const head_ref = head_ref_opt orelse {
        // Detached HEAD -- write directly
        try writeOidToHead(git_dir, oid);
        return;
    };
    defer allocator.free(head_ref);

    // Update the branch ref
    try ref_mod.createRef(allocator, git_dir, head_ref, oid, null);
}

fn writeOidToHead(git_dir: []const u8, oid: types.ObjectId) !void {
    var path_buf: [4096]u8 = undefined;
    const head_path = buildPath(&path_buf, git_dir, "/HEAD");
    const hex = oid.toHex();
    var content_buf: [types.OID_HEX_LEN + 1]u8 = undefined;
    @memcpy(content_buf[0..types.OID_HEX_LEN], &hex);
    content_buf[types.OID_HEX_LEN] = '\n';
    const file = try std.fs.createFileAbsolute(head_path, .{});
    defer file.close();
    try file.writeAll(&content_buf);
}

fn buildTrackingRef(buf: []u8, remote: []const u8, branch: []const u8) []const u8 {
    const prefix = "refs/remotes/";
    var pos: usize = 0;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos..][0..remote.len], remote);
    pos += remote.len;
    buf[pos] = '/';
    pos += 1;
    @memcpy(buf[pos..][0..branch.len], branch);
    pos += branch.len;
    return buf[0..pos];
}

fn buildPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn buildCompoundKey(buf: []u8, prefix: []const u8, name: []const u8, suffix: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    return buf[0..pos];
}
