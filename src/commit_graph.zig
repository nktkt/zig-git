const std = @import("std");
const types = @import("types.zig");

const CGRAPH_MAGIC = "CGPH";
const CHUNK_OID_FANOUT: u32 = 0x4f494446;
const CHUNK_OID_LOOKUP: u32 = 0x4f49444c;
const CHUNK_COMMIT_DATA: u32 = 0x43444154;
const CHUNK_EXTRA_EDGES: u32 = 0x45444745;

pub const CommitGraph = struct {
    data: []align(std.heap.page_size_min) const u8,
    file: std.fs.File,
    num_commits: u32,
    oid_version: u8,
    fanout_offset: usize,
    oid_lookup_offset: usize,
    commit_data_offset: usize,
    extra_edges_offset: ?usize,

    pub fn open(path: []const u8) !CommitGraph {
        const file = std.fs.openFileAbsolute(path, .{}) catch return error.CommitGraphNotFound;
        errdefer file.close();

        const stat = try file.stat();
        if (stat.size < 8) return error.CommitGraphTooSmall;

        const data = try std.posix.mmap(null, stat.size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, file.handle, 0);
        errdefer std.posix.munmap(@constCast(@alignCast(data)));

        if (!std.mem.eql(u8, data[0..4], CGRAPH_MAGIC)) return error.InvalidCommitGraph;

        const version = data[4];
        if (version != 1) return error.UnsupportedCommitGraphVersion;

        const oid_version = data[5];
        const num_chunks = data[6];

        var fanout_offset: usize = 0;
        var oid_lookup_offset: usize = 0;
        var commit_data_offset: usize = 0;
        var extra_edges_offset: ?usize = null;

        const chunk_table_start: usize = 8;
        for (0..num_chunks) |i| {
            const entry_offset = chunk_table_start + i * 12;
            if (entry_offset + 12 > data.len) return error.CommitGraphTruncated;

            const chunk_id = std.mem.readInt(u32, data[entry_offset..][0..4], .big);
            const chunk_offset: usize = @intCast(std.mem.readInt(u64, data[entry_offset + 4 ..][0..8], .big));

            switch (chunk_id) {
                CHUNK_OID_FANOUT => fanout_offset = chunk_offset,
                CHUNK_OID_LOOKUP => oid_lookup_offset = chunk_offset,
                CHUNK_COMMIT_DATA => commit_data_offset = chunk_offset,
                CHUNK_EXTRA_EDGES => extra_edges_offset = chunk_offset,
                else => {},
            }
        }

        if (fanout_offset == 0 or oid_lookup_offset == 0 or commit_data_offset == 0) {
            return error.CommitGraphMissingChunks;
        }

        const num_commits = std.mem.readInt(u32, data[fanout_offset + 255 * 4 ..][0..4], .big);

        return CommitGraph{
            .data = data,
            .file = file,
            .num_commits = num_commits,
            .oid_version = oid_version,
            .fanout_offset = fanout_offset,
            .oid_lookup_offset = oid_lookup_offset,
            .commit_data_offset = commit_data_offset,
            .extra_edges_offset = extra_edges_offset,
        };
    }

    pub fn close(self: *CommitGraph) void {
        std.posix.munmap(@constCast(@alignCast(self.data)));
        self.file.close();
    }

    pub fn findCommit(self: *const CommitGraph, oid: *const types.ObjectId) ?u32 {
        const first_byte = oid.bytes[0];

        const lo: u32 = if (first_byte == 0) 0 else std.mem.readInt(u32, self.data[self.fanout_offset + (@as(usize, first_byte) - 1) * 4 ..][0..4], .big);
        const hi: u32 = std.mem.readInt(u32, self.data[self.fanout_offset + @as(usize, first_byte) * 4 ..][0..4], .big);

        if (lo >= hi) return null;

        var low = lo;
        var high = hi;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const entry_offset = self.oid_lookup_offset + @as(usize, mid) * types.OID_RAW_LEN;
            const entry_oid = self.data[entry_offset..][0..types.OID_RAW_LEN];

            switch (std.mem.order(u8, entry_oid, &oid.bytes)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return mid,
            }
        }

        return null;
    }

    pub const CommitData = struct {
        tree_oid: types.ObjectId,
        parent1: u32,
        parent2: u32,
        generation: u32,
        timestamp: u64,
    };

    pub fn getCommitData(self: *const CommitGraph, index: u32) !CommitData {
        if (index >= self.num_commits) return error.CommitGraphIndexOutOfBounds;

        const entry_size = types.OID_RAW_LEN + 4 + 4 + 8;
        const entry_offset = self.commit_data_offset + @as(usize, index) * entry_size;

        var tree_oid: types.ObjectId = undefined;
        @memcpy(&tree_oid.bytes, self.data[entry_offset..][0..types.OID_RAW_LEN]);

        const p1_offset = entry_offset + types.OID_RAW_LEN;
        const parent1 = std.mem.readInt(u32, self.data[p1_offset..][0..4], .big);
        const parent2 = std.mem.readInt(u32, self.data[p1_offset + 4 ..][0..4], .big);

        const gen_ts = std.mem.readInt(u64, self.data[p1_offset + 8 ..][0..8], .big);
        const generation: u32 = @intCast(gen_ts >> 34);
        const timestamp: u64 = gen_ts & 0x3FFFFFFFF;

        return CommitData{
            .tree_oid = tree_oid,
            .parent1 = parent1,
            .parent2 = parent2,
            .generation = generation,
            .timestamp = timestamp,
        };
    }

    pub fn getOid(self: *const CommitGraph, index: u32) types.ObjectId {
        const oid_offset = self.oid_lookup_offset + @as(usize, index) * types.OID_RAW_LEN;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, self.data[oid_offset..][0..types.OID_RAW_LEN]);
        return oid;
    }
};
