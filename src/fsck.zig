const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const loose = @import("loose.zig");
const hash_mod = @import("hash.zig");
const compress = @import("compress.zig");
const ref_mod = @import("ref.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const fsck_usage =
    \\usage: zig-git fsck [options]
    \\
    \\  --full           Check not just objects in GIT_OBJECT_DIRECTORY, but also
    \\                   objects found via alternate object databases
    \\  --strict         Enable more strict checking
    \\  --no-dangling    Do not report dangling objects
    \\  --connectivity-only  Check only connectivity, not object contents
    \\  --verbose        Be more verbose
    \\  --progress       Show progress information
    \\  --unreachable    Show unreachable objects
    \\  --root           Report root (parentless) commits as dangling
    \\
;

/// Options for the fsck command.
const FsckOptions = struct {
    /// Enable full checking.
    full: bool = false,
    /// Enable strict checking.
    strict: bool = false,
    /// Report dangling objects.
    report_dangling: bool = true,
    /// Check only connectivity.
    connectivity_only: bool = false,
    /// Verbose output.
    verbose: bool = false,
    /// Show unreachable objects.
    show_unreachable: bool = false,
    /// Report root commits.
    report_root: bool = false,
};

/// Severity of an fsck issue.
const IssueSeverity = enum {
    info,
    warning,
    @"error",
};

/// A single fsck issue found during verification.
const FsckIssue = struct {
    severity: IssueSeverity,
    message: []const u8,
};

/// Entry point for the fsck command.
pub fn runFsck(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = FsckOptions{};

    // Parse arguments
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--full")) {
            opts.full = true;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            opts.strict = true;
        } else if (std.mem.eql(u8, arg, "--no-dangling")) {
            opts.report_dangling = false;
        } else if (std.mem.eql(u8, arg, "--connectivity-only")) {
            opts.connectivity_only = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--unreachable")) {
            opts.show_unreachable = true;
        } else if (std.mem.eql(u8, arg, "--root")) {
            opts.report_root = true;
        }
    }

    // Collect all known objects
    var all_objects = std.array_list.Managed(ObjectInfo).init(allocator);
    defer all_objects.deinit();

    // Collect all referenced OIDs (objects referenced by other objects)
    var referenced_oids = std.array_list.Managed([types.OID_HEX_LEN]u8).init(allocator);
    defer referenced_oids.deinit();

    // Collect all reachable OIDs (from refs)
    var reachable_oids = std.array_list.Managed([types.OID_HEX_LEN]u8).init(allocator);
    defer reachable_oids.deinit();

    var issues = std.array_list.Managed(FsckIssue).init(allocator);
    defer {
        for (issues.items) |issue| allocator.free(@constCast(issue.message));
        issues.deinit();
    }

    var issue_strings = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (issue_strings.items) |s| allocator.free(s);
        issue_strings.deinit();
    }

    // Phase 1: Enumerate all loose objects
    try enumerateLooseObjects(allocator, repo.git_dir, &all_objects);

    // Phase 2: Enumerate packed objects
    try enumeratePackedObjects(repo, &all_objects);

    if (opts.verbose) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Checking {d} objects...\n", .{all_objects.items.len}) catch "Checking objects...\n";
        try stderr_file.writeAll(msg);
    }

    // Phase 3: Verify each object
    var error_count: usize = 0;
    var warning_count: usize = 0;

    if (!opts.connectivity_only) {
        for (all_objects.items) |*obj_info| {
            try verifyObject(repo, allocator, obj_info, &referenced_oids, &error_count, &warning_count, &opts, &issue_strings);
        }
    }

    // Phase 4: Check refs point to valid objects
    try verifyRefs(repo, allocator, &reachable_oids, &error_count, &issue_strings);

    // Phase 5: Check connectivity (all referenced objects exist)
    try checkConnectivity(repo, allocator, &all_objects, &referenced_oids, &error_count, &issue_strings);

    // Phase 6: Find dangling objects (objects not referenced by anything reachable)
    if (opts.report_dangling or opts.show_unreachable) {
        try findDanglingObjects(allocator, &all_objects, &reachable_oids, &referenced_oids, &opts, &issue_strings, repo);
    }

    // Print all collected issues
    for (issue_strings.items) |msg| {
        try stdout_file.writeAll(msg);
    }

    // Summary
    if (error_count == 0 and warning_count == 0) {
        if (opts.verbose) {
            try stdout_file.writeAll("Checking object directories: done.\n");
        }
    }

    if (error_count > 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Checking objects: {d} error(s) found.\n", .{error_count}) catch "Checking objects: errors found.\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    }
}

/// Information about a discovered object.
const ObjectInfo = struct {
    oid: types.ObjectId,
    obj_type: types.ObjectType,
    /// Whether this is a loose object (vs packed).
    is_loose: bool,
    /// Whether sha verification passed.
    verified: bool,
};

/// Enumerate all loose objects in .git/objects/.
fn enumerateLooseObjects(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    objects: *std.array_list.Managed(ObjectInfo),
) !void {
    var objects_path_buf: [4096]u8 = undefined;
    const objects_path = buildPath(&objects_path_buf, git_dir, "/objects");

    var dir = std.fs.openDirAbsolute(objects_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len != 2) continue;

        // Validate hex
        if (!isHexChar(entry.name[0]) or !isHexChar(entry.name[1])) continue;

        var fanout_path_buf: [4096]u8 = undefined;
        const fanout_path = buildPath2(&fanout_path_buf, objects_path, "/", entry.name);

        var fanout_dir = std.fs.openDirAbsolute(fanout_path, .{ .iterate = true }) catch continue;
        defer fanout_dir.close();

        var fanout_iter = fanout_dir.iterate();
        while (try fanout_iter.next()) |obj_entry| {
            if (obj_entry.kind != .file) continue;
            if (obj_entry.name.len != types.OID_HEX_LEN - 2) continue;

            // Reconstruct full hex OID
            var full_hex: [types.OID_HEX_LEN]u8 = undefined;
            full_hex[0] = entry.name[0];
            full_hex[1] = entry.name[1];
            @memcpy(full_hex[2..], obj_entry.name[0 .. types.OID_HEX_LEN - 2]);

            const oid = types.ObjectId.fromHex(&full_hex) catch continue;

            // Read the object to determine its type
            var obj = loose.readLooseObject(allocator, git_dir, &oid) catch {
                try objects.append(.{
                    .oid = oid,
                    .obj_type = .blob,
                    .is_loose = true,
                    .verified = false,
                });
                continue;
            };
            const obj_type = obj.obj_type;
            obj.deinit();

            try objects.append(.{
                .oid = oid,
                .obj_type = obj_type,
                .is_loose = true,
                .verified = true,
            });
        }
    }
}

/// Enumerate packed objects.
fn enumeratePackedObjects(
    repo: *repository.Repository,
    objects: *std.array_list.Managed(ObjectInfo),
) !void {
    for (repo.packs.items) |*pack_entry| {
        var idx_iter = pack_entry.pack.idx.iterator();
        while (idx_iter.next()) |item| {
            try objects.append(.{
                .oid = item.oid,
                .obj_type = .blob, // We don't know the type yet without reading
                .is_loose = false,
                .verified = true, // Pack integrity is checked separately
            });
        }
    }
}

/// Verify a single object's integrity and collect its references.
fn verifyObject(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    obj_info: *ObjectInfo,
    referenced_oids: *std.array_list.Managed([types.OID_HEX_LEN]u8),
    error_count: *usize,
    warning_count: *usize,
    opts: *const FsckOptions,
    issue_strings: *std.array_list.Managed([]u8),
) !void {
    _ = warning_count;

    // Read and verify the object
    var obj = repo.readObject(allocator, &obj_info.oid) catch {
        const hex = obj_info.oid.toHex();
        const msg = try std.fmt.allocPrint(allocator, "error: object {s} is corrupted\n", .{&hex});
        try issue_strings.append(msg);
        error_count.* += 1;
        return;
    };
    defer obj.deinit();

    obj_info.obj_type = obj.obj_type;

    // If loose, verify SHA-1 matches content
    if (obj_info.is_loose) {
        try verifyLooseSha(allocator, repo.git_dir, obj_info, error_count, issue_strings);
    }

    // Extract references from the object
    switch (obj.obj_type) {
        .commit => {
            try extractCommitRefs(allocator, obj.data, referenced_oids, error_count, obj_info, opts, issue_strings);
        },
        .tree => {
            try extractTreeRefs(allocator, obj.data, referenced_oids, error_count, obj_info, issue_strings);
        },
        .tag => {
            try extractTagRefs(allocator, obj.data, referenced_oids, error_count, obj_info, issue_strings);
        },
        .blob => {
            // Blobs don't reference other objects
        },
    }
}

/// Verify that a loose object's SHA-1 matches its content.
fn verifyLooseSha(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    obj_info: *const ObjectInfo,
    error_count: *usize,
    issue_strings: *std.array_list.Managed([]u8),
) !void {
    // Read the raw compressed file
    var path_buf: [512]u8 = undefined;
    const rel_path = obj_info.oid.loosePath(&path_buf) catch return;

    var full_path_buf: [1024]u8 = undefined;
    const full_path = buildPath2(&full_path_buf, git_dir, "/", rel_path);

    const file = std.fs.openFileAbsolute(full_path, .{}) catch return;
    defer file.close();

    const stat = try file.stat();
    const compressed = try allocator.alloc(u8, stat.size);
    defer allocator.free(compressed);
    const bytes_read = try file.readAll(compressed);

    const raw = compress.zlibInflate(allocator, compressed[0..bytes_read]) catch {
        const hex = obj_info.oid.toHex();
        const msg = try std.fmt.allocPrint(allocator, "error: object {s} failed to decompress\n", .{&hex});
        try issue_strings.append(msg);
        error_count.* += 1;
        return;
    };
    defer allocator.free(raw);

    // Compute SHA-1 of the raw decompressed content
    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(raw);
    const computed = hasher.finalResult();
    const computed_oid = types.ObjectId{ .bytes = computed };

    if (!computed_oid.eql(&obj_info.oid)) {
        const expected_hex = obj_info.oid.toHex();
        const actual_hex = computed_oid.toHex();
        const msg = try std.fmt.allocPrint(allocator, "error: hash mismatch for object {s} (computed {s})\n", .{ &expected_hex, &actual_hex });
        try issue_strings.append(msg);
        error_count.* += 1;
    }
}

/// Extract referenced OIDs from a commit object.
fn extractCommitRefs(
    allocator: std.mem.Allocator,
    data: []const u8,
    referenced_oids: *std.array_list.Managed([types.OID_HEX_LEN]u8),
    error_count: *usize,
    obj_info: *const ObjectInfo,
    opts: *const FsckOptions,
    issue_strings: *std.array_list.Managed([]u8),
) !void {
    var has_tree = false;
    var has_parent = false;
    var has_author = false;
    var has_committer = false;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) break; // End of headers

        if (std.mem.startsWith(u8, line, "tree ")) {
            has_tree = true;
            if (line.len >= 5 + types.OID_HEX_LEN) {
                var hex: [types.OID_HEX_LEN]u8 = undefined;
                @memcpy(&hex, line[5..][0..types.OID_HEX_LEN]);
                try referenced_oids.append(hex);
            } else {
                const hex = obj_info.oid.toHex();
                const msg = try std.fmt.allocPrint(allocator, "error in commit {s}: invalid tree line\n", .{&hex});
                try issue_strings.append(msg);
                error_count.* += 1;
            }
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            has_parent = true;
            if (line.len >= 7 + types.OID_HEX_LEN) {
                var hex: [types.OID_HEX_LEN]u8 = undefined;
                @memcpy(&hex, line[7..][0..types.OID_HEX_LEN]);
                try referenced_oids.append(hex);
            }
        } else if (std.mem.startsWith(u8, line, "author ")) {
            has_author = true;
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            has_committer = true;
        }
    }

    // Validate commit structure
    if (!has_tree) {
        const hex = obj_info.oid.toHex();
        const msg = try std.fmt.allocPrint(allocator, "error in commit {s}: missing tree\n", .{&hex});
        try issue_strings.append(msg);
        error_count.* += 1;
    }

    if (opts.strict) {
        if (!has_author) {
            const hex = obj_info.oid.toHex();
            const msg = try std.fmt.allocPrint(allocator, "warning in commit {s}: missing author\n", .{&hex});
            try issue_strings.append(msg);
        }
        if (!has_committer) {
            const hex = obj_info.oid.toHex();
            const msg = try std.fmt.allocPrint(allocator, "warning in commit {s}: missing committer\n", .{&hex});
            try issue_strings.append(msg);
        }
    }

    // Root commits have no parents; optionally report them
    if (opts.report_root and !has_parent) {
        const hex = obj_info.oid.toHex();
        const msg = try std.fmt.allocPrint(allocator, "dangling commit {s} (root)\n", .{&hex});
        try issue_strings.append(msg);
    }
}

/// Extract referenced OIDs from a tree object.
fn extractTreeRefs(
    allocator: std.mem.Allocator,
    data: []const u8,
    referenced_oids: *std.array_list.Managed([types.OID_HEX_LEN]u8),
    error_count: *usize,
    obj_info: *const ObjectInfo,
    issue_strings: *std.array_list.Managed([]u8),
) !void {
    var pos: usize = 0;

    while (pos < data.len) {
        // Format: "mode name\0sha1"
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse {
            const hex = obj_info.oid.toHex();
            const msg = try std.fmt.allocPrint(allocator, "error in tree {s}: malformed entry at offset {d}\n", .{ &hex, pos });
            try issue_strings.append(msg);
            error_count.* += 1;
            break;
        };

        const null_pos = std.mem.indexOfScalarPos(u8, data, space_pos + 1, 0) orelse {
            const hex = obj_info.oid.toHex();
            const msg = try std.fmt.allocPrint(allocator, "error in tree {s}: missing null terminator\n", .{&hex});
            try issue_strings.append(msg);
            error_count.* += 1;
            break;
        };

        if (null_pos + 1 + types.OID_RAW_LEN > data.len) {
            const hex = obj_info.oid.toHex();
            const msg = try std.fmt.allocPrint(allocator, "error in tree {s}: truncated entry\n", .{&hex});
            try issue_strings.append(msg);
            error_count.* += 1;
            break;
        }

        // Extract the referenced OID
        var ref_oid: types.ObjectId = undefined;
        @memcpy(&ref_oid.bytes, data[null_pos + 1 ..][0..types.OID_RAW_LEN]);
        const ref_hex = ref_oid.toHex();
        try referenced_oids.append(ref_hex);

        pos = null_pos + 1 + types.OID_RAW_LEN;
    }
}

/// Extract referenced OIDs from a tag object.
fn extractTagRefs(
    allocator: std.mem.Allocator,
    data: []const u8,
    referenced_oids: *std.array_list.Managed([types.OID_HEX_LEN]u8),
    error_count: *usize,
    obj_info: *const ObjectInfo,
    issue_strings: *std.array_list.Managed([]u8),
) !void {
    var has_object = false;
    var has_type = false;
    var has_tag_name = false;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) break;

        if (std.mem.startsWith(u8, line, "object ")) {
            has_object = true;
            if (line.len >= 7 + types.OID_HEX_LEN) {
                var hex: [types.OID_HEX_LEN]u8 = undefined;
                @memcpy(&hex, line[7..][0..types.OID_HEX_LEN]);
                try referenced_oids.append(hex);
            }
        } else if (std.mem.startsWith(u8, line, "type ")) {
            has_type = true;
        } else if (std.mem.startsWith(u8, line, "tag ")) {
            has_tag_name = true;
        }
    }

    if (!has_object) {
        const hex = obj_info.oid.toHex();
        const msg = try std.fmt.allocPrint(allocator, "error in tag {s}: missing object\n", .{&hex});
        try issue_strings.append(msg);
        error_count.* += 1;
    }
    if (!has_type) {
        const hex = obj_info.oid.toHex();
        const msg = try std.fmt.allocPrint(allocator, "error in tag {s}: missing type\n", .{&hex});
        try issue_strings.append(msg);
        error_count.* += 1;
    }
    if (!has_tag_name) {
        const hex = obj_info.oid.toHex();
        const msg = try std.fmt.allocPrint(allocator, "error in tag {s}: missing tag name\n", .{&hex});
        try issue_strings.append(msg);
        error_count.* += 1;
    }
}

/// Verify that all refs point to valid objects.
fn verifyRefs(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    reachable_oids: *std.array_list.Managed([types.OID_HEX_LEN]u8),
    error_count: *usize,
    issue_strings: *std.array_list.Managed([]u8),
) !void {
    const ref_prefixes = [_][]const u8{ "refs/heads/", "refs/tags/", "refs/remotes/" };

    for (ref_prefixes) |prefix| {
        const entries = ref_mod.listRefs(allocator, repo.git_dir, prefix) catch continue;
        defer ref_mod.freeRefEntries(allocator, entries);

        for (entries) |entry| {
            if (!repo.objectExists(&entry.oid)) {
                const hex = entry.oid.toHex();
                const msg = try std.fmt.allocPrint(allocator, "error: {s} points to invalid object {s}\n", .{ entry.name, &hex });
                try issue_strings.append(msg);
                error_count.* += 1;
            } else {
                const hex = entry.oid.toHex();
                try reachable_oids.append(hex);

                // Walk the commit history to mark all reachable objects
                try markReachable(repo, allocator, &entry.oid, reachable_oids);
            }
        }
    }

    // Also check HEAD
    const head_oid = repo.resolveRef(allocator, "HEAD") catch return;
    const head_hex = head_oid.toHex();
    try reachable_oids.append(head_hex);
    try markReachable(repo, allocator, &head_oid, reachable_oids);
}

/// Walk from a commit and mark all reachable objects.
fn markReachable(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    start_oid: *const types.ObjectId,
    reachable: *std.array_list.Managed([types.OID_HEX_LEN]u8),
) !void {
    var queue = std.array_list.Managed(types.ObjectId).init(allocator);
    defer queue.deinit();

    try queue.append(start_oid.*);

    // Limit walk depth to prevent excessive traversal
    const max_walk: usize = 5000;
    var walk_count: usize = 0;

    while (queue.items.len > 0 and walk_count < max_walk) {
        const oid = queue.orderedRemove(0);
        walk_count += 1;

        const hex = oid.toHex();

        // Check if already in reachable set
        var found = false;
        for (reachable.items) |*r| {
            if (std.mem.eql(u8, r, &hex)) {
                found = true;
                break;
            }
        }
        if (found) continue;

        try reachable.append(hex);

        // Read object and follow references
        var obj = repo.readObject(allocator, &oid) catch continue;
        defer obj.deinit();

        switch (obj.obj_type) {
            .commit => {
                // Mark tree and parents
                var lines = std.mem.splitScalar(u8, obj.data, '\n');
                while (lines.next()) |line| {
                    if (line.len == 0) break;
                    if (std.mem.startsWith(u8, line, "tree ") and line.len >= 5 + types.OID_HEX_LEN) {
                        const tree_oid = types.ObjectId.fromHex(line[5..][0..types.OID_HEX_LEN]) catch continue;
                        try queue.append(tree_oid);
                    } else if (std.mem.startsWith(u8, line, "parent ") and line.len >= 7 + types.OID_HEX_LEN) {
                        const parent_oid = types.ObjectId.fromHex(line[7..][0..types.OID_HEX_LEN]) catch continue;
                        try queue.append(parent_oid);
                    }
                }
            },
            .tree => {
                // Mark all entries
                var pos: usize = 0;
                while (pos < obj.data.len) {
                    const sp = std.mem.indexOfScalarPos(u8, obj.data, pos, ' ') orelse break;
                    const nl = std.mem.indexOfScalarPos(u8, obj.data, sp + 1, 0) orelse break;
                    if (nl + 1 + types.OID_RAW_LEN > obj.data.len) break;
                    var entry_oid: types.ObjectId = undefined;
                    @memcpy(&entry_oid.bytes, obj.data[nl + 1 ..][0..types.OID_RAW_LEN]);
                    try queue.append(entry_oid);
                    pos = nl + 1 + types.OID_RAW_LEN;
                }
            },
            .tag => {
                // Mark the object the tag points to
                if (std.mem.startsWith(u8, obj.data, "object ") and obj.data.len >= 7 + types.OID_HEX_LEN) {
                    const target_oid = types.ObjectId.fromHex(obj.data[7..][0..types.OID_HEX_LEN]) catch continue;
                    try queue.append(target_oid);
                }
            },
            .blob => {},
        }
    }
}

/// Check that all referenced objects actually exist.
fn checkConnectivity(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    all_objects: *const std.array_list.Managed(ObjectInfo),
    referenced_oids: *const std.array_list.Managed([types.OID_HEX_LEN]u8),
    error_count: *usize,
    issue_strings: *std.array_list.Managed([]u8),
) !void {
    _ = all_objects;

    for (referenced_oids.items) |*ref_hex| {
        const ref_oid = types.ObjectId.fromHex(ref_hex) catch continue;
        if (!repo.objectExists(&ref_oid)) {
            const msg = try std.fmt.allocPrint(allocator, "missing {s}\n", .{ref_hex});
            try issue_strings.append(msg);
            error_count.* += 1;
        }
    }
}

/// Find and report dangling objects (objects not referenced by any reachable object).
fn findDanglingObjects(
    allocator: std.mem.Allocator,
    all_objects: *const std.array_list.Managed(ObjectInfo),
    reachable_oids: *const std.array_list.Managed([types.OID_HEX_LEN]u8),
    referenced_oids: *const std.array_list.Managed([types.OID_HEX_LEN]u8),
    opts: *const FsckOptions,
    issue_strings: *std.array_list.Managed([]u8),
    repo: *repository.Repository,
) !void {
    _ = referenced_oids;
    _ = repo;

    for (all_objects.items) |*obj_info| {
        const hex = obj_info.oid.toHex();

        // Check if this object is reachable
        var is_reachable = false;
        for (reachable_oids.items) |*r| {
            if (std.mem.eql(u8, r, &hex)) {
                is_reachable = true;
                break;
            }
        }

        if (!is_reachable) {
            const type_str = obj_info.obj_type.toString();
            if (opts.show_unreachable) {
                const msg = try std.fmt.allocPrint(allocator, "unreachable {s} {s}\n", .{ type_str, &hex });
                try issue_strings.append(msg);
            } else if (opts.report_dangling) {
                const msg = try std.fmt.allocPrint(allocator, "dangling {s} {s}\n", .{ type_str, &hex });
                try issue_strings.append(msg);
            }
        }
    }
}

/// Check if a character is a valid hexadecimal digit.
fn isHexChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
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

/// Verify the integrity of pack files.
/// Checks:
///   - Pack header (PACK magic, version, object count)
///   - Pack checksum (trailing SHA-1)
///   - Index file consistency with the pack
fn verifyPackFiles(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    error_count: *usize,
    warning_count: *usize,
    issue_strings: *std.array_list.Managed([]u8),
    verbose: bool,
) !void {
    var pack_dir_buf: [4096]u8 = undefined;
    const pack_dir_path = buildPath(&pack_dir_buf, git_dir, "/objects/pack");

    var dir = std.fs.openDirAbsolute(pack_dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pack")) continue;

        var pack_path_buf: [4096]u8 = undefined;
        const pack_path = buildPath2(&pack_path_buf, pack_dir_path, "/", entry.name);

        if (verbose) {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Verifying pack {s}...\n", .{entry.name}) catch "Verifying pack...\n";
            stderr_file.writeAll(msg) catch {};
        }

        try verifyPackHeader(allocator, pack_path, entry.name, error_count, issue_strings);
        try verifyPackChecksum(allocator, pack_path, entry.name, error_count, issue_strings);

        // Check that matching .idx file exists
        const idx_name_len = entry.name.len - 5 + 4; // replace ".pack" with ".idx"
        if (idx_name_len <= 256) {
            var idx_name_buf: [256]u8 = undefined;
            @memcpy(idx_name_buf[0 .. entry.name.len - 5], entry.name[0 .. entry.name.len - 5]);
            @memcpy(idx_name_buf[entry.name.len - 5 ..][0..4], ".idx");
            const idx_name = idx_name_buf[0..idx_name_len];

            var idx_path_buf: [4096]u8 = undefined;
            const idx_path = buildPath2(&idx_path_buf, pack_dir_path, "/", idx_name);

            const idx_file = std.fs.openFileAbsolute(idx_path, .{}) catch {
                const msg = try std.fmt.allocPrint(allocator, "warning: pack {s} has no corresponding index file\n", .{entry.name});
                try issue_strings.append(msg);
                warning_count.* += 1;
                continue;
            };
            idx_file.close();

            // Verify index header
            try verifyPackIndex(allocator, idx_path, idx_name, error_count, issue_strings);
        }
    }
}

/// Verify a pack file's header.
fn verifyPackHeader(
    allocator: std.mem.Allocator,
    path: []const u8,
    name: []const u8,
    error_count: *usize,
    issue_strings: *std.array_list.Managed([]u8),
) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    var header: [12]u8 = undefined;
    const n = file.readAll(&header) catch return;
    if (n < 12) {
        const msg = try std.fmt.allocPrint(allocator, "error: pack {s} is too small (header truncated)\n", .{name});
        try issue_strings.append(msg);
        error_count.* += 1;
        return;
    }

    // Check magic
    if (!std.mem.eql(u8, header[0..4], "PACK")) {
        const msg = try std.fmt.allocPrint(allocator, "error: pack {s} has invalid magic\n", .{name});
        try issue_strings.append(msg);
        error_count.* += 1;
        return;
    }

    // Check version
    const version = std.mem.readInt(u32, header[4..8], .big);
    if (version != 2 and version != 3) {
        const msg = try std.fmt.allocPrint(allocator, "error: pack {s} has unsupported version {d}\n", .{ name, version });
        try issue_strings.append(msg);
        error_count.* += 1;
    }
}

/// Verify a pack file's trailing SHA-1 checksum.
fn verifyPackChecksum(
    allocator: std.mem.Allocator,
    path: []const u8,
    name: []const u8,
    error_count: *usize,
    issue_strings: *std.array_list.Managed([]u8),
) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    const stat = file.stat() catch return;
    if (stat.size < 32) return; // Too small for header + checksum

    // Read the entire file to verify checksum
    // For large packs, this could be done in chunks
    const file_size: usize = @intCast(stat.size);
    if (file_size > 256 * 1024 * 1024) {
        // Skip checksum verification for very large packs to avoid OOM
        return;
    }

    const data = allocator.alloc(u8, file_size) catch return;
    defer allocator.free(data);
    const bytes_read = file.readAll(data) catch return;
    if (bytes_read < 20) return;

    // The last 20 bytes are the SHA-1 of everything before
    const content = data[0 .. bytes_read - 20];
    const stored_checksum = data[bytes_read - 20 .. bytes_read];

    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(content);
    const computed = hasher.finalResult();

    if (!std.mem.eql(u8, stored_checksum, &computed)) {
        const msg = try std.fmt.allocPrint(allocator, "error: pack {s} has invalid checksum\n", .{name});
        try issue_strings.append(msg);
        error_count.* += 1;
    }
}

/// Verify a pack index file's header and version.
fn verifyPackIndex(
    allocator: std.mem.Allocator,
    path: []const u8,
    name: []const u8,
    error_count: *usize,
    issue_strings: *std.array_list.Managed([]u8),
) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    var header: [8]u8 = undefined;
    const n = file.readAll(&header) catch return;
    if (n < 8) {
        const msg = try std.fmt.allocPrint(allocator, "error: pack index {s} is too small\n", .{name});
        try issue_strings.append(msg);
        error_count.* += 1;
        return;
    }

    // Pack index v2 has a magic header: ff 74 4f 63
    const v2_magic = [_]u8{ 0xff, 0x74, 0x4f, 0x63 };
    if (std.mem.eql(u8, header[0..4], &v2_magic)) {
        // Version 2 index
        const version = std.mem.readInt(u32, header[4..8], .big);
        if (version != 2) {
            const msg = try std.fmt.allocPrint(allocator, "error: pack index {s} has unsupported version {d}\n", .{ name, version });
            try issue_strings.append(msg);
            error_count.* += 1;
        }
    }
    // Version 1 indexes don't have a magic header - they start with the fan-out table
}

/// Summary report of fsck results.
const FsckSummary = struct {
    total_objects: usize,
    loose_objects: usize,
    packed_objects: usize,
    errors_found: usize,
    warnings_found: usize,
    dangling_commits: usize,
    dangling_blobs: usize,
    dangling_trees: usize,
    missing_objects: usize,
};

/// Print a detailed summary of the fsck results.
fn printFsckSummary(summary: *const FsckSummary) !void {
    var buf: [512]u8 = undefined;

    try stdout_file.writeAll("--- fsck summary ---\n");

    var msg = std.fmt.bufPrint(&buf, "total objects: {d}\n", .{summary.total_objects}) catch return;
    try stdout_file.writeAll(msg);

    msg = std.fmt.bufPrint(&buf, "  loose: {d}\n", .{summary.loose_objects}) catch return;
    try stdout_file.writeAll(msg);

    msg = std.fmt.bufPrint(&buf, "  packed: {d}\n", .{summary.packed_objects}) catch return;
    try stdout_file.writeAll(msg);

    if (summary.errors_found > 0) {
        msg = std.fmt.bufPrint(&buf, "errors: {d}\n", .{summary.errors_found}) catch return;
        try stdout_file.writeAll(msg);
    }

    if (summary.warnings_found > 0) {
        msg = std.fmt.bufPrint(&buf, "warnings: {d}\n", .{summary.warnings_found}) catch return;
        try stdout_file.writeAll(msg);
    }

    if (summary.dangling_commits > 0) {
        msg = std.fmt.bufPrint(&buf, "dangling commits: {d}\n", .{summary.dangling_commits}) catch return;
        try stdout_file.writeAll(msg);
    }

    if (summary.dangling_blobs > 0) {
        msg = std.fmt.bufPrint(&buf, "dangling blobs: {d}\n", .{summary.dangling_blobs}) catch return;
        try stdout_file.writeAll(msg);
    }

    if (summary.dangling_trees > 0) {
        msg = std.fmt.bufPrint(&buf, "dangling trees: {d}\n", .{summary.dangling_trees}) catch return;
        try stdout_file.writeAll(msg);
    }

    if (summary.missing_objects > 0) {
        msg = std.fmt.bufPrint(&buf, "missing objects: {d}\n", .{summary.missing_objects}) catch return;
        try stdout_file.writeAll(msg);
    }
}

test "isHexChar" {
    try std.testing.expect(isHexChar('0'));
    try std.testing.expect(isHexChar('9'));
    try std.testing.expect(isHexChar('a'));
    try std.testing.expect(isHexChar('f'));
    try std.testing.expect(!isHexChar('g'));
    try std.testing.expect(!isHexChar('/'));
}
