const std = @import("std");
const types = @import("types.zig");
const hash_mod = @import("hash.zig");
const repository = @import("repository.zig");
const ref_mod = @import("ref.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const CGRAPH_MAGIC = "CGPH";
const CGRAPH_VERSION: u8 = 1;
const OID_VERSION: u8 = 1; // SHA-1
const CHUNK_OID_FANOUT: u32 = 0x4f494446;
const CHUNK_OID_LOOKUP: u32 = 0x4f49444c;
const CHUNK_COMMIT_DATA: u32 = 0x43444154;
const CHUNK_EXTRA_EDGES: u32 = 0x45444745;

const NO_PARENT: u32 = 0x70000000;
const EXTRA_EDGE_LIST_FLAG: u32 = 0x80000000;
const LAST_EDGE_FLAG: u32 = 0x80000000;

/// A commit entry for the commit-graph.
const CommitEntry = struct {
    oid: types.ObjectId,
    tree_oid: types.ObjectId,
    parents: []types.ObjectId,
    timestamp: u64,
    generation: u32,
    // Index in the sorted array (for parent references)
    sorted_index: u32,
};

/// Write the commit-graph file for the repository.
pub fn writeCommitGraph(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
) !u32 {
    // Step 1: Collect all commits reachable from refs
    var commits = std.array_list.Managed(CommitEntry).init(allocator);
    defer {
        for (commits.items) |*c| allocator.free(c.parents);
        commits.deinit();
    }

    var visited = std.AutoHashMap([types.OID_RAW_LEN]u8, void).init(allocator);
    defer visited.deinit();

    // Collect tips from refs
    var tips = std.array_list.Managed(types.ObjectId).init(allocator);
    defer tips.deinit();

    const ref_prefixes = [_][]const u8{ "refs/heads/", "refs/tags/", "refs/remotes/" };
    for (ref_prefixes) |prefix| {
        const refs = ref_mod.listRefs(allocator, repo.git_dir, prefix) catch continue;
        defer {
            for (refs) |e| allocator.free(@constCast(e.name));
            allocator.free(refs);
        }
        for (refs) |entry| {
            try tips.append(entry.oid);
        }
    }

    // HEAD
    if (repo.resolveRef(allocator, "HEAD")) |head_oid| {
        try tips.append(head_oid);
    } else |_| {}

    // BFS to find all commits
    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();

    for (tips.items) |tip| {
        if (!visited.contains(tip.bytes)) {
            try visited.put(tip.bytes, {});
            try queue.append(tip);
        }
    }

    while (queue.items.len > 0) {
        const current = queue.orderedRemove(0);

        var obj = repo.readObject(allocator, &current) catch continue;
        defer obj.deinit();

        if (obj.obj_type != .commit) continue;

        // Parse commit data
        const tree_oid = parseCommitTree(obj.data) catch continue;
        const parents = try parseCommitParents(allocator, obj.data);
        const timestamp = parseCommitTimestamp(obj.data);

        try commits.append(.{
            .oid = current,
            .tree_oid = tree_oid,
            .parents = parents,
            .timestamp = timestamp,
            .generation = 0,
            .sorted_index = 0,
        });

        // Add parents to queue
        for (parents) |parent_oid| {
            if (!visited.contains(parent_oid.bytes)) {
                try visited.put(parent_oid.bytes, {});
                try queue.append(parent_oid);
            }
        }
    }

    if (commits.items.len == 0) return 0;

    // Step 2: Sort by OID
    std.mem.sort(CommitEntry, commits.items, {}, struct {
        fn lessThan(_: void, a: CommitEntry, b: CommitEntry) bool {
            return std.mem.order(u8, &a.oid.bytes, &b.oid.bytes) == .lt;
        }
    }.lessThan);

    // Build OID -> index map and set sorted_index
    var oid_to_index = std.AutoHashMap([types.OID_RAW_LEN]u8, u32).init(allocator);
    defer oid_to_index.deinit();
    for (commits.items, 0..) |*c, idx| {
        c.sorted_index = @intCast(idx);
        try oid_to_index.put(c.oid.bytes, @intCast(idx));
    }

    // Step 3: Compute generation numbers
    try computeGenerations(allocator, commits.items, &oid_to_index);

    // Step 4: Write the commit-graph file
    const num_commits: u32 = @intCast(commits.items.len);

    // Count extra edges needed (for octopus merges with > 2 parents)
    var num_extra_edges: u32 = 0;
    for (commits.items) |c| {
        if (c.parents.len > 2) {
            num_extra_edges += @intCast(c.parents.len - 1);
        }
    }

    const has_extra_edges = num_extra_edges > 0;
    const num_chunks: u8 = if (has_extra_edges) 4 else 3;

    // Build the file content
    var data = std.array_list.Managed(u8).init(allocator);
    defer data.deinit();

    // Header: magic(4) + version(1) + oid_version(1) + num_chunks(1) + base_graphs(1)
    try data.appendSlice(CGRAPH_MAGIC);
    try data.append(CGRAPH_VERSION);
    try data.append(OID_VERSION);
    try data.append(num_chunks);
    try data.append(0); // base graph count

    // Chunk table of contents
    // Each entry: chunk_id(4) + offset(8)
    // The offset is from the start of the file
    const chunk_toc_size: usize = @as(usize, num_chunks + 1) * 12; // +1 for terminator
    const chunks_start: usize = 8 + chunk_toc_size;

    // Calculate chunk sizes and offsets
    const fanout_size: usize = 256 * 4;
    const oid_lookup_size: usize = @as(usize, num_commits) * types.OID_RAW_LEN;
    const commit_data_size: usize = @as(usize, num_commits) * (types.OID_RAW_LEN + 16);
    const extra_edges_size: usize = @as(usize, num_extra_edges) * 4;

    var offset: u64 = @intCast(chunks_start);

    // OID Fanout chunk entry
    try appendU32Big(&data, CHUNK_OID_FANOUT);
    try appendU64Big(&data, offset);
    offset += fanout_size;

    // OID Lookup chunk entry
    try appendU32Big(&data, CHUNK_OID_LOOKUP);
    try appendU64Big(&data, offset);
    offset += oid_lookup_size;

    // Commit Data chunk entry
    try appendU32Big(&data, CHUNK_COMMIT_DATA);
    try appendU64Big(&data, offset);
    offset += commit_data_size;

    if (has_extra_edges) {
        // Extra Edges chunk entry
        try appendU32Big(&data, CHUNK_EXTRA_EDGES);
        try appendU64Big(&data, offset);
        offset += extra_edges_size;
    }

    // Terminator entry (zero chunk ID)
    try appendU32Big(&data, 0);
    try appendU64Big(&data, offset);

    // OID Fanout chunk
    var fanout: [256]u32 = [_]u32{0} ** 256;
    for (commits.items) |c| {
        var b: usize = c.oid.bytes[0];
        while (b < 256) : (b += 1) {
            fanout[b] += 1;
        }
    }
    for (fanout) |count| {
        try appendU32Big(&data, count);
    }

    // OID Lookup chunk
    for (commits.items) |c| {
        try data.appendSlice(&c.oid.bytes);
    }

    // Commit Data chunk
    var extra_edge_idx: u32 = 0;
    for (commits.items) |c| {
        // Tree OID
        try data.appendSlice(&c.tree_oid.bytes);

        // Parent 1
        if (c.parents.len >= 1) {
            const p1_idx = oid_to_index.get(c.parents[0].bytes) orelse NO_PARENT;
            try appendU32Big(&data, p1_idx);
        } else {
            try appendU32Big(&data, NO_PARENT);
        }

        // Parent 2 (or extra edge list flag)
        if (c.parents.len == 0 or c.parents.len == 1) {
            try appendU32Big(&data, NO_PARENT);
        } else if (c.parents.len == 2) {
            const p2_idx = oid_to_index.get(c.parents[1].bytes) orelse NO_PARENT;
            try appendU32Big(&data, p2_idx);
        } else {
            // Octopus merge: point to extra edge list
            try appendU32Big(&data, EXTRA_EDGE_LIST_FLAG | extra_edge_idx);
            extra_edge_idx += @intCast(c.parents.len - 1);
        }

        // Generation number (30 bits) + timestamp (34 bits) = 8 bytes
        const gen: u64 = @as(u64, c.generation) << 34;
        const ts: u64 = c.timestamp & 0x3FFFFFFFF;
        try appendU64Big(&data, gen | ts);
    }

    // Extra Edges chunk
    if (has_extra_edges) {
        for (commits.items) |c| {
            if (c.parents.len <= 2) continue;
            // Write parents[1..] as extra edges
            for (c.parents[1..], 0..) |parent, pi| {
                const p_idx = oid_to_index.get(parent.bytes) orelse NO_PARENT;
                if (pi == c.parents.len - 2) {
                    // Last extra edge
                    try appendU32Big(&data, p_idx | LAST_EDGE_FLAG);
                } else {
                    try appendU32Big(&data, p_idx);
                }
            }
        }
    }

    // Trailing hash
    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(data.items);
    const file_hash = hasher.finalResult();
    try data.appendSlice(&file_hash);

    // Write to .git/objects/info/commit-graph
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..repo.git_dir.len], repo.git_dir);
    pos += repo.git_dir.len;
    const info_dir = "/objects/info";
    @memcpy(path_buf[pos..][0..info_dir.len], info_dir);
    pos += info_dir.len;
    const info_path = path_buf[0..pos];

    // Ensure directory exists
    std.fs.makeDirAbsolute(info_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const cg_suffix = "/commit-graph";
    @memcpy(path_buf[pos..][0..cg_suffix.len], cg_suffix);
    pos += cg_suffix.len;
    const cg_path = path_buf[0..pos];

    const file = try std.fs.createFileAbsolute(cg_path, .{});
    defer file.close();
    try file.writeAll(data.items);

    return num_commits;
}

/// Compute generation numbers using iterative topological processing.
fn computeGenerations(
    allocator: std.mem.Allocator,
    commits: []CommitEntry,
    oid_to_index: *std.AutoHashMap([types.OID_RAW_LEN]u8, u32),
) !void {
    // Initialize all generations to 0
    for (commits) |*c| c.generation = 0;

    // Iterative computation: repeat until no changes
    var changed = true;
    var iterations: u32 = 0;
    const max_iterations: u32 = @intCast(commits.len + 1);

    while (changed and iterations < max_iterations) {
        changed = false;
        iterations += 1;

        for (commits) |*c| {
            var max_parent_gen: u32 = 0;
            for (c.parents) |parent_oid| {
                if (oid_to_index.get(parent_oid.bytes)) |pidx| {
                    if (commits[pidx].generation > max_parent_gen) {
                        max_parent_gen = commits[pidx].generation;
                    }
                }
            }
            const new_gen = max_parent_gen + 1;
            if (new_gen > c.generation) {
                c.generation = new_gen;
                changed = true;
            }
        }
    }

    _ = allocator;
}

/// Parse the tree OID from commit data.
fn parseCommitTree(data: []const u8) !types.ObjectId {
    if (data.len < 5 + types.OID_HEX_LEN) return error.InvalidCommitFormat;
    if (!std.mem.startsWith(u8, data, "tree ")) return error.InvalidCommitFormat;
    return types.ObjectId.fromHex(data[5..][0..types.OID_HEX_LEN]);
}

/// Parse parent OIDs from commit data.
fn parseCommitParents(allocator: std.mem.Allocator, data: []const u8) ![]types.ObjectId {
    var parents = std.array_list.Managed(types.ObjectId).init(allocator);
    defer parents.deinit();

    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "parent ")) {
            if (line.len >= 7 + types.OID_HEX_LEN) {
                const oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch continue;
                try parents.append(oid);
            }
        }
    }

    return parents.toOwnedSlice();
}

/// Parse the author timestamp from commit data.
fn parseCommitTimestamp(data: []const u8) u64 {
    var line_iter = std.mem.splitScalar(u8, data, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "committer ")) {
            // Find the timestamp: last two tokens before newline are "TIMESTAMP TIMEZONE"
            const rest = line["committer ".len..];
            // Find > which ends the email
            const gt_pos = std.mem.lastIndexOfScalar(u8, rest, '>') orelse continue;
            const after_email = std.mem.trimLeft(u8, rest[gt_pos + 1 ..], " ");
            const space_pos = std.mem.indexOfScalar(u8, after_email, ' ');
            const ts_str = if (space_pos) |sp| after_email[0..sp] else after_email;
            return std.fmt.parseInt(u64, ts_str, 10) catch 0;
        }
    }
    return 0;
}

fn appendU32Big(data: *std.array_list.Managed(u8), value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .big);
    try data.appendSlice(&buf);
}

fn appendU64Big(data: *std.array_list.Managed(u8), value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .big);
    try data.appendSlice(&buf);
}

test "parseCommitTimestamp" {
    const data = "tree abc\nparent def\nauthor A <a@b.c> 1700000000 +0000\ncommitter B <b@c.d> 1700000001 +0000\n\nmessage";
    const ts = parseCommitTimestamp(data);
    try std.testing.expectEqual(@as(u64, 1700000001), ts);
}

test "parseCommitTree in graph" {
    const data = "tree e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\nparent abc\n\nmessage";
    const oid = try parseCommitTree(data);
    const hex = oid.toHex();
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &hex);
}
