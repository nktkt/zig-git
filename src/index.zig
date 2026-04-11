const std = @import("std");
const types = @import("types.zig");
const hash_mod = @import("hash.zig");

/// Represents a single entry in the Git index.
pub const IndexEntry = struct {
    ctime_s: u32,
    ctime_ns: u32,
    mtime_s: u32,
    mtime_ns: u32,
    dev: u32,
    ino: u32,
    mode: u32,
    uid: u32,
    gid: u32,
    file_size: u32,
    oid: types.ObjectId,
    flags: u16,
    name: []const u8,
    /// Whether the name is owned by the allocator (for entries we create).
    owned: bool,
};

/// Git index (DIRC format) reader/writer.
pub const Index = struct {
    allocator: std.mem.Allocator,
    version: u32,
    entries: std.array_list.Managed(IndexEntry),
    /// Raw data backing entry names when read from file.
    raw_data: ?[]u8,

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{
            .allocator = allocator,
            .version = 2,
            .entries = std.array_list.Managed(IndexEntry).init(allocator),
            .raw_data = null,
        };
    }

    pub fn deinit(self: *Index) void {
        for (self.entries.items) |*entry| {
            if (entry.owned) {
                self.allocator.free(entry.name);
            }
        }
        self.entries.deinit();
        if (self.raw_data) |d| {
            self.allocator.free(d);
        }
    }

    /// Read an index file from the given path.
    pub fn readFromFile(allocator: std.mem.Allocator, path: []const u8) !Index {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // No index file means empty index
                return Index.init(allocator);
            },
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size < 12) return error.InvalidIndex;
        const raw_data = try allocator.alloc(u8, @intCast(stat.size));
        const n = try file.readAll(raw_data);
        if (n < 12) {
            allocator.free(raw_data);
            return error.InvalidIndex;
        }

        // If we read fewer bytes than allocated, reallocate to the exact size
        // so that raw_data in parseIndex can be freed correctly.
        const data = if (n < raw_data.len) blk: {
            const exact = allocator.alloc(u8, n) catch {
                allocator.free(raw_data);
                return error.OutOfMemory;
            };
            @memcpy(exact, raw_data[0..n]);
            allocator.free(raw_data);
            break :blk exact;
        } else raw_data;
        errdefer allocator.free(data);

        return parseIndex(allocator, data);
    }

    fn parseIndex(allocator: std.mem.Allocator, data: []u8) !Index {
        if (data.len < 12 + 20) return error.InvalidIndex;

        // Verify checksum: last 20 bytes are SHA-1 of everything before
        const content_end = data.len - 20;
        const stored_checksum = data[content_end..][0..20];
        const computed = hash_mod.sha1Digest(data[0..content_end]);
        if (!std.mem.eql(u8, stored_checksum, &computed)) {
            return error.InvalidIndexChecksum;
        }

        // Header: DIRC + version(4) + num_entries(4)
        if (!std.mem.eql(u8, data[0..4], "DIRC")) return error.InvalidIndex;
        const version = readU32(data[4..8]);
        if (version < 2 or version > 4) return error.UnsupportedIndexVersion;
        const num_entries = readU32(data[8..12]);

        var idx = Index{
            .allocator = allocator,
            .version = version,
            .entries = std.array_list.Managed(IndexEntry).init(allocator),
            .raw_data = data,
        };
        errdefer {
            idx.entries.deinit();
            // raw_data is owned by caller on error via errdefer on data
        }

        var pos: usize = 12;
        var i: u32 = 0;
        while (i < num_entries) : (i += 1) {
            if (pos + 62 > content_end) return error.InvalidIndex;

            const entry_start = pos;
            var entry: IndexEntry = undefined;
            entry.ctime_s = readU32(data[pos..][0..4]);
            pos += 4;
            entry.ctime_ns = readU32(data[pos..][0..4]);
            pos += 4;
            entry.mtime_s = readU32(data[pos..][0..4]);
            pos += 4;
            entry.mtime_ns = readU32(data[pos..][0..4]);
            pos += 4;
            entry.dev = readU32(data[pos..][0..4]);
            pos += 4;
            entry.ino = readU32(data[pos..][0..4]);
            pos += 4;
            entry.mode = readU32(data[pos..][0..4]);
            pos += 4;
            entry.uid = readU32(data[pos..][0..4]);
            pos += 4;
            entry.gid = readU32(data[pos..][0..4]);
            pos += 4;
            entry.file_size = readU32(data[pos..][0..4]);
            pos += 4;
            @memcpy(&entry.oid.bytes, data[pos..][0..20]);
            pos += 20;
            entry.flags = readU16(data[pos..][0..2]);
            pos += 2;

            // Name length from flags (low 12 bits)
            const name_len_from_flags = entry.flags & 0xFFF;

            if (version < 4) {
                // V2/V3: name is NUL-terminated, entry padded to multiple of 8
                const name_start = pos;
                // Find NUL terminator
                var name_end = pos;
                while (name_end < content_end and data[name_end] != 0) {
                    name_end += 1;
                }
                if (name_end >= content_end) return error.InvalidIndex;

                entry.name = data[name_start..name_end];
                entry.owned = false;

                // Padding: entry is padded to multiple of 8 bytes
                // Entry size from entry_start to end of NUL, padded to 8
                const entry_size = (name_end - entry_start + 8) & ~@as(usize, 7);
                pos = entry_start + entry_size;
            } else {
                // V4: prefix-compressed names (simplified: read NUL-terminated)
                _ = name_len_from_flags;
                const name_start = pos;
                var name_end = pos;
                while (name_end < content_end and data[name_end] != 0) {
                    name_end += 1;
                }
                if (name_end >= content_end) return error.InvalidIndex;
                entry.name = data[name_start..name_end];
                entry.owned = false;
                pos = name_end + 1;
            }

            try idx.entries.append(entry);
        }

        return idx;
    }

    /// Write the index to a file at the given path.
    pub fn writeToFile(self: *const Index, path: []const u8) !void {
        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();

        var hasher = hash_mod.Sha1.init(.{});

        // Header
        var header: [12]u8 = undefined;
        @memcpy(header[0..4], "DIRC");
        writeU32(header[4..8], self.version);
        if (self.entries.items.len > std.math.maxInt(u32)) return error.TooManyEntries;
        writeU32(header[8..12], @intCast(self.entries.items.len));
        try file.writeAll(&header);
        hasher.update(&header);

        // Entries
        for (self.entries.items) |*entry| {
            // 62 bytes fixed fields + name + NUL + up to 7 bytes padding
            const max_entry_size = 62 + entry.name.len + 1 + 7;
            if (max_entry_size > 4096) return error.NameTooLong;
            var entry_buf: [4096]u8 = undefined;
            var pos: usize = 0;

            writeU32(entry_buf[pos..][0..4], entry.ctime_s);
            pos += 4;
            writeU32(entry_buf[pos..][0..4], entry.ctime_ns);
            pos += 4;
            writeU32(entry_buf[pos..][0..4], entry.mtime_s);
            pos += 4;
            writeU32(entry_buf[pos..][0..4], entry.mtime_ns);
            pos += 4;
            writeU32(entry_buf[pos..][0..4], entry.dev);
            pos += 4;
            writeU32(entry_buf[pos..][0..4], entry.ino);
            pos += 4;
            writeU32(entry_buf[pos..][0..4], entry.mode);
            pos += 4;
            writeU32(entry_buf[pos..][0..4], entry.uid);
            pos += 4;
            writeU32(entry_buf[pos..][0..4], entry.gid);
            pos += 4;
            writeU32(entry_buf[pos..][0..4], entry.file_size);
            pos += 4;
            @memcpy(entry_buf[pos..][0..20], &entry.oid.bytes);
            pos += 20;

            // Flags: name length (capped at 0xFFF)
            const name_len: u16 = if (entry.name.len > 0xFFF) 0xFFF else @intCast(entry.name.len);
            const flags = (entry.flags & 0xF000) | name_len;
            writeU16(entry_buf[pos..][0..2], flags);
            pos += 2;

            // Name + NUL + padding to 8-byte boundary
            @memcpy(entry_buf[pos..][0..entry.name.len], entry.name);
            pos += entry.name.len;
            entry_buf[pos] = 0;
            pos += 1;

            // Pad to multiple of 8 bytes (from beginning of entry which is 62 bytes of fixed + name + NUL)
            const total_unpadded = 62 + entry.name.len + 1;
            const padded = (total_unpadded + 7) & ~@as(usize, 7);
            const padding = padded - total_unpadded;
            if (padding > 0) {
                @memset(entry_buf[pos..][0..padding], 0);
                pos += padding;
            }

            try file.writeAll(entry_buf[0..pos]);
            hasher.update(entry_buf[0..pos]);
        }

        // Checksum
        const checksum = hasher.finalResult();
        try file.writeAll(&checksum);
    }

    /// Find an entry by path name.
    pub fn findEntry(self: *const Index, name: []const u8) ?usize {
        for (self.entries.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, entry.name, name)) return i;
        }
        return null;
    }

    /// Add or update an entry. Keeps entries sorted by name.
    pub fn addEntry(self: *Index, entry: IndexEntry) !void {
        // Check if entry already exists
        if (self.findEntry(entry.name)) |existing_idx| {
            // Free old owned name if needed
            if (self.entries.items[existing_idx].owned) {
                self.allocator.free(self.entries.items[existing_idx].name);
            }
            self.entries.items[existing_idx] = entry;
            return;
        }

        // Insert sorted
        var insert_pos: usize = self.entries.items.len;
        for (self.entries.items, 0..) |*e, i| {
            if (compareEntryNames(entry.name, e.name) == .lt) {
                insert_pos = i;
                break;
            }
        }
        try self.entries.insert(insert_pos, entry);
    }

    /// Remove an entry by name.
    pub fn removeEntry(self: *Index, name: []const u8) bool {
        if (self.findEntry(name)) |idx| {
            if (self.entries.items[idx].owned) {
                self.allocator.free(self.entries.items[idx].name);
            }
            _ = self.entries.orderedRemove(idx);
            return true;
        }
        return false;
    }

    fn compareEntryNames(a: []const u8, b: []const u8) std.math.Order {
        return std.mem.order(u8, a, b);
    }
};

fn readU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

fn readU16(bytes: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes, .big);
}

fn writeU32(buf: *[4]u8, val: u32) void {
    std.mem.writeInt(u32, buf, val, .big);
}

fn writeU16(buf: *[2]u8, val: u16) void {
    std.mem.writeInt(u16, buf, val, .big);
}
