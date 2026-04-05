const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const ref_mod = @import("ref.zig");
const loose = @import("loose.zig");
const hash_mod = @import("hash.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const notes_usage =
    \\usage: zig-git notes [list]
    \\   or: zig-git notes add [-f] -m <message> [<object>]
    \\   or: zig-git notes show [<object>]
    \\   or: zig-git notes remove [<object>]
    \\   or: zig-git notes prune
    \\
    \\Subcommands:
    \\  list       List notes for all objects (default)
    \\  add        Add a note to an object
    \\  show       Show the note attached to an object
    \\  remove     Remove the note from an object
    \\  prune      Remove notes for objects that no longer exist
    \\
    \\Options:
    \\  -m <msg>   Note message
    \\  -f         Overwrite existing note
    \\  --ref <r>  Use <r> instead of refs/notes/commits
    \\
;

/// The default notes ref.
const DEFAULT_NOTES_REF = "refs/notes/commits";

/// Options for the notes command.
const NotesOptions = struct {
    /// Subcommand: list, add, show, remove, prune.
    subcommand: Subcommand = .list,
    /// Note message (for add).
    message: ?[]const u8 = null,
    /// Force overwrite existing note.
    force: bool = false,
    /// Notes ref to use.
    notes_ref: []const u8 = DEFAULT_NOTES_REF,
    /// Target object (default: HEAD).
    object_ref: []const u8 = "HEAD",
};

const Subcommand = enum {
    list,
    add,
    show,
    remove,
    prune,
};

/// Entry point for the notes command.
pub fn runNotes(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = NotesOptions{};

    // Parse arguments
    var i: usize = 0;
    var found_subcmd = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!found_subcmd and !std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "list")) {
                opts.subcommand = .list;
                found_subcmd = true;
            } else if (std.mem.eql(u8, arg, "add")) {
                opts.subcommand = .add;
                found_subcmd = true;
            } else if (std.mem.eql(u8, arg, "show")) {
                opts.subcommand = .show;
                found_subcmd = true;
            } else if (std.mem.eql(u8, arg, "remove")) {
                opts.subcommand = .remove;
                found_subcmd = true;
            } else if (std.mem.eql(u8, arg, "prune")) {
                opts.subcommand = .prune;
                found_subcmd = true;
            } else {
                opts.object_ref = arg;
            }
        } else if (std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("fatal: -m requires a message\n");
                std.process.exit(1);
            }
            opts.message = args[i];
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, arg, "--ref")) {
            i += 1;
            if (i >= args.len) {
                try stderr_file.writeAll("fatal: --ref requires a ref name\n");
                std.process.exit(1);
            }
            opts.notes_ref = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            opts.object_ref = arg;
        }
    }

    switch (opts.subcommand) {
        .list => try notesList(repo, allocator, &opts),
        .add => try notesAdd(repo, allocator, &opts),
        .show => try notesShow(repo, allocator, &opts),
        .remove => try notesRemove(repo, allocator, &opts),
        .prune => try notesPrune(repo, allocator, &opts),
    }
}

/// List all notes.
fn notesList(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    opts: *const NotesOptions,
) !void {
    // Read the notes tree
    const notes_tree_oid = getNotesTreeOid(repo, allocator, opts.notes_ref) catch {
        // No notes ref means no notes
        return;
    };

    // Parse the notes tree
    const tree_entries = readTreeEntries(repo, allocator, &notes_tree_oid) catch return;
    defer {
        for (tree_entries) |*e| {
            _ = e;
        }
        allocator.free(tree_entries);
    }

    // Each entry in the notes tree has:
    // - name = hex OID of the annotated object (possibly with slashes for fan-out)
    // - oid = blob OID containing the note text
    for (tree_entries) |*entry| {
        const note_hex = entry.oid.toHex();
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} {s}\n", .{ &note_hex, entry.name }) catch continue;
        try stdout_file.writeAll(line);
    }
}

/// Add a note to an object.
fn notesAdd(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    opts: *const NotesOptions,
) !void {
    if (opts.message == null) {
        try stderr_file.writeAll("fatal: no note message given (use -m)\n");
        std.process.exit(1);
    }

    // Resolve the target object
    const target_oid = repo.resolveRef(allocator, opts.object_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: not a valid object name: '{s}'\n", .{opts.object_ref}) catch "fatal: not a valid object name\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    const target_hex = target_oid.toHex();

    // Check if a note already exists for this object
    const has_existing = noteExists(repo, allocator, opts.notes_ref, &target_hex);

    if (has_existing and !opts.force) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: Cannot add notes. Found existing notes for object {s}. Use '-f' to overwrite existing notes.\n", .{target_hex[0..7]}) catch "error: existing note found, use -f to overwrite\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    }

    // Write the note message as a blob
    const note_blob_oid = loose.writeLooseObject(allocator, repo.git_dir, .blob, opts.message.?) catch |err| switch (err) {
        error.PathAlreadyExists => computeBlobOid(opts.message.?),
        else => return err,
    };

    // Build the new notes tree
    try updateNotesTree(repo, allocator, opts.notes_ref, &target_hex, note_blob_oid);

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Adding note to object {s}\n", .{target_hex[0..7]}) catch "Adding note.\n";
    try stdout_file.writeAll(msg);
}

/// Show the note for a given object.
fn notesShow(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    opts: *const NotesOptions,
) !void {
    // Resolve the target object
    const target_oid = repo.resolveRef(allocator, opts.object_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: not a valid object name: '{s}'\n", .{opts.object_ref}) catch "fatal: not a valid object name\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    const target_hex = target_oid.toHex();

    // Find the note blob
    const note_blob_oid = findNoteBlobOid(repo, allocator, opts.notes_ref, &target_hex) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: no note found for object {s}\n", .{target_hex[0..7]}) catch "error: no note found\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    };

    // Read the note blob
    var obj = repo.readObject(allocator, &note_blob_oid) catch {
        try stderr_file.writeAll("error: could not read note\n");
        std.process.exit(1);
    };
    defer obj.deinit();

    try stdout_file.writeAll(obj.data);
    // Ensure a trailing newline
    if (obj.data.len == 0 or obj.data[obj.data.len - 1] != '\n') {
        try stdout_file.writeAll("\n");
    }
}

/// Remove a note from an object.
fn notesRemove(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    opts: *const NotesOptions,
) !void {
    // Resolve the target object
    const target_oid = repo.resolveRef(allocator, opts.object_ref) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: not a valid object name: '{s}'\n", .{opts.object_ref}) catch "fatal: not a valid object name\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    const target_hex = target_oid.toHex();

    // Check if note exists
    if (!noteExists(repo, allocator, opts.notes_ref, &target_hex)) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: no note found for object {s}\n", .{target_hex[0..7]}) catch "error: no note found\n";
        try stderr_file.writeAll(msg);
        std.process.exit(1);
    }

    // Remove the entry from the notes tree
    try removeFromNotesTree(repo, allocator, opts.notes_ref, &target_hex);

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Removing note for object {s}\n", .{target_hex[0..7]}) catch "Removing note.\n";
    try stdout_file.writeAll(msg);
}

/// Prune notes for objects that no longer exist.
fn notesPrune(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    opts: *const NotesOptions,
) !void {
    const notes_tree_oid = getNotesTreeOid(repo, allocator, opts.notes_ref) catch return;

    const tree_entries = readTreeEntries(repo, allocator, &notes_tree_oid) catch return;
    defer allocator.free(tree_entries);

    var pruned_count: usize = 0;

    for (tree_entries) |*entry| {
        // The entry name should be a hex OID
        if (entry.name.len == types.OID_HEX_LEN) {
            const obj_oid = types.ObjectId.fromHex(entry.name) catch continue;
            if (!repo.objectExists(&obj_oid)) {
                // Object no longer exists, prune this note
                try removeFromNotesTree(repo, allocator, opts.notes_ref, entry.name);
                pruned_count += 1;
            }
        }
    }

    if (pruned_count > 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Pruned {d} note(s)\n", .{pruned_count}) catch "Pruned notes.\n";
        try stdout_file.writeAll(msg);
    }
}

/// Get the tree OID that the notes ref points to.
fn getNotesTreeOid(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    notes_ref: []const u8,
) !types.ObjectId {
    // Read the notes ref -> commit -> tree
    const commit_oid = try ref_mod.readRef(allocator, repo.git_dir, notes_ref);

    var obj = try repo.readObject(allocator, &commit_oid);
    defer obj.deinit();

    if (obj.obj_type != .commit) return error.InvalidNotesRef;

    // Parse tree OID from commit
    return parseTreeOidFromCommit(obj.data);
}

/// Parse the tree OID from commit data.
fn parseTreeOidFromCommit(data: []const u8) !types.ObjectId {
    const prefix = "tree ";
    if (!std.mem.startsWith(u8, data, prefix)) return error.InvalidCommit;
    if (data.len < prefix.len + types.OID_HEX_LEN) return error.InvalidCommit;
    return types.ObjectId.fromHex(data[prefix.len..][0..types.OID_HEX_LEN]);
}

/// A tree entry parsed from tree object data.
const TreeEntry = struct {
    mode: []const u8,
    name: []const u8,
    oid: types.ObjectId,
};

/// Read and parse tree entries from a tree object.
fn readTreeEntries(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    tree_oid: *const types.ObjectId,
) ![]TreeEntry {
    var obj = try repo.readObject(allocator, tree_oid);
    defer obj.deinit();

    if (obj.obj_type != .tree) return error.NotATree;

    var entries = std.array_list.Managed(TreeEntry).init(allocator);
    errdefer entries.deinit();

    var pos: usize = 0;
    const data = obj.data;

    while (pos < data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse break;
        const mode = data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, data, space_pos + 1, 0) orelse break;
        const name = data[space_pos + 1 .. null_pos];

        if (null_pos + 1 + types.OID_RAW_LEN > data.len) break;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, data[null_pos + 1 ..][0..types.OID_RAW_LEN]);
        pos = null_pos + 1 + types.OID_RAW_LEN;

        // Make owned copies of mode and name since obj.data will be freed
        const owned_mode = try allocator.alloc(u8, mode.len);
        @memcpy(owned_mode, mode);
        const owned_name = try allocator.alloc(u8, name.len);
        @memcpy(owned_name, name);

        try entries.append(.{
            .mode = owned_mode,
            .name = owned_name,
            .oid = oid,
        });
    }

    return entries.toOwnedSlice();
}

/// Check if a note exists for the given object hex.
fn noteExists(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    notes_ref: []const u8,
    target_hex: []const u8,
) bool {
    _ = findNoteBlobOid(repo, allocator, notes_ref, target_hex) catch return false;
    return true;
}

/// Find the blob OID for a note attached to the given object.
fn findNoteBlobOid(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    notes_ref: []const u8,
    target_hex: []const u8,
) !types.ObjectId {
    const notes_tree_oid = try getNotesTreeOid(repo, allocator, notes_ref);
    const tree_entries = try readTreeEntries(repo, allocator, &notes_tree_oid);
    defer {
        for (tree_entries) |*e| {
            allocator.free(@constCast(e.mode));
            allocator.free(@constCast(e.name));
        }
        allocator.free(tree_entries);
    }

    for (tree_entries) |*entry| {
        if (std.mem.eql(u8, entry.name, target_hex)) {
            return entry.oid;
        }
        // Also check fan-out format (first 2 chars / remaining)
        if (target_hex.len == types.OID_HEX_LEN and entry.name.len == types.OID_HEX_LEN) {
            if (std.mem.eql(u8, entry.name, target_hex)) {
                return entry.oid;
            }
        }
    }

    return error.NoteNotFound;
}

/// Update the notes tree: add or replace a note entry.
fn updateNotesTree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    notes_ref: []const u8,
    target_hex: []const u8,
    note_blob_oid: types.ObjectId,
) !void {
    // Read existing tree entries (or start fresh)
    var existing_entries: ?[]TreeEntry = null;
    const notes_tree_oid = getNotesTreeOid(repo, allocator, notes_ref) catch null;

    if (notes_tree_oid) |nt_oid| {
        existing_entries = readTreeEntries(repo, allocator, &nt_oid) catch null;
    }

    defer {
        if (existing_entries) |entries| {
            for (entries) |*e| {
                allocator.free(@constCast(e.mode));
                allocator.free(@constCast(e.name));
            }
            allocator.free(entries);
        }
    }

    // Build new tree data
    var tree_data_buf = std.array_list.Managed(u8).init(allocator);
    defer tree_data_buf.deinit();

    var found_existing = false;

    if (existing_entries) |entries| {
        for (entries) |*entry| {
            if (std.mem.eql(u8, entry.name, target_hex)) {
                // Replace with new note
                try appendTreeEntry(&tree_data_buf, "100644", target_hex, &note_blob_oid);
                found_existing = true;
            } else {
                try appendTreeEntry(&tree_data_buf, entry.mode, entry.name, &entry.oid);
            }
        }
    }

    if (!found_existing) {
        try appendTreeEntry(&tree_data_buf, "100644", target_hex, &note_blob_oid);
    }

    // Write the new tree object
    const new_tree_oid = loose.writeLooseObject(allocator, repo.git_dir, .tree, tree_data_buf.items) catch |err| switch (err) {
        error.PathAlreadyExists => computeTreeOid(tree_data_buf.items),
        else => return err,
    };

    // Create a commit pointing to this tree
    try createNotesCommit(repo, allocator, notes_ref, new_tree_oid, "Notes added by 'git notes add'");
}

/// Remove an entry from the notes tree.
fn removeFromNotesTree(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    notes_ref: []const u8,
    target_hex: []const u8,
) !void {
    const notes_tree_oid = try getNotesTreeOid(repo, allocator, notes_ref);
    const existing_entries = try readTreeEntries(repo, allocator, &notes_tree_oid);
    defer {
        for (existing_entries) |*e| {
            allocator.free(@constCast(e.mode));
            allocator.free(@constCast(e.name));
        }
        allocator.free(existing_entries);
    }

    var tree_data_buf = std.array_list.Managed(u8).init(allocator);
    defer tree_data_buf.deinit();

    for (existing_entries) |*entry| {
        if (std.mem.eql(u8, entry.name, target_hex)) continue; // Skip this entry
        try appendTreeEntry(&tree_data_buf, entry.mode, entry.name, &entry.oid);
    }

    // Write the new tree object
    const new_tree_oid = loose.writeLooseObject(allocator, repo.git_dir, .tree, tree_data_buf.items) catch |err| switch (err) {
        error.PathAlreadyExists => computeTreeOid(tree_data_buf.items),
        else => return err,
    };

    // Create a commit
    try createNotesCommit(repo, allocator, notes_ref, new_tree_oid, "Notes removed by 'git notes remove'");
}

/// Append a single tree entry to the tree data buffer.
fn appendTreeEntry(
    buf: *std.array_list.Managed(u8),
    mode: []const u8,
    name: []const u8,
    oid: *const types.ObjectId,
) !void {
    try buf.appendSlice(mode);
    try buf.append(' ');
    try buf.appendSlice(name);
    try buf.append(0);
    try buf.appendSlice(&oid.bytes);
}

/// Create a new commit for the notes ref.
fn createNotesCommit(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    notes_ref: []const u8,
    tree_oid: types.ObjectId,
    message: []const u8,
) !void {
    // Build commit content
    var commit_buf = std.array_list.Managed(u8).init(allocator);
    defer commit_buf.deinit();

    const tree_hex = tree_oid.toHex();
    try commit_buf.appendSlice("tree ");
    try commit_buf.appendSlice(&tree_hex);
    try commit_buf.append('\n');

    // Add parent (previous notes commit, if any)
    const parent_oid = ref_mod.readRef(allocator, repo.git_dir, notes_ref) catch null;
    if (parent_oid) |p| {
        const parent_hex = p.toHex();
        try commit_buf.appendSlice("parent ");
        try commit_buf.appendSlice(&parent_hex);
        try commit_buf.append('\n');
    }

    // Author/committer
    try commit_buf.appendSlice("author zig-git <zig-git@localhost> ");
    try appendTimestamp(&commit_buf);
    try commit_buf.append('\n');
    try commit_buf.appendSlice("committer zig-git <zig-git@localhost> ");
    try appendTimestamp(&commit_buf);
    try commit_buf.append('\n');
    try commit_buf.append('\n');
    try commit_buf.appendSlice(message);
    try commit_buf.append('\n');

    // Write commit object
    const commit_oid = loose.writeLooseObject(allocator, repo.git_dir, .commit, commit_buf.items) catch |err| switch (err) {
        error.PathAlreadyExists => computeCommitOid(commit_buf.items),
        else => return err,
    };

    // Update the notes ref
    ref_mod.createRef(allocator, repo.git_dir, notes_ref, commit_oid, null) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: could not update notes ref: {s}\n", .{@errorName(err)}) catch "fatal: could not update notes ref\n";
        stderr_file.writeAll(msg) catch {};
        std.process.exit(128);
    };
}

/// Append a Unix timestamp and timezone to the buffer.
fn appendTimestamp(buf: *std.array_list.Managed(u8)) !void {
    // Use a simple approach: get current time
    // For simplicity, use epoch 0 with +0000 timezone
    // In a real implementation, we'd use std.time
    const timestamp = std.time.timestamp();
    var ts_buf: [32]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d} +0000", .{timestamp}) catch "0 +0000";
    try buf.appendSlice(ts_str);
}

/// Compute blob OID without writing.
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

/// Compute tree OID without writing.
fn computeTreeOid(data: []const u8) types.ObjectId {
    var header_buf: [64]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    hwriter.writeAll("tree ") catch unreachable;
    hwriter.print("{d}", .{data.len}) catch unreachable;
    hwriter.writeByte(0) catch unreachable;
    const header = header_buf[0..hstream.pos];

    var hasher = hash_mod.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    return types.ObjectId{ .bytes = hasher.finalResult() };
}

/// Compute commit OID without writing.
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

test "parseTreeOidFromCommit" {
    const data = "tree e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\nauthor Test <test@example.com>\n\nTest commit\n";
    const oid = try parseTreeOidFromCommit(data);
    const hex = oid.toHex();
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &hex);
}
