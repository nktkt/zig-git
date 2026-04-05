const std = @import("std");
const hash = @import("hash.zig");

pub const OID_RAW_LEN = hash.SHA1_DIGEST_LENGTH; // 20
pub const OID_HEX_LEN = hash.SHA1_HEX_LENGTH; // 40

pub const ObjectId = struct {
    bytes: [OID_RAW_LEN]u8,

    pub const ZERO = ObjectId{ .bytes = [_]u8{0} ** OID_RAW_LEN };

    pub fn fromHex(hex: []const u8) !ObjectId {
        if (hex.len < OID_HEX_LEN) return error.InvalidObjectId;
        var oid: ObjectId = undefined;
        try hash.hexToBytes(hex[0..OID_HEX_LEN], &oid.bytes);
        return oid;
    }

    pub fn toHex(self: *const ObjectId) [OID_HEX_LEN]u8 {
        var hex: [OID_HEX_LEN]u8 = undefined;
        hash.bytesToHex(&self.bytes, &hex);
        return hex;
    }

    pub fn eql(self: *const ObjectId, other: *const ObjectId) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn order(self: *const ObjectId, other: *const ObjectId) std.math.Order {
        return std.mem.order(u8, &self.bytes, &other.bytes);
    }

    pub fn loosePath(self: *const ObjectId, buf: []u8) ![]u8 {
        const hex = self.toHex();
        if (buf.len < "objects/".len + 2 + 1 + OID_HEX_LEN - 2) return error.BufferTooSmall;
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();
        try writer.writeAll("objects/");
        try writer.writeByte(hex[0]);
        try writer.writeByte(hex[1]);
        try writer.writeByte('/');
        try writer.writeAll(hex[2..]);
        return buf[0..stream.pos];
    }
};

pub const ObjectType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,

    pub fn toString(self: ObjectType) []const u8 {
        return switch (self) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
        };
    }

    pub fn fromString(s: []const u8) !ObjectType {
        if (std.mem.eql(u8, s, "commit")) return .commit;
        if (std.mem.eql(u8, s, "tree")) return .tree;
        if (std.mem.eql(u8, s, "blob")) return .blob;
        if (std.mem.eql(u8, s, "tag")) return .tag;
        return error.InvalidObjectType;
    }

    pub fn fromPackType(t: u3) !ObjectType {
        return switch (t) {
            1 => .commit,
            2 => .tree,
            3 => .blob,
            4 => .tag,
            else => error.InvalidPackObjectType,
        };
    }
};

pub const PackObjectType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,

    pub fn fromInt(v: u3) !PackObjectType {
        return switch (v) {
            1 => .commit,
            2 => .tree,
            3 => .blob,
            4 => .tag,
            6 => .ofs_delta,
            7 => .ref_delta,
            else => error.InvalidPackObjectType,
        };
    }

    pub fn isBase(self: PackObjectType) bool {
        return switch (self) {
            .commit, .tree, .blob, .tag => true,
            .ofs_delta, .ref_delta => false,
        };
    }

    pub fn toObjectType(self: PackObjectType) !ObjectType {
        return switch (self) {
            .commit => .commit,
            .tree => .tree,
            .blob => .blob,
            .tag => .tag,
            .ofs_delta, .ref_delta => error.DeltaNotResolved,
        };
    }
};

pub const Object = struct {
    obj_type: ObjectType,
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Object) void {
        self.allocator.free(self.data);
    }
};

pub const TreeEntry = struct {
    mode: []const u8,
    name: []const u8,
    oid: ObjectId,
};

test "ObjectId from hex" {
    const oid = try ObjectId.fromHex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    const hex = oid.toHex();
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &hex);
}

test "ObjectId loose path" {
    const oid = try ObjectId.fromHex("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    var buf: [256]u8 = undefined;
    const path = try oid.loosePath(&buf);
    try std.testing.expectEqualStrings("objects/e6/9de29bb2d1d6434b8b29ae775ad8c2e48c5391", path);
}
