const std = @import("std");
const types = @import("types.zig");
const compress = @import("compress.zig");

pub fn readLooseObject(allocator: std.mem.Allocator, git_dir: []const u8, oid: *const types.ObjectId) !types.Object {
    var path_buf: [512]u8 = undefined;
    const rel_path = try oid.loosePath(&path_buf);

    var full_path_buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&full_path_buf);
    const writer = stream.writer();
    try writer.writeAll(git_dir);
    try writer.writeByte('/');
    try writer.writeAll(rel_path);
    const full_path = full_path_buf[0..stream.pos];

    const file = std.fs.openFileAbsolute(full_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ObjectNotFound,
        else => return error.ObjectReadFailed,
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.size > 128 * 1024 * 1024) return error.ObjectReadFailed; // Sanity limit
    const compressed = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(compressed);
    const bytes_read = try file.readAll(compressed);

    const raw = compress.zlibInflate(allocator, compressed[0..bytes_read]) catch return error.ObjectDecompressFailed;
    defer allocator.free(raw);

    return parseObjectContent(allocator, raw);
}

fn parseObjectContent(allocator: std.mem.Allocator, raw: []const u8) !types.Object {
    // Format: "TYPE SIZE\0CONTENT"
    const space_pos = std.mem.indexOfScalar(u8, raw, ' ') orelse return error.InvalidObjectFormat;
    const null_pos = std.mem.indexOfScalar(u8, raw, 0) orelse return error.InvalidObjectFormat;

    if (null_pos <= space_pos) return error.InvalidObjectFormat;

    const type_str = raw[0..space_pos];
    const obj_type = try types.ObjectType.fromString(type_str);

    const content = raw[null_pos + 1 ..];
    const data = try allocator.alloc(u8, content.len);
    @memcpy(data, content);

    return types.Object{
        .obj_type = obj_type,
        .data = data,
        .allocator = allocator,
    };
}

pub fn writeLooseObject(allocator: std.mem.Allocator, git_dir: []const u8, obj_type: types.ObjectType, data: []const u8) !types.ObjectId {
    // Build header: "TYPE SIZE\0"
    var header_buf: [64]u8 = undefined;
    var hstream = std.io.fixedBufferStream(&header_buf);
    const hwriter = hstream.writer();
    try hwriter.writeAll(obj_type.toString());
    try hwriter.writeByte(' ');
    try hwriter.print("{d}", .{data.len});
    try hwriter.writeByte(0);
    const header = header_buf[0..hstream.pos];

    // Compute SHA-1
    var hasher = @import("hash.zig").Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    const digest = hasher.finalResult();
    const oid = types.ObjectId{ .bytes = digest };

    // Compress header + content
    const total_len = std.math.add(usize, header.len, data.len) catch return error.ObjectReadFailed;
    var raw = try allocator.alloc(u8, total_len);
    defer allocator.free(raw);
    @memcpy(raw[0..header.len], header);
    @memcpy(raw[header.len..], data);

    const compressed = try compress.zlibDeflate(allocator, raw);
    defer allocator.free(compressed);

    // Write to objects/XX/YY...
    var path_buf: [512]u8 = undefined;
    const rel_path = try oid.loosePath(&path_buf);

    var full_path_buf: [1024]u8 = undefined;
    var fstream = std.io.fixedBufferStream(&full_path_buf);
    const fwriter = fstream.writer();
    try fwriter.writeAll(git_dir);
    try fwriter.writeByte('/');
    try fwriter.writeAll(rel_path);
    const full_path = full_path_buf[0..fstream.pos];

    // Ensure directory exists
    const dir_end = std.mem.lastIndexOfScalar(u8, full_path, '/') orelse return error.InvalidPath;
    std.fs.makeDirAbsolute(full_path[0..dir_end]) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Write file (if it already exists, object is identical — content-addressable)
    const file = std.fs.createFileAbsolute(full_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return oid,
        else => return err,
    };
    defer file.close();
    try file.writeAll(compressed);

    return oid;
}
