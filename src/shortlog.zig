const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const log_mod = @import("log.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

const shortlog_usage =
    \\usage: zig-git shortlog [options] [<revision-range>]
    \\
    \\  -n, --numbered   Sort output by number of commits per author (descending)
    \\  -s, --summary    Suppress commit descriptions, show only counts
    \\  -e, --email      Show the email address of each author
    \\  --no-merges      Exclude merge commits
    \\  --all            Use all refs (not just HEAD)
    \\  --format=<fmt>   Custom format for commit description (placeholder: %s = subject)
    \\
;

/// Options for the shortlog command.
const ShortlogOptions = struct {
    /// Sort by commit count instead of alphabetically.
    numbered: bool = false,
    /// Show only counts (summary mode).
    summary: bool = false,
    /// Show email addresses.
    show_email: bool = false,
    /// Exclude merge commits.
    no_merges: bool = false,
    /// Maximum number of commits to process (0 = unlimited).
    max_count: usize = 0,
    /// Starting ref (default: HEAD).
    start_ref: []const u8 = "HEAD",
    /// Group key (author or committer).
    group_by_committer: bool = false,
};

/// An author entry in the shortlog output.
const AuthorEntry = struct {
    /// The author's display name (and optionally email).
    name: []const u8,
    /// List of commit subject lines by this author.
    subjects: std.array_list.Managed([]const u8),
    /// Count of commits.
    count: usize,
};

/// Entry point for the shortlog command.
pub fn runShortlog(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    var opts = ShortlogOptions{};

    // Parse arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--numbered")) {
            opts.numbered = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--summary")) {
            opts.summary = true;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--email")) {
            opts.show_email = true;
        } else if (std.mem.eql(u8, arg, "-sn") or std.mem.eql(u8, arg, "-ns")) {
            opts.summary = true;
            opts.numbered = true;
        } else if (std.mem.eql(u8, arg, "-sne") or std.mem.eql(u8, arg, "-nse") or
            std.mem.eql(u8, arg, "-ens") or std.mem.eql(u8, arg, "-esn") or
            std.mem.eql(u8, arg, "-nes") or std.mem.eql(u8, arg, "-sen"))
        {
            opts.summary = true;
            opts.numbered = true;
            opts.show_email = true;
        } else if (std.mem.eql(u8, arg, "--no-merges")) {
            opts.no_merges = true;
        } else if (std.mem.eql(u8, arg, "--committer")) {
            opts.group_by_committer = true;
        } else if (std.mem.startsWith(u8, arg, "--max-count=")) {
            const val = arg["--max-count=".len..];
            opts.max_count = std.fmt.parseInt(usize, val, 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // Check for -nNUM format
            if (arg.len > 2 and arg[1] == 'n') {
                // Might be -n followed by a number without space
            }
            // Ignore other unknown flags silently for compatibility
        } else {
            opts.start_ref = arg;
        }
    }

    // Resolve starting commit
    const start_oid = repo.resolveRef(allocator, opts.start_ref) catch |err| {
        switch (err) {
            error.ObjectNotFound => {
                // Empty repo - nothing to show
                return;
            },
            else => return err,
        }
    };

    // Walk commit history and group by author
    var authors_map = AuthorMap.init(allocator);
    defer authors_map.deinit();

    var walker = log_mod.CommitWalker.init(allocator, repo);
    defer walker.deinit();

    try walker.push(start_oid);

    var count: usize = 0;

    while (try walker.next()) |oid| {
        if (opts.max_count > 0 and count >= opts.max_count) break;

        var commit = log_mod.parseCommit(allocator, repo, &oid) catch continue;
        defer commit.deinit();

        // Skip merge commits if --no-merges
        if (opts.no_merges and commit.parents.items.len > 1) continue;

        // Get author name/email
        const author_key = if (opts.group_by_committer)
            buildAuthorKey(allocator, commit.committer_name, commit.committer_email, opts.show_email) catch continue
        else
            buildAuthorKey(allocator, commit.author_name, commit.author_email, opts.show_email) catch continue;

        // Get first line of commit message (subject)
        const subject = getFirstLine(commit.message);

        // Store an owned copy of the subject
        const owned_subject = allocator.alloc(u8, subject.len) catch continue;
        @memcpy(owned_subject, subject);

        try authors_map.addCommit(author_key, owned_subject);
        count += 1;
    }

    // Convert to sorted list
    var entries = std.array_list.Managed(AuthorSummary).init(allocator);
    defer {
        for (entries.items) |*entry| {
            allocator.free(entry.name);
            for (entry.subjects.items) |s| allocator.free(s);
            entry.subjects.deinit();
        }
        entries.deinit();
    }

    var map_iter = authors_map.map.iterator();
    while (map_iter.next()) |kv| {
        var author_subjects = std.array_list.Managed([]const u8).init(allocator);
        for (kv.value_ptr.subjects.items) |s| {
            const owned = try allocator.alloc(u8, s.len);
            @memcpy(owned, s);
            try author_subjects.append(owned);
        }
        const name_copy = try allocator.alloc(u8, kv.key_ptr.len);
        @memcpy(name_copy, kv.key_ptr.*);
        try entries.append(.{
            .name = name_copy,
            .subjects = author_subjects,
            .count = kv.value_ptr.subjects.items.len,
        });
    }

    // Sort entries
    if (opts.numbered) {
        // Sort by count (descending), then alphabetically by name
        std.mem.sort(AuthorSummary, entries.items, {}, struct {
            fn lessThan(_: void, a: AuthorSummary, b: AuthorSummary) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
    } else {
        // Sort alphabetically by name
        std.mem.sort(AuthorSummary, entries.items, {}, struct {
            fn lessThan(_: void, a: AuthorSummary, b: AuthorSummary) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
    }

    // Output results
    for (entries.items) |*entry| {
        if (opts.summary) {
            // Summary mode: just "COUNT\tAUTHOR\n"
            var buf: [1024]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{d:>6}\t{s}\n", .{ entry.count, entry.name }) catch continue;
            try stdout_file.writeAll(line);
        } else {
            // Full mode: "AUTHOR (COUNT):" followed by indented subjects
            var buf: [1024]u8 = undefined;
            const header = std.fmt.bufPrint(&buf, "{s} ({d}):\n", .{ entry.name, entry.count }) catch continue;
            try stdout_file.writeAll(header);

            // Sort subjects alphabetically for consistent output
            sortStrings(entry.subjects.items);

            for (entry.subjects.items) |subject| {
                var line_buf: [4096]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "      {s}\n", .{subject}) catch continue;
                try stdout_file.writeAll(line);
            }
            try stdout_file.writeAll("\n");
        }
    }
}

/// Summary data for a single author.
const AuthorSummary = struct {
    name: []const u8,
    subjects: std.array_list.Managed([]const u8),
    count: usize,
};

/// A map from author name to their commit data.
const AuthorMap = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(AuthorData),

    const AuthorData = struct {
        subjects: std.array_list.Managed([]const u8),
    };

    fn init(allocator: std.mem.Allocator) AuthorMap {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(AuthorData).init(allocator),
        };
    }

    fn deinit(self: *AuthorMap) void {
        var iter = self.map.iterator();
        while (iter.next()) |kv| {
            for (kv.value_ptr.subjects.items) |s| {
                self.allocator.free(s);
            }
            kv.value_ptr.subjects.deinit();
            self.allocator.free(kv.key_ptr.*);
        }
        self.map.deinit();
    }

    fn addCommit(self: *AuthorMap, author_key: []const u8, subject: []const u8) !void {
        if (self.map.getPtr(author_key)) |data| {
            try data.subjects.append(subject);
            // Free the key since it's a duplicate
            self.allocator.free(author_key);
        } else {
            var data = AuthorData{
                .subjects = std.array_list.Managed([]const u8).init(self.allocator),
            };
            try data.subjects.append(subject);
            try self.map.put(author_key, data);
        }
    }
};

/// Build the display key for an author: "Name" or "Name <email>"
fn buildAuthorKey(
    allocator: std.mem.Allocator,
    name: []const u8,
    email: []const u8,
    show_email: bool,
) ![]const u8 {
    if (show_email and email.len > 0) {
        // "Name <email>"
        const key_len = name.len + 2 + email.len + 1;
        const key = try allocator.alloc(u8, key_len);
        var pos: usize = 0;
        @memcpy(key[pos..][0..name.len], name);
        pos += name.len;
        key[pos] = ' ';
        pos += 1;
        key[pos] = '<';
        pos += 1;
        @memcpy(key[pos..][0..email.len], email);
        pos += email.len;
        key[pos] = '>';
        pos += 1;
        return key[0..pos];
    } else {
        const key = try allocator.alloc(u8, name.len);
        @memcpy(key, name);
        return key;
    }
}

/// Get the first non-empty line from a message.
fn getFirstLine(message: []const u8) []const u8 {
    const trimmed = std.mem.trimLeft(u8, message, "\n\r ");
    const nl = std.mem.indexOfScalar(u8, trimmed, '\n');
    if (nl) |n| {
        return std.mem.trimRight(u8, trimmed[0..n], " \r");
    }
    return std.mem.trimRight(u8, trimmed, " \r\n");
}

/// Sort a slice of strings alphabetically.
fn sortStrings(items: [][]const u8) void {
    for (items, 0..) |_, i_idx| {
        if (i_idx == 0) continue;
        var j = i_idx;
        while (j > 0 and std.mem.order(u8, items[j], items[j - 1]) == .lt) {
            const tmp = items[j];
            items[j] = items[j - 1];
            items[j - 1] = tmp;
            j -= 1;
        }
    }
}

test "getFirstLine" {
    try std.testing.expectEqualStrings("hello world", getFirstLine("hello world\nmore stuff\n"));
    try std.testing.expectEqualStrings("single", getFirstLine("single"));
    try std.testing.expectEqualStrings("after blank", getFirstLine("\n\nafter blank\n"));
}

test "buildAuthorKey without email" {
    const key = try buildAuthorKey(std.testing.allocator, "John Doe", "john@example.com", false);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("John Doe", key);
}

test "buildAuthorKey with email" {
    const key = try buildAuthorKey(std.testing.allocator, "John Doe", "john@example.com", true);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("John Doe <john@example.com>", key);
}

/// Mailmap support: resolve author name/email aliases.
/// The .mailmap file maps different representations to a canonical form.
///
/// Format:
///   Proper Name <proper@email> <commit@email>
///   Proper Name <proper@email> Commit Name <commit@email>
///   <proper@email> <commit@email>
///
const MailmapEntry = struct {
    /// Canonical name (or empty if not specified).
    proper_name: []const u8,
    /// Canonical email (or empty if not specified).
    proper_email: []const u8,
    /// The commit name to match (or empty for any name).
    commit_name: []const u8,
    /// The commit email to match.
    commit_email: []const u8,
};

const Mailmap = struct {
    allocator: std.mem.Allocator,
    entries: std.array_list.Managed(MailmapEntry),
    owned_data: std.array_list.Managed([]u8),

    fn init(allocator: std.mem.Allocator) Mailmap {
        return .{
            .allocator = allocator,
            .entries = std.array_list.Managed(MailmapEntry).init(allocator),
            .owned_data = std.array_list.Managed([]u8).init(allocator),
        };
    }

    fn deinit(self: *Mailmap) void {
        for (self.owned_data.items) |d| self.allocator.free(d);
        self.owned_data.deinit();
        self.entries.deinit();
    }

    /// Load a .mailmap file from the given path.
    fn loadFile(self: *Mailmap, path: []const u8) !void {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size == 0 or stat.size > 1024 * 1024) return;

        const data = try self.allocator.alloc(u8, stat.size);
        errdefer self.allocator.free(data);
        const n = try file.readAll(data);
        if (n == 0) {
            self.allocator.free(data);
            return;
        }
        try self.owned_data.append(data);

        var lines = std.mem.splitScalar(u8, data[0..n], '\n');
        while (lines.next()) |line| {
            self.parseLine(line) catch continue;
        }
    }

    /// Parse a single mailmap line.
    fn parseLine(self: *Mailmap, raw_line: []const u8) !void {
        var line = std.mem.trimRight(u8, raw_line, "\r ");
        if (line.len == 0 or line[0] == '#') return;

        var proper_name: []const u8 = "";
        var proper_email: []const u8 = "";
        var commit_name: []const u8 = "";
        var commit_email: []const u8 = "";

        // Parse: extract emails in angle brackets and names outside them
        const first_lt = std.mem.indexOfScalar(u8, line, '<') orelse return;
        const first_gt = std.mem.indexOfScalarPos(u8, line, first_lt, '>') orelse return;

        if (first_lt > 0) {
            proper_name = std.mem.trimRight(u8, line[0..first_lt], " ");
        }
        proper_email = line[first_lt + 1 .. first_gt];

        // Look for a second email
        if (first_gt + 1 < line.len) {
            const rest = line[first_gt + 1 ..];
            const second_lt = std.mem.indexOfScalar(u8, rest, '<');
            if (second_lt) |slt| {
                const second_gt = std.mem.indexOfScalarPos(u8, rest, slt, '>');
                if (second_gt) |sgt| {
                    commit_email = rest[slt + 1 .. sgt];
                    if (slt > 0) {
                        commit_name = std.mem.trim(u8, rest[0..slt], " ");
                    }
                }
            }
        }

        if (commit_email.len == 0) {
            // Simple form: proper email only, match any email
            commit_email = proper_email;
        }

        try self.entries.append(.{
            .proper_name = proper_name,
            .proper_email = proper_email,
            .commit_name = commit_name,
            .commit_email = commit_email,
        });
    }

    /// Resolve an author using the mailmap.
    /// Returns (resolved_name, resolved_email).
    fn resolve(self: *const Mailmap, name: []const u8, email: []const u8) struct { []const u8, []const u8 } {
        // Search entries in reverse order (last matching entry wins)
        var best_name = name;
        var best_email = email;

        for (self.entries.items) |*entry| {
            // Check if the commit email matches
            if (!caseInsensitiveEql(entry.commit_email, email)) continue;

            // If commit_name is specified, it must also match
            if (entry.commit_name.len > 0) {
                if (!std.mem.eql(u8, entry.commit_name, name)) continue;
            }

            // Apply the mapping
            if (entry.proper_name.len > 0) best_name = entry.proper_name;
            if (entry.proper_email.len > 0) best_email = entry.proper_email;
        }

        return .{ best_name, best_email };
    }
};

/// Case-insensitive string comparison for email addresses.
fn caseInsensitiveEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

/// Format a commit count with proper alignment for display.
fn formatCount(buf: []u8, count: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{count}) catch "0";
}

/// Wrap text to a given width, preserving indentation.
fn wrapText(allocator: std.mem.Allocator, text: []const u8, width: usize, indent: []const u8) ![]const u8 {
    if (text.len + indent.len <= width) {
        const result = try allocator.alloc(u8, indent.len + text.len);
        @memcpy(result[0..indent.len], indent);
        @memcpy(result[indent.len..], text);
        return result;
    }

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    try output.appendSlice(indent);

    var pos: usize = 0;
    var line_len: usize = indent.len;

    while (pos < text.len) {
        // Find next word boundary
        var word_end = pos;
        while (word_end < text.len and text[word_end] != ' ') word_end += 1;
        const word = text[pos..word_end];

        if (line_len + word.len > width and line_len > indent.len) {
            // Wrap to next line
            try output.append('\n');
            try output.appendSlice(indent);
            line_len = indent.len;
        }

        try output.appendSlice(word);
        line_len += word.len;

        if (word_end < text.len) {
            try output.append(' ');
            line_len += 1;
        }

        pos = word_end;
        while (pos < text.len and text[pos] == ' ') pos += 1;
    }

    return output.toOwnedSlice();
}

test "caseInsensitiveEql" {
    try std.testing.expect(caseInsensitiveEql("test@example.com", "Test@Example.COM"));
    try std.testing.expect(caseInsensitiveEql("abc", "ABC"));
    try std.testing.expect(!caseInsensitiveEql("abc", "abd"));
    try std.testing.expect(!caseInsensitiveEql("ab", "abc"));
}

test "formatCount" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("42", formatCount(&buf, 42));
    try std.testing.expectEqualStrings("0", formatCount(&buf, 0));
    try std.testing.expectEqualStrings("1000", formatCount(&buf, 1000));
}

test "wrapText short" {
    const result = try wrapText(std.testing.allocator, "hello", 80, "  ");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("  hello", result);
}
