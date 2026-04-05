const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Run the "rev-parse" command.
pub fn runRevParse(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var short = false;
    var rev_spec: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--short")) {
            short = true;
        } else if (std.mem.eql(u8, arg, "--verify")) {
            // Accept but ignore (we always verify).
        } else if (std.mem.eql(u8, arg, "--git-dir")) {
            // Print git dir and return.
            try stdout_file.writeAll(repo.git_dir);
            try stdout_file.writeAll("\n");
            return;
        } else if (std.mem.eql(u8, arg, "--show-toplevel")) {
            const work_dir = getWorkDir(repo.git_dir);
            try stdout_file.writeAll(work_dir);
            try stdout_file.writeAll("\n");
            return;
        } else if (std.mem.eql(u8, arg, "--is-inside-work-tree")) {
            try stdout_file.writeAll("true\n");
            return;
        } else if (std.mem.eql(u8, arg, "--is-bare-repository")) {
            try stdout_file.writeAll("false\n");
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            rev_spec = arg;
        }
    }

    if (rev_spec == null) {
        try stderr_file.writeAll("fatal: bad revision\n");
        std.process.exit(128);
    }

    const spec = rev_spec.?;

    const oid = resolveRevision(repo, allocator, spec) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = switch (err) {
            error.AmbiguousObjectName => std.fmt.bufPrint(&buf, "fatal: ambiguous argument '{s}'\n", .{spec}) catch "fatal: ambiguous argument\n",
            else => std.fmt.bufPrint(&buf, "fatal: bad revision '{s}'\n", .{spec}) catch "fatal: bad revision\n",
        };
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    const hex = oid.toHex();
    if (short) {
        try stdout_file.writeAll(hex[0..7]);
        try stdout_file.writeAll("\n");
    } else {
        try stdout_file.writeAll(&hex);
        try stdout_file.writeAll("\n");
    }
}

/// Resolve a revision specification string to an ObjectId.
///
/// Supports:
///   - Full 40-char hex SHA
///   - Abbreviated hex SHA (4+ chars)
///   - HEAD, HEAD~N, HEAD^, HEAD^N
///   - Branch names (refs/heads/<name>)
///   - Tag names (refs/tags/<name>)
///   - <rev>^{tree} — dereference to tree
///   - <rev>^{commit} — dereference to commit
///   - @{N} — reflog entry
pub fn resolveRevision(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    spec: []const u8,
) !types.ObjectId {
    // Check for ^{type} suffix: dereference.
    if (std.mem.indexOf(u8, spec, "^{")) |caret_pos| {
        const close = std.mem.indexOfScalarPos(u8, spec, caret_pos, '}') orelse return error.InvalidRevision;
        const base_spec = spec[0..caret_pos];
        const deref_type = spec[caret_pos + 2 .. close];

        const base_oid = try resolveRevision(repo, allocator, base_spec);

        if (std.mem.eql(u8, deref_type, "tree")) {
            return dereferenceToTree(repo, allocator, base_oid);
        } else if (std.mem.eql(u8, deref_type, "commit")) {
            return dereferenceToCommit(repo, allocator, base_oid);
        } else if (deref_type.len == 0) {
            // ^{} means dereference to non-tag object.
            return dereferenceTag(repo, allocator, base_oid);
        }
        return error.InvalidRevision;
    }

    // Check for ~N suffix.
    if (std.mem.indexOfScalar(u8, spec, '~')) |tilde_pos| {
        const base_spec = spec[0..tilde_pos];
        const count_str = spec[tilde_pos + 1 ..];
        const count: usize = if (count_str.len == 0) 1 else std.fmt.parseInt(usize, count_str, 10) catch return error.InvalidRevision;

        var oid = try resolveRevision(repo, allocator, base_spec);

        // Walk back N parents (first parent each time).
        var n: usize = 0;
        while (n < count) : (n += 1) {
            oid = try getCommitParentN(repo, allocator, oid, 0);
        }
        return oid;
    }

    // Check for ^N suffix (parent selection).
    if (std.mem.lastIndexOfScalar(u8, spec, '^')) |caret_pos| {
        // Make sure this isn't ^{ which was handled above.
        if (caret_pos + 1 < spec.len and spec[caret_pos + 1] == '{') {
            // Should have been caught above; fall through.
        } else {
            const base_spec = spec[0..caret_pos];
            const parent_str = spec[caret_pos + 1 ..];
            const parent_num: usize = if (parent_str.len == 0) 1 else std.fmt.parseInt(usize, parent_str, 10) catch return error.InvalidRevision;

            if (parent_num == 0) {
                // ^0 means the commit itself.
                return resolveRevision(repo, allocator, base_spec);
            }

            const base_oid = try resolveRevision(repo, allocator, base_spec);
            return getCommitParentN(repo, allocator, base_oid, parent_num - 1);
        }
    }

    // Check for @{N} reflog syntax.
    if (std.mem.indexOf(u8, spec, "@{")) |at_pos| {
        const close = std.mem.indexOfScalarPos(u8, spec, at_pos, '}') orelse return error.InvalidRevision;
        const ref_name = if (at_pos == 0) "HEAD" else spec[0..at_pos];
        const idx_str = spec[at_pos + 2 .. close];
        const idx = std.fmt.parseInt(usize, idx_str, 10) catch return error.InvalidRevision;

        return resolveReflog(repo, allocator, ref_name, idx);
    }

    // Try "HEAD" or "head".
    if (std.mem.eql(u8, spec, "HEAD") or std.mem.eql(u8, spec, "head")) {
        return resolveHead(repo, allocator);
    }

    // Try as a full 40-char hex OID.
    if (spec.len == types.OID_HEX_LEN) {
        if (types.ObjectId.fromHex(spec)) |oid| {
            if (repo.objectExists(&oid)) return oid;
        } else |_| {}
    }

    // Try as branch name (refs/heads/<name>).
    var buf1: [512]u8 = [_]u8{0} ** 512;
    if (ref_mod.readRef(allocator, repo.git_dir, buildRefPath("refs/heads/", spec, &buf1))) |oid| {
        return oid;
    } else |_| {}

    // Try as tag name (refs/tags/<name>).
    var buf2: [512]u8 = [_]u8{0} ** 512;
    if (ref_mod.readRef(allocator, repo.git_dir, buildRefPath("refs/tags/", spec, &buf2))) |oid| {
        return oid;
    } else |_| {}

    // Try as a full ref path (e.g., refs/remotes/origin/main).
    if (ref_mod.readRef(allocator, repo.git_dir, spec)) |oid| {
        return oid;
    } else |_| {}

    // Try as abbreviated hex OID.
    if (spec.len >= 4 and spec.len < types.OID_HEX_LEN) {
        return repo.resolveRef(allocator, spec);
    }

    return error.ObjectNotFound;
}

/// Resolve HEAD to an OID.
fn resolveHead(repo: *repository.Repository, allocator: std.mem.Allocator) !types.ObjectId {
    // Try reading HEAD via ref.
    if (ref_mod.readHead(allocator, repo.git_dir) catch null) |ref_name| {
        defer allocator.free(ref_name);
        if (ref_mod.readRef(allocator, repo.git_dir, ref_name)) |oid| {
            return oid;
        } else |_| {}
    }

    // Try as direct OID in HEAD.
    var path_buf: [4096]u8 = undefined;
    const head_path = buildPath(&path_buf, repo.git_dir, "/HEAD");

    const content = readFileContents(allocator, head_path) catch return error.ObjectNotFound;
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n\r ");

    if (trimmed.len >= types.OID_HEX_LEN) {
        return types.ObjectId.fromHex(trimmed[0..types.OID_HEX_LEN]) catch error.ObjectNotFound;
    }

    return error.ObjectNotFound;
}

/// Get the Nth parent of a commit (0-indexed).
fn getCommitParentN(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    commit_oid: types.ObjectId,
    n: usize,
) !types.ObjectId {
    var obj = try repo.readObject(allocator, &commit_oid);
    defer obj.deinit();

    if (obj.obj_type != .commit) return error.NotACommit;

    // Parse parent lines.
    var parent_count: usize = 0;
    var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) break; // End of headers.
        if (std.mem.startsWith(u8, line, "parent ")) {
            if (parent_count == n) {
                if (line.len >= "parent ".len + types.OID_HEX_LEN) {
                    return types.ObjectId.fromHex(line["parent ".len..][0..types.OID_HEX_LEN]) catch error.InvalidRevision;
                }
            }
            parent_count += 1;
        }
    }

    return error.ObjectNotFound;
}

/// Dereference a commit OID to its tree OID.
fn dereferenceToTree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    oid: types.ObjectId,
) !types.ObjectId {
    var obj = try repo.readObject(allocator, &oid);
    defer obj.deinit();

    if (obj.obj_type == .tree) return oid;

    if (obj.obj_type == .commit) {
        // Parse tree from commit.
        if (std.mem.startsWith(u8, obj.data, "tree ")) {
            const newline = std.mem.indexOfScalar(u8, obj.data, '\n') orelse return error.InvalidCommit;
            if (newline >= "tree ".len + types.OID_HEX_LEN) {
                return types.ObjectId.fromHex(obj.data["tree ".len..][0..types.OID_HEX_LEN]) catch error.InvalidCommit;
            }
        }
    }

    if (obj.obj_type == .tag) {
        // Dereference tag, then try again.
        const target_oid = try parseTagTarget(obj.data);
        return dereferenceToTree(repo, allocator, target_oid);
    }

    return error.InvalidRevision;
}

/// Dereference to a commit (peel tags).
fn dereferenceToCommit(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    oid: types.ObjectId,
) !types.ObjectId {
    var obj = try repo.readObject(allocator, &oid);
    defer obj.deinit();

    if (obj.obj_type == .commit) return oid;

    if (obj.obj_type == .tag) {
        const target_oid = try parseTagTarget(obj.data);
        return dereferenceToCommit(repo, allocator, target_oid);
    }

    return error.InvalidRevision;
}

/// Dereference a tag object to its target (peel all tags).
fn dereferenceTag(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    oid: types.ObjectId,
) !types.ObjectId {
    var current = oid;
    var depth: usize = 0;
    while (depth < 100) : (depth += 1) {
        var obj = try repo.readObject(allocator, &current);
        defer obj.deinit();

        if (obj.obj_type != .tag) return current;

        current = try parseTagTarget(obj.data);
    }
    return error.InvalidRevision;
}

/// Parse the "object" line from tag data.
fn parseTagTarget(data: []const u8) !types.ObjectId {
    if (std.mem.startsWith(u8, data, "object ")) {
        if (data.len >= "object ".len + types.OID_HEX_LEN) {
            return types.ObjectId.fromHex(data["object ".len..][0..types.OID_HEX_LEN]) catch error.InvalidRevision;
        }
    }
    return error.InvalidRevision;
}

/// Resolve a reflog entry: ref@{N}.
fn resolveReflog(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    ref_name: []const u8,
    index: usize,
) !types.ObjectId {
    // Determine the actual ref path for the reflog.
    var actual_ref: []const u8 = ref_name;
    var owned_ref: ?[]u8 = null;
    defer if (owned_ref) |r| allocator.free(r);

    if (std.mem.eql(u8, ref_name, "HEAD")) {
        actual_ref = "HEAD";
    } else {
        // Try refs/heads/<name>.
        var buf: [512]u8 = undefined;
        const full_ref = buildRefPath("refs/heads/", ref_name, &buf);
        owned_ref = try allocator.alloc(u8, full_ref.len);
        @memcpy(owned_ref.?, full_ref);
        actual_ref = owned_ref.?;
    }

    var result = reflog_mod.readReflog(allocator, repo.git_dir, actual_ref) catch return error.ObjectNotFound;
    defer result.deinit();

    // Reflog entries are stored oldest-first; index 0 = most recent.
    if (result.entries.len == 0) return error.ObjectNotFound;
    if (index >= result.entries.len) return error.ObjectNotFound;

    // index 0 = newest = last entry in the array.
    const entry_idx = result.entries.len - 1 - index;
    return result.entries[entry_idx].new_oid;
}

// ── Utility functions ──────────────────────────────────────────────────────

fn refBuf1() [512]u8 {
    return [_]u8{0} ** 512;
}

fn refBuf2() [512]u8 {
    return [_]u8{0} ** 512;
}

fn buildRefPath(prefix: []const u8, name: []const u8, buf: *[512]u8) []const u8 {
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..name.len], name);
    return buf[0 .. prefix.len + name.len];
}

fn buildPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn getWorkDir(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    if (std.fs.path.dirname(git_dir)) |parent| {
        return parent;
    }
    return git_dir;
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
