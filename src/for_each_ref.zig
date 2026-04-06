const std = @import("std");
const types = @import("types.zig");
const repository = @import("repository.zig");
const ref_mod = @import("ref.zig");
const tree_diff = @import("tree_diff.zig");

const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = std.posix.STDERR_FILENO };

pub const ForEachRefOptions = struct {
    format: []const u8 = "%(objectname) %(objecttype)\t%(refname)",
    sort_key: ?[]const u8 = null,
    count: ?usize = null,
    points_at: ?[]const u8 = null,
    filter_prefix: ?[]const u8 = null,
};

pub fn runForEachRef(repo: *repository.Repository, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var opts = ForEachRefOptions{};

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--format=")) {
            opts.format = arg["--format=".len..];
        } else if (std.mem.startsWith(u8, arg, "--sort=")) {
            opts.sort_key = arg["--sort=".len..];
        } else if (std.mem.startsWith(u8, arg, "--count=")) {
            const val = arg["--count=".len..];
            opts.count = std.fmt.parseInt(usize, val, 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--points-at=")) {
            opts.points_at = arg["--points-at=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            opts.filter_prefix = arg;
        }
    }

    // Resolve points-at OID if specified
    var points_at_oid: ?types.ObjectId = null;
    if (opts.points_at) |pat| {
        points_at_oid = repo.resolveRef(allocator, pat) catch null;
    }

    // Determine the ref prefix to search
    const prefix = opts.filter_prefix orelse "refs/";

    // List all refs
    const entries = ref_mod.listRefs(allocator, repo.git_dir, prefix) catch {
        return; // No refs found
    };
    defer ref_mod.freeRefEntries(allocator, entries);

    // Collect refs with their info for sorting
    var ref_infos = std.array_list.Managed(RefInfo).init(allocator);
    defer {
        for (ref_infos.items) |*info| {
            if (info.commit_data) |d| allocator.free(d);
        }
        ref_infos.deinit();
    }

    for (entries) |*entry| {
        // Apply points-at filter
        if (points_at_oid) |filter_oid| {
            if (!entry.oid.eql(&filter_oid)) continue;
        }

        var info = RefInfo{
            .name = entry.name,
            .oid = entry.oid,
            .obj_type = .commit,
            .commit_data = null,
        };

        // Read object to get type and commit info
        if (repo.readObject(allocator, &entry.oid)) |obj_val| {
            var obj = obj_val;
            info.obj_type = obj.obj_type;
            if (obj.obj_type == .commit) {
                const data = try allocator.alloc(u8, obj.data.len);
                @memcpy(data, obj.data);
                info.commit_data = data;
            }
            obj.deinit();
        } else |_| {}

        try ref_infos.append(info);
    }

    // Sort if requested
    if (opts.sort_key) |key| {
        sortRefs(ref_infos.items, key);
    }

    // Output
    var output_count: usize = 0;
    for (ref_infos.items) |*info| {
        if (opts.count) |max| {
            if (output_count >= max) break;
        }

        try formatRef(allocator, repo, info, opts.format);
        output_count += 1;
    }
}

const RefInfo = struct {
    name: []const u8,
    oid: types.ObjectId,
    obj_type: types.ObjectType,
    commit_data: ?[]u8,
};

fn formatRef(allocator: std.mem.Allocator, repo: *repository.Repository, info: *const RefInfo, format: []const u8) !void {
    _ = repo;
    var output_buf: [4096]u8 = undefined;
    var out_pos: usize = 0;

    var i: usize = 0;
    while (i < format.len) {
        if (i + 1 < format.len and format[i] == '%' and format[i + 1] == '(') {
            // Find closing )
            const end = std.mem.indexOfScalarPos(u8, format, i + 2, ')') orelse {
                if (out_pos < output_buf.len) {
                    output_buf[out_pos] = format[i];
                    out_pos += 1;
                }
                i += 1;
                continue;
            };
            const token = format[i + 2 .. end];
            const value = resolveToken(allocator, info, token);

            if (out_pos + value.len <= output_buf.len) {
                @memcpy(output_buf[out_pos..][0..value.len], value);
                out_pos += value.len;
            }
            i = end + 1;
        } else {
            if (out_pos < output_buf.len) {
                output_buf[out_pos] = format[i];
                out_pos += 1;
            }
            i += 1;
        }
    }

    try stdout_file.writeAll(output_buf[0..out_pos]);
    try stdout_file.writeAll("\n");
}

fn resolveToken(allocator: std.mem.Allocator, info: *const RefInfo, token: []const u8) []const u8 {
    _ = allocator;

    if (std.mem.eql(u8, token, "refname")) {
        return info.name;
    } else if (std.mem.eql(u8, token, "refname:short")) {
        return shortRefName(info.name);
    } else if (std.mem.eql(u8, token, "objecttype")) {
        return info.obj_type.toString();
    } else if (std.mem.eql(u8, token, "objectname")) {
        // We store hex in a thread-local/static buf
        const hex = info.oid.toHex();
        // Return a pointer to temporary storage - used immediately in formatRef
        return &hex;
    } else if (std.mem.eql(u8, token, "objectname:short")) {
        const hex = info.oid.toHex();
        return hex[0..7];
    } else if (std.mem.eql(u8, token, "HEAD")) {
        // Would check if HEAD points at this ref; simplified to " "
        return " ";
    } else if (std.mem.eql(u8, token, "subject")) {
        return extractCommitField(info.commit_data, "subject");
    } else if (std.mem.eql(u8, token, "body")) {
        return extractCommitField(info.commit_data, "body");
    } else if (std.mem.eql(u8, token, "authorname")) {
        return extractCommitField(info.commit_data, "authorname");
    } else if (std.mem.eql(u8, token, "authoremail")) {
        return extractCommitField(info.commit_data, "authoremail");
    } else if (std.mem.eql(u8, token, "authordate")) {
        return extractCommitField(info.commit_data, "authordate");
    } else if (std.mem.eql(u8, token, "committerdate") or std.mem.eql(u8, token, "creatordate")) {
        return extractCommitField(info.commit_data, "committerdate");
    } else if (std.mem.eql(u8, token, "committerdate")) {
        return extractCommitField(info.commit_data, "committerdate");
    } else if (std.mem.eql(u8, token, "committername")) {
        return extractCommitField(info.commit_data, "committername");
    } else if (std.mem.eql(u8, token, "committeremail")) {
        return extractCommitField(info.commit_data, "committeremail");
    }

    return "";
}

fn shortRefName(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "refs/heads/")) {
        return name["refs/heads/".len..];
    } else if (std.mem.startsWith(u8, name, "refs/tags/")) {
        return name["refs/tags/".len..];
    } else if (std.mem.startsWith(u8, name, "refs/remotes/")) {
        return name["refs/remotes/".len..];
    }
    return name;
}

fn extractCommitField(commit_data: ?[]u8, field: []const u8) []const u8 {
    const data = commit_data orelse return "";

    if (std.mem.eql(u8, field, "subject")) {
        // Find the blank line separating headers from message
        if (std.mem.indexOf(u8, data, "\n\n")) |blank_pos| {
            const msg_start = blank_pos + 2;
            if (msg_start < data.len) {
                // Subject is first line of message
                const msg = data[msg_start..];
                if (std.mem.indexOfScalar(u8, msg, '\n')) |nl| {
                    return msg[0..nl];
                }
                return msg;
            }
        }
        return "";
    }

    if (std.mem.eql(u8, field, "body")) {
        if (std.mem.indexOf(u8, data, "\n\n")) |blank_pos| {
            const msg_start = blank_pos + 2;
            if (msg_start < data.len) {
                const msg = data[msg_start..];
                if (std.mem.indexOfScalar(u8, msg, '\n')) |nl| {
                    if (nl + 1 < msg.len) {
                        return msg[nl + 1 ..];
                    }
                }
            }
        }
        return "";
    }

    if (std.mem.eql(u8, field, "authorname") or std.mem.eql(u8, field, "authoremail") or std.mem.eql(u8, field, "authordate")) {
        return extractPersonField(data, "author ", field);
    }

    if (std.mem.eql(u8, field, "committername") or std.mem.eql(u8, field, "committeremail") or std.mem.eql(u8, field, "committerdate")) {
        return extractPersonField(data, "committer ", field);
    }

    return "";
}

fn extractPersonField(data: []const u8, header_prefix: []const u8, field: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, header_prefix)) {
            const rest = line[header_prefix.len..];
            // Format: "Name <email> timestamp timezone"
            if (std.mem.endsWith(u8, field, "name")) {
                // Name is everything before '<'
                if (std.mem.indexOfScalar(u8, rest, '<')) |lt| {
                    if (lt > 0) {
                        return std.mem.trimRight(u8, rest[0 .. lt - 1], " ");
                    }
                }
                return rest;
            } else if (std.mem.endsWith(u8, field, "email")) {
                if (std.mem.indexOfScalar(u8, rest, '<')) |lt| {
                    if (std.mem.indexOfScalarPos(u8, rest, lt, '>')) |gt| {
                        return rest[lt .. gt + 1];
                    }
                }
                return "";
            } else if (std.mem.endsWith(u8, field, "date")) {
                // Date is after '> '
                if (std.mem.indexOfScalar(u8, rest, '>')) |gt| {
                    if (gt + 2 < rest.len) {
                        return std.mem.trimRight(u8, rest[gt + 2 ..], " \r");
                    }
                }
                return "";
            }
        }
    }
    return "";
}

fn sortRefs(refs: []RefInfo, key: []const u8) void {
    const is_reverse = std.mem.startsWith(u8, key, "-");
    const actual_key = if (is_reverse) key[1..] else key;

    if (std.mem.eql(u8, actual_key, "refname")) {
        std.mem.sort(RefInfo, refs, is_reverse, struct {
            fn lessThan(reverse: bool, a: RefInfo, b: RefInfo) bool {
                const order = std.mem.order(u8, a.name, b.name);
                return if (reverse) order == .gt else order == .lt;
            }
        }.lessThan);
    } else if (std.mem.eql(u8, actual_key, "authordate") or
        std.mem.eql(u8, actual_key, "committerdate") or
        std.mem.eql(u8, actual_key, "creatordate"))
    {
        std.mem.sort(RefInfo, refs, is_reverse, struct {
            fn lessThan(reverse: bool, a: RefInfo, b: RefInfo) bool {
                const a_date = extractTimestamp(a.commit_data);
                const b_date = extractTimestamp(b.commit_data);
                return if (reverse) a_date > b_date else a_date < b_date;
            }
        }.lessThan);
    }
}

fn extractTimestamp(commit_data: ?[]u8) i64 {
    const data = commit_data orelse return 0;
    // Look for committer line and extract timestamp
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "committer ")) {
            // Find '> ' then parse timestamp
            if (std.mem.indexOf(u8, line, "> ")) |gt_pos| {
                const after = line[gt_pos + 2 ..];
                // Timestamp is the first number
                if (std.mem.indexOfScalar(u8, after, ' ')) |space| {
                    return std.fmt.parseInt(i64, after[0..space], 10) catch 0;
                }
                return std.fmt.parseInt(i64, after, 10) catch 0;
            }
        }
    }
    return 0;
}
