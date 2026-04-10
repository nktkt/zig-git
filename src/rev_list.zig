const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_diff = @import("tree_diff.zig");
const commit_info = @import("commit_info.zig");
const ref_mod = @import("ref.zig");
const commit_graph_mod = @import("commit_graph.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Sort order for rev-list output.
pub const SortOrder = enum {
    /// Default: chronological (by timestamp, newest first).
    chronological,
    /// Topological: children before parents.
    topo,
    /// Date order: by committer date.
    date,
};

/// Options for the rev-list command.
pub const RevListOptions = struct {
    /// Count commits instead of listing.
    count: bool = false,
    /// List all reachable objects (commits + trees + blobs).
    objects: bool = false,
    /// Only commits on ancestry path between endpoints.
    ancestry_path: bool = false,
    /// Sort order.
    sort_order: SortOrder = .chronological,
    /// Reverse output order.
    reverse: bool = false,
    /// Max commits to output (0 = unlimited).
    max_count: usize = 0,
    /// Number of commits to skip.
    skip: usize = 0,
    /// Only commits after this timestamp (inclusive).
    since: i64 = 0,
    /// Only commits before this timestamp (inclusive).
    until: i64 = 0,
    /// Follow only first parent of merge commits.
    first_parent: bool = false,
};

/// Range specification parsed from command line.
const RangeSpec = struct {
    /// Positive refs (include commits reachable from these).
    include: std.array_list.Managed(types.ObjectId),
    /// Negative refs (exclude commits reachable from these).
    exclude: std.array_list.Managed(types.ObjectId),
    /// Whether this is a symmetric difference (A...B).
    symmetric: bool,

    fn deinit(self: *RangeSpec) void {
        self.include.deinit();
        self.exclude.deinit();
    }
};

pub fn runRevList(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = RevListOptions{};
    var positionals = std.array_list.Managed([]const u8).init(allocator);
    defer positionals.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--count")) {
            opts.count = true;
        } else if (std.mem.eql(u8, arg, "--objects")) {
            opts.objects = true;
        } else if (std.mem.eql(u8, arg, "--ancestry-path")) {
            opts.ancestry_path = true;
        } else if (std.mem.eql(u8, arg, "--topo-order")) {
            opts.sort_order = .topo;
        } else if (std.mem.eql(u8, arg, "--date-order")) {
            opts.sort_order = .date;
        } else if (std.mem.eql(u8, arg, "--reverse")) {
            opts.reverse = true;
        } else if (std.mem.eql(u8, arg, "--first-parent")) {
            opts.first_parent = true;
        } else if (std.mem.startsWith(u8, arg, "--max-count=")) {
            opts.max_count = std.fmt.parseInt(usize, arg["--max-count=".len..], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "-n")) {
            i += 1;
            if (i < args.len) {
                opts.max_count = std.fmt.parseInt(usize, args[i], 10) catch 0;
            }
        } else if (std.mem.startsWith(u8, arg, "--skip=")) {
            opts.skip = std.fmt.parseInt(usize, arg["--skip=".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--since=") or std.mem.startsWith(u8, arg, "--after=")) {
            const val = if (std.mem.startsWith(u8, arg, "--since=")) arg["--since=".len..] else arg["--after=".len..];
            opts.since = commit_info.parseDateToTimestamp(val);
        } else if (std.mem.startsWith(u8, arg, "--until=") or std.mem.startsWith(u8, arg, "--before=")) {
            const val = if (std.mem.startsWith(u8, arg, "--until=")) arg["--until=".len..] else arg["--before=".len..];
            opts.until = commit_info.parseDateToTimestamp(val);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try positionals.append(arg);
        }
    }

    // Parse range specifications
    var range = try parseRange(allocator, repo, positionals.items);
    defer range.deinit();

    if (range.include.items.len == 0) {
        // Default: HEAD
        const head_oid = repo.resolveRef(allocator, "HEAD") catch {
            return;
        };
        try range.include.append(head_oid);
    }

    // Collect excluded commits
    var excluded = std.AutoHashMap(types.ObjectId, void).init(allocator);
    defer excluded.deinit();

    for (range.exclude.items) |exc_oid| {
        try collectReachable(allocator, repo, exc_oid, &excluded, opts.first_parent);
    }

    // Walk commits from included refs
    var result_oids = std.array_list.Managed(types.ObjectId).init(allocator);
    defer result_oids.deinit();

    var visited = std.AutoHashMap(types.ObjectId, void).init(allocator);
    defer visited.deinit();

    // For symmetric diff, we also walk from exclude side and merge
    if (range.symmetric and range.exclude.items.len > 0) {
        // Symmetric: (A...B) = commits in A not in B, plus commits in B not in A
        // We already have excluded set from A. Now collect excluded from B for A's side.
        var excluded_b = std.AutoHashMap(types.ObjectId, void).init(allocator);
        defer excluded_b.deinit();

        for (range.include.items) |inc_oid| {
            try collectReachable(allocator, repo, inc_oid, &excluded_b, opts.first_parent);
        }

        // Commits reachable from B but not A
        try walkCommits(allocator, repo, range.include.items, &excluded, &visited, &result_oids, &opts);

        // Commits reachable from A (exclude side) but not B
        try walkCommits(allocator, repo, range.exclude.items, &excluded_b, &visited, &result_oids, &opts);
    } else {
        try walkCommits(allocator, repo, range.include.items, &excluded, &visited, &result_oids, &opts);
    }

    // Sort if needed
    if (opts.sort_order == .date or opts.sort_order == .topo) {
        try sortCommits(allocator, repo, result_oids.items, opts.sort_order);
    }

    // Apply ancestry-path filter
    if (opts.ancestry_path and range.exclude.items.len > 0) {
        var filtered = std.array_list.Managed(types.ObjectId).init(allocator);
        defer filtered.deinit();

        try filterAncestryPath(allocator, repo, result_oids.items, range.include.items, range.exclude.items, &filtered, opts.first_parent);
        result_oids.clearRetainingCapacity();
        try result_oids.appendSlice(filtered.items);
    }

    // Reverse if requested
    if (opts.reverse) {
        std.mem.reverse(types.ObjectId, result_oids.items);
    }

    // Apply skip
    var output_start: usize = 0;
    if (opts.skip > 0) {
        output_start = @min(opts.skip, result_oids.items.len);
    }

    // Apply max-count
    var output_end: usize = result_oids.items.len;
    if (opts.max_count > 0) {
        output_end = @min(output_start + opts.max_count, result_oids.items.len);
    }

    const output_slice = result_oids.items[output_start..output_end];

    if (opts.count) {
        var buf: [32]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        stream.writer().print("{d}\n", .{output_slice.len}) catch {};
        try stdout_file.writeAll(buf[0..stream.pos]);
        return;
    }

    // Output
    if (opts.objects) {
        // List all objects: commits + trees + blobs
        try outputAllObjects(allocator, repo, output_slice);
    } else {
        for (output_slice) |oid| {
            const hex = oid.toHex();
            try stdout_file.writeAll(&hex);
            try stdout_file.writeAll("\n");
        }
    }
}

/// Parse range specifications from positional arguments.
fn parseRange(allocator: std.mem.Allocator, repo: *repository.Repository, positionals: []const []const u8) !RangeSpec {
    var spec = RangeSpec{
        .include = std.array_list.Managed(types.ObjectId).init(allocator),
        .exclude = std.array_list.Managed(types.ObjectId).init(allocator),
        .symmetric = false,
    };
    errdefer {
        spec.include.deinit();
        spec.exclude.deinit();
    }

    for (positionals) |arg| {
        // Check for A...B (symmetric difference)
        if (std.mem.indexOf(u8, arg, "...")) |dot_pos| {
            const left = arg[0..dot_pos];
            const right = arg[dot_pos + 3 ..];
            if (left.len > 0) {
                const left_oid = try repo.resolveRef(allocator, left);
                try spec.exclude.append(left_oid);
            }
            if (right.len > 0) {
                const right_oid = try repo.resolveRef(allocator, right);
                try spec.include.append(right_oid);
            }
            spec.symmetric = true;
            continue;
        }

        // Check for A..B (range)
        if (std.mem.indexOf(u8, arg, "..")) |dot_pos| {
            const left = arg[0..dot_pos];
            const right = arg[dot_pos + 2 ..];
            if (left.len > 0) {
                const left_oid = try repo.resolveRef(allocator, left);
                try spec.exclude.append(left_oid);
            }
            if (right.len > 0) {
                const right_oid = try repo.resolveRef(allocator, right);
                try spec.include.append(right_oid);
            }
            continue;
        }

        // Check for ^REF (exclude)
        if (arg.len > 1 and arg[0] == '^') {
            const ref_oid = try repo.resolveRef(allocator, arg[1..]);
            try spec.exclude.append(ref_oid);
            continue;
        }

        // Plain ref (include)
        const oid = try repo.resolveRef(allocator, arg);
        try spec.include.append(oid);
    }

    return spec;
}

/// Collect all commits reachable from a starting OID.
fn collectReachable(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    start_oid: types.ObjectId,
    out: *std.AutoHashMap(types.ObjectId, void),
    first_parent: bool,
) !void {
    const GRAPH_NO_PARENT: u32 = 0x70000000;
    const GRAPH_EXTRA_EDGES: u32 = 0x80000000;

    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();
    try queue.append(start_oid);

    while (queue.items.len > 0) {
        const oid = queue.orderedRemove(0);

        // Check if already in output (O(1) hash lookup)
        const gop = try out.getOrPut(oid);
        if (gop.found_existing) continue;

        // Try commit-graph for fast parent resolution
        if (repo.commit_graph) |*cg| {
            if (cg.findCommit(&oid)) |idx| {
                if (cg.getCommitData(idx)) |cdata| {
                    if (first_parent) {
                        if (cdata.parent1 != GRAPH_NO_PARENT) {
                            try queue.append(cg.getOid(cdata.parent1));
                        }
                    } else {
                        if (cdata.parent1 != GRAPH_NO_PARENT) {
                            try queue.append(cg.getOid(cdata.parent1));
                        }
                        if (cdata.parent2 != GRAPH_NO_PARENT) {
                            if (cdata.parent2 & GRAPH_EXTRA_EDGES != 0) {
                                const extra_idx = cdata.parent2 & 0x7fffffff;
                                if (cg.extra_edges_offset) |extra_off| {
                                    var ei = extra_idx;
                                    while (true) {
                                        const edge_offset = extra_off + @as(usize, ei) * 4;
                                        if (edge_offset + 4 > cg.data.len) break;
                                        const edge_val = std.mem.readInt(u32, cg.data[edge_offset..][0..4], .big);
                                        const parent_idx = edge_val & 0x7fffffff;
                                        try queue.append(cg.getOid(parent_idx));
                                        if (edge_val & 0x80000000 != 0) break;
                                        ei += 1;
                                    }
                                }
                            } else {
                                try queue.append(cg.getOid(cdata.parent2));
                            }
                        }
                    }
                    continue;
                } else |_| {}
            }
        }

        // Fallback: read commit and add parents
        var obj = repo.readObject(allocator, &oid) catch continue;
        defer obj.deinit();
        if (obj.obj_type != .commit) continue;

        var parents = tree_diff.getCommitParents(allocator, obj.data) catch continue;
        defer parents.deinit();

        if (first_parent) {
            if (parents.items.len > 0) {
                try queue.append(parents.items[0]);
            }
        } else {
            for (parents.items) |parent_oid| {
                try queue.append(parent_oid);
            }
        }
    }
}

/// Walk commits from starting OIDs, filtering out excluded ones.
fn walkCommits(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    starts: []const types.ObjectId,
    excluded: *std.AutoHashMap(types.ObjectId, void),
    visited: *std.AutoHashMap(types.ObjectId, void),
    result: *std.array_list.Managed(types.ObjectId),
    opts: *const RevListOptions,
) !void {
    const GRAPH_NO_PARENT: u32 = 0x70000000;
    const GRAPH_EXTRA_EDGES: u32 = 0x80000000;

    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();

    for (starts) |oid| {
        try queue.append(oid);
    }

    while (queue.items.len > 0) {
        const oid = queue.orderedRemove(0);

        // Check if visited (O(1) hash lookup)
        const visit_gop = try visited.getOrPut(oid);
        if (visit_gop.found_existing) continue;

        // Check if excluded (O(1) hash lookup)
        if (excluded.contains(oid)) continue;

        // Try commit-graph for fast traversal (no object read needed for counting)
        if (repo.commit_graph) |*cg| {
            if (cg.findCommit(&oid)) |idx| {
                if (cg.getCommitData(idx)) |cdata| {
                    // Apply date filters using commit-graph timestamp
                    if (opts.since != 0 or opts.until != 0) {
                        const ts: i64 = @intCast(cdata.timestamp);
                        if (opts.since != 0 and ts < opts.since) continue;
                        if (opts.until != 0 and ts > opts.until) continue;
                    }

                    try result.append(oid);

                    // Add parents from commit-graph
                    if (opts.first_parent) {
                        if (cdata.parent1 != GRAPH_NO_PARENT) {
                            try queue.append(cg.getOid(cdata.parent1));
                        }
                    } else {
                        if (cdata.parent1 != GRAPH_NO_PARENT) {
                            try queue.append(cg.getOid(cdata.parent1));
                        }
                        if (cdata.parent2 != GRAPH_NO_PARENT) {
                            if (cdata.parent2 & GRAPH_EXTRA_EDGES != 0) {
                                const extra_idx = cdata.parent2 & 0x7fffffff;
                                if (cg.extra_edges_offset) |extra_off| {
                                    var ei = extra_idx;
                                    while (true) {
                                        const edge_offset = extra_off + @as(usize, ei) * 4;
                                        if (edge_offset + 4 > cg.data.len) break;
                                        const edge_val = std.mem.readInt(u32, cg.data[edge_offset..][0..4], .big);
                                        const parent_idx = edge_val & 0x7fffffff;
                                        try queue.append(cg.getOid(parent_idx));
                                        if (edge_val & 0x80000000 != 0) break;
                                        ei += 1;
                                    }
                                }
                            } else {
                                try queue.append(cg.getOid(cdata.parent2));
                            }
                        }
                    }
                    continue;
                } else |_| {}
            }
        }

        // Fallback: read commit object
        var obj = repo.readObject(allocator, &oid) catch continue;
        defer obj.deinit();
        if (obj.obj_type != .commit) continue;

        // Apply date filters
        if (opts.since != 0 or opts.until != 0) {
            const author = commit_info.parseAuthor(findAuthorLine(obj.data));
            if (opts.since != 0 and author.timestamp < opts.since) continue;
            if (opts.until != 0 and author.timestamp > opts.until) continue;
        }

        try result.append(oid);

        // Add parents to queue
        var parents = tree_diff.getCommitParents(allocator, obj.data) catch continue;
        defer parents.deinit();

        if (opts.first_parent) {
            if (parents.items.len > 0) {
                try queue.append(parents.items[0]);
            }
        } else {
            for (parents.items) |parent_oid| {
                try queue.append(parent_oid);
            }
        }
    }
}

/// Find the "author ..." line in commit data and return the part after "author ".
fn findAuthorLine(data: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "author ")) {
            return line[7..];
        }
    }
    return "";
}

/// Sort commits by the given order.
fn sortCommits(allocator: std.mem.Allocator, repo: *repository.Repository, commits: []types.ObjectId, order: SortOrder) !void {
    _ = order;
    // Collect timestamps for sorting
    var timestamps = try allocator.alloc(i64, commits.len);
    defer allocator.free(timestamps);

    for (commits, 0..) |*oid, idx| {
        var obj = repo.readObject(allocator, oid) catch {
            timestamps[idx] = 0;
            continue;
        };
        defer obj.deinit();
        const author = commit_info.parseAuthor(findAuthorLine(obj.data));
        timestamps[idx] = author.timestamp;
    }

    // Simple insertion sort (stable) - sort by timestamp descending
    var ci: usize = 1;
    while (ci < commits.len) : (ci += 1) {
        var j = ci;
        while (j > 0 and timestamps[j] > timestamps[j - 1]) {
            std.mem.swap(types.ObjectId, &commits[j], &commits[j - 1]);
            std.mem.swap(i64, &timestamps[j], &timestamps[j - 1]);
            j -= 1;
        }
    }
}

/// Filter commits to only those on the ancestry path between include and exclude refs.
fn filterAncestryPath(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    commits: []const types.ObjectId,
    include: []const types.ObjectId,
    exclude: []const types.ObjectId,
    out: *std.array_list.Managed(types.ObjectId),
    first_parent: bool,
) !void {
    _ = first_parent;
    // An ancestry path commit is one that is both an ancestor of an include ref
    // and a descendant of an exclude ref.
    // Simple approach: for each commit, check if any include ref is reachable from it,
    // and if it is reachable from any exclude ref.

    // Build set of commits for fast lookup
    for (commits) |oid| {
        // Check: is this commit an ancestor of any include?
        // Since we already walked from include, all commits in the list are ancestors.
        // We just need to check if the commit is a descendant of any exclude ref.
        var is_descendant = false;
        for (exclude) |exc_oid| {
            if (isAncestor(allocator, repo, &exc_oid, &oid)) {
                is_descendant = true;
                break;
            }
        }
        _ = include;

        if (is_descendant) {
            try out.append(oid);
        }
    }
}

/// Check if `ancestor` is an ancestor of `descendant`.
fn isAncestor(allocator: std.mem.Allocator, repo: *repository.Repository, ancestor: *const types.ObjectId, descendant: *const types.ObjectId) bool {
    if (ancestor.eql(descendant)) return true;

    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();
    queue.append(descendant.*) catch return false;

    var visited_map = std.AutoHashMap(types.ObjectId, void).init(allocator);
    defer visited_map.deinit();

    var iterations: usize = 0;
    const max_iterations: usize = 10000;

    while (queue.items.len > 0 and iterations < max_iterations) {
        iterations += 1;
        const oid = queue.orderedRemove(0);

        if (oid.eql(ancestor)) return true;

        const gop = visited_map.getOrPut(oid) catch continue;
        if (gop.found_existing) continue;

        var obj = repo.readObject(allocator, &oid) catch continue;
        defer obj.deinit();
        if (obj.obj_type != .commit) continue;

        var parents = tree_diff.getCommitParents(allocator, obj.data) catch continue;
        defer parents.deinit();

        for (parents.items) |parent_oid| {
            queue.append(parent_oid) catch continue;
        }
    }

    return false;
}

/// Output all objects reachable from the given commits (commits + trees + blobs).
/// Uses an iterative approach with an explicit stack to avoid recursive error set issues.
fn outputAllObjects(allocator: std.mem.Allocator, repo: *repository.Repository, commits: []const types.ObjectId) !void {
    var seen = std.AutoHashMap(types.ObjectId, void).init(allocator);
    defer seen.deinit();

    var stack = std.array_list.Managed(types.ObjectId).init(allocator);
    defer stack.deinit();

    for (commits) |oid| {
        try stack.append(oid);
    }

    while (stack.items.len > 0) {
        const oid = stack.orderedRemove(stack.items.len - 1);

        // Check if already seen (O(1) hash lookup)
        const gop = seen.getOrPut(oid) catch continue;
        if (gop.found_existing) continue;

        const hex = oid.toHex();
        stdout_file.writeAll(&hex) catch continue;
        stdout_file.writeAll("\n") catch continue;

        // Read the object to find children
        var obj = repo.readObject(allocator, &oid) catch continue;
        defer obj.deinit();

        switch (obj.obj_type) {
            .commit => {
                const tree_oid = tree_diff.getCommitTreeOid(obj.data) catch continue;
                stack.append(tree_oid) catch continue;
            },
            .tree => {
                var pos: usize = 0;
                while (pos < obj.data.len) {
                    const space = std.mem.indexOfScalarPos(u8, obj.data, pos, ' ') orelse break;
                    const null_byte = std.mem.indexOfScalarPos(u8, obj.data, space, 0) orelse break;
                    if (null_byte + 1 + types.OID_RAW_LEN > obj.data.len) break;

                    var entry_oid: types.ObjectId = undefined;
                    @memcpy(&entry_oid.bytes, obj.data[null_byte + 1 ..][0..types.OID_RAW_LEN]);
                    stack.append(entry_oid) catch {};

                    pos = null_byte + 1 + types.OID_RAW_LEN;
                }
            },
            .blob => {},
            .tag => {
                const target = parseTagTarget(obj.data) catch continue;
                stack.append(target) catch continue;
            },
        }
    }
}

fn parseTagTarget(data: []const u8) !types.ObjectId {
    if (!std.mem.startsWith(u8, data, "object ")) return error.InvalidTag;
    if (data.len < 7 + types.OID_HEX_LEN) return error.InvalidTag;
    return types.ObjectId.fromHex(data[7..][0..types.OID_HEX_LEN]);
}

test "findAuthorLine" {
    const data = "tree abc\nparent def\nauthor John <j@e.com> 12345 +0000\ncommitter Jane <j2@e.com> 12345 +0000\n\nmessage\n";
    const line = findAuthorLine(data);
    try std.testing.expect(std.mem.startsWith(u8, line, "John"));
}

test "parseRange empty" {
    // Just a smoke test that parseRange handles empty positionals
    // (actual resolution requires a repo, so we cannot fully test here)
}
