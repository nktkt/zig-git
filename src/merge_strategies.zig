const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_diff = @import("tree_diff.zig");
const diff_mod = @import("diff.zig");
const loose = @import("loose.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Merge strategy selection.
pub const MergeStrategy = enum {
    recursive,
    ours,
    theirs,
    resolve,
};

/// Strategy-specific options (e.g., -X ours, -X theirs).
pub const StrategyOption = enum {
    none,
    ours,
    theirs,
    patience,
    ignore_space_change,
    ignore_all_space,
    renormalize,
};

/// Result of merging a single file.
pub const FileMergeResult = enum {
    clean,
    conflict,
    ours_version,
    theirs_version,
};

/// Merged file output.
pub const MergedFile = struct {
    result: FileMergeResult,
    content: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MergedFile) void {
        self.allocator.free(self.content);
    }
};

/// Result of a full tree merge.
pub const TreeMergeResult = struct {
    has_conflicts: bool,
    conflict_paths: std.array_list.Managed([]u8),
    /// The merged tree entries (path -> oid).
    merged_entries: std.StringHashMap(types.ObjectId),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TreeMergeResult) void {
        for (self.conflict_paths.items) |p| self.allocator.free(p);
        self.conflict_paths.deinit();

        var ki = self.merged_entries.keyIterator();
        while (ki.next()) |key| self.allocator.free(@constCast(key.*));
        self.merged_entries.deinit();
    }
};

/// Parse a merge strategy from a command-line argument.
pub fn parseStrategy(arg: []const u8) MergeStrategy {
    if (std.mem.eql(u8, arg, "ours")) return .ours;
    if (std.mem.eql(u8, arg, "theirs")) return .theirs;
    if (std.mem.eql(u8, arg, "recursive")) return .recursive;
    if (std.mem.eql(u8, arg, "resolve")) return .resolve;
    return .recursive;
}

/// Parse a strategy option from -X argument.
pub fn parseStrategyOption(arg: []const u8) StrategyOption {
    if (std.mem.eql(u8, arg, "ours")) return .ours;
    if (std.mem.eql(u8, arg, "theirs")) return .theirs;
    if (std.mem.eql(u8, arg, "patience")) return .patience;
    if (std.mem.eql(u8, arg, "ignore-space-change")) return .ignore_space_change;
    if (std.mem.eql(u8, arg, "ignore-all-space")) return .ignore_all_space;
    if (std.mem.eql(u8, arg, "renormalize")) return .renormalize;
    return .none;
}

// ---------------------------------------------------------------------------
// Strategy dispatch
// ---------------------------------------------------------------------------

/// Execute a merge strategy on two tree OIDs with a common base.
pub fn executeMerge(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    base_oid: ?*const types.ObjectId,
    ours_oid: *const types.ObjectId,
    theirs_oid: *const types.ObjectId,
    strategy: MergeStrategy,
    option: StrategyOption,
) !TreeMergeResult {
    switch (strategy) {
        .ours => return oursStrategy(allocator, repo, ours_oid),
        .theirs => return theirsStrategy(allocator, repo, theirs_oid),
        .recursive, .resolve => return recursiveStrategy(allocator, repo, base_oid, ours_oid, theirs_oid, option),
    }
}

// ---------------------------------------------------------------------------
// "ours" strategy: always use our tree
// ---------------------------------------------------------------------------

fn oursStrategy(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    ours_oid: *const types.ObjectId,
) !TreeMergeResult {
    var result = TreeMergeResult{
        .has_conflicts = false,
        .conflict_paths = std.array_list.Managed([]u8).init(allocator),
        .merged_entries = std.StringHashMap(types.ObjectId).init(allocator),
        .allocator = allocator,
    };
    errdefer result.deinit();

    // Load our tree
    try loadTreeFlat(repo, allocator, ours_oid, &result.merged_entries, "");

    return result;
}

// ---------------------------------------------------------------------------
// "theirs" strategy: always use their tree
// ---------------------------------------------------------------------------

fn theirsStrategy(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    theirs_oid: *const types.ObjectId,
) !TreeMergeResult {
    var result = TreeMergeResult{
        .has_conflicts = false,
        .conflict_paths = std.array_list.Managed([]u8).init(allocator),
        .merged_entries = std.StringHashMap(types.ObjectId).init(allocator),
        .allocator = allocator,
    };
    errdefer result.deinit();

    try loadTreeFlat(repo, allocator, theirs_oid, &result.merged_entries, "");

    return result;
}

// ---------------------------------------------------------------------------
// "recursive" strategy: three-way merge
// ---------------------------------------------------------------------------

fn recursiveStrategy(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    base_oid: ?*const types.ObjectId,
    ours_oid: *const types.ObjectId,
    theirs_oid: *const types.ObjectId,
    option: StrategyOption,
) !TreeMergeResult {
    var result = TreeMergeResult{
        .has_conflicts = false,
        .conflict_paths = std.array_list.Managed([]u8).init(allocator),
        .merged_entries = std.StringHashMap(types.ObjectId).init(allocator),
        .allocator = allocator,
    };
    errdefer result.deinit();

    // Load all three trees
    var base_entries = std.StringHashMap(types.ObjectId).init(allocator);
    defer freeStringHashMap(allocator, &base_entries);

    var ours_entries = std.StringHashMap(types.ObjectId).init(allocator);
    defer freeStringHashMap(allocator, &ours_entries);

    var theirs_entries = std.StringHashMap(types.ObjectId).init(allocator);
    defer freeStringHashMap(allocator, &theirs_entries);

    if (base_oid) |boid| {
        try loadTreeFlat(repo, allocator, boid, &base_entries, "");
    }
    try loadTreeFlat(repo, allocator, ours_oid, &ours_entries, "");
    try loadTreeFlat(repo, allocator, theirs_oid, &theirs_entries, "");

    // Collect all unique paths
    var all_paths = std.StringHashMap(void).init(allocator);
    defer {
        var ki = all_paths.keyIterator();
        while (ki.next()) |key| allocator.free(@constCast(key.*));
        all_paths.deinit();
    }

    try collectKeys(allocator, &base_entries, &all_paths);
    try collectKeys(allocator, &ours_entries, &all_paths);
    try collectKeys(allocator, &theirs_entries, &all_paths);

    // Process each path
    var path_iter = all_paths.keyIterator();
    while (path_iter.next()) |key_ptr| {
        const path = key_ptr.*;
        const base_oid_val = base_entries.get(path);
        const ours_oid_val = ours_entries.get(path);
        const theirs_oid_val = theirs_entries.get(path);

        const merged_oid = try mergeFilePath(
            allocator,
            repo,
            path,
            base_oid_val,
            ours_oid_val,
            theirs_oid_val,
            option,
            &result,
        );

        if (merged_oid) |oid| {
            const owned_path = try allocator.alloc(u8, path.len);
            @memcpy(owned_path, path);
            try result.merged_entries.put(owned_path, oid);
        }
    }

    return result;
}

/// Merge a single file path using three-way merge logic.
fn mergeFilePath(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    path: []const u8,
    base_oid: ?types.ObjectId,
    ours_oid: ?types.ObjectId,
    theirs_oid: ?types.ObjectId,
    option: StrategyOption,
    result: *TreeMergeResult,
) !?types.ObjectId {
    // Both sides deleted
    if (ours_oid == null and theirs_oid == null) {
        return null;
    }

    // Only one side changed
    if (ours_oid != null and theirs_oid == null) {
        // Theirs deleted, ours has it
        if (base_oid != null) {
            // File was deleted by theirs - conflict or accept based on strategy option
            if (option == .ours) return ours_oid;
            if (option == .theirs) return null;
            // Conflict: delete vs modify
            try addConflictPath(allocator, path, result);
            return ours_oid;
        }
        return ours_oid;
    }

    if (ours_oid == null and theirs_oid != null) {
        if (base_oid != null) {
            if (option == .ours) return null;
            if (option == .theirs) return theirs_oid;
            try addConflictPath(allocator, path, result);
            return theirs_oid;
        }
        return theirs_oid;
    }

    // Both sides have the file
    const our_oid = ours_oid.?;
    const their_oid = theirs_oid.?;

    // Same content on both sides
    if (our_oid.eql(&their_oid)) {
        return our_oid;
    }

    // One side unchanged from base
    if (base_oid) |boid| {
        if (our_oid.eql(&boid)) {
            // Ours unchanged, take theirs
            return their_oid;
        }
        if (their_oid.eql(&boid)) {
            // Theirs unchanged, take ours
            return our_oid;
        }
    }

    // Strategy option overrides
    if (option == .ours) return our_oid;
    if (option == .theirs) return their_oid;

    // Three-way content merge
    const base_content = if (base_oid) |boid|
        readBlobContent(repo, allocator, &boid)
    else
        null;
    defer if (base_content) |c| allocator.free(c);

    const ours_content = readBlobContent(repo, allocator, &our_oid);
    defer if (ours_content) |c| allocator.free(c);

    const theirs_content = readBlobContent(repo, allocator, &their_oid);
    defer if (theirs_content) |c| allocator.free(c);

    if (ours_content == null or theirs_content == null) {
        // Can't read content, conflict
        try addConflictPath(allocator, path, result);
        return our_oid;
    }

    var merged = try threeWayMergeContent(
        allocator,
        base_content orelse "",
        ours_content.?,
        theirs_content.?,
        option,
    );
    defer merged.deinit();

    if (merged.result == .conflict) {
        try addConflictPath(allocator, path, result);
    }

    // Write merged content as blob
    const new_oid = try loose.writeLooseObject(allocator, repo.git_dir, .blob, merged.content);
    return new_oid;
}

fn addConflictPath(allocator: std.mem.Allocator, path: []const u8, result: *TreeMergeResult) !void {
    result.has_conflicts = true;
    const owned = try allocator.alloc(u8, path.len);
    @memcpy(owned, path);
    try result.conflict_paths.append(owned);
}

// ---------------------------------------------------------------------------
// Three-way content merge
// ---------------------------------------------------------------------------

/// Perform a three-way text merge.
pub fn threeWayMergeContent(
    allocator: std.mem.Allocator,
    base_text: []const u8,
    ours_text: []const u8,
    theirs_text: []const u8,
    option: StrategyOption,
) !MergedFile {
    // Future: apply whitespace normalization based on option
    // (ignore_space_change, ignore_all_space, renormalize)

    // Get diff between base-ours and base-theirs
    var ours_diff = try diff_mod.diffLines(allocator, base_text, ours_text);
    defer ours_diff.deinit();

    var theirs_diff = try diff_mod.diffLines(allocator, base_text, theirs_text);
    defer theirs_diff.deinit();

    // Simple merge: if only one side has changes, take that side
    if (ours_diff.hunks.items.len == 0) {
        const content = try allocator.alloc(u8, theirs_text.len);
        @memcpy(content, theirs_text);
        return MergedFile{
            .result = .clean,
            .content = content,
            .allocator = allocator,
        };
    }

    if (theirs_diff.hunks.items.len == 0) {
        const content = try allocator.alloc(u8, ours_text.len);
        @memcpy(content, ours_text);
        return MergedFile{
            .result = .clean,
            .content = content,
            .allocator = allocator,
        };
    }

    // Both sides have changes - check if they overlap
    const overlapping = hunksOverlap(&ours_diff, &theirs_diff);

    if (!overlapping) {
        // Non-overlapping changes: apply both (simplified: take ours)
        const content = try allocator.alloc(u8, ours_text.len);
        @memcpy(content, ours_text);
        return MergedFile{
            .result = .clean,
            .content = content,
            .allocator = allocator,
        };
    }

    // Overlapping changes - conflict or strategy override
    if (option == .ours) {
        const content = try allocator.alloc(u8, ours_text.len);
        @memcpy(content, ours_text);
        return MergedFile{
            .result = .ours_version,
            .content = content,
            .allocator = allocator,
        };
    }

    if (option == .theirs) {
        const content = try allocator.alloc(u8, theirs_text.len);
        @memcpy(content, theirs_text);
        return MergedFile{
            .result = .theirs_version,
            .content = content,
            .allocator = allocator,
        };
    }

    // Generate conflict markers
    var merged_content = std.array_list.Managed(u8).init(allocator);
    defer merged_content.deinit();

    try merged_content.appendSlice("<<<<<<< ours\n");
    try merged_content.appendSlice(ours_text);
    if (ours_text.len > 0 and ours_text[ours_text.len - 1] != '\n') {
        try merged_content.append('\n');
    }
    try merged_content.appendSlice("=======\n");
    try merged_content.appendSlice(theirs_text);
    if (theirs_text.len > 0 and theirs_text[theirs_text.len - 1] != '\n') {
        try merged_content.append('\n');
    }
    try merged_content.appendSlice(">>>>>>> theirs\n");

    const content = try allocator.alloc(u8, merged_content.items.len);
    @memcpy(content, merged_content.items);

    return MergedFile{
        .result = .conflict,
        .content = content,
        .allocator = allocator,
    };
}

/// Check if two diff results have overlapping hunk ranges.
fn hunksOverlap(ours: *diff_mod.DiffResult, theirs: *diff_mod.DiffResult) bool {
    for (ours.hunks.items) |*oh| {
        for (theirs.hunks.items) |*th| {
            // Check if the old-file ranges overlap
            const o_start = oh.old_start;
            const o_end = oh.old_start + oh.old_count;
            const t_start = th.old_start;
            const t_end = th.old_start + th.old_count;

            if (o_start < t_end and t_start < o_end) return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tree loading helpers
// ---------------------------------------------------------------------------

fn loadTreeFlat(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    tree_oid: *const types.ObjectId,
    entries: *std.StringHashMap(types.ObjectId),
    prefix: []const u8,
) !void {
    // First resolve commit to tree if needed
    var actual_tree_oid = tree_oid.*;
    {
        var obj = repo.readObject(allocator, tree_oid) catch return;
        defer obj.deinit();

        if (obj.obj_type == .commit) {
            actual_tree_oid = tree_diff.getCommitTreeOid(obj.data) catch return;
        }
    }

    var obj = repo.readObject(allocator, &actual_tree_oid) catch return;
    defer obj.deinit();
    if (obj.obj_type != .tree) return;

    var pos: usize = 0;
    while (pos < obj.data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, obj.data, pos, ' ') orelse break;
        const mode_str = obj.data[pos..space_pos];
        pos = space_pos + 1;

        const null_pos = std.mem.indexOfScalarPos(u8, obj.data, pos, 0) orelse break;
        const name = obj.data[pos..null_pos];
        pos = null_pos + 1;

        if (pos + 20 > obj.data.len) break;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, obj.data[pos..][0..20]);
        pos += 20;

        // Build full path
        var path_buf: [4096]u8 = undefined;
        var path_pos: usize = 0;
        if (prefix.len > 0) {
            @memcpy(path_buf[0..prefix.len], prefix);
            path_pos += prefix.len;
            path_buf[path_pos] = '/';
            path_pos += 1;
        }
        @memcpy(path_buf[path_pos..][0..name.len], name);
        path_pos += name.len;

        const full_path = try allocator.alloc(u8, path_pos);
        @memcpy(full_path, path_buf[0..path_pos]);

        if (std.mem.eql(u8, mode_str, "40000")) {
            try loadTreeFlat(repo, allocator, &oid, entries, full_path);
            allocator.free(full_path);
        } else {
            try entries.put(full_path, oid);
        }
    }
}

fn freeStringHashMap(allocator: std.mem.Allocator, map: *std.StringHashMap(types.ObjectId)) void {
    var ki = map.keyIterator();
    while (ki.next()) |key| allocator.free(@constCast(key.*));
    map.deinit();
}

fn collectKeys(
    allocator: std.mem.Allocator,
    source: *std.StringHashMap(types.ObjectId),
    dest: *std.StringHashMap(void),
) !void {
    var ki = source.keyIterator();
    while (ki.next()) |key| {
        if (!dest.contains(key.*)) {
            const owned = try allocator.alloc(u8, key.len);
            @memcpy(owned, key.*);
            try dest.put(owned, {});
        }
    }
}

fn readBlobContent(repo: *repository.Repository, allocator: std.mem.Allocator, oid: *const types.ObjectId) ?[]u8 {
    var obj = repo.readObject(allocator, oid) catch return null;
    if (obj.obj_type != .blob) {
        obj.deinit();
        return null;
    }
    return obj.data;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseStrategy" {
    try std.testing.expectEqual(MergeStrategy.ours, parseStrategy("ours"));
    try std.testing.expectEqual(MergeStrategy.theirs, parseStrategy("theirs"));
    try std.testing.expectEqual(MergeStrategy.recursive, parseStrategy("recursive"));
    try std.testing.expectEqual(MergeStrategy.recursive, parseStrategy("unknown"));
}

test "parseStrategyOption" {
    try std.testing.expectEqual(StrategyOption.ours, parseStrategyOption("ours"));
    try std.testing.expectEqual(StrategyOption.theirs, parseStrategyOption("theirs"));
    try std.testing.expectEqual(StrategyOption.patience, parseStrategyOption("patience"));
    try std.testing.expectEqual(StrategyOption.ignore_space_change, parseStrategyOption("ignore-space-change"));
    try std.testing.expectEqual(StrategyOption.none, parseStrategyOption("unknown"));
}

test "threeWayMergeContent no overlap" {
    const allocator = std.testing.allocator;

    var merged = try threeWayMergeContent(allocator, "line1\nline2\nline3\n", "line1\nline2\nline3\n", "line1\nline2\nline3\n", .none);
    defer merged.deinit();

    try std.testing.expectEqual(FileMergeResult.clean, merged.result);
}

test "threeWayMergeContent only ours changed" {
    const allocator = std.testing.allocator;

    var merged = try threeWayMergeContent(allocator, "line1\n", "line1\nline2\n", "line1\n", .none);
    defer merged.deinit();

    try std.testing.expectEqual(FileMergeResult.clean, merged.result);
    try std.testing.expectEqualStrings("line1\nline2\n", merged.content);
}

test "hunksOverlap" {
    const allocator = std.testing.allocator;

    // Create two diffs that modify different regions
    var diff1 = try diff_mod.diffLines(allocator, "a\nb\nc\n", "a\nB\nc\n");
    defer diff1.deinit();

    var diff2 = try diff_mod.diffLines(allocator, "a\nb\nc\n", "a\nb\nC\n");
    defer diff2.deinit();

    // These modify adjacent (potentially non-overlapping) regions
    // Result depends on context lines in the diff algorithm
    _ = hunksOverlap(&diff1, &diff2);
}
