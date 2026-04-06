const std = @import("std");

/// A mailmap entry mapping commit identity to canonical identity.
pub const MailmapEntry = struct {
    /// Canonical name (or null to keep original).
    proper_name: ?[]const u8,
    /// Canonical email (or null to keep original).
    proper_email: ?[]const u8,
    /// The commit email to match on.
    commit_email: ?[]const u8,
    /// The commit name to match on (optional, for more specific matching).
    commit_name: ?[]const u8,
};

/// Lookup result from the mailmap.
pub const MappedIdentity = struct {
    name: []const u8,
    email: []const u8,
};

/// Parser and lookup for .mailmap files.
pub const Mailmap = struct {
    allocator: std.mem.Allocator,
    entries: std.array_list.Managed(MailmapEntry),
    /// Owned string data.
    owned_data: std.array_list.Managed([]u8),

    pub fn init(allocator: std.mem.Allocator) Mailmap {
        return .{
            .allocator = allocator,
            .entries = std.array_list.Managed(MailmapEntry).init(allocator),
            .owned_data = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Mailmap) void {
        for (self.owned_data.items) |d| {
            self.allocator.free(d);
        }
        self.owned_data.deinit();
        self.entries.deinit();
    }

    /// Load mailmap from a file path.
    pub fn loadFile(self: *Mailmap, path: []const u8) !void {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size == 0) return;
        if (stat.size > 1024 * 1024) return error.FileTooLarge;

        const data = try self.allocator.alloc(u8, stat.size);
        errdefer self.allocator.free(data);
        const n = try file.readAll(data);
        if (n == 0) {
            self.allocator.free(data);
            return;
        }
        try self.owned_data.append(data);

        try self.parseData(data[0..n]);
    }

    /// Load .mailmap from a working directory.
    pub fn loadFromWorkDir(self: *Mailmap, work_dir: []const u8) !void {
        var path_buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&path_buf);
        const writer = stream.writer();
        try writer.writeAll(work_dir);
        try writer.writeAll("/.mailmap");
        const path = path_buf[0..stream.pos];
        try self.loadFile(path);
    }

    /// Parse mailmap data.
    fn parseData(self: *Mailmap, data: []const u8) !void {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r \t");
            if (line.len == 0) continue;
            if (line[0] == '#') continue;

            self.parseLine(line) catch continue;
        }
    }

    /// Parse a single mailmap line.
    /// Formats:
    ///   Proper Name <proper@email> <commit@email>
    ///   Proper Name <proper@email> Old Name <commit@email>
    ///   <proper@email> <commit@email>
    ///   Proper Name <commit@email>
    fn parseLine(self: *Mailmap, line: []const u8) !void {
        var entry = MailmapEntry{
            .proper_name = null,
            .proper_email = null,
            .commit_email = null,
            .commit_name = null,
        };

        // Find all <email> tokens
        var emails = std.array_list.Managed(EmailToken).init(self.allocator);
        defer emails.deinit();

        var pos: usize = 0;
        while (pos < line.len) {
            if (std.mem.indexOfScalarPos(u8, line, pos, '<')) |start| {
                if (std.mem.indexOfScalarPos(u8, line, start + 1, '>')) |end| {
                    try emails.append(.{
                        .email = line[start + 1 .. end],
                        .prefix_start = pos,
                        .prefix_end = start,
                    });
                    pos = end + 1;
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        if (emails.items.len == 0) return error.InvalidFormat;

        if (emails.items.len == 1) {
            // Format: "Proper Name <commit@email>"
            // This maps commit@email to Proper Name (keeping commit email)
            const name_part = std.mem.trimRight(u8, line[0..emails.items[0].prefix_end], " \t");
            if (name_part.len > 0) {
                entry.proper_name = name_part;
            }
            entry.commit_email = emails.items[0].email;
        } else if (emails.items.len >= 2) {
            // Two or more emails
            const first = &emails.items[0];
            const second = &emails.items[1];

            // Text before first <email> is the proper name
            const name_part = std.mem.trimRight(u8, line[0..first.prefix_end], " \t");
            if (name_part.len > 0) {
                entry.proper_name = name_part;
            }
            entry.proper_email = first.email;

            // Text between first > and second < is the commit name
            const between = std.mem.trim(u8, line[first.prefix_end + first.email.len + 2 .. second.prefix_end], " \t");
            if (between.len > 0) {
                entry.commit_name = between;
            }

            entry.commit_email = second.email;
        }

        try self.entries.append(entry);
    }

    /// Look up the canonical name and email for a given commit identity.
    pub fn lookup(self: *const Mailmap, name: []const u8, email: []const u8) MappedIdentity {
        var result = MappedIdentity{
            .name = name,
            .email = email,
        };

        for (self.entries.items) |*entry| {
            // Must match commit email
            if (entry.commit_email) |ce| {
                if (!eqlCaseInsensitive(ce, email)) continue;
            } else {
                continue;
            }

            // If commit_name is specified, must also match
            if (entry.commit_name) |cn| {
                if (!std.mem.eql(u8, cn, name)) continue;
            }

            // Apply mapping
            if (entry.proper_name) |pn| {
                result.name = pn;
            }
            if (entry.proper_email) |pe| {
                result.email = pe;
            }
        }

        return result;
    }
};

const EmailToken = struct {
    email: []const u8,
    prefix_start: usize,
    prefix_end: usize,
};

/// Case-insensitive email comparison.
fn eqlCaseInsensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la: u8 = if (ca >= 'A' and ca <= 'Z') ca + ('a' - 'A') else ca;
        const lb: u8 = if (cb >= 'A' and cb <= 'Z') cb + ('a' - 'A') else cb;
        if (la != lb) return false;
    }
    return true;
}

test "eqlCaseInsensitive" {
    try std.testing.expect(eqlCaseInsensitive("hello", "hello"));
    try std.testing.expect(eqlCaseInsensitive("Hello", "hello"));
    try std.testing.expect(eqlCaseInsensitive("HELLO", "hello"));
    try std.testing.expect(!eqlCaseInsensitive("hello", "world"));
    try std.testing.expect(!eqlCaseInsensitive("hello", "hell"));
}

test "Mailmap parseLine: Proper Name <commit@email>" {
    var mm = Mailmap.init(std.testing.allocator);
    defer mm.deinit();

    try mm.parseLine("John Doe <john@example.com>");

    try std.testing.expectEqual(@as(usize, 1), mm.entries.items.len);
    const entry = &mm.entries.items[0];
    try std.testing.expectEqualStrings("John Doe", entry.proper_name.?);
    try std.testing.expect(entry.proper_email == null);
    try std.testing.expectEqualStrings("john@example.com", entry.commit_email.?);
}

test "Mailmap parseLine: Proper Name <proper@email> <commit@email>" {
    var mm = Mailmap.init(std.testing.allocator);
    defer mm.deinit();

    try mm.parseLine("John Doe <john@new.com> <john@old.com>");

    try std.testing.expectEqual(@as(usize, 1), mm.entries.items.len);
    const entry = &mm.entries.items[0];
    try std.testing.expectEqualStrings("John Doe", entry.proper_name.?);
    try std.testing.expectEqualStrings("john@new.com", entry.proper_email.?);
    try std.testing.expectEqualStrings("john@old.com", entry.commit_email.?);
}

test "Mailmap parseLine: <proper@email> <commit@email>" {
    var mm = Mailmap.init(std.testing.allocator);
    defer mm.deinit();

    try mm.parseLine("<john@new.com> <john@old.com>");

    try std.testing.expectEqual(@as(usize, 1), mm.entries.items.len);
    const entry = &mm.entries.items[0];
    try std.testing.expect(entry.proper_name == null);
    try std.testing.expectEqualStrings("john@new.com", entry.proper_email.?);
    try std.testing.expectEqualStrings("john@old.com", entry.commit_email.?);
}

test "Mailmap lookup" {
    var mm = Mailmap.init(std.testing.allocator);
    defer mm.deinit();

    try mm.parseLine("John Doe <john@new.com> <john@old.com>");

    const result = mm.lookup("jdoe", "john@old.com");
    try std.testing.expectEqualStrings("John Doe", result.name);
    try std.testing.expectEqualStrings("john@new.com", result.email);
}

test "Mailmap lookup no match" {
    var mm = Mailmap.init(std.testing.allocator);
    defer mm.deinit();

    try mm.parseLine("John Doe <john@new.com> <john@old.com>");

    const result = mm.lookup("someone", "someone@other.com");
    try std.testing.expectEqualStrings("someone", result.name);
    try std.testing.expectEqualStrings("someone@other.com", result.email);
}

test "Mailmap lookup case insensitive email" {
    var mm = Mailmap.init(std.testing.allocator);
    defer mm.deinit();

    try mm.parseLine("John Doe <john@new.com> <John@Old.Com>");

    const result = mm.lookup("jdoe", "john@old.com");
    try std.testing.expectEqualStrings("John Doe", result.name);
    try std.testing.expectEqualStrings("john@new.com", result.email);
}

test "Mailmap lookup name-only mapping" {
    var mm = Mailmap.init(std.testing.allocator);
    defer mm.deinit();

    try mm.parseLine("Proper Name <user@example.com>");

    const result = mm.lookup("wrong name", "user@example.com");
    try std.testing.expectEqualStrings("Proper Name", result.name);
    try std.testing.expectEqualStrings("user@example.com", result.email);
}
