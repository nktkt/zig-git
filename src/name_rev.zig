const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const ref_mod = @import("ref.zig");
const tree_diff = @import("tree_diff.zig");
const commit_info = @import("commit_info.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Options for name-rev.
pub const NameRevOptions = struct {
    /// Only output the symbolic name.
    name_only: bool = false,
    /// Only use refs matching this pattern.
    refs_pattern: ?[]const u8 = null,
    /// Only use tags.
    tags_only: bool = false,
    /// Error if no name found.
    no_undefined: bool = false,
    /// Fallback to abbreviated SHA.
    always: bool = false,
    /// Read SHAs from stdin and annotate.
    use_stdin: bool = false,
};

/// A naming result for a commit.
const NamingResult = struct {
    /// The symbolic name (e.g., "refs/heads/main~2").
    name: []const u8,
    /// Distance from the ref to this commit.
    distance: usize,
};

pub fn runNameRev(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = NameRevOptions{};
    var positionals = std.array_list.Managed([]const u8).init(allocator);
    defer positionals.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--name-only")) {
            opts.name_only = true;
        } else if (std.mem.startsWith(u8, arg, "--refs=")) {
            opts.refs_pattern = arg["--refs=".len..];
        } else if (std.mem.eql(u8, arg, "--tags")) {
            opts.tags_only = true;
        } else if (std.mem.eql(u8, arg, "--no-undefined")) {
            opts.no_undefined = true;
        } else if (std.mem.eql(u8, arg, "--always")) {
            opts.always = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            opts.use_stdin = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try positionals.append(arg);
        }
    }

    if (opts.use_stdin) {
        try processStdin(repo, allocator, &opts);
        return;
    }

    if (positionals.items.len == 0) {
        // Default to HEAD
        try positionals.append("HEAD");
    }

    for (positionals.items) |ref_str| {
        const oid = repo.resolveRef(allocator, ref_str) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: could not resolve '{s}'\n", .{ref_str}) catch "fatal: could not resolve ref\n";
            try stderr_file.writeAll(msg);
            std.process.exit(128);
        };

        try outputNameRev(repo, allocator, &oid, &opts);
    }
}

fn processStdin(repo: *repository.Repository, allocator: std.mem.Allocator, opts: *const NameRevOptions) !void {
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };

    // Read all stdin
    var input_buf = std.array_list.Managed(u8).init(allocator);
    defer input_buf.deinit();

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = stdin_file.read(&read_buf) catch break;
        if (n == 0) break;
        try input_buf.appendSlice(read_buf[0..n]);
    }

    // Process line by line, looking for hex SHAs to annotate
    var lines = std.mem.splitScalar(u8, input_buf.items, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            try stdout_file.writeAll("\n");
            continue;
        }

        // Try to find a hex SHA in the line
        var annotated = false;
        if (line.len >= types.OID_HEX_LEN) {
            // Check for a full SHA at the start
            if (types.ObjectId.fromHex(line[0..types.OID_HEX_LEN])) |oid| {
                const name = findName(repo, allocator, &oid, opts);
                if (name) |n| {
                    defer allocator.free(n);
                    try stdout_file.writeAll(line[0..types.OID_HEX_LEN]);
                    try stdout_file.writeAll(" (");
                    try stdout_file.writeAll(n);
                    try stdout_file.writeAll(")");
                    if (line.len > types.OID_HEX_LEN) {
                        try stdout_file.writeAll(line[types.OID_HEX_LEN..]);
                    }
                    try stdout_file.writeAll("\n");
                    annotated = true;
                }
            } else |_| {}
        }

        if (!annotated) {
            try stdout_file.writeAll(line);
            try stdout_file.writeAll("\n");
        }
    }
}

fn outputNameRev(repo: *repository.Repository, allocator: std.mem.Allocator, oid: *const types.ObjectId, opts: *const NameRevOptions) !void {
    const hex = oid.toHex();
    const name = findName(repo, allocator, oid, opts);

    if (name) |n| {
        defer allocator.free(n);
        if (opts.name_only) {
            try stdout_file.writeAll(n);
            try stdout_file.writeAll("\n");
        } else {
            try stdout_file.writeAll(&hex);
            try stdout_file.writeAll(" ");
            try stdout_file.writeAll(n);
            try stdout_file.writeAll("\n");
        }
    } else {
        if (opts.no_undefined) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: cannot describe '{s}'\n", .{hex[0..7]}) catch "fatal: cannot describe\n";
            try stderr_file.writeAll(msg);
            std.process.exit(128);
        }

        if (opts.always) {
            if (opts.name_only) {
                try stdout_file.writeAll(hex[0..7]);
                try stdout_file.writeAll("\n");
            } else {
                try stdout_file.writeAll(&hex);
                try stdout_file.writeAll(" ");
                try stdout_file.writeAll(hex[0..7]);
                try stdout_file.writeAll("\n");
            }
        } else {
            try stdout_file.writeAll(&hex);
            try stdout_file.writeAll(" undefined\n");
        }
    }
}

/// Find the best symbolic name for a commit.
fn findName(repo: *repository.Repository, allocator: std.mem.Allocator, target_oid: *const types.ObjectId, opts: *const NameRevOptions) ?[]u8 {
    // Collect all refs to search
    var best_name: ?[]u8 = null;
    var best_distance: usize = std.math.maxInt(usize);

    // List refs from heads and tags
    const prefixes = if (opts.tags_only)
        &[_][]const u8{"refs/tags/"}
    else
        &[_][]const u8{ "refs/heads/", "refs/tags/", "refs/remotes/" };

    for (prefixes) |prefix| {
        const ref_entries = ref_mod.listRefs(allocator, repo.git_dir, prefix) catch continue;
        defer ref_mod.freeRefEntries(allocator, ref_entries);

        for (ref_entries) |ref_entry| {
            // Apply refs pattern filter
            if (opts.refs_pattern) |pattern| {
                if (!matchGlob(pattern, ref_entry.name)) continue;
            }

            // Resolve the ref to a commit OID (dereference tags)
            const commit_oid = resolveToCommit(repo, allocator, ref_entry.oid) catch continue;

            // Walk from this ref to find the target
            const distance = findDistance(allocator, repo, commit_oid, target_oid) orelse continue;

            if (distance < best_distance) {
                if (best_name) |old| allocator.free(old);
                best_distance = distance;
                best_name = formatRefName(allocator, ref_entry.name, distance) catch continue;
            }
        }
    }

    return best_name;
}

/// Resolve an OID to a commit OID (dereferences tags).
fn resolveToCommit(repo: *repository.Repository, allocator: std.mem.Allocator, oid: types.ObjectId) !types.ObjectId {
    var current = oid;
    var depth: usize = 0;
    while (depth < 10) : (depth += 1) {
        var obj = try repo.readObject(allocator, &current);
        defer obj.deinit();

        switch (obj.obj_type) {
            .commit => return current,
            .tag => {
                // Parse tag target
                if (std.mem.startsWith(u8, obj.data, "object ")) {
                    if (obj.data.len >= 7 + types.OID_HEX_LEN) {
                        current = try types.ObjectId.fromHex(obj.data[7..][0..types.OID_HEX_LEN]);
                        continue;
                    }
                }
                return error.InvalidTag;
            },
            else => return error.NotACommit,
        }
    }
    return error.TooManyDereferences;
}

/// Find the distance (number of commits) from `start` to `target` using BFS.
/// Returns null if target is not reachable from start.
fn findDistance(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    start: types.ObjectId,
    target: *const types.ObjectId,
) ?usize {
    if (start.eql(target)) return 0;

    const QueueEntry = struct {
        oid: types.ObjectId,
        distance: usize,
    };

    var queue = std.array_list.Managed(QueueEntry).init(allocator);
    defer queue.deinit();
    queue.append(.{ .oid = start, .distance = 0 }) catch return null;

    var visited_list = std.array_list.Managed([types.OID_HEX_LEN]u8).init(allocator);
    defer visited_list.deinit();

    const target_hex = target.toHex();

    var iterations: usize = 0;
    const max_iterations: usize = 5000;

    while (queue.items.len > 0 and iterations < max_iterations) {
        iterations += 1;
        const current = queue.orderedRemove(0);
        const hex = current.oid.toHex();

        if (std.mem.eql(u8, &hex, &target_hex)) return current.distance;

        var found = false;
        for (visited_list.items) |*v| {
            if (std.mem.eql(u8, v, &hex)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        visited_list.append(hex) catch continue;

        var obj = repo.readObject(allocator, &current.oid) catch continue;
        defer obj.deinit();
        if (obj.obj_type != .commit) continue;

        var parents = tree_diff.getCommitParents(allocator, obj.data) catch continue;
        defer parents.deinit();

        for (parents.items) |parent_oid| {
            queue.append(.{ .oid = parent_oid, .distance = current.distance + 1 }) catch continue;
        }
    }

    return null;
}

/// Format a ref name with distance suffix.
fn formatRefName(allocator: std.mem.Allocator, ref_name: []const u8, distance: usize) ![]u8 {
    if (distance == 0) {
        // Exact match: "refs/tags/v1.0^0" or just the ref name
        var result = try allocator.alloc(u8, ref_name.len + 2);
        @memcpy(result[0..ref_name.len], ref_name);
        result[ref_name.len] = '^';
        result[ref_name.len + 1] = '0';
        // For tags, show ^0; for branches, just the name
        if (std.mem.startsWith(u8, ref_name, "refs/tags/")) {
            return result;
        } else {
            allocator.free(result);
            result = try allocator.alloc(u8, ref_name.len);
            @memcpy(result, ref_name);
            return result;
        }
    }

    // Non-zero distance: "ref~N"
    var dist_buf: [16]u8 = undefined;
    var dist_stream = std.io.fixedBufferStream(&dist_buf);
    dist_stream.writer().print("{d}", .{distance}) catch return error.OutOfMemory;
    const dist_str = dist_buf[0..dist_stream.pos];

    const result = try allocator.alloc(u8, ref_name.len + 1 + dist_str.len);
    @memcpy(result[0..ref_name.len], ref_name);
    result[ref_name.len] = '~';
    @memcpy(result[ref_name.len + 1 ..][0..dist_str.len], dist_str);
    return result;
}

/// Simple glob matching (supports * and ?).
fn matchGlob(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == text[ti] or pattern[pi] == '?')) {
            pi += 1;
            ti += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') {
        pi += 1;
    }

    return pi == pattern.len;
}

test "matchGlob" {
    try std.testing.expect(matchGlob("refs/heads/*", "refs/heads/main"));
    try std.testing.expect(matchGlob("refs/tags/v*", "refs/tags/v1.0"));
    try std.testing.expect(!matchGlob("refs/heads/*", "refs/tags/v1.0"));
    try std.testing.expect(matchGlob("*", "anything"));
    try std.testing.expect(matchGlob("refs/?ain", "refs/main"));
}

test "formatRefName" {
    const allocator = std.testing.allocator;

    const name1 = try formatRefName(allocator, "refs/heads/main", 3);
    defer allocator.free(name1);
    try std.testing.expectEqualStrings("refs/heads/main~3", name1);

    const name2 = try formatRefName(allocator, "refs/heads/main", 0);
    defer allocator.free(name2);
    try std.testing.expectEqualStrings("refs/heads/main", name2);

    const name3 = try formatRefName(allocator, "refs/tags/v1.0", 0);
    defer allocator.free(name3);
    try std.testing.expectEqualStrings("refs/tags/v1.0^0", name3);
}
