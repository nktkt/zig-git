const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const tree_diff = @import("tree_diff.zig");
const ref_mod = @import("ref.zig");
const reflog_mod = @import("reflog.zig");
const checkout_mod = @import("checkout.zig");
const index_mod = @import("index.zig");
const loose = @import("loose.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

// Bisect state files
const BISECT_LOG = "/BISECT_LOG";
const BISECT_START = "/BISECT_START";
const BISECT_EXPECTED_REV = "/BISECT_EXPECTED_REV";
const BISECT_ANCESTORS_OK = "/BISECT_ANCESTORS_OK";
const BISECT_NAMES = "/BISECT_NAMES";

/// Commands for the bisect subcommand.
pub const BisectCommand = enum {
    start,
    good,
    bad,
    reset,
    log,
    visualize,
    skip,
    replay,
    status,
};

/// State of an ongoing bisect session.
pub const BisectState = struct {
    good_commits: std.array_list.Managed(types.ObjectId),
    bad_commit: ?types.ObjectId,
    skipped_commits: std.array_list.Managed(types.ObjectId),
    orig_head: ?types.ObjectId,
    orig_ref: ?[]u8,
    log_entries: std.array_list.Managed([]u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BisectState {
        return .{
            .good_commits = std.array_list.Managed(types.ObjectId).init(allocator),
            .bad_commit = null,
            .skipped_commits = std.array_list.Managed(types.ObjectId).init(allocator),
            .orig_head = null,
            .orig_ref = null,
            .log_entries = std.array_list.Managed([]u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BisectState) void {
        self.good_commits.deinit();
        self.skipped_commits.deinit();
        if (self.orig_ref) |r| self.allocator.free(r);
        for (self.log_entries.items) |e| {
            self.allocator.free(e);
        }
        self.log_entries.deinit();
    }
};

/// Entry point for the bisect command.
pub fn runBisect(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len == 0) {
        try printBisectUsage();
        std.process.exit(1);
    }

    const subcmd_str = args[0];
    const subcmd = parseBisectCommand(subcmd_str) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: unknown bisect subcommand '{s}'\n", .{subcmd_str}) catch
            "error: unknown bisect subcommand\n";
        try stderr_file.writeAll(msg);
        try printBisectUsage();
        std.process.exit(1);
    };

    const sub_args = args[1..];

    switch (subcmd) {
        .start => return bisectStart(repo, allocator, sub_args),
        .good => return bisectGood(repo, allocator, sub_args),
        .bad => return bisectBad(repo, allocator, sub_args),
        .reset => return bisectReset(repo, allocator),
        .log => return bisectLog(repo, allocator),
        .skip => return bisectSkip(repo, allocator, sub_args),
        .status => return bisectStatus(repo, allocator),
        .visualize, .replay => {
            try stderr_file.writeAll("error: this bisect subcommand is not yet implemented\n");
            std.process.exit(1);
        },
    }
}

fn parseBisectCommand(s: []const u8) ?BisectCommand {
    if (std.mem.eql(u8, s, "start")) return .start;
    if (std.mem.eql(u8, s, "good") or std.mem.eql(u8, s, "old")) return .good;
    if (std.mem.eql(u8, s, "bad") or std.mem.eql(u8, s, "new")) return .bad;
    if (std.mem.eql(u8, s, "reset")) return .reset;
    if (std.mem.eql(u8, s, "log")) return .log;
    if (std.mem.eql(u8, s, "visualize") or std.mem.eql(u8, s, "view")) return .visualize;
    if (std.mem.eql(u8, s, "skip")) return .skip;
    if (std.mem.eql(u8, s, "replay")) return .replay;
    if (std.mem.eql(u8, s, "status")) return .status;
    return null;
}

fn printBisectUsage() !void {
    try stderr_file.writeAll(
        \\usage: zig-git bisect <subcommand>
        \\
        \\Subcommands:
        \\  start         Start bisect session
        \\  good [<rev>]  Mark a commit as good
        \\  bad [<rev>]   Mark a commit as bad
        \\  skip [<rev>]  Skip a commit
        \\  reset         End bisect session
        \\  log           Show bisect log
        \\  status        Show current bisect status
        \\
    );
}

/// Start a bisect session.
fn bisectStart(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    // Check if bisect is already in progress
    if (isBisectInProgress(repo.git_dir)) {
        try stderr_file.writeAll("error: bisect is already in progress\n");
        try stderr_file.writeAll("hint: use 'zig-git bisect reset' to end it first\n");
        std.process.exit(1);
    }

    // Save current HEAD
    const head_oid = repo.resolveRef(allocator, "HEAD") catch {
        try stderr_file.writeAll("fatal: cannot read HEAD\n");
        std.process.exit(128);
    };

    const head_ref = ref_mod.readHead(allocator, repo.git_dir) catch null;
    defer if (head_ref) |h| allocator.free(h);

    // Write BISECT_START
    {
        var path_buf: [4096]u8 = undefined;
        const path = buildPath(&path_buf, repo.git_dir, BISECT_START);
        const hex = head_oid.toHex();
        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(&hex);
        try file.writeAll("\n");
        if (head_ref) |h| {
            try file.writeAll(h);
            try file.writeAll("\n");
        }
    }

    // Initialize empty bisect log
    {
        var path_buf: [4096]u8 = undefined;
        const path = buildPath(&path_buf, repo.git_dir, BISECT_LOG);
        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("# bisect log\n");
    }

    // Handle optional bad and good arguments: bisect start <bad> <good>
    if (args.len >= 1) {
        // First arg is bad commit
        const bad_ref = args[0];
        const bad_oid = repo.resolveRef(allocator, bad_ref) catch {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "fatal: bad revision '{s}'\n", .{bad_ref}) catch
                "fatal: bad revision\n";
            try stderr_file.writeAll(msg);
            std.process.exit(128);
        };
        try appendBisectLog(repo.git_dir, "bad", &bad_oid);
        try writeBisectRef(repo.git_dir, "bad", bad_oid);

        if (args.len >= 2) {
            // Second arg is good commit
            const good_ref = args[1];
            const good_oid = repo.resolveRef(allocator, good_ref) catch {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "fatal: bad revision '{s}'\n", .{good_ref}) catch
                    "fatal: bad revision\n";
                try stderr_file.writeAll(msg);
                std.process.exit(128);
            };
            try appendBisectLog(repo.git_dir, "good", &good_oid);
            try writeBisectRef(repo.git_dir, "good", good_oid);

            // Immediately try to find a midpoint
            try findAndCheckoutMidpoint(repo, allocator);
            return;
        }
    }

    try stdout_file.writeAll("Bisect started. Mark commits as 'good' or 'bad'.\n");
    try stdout_file.writeAll("Use 'zig-git bisect good <rev>' and 'zig-git bisect bad <rev>'.\n");
}

/// Mark a commit as good.
fn bisectGood(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (!isBisectInProgress(repo.git_dir)) {
        try stderr_file.writeAll("error: no bisect in progress\n");
        std.process.exit(1);
    }

    // Resolve the commit (defaults to HEAD)
    const ref_str = if (args.len > 0) args[0] else "HEAD";
    const oid = repo.resolveRef(allocator, ref_str) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: bad revision '{s}'\n", .{ref_str}) catch
            "fatal: bad revision\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    try appendBisectLog(repo.git_dir, "good", &oid);
    try writeBisectRef(repo.git_dir, "good", oid);

    const hex = oid.toHex();
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Bisecting: marking {s} as good\n", .{hex[0..7]}) catch
        "Bisecting: marked as good\n";
    try stdout_file.writeAll(msg);

    // Try to narrow the range
    try findAndCheckoutMidpoint(repo, allocator);
}

/// Mark a commit as bad.
fn bisectBad(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (!isBisectInProgress(repo.git_dir)) {
        try stderr_file.writeAll("error: no bisect in progress\n");
        std.process.exit(1);
    }

    const ref_str = if (args.len > 0) args[0] else "HEAD";
    const oid = repo.resolveRef(allocator, ref_str) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: bad revision '{s}'\n", .{ref_str}) catch
            "fatal: bad revision\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    try appendBisectLog(repo.git_dir, "bad", &oid);
    try writeBisectRef(repo.git_dir, "bad", oid);

    const hex = oid.toHex();
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Bisecting: marking {s} as bad\n", .{hex[0..7]}) catch
        "Bisecting: marked as bad\n";
    try stdout_file.writeAll(msg);

    try findAndCheckoutMidpoint(repo, allocator);
}

/// Skip a commit.
fn bisectSkip(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (!isBisectInProgress(repo.git_dir)) {
        try stderr_file.writeAll("error: no bisect in progress\n");
        std.process.exit(1);
    }

    const ref_str = if (args.len > 0) args[0] else "HEAD";
    const oid = repo.resolveRef(allocator, ref_str) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "fatal: bad revision '{s}'\n", .{ref_str}) catch
            "fatal: bad revision\n";
        try stderr_file.writeAll(msg);
        std.process.exit(128);
    };

    try appendBisectLog(repo.git_dir, "skip", &oid);

    const hex = oid.toHex();
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Bisecting: skipping {s}\n", .{hex[0..7]}) catch
        "Bisecting: skipped\n";
    try stdout_file.writeAll(msg);

    try findAndCheckoutMidpoint(repo, allocator);
}

/// Reset bisect session.
fn bisectReset(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    if (!isBisectInProgress(repo.git_dir)) {
        try stderr_file.writeAll("error: no bisect in progress\n");
        std.process.exit(1);
    }

    // Read original HEAD from BISECT_START
    const start_data = readFileContentsOpt(allocator, repo.git_dir, BISECT_START);
    defer if (start_data) |d| allocator.free(d);

    if (start_data) |data| {
        var lines = std.mem.splitScalar(u8, data, '\n');
        const oid_line = lines.next();
        const ref_line = lines.next();

        if (oid_line) |ol| {
            if (ol.len >= types.OID_HEX_LEN) {
                const orig_oid = types.ObjectId.fromHex(ol[0..types.OID_HEX_LEN]) catch {
                    cleanupBisect(repo.git_dir);
                    try stdout_file.writeAll("Bisect reset.\n");
                    return;
                };

                // Restore original ref
                if (ref_line) |rl| {
                    const trimmed = std.mem.trimRight(u8, rl, "\n\r ");
                    if (trimmed.len > 0) {
                        ref_mod.updateSymRef(repo.git_dir, "HEAD", trimmed) catch {};
                        ref_mod.createRef(allocator, repo.git_dir, trimmed, orig_oid, null) catch {};
                    }
                }

                // Reset working tree
                var obj = repo.readObject(allocator, &orig_oid) catch {
                    cleanupBisect(repo.git_dir);
                    try stdout_file.writeAll("Bisect reset.\n");
                    return;
                };
                defer obj.deinit();

                if (obj.obj_type == .commit) {
                    const tree_oid = tree_diff.getCommitTreeOid(obj.data) catch {
                        cleanupBisect(repo.git_dir);
                        try stdout_file.writeAll("Bisect reset.\n");
                        return;
                    };
                    resetToTree(allocator, repo, &tree_oid) catch {};
                }
            }
        }
    }

    cleanupBisect(repo.git_dir);
    try stdout_file.writeAll("Bisect reset.\n");
}

/// Show bisect log.
fn bisectLog(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator;
    if (!isBisectInProgress(repo.git_dir)) {
        try stderr_file.writeAll("error: no bisect in progress\n");
        std.process.exit(1);
    }

    var path_buf: [4096]u8 = undefined;
    const path = buildPath(&path_buf, repo.git_dir, BISECT_LOG);

    const file = std.fs.openFileAbsolute(path, .{}) catch {
        try stderr_file.writeAll("error: cannot read bisect log\n");
        std.process.exit(1);
    };
    defer file.close();

    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = file.read(&read_buf) catch break;
        if (n == 0) break;
        try stdout_file.writeAll(read_buf[0..n]);
    }
}

/// Show bisect status.
fn bisectStatus(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    if (!isBisectInProgress(repo.git_dir)) {
        try stderr_file.writeAll("error: no bisect in progress\n");
        std.process.exit(1);
    }

    // Read the current state from the bisect log
    var state = try loadBisectState(allocator, repo.git_dir);
    defer state.deinit();

    const good_count = state.good_commits.items.len;
    var bad_str: [48]u8 = undefined;
    const bad_display = if (state.bad_commit) |b|
        (std.fmt.bufPrint(&bad_str, "{s}", .{b.toHex()[0..7]}) catch "unknown")
    else
        "not set";

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Bisect status: {d} good commit(s), bad={s}\n", .{
        good_count,
        bad_display,
    }) catch "Bisect in progress.\n";
    try stdout_file.writeAll(msg);

    // Estimate remaining steps
    if (good_count > 0 and state.bad_commit != null) {
        const commits_between = try countCommitsBetween(allocator, repo, &state.good_commits.items[0], &state.bad_commit.?);
        if (commits_between > 0) {
            const steps = estimateSteps(commits_between);
            var sbuf: [128]u8 = undefined;
            const smsg = std.fmt.bufPrint(&sbuf, "Approximately {d} steps remaining ({d} commits to test)\n", .{
                steps,
                commits_between,
            }) catch "";
            try stdout_file.writeAll(smsg);
        }
    }
}

/// Find and checkout the midpoint commit.
fn findAndCheckoutMidpoint(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
) !void {
    // Load current bisect state
    var state = try loadBisectState(allocator, repo.git_dir);
    defer state.deinit();

    if (state.good_commits.items.len == 0 or state.bad_commit == null) {
        try stdout_file.writeAll("Waiting for both 'good' and 'bad' commits to start bisecting.\n");
        return;
    }

    const good_oid = state.good_commits.items[0]; // Use first good commit
    const bad_oid = state.bad_commit.?;

    // Collect commits between good and bad
    var commits = try collectCommitsBetween(allocator, repo, &good_oid, &bad_oid);
    defer {
        for (commits.items) |*c| {
            allocator.free(c.hex);
        }
        commits.deinit();
    }

    if (commits.items.len == 0) {
        // The bad commit itself is the first bad commit
        const hex = bad_oid.toHex();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s} is the first bad commit\n", .{hex[0..40]}) catch
            "Found the first bad commit.\n";
        try stdout_file.writeAll(msg);
        return;
    }

    if (commits.items.len == 1) {
        // Only one commit left: the bad commit is the answer
        const hex = bad_oid.toHex();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s} is the first bad commit\n", .{hex[0..40]}) catch
            "Found the first bad commit.\n";
        try stdout_file.writeAll(msg);
        return;
    }

    // Filter out skipped commits
    var valid_commits = std.array_list.Managed(CommitEntry).init(allocator);
    defer valid_commits.deinit();

    for (commits.items) |*c| {
        var is_skipped = false;
        for (state.skipped_commits.items) |*skip| {
            if (c.oid.eql(skip)) {
                is_skipped = true;
                break;
            }
        }
        if (!is_skipped) {
            try valid_commits.append(c.*);
        }
    }

    if (valid_commits.items.len == 0) {
        try stderr_file.writeAll("error: all commits between good and bad are skipped\n");
        std.process.exit(1);
    }

    // Find the midpoint
    const mid_idx = valid_commits.items.len / 2;
    const mid_oid = valid_commits.items[mid_idx].oid;

    // Checkout the midpoint
    try checkoutCommit(allocator, repo, mid_oid);

    const steps = estimateSteps(valid_commits.items.len);
    const hex = mid_oid.toHex();
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Bisecting: roughly {d} steps left ({d} commits). Testing {s}\n", .{
        steps,
        valid_commits.items.len,
        hex[0..7],
    }) catch "Bisecting...\n";
    try stdout_file.writeAll(msg);
}

/// A commit entry with OID and hex for collection purposes.
const CommitEntry = struct {
    oid: types.ObjectId,
    hex: []u8,
};

/// Collect all commits between good (exclusive) and bad (inclusive) in order.
fn collectCommitsBetween(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    good_oid: *const types.ObjectId,
    bad_oid: *const types.ObjectId,
) !std.array_list.Managed(CommitEntry) {
    var result = std.array_list.Managed(CommitEntry).init(allocator);
    errdefer {
        for (result.items) |*c| {
            allocator.free(c.hex);
        }
        result.deinit();
    }

    // Walk from bad backwards until we reach good
    var current_oid = bad_oid.*;
    var iterations: usize = 0;
    const max_iterations: usize = 10000;

    while (iterations < max_iterations) {
        iterations += 1;

        if (current_oid.eql(good_oid)) break;

        // Store the commit
        const hex = current_oid.toHex();
        const hex_copy = try allocator.alloc(u8, hex.len);
        @memcpy(hex_copy, &hex);
        try result.append(.{
            .oid = current_oid,
            .hex = hex_copy,
        });

        // Get parent
        var obj = repo.readObject(allocator, &current_oid) catch break;
        defer obj.deinit();

        if (obj.obj_type != .commit) break;

        var parents = tree_diff.getCommitParents(allocator, obj.data) catch break;
        defer parents.deinit();

        if (parents.items.len == 0) break;
        current_oid = parents.items[0];
    }

    // Reverse to get oldest first
    std.mem.reverse(CommitEntry, result.items);

    return result;
}

/// Count commits between two commits.
fn countCommitsBetween(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    good_oid: *const types.ObjectId,
    bad_oid: *const types.ObjectId,
) !usize {
    var count: usize = 0;
    var current_oid = bad_oid.*;
    var iterations: usize = 0;
    const max_iterations: usize = 10000;

    while (iterations < max_iterations) {
        iterations += 1;

        if (current_oid.eql(good_oid)) break;
        count += 1;

        var obj = repo.readObject(allocator, &current_oid) catch break;
        defer obj.deinit();

        if (obj.obj_type != .commit) break;

        var parents = tree_diff.getCommitParents(allocator, obj.data) catch break;
        defer parents.deinit();

        if (parents.items.len == 0) break;
        current_oid = parents.items[0];
    }

    return count;
}

/// Estimate the number of bisect steps remaining.
fn estimateSteps(n: usize) usize {
    if (n <= 1) return 0;
    var steps: usize = 0;
    var remaining = n;
    while (remaining > 1) {
        remaining /= 2;
        steps += 1;
    }
    return steps;
}

/// Load bisect state from the log file.
fn loadBisectState(allocator: std.mem.Allocator, git_dir: []const u8) !BisectState {
    var state = BisectState.init(allocator);
    errdefer state.deinit();

    // Read the bisect log
    var path_buf: [4096]u8 = undefined;
    const log_path = buildPath(&path_buf, git_dir, BISECT_LOG);

    const content = readFileContents(allocator, log_path) catch return state;
    defer allocator.free(content);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        // Format: "command OID"
        const space_pos = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const cmd = line[0..space_pos];
        const oid_str = line[space_pos + 1 ..];

        if (oid_str.len < types.OID_HEX_LEN) continue;
        const oid = types.ObjectId.fromHex(oid_str[0..types.OID_HEX_LEN]) catch continue;

        if (std.mem.eql(u8, cmd, "good")) {
            try state.good_commits.append(oid);
        } else if (std.mem.eql(u8, cmd, "bad")) {
            state.bad_commit = oid;
        } else if (std.mem.eql(u8, cmd, "skip")) {
            try state.skipped_commits.append(oid);
        }
    }

    return state;
}

/// Checkout a specific commit (detached HEAD).
fn checkoutCommit(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    oid: types.ObjectId,
) !void {
    var obj = try repo.readObject(allocator, &oid);
    defer obj.deinit();

    if (obj.obj_type != .commit) return error.NotACommit;

    const tree_oid = try tree_diff.getCommitTreeOid(obj.data);

    // Flatten tree and update working tree
    try resetToTree(allocator, repo, &tree_oid);

    // Write detached HEAD
    try writeDetachedHead(repo.git_dir, oid);
}

/// Append an entry to the bisect log.
fn appendBisectLog(git_dir: []const u8, cmd: []const u8, oid: *const types.ObjectId) !void {
    var path_buf: [4096]u8 = undefined;
    const path = buildPath(&path_buf, git_dir, BISECT_LOG);

    const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch {
        const f = try std.fs.createFileAbsolute(path, .{});
        defer f.close();
        try f.writeAll("# bisect log\n");
        const hex = oid.toHex();
        try f.writeAll(cmd);
        try f.writeAll(" ");
        try f.writeAll(&hex);
        try f.writeAll("\n");
        return;
    };
    defer file.close();

    const stat = try file.stat();
    try file.seekTo(stat.size);

    const hex = oid.toHex();
    try file.writeAll(cmd);
    try file.writeAll(" ");
    try file.writeAll(&hex);
    try file.writeAll("\n");
}

/// Write a bisect ref (good/bad) for reference purposes.
fn writeBisectRef(git_dir: []const u8, kind: []const u8, oid: types.ObjectId) !void {
    // Write to refs/bisect/<kind>
    var path_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    @memcpy(path_buf[pos..][0..git_dir.len], git_dir);
    pos += git_dir.len;
    const prefix = "/refs/bisect/";
    @memcpy(path_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(path_buf[pos..][0..kind.len], kind);
    pos += kind.len;
    const ref_path = path_buf[0..pos];

    // Ensure directory exists
    const dir_end = std.mem.lastIndexOfScalar(u8, ref_path, '/') orelse return;
    mkdirRecursive(ref_path[0..dir_end]) catch {};

    const hex = oid.toHex();
    var content_buf: [types.OID_HEX_LEN + 1]u8 = undefined;
    @memcpy(content_buf[0..types.OID_HEX_LEN], &hex);
    content_buf[types.OID_HEX_LEN] = '\n';

    const file = try std.fs.createFileAbsolute(ref_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(&content_buf);
}

/// Check if bisect is in progress.
fn isBisectInProgress(git_dir: []const u8) bool {
    var path_buf: [4096]u8 = undefined;
    const path = buildPath(&path_buf, git_dir, BISECT_START);
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

/// Clean up all bisect state files.
fn cleanupBisect(git_dir: []const u8) void {
    const files_to_remove = [_][]const u8{
        BISECT_LOG,
        BISECT_START,
        BISECT_EXPECTED_REV,
        BISECT_ANCESTORS_OK,
        BISECT_NAMES,
    };

    for (files_to_remove) |suffix| {
        var path_buf: [4096]u8 = undefined;
        const path = buildPath(&path_buf, git_dir, suffix);
        std.fs.deleteFileAbsolute(path) catch {};
    }

    // Remove refs/bisect/
    var dir_buf: [4096]u8 = undefined;
    const refs_dir = buildPath(&dir_buf, git_dir, "/refs/bisect");

    var dir = std.fs.openDirAbsolute(refs_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file) {
            dir.deleteFile(entry.name) catch {};
        }
    }

    std.fs.deleteDirAbsolute(refs_dir) catch {};
}

/// Reset working tree and index to a tree.
fn resetToTree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    tree_oid: *const types.ObjectId,
) !void {
    const work_dir = getWorkDir(repo.git_dir);

    var flat = try checkout_mod.flattenTree(allocator, repo, tree_oid);
    defer flat.deinit();

    for (flat.entries.items) |*entry| {
        writeBlobToWorkTree(allocator, repo, work_dir, entry.path, &entry.oid) catch continue;
    }

    var idx = index_mod.Index.init(allocator);
    defer idx.deinit();

    for (flat.entries.items) |*entry| {
        const name_copy = try allocator.alloc(u8, entry.path.len);
        @memcpy(name_copy, entry.path);
        try idx.addEntry(.{
            .ctime_s = 0,
            .ctime_ns = 0,
            .mtime_s = 0,
            .mtime_ns = 0,
            .dev = 0,
            .ino = 0,
            .mode = entry.mode,
            .uid = 0,
            .gid = 0,
            .file_size = 0,
            .oid = entry.oid,
            .flags = 0,
            .name = name_copy,
            .owned = true,
        });
    }

    var index_path_buf: [4096]u8 = undefined;
    const index_path = buildPath(&index_path_buf, repo.git_dir, "/index");
    try idx.writeToFile(index_path);
}

fn writeBlobToWorkTree(
    allocator: std.mem.Allocator,
    repo: *repository.Repository,
    work_dir: []const u8,
    rel_path: []const u8,
    oid: *const types.ObjectId,
) !void {
    var obj = try repo.readObject(allocator, oid);
    defer obj.deinit();

    if (obj.obj_type != .blob) return error.NotABlob;

    var path_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&path_buf);
    const writer = stream.writer();
    try writer.writeAll(work_dir);
    try writer.writeByte('/');
    try writer.writeAll(rel_path);
    const full_path = path_buf[0..stream.pos];

    const dir_end = std.mem.lastIndexOfScalar(u8, full_path, '/') orelse return error.InvalidPath;
    mkdirRecursive(full_path[0..dir_end]) catch {};

    const file = try std.fs.createFileAbsolute(full_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(obj.data);
}

fn writeDetachedHead(git_dir: []const u8, oid: types.ObjectId) !void {
    var path_buf: [4096]u8 = undefined;
    const path = buildPath(&path_buf, git_dir, "/HEAD");
    const hex = oid.toHex();
    var content_buf: [types.OID_HEX_LEN + 1]u8 = undefined;
    @memcpy(content_buf[0..types.OID_HEX_LEN], &hex);
    content_buf[types.OID_HEX_LEN] = '\n';
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(&content_buf);
}

fn readFileContentsOpt(allocator: std.mem.Allocator, git_dir: []const u8, suffix: []const u8) ?[]u8 {
    var path_buf: [4096]u8 = undefined;
    const path = buildPath(&path_buf, git_dir, suffix);
    return readFileContents(allocator, path) catch return null;
}

fn getWorkDir(git_dir: []const u8) []const u8 {
    if (std.mem.endsWith(u8, git_dir, "/.git")) {
        return git_dir[0 .. git_dir.len - 5];
    }
    if (std.fs.path.dirname(git_dir)) |parent| return parent;
    return git_dir;
}

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

fn mkdirRecursive(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
            try mkdirRecursive(parent);
            std.fs.makeDirAbsolute(path) catch |err2| switch (err2) {
                error.PathAlreadyExists => return,
                else => return err2,
            };
        },
        else => return err,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "estimateSteps" {
    try std.testing.expectEqual(@as(usize, 0), estimateSteps(1));
    try std.testing.expectEqual(@as(usize, 1), estimateSteps(2));
    try std.testing.expectEqual(@as(usize, 2), estimateSteps(4));
    try std.testing.expectEqual(@as(usize, 3), estimateSteps(8));
    try std.testing.expectEqual(@as(usize, 4), estimateSteps(16));
    try std.testing.expectEqual(@as(usize, 6), estimateSteps(100));
}

test "parseBisectCommand" {
    try std.testing.expect(parseBisectCommand("start") == .start);
    try std.testing.expect(parseBisectCommand("good") == .good);
    try std.testing.expect(parseBisectCommand("bad") == .bad);
    try std.testing.expect(parseBisectCommand("old") == .good);
    try std.testing.expect(parseBisectCommand("new") == .bad);
    try std.testing.expect(parseBisectCommand("reset") == .reset);
    try std.testing.expect(parseBisectCommand("unknown") == null);
}

test "BisectState init/deinit" {
    const allocator = std.testing.allocator;
    var state = BisectState.init(allocator);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 0), state.good_commits.items.len);
    try std.testing.expect(state.bad_commit == null);
}

test "buildPath" {
    var buf: [256]u8 = undefined;
    const result = buildPath(&buf, "/foo", "/bar");
    try std.testing.expectEqualStrings("/foo/bar", result);
}
