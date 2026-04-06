const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const config_mod = @import("config.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

/// Options for the send-email command.
pub const SendEmailOptions = struct {
    to: std.array_list.Managed([]const u8),
    cc: std.array_list.Managed([]const u8),
    subject_prefix: []const u8,
    in_reply_to: []const u8,
    dry_run: bool,
    smtp_server: []const u8,
    smtp_port: u16,
    smtp_user: []const u8,
    from: []const u8,
    compose: bool,
    annotate: bool,
    cover_letter: bool,

    pub fn init(allocator: std.mem.Allocator) SendEmailOptions {
        return .{
            .to = std.array_list.Managed([]const u8).init(allocator),
            .cc = std.array_list.Managed([]const u8).init(allocator),
            .subject_prefix = "PATCH",
            .in_reply_to = "",
            .dry_run = true, // Default to dry-run for safety
            .smtp_server = "",
            .smtp_port = 587,
            .smtp_user = "",
            .from = "",
            .compose = false,
            .annotate = false,
            .cover_letter = false,
        };
    }

    pub fn deinit(self: *SendEmailOptions) void {
        self.to.deinit();
        self.cc.deinit();
    }
};

/// Email message to be sent.
const EmailMessage = struct {
    from: []const u8,
    to: []const u8,
    cc: []const u8,
    subject: []const u8,
    in_reply_to: []const u8,
    message_id: []const u8,
    body: []const u8,
};

/// Run the send-email command.
pub fn runSendEmail(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = SendEmailOptions.init(allocator);
    defer opts.deinit();

    var patch_files = std.array_list.Managed([]const u8).init(allocator);
    defer patch_files.deinit();

    // Load SMTP config from git config
    loadSmtpConfig(repo, allocator, &opts);

    // Parse command line arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--to")) {
            i += 1;
            if (i < args.len) try opts.to.append(args[i]);
        } else if (std.mem.eql(u8, arg, "--cc")) {
            i += 1;
            if (i < args.len) try opts.cc.append(args[i]);
        } else if (std.mem.eql(u8, arg, "--from")) {
            i += 1;
            if (i < args.len) opts.from = args[i];
        } else if (std.mem.eql(u8, arg, "--subject-prefix")) {
            i += 1;
            if (i < args.len) opts.subject_prefix = args[i];
        } else if (std.mem.eql(u8, arg, "--in-reply-to")) {
            i += 1;
            if (i < args.len) opts.in_reply_to = args[i];
        } else if (std.mem.eql(u8, arg, "--smtp-server")) {
            i += 1;
            if (i < args.len) opts.smtp_server = args[i];
        } else if (std.mem.eql(u8, arg, "--smtp-server-port")) {
            i += 1;
            if (i < args.len) opts.smtp_port = std.fmt.parseInt(u16, args[i], 10) catch 587;
        } else if (std.mem.eql(u8, arg, "--smtp-user")) {
            i += 1;
            if (i < args.len) opts.smtp_user = args[i];
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--no-dry-run")) {
            opts.dry_run = false;
        } else if (std.mem.eql(u8, arg, "--compose")) {
            opts.compose = true;
        } else if (std.mem.eql(u8, arg, "--annotate")) {
            opts.annotate = true;
        } else if (std.mem.eql(u8, arg, "--cover-letter")) {
            opts.cover_letter = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try patch_files.append(arg);
        }
    }

    if (patch_files.items.len == 0) {
        try stderr_file.writeAll(send_email_usage);
        return;
    }

    if (opts.to.items.len == 0) {
        try stderr_file.writeAll("error: no --to specified\n");
        try stderr_file.writeAll("hint: Configure sendemail.to in git config or use --to\n");
        return;
    }

    // Process each patch file
    const total = patch_files.items.len;
    var msg_ids = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (msg_ids.items) |mid| allocator.free(mid);
        msg_ids.deinit();
    }

    for (patch_files.items, 0..) |patch_file, idx| {
        const patch_num = idx + 1;

        // Read the patch file
        const content = readFile(allocator, patch_file) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: could not read {s}: {s}\n", .{ patch_file, @errorName(err) }) catch
                "error: could not read patch file\n";
            try stderr_file.writeAll(msg);
            continue;
        };
        defer allocator.free(content);

        // Parse the patch email headers
        var subject: []const u8 = "";
        var from: []const u8 = opts.from;
        var date: []const u8 = "";
        var body_start: usize = 0;

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        var in_headers = true;
        var pos: usize = 0;

        // Skip the "From HASH date" line
        if (line_iter.next()) |first_line| {
            pos += first_line.len + 1;
            if (!std.mem.startsWith(u8, first_line, "From ")) {
                // Not a standard mbox format, treat as raw patch
                in_headers = false;
                body_start = 0;
            }
        }

        if (in_headers) {
            while (line_iter.next()) |raw_line| {
                pos += raw_line.len + 1;
                const line = std.mem.trimRight(u8, raw_line, "\r");

                if (line.len == 0) {
                    body_start = pos;
                    break;
                }

                if (std.mem.startsWith(u8, line, "Subject: ")) {
                    subject = line["Subject: ".len..];
                } else if (std.mem.startsWith(u8, line, "From: ")) {
                    if (from.len == 0) from = line["From: ".len..];
                } else if (std.mem.startsWith(u8, line, "Date: ")) {
                    date = line["Date: ".len..];
                }
            }
        }

        // Generate a message ID
        var msg_id_buf: [128]u8 = undefined;
        const msg_id = std.fmt.bufPrint(&msg_id_buf, "<{d}.{d}.zig-git@localhost>", .{ patch_num, total }) catch "<zig-git@localhost>";

        const msg_id_copy = try allocator.alloc(u8, msg_id.len);
        @memcpy(msg_id_copy, msg_id);
        try msg_ids.append(msg_id_copy);

        // Build the email
        const in_reply_to = if (opts.in_reply_to.len > 0) opts.in_reply_to else if (idx > 0 and msg_ids.items.len > 1) @as([]const u8, msg_ids.items[0]) else "";

        // Format to/cc lists
        var to_str_buf: [4096]u8 = undefined;
        const to_str = formatAddrList(&to_str_buf, opts.to.items);

        var cc_str_buf: [4096]u8 = undefined;
        const cc_str = formatAddrList(&cc_str_buf, opts.cc.items);

        if (opts.dry_run) {
            try stdout_file.writeAll("=== Email ===\n");

            var buf: [4096]u8 = undefined;
            var line2 = std.fmt.bufPrint(&buf, "From: {s}\n", .{from}) catch "";
            try stdout_file.writeAll(line2);

            line2 = std.fmt.bufPrint(&buf, "To: {s}\n", .{to_str}) catch "";
            try stdout_file.writeAll(line2);

            if (cc_str.len > 0) {
                line2 = std.fmt.bufPrint(&buf, "Cc: {s}\n", .{cc_str}) catch "";
                try stdout_file.writeAll(line2);
            }

            line2 = std.fmt.bufPrint(&buf, "Subject: {s}\n", .{subject}) catch "";
            try stdout_file.writeAll(line2);

            if (date.len > 0) {
                line2 = std.fmt.bufPrint(&buf, "Date: {s}\n", .{date}) catch "";
                try stdout_file.writeAll(line2);
            }

            line2 = std.fmt.bufPrint(&buf, "Message-Id: {s}\n", .{msg_id}) catch "";
            try stdout_file.writeAll(line2);

            if (in_reply_to.len > 0) {
                line2 = std.fmt.bufPrint(&buf, "In-Reply-To: {s}\n", .{in_reply_to}) catch "";
                try stdout_file.writeAll(line2);
            }

            try stdout_file.writeAll("X-Mailer: zig-git-send-email 0.2.0\n");
            try stdout_file.writeAll("MIME-Version: 1.0\n");
            try stdout_file.writeAll("Content-Type: text/plain; charset=UTF-8\n");
            try stdout_file.writeAll("Content-Transfer-Encoding: 8bit\n");
            try stdout_file.writeAll("\n");

            // Write body
            if (body_start < content.len) {
                try stdout_file.writeAll(content[body_start..]);
            }

            try stdout_file.writeAll("\n=== End ===\n\n");

            line2 = std.fmt.bufPrint(&buf, "(dry-run) Would send email {d}/{d}: {s}\n", .{ patch_num, total, subject }) catch
                "(dry-run) Would send email\n";
            try stderr_file.writeAll(line2);
        } else {
            // Actual sending would go here, but we just show a message
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Sending email {d}/{d}: {s}\n", .{ patch_num, total, subject }) catch
                "Sending email...\n";
            try stderr_file.writeAll(msg);

            try stderr_file.writeAll("warning: actual SMTP sending is not implemented\n");
            try stderr_file.writeAll("hint: Use --dry-run to preview emails\n");
        }

    }

    if (opts.dry_run) {
        var buf: [128]u8 = undefined;
        const summary = std.fmt.bufPrint(&buf, "\nDry-run complete. {d} email(s) would be sent.\n", .{patch_files.items.len}) catch
            "\nDry-run complete.\n";
        try stdout_file.writeAll(summary);
    }
}

const send_email_usage =
    \\usage: zig-git send-email [options] <patch-files>...
    \\
    \\Options:
    \\  --to <addr>            Recipient email address
    \\  --cc <addr>            CC email address
    \\  --from <addr>          Sender email address
    \\  --subject-prefix <pre> Subject prefix (default: PATCH)
    \\  --in-reply-to <id>     Message-Id to reply to
    \\  --smtp-server <host>   SMTP server hostname
    \\  --smtp-server-port <p> SMTP server port (default: 587)
    \\  --smtp-user <user>     SMTP username
    \\  --dry-run              Show what would be sent (default)
    \\  --no-dry-run           Actually attempt to send
    \\  --compose              Open editor for cover letter
    \\  --annotate             Open editor for each patch
    \\  --cover-letter         Generate a cover letter
    \\
;

/// Load SMTP configuration from git config.
fn loadSmtpConfig(repo: *repository.Repository, allocator: std.mem.Allocator, opts: *SendEmailOptions) void {
    var config_path_buf: [4096]u8 = undefined;
    @memcpy(config_path_buf[0..repo.git_dir.len], repo.git_dir);
    const suffix = "/config";
    @memcpy(config_path_buf[repo.git_dir.len..][0..suffix.len], suffix);
    const config_path = config_path_buf[0 .. repo.git_dir.len + suffix.len];

    var cfg = config_mod.Config.loadFile(allocator, config_path) catch return;
    defer cfg.deinit();

    if (cfg.get("sendemail.smtpserver")) |v| {
        opts.smtp_server = v;
    }
    if (cfg.get("sendemail.smtpserverport")) |v| {
        opts.smtp_port = std.fmt.parseInt(u16, v, 10) catch 587;
    }
    if (cfg.get("sendemail.smtpuser")) |v| {
        opts.smtp_user = v;
    }
    if (cfg.get("sendemail.from")) |v| {
        opts.from = v;
    }
    if (cfg.get("sendemail.to")) |v| {
        opts.to.append(v) catch {};
    }
    if (cfg.get("sendemail.cc")) |v| {
        opts.cc.append(v) catch {};
    }
    if (cfg.get("sendemail.subjectprefix")) |v| {
        opts.subject_prefix = v;
    }
}

fn formatAddrList(buf: []u8, addrs: []const []const u8) []const u8 {
    var pos: usize = 0;
    for (addrs, 0..) |addr, idx| {
        if (idx > 0) {
            if (pos + 2 > buf.len) break;
            buf[pos] = ',';
            buf[pos + 1] = ' ';
            pos += 2;
        }
        if (pos + addr.len > buf.len) break;
        @memcpy(buf[pos..][0..addr.len], addr);
        pos += addr.len;
    }
    return buf[0..pos];
}

/// Generate a cover letter for a patch series.
pub fn generateCoverLetterEmail(
    allocator: std.mem.Allocator,
    total_patches: usize,
    opts: *const SendEmailOptions,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var buf: [4096]u8 = undefined;

    var line = std.fmt.bufPrint(&buf, "From: {s}\n", .{opts.from}) catch return output.toOwnedSlice();
    try output.appendSlice(line);

    var to_str_buf: [4096]u8 = undefined;
    const to_str = formatAddrList(&to_str_buf, opts.to.items);
    line = std.fmt.bufPrint(&buf, "To: {s}\n", .{to_str}) catch return output.toOwnedSlice();
    try output.appendSlice(line);

    line = std.fmt.bufPrint(&buf, "Subject: [{s} 0/{d}] *** SUBJECT HERE ***\n", .{ opts.subject_prefix, total_patches }) catch return output.toOwnedSlice();
    try output.appendSlice(line);

    try output.appendSlice("MIME-Version: 1.0\n");
    try output.appendSlice("Content-Type: text/plain; charset=UTF-8\n");
    try output.appendSlice("\n");
    try output.appendSlice("*** BLURB HERE ***\n\n");
    try output.appendSlice("-- \n");
    try output.appendSlice("zig-git version 0.2.0\n");

    return output.toOwnedSlice();
}

/// Format a single patch as an email ready to send.
pub fn formatPatchAsEmail(
    allocator: std.mem.Allocator,
    patch_content: []const u8,
    num: usize,
    total: usize,
    opts: *const SendEmailOptions,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var buf: [4096]u8 = undefined;

    // Extract subject from patch content
    var subject: []const u8 = "patch";
    var line_iter = std.mem.splitScalar(u8, patch_content, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "Subject: ")) {
            subject = line["Subject: ".len..];
            break;
        }
    }

    var line2 = std.fmt.bufPrint(&buf, "From: {s}\n", .{opts.from}) catch return output.toOwnedSlice();
    try output.appendSlice(line2);

    var to_str_buf: [4096]u8 = undefined;
    const to_str = formatAddrList(&to_str_buf, opts.to.items);
    line2 = std.fmt.bufPrint(&buf, "To: {s}\n", .{to_str}) catch return output.toOwnedSlice();
    try output.appendSlice(line2);

    if (opts.cc.items.len > 0) {
        var cc_str_buf: [4096]u8 = undefined;
        const cc_str = formatAddrList(&cc_str_buf, opts.cc.items);
        line2 = std.fmt.bufPrint(&buf, "Cc: {s}\n", .{cc_str}) catch return output.toOwnedSlice();
        try output.appendSlice(line2);
    }

    line2 = std.fmt.bufPrint(&buf, "Subject: [{s} {d}/{d}] {s}\n", .{ opts.subject_prefix, num, total, subject }) catch return output.toOwnedSlice();
    try output.appendSlice(line2);

    line2 = std.fmt.bufPrint(&buf, "Message-Id: <{d}.{d}.zig-git@localhost>\n", .{ num, total }) catch return output.toOwnedSlice();
    try output.appendSlice(line2);

    if (opts.in_reply_to.len > 0) {
        line2 = std.fmt.bufPrint(&buf, "In-Reply-To: {s}\n", .{opts.in_reply_to}) catch return output.toOwnedSlice();
        try output.appendSlice(line2);
    }

    try output.appendSlice("X-Mailer: zig-git-send-email 0.2.0\n");
    try output.appendSlice("MIME-Version: 1.0\n");
    try output.appendSlice("Content-Type: text/plain; charset=UTF-8\n");
    try output.appendSlice("Content-Transfer-Encoding: 8bit\n");
    try output.appendSlice("\n");
    try output.appendSlice(patch_content);

    return output.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        const stat = try file.stat();
        if (stat.size > 50 * 1024 * 1024) return error.FileTooLarge;
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
    const file = std.fs.cwd().openFile(path, .{}) catch return error.FileNotFound;
    defer file.close();
    const stat = try file.stat();
    if (stat.size > 50 * 1024 * 1024) return error.FileTooLarge;
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

test "formatAddrList" {
    var buf: [256]u8 = undefined;
    const addrs = [_][]const u8{ "alice@example.com", "bob@example.com" };
    const result = formatAddrList(&buf, &addrs);
    try std.testing.expectEqualStrings("alice@example.com, bob@example.com", result);
}

test "formatAddrList single" {
    var buf: [256]u8 = undefined;
    const addrs = [_][]const u8{"alice@example.com"};
    const result = formatAddrList(&buf, &addrs);
    try std.testing.expectEqualStrings("alice@example.com", result);
}
