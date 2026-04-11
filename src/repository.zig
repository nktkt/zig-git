const std = @import("std");
const types = @import("types.zig");
const loose = @import("loose.zig");
const pack_mod = @import("pack.zig");
const commit_graph_mod = @import("commit_graph.zig");

pub const PackEntry = struct {
    pack: pack_mod.PackFile,
    path: []const u8,
};

/// Simple fixed-size LRU object cache keyed by ObjectId.
pub const ObjectCache = struct {
    const CACHE_SIZE = 4096;

    const CacheEntry = struct {
        oid: types.ObjectId,
        obj_type: types.ObjectType,
        data: []u8,
        valid: bool,
    };

    entries: [CACHE_SIZE]CacheEntry,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ObjectCache {
        var cache: ObjectCache = undefined;
        cache.allocator = allocator;
        for (&cache.entries) |*e| {
            e.valid = false;
            e.data = &.{};
            e.oid = types.ObjectId.ZERO;
            e.obj_type = .blob;
        }
        return cache;
    }

    pub fn deinit(self: *ObjectCache) void {
        for (&self.entries) |*e| {
            if (e.valid and e.data.len > 0) {
                self.allocator.free(e.data);
            }
        }
    }

    fn hashOid(oid: *const types.ObjectId) usize {
        // Use first 4 bytes of OID as hash, mask to cache size
        const h = std.mem.readInt(u32, oid.bytes[0..4], .little);
        return h % CACHE_SIZE;
    }

    pub fn get(self: *ObjectCache, allocator: std.mem.Allocator, oid: *const types.ObjectId) ?types.Object {
        const idx = hashOid(oid);
        const entry = &self.entries[idx];
        if (entry.valid and entry.oid.eql(oid)) {
            // Return a copy of the data so the caller owns it
            const data_copy = allocator.alloc(u8, entry.data.len) catch return null;
            @memcpy(data_copy, entry.data);
            return types.Object{
                .obj_type = entry.obj_type,
                .data = data_copy,
                .allocator = allocator,
            };
        }
        return null;
    }

    pub fn put(self: *ObjectCache, oid: *const types.ObjectId, obj_type: types.ObjectType, data: []const u8) void {
        const idx = hashOid(oid);
        const entry = &self.entries[idx];

        // Evict old entry if present
        if (entry.valid and entry.data.len > 0) {
            self.allocator.free(entry.data);
        }

        // Store a copy
        const data_copy = self.allocator.alloc(u8, data.len) catch return;
        @memcpy(data_copy, data);

        entry.oid = oid.*;
        entry.obj_type = obj_type;
        entry.data = data_copy;
        entry.valid = true;
    }
};

pub const Repository = struct {
    allocator: std.mem.Allocator,
    git_dir: []u8,
    packs: std.array_list.Managed(PackEntry),
    commit_graph: ?commit_graph_mod.CommitGraph,
    obj_cache: ?*ObjectCache,

    pub fn discover(allocator: std.mem.Allocator, start_path: ?[]const u8) !Repository {
        var owned_path: ?[]u8 = null;
        defer if (owned_path) |p| allocator.free(p);

        const search_path = if (start_path) |p| p else blk: {
            owned_path = try std.fs.cwd().realpathAlloc(allocator, ".");
            break :blk owned_path.?;
        };

        var current: []const u8 = search_path;

        while (true) {
            // Check for .git directory
            var path_buf: [4096]u8 = undefined;
            const git_path = bufConcat(&path_buf, current, "/.git");

            if (isDirectory(git_path)) {
                const git_dir = try allocator.alloc(u8, git_path.len);
                @memcpy(git_dir, git_path);

                const cache = allocator.create(ObjectCache) catch {
                    allocator.free(git_dir);
                    return error.OutOfMemory;
                };
                cache.* = ObjectCache.init(allocator);

                var repo = Repository{
                    .allocator = allocator,
                    .git_dir = git_dir,
                    .packs = std.array_list.Managed(PackEntry).init(allocator),
                    .commit_graph = null,
                    .obj_cache = cache,
                };
                errdefer repo.deinit();

                try repo.loadPacks();
                repo.loadCommitGraph();

                return repo;
            }

            // Check for bare repo
            const head_path = bufConcat(&path_buf, current, "/HEAD");

            if (isFile(head_path)) {
                var obj_buf: [4096]u8 = undefined;
                const objects_path = bufConcat(&obj_buf, current, "/objects");

                if (isDirectory(objects_path)) {
                    const git_dir = try allocator.alloc(u8, current.len);
                    @memcpy(git_dir, current);

                    const cache2 = allocator.create(ObjectCache) catch {
                        allocator.free(git_dir);
                        return error.OutOfMemory;
                    };
                    cache2.* = ObjectCache.init(allocator);

                    var repo = Repository{
                        .allocator = allocator,
                        .git_dir = git_dir,
                        .packs = std.array_list.Managed(PackEntry).init(allocator),
                        .commit_graph = null,
                        .obj_cache = cache2,
                    };
                    errdefer repo.deinit();

                    try repo.loadPacks();
                    repo.loadCommitGraph();

                    return repo;
                }
            }

            const parent = std.fs.path.dirname(current);
            if (parent == null or std.mem.eql(u8, parent.?, current)) {
                return error.NotAGitRepository;
            }
            current = parent.?;
        }
    }

    pub fn deinit(self: *Repository) void {
        if (self.obj_cache) |cache| {
            cache.deinit();
            self.allocator.destroy(cache);
        }
        for (self.packs.items) |*entry| {
            entry.pack.close();
            self.allocator.free(entry.path);
        }
        self.packs.deinit();
        if (self.commit_graph) |*cg| {
            cg.close();
        }
        self.allocator.free(self.git_dir);
    }

    pub fn readObject(self: *Repository, allocator: std.mem.Allocator, oid: *const types.ObjectId) !types.Object {
        // Check cache first
        if (self.obj_cache) |cache| {
            if (cache.get(allocator, oid)) |obj| {
                return obj;
            }
        }

        // Try loose first
        if (loose.readLooseObject(allocator, self.git_dir, oid)) |obj| {
            if (self.obj_cache) |cache| {
                cache.put(oid, obj.obj_type, obj.data);
            }
            return obj;
        } else |_| {}

        // Try pack files
        for (self.packs.items) |*entry| {
            if (entry.pack.findObject(oid)) |offset| {
                const obj = try entry.pack.readObject(allocator, offset);
                if (self.obj_cache) |cache| {
                    cache.put(oid, obj.obj_type, obj.data);
                }
                return obj;
            }
        }

        return error.ObjectNotFound;
    }

    pub fn objectExists(self: *Repository, oid: *const types.ObjectId) bool {
        // Check loose
        var path_buf: [512]u8 = undefined;
        const rel_path = oid.loosePath(&path_buf) catch return false;

        var full_buf: [1024]u8 = undefined;
        const full_path = bufConcat(&full_buf, self.git_dir, "/");
        const end = full_path.len;
        if (end + rel_path.len > full_buf.len) return false;
        @memcpy(full_buf[end..][0..rel_path.len], rel_path);
        const final_path = full_buf[0 .. end + rel_path.len];

        if (isFile(final_path)) return true;

        // Check packs
        for (self.packs.items) |*entry| {
            if (entry.pack.findObject(oid) != null) return true;
        }

        return false;
    }

    fn loadPacks(self: *Repository) !void {
        var path_buf: [4096]u8 = undefined;
        const pack_dir_path = bufConcat(&path_buf, self.git_dir, "/objects/pack");

        var dir = std.fs.openDirAbsolute(pack_dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".pack")) continue;

            var pack_path_buf: [4096]u8 = undefined;
            const base = bufConcat(&pack_path_buf, pack_dir_path, "/");
            const base_len = base.len;
            if (base_len + entry.name.len > pack_path_buf.len) continue;
            @memcpy(pack_path_buf[base_len..][0..entry.name.len], entry.name);
            const pack_path = pack_path_buf[0 .. base_len + entry.name.len];

            const stored_path = try self.allocator.alloc(u8, pack_path.len);
            @memcpy(stored_path, pack_path);

            var pack_file = pack_mod.PackFile.open(stored_path) catch {
                self.allocator.free(stored_path);
                continue;
            };

            self.packs.append(PackEntry{
                .pack = pack_file,
                .path = stored_path,
            }) catch {
                pack_file.close();
                self.allocator.free(stored_path);
                return error.OutOfMemory;
            };
        }
    }

    fn loadCommitGraph(self: *Repository) void {
        var path_buf: [4096]u8 = undefined;
        const cg_path = bufConcat(&path_buf, self.git_dir, "/objects/info/commit-graph");
        self.commit_graph = commit_graph_mod.CommitGraph.open(cg_path) catch null;
    }

    pub fn resolveRef(self: *Repository, allocator: std.mem.Allocator, ref_str: []const u8) !types.ObjectId {
        // Full hex OID
        if (ref_str.len == types.OID_HEX_LEN) {
            const oid = try types.ObjectId.fromHex(ref_str);
            if (self.objectExists(&oid)) return oid;
            return error.ObjectNotFound;
        }

        // Try as ref name
        if (try self.resolveSymRef(allocator, ref_str)) |oid| {
            return oid;
        }

        // Try abbreviated hex
        if (ref_str.len >= 4 and ref_str.len < types.OID_HEX_LEN) {
            if (try self.resolveAbbrev(ref_str)) |oid| {
                return oid;
            }
        }

        return error.ObjectNotFound;
    }

    fn resolveSymRef(self: *Repository, allocator: std.mem.Allocator, name: []const u8) !?types.ObjectId {
        const prefixes = [_][]const u8{ "", "refs/", "refs/tags/", "refs/heads/", "refs/remotes/" };

        for (prefixes) |prefix| {
            var path_buf: [4096]u8 = undefined;
            const total_len = self.git_dir.len + 1 + prefix.len + name.len;
            if (total_len > path_buf.len) continue;
            var pos: usize = 0;

            @memcpy(path_buf[pos..][0..self.git_dir.len], self.git_dir);
            pos += self.git_dir.len;
            path_buf[pos] = '/';
            pos += 1;
            @memcpy(path_buf[pos..][0..prefix.len], prefix);
            pos += prefix.len;
            @memcpy(path_buf[pos..][0..name.len], name);
            pos += name.len;
            const ref_path = path_buf[0..pos];

            const content = readFileContents(allocator, ref_path) catch continue;
            defer allocator.free(content);

            const trimmed = std.mem.trimRight(u8, content, "\n\r ");

            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                return self.resolveSymRef(allocator, trimmed[5..]);
            }

            if (trimmed.len >= types.OID_HEX_LEN) {
                return types.ObjectId.fromHex(trimmed[0..types.OID_HEX_LEN]) catch null;
            }
        }

        // Try packed-refs
        return self.resolvePackedRef(allocator, name);
    }

    fn resolvePackedRef(self: *Repository, allocator: std.mem.Allocator, name: []const u8) !?types.ObjectId {
        var path_buf: [4096]u8 = undefined;
        const packed_path = bufConcat(&path_buf, self.git_dir, "/packed-refs");

        const content = readFileContents(allocator, packed_path) catch return null;
        defer allocator.free(content);

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;

            // Format: "SHA REF_NAME"
            if (line.len < types.OID_HEX_LEN + 1) continue;
            const ref_name = std.mem.trimRight(u8, line[types.OID_HEX_LEN + 1 ..], " \r");

            if (std.mem.eql(u8, ref_name, name) or
                endsWithRef(ref_name, name))
            {
                return types.ObjectId.fromHex(line[0..types.OID_HEX_LEN]) catch null;
            }
        }

        return null;
    }

    fn resolveAbbrev(self: *Repository, abbrev: []const u8) !?types.ObjectId {
        if (abbrev.len < 4) return null;

        var dir_path_buf: [4096]u8 = undefined;
        var pos: usize = 0;
        @memcpy(dir_path_buf[pos..][0..self.git_dir.len], self.git_dir);
        pos += self.git_dir.len;
        const suffix_str = "/objects/";
        @memcpy(dir_path_buf[pos..][0..suffix_str.len], suffix_str);
        pos += suffix_str.len;
        @memcpy(dir_path_buf[pos..][0..2], abbrev[0..2]);
        pos += 2;
        const dir_path = dir_path_buf[0..pos];

        const rest = abbrev[2..];
        var match_count: u32 = 0;
        var matched_oid: types.ObjectId = types.ObjectId.ZERO;

        if (std.fs.openDirAbsolute(dir_path, .{ .iterate = true })) |dir_handle| {
            var d = dir_handle;
            defer d.close();
            var iter = d.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind != .file) continue;
                if (entry.name.len != types.OID_HEX_LEN - 2) continue;
                if (std.mem.startsWith(u8, entry.name, rest)) {
                    match_count += 1;
                    if (match_count > 1) return error.AmbiguousObjectName;
                    var full_hex: [types.OID_HEX_LEN]u8 = undefined;
                    full_hex[0] = abbrev[0];
                    full_hex[1] = abbrev[1];
                    @memcpy(full_hex[2..], entry.name[0 .. types.OID_HEX_LEN - 2]);
                    matched_oid = types.ObjectId.fromHex(&full_hex) catch continue;
                }
            }
        } else |_| {}

        if (match_count == 1) return matched_oid;

        // Check pack indexes
        for (self.packs.items) |*entry| {
            var idx_iter = entry.pack.idx.iterator();
            while (idx_iter.next()) |item| {
                const hex = item.oid.toHex();
                if (std.mem.startsWith(u8, &hex, abbrev)) {
                    if (match_count > 0 and !matched_oid.eql(&item.oid)) {
                        return error.AmbiguousObjectName;
                    }
                    matched_oid = item.oid;
                    match_count += 1;
                }
            }
        }

        if (match_count >= 1) return matched_oid;
        return null;
    }
};

fn endsWithRef(full_ref: []const u8, name: []const u8) bool {
    if (full_ref.len < name.len) return false;
    const tail = full_ref[full_ref.len - name.len ..];
    return std.mem.eql(u8, tail, name);
}

fn bufConcat(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    if (a.len + b.len > buf.len) {
        // Truncate to buffer size to avoid out-of-bounds; caller should
        // use large enough buffers, but crashing is worse.
        const a_copy = @min(a.len, buf.len);
        @memcpy(buf[0..a_copy], a[0..a_copy]);
        const remaining = buf.len - a_copy;
        const b_copy = @min(b.len, remaining);
        @memcpy(buf[a_copy..][0..b_copy], b[0..b_copy]);
        return buf[0 .. a_copy + b_copy];
    }
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn isDirectory(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

fn isFile(path: []const u8) bool {
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
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
