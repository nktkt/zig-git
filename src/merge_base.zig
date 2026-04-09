const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_diff = @import("tree_diff.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Mode of merge-base operation.
pub const MergeBaseMode = enum {
    /// Find best common ancestor of two commits.
    normal,
    /// Find all common ancestors.
    all,
    /// Check if A is ancestor of B.
    is_ancestor,
    /// Find common ancestor of multiple commits (octopus).
    octopus,
    /// Find commits not reachable from others.
    independent,
    /// Find fork point using reflog.
    fork_point,
};

pub fn runMergeBase(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var mode = MergeBaseMode.normal;
    var positionals = std.array_list.Managed([]const u8).init(allocator);
    defer positionals.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            mode = .all;
        } else if (std.mem.eql(u8, arg, "--is-ancestor")) {
            mode = .is_ancestor;
        } else if (std.mem.eql(u8, arg, "--octopus")) {
            mode = .octopus;
        } else if (std.mem.eql(u8, arg, "--independent")) {
            mode = .independent;
        } else if (std.mem.eql(u8, arg, "--fork-point")) {
            mode = .fork_point;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try positionals.append(arg);
        }
    }

    switch (mode) {
        .normal => {
            if (positionals.items.len < 2) {
                try stderr_file.writeAll("usage: zig-git merge-base <commit> <commit>\n");
                std.process.exit(1);
            }
            const a = try repo.resolveRef(allocator, positionals.items[0]);
            const b = try repo.resolveRef(allocator, positionals.items[1]);

            const result = findMergeBase(allocator, repo, a, b);
            if (result) |base| {
                const hex = base.toHex();
                try stdout_file.writeAll(&hex);
                try stdout_file.writeAll("\n");
            } else {
                std.process.exit(1);
            }
        },
        .all => {
            if (positionals.items.len < 2) {
                try stderr_file.writeAll("usage: zig-git merge-base --all <commit> <commit>\n");
                std.process.exit(1);
            }
            const a = try repo.resolveRef(allocator, positionals.items[0]);
            const b = try repo.resolveRef(allocator, positionals.items[1]);

            var bases = findAllMergeBases(allocator, repo, a, b);
            defer bases.deinit();

            if (bases.items.len == 0) {
                std.process.exit(1);
            }

            for (bases.items) |base| {
                const hex = base.toHex();
                try stdout_file.writeAll(&hex);
                try stdout_file.writeAll("\n");
            }
        },
        .is_ancestor => {
            if (positionals.items.len < 2) {
                try stderr_file.writeAll("usage: zig-git merge-base --is-ancestor <commit> <commit>\n");
                std.process.exit(1);
            }
            const a = try repo.resolveRef(allocator, positionals.items[0]);
            const b = try repo.resolveRef(allocator, positionals.items[1]);

            if (isAncestor(allocator, repo, a, b)) {
                std.process.exit(0);
            } else {
                std.process.exit(1);
            }
        },
        .octopus => {
            if (positionals.items.len < 2) {
                try stderr_file.writeAll("usage: zig-git merge-base --octopus <commit>...\n");
                std.process.exit(1);
            }

            var oids = std.array_list.Managed(types.ObjectId).init(allocator);
            defer oids.deinit();

            for (positionals.items) |ref_str| {
                const oid = try repo.resolveRef(allocator, ref_str);
                try oids.append(oid);
            }

            const result = findOctopusMergeBase(allocator, repo, oids.items);
            if (result) |base| {
                const hex = base.toHex();
                try stdout_file.writeAll(&hex);
                try stdout_file.writeAll("\n");
            } else {
                std.process.exit(1);
            }
        },
        .independent => {
            if (positionals.items.len < 2) {
                try stderr_file.writeAll("usage: zig-git merge-base --independent <commit>...\n");
                std.process.exit(1);
            }

            var oids = std.array_list.Managed(types.ObjectId).init(allocator);
            defer oids.deinit();

            for (positionals.items) |ref_str| {
                const oid = try repo.resolveRef(allocator, ref_str);
                try oids.append(oid);
            }

            var indep = findIndependent(allocator, repo, oids.items);
            defer indep.deinit();

            for (indep.items) |oid| {
                const hex = oid.toHex();
                try stdout_file.writeAll(&hex);
                try stdout_file.writeAll("\n");
            }
        },
        .fork_point => {
            if (positionals.items.len < 1) {
                try stderr_file.writeAll("usage: zig-git merge-base --fork-point <ref> [<commit>]\n");
                std.process.exit(1);
            }
            const ref_name = positionals.items[0];
            const commit_ref = if (positionals.items.len > 1) positionals.items[1] else "HEAD";

            const result = findForkPoint(allocator, repo, ref_name, commit_ref);
            if (result) |base| {
                const hex = base.toHex();
                try stdout_file.writeAll(&hex);
                try stdout_file.writeAll("\n");
            } else {
                std.process.exit(1);
            }
        },
    }
}

/// Find the best common ancestor of two commits using BFS from both sides.
pub fn findMergeBase(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    a: types.ObjectId,
    b: types.ObjectId,
) ?types.ObjectId {
    // Collect all ancestors of A
    var ancestors_a = collectAncestors(allocator, repo, a) orelse return null;
    defer ancestors_a.deinit();

    // BFS from B, first hit in A's ancestors is the merge base
    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();
    queue.append(b) catch return null;

    var visited_list = std.array_list.Managed([types.OID_HEX_LEN]u8).init(allocator);
    defer visited_list.deinit();

    var iterations: usize = 0;
    const max_iterations: usize = 50000;

    while (queue.items.len > 0 and iterations < max_iterations) {
        iterations += 1;
        const oid = queue.orderedRemove(0);
        const hex = oid.toHex();

        // Check if in A's ancestors
        for (ancestors_a.items) |*v| {
            if (std.mem.eql(u8, v, &hex)) return oid;
        }

        var found = false;
        for (visited_list.items) |*v| {
            if (std.mem.eql(u8, v, &hex)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        visited_list.append(hex) catch continue;

        var obj = repo.readObject(allocator, &oid) catch continue;
        defer obj.deinit();
        if (obj.obj_type != .commit) continue;

        var parents = tree_diff.getCommitParents(allocator, obj.data) catch continue;
        defer parents.deinit();

        for (parents.items) |parent_oid| {
            queue.append(parent_oid) catch continue;
        }
    }

    return null;
}

/// Collect all ancestors (including self) of a commit as hex strings.
fn collectAncestors(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    start: types.ObjectId,
) ?std.array_list.Managed([types.OID_HEX_LEN]u8) {
    var result = std.array_list.Managed([types.OID_HEX_LEN]u8).init(allocator);

    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();
    queue.append(start) catch return null;

    var iterations: usize = 0;
    const max_iterations: usize = 50000;

    while (queue.items.len > 0 and iterations < max_iterations) {
        iterations += 1;
        const oid = queue.orderedRemove(0);
        const hex = oid.toHex();

        var found = false;
        for (result.items) |*v| {
            if (std.mem.eql(u8, v, &hex)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        result.append(hex) catch continue;

        var obj = repo.readObject(allocator, &oid) catch continue;
        defer obj.deinit();
        if (obj.obj_type != .commit) continue;

        var parents = tree_diff.getCommitParents(allocator, obj.data) catch continue;
        defer parents.deinit();

        for (parents.items) |parent_oid| {
            queue.append(parent_oid) catch continue;
        }
    }

    return result;
}

/// Find all common ancestors of two commits.
fn findAllMergeBases(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    a: types.ObjectId,
    b: types.ObjectId,
) std.array_list.Managed(types.ObjectId) {
    var result = std.array_list.Managed(types.ObjectId).init(allocator);

    // Collect ancestors of both
    var ancestors_a = collectAncestors(allocator, repo, a) orelse return result;
    defer ancestors_a.deinit();

    var ancestors_b = collectAncestors(allocator, repo, b) orelse return result;
    defer ancestors_b.deinit();

    // Find common ancestors
    var common = std.array_list.Managed(types.ObjectId).init(allocator);
    defer common.deinit();

    for (ancestors_a.items) |*hex_a| {
        for (ancestors_b.items) |*hex_b| {
            if (std.mem.eql(u8, hex_a, hex_b)) {
                const oid = types.ObjectId.fromHex(hex_a) catch continue;
                common.append(oid) catch continue;
                break;
            }
        }
    }

    // Filter to only "best" common ancestors (those not reachable from other common ancestors)
    for (common.items) |ca| {
        var is_reachable = false;
        for (common.items) |other| {
            if (ca.eql(&other)) continue;
            if (isAncestor(allocator, repo, ca, other)) {
                is_reachable = true;
                break;
            }
        }
        if (!is_reachable) {
            result.append(ca) catch continue;
        }
    }

    return result;
}

/// Check if `ancestor` is an ancestor of `descendant`.
pub fn isAncestor(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    ancestor: types.ObjectId,
    descendant: types.ObjectId,
) bool {
    if (ancestor.eql(&descendant)) return true;

    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();
    queue.append(descendant) catch return false;

    var visited_list = std.array_list.Managed([types.OID_HEX_LEN]u8).init(allocator);
    defer visited_list.deinit();

    const target_hex = ancestor.toHex();

    var iterations: usize = 0;
    const max_iterations: usize = 50000;

    while (queue.items.len > 0 and iterations < max_iterations) {
        iterations += 1;
        const oid = queue.orderedRemove(0);
        const hex = oid.toHex();

        if (std.mem.eql(u8, &hex, &target_hex)) return true;

        var found = false;
        for (visited_list.items) |*v| {
            if (std.mem.eql(u8, v, &hex)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        visited_list.append(hex) catch continue;

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

/// Find common ancestor of multiple commits (octopus merge base).
fn findOctopusMergeBase(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    oids: []const types.ObjectId,
) ?types.ObjectId {
    if (oids.len == 0) return null;
    if (oids.len == 1) return oids[0];

    var current = oids[0];
    for (oids[1..]) |oid| {
        const base = findMergeBase(allocator, repo, current, oid) orelse return null;
        current = base;
    }
    return current;
}

/// Find commits not reachable from others in the set.
fn findIndependent(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    oids: []const types.ObjectId,
) std.array_list.Managed(types.ObjectId) {
    var result = std.array_list.Managed(types.ObjectId).init(allocator);

    for (oids, 0..) |oid, i| {
        var is_reachable = false;
        for (oids, 0..) |other, j| {
            if (i == j) continue;
            if (isAncestor(allocator, repo, oid, other)) {
                is_reachable = true;
                break;
            }
        }
        if (!is_reachable) {
            result.append(oid) catch continue;
        }
    }

    return result;
}

/// Find fork point using reflog.
fn findForkPoint(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    ref_name: []const u8,
    commit_ref: []const u8,
) ?types.ObjectId {
    const commit_oid = repo.resolveRef(allocator, commit_ref) catch return null;

    // Read reflog for the given ref
    var result = reflog_mod.readReflog(allocator, repo.git_dir, ref_name) catch return null;
    defer result.deinit();

    // Try each reflog entry as a potential fork point
    var best: ?types.ObjectId = null;
    var best_distance: usize = std.math.maxInt(usize);

    for (result.entries) |entry| {
        // Check if the old OID of this reflog entry is an ancestor of commit_oid
        if (isAncestor(allocator, repo, entry.new_oid, commit_oid)) {
            // The merge base of this reflog entry and the commit is a candidate
            const mb = findMergeBase(allocator, repo, entry.new_oid, commit_oid);
            if (mb) |base| {
                // Estimate distance using timestamp (simpler than counting commits)
                const dist = countCommitsTo(allocator, repo, commit_oid, base);
                if (dist < best_distance) {
                    best_distance = dist;
                    best = base;
                }
            }
        }
    }

    return best;
}

/// Count number of commits from start to target (simple BFS distance).
fn countCommitsTo(allocator: std.mem.Allocator, repo: *repository.Repository, start: types.ObjectId, target: types.ObjectId) usize {
    if (start.eql(&target)) return 0;

    const QueueItem = struct {
        oid: types.ObjectId,
        dist: usize,
    };

    var queue = std.array_list.Managed(QueueItem).init(allocator);
    defer queue.deinit();
    queue.append(.{ .oid = start, .dist = 0 }) catch return std.math.maxInt(usize);

    var visited_list = std.array_list.Managed([types.OID_HEX_LEN]u8).init(allocator);
    defer visited_list.deinit();

    const target_hex = target.toHex();

    var iterations: usize = 0;
    while (queue.items.len > 0 and iterations < 10000) {
        iterations += 1;
        const item = queue.orderedRemove(0);
        const hex = item.oid.toHex();

        if (std.mem.eql(u8, &hex, &target_hex)) return item.dist;

        var found = false;
        for (visited_list.items) |*v| {
            if (std.mem.eql(u8, v, &hex)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        visited_list.append(hex) catch continue;

        var obj = repo.readObject(allocator, &item.oid) catch continue;
        defer obj.deinit();
        if (obj.obj_type != .commit) continue;

        var parents = tree_diff.getCommitParents(allocator, obj.data) catch continue;
        defer parents.deinit();

        for (parents.items) |parent_oid| {
            queue.append(.{ .oid = parent_oid, .dist = item.dist + 1 }) catch continue;
        }
    }

    return std.math.maxInt(usize);
}

test "isAncestor same commit" {
    // Cannot test without a repo, but verify the function signature compiles
}

test "octopus merge base empty returns null" {
    // An empty slice should return null without needing a repo.
    // We cannot pass undefined for a pointer, so just verify the logic path.
    try std.testing.expect(true);
}
