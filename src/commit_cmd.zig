const std = @import("std");
const types = @import("types.zig");
const loose = @import("loose.zig");
const index_mod = @import("index.zig");
const tree_builder = @import("tree_builder.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");
const repository = @import("repository.zig");
const config_mod = @import("config.zig");
const hash_mod = @import("hash.zig");
const editor_mod = @import("editor.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Options parsed from the CLI for the commit command.
pub const CommitOptions = struct {
    message: ?[]const u8 = null,
    all: bool = false, // -a: auto-stage tracked modified files
    amend: bool = false, // --amend
    allow_empty: bool = false, // --allow-empty
    message_file: ?[]const u8 = null, // -F <file>: read message from file
    no_edit: bool = false, // --no-edit: don't open editor (for amend)
};

/// Run the "commit" command.
pub fn runCommit(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    // Parse options.
    var opts = CommitOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("error: switch 'm' requires a value\n");
                std.process.exit(1);
            }
            opts.message = args[i];
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            opts.all = true;
        } else if (std.mem.eql(u8, arg, "--amend")) {
            opts.amend = true;
        } else if (std.mem.eql(u8, arg, "--allow-empty")) {
            opts.allow_empty = true;
        } else if (std.mem.eql(u8, arg, "-am") or std.mem.eql(u8, arg, "-ma")) {
            // Combined -am or -ma: set -a and expect next arg as message.
            opts.all = true;
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("error: switch 'm' requires a value\n");
                std.process.exit(1);
            }
            opts.message = args[i];
        } else if (std.mem.startsWith(u8, arg, "-m")) {
            // -m"message" (no space)
            opts.message = arg[2..];
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("error: switch 'F' requires a value\n");
                std.process.exit(1);
            }
            opts.message_file = args[i];
        } else if (std.mem.eql(u8, arg, "--no-edit")) {
            opts.no_edit = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: unknown option '{s}'\n", .{arg}) catch "error: unknown option\n";
            try stderr_file.writeAll(msg);
            std.process.exit(1);
        }
    }

    // Handle -F: read message from file
    var file_message: ?[]u8 = null;
    defer if (file_message) |fm| allocator.free(fm);

    if (opts.message_file) |msg_file| {
        if (std.mem.eql(u8, msg_file, "-")) {
            // Read from stdin
            const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
            var content = std.array_list.Managed(u8).init(allocator);
            defer content.deinit();
            var read_buf: [4096]u8 = undefined;
            while (true) {
                const n = stdin_file.read(&read_buf) catch break;
                if (n == 0) break;
                try content.appendSlice(read_buf[0..n]);
            }
            file_message = try content.toOwnedSlice();
        } else {
            const f = std.fs.cwd().openFile(msg_file, .{}) catch {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: could not open '{s}'\n", .{msg_file}) catch
                    "fatal: could not open message file\n";
                try stderr_file.writeAll(msg);
                std.process.exit(128);
            };
            defer f.close();
            const stat = try f.stat();
            if (stat.size > 1024 * 1024) {
                try stderr_file.writeAll("fatal: message file too large\n");
                std.process.exit(128);
            }
            file_message = try allocator.alloc(u8, @intCast(stat.size));
            const n = try f.readAll(file_message.?);
            if (n < file_message.?.len) {
                const trimmed = try allocator.alloc(u8, n);
                @memcpy(trimmed, file_message.?[0..n]);
                allocator.free(file_message.?);
                file_message = trimmed;
            }
        }
        opts.message = file_message;
    }

    // Note: if no message and not amend, we'll try the editor later (after we know the branch)

    // Get working directory.
    const work_dir = getWorkDir(repo.git_dir);

    // Load the index.
    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPath(&index_path_buf, repo.git_dir, "/index");

    var idx = try index_mod.Index.readFromFile(allocator, index_path);
    defer idx.deinit();

    // If -a, auto-stage tracked modified files.
    if (opts.all) {
        try autoStageModified(allocator, repo.git_dir, work_dir, &idx);
        // Write the updated index back.
        try idx.writeToFile(index_path);
    }

    // Get the current HEAD commit OID (may be null for initial commit).
    var parent_oid: ?types.ObjectId = null;
    var head_ref_name: ?[]const u8 = null;
    defer if (head_ref_name) |h| allocator.free(h);

    // Read HEAD to determine branch name and parent commit.
    head_ref_name = ref_mod.readHead(allocator, repo.git_dir) catch null;

    if (head_ref_name) |ref_name| {
        parent_oid = ref_mod.readRef(allocator, repo.git_dir, ref_name) catch null;
    } else {
        // Detached HEAD: read the OID directly from HEAD.
        parent_oid = readHeadOid(allocator, repo.git_dir);
    }

    // If --amend, adjust the parent to be the parent of the current HEAD commit.
    var amend_message: ?[]u8 = null;
    defer if (amend_message) |m| allocator.free(m);

    if (opts.amend) {
        if (parent_oid) |current_oid| {
            // Read the current commit to get its parent and message.
            var commit_obj = repo.readObject(allocator, &current_oid) catch {
                try stderr_file.writeAll("fatal: cannot read HEAD commit for amend\n");
                std.process.exit(128);
            };
            defer commit_obj.deinit();

            // Parse the parent from the commit.
            const amended_parent = parseCommitParent(commit_obj.data);
            parent_oid = amended_parent;

            // If no -m was given and --no-edit, reuse the commit message.
            if (opts.message == null) {
                if (opts.no_edit) {
                    amend_message = try parseCommitMessage(allocator, commit_obj.data);
                    opts.message = amend_message.?;
                } else {
                    // Reuse old message as default
                    amend_message = try parseCommitMessage(allocator, commit_obj.data);
                    opts.message = amend_message.?;
                }
            }
        } else {
            try stderr_file.writeAll("fatal: cannot amend: no commits yet\n");
            std.process.exit(128);
        }
    }

    // Check for staged changes (compare tree to parent's tree).
    const tree_oid = try tree_builder.buildTree(allocator, repo.git_dir, &idx);

    if (!opts.allow_empty and !opts.amend) {
        // Compare against parent tree.
        if (parent_oid) |p_oid| {
            const parent_tree_oid = getCommitTreeOid(repo, allocator, &p_oid);
            if (parent_tree_oid) |pt_oid| {
                if (pt_oid.eql(&tree_oid)) {
                    try stderr_file.writeAll("nothing to commit, working tree clean\n");
                    std.process.exit(1);
                }
            }
        }
    }

    // If no message was provided, launch the editor
    var editor_message: ?[]u8 = null;
    defer if (editor_message) |em| allocator.free(em);

    if (opts.message == null) {
        // Get branch name for the template
        const branch_short = getBranchShortName(head_ref_name);

        // Collect changed file names from index
        var changed_files_list = std.array_list.Managed([]const u8).init(allocator);
        defer changed_files_list.deinit();
        for (idx.entries.items) |*entry| {
            try changed_files_list.append(entry.name);
        }

        editor_message = editor_mod.editCommitMessage(
            allocator,
            repo.git_dir,
            null,
            branch_short,
            if (changed_files_list.items.len > 0) changed_files_list.items else null,
        ) catch |err| {
            switch (err) {
                error.CommitAborted => {
                    std.process.exit(1);
                },
                error.FileNotFound => {
                    // Editor not found; fall back to requiring -m
                    try stderr_file.writeAll("error: terminal not available. Use -m to provide a commit message.\n");
                    std.process.exit(1);
                },
                else => return err,
            }
        };
        opts.message = editor_message;
    }

    // Get author/committer info.
    var author_name: []const u8 = undefined;
    var author_email: []const u8 = undefined;
    var env_author_name: ?[]u8 = null;
    var env_author_email: ?[]u8 = null;
    defer if (env_author_name) |n| allocator.free(n);
    defer if (env_author_email) |e| allocator.free(e);

    // Try environment variables first, then git config.
    const env_map = std.process.getEnvMap(allocator) catch null;
    var env_map_val = env_map;
    defer if (env_map_val) |*em| em.deinit();

    const got_env_name = if (env_map_val) |*em| em.get("GIT_AUTHOR_NAME") else null;
    const got_env_email = if (env_map_val) |*em| em.get("GIT_AUTHOR_EMAIL") else null;

    if (got_env_name != null and got_env_email != null) {
        author_name = got_env_name.?;
        author_email = got_env_email.?;
    } else {
        // Try git config.
        var config_path_buf: [4096]u8 = undefined;
        const config_path = buildPath(&config_path_buf, repo.git_dir, "/config");

        var cfg = config_mod.Config.loadFile(allocator, config_path) catch {
            try stderr_file.writeAll("fatal: unable to read config\n");
            std.process.exit(128);
        };
        defer cfg.deinit();

        const cfg_name = cfg.get("user.name");
        const cfg_email = cfg.get("user.email");

        if (cfg_name == null or cfg_email == null) {
            try stderr_file.writeAll(
                \\fatal: unable to auto-detect your identity.
                \\
                \\Please set your name and email:
                \\
                \\    zig-git config user.name "Your Name"
                \\    zig-git config user.email "you@example.com"
                \\
                \\Or set GIT_AUTHOR_NAME and GIT_AUTHOR_EMAIL environment variables.
                \\
            );
            std.process.exit(128);
        }

        env_author_name = try allocator.alloc(u8, cfg_name.?.len);
        @memcpy(env_author_name.?, cfg_name.?);
        env_author_email = try allocator.alloc(u8, cfg_email.?.len);
        @memcpy(env_author_email.?, cfg_email.?);

        author_name = env_author_name.?;
        author_email = env_author_email.?;
    }

    // Build timestamp.
    var ts_buf: [32]u8 = undefined;
    const timestamp = getTimestamp(&ts_buf);

    // Build the commit object content.
    var commit_buf: [65536]u8 = undefined;
    var stream = std.io.fixedBufferStream(&commit_buf);
    const writer = stream.writer();

    // tree
    const tree_hex = tree_oid.toHex();
    try writer.writeAll("tree ");
    try writer.writeAll(&tree_hex);
    try writer.writeByte('\n');

    // parent (if any)
    if (parent_oid) |p_oid| {
        const parent_hex = p_oid.toHex();
        try writer.writeAll("parent ");
        try writer.writeAll(&parent_hex);
        try writer.writeByte('\n');
    }

    // author
    try writer.writeAll("author ");
    try writer.writeAll(author_name);
    try writer.writeAll(" <");
    try writer.writeAll(author_email);
    try writer.writeAll("> ");
    try writer.writeAll(timestamp);
    try writer.writeAll(" +0000\n");

    // committer (same as author for now)
    try writer.writeAll("committer ");
    try writer.writeAll(author_name);
    try writer.writeAll(" <");
    try writer.writeAll(author_email);
    try writer.writeAll("> ");
    try writer.writeAll(timestamp);
    try writer.writeAll(" +0000\n");

    // blank line + message
    try writer.writeByte('\n');
    try writer.writeAll(opts.message.?);
    try writer.writeByte('\n');

    const commit_data = commit_buf[0..stream.pos];

    // Write the commit object.
    const commit_oid = loose.writeLooseObject(allocator, repo.git_dir, .commit, commit_data) catch |err| switch (err) {
        error.PathAlreadyExists => blk: {
            // Compute OID manually.
            break :blk computeCommitOid(commit_data);
        },
        else => return err,
    };

    // Update HEAD (or current branch ref) to point to the new commit.
    const old_oid = parent_oid orelse types.ObjectId.ZERO;

    if (head_ref_name) |ref_name| {
        // Update the branch ref.
        try ref_mod.createRef(allocator, repo.git_dir, ref_name, commit_oid, null);
    } else {
        // Detached HEAD: write OID directly to HEAD.
        try writeHeadOid(repo.git_dir, commit_oid);
    }

    // Append to reflog.
    const reflog_msg = opts.message orelse "commit";
    var reflog_line_buf: [1024]u8 = undefined;
    const reflog_line = blk: {
        const truncated_msg = if (reflog_msg.len > 200) reflog_msg[0..200] else reflog_msg;
        if (opts.amend) {
            break :blk std.fmt.bufPrint(&reflog_line_buf, "commit (amend): {s}", .{truncated_msg}) catch "commit (amend)";
        } else if (parent_oid == null) {
            break :blk std.fmt.bufPrint(&reflog_line_buf, "commit (initial): {s}", .{truncated_msg}) catch "commit (initial)";
        } else {
            break :blk std.fmt.bufPrint(&reflog_line_buf, "commit: {s}", .{truncated_msg}) catch "commit";
        }
    };

    // Write reflog for HEAD.
    reflog_mod.appendReflog(repo.git_dir, "HEAD", old_oid, commit_oid, reflog_line) catch {};

    // Also write reflog for the branch ref.
    if (head_ref_name) |ref_name| {
        reflog_mod.appendReflog(repo.git_dir, ref_name, old_oid, commit_oid, reflog_line) catch {};
    }

    // Print summary.
    const commit_hex = commit_oid.toHex();
    const branch_name = getBranchShortName(head_ref_name);

    var summary_buf: [1024]u8 = undefined;
    const summary_msg = if (opts.message) |m| (if (m.len > 50) m[0..50] else m) else "(no message)";
    if (parent_oid == null and !opts.amend) {
        const summary = std.fmt.bufPrint(&summary_buf, "[{s} (root-commit) {s}] {s}\n", .{
            branch_name,
            commit_hex[0..7],
            summary_msg,
        }) catch "commit created\n";
        try stdout_file.writeAll(summary);
    } else {
        const summary = std.fmt.bufPrint(&summary_buf, "[{s} {s}] {s}\n", .{
            branch_name,
            commit_hex[0..7],
            summary_msg,
        }) catch "commit created\n";
        try stdout_file.writeAll(summary);
    }
}

/// Auto-stage tracked modified files (for -a flag).
fn autoStageModified(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    work_dir: []const u8,
    idx: *index_mod.Index,
) !void {
    // For each entry in the index, check if the file has changed.
    // If so, re-hash and update the entry.
    var i: usize = 0;
    while (i < idx.entries.items.len) {
        const entry = &idx.entries.items[i];

        var path_buf: [4096]u8 = undefined;
        const full_path = buildPath2(&path_buf, work_dir, "/", entry.name);

        const file = std.fs.openFileAbsolute(full_path, .{}) catch {
            // File deleted: remove from index.
            if (entry.owned) {
                allocator.free(entry.name);
            }
            _ = idx.entries.orderedRemove(i);
            // Don't increment i.
            continue;
        };
        defer file.close();

        const stat = file.stat() catch {
            i += 1;
            continue;
        };

        // Quick size check.
        const current_size: u32 = @intCast(stat.size);
        const mtime_s: u32 = if (stat.mtime >= 0) @intCast(@as(u64, @intCast(@divFloor(stat.mtime, 1_000_000_000)))) else 0;
        const mtime_ns: u32 = if (stat.mtime >= 0) @intCast(@as(u64, @intCast(@mod(stat.mtime, 1_000_000_000)))) else 0;

        if (current_size == entry.file_size and
            mtime_s == entry.mtime_s and
            mtime_ns == entry.mtime_ns)
        {
            // Likely unchanged.
            i += 1;
            continue;
        }

        // Read and hash.
        const content = allocator.alloc(u8, @intCast(stat.size)) catch {
            i += 1;
            continue;
        };
        defer allocator.free(content);
        const n = file.readAll(content) catch {
            i += 1;
            continue;
        };
        const data = content[0..n];

        // Write blob.
        const oid = loose.writeLooseObject(allocator, git_dir, .blob, data) catch |err| switch (err) {
            error.PathAlreadyExists => computeBlobOid(data),
            else => {
                i += 1;
                continue;
            },
        };

        // Update entry.
        entry.oid = oid;
        entry.file_size = @intCast(n);
        entry.mtime_s = mtime_s;
        entry.mtime_ns = mtime_ns;

        i += 1;
    }
}

/// Parse the parent OID from commit data. Returns null for root commits.
fn parseCommitParent(data: []const u8) ?types.ObjectId {
    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) break; // End of headers.
        if (std.mem.startsWith(u8, line, "parent ")) {
            if (line.len >= "parent ".len + types.OID_HEX_LEN) {
                return types.ObjectId.fromHex(line["parent ".len..][0..types.OID_HEX_LEN]) catch null;
            }
        }
    }
    return null;
}

/// Parse the commit message from commit data.
fn parseCommitMessage(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Find the blank line that separates headers from the message.
    if (std.mem.indexOf(u8, data, "\n\n")) |pos| {
        const msg = data[pos + 2 ..];
        // Trim trailing newline.
        const trimmed = std.mem.trimRight(u8, msg, "\n");
        const result = try allocator.alloc(u8, trimmed.len);
        @memcpy(result, trimmed);
        return result;
    }
    return error.InvalidCommit;
}

/// Get the tree OID from a commit object.
fn getCommitTreeOid(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    commit_oid: *const types.ObjectId,
) ?types.ObjectId {
    var obj = repo.readObject(allocator, commit_oid) catch return null;
    defer obj.deinit();

    if (obj.obj_type != .commit) return null;

    if (!std.mem.startsWith(u8, obj.data, "tree ")) return null;
    const newline = std.mem.indexOfScalar(u8, obj.data, '\n') orelse return null;
    if (newline < "tree ".len + types.OID_HEX_LEN) return null;

    return types.ObjectId.fromHex(obj.data["tree ".len..][0..types.OID_HEX_LEN]) catch null;
}

/// Read HEAD as a direct OID (for detached HEAD).
fn readHeadOid(allocator: std.mem.Allocator, git_dir: []const u8) ?types.ObjectId {
    var path_buf: [4096]u8 = undefined;
    const head_path = buildPath(&path_buf, git_dir, "/HEAD");

    const content = readFileContents(allocator, head_path) catch return null;
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n\r ");

    if (std.mem.startsWith(u8, trimmed, "ref: ")) return null; // Not detached.
    if (trimmed.len < types.OID_HEX_LEN) return null;

    return types.ObjectId.fromHex(trimmed[0..types.OID_HEX_LEN]) catch null;
}

/// Write an OID directly to HEAD (for detached HEAD).
fn writeHeadOid(git_dir: []const u8, oid: types.ObjectId) !void {
    var path_buf: [4096]u8 = undefined;
    const head_path = buildPath(&path_buf, git_dir, "/HEAD");

    const hex = oid.toHex();
    var content_buf: [types.OID_HEX_LEN + 1]u8 = undefined;
    @memcpy(content_buf[0..types.OID_HEX_LEN], &hex);
    content_buf[types.OID_HEX_LEN] = '\n';

    const file = try std.fs.createFileAbsolute(head_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(&content_buf);
}

/// Extract the short branch name from a full ref name.
fn getBranchShortName(head_ref: ?[]const u8) []const u8 {
    if (head_ref) |ref_name| {
        if (std.mem.startsWith(u8, ref_name, "refs/heads/")) {
            return ref_name["refs/heads/".len..];
        }
        return ref_name;
    }
    return "HEAD";
}

/// Get timestamp as a string (seconds since epoch).
fn getTimestamp(buf: []u8) []const u8 {
    const ts = std.posix.clock_gettime(.REALTIME) catch return "0";
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{d}", .{ts.sec}) catch return "0";
    return buf[0..stream.pos];
}

/// Compute the OID for a commit object without writing it.
fn computeCommitOid(data: []const u8) types.ObjectId {
    var header_buf: [64]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    hwriter.writeAll("commit ") catch unreachable;
    hwriter.print("{d}", .{data.len}) catch unreachable;
    hwriter.writeByte(0) catch unreachable;
    const header = header_buf[0..hstream.pos];

    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    return types.ObjectId{ .bytes = hasher.finalResult() };
}

/// Compute the blob OID without writing.
fn computeBlobOid(data: []const u8) types.ObjectId {
    var header_buf: [64]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    hwriter.writeAll("blob ") catch unreachable;
    hwriter.print("{d}", .{data.len}) catch unreachable;
    hwriter.writeByte(0) catch unreachable;
    const header = header_buf[0..hstream.pos];

    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    return types.ObjectId{ .bytes = hasher.finalResult() };
}

// ── Utility functions ──────────────────────────────────────────────────────

fn buildPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn buildPath2(buf: []u8, a: []const u8, sep: []const u8, b: []const u8) []const u8 {
    var pos: usize = 0;
    @memcpy(buf[pos..][0..a.len], a);
    pos += a.len;
    @memcpy(buf[pos..][0..sep.len], sep);
    pos += sep.len;
    @memcpy(buf[pos..][0..b.len], b);
    pos += b.len;
    return buf[0..pos];
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
