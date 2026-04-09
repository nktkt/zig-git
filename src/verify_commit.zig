const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const commit_info = @import("commit_info.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Verification result.
pub const VerifyResult = enum(u8) {
    /// Good signature verified.
    good = 0,
    /// No signature present.
    no_signature = 1,
    /// Bad or unverifiable signature.
    bad_signature = 2,
    /// Error reading/parsing.
    err = 3,
};

/// Options for verify-commit/verify-tag.
pub const VerifyOptions = struct {
    /// Show raw GPG output.
    raw: bool = false,
    /// Verbose output.
    verbose: bool = false,
};

/// Run the verify-commit command.
pub fn runVerifyCommit(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = VerifyOptions{};
    var refs = std.array_list.Managed([]const u8).init(allocator);
    defer refs.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--raw")) {
            opts.raw = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try refs.append(arg);
        }
    }

    if (refs.items.len == 0) {
        try stderr_file.writeAll("usage: zig-git verify-commit [--raw] [-v] <commit>...\n");
        std.process.exit(1);
    }

    var worst_result: u8 = 0;

    for (refs.items) |ref_str| {
        const result = verifyCommitSignature(repo, allocator, ref_str, &opts);
        if (@intFromEnum(result) > worst_result) {
            worst_result = @intFromEnum(result);
        }
    }

    std.process.exit(worst_result);
}

/// Run the verify-tag command.
pub fn runVerifyTag(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = VerifyOptions{};
    var refs = std.array_list.Managed([]const u8).init(allocator);
    defer refs.deinit();

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--raw")) {
            opts.raw = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try refs.append(arg);
        }
    }

    if (refs.items.len == 0) {
        try stderr_file.writeAll("usage: zig-git verify-tag [--raw] [-v] <tag>...\n");
        std.process.exit(1);
    }

    var worst_result: u8 = 0;

    for (refs.items) |ref_str| {
        const result = verifyTagSignature(repo, allocator, ref_str, &opts);
        if (@intFromEnum(result) > worst_result) {
            worst_result = @intFromEnum(result);
        }
    }

    std.process.exit(worst_result);
}

/// Verify the GPG signature of a commit.
fn verifyCommitSignature(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    ref_str: []const u8,
    opts: *const VerifyOptions,
) VerifyResult {
    const oid = repo.resolveRef(allocator, ref_str) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: could not resolve '{s}'\n", .{ref_str}) catch "error: could not resolve ref\n";
        stderr_file.writeAll(msg) catch {};
        return .err;
    };

    var obj = repo.readObject(allocator, &oid) catch {
        stderr_file.writeAll("error: could not read object\n") catch {};
        return .err;
    };
    defer obj.deinit();

    if (obj.obj_type != .commit) {
        stderr_file.writeAll("error: object is not a commit\n") catch {};
        return .err;
    }

    const hex = oid.toHex();

    // Check for signature
    if (!commit_info.isSignedCommit(obj.data)) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: no signature found in commit {s}\n", .{hex[0..7]}) catch "error: no signature found\n";
        stderr_file.writeAll(msg) catch {};
        return .no_signature;
    }

    // Extract the signature
    const sig = commit_info.extractSignature(obj.data);
    if (sig == null) {
        stderr_file.writeAll("error: could not extract signature\n") catch {};
        return .no_signature;
    }

    // Strip signature to get signed payload
    const payload = commit_info.stripSignature(allocator, obj.data) catch {
        stderr_file.writeAll("error: could not strip signature\n") catch {};
        return .err;
    };
    defer allocator.free(payload);

    // Try to verify with gpg
    return gpgVerify(allocator, sig.?, payload, &hex, opts);
}

/// Verify the GPG signature of a tag.
fn verifyTagSignature(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    ref_str: []const u8,
    opts: *const VerifyOptions,
) VerifyResult {
    // Try to resolve as tag ref
    const tag_oid = resolveTagRef(repo, allocator, ref_str) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: could not resolve tag '{s}'\n", .{ref_str}) catch "error: could not resolve tag\n";
        stderr_file.writeAll(msg) catch {};
        return .err;
    };

    var obj = repo.readObject(allocator, &tag_oid) catch {
        stderr_file.writeAll("error: could not read tag object\n") catch {};
        return .err;
    };
    defer obj.deinit();

    if (obj.obj_type != .tag) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: {s} is not a tag object\n", .{ref_str}) catch "error: not a tag object\n";
        stderr_file.writeAll(msg) catch {};
        return .err;
    }

    const hex = tag_oid.toHex();

    // Check for PGP/SSH signature in tag data
    const begin_pgp = "-----BEGIN PGP SIGNATURE-----";
    const begin_ssh = "-----BEGIN SSH SIGNATURE-----";

    const has_pgp = std.mem.indexOf(u8, obj.data, begin_pgp);
    const has_ssh = std.mem.indexOf(u8, obj.data, begin_ssh);

    if (has_pgp == null and has_ssh == null) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: no signature found in tag {s}\n", .{ref_str}) catch "error: no signature found in tag\n";
        stderr_file.writeAll(msg) catch {};
        return .no_signature;
    }

    // The tag signature is appended after the tag body.
    // The signed payload is everything before the signature.
    const sig_start = has_pgp orelse has_ssh orelse unreachable;
    const payload = obj.data[0..sig_start];
    const sig = obj.data[sig_start..];

    return gpgVerify(allocator, sig, payload, &hex, opts);
}

/// Resolve a tag reference to its OID.
fn resolveTagRef(repo: *repository.Repository, allocator: std.mem.Allocator, ref_str: []const u8) !types.ObjectId {
    // Try "refs/tags/<name>" first
    if (repo.resolveRef(allocator, ref_str)) |oid| {
        return oid;
    } else |_| {}

    // Try with explicit prefix
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    stream.writer().print("refs/tags/{s}", .{ref_str}) catch return error.BufferTooSmall;
    const full_ref = buf[0..stream.pos];

    return repo.resolveRef(allocator, full_ref);
}

/// Verify a detached signature using gpg.
fn gpgVerify(
    allocator: std.mem.Allocator,
    signature: []const u8,
    payload: []const u8,
    hex: *const [types.OID_HEX_LEN]u8,
    opts: *const VerifyOptions,
) VerifyResult {
    // Write signature to a temp file
    const sig_path = writeTempFile(allocator, signature, "zig-git-sig-") catch {
        // Cannot create temp file, try inline verification
        reportCannotVerify(hex, opts);
        return .bad_signature;
    };
    defer {
        std.fs.deleteFileAbsolute(sig_path) catch {};
        allocator.free(sig_path);
    }

    // Write payload to a temp file
    const payload_path = writeTempFile(allocator, payload, "zig-git-payload-") catch {
        reportCannotVerify(hex, opts);
        return .bad_signature;
    };
    defer {
        std.fs.deleteFileAbsolute(payload_path) catch {};
        allocator.free(payload_path);
    }

    // Try gpg --verify
    const gpg_result = runGpgVerify(allocator, sig_path, payload_path);

    switch (gpg_result.exit_code) {
        0 => {
            // Good signature
            if (opts.raw) {
                if (gpg_result.output) |output| {
                    stdout_file.writeAll(output) catch {};
                }
            } else {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Good signature for {s}\n", .{hex[0..7]}) catch "Good signature\n";
                stdout_file.writeAll(msg) catch {};
            }

            if (gpg_result.output) |output| allocator.free(output);
            return .good;
        },
        1 => {
            // Bad signature
            if (opts.raw) {
                if (gpg_result.output) |output| {
                    stderr_file.writeAll(output) catch {};
                }
            } else {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Bad signature for {s}\n", .{hex[0..7]}) catch "Bad signature\n";
                stderr_file.writeAll(msg) catch {};
            }

            if (gpg_result.output) |output| allocator.free(output);
            return .bad_signature;
        },
        else => {
            // GPG not available or other error
            reportCannotVerify(hex, opts);
            if (gpg_result.output) |output| allocator.free(output);
            return .bad_signature;
        },
    }
}

fn reportCannotVerify(hex: *const [types.OID_HEX_LEN]u8, opts: *const VerifyOptions) void {
    _ = opts;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error: could not verify signature for {s} (gpg not available?)\n", .{hex[0..7]}) catch "error: could not verify signature\n";
    stderr_file.writeAll(msg) catch {};
}

const GpgResult = struct {
    exit_code: u8,
    output: ?[]u8,
};

fn runGpgVerify(allocator: std.mem.Allocator, sig_path: []const u8, payload_path: []const u8) GpgResult {
    // Build argv
    const argv = [_][]const u8{
        "gpg",
        "--verify",
        sig_path,
        payload_path,
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    child.spawn() catch {
        return .{ .exit_code = 127, .output = null };
    };

    // Read output
    var output_buf = std.array_list.Managed(u8).init(allocator);
    defer output_buf.deinit();

    if (child.stderr) |stderr_pipe| {
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = stderr_pipe.read(&read_buf) catch break;
            if (n == 0) break;
            output_buf.appendSlice(read_buf[0..n]) catch break;
        }
    }

    const term = child.wait() catch {
        return .{ .exit_code = 127, .output = null };
    };

    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 127,
    };

    const output = if (output_buf.items.len > 0)
        output_buf.toOwnedSlice() catch null
    else
        null;

    return .{ .exit_code = exit_code, .output = output };
}

/// Write data to a temp file and return the path.
fn writeTempFile(allocator: std.mem.Allocator, data: []const u8, prefix: []const u8) ![]u8 {
    var path_buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&path_buf);
    const writer = stream.writer();
    try writer.writeAll("/tmp/");
    try writer.writeAll(prefix);

    // Use timestamp for uniqueness
    const ts = std.posix.clock_gettime(.REALTIME) catch std.posix.timespec{ .sec = 0, .nsec = 0 };
    try writer.print("{d}_{d}", .{ ts.sec, ts.nsec });

    const path = path_buf[0..stream.pos];

    // Write the file
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);

    const result = try allocator.alloc(u8, path.len);
    @memcpy(result, path);
    return result;
}

test "VerifyResult values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(VerifyResult.good));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(VerifyResult.no_signature));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(VerifyResult.bad_signature));
}
