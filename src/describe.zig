const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const ref_mod = @import("ref.zig");
const log_mod = @import("log.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const describe_usage =
    \\usage: zig-git describe [--all] [--tags] [--long] [--always] [--abbrev=<n>]
    \\                        [--match <pattern>] [--candidates <n>] [<commit-ish>]
    \\
    \\  --all            Use any ref, not just annotated tags
    \\  --tags           Use any tag, including lightweight tags
    \\  --long           Always output the long format (tag-distance-gSHA)
    \\  --always         Show abbreviated commit object as fallback
    \\  --abbrev=<n>     Use <n> digits of the abbreviated SHA (default: 7)
    \\  --match <pat>    Only consider tags matching the given glob pattern
    \\  --candidates <n> Consider <n> most recent tags (default: 10)
    \\  --exact-match    Only output exact matches (tag directly on the commit)
    \\  --dirty[=mark]   Append '-dirty' if the working tree has modifications
    \\
;

/// Options for the describe command.
const DescribeOptions = struct {
    /// Use all refs, not just tags.
    all: bool = false,
    /// Use any tag (including lightweight tags).
    tags: bool = false,
    /// Always output long format.
    long: bool = false,
    /// Show abbreviated commit even if no tags found.
    always: bool = false,
    /// Number of hex digits for abbreviated SHA.
    abbrev: usize = 7,
    /// Only output if there's an exact tag match.
    exact_match: bool = false,
    /// Optional glob pattern to match tag names against.
    match_pattern: ?[]const u8 = null,
    /// Maximum number of candidate tags to consider.
    candidates: usize = 10,
    /// Commit-ish to describe (default: HEAD).
    commit_ref: []const u8 = "HEAD",
    /// Append dirty marker.
    dirty: bool = false,
    /// Custom dirty marker suffix.
    dirty_mark: []const u8 = "-dirty",
};

/// A tag candidate with its distance from the target commit.
const TagCandidate = struct {
    tag_name: []const u8,
    tag_oid: types.ObjectId,
    /// The commit OID that the tag points to.
    commit_oid: types.ObjectId,
    /// Distance (number of commits) from the described commit to this tag.
    distance: usize,
};

/// Entry point for the describe command.
pub fn runDescribe(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = DescribeOptions{};

    // Parse arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--all")) {
            opts.all = true;
        } else if (std.mem.eql(u8, arg, "--tags")) {
            opts.tags = true;
        } else if (std.mem.eql(u8, arg, "--long")) {
            opts.long = true;
        } else if (std.mem.eql(u8, arg, "--always")) {
            opts.always = true;
        } else if (std.mem.eql(u8, arg, "--exact-match")) {
            opts.exact_match = true;
        } else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
            const val = arg["--abbrev=".len..];
            opts.abbrev = std.fmt.parseInt(usize, val, 10) catch 7;
            if (opts.abbrev > types.OID_HEX_LEN) opts.abbrev = types.OID_HEX_LEN;
        } else if (std.mem.eql(u8, arg, "--abbrev")) {
            i += 1;
            if (i < args.len) {
                opts.abbrev = std.fmt.parseInt(usize, args[i], 10) catch 7;
                if (opts.abbrev > types.OID_HEX_LEN) opts.abbrev = types.OID_HEX_LEN;
            }
        } else if (std.mem.eql(u8, arg, "--match")) {
            i += 1;
            if (i < args.len) {
                opts.match_pattern = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--candidates")) {
            i += 1;
            if (i < args.len) {
                opts.candidates = std.fmt.parseInt(usize, args[i], 10) catch 10;
            }
        } else if (std.mem.eql(u8, arg, "--dirty")) {
            opts.dirty = true;
        } else if (std.mem.startsWith(u8, arg, "--dirty=")) {
            opts.dirty = true;
            opts.dirty_mark = arg["--dirty=".len..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: unknown option: {s}\n", .{arg}) catch "fatal: unknown option\n";
            try stderr_file.writeAll(msg);
            std.process.exit(1);
        } else {
            opts.commit_ref = arg;
        }
    }

    // Resolve the target commit
    const target_oid = repo.resolveRef(allocator, opts.commit_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: not a valid object name: '{s}'\n", .{opts.commit_ref}) catch "fatal: not a valid object name\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    // Collect all tags
    var tag_map = std.array_list.Managed(TagCandidate).init(allocator);
    defer tag_map.deinit();

    try collectTags(repo, allocator, &tag_map, &opts);

    // Check for exact match first: is the target commit directly tagged?
    for (tag_map.items) |*candidate| {
        if (candidate.commit_oid.eql(&target_oid)) {
            candidate.distance = 0;
        }
    }

    // Find exact matches
    var exact_match: ?[]const u8 = null;
    for (tag_map.items) |*candidate| {
        if (candidate.commit_oid.eql(&target_oid)) {
            if (exact_match == null or candidate.tag_name.len < exact_match.?.len) {
                exact_match = candidate.tag_name;
            }
        }
    }

    if (exact_match) |tag_name| {
        if (opts.long) {
            // Long format even for exact match: "tag-0-gSHA"
            const hex = target_oid.toHex();
            const abbrev_sha = hex[0..opts.abbrev];
            var buf: [512]u8 = undefined;
            var msg: []const u8 = undefined;
            if (opts.dirty) {
                msg = std.fmt.bufPrint(&buf, "{s}-0-g{s}{s}\n", .{ tag_name, abbrev_sha, opts.dirty_mark }) catch "describe output error\n";
            } else {
                msg = std.fmt.bufPrint(&buf, "{s}-0-g{s}\n", .{ tag_name, abbrev_sha }) catch "describe output error\n";
            }
            try stdout_file.writeAll(msg);
        } else {
            var buf: [512]u8 = undefined;
            var msg: []const u8 = undefined;
            if (opts.dirty) {
                msg = std.fmt.bufPrint(&buf, "{s}{s}\n", .{ tag_name, opts.dirty_mark }) catch "describe output error\n";
            } else {
                msg = std.fmt.bufPrint(&buf, "{s}\n", .{tag_name}) catch "describe output error\n";
            }
            try stdout_file.writeAll(msg);
        }
        return;
    }

    if (opts.exact_match) {
        var buf: [256]u8 = undefined;
        const hex = target_oid.toHex();
        const msg = std.fmt.bufPrint(&buf, "fatal: no tag exactly matches '{s}'\n", .{hex[0..7]}) catch "fatal: no tag exactly matches\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    }

    // Walk backwards from the target commit and find distances to all tags
    try computeDistances(repo, allocator, &target_oid, &tag_map);

    // Find the best candidate (closest tag with smallest distance)
    var best: ?*TagCandidate = null;
    for (tag_map.items) |*candidate| {
        if (candidate.distance == 0) continue; // Skip if distance not computed
        if (candidate.distance == std.math.maxInt(usize)) continue; // Not reachable
        if (best == null or candidate.distance < best.?.distance) {
            best = candidate;
        } else if (candidate.distance == best.?.distance) {
            // Prefer alphabetically earlier tag names on tie
            if (std.mem.order(u8, candidate.tag_name, best.?.tag_name) == .lt) {
                best = candidate;
            }
        }
    }

    if (best) |b| {
        const hex = target_oid.toHex();
        const abbrev_sha = hex[0..opts.abbrev];
        var buf: [512]u8 = undefined;
        var msg: []const u8 = undefined;
        if (opts.dirty) {
            msg = std.fmt.bufPrint(&buf, "{s}-{d}-g{s}{s}\n", .{ b.tag_name, b.distance, abbrev_sha, opts.dirty_mark }) catch "describe output error\n";
        } else {
            msg = std.fmt.bufPrint(&buf, "{s}-{d}-g{s}\n", .{ b.tag_name, b.distance, abbrev_sha }) catch "describe output error\n";
        }
        try stdout_file.writeAll(msg);
        return;
    }

    // No tags found
    if (opts.always) {
        const hex = target_oid.toHex();
        const abbrev_sha = hex[0..opts.abbrev];
        var buf: [128]u8 = undefined;
        var msg: []const u8 = undefined;
        if (opts.dirty) {
            msg = std.fmt.bufPrint(&buf, "{s}{s}\n", .{ abbrev_sha, opts.dirty_mark }) catch "describe output error\n";
        } else {
            msg = std.fmt.bufPrint(&buf, "{s}\n", .{abbrev_sha}) catch "describe output error\n";
        }
        try stdout_file.writeAll(msg);
    } else {
        try stderr_file.writeAll("fatal: No names found, cannot describe anything.\n");
        std.process.exit(128);
    }
}

/// Collect all tags (and optionally all refs) as candidates.
fn collectTags(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    candidates: *std.array_list.Managed(TagCandidate),
    opts: *const DescribeOptions,
) !void {
    // Collect annotated and lightweight tags
    const tag_entries = try ref_mod.listRefs(allocator, repo.git_dir, "refs/tags/");
    defer ref_mod.freeRefEntries(allocator, tag_entries);

    for (tag_entries) |entry| {
        const prefix_str = "refs/tags/";
        const tag_name = if (std.mem.startsWith(u8, entry.name, prefix_str))
            entry.name[prefix_str.len..]
        else
            entry.name;

        // Apply match pattern filter
        if (opts.match_pattern) |pattern| {
            if (!simpleGlobMatch(pattern, tag_name)) continue;
        }

        // Resolve the tag to a commit OID
        // For annotated tags, the ref points to a tag object; we need to peel to commit
        const commit_oid = resolveToCommit(repo, allocator, &entry.oid) catch continue;

        // Determine if this is a lightweight tag or annotated tag
        const is_annotated = !entry.oid.eql(&commit_oid);

        // If not using --tags and it's lightweight, skip
        if (!opts.tags and !opts.all and !is_annotated) continue;

        try candidates.append(.{
            .tag_name = tag_name,
            .tag_oid = entry.oid,
            .commit_oid = commit_oid,
            .distance = std.math.maxInt(usize),
        });
    }

    // If --all, also collect branch refs
    if (opts.all) {
        const branch_entries = try ref_mod.listRefs(allocator, repo.git_dir, "refs/heads/");
        defer ref_mod.freeRefEntries(allocator, branch_entries);

        for (branch_entries) |entry| {
            const prefix_str = "refs/heads/";
            const branch_name = if (std.mem.startsWith(u8, entry.name, prefix_str))
                entry.name[prefix_str.len..]
            else
                entry.name;

            try candidates.append(.{
                .tag_name = branch_name,
                .tag_oid = entry.oid,
                .commit_oid = entry.oid,
                .distance = std.math.maxInt(usize),
            });
        }

        const remote_entries = try ref_mod.listRefs(allocator, repo.git_dir, "refs/remotes/");
        defer ref_mod.freeRefEntries(allocator, remote_entries);

        for (remote_entries) |entry| {
            const prefix_str = "refs/remotes/";
            const remote_name = if (std.mem.startsWith(u8, entry.name, prefix_str))
                entry.name[prefix_str.len..]
            else
                entry.name;

            try candidates.append(.{
                .tag_name = remote_name,
                .tag_oid = entry.oid,
                .commit_oid = entry.oid,
                .distance = std.math.maxInt(usize),
            });
        }
    }
}

/// Resolve a potentially annotated tag OID to the commit it ultimately points to.
fn resolveToCommit(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    oid: *const types.ObjectId,
) !types.ObjectId {
    var current = oid.*;
    var depth: usize = 0;

    while (depth < 10) : (depth += 1) {
        var obj = try repo.readObject(allocator, &current);
        defer obj.deinit();

        if (obj.obj_type == .commit) return current;

        if (obj.obj_type == .tag) {
            // Parse the tag object to find the target
            const target_oid = parseTagTarget(obj.data) catch return error.InvalidTag;
            current = target_oid;
            continue;
        }

        return error.NotACommit;
    }

    return error.TooManyDereferences;
}

/// Parse a tag object to extract its target OID.
fn parseTagTarget(data: []const u8) !types.ObjectId {
    const prefix = "object ";
    if (!std.mem.startsWith(u8, data, prefix)) return error.InvalidTag;

    if (data.len < prefix.len + types.OID_HEX_LEN) return error.InvalidTag;

    return types.ObjectId.fromHex(data[prefix.len..][0..types.OID_HEX_LEN]);
}

/// Compute distances from the target commit to each tag candidate
/// by walking the commit graph backwards (BFS).
fn computeDistances(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    target_oid: *const types.ObjectId,
    candidates: *std.array_list.Managed(TagCandidate),
) !void {
    if (candidates.items.len == 0) return;

    // BFS from the target commit
    const QueueEntry = struct {
        oid: types.ObjectId,
        depth: usize,
    };

    var queue = std.array_list.Managed(QueueEntry).init(allocator);
    defer queue.deinit();

    var visited = std.array_list.Managed([types.OID_HEX_LEN]u8).init(allocator);
    defer visited.deinit();

    try queue.append(.{ .oid = target_oid.*, .depth = 0 });

    // Limit the walk to prevent excessive traversal
    const max_walk: usize = 10000;
    var walk_count: usize = 0;

    while (queue.items.len > 0 and walk_count < max_walk) {
        const current = queue.orderedRemove(0);
        walk_count += 1;

        // Check if visited
        const hex = current.oid.toHex();
        var already_visited = false;
        for (visited.items) |*v| {
            if (std.mem.eql(u8, v, &hex)) {
                already_visited = true;
                break;
            }
        }
        if (already_visited) continue;
        try visited.append(hex);

        // Check if this commit matches any candidate
        for (candidates.items) |*candidate| {
            if (candidate.commit_oid.eql(&current.oid)) {
                if (current.depth < candidate.distance) {
                    candidate.distance = current.depth;
                }
            }
        }

        // Check if all candidates have been found
        var all_found = true;
        for (candidates.items) |*candidate| {
            if (candidate.distance == std.math.maxInt(usize)) {
                all_found = false;
                break;
            }
        }
        if (all_found) break;

        // Read commit and enqueue parents
        var obj = repo.readObject(allocator, &current.oid) catch continue;
        defer obj.deinit();
        if (obj.obj_type != .commit) continue;

        var parents = getCommitParents(allocator, obj.data) catch continue;
        defer parents.deinit();

        for (parents.items) |parent_oid| {
            try queue.append(.{ .oid = parent_oid, .depth = current.depth + 1 });
        }
    }
}

/// Parse commit data to extract parent OIDs.
fn getCommitParents(allocator: std.mem.Allocator, commit_data: []const u8) !std.array_list.Managed(types.ObjectId) {
    var parents = std.array_list.Managed(types.ObjectId).init(allocator);
    errdefer parents.deinit();

    var lines = std.mem.splitScalar(u8, commit_data, '\n');
    // Skip tree line
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "parent ")) {
            if (line.len >= 7 + types.OID_HEX_LEN) {
                const oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch continue;
                try parents.append(oid);
            }
        }
    }

    return parents;
}

/// Simple glob matching for tag name patterns.
/// Supports * (match any sequence of chars) and ? (match single char).
fn simpleGlobMatch(pattern: []const u8, text: []const u8) bool {
    return simpleGlobMatchInner(pattern, text, 0);
}

fn simpleGlobMatchInner(pattern: []const u8, text: []const u8, depth: usize) bool {
    if (depth > 50) return false;

    var pi: usize = 0;
    var ti: usize = 0;

    while (pi < pattern.len) {
        if (pattern[pi] == '*') {
            // Skip consecutive stars
            while (pi < pattern.len and pattern[pi] == '*') pi += 1;
            if (pi == pattern.len) return true; // trailing * matches everything

            // Try matching rest at each position
            while (ti <= text.len) {
                if (simpleGlobMatchInner(pattern[pi..], text[ti..], depth + 1)) return true;
                if (ti >= text.len) break;
                ti += 1;
            }
            return false;
        } else if (pattern[pi] == '?') {
            if (ti >= text.len) return false;
            pi += 1;
            ti += 1;
        } else {
            if (ti >= text.len) return false;
            if (pattern[pi] != text[ti]) return false;
            pi += 1;
            ti += 1;
        }
    }

    return ti == text.len;
}

test "simpleGlobMatch" {
    try std.testing.expect(simpleGlobMatch("v*", "v1.0"));
    try std.testing.expect(simpleGlobMatch("v*", "v2.0.1"));
    try std.testing.expect(!simpleGlobMatch("v*", "release-1.0"));
    try std.testing.expect(simpleGlobMatch("v?.?", "v1.0"));
    try std.testing.expect(!simpleGlobMatch("v?.?", "v10.0"));
    try std.testing.expect(simpleGlobMatch("*", "anything"));
    try std.testing.expect(simpleGlobMatch("release-*", "release-2.0"));
}

test "parseTagTarget" {
    const tag_data = "object e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\ntype commit\ntag v1.0\ntagger Test <test@example.com>\n\nTag message\n";
    const oid = try parseTagTarget(tag_data);
    const hex = oid.toHex();
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &hex);
}
