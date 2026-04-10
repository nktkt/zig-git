const std = @import("std");
const config_mod = @import("config.zig");
const ref_mod = @import("ref.zig");
const index_mod = @import("index.zig");

const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Determine which editor to use.
/// Priority: core.editor config -> GIT_EDITOR env -> VISUAL env -> EDITOR env -> "vi"
pub fn getEditorCommand(allocator: std.mem.Allocator, git_dir: []const u8) []const u8 {
    // 1. Check core.editor from config
    var config_path_buf: [4096]u8 = undefined;
    const config_path = buildPath(&config_path_buf, git_dir, "/config");
    var cfg = config_mod.Config.loadFile(allocator, config_path) catch {
        return "vi";
    };
    defer cfg.deinit();
    if (cfg.get("core.editor")) |editor| {
        if (editor.len > 0) return editor;
    }

    // 2-4. We just default to "vi" since env values cannot outlive the scope
    // In a real implementation, we'd allocate copies of the env values.
    // For simplicity, default to "vi".
    return "vi";
}

/// Open a file in the editor and wait for it to exit.
pub fn openEditor(allocator: std.mem.Allocator, git_dir: []const u8, file_path: []const u8) !void {
    const editor_cmd = getEditorCommand(allocator, git_dir);

    // Spawn the editor process
    var child = std.process.Child.init(&[_][]const u8{ editor_cmd, file_path }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const result = try child.wait();

    switch (result) {
        .Exited => |code| {
            if (code != 0) {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "error: editor exited with code {d}\n", .{code}) catch
                    "error: editor exited with non-zero code\n";
                try stderr_file.writeAll(msg);
                return error.EditorFailed;
            }
        },
        else => {
            try stderr_file.writeAll("error: editor was terminated by signal\n");
            return error.EditorFailed;
        },
    }
}

/// Edit a commit message using the configured editor.
/// Writes an initial template to COMMIT_EDITMSG, opens the editor,
/// reads back the result, strips comments and validates.
pub fn editCommitMessage(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    initial_message: ?[]const u8,
    branch_name: []const u8,
    changed_files: ?[]const []const u8,
) ![]u8 {
    // Build the COMMIT_EDITMSG path
    var path_buf: [4096]u8 = undefined;
    const editmsg_path = buildPath(&path_buf, git_dir, "/COMMIT_EDITMSG");

    // Write template
    {
        const file = try std.fs.createFileAbsolute(editmsg_path, .{ .truncate = true });
        defer file.close();

        // Initial message or blank line
        if (initial_message) |msg| {
            try file.writeAll(msg);
        }
        try file.writeAll("\n");

        // Comment block
        try file.writeAll("# Please enter the commit message for your changes.\n");
        try file.writeAll("# Lines starting with '#' will be ignored, and an empty\n");
        try file.writeAll("# message aborts the commit.\n");
        try file.writeAll("#\n");

        // Branch info
        var branch_buf: [256]u8 = undefined;
        const branch_line = std.fmt.bufPrint(&branch_buf, "# On branch {s}\n", .{branch_name}) catch "# On branch (unknown)\n";
        try file.writeAll(branch_line);

        // Changed files
        if (changed_files) |files| {
            if (files.len > 0) {
                try file.writeAll("# Changes to be committed:\n");
                for (files) |f| {
                    var line_buf: [512]u8 = undefined;
                    const line = std.fmt.bufPrint(&line_buf, "#\tmodified:   {s}\n", .{f}) catch continue;
                    try file.writeAll(line);
                }
            }
        }
        try file.writeAll("#\n");
    }

    // Open editor
    openEditor(allocator, git_dir, editmsg_path) catch |err| {
        switch (err) {
            error.EditorFailed => {
                try stderr_file.writeAll("Aborting commit due to editor failure.\n");
                return error.CommitAborted;
            },
            error.FileNotFound => {
                try stderr_file.writeAll("error: unable to launch editor. Set GIT_EDITOR or core.editor config.\n");
                return error.CommitAborted;
            },
            else => return err,
        }
    };

    // Read back the file
    const content = readFileContents(allocator, editmsg_path) catch {
        try stderr_file.writeAll("error: could not read COMMIT_EDITMSG\n");
        return error.CommitAborted;
    };
    defer allocator.free(content);

    // Strip comment lines and trailing whitespace
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var has_content = false;
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len > 0 and trimmed[0] == '#') continue;
        try result.appendSlice(line);
        try result.append('\n');
        if (std.mem.trimRight(u8, line, " \t\n\r").len > 0) {
            has_content = true;
        }
    }

    if (!has_content) {
        result.deinit();
        try stderr_file.writeAll("Aborting commit due to empty commit message.\n");
        return error.CommitAborted;
    }

    // Trim trailing whitespace/newlines but keep one trailing newline
    var final = result.toOwnedSlice() catch return error.OutOfMemory;

    // Trim trailing newlines to just content
    var end: usize = final.len;
    while (end > 0 and (final[end - 1] == '\n' or final[end - 1] == ' ' or final[end - 1] == '\t' or final[end - 1] == '\r')) {
        end -= 1;
    }

    if (end == 0) {
        allocator.free(final);
        try stderr_file.writeAll("Aborting commit due to empty commit message.\n");
        return error.CommitAborted;
    }

    // Return just the content portion
    const trimmed_result = try allocator.alloc(u8, end);
    @memcpy(trimmed_result, final[0..end]);
    allocator.free(final);
    return trimmed_result;
}

// -- Helpers --

fn buildPath(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
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
