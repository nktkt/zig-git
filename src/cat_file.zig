const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");

pub const Mode = enum {
    pretty,
    type_only,
    size_only,
    exists,
};

pub fn catFile(
    repo: *repository.Repository,
    allocator: std.mem.Allocator,
    object_ref: []const u8,
    mode: Mode,
    stdout: std.fs.File,
) !void {
    const oid = try repo.resolveRef(allocator, object_ref);

    if (mode == .exists) return;

    var obj = try repo.readObject(allocator, &oid);
    defer obj.deinit();

    switch (mode) {
        .type_only => {
            try stdout.writeAll(obj.obj_type.toString());
            try stdout.writeAll("\n");
        },
        .size_only => {
            var buf: [32]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{d}\n", .{obj.data.len}) catch unreachable;
            try stdout.writeAll(msg);
        },
        .pretty => {
            switch (obj.obj_type) {
                .blob, .commit, .tag => {
                    try stdout.writeAll(obj.data);
                },
                .tree => {
                    try prettyPrintTree(obj.data, stdout);
                },
            }
        },
        .exists => unreachable,
    }
}

fn prettyPrintTree(data: []const u8, file: std.fs.File) !void {
    var pos: usize = 0;

    while (pos < data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse return error.InvalidTreeEntry;
        const mode = data[pos..space_pos];

        const null_pos = std.mem.indexOfScalarPos(u8, data, space_pos + 1, 0) orelse return error.InvalidTreeEntry;
        const name = data[space_pos + 1 .. null_pos];

        if (null_pos + 1 + types.OID_RAW_LEN > data.len) return error.InvalidTreeEntry;
        var oid: types.ObjectId = undefined;
        @memcpy(&oid.bytes, data[null_pos + 1 ..][0..types.OID_RAW_LEN]);

        const obj_type_str = modeToType(mode);
        const hex = oid.toHex();

        // Format: "MMMMMM type sha\tname\n"
        var buf: [512]u8 = undefined;
        // Pad mode to 6 chars
        const line = std.fmt.bufPrint(&buf, "{s:0>6} {s} {s}\t{s}\n", .{ mode, obj_type_str, &hex, name }) catch continue;
        try file.writeAll(line);

        pos = null_pos + 1 + types.OID_RAW_LEN;
    }
}

fn modeToType(mode: []const u8) []const u8 {
    if (std.mem.eql(u8, mode, "40000")) return "tree";
    if (std.mem.startsWith(u8, mode, "1")) {
        if (std.mem.eql(u8, mode, "160000")) return "commit";
        return "blob";
    }
    return "blob";
}
