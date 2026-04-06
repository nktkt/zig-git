const std = @import("std");

/// Git protocol capability negotiation.
///
/// During the reference discovery phase of git transport, the server
/// advertises its capabilities. The client selects which capabilities
/// to use from the intersection of server and client support.
///
/// Protocol v1: capabilities appear on the first ref line after a NUL byte.
/// Protocol v2: capabilities are listed as separate pkt-lines.

/// Known capability names for protocol v1.
pub const Cap = enum {
    multi_ack,
    multi_ack_detailed,
    thin_pack,
    side_band,
    side_band_64k,
    ofs_delta,
    shallow,
    deepen_since,
    deepen_not,
    deepen_relative,
    no_progress,
    include_tag,
    report_status,
    report_status_v2,
    delete_refs,
    allow_tip_sha1_in_want,
    allow_reachable_sha1_in_want,
    push_options,
    no_done,
    symref,
    quiet,
    atomic,
    object_format,
    agent,
    filter,

    pub fn toString(self: Cap) []const u8 {
        return switch (self) {
            .multi_ack => "multi_ack",
            .multi_ack_detailed => "multi_ack_detailed",
            .thin_pack => "thin-pack",
            .side_band => "side-band",
            .side_band_64k => "side-band-64k",
            .ofs_delta => "ofs-delta",
            .shallow => "shallow",
            .deepen_since => "deepen-since",
            .deepen_not => "deepen-not",
            .deepen_relative => "deepen-relative",
            .no_progress => "no-progress",
            .include_tag => "include-tag",
            .report_status => "report-status",
            .report_status_v2 => "report-status-v2",
            .delete_refs => "delete-refs",
            .allow_tip_sha1_in_want => "allow-tip-sha1-in-want",
            .allow_reachable_sha1_in_want => "allow-reachable-sha1-in-want",
            .push_options => "push-options",
            .no_done => "no-done",
            .symref => "symref",
            .quiet => "quiet",
            .atomic => "atomic",
            .object_format => "object-format",
            .agent => "agent",
            .filter => "filter",
        };
    }

    pub fn fromString(s: []const u8) ?Cap {
        // Handle capabilities with values (e.g., "symref=HEAD:refs/heads/main")
        const name = if (std.mem.indexOfScalar(u8, s, '=')) |eq_pos|
            s[0..eq_pos]
        else
            s;

        if (std.mem.eql(u8, name, "multi_ack")) return .multi_ack;
        if (std.mem.eql(u8, name, "multi_ack_detailed")) return .multi_ack_detailed;
        if (std.mem.eql(u8, name, "thin-pack")) return .thin_pack;
        if (std.mem.eql(u8, name, "side-band")) return .side_band;
        if (std.mem.eql(u8, name, "side-band-64k")) return .side_band_64k;
        if (std.mem.eql(u8, name, "ofs-delta")) return .ofs_delta;
        if (std.mem.eql(u8, name, "shallow")) return .shallow;
        if (std.mem.eql(u8, name, "deepen-since")) return .deepen_since;
        if (std.mem.eql(u8, name, "deepen-not")) return .deepen_not;
        if (std.mem.eql(u8, name, "deepen-relative")) return .deepen_relative;
        if (std.mem.eql(u8, name, "no-progress")) return .no_progress;
        if (std.mem.eql(u8, name, "include-tag")) return .include_tag;
        if (std.mem.eql(u8, name, "report-status")) return .report_status;
        if (std.mem.eql(u8, name, "report-status-v2")) return .report_status_v2;
        if (std.mem.eql(u8, name, "delete-refs")) return .delete_refs;
        if (std.mem.eql(u8, name, "allow-tip-sha1-in-want")) return .allow_tip_sha1_in_want;
        if (std.mem.eql(u8, name, "allow-reachable-sha1-in-want")) return .allow_reachable_sha1_in_want;
        if (std.mem.eql(u8, name, "push-options")) return .push_options;
        if (std.mem.eql(u8, name, "no-done")) return .no_done;
        if (std.mem.eql(u8, name, "symref")) return .symref;
        if (std.mem.eql(u8, name, "quiet")) return .quiet;
        if (std.mem.eql(u8, name, "atomic")) return .atomic;
        if (std.mem.eql(u8, name, "object-format")) return .object_format;
        if (std.mem.eql(u8, name, "agent")) return .agent;
        if (std.mem.eql(u8, name, "filter")) return .filter;
        return null;
    }
};

/// Protocol v2 capabilities.
pub const CapV2 = enum {
    ls_refs,
    fetch,
    server_option,
    object_format,
    object_info,
    push,

    pub fn toString(self: CapV2) []const u8 {
        return switch (self) {
            .ls_refs => "ls-refs",
            .fetch => "fetch",
            .server_option => "server-option",
            .object_format => "object-format",
            .object_info => "object-info",
            .push => "push",
        };
    }

    pub fn fromString(s: []const u8) ?CapV2 {
        const name = if (std.mem.indexOfScalar(u8, s, '=')) |eq_pos|
            s[0..eq_pos]
        else
            s;

        if (std.mem.eql(u8, name, "ls-refs")) return .ls_refs;
        if (std.mem.eql(u8, name, "fetch")) return .fetch;
        if (std.mem.eql(u8, name, "server-option")) return .server_option;
        if (std.mem.eql(u8, name, "object-format")) return .object_format;
        if (std.mem.eql(u8, name, "object-info")) return .object_info;
        if (std.mem.eql(u8, name, "push")) return .push;
        return null;
    }
};

/// Parsed capability set. Stores which capabilities the server supports
/// along with any associated values.
pub const Capabilities = struct {
    allocator: std.mem.Allocator,
    /// Map from capability string name to optional value.
    caps: std.StringHashMap(?[]const u8),
    /// V2 capabilities.
    v2_caps: std.StringHashMap(?[]const u8),

    pub fn init(allocator: std.mem.Allocator) Capabilities {
        return .{
            .allocator = allocator,
            .caps = std.StringHashMap(?[]const u8).init(allocator),
            .v2_caps = std.StringHashMap(?[]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Capabilities) void {
        // Free duplicated keys and values
        var it = self.caps.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |v| {
                self.allocator.free(v);
            }
        }
        self.caps.deinit();

        var it2 = self.v2_caps.iterator();
        while (it2.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |v| {
                self.allocator.free(v);
            }
        }
        self.v2_caps.deinit();
    }

    /// Check if a capability is present (v1).
    pub fn has(self: *const Capabilities, name: []const u8) bool {
        return self.caps.contains(name);
    }

    /// Get the value associated with a capability, if any (v1).
    pub fn getValue(self: *const Capabilities, name: []const u8) ?[]const u8 {
        if (self.caps.get(name)) |maybe_val| {
            return maybe_val;
        }
        return null;
    }

    /// Check if a v2 capability is present.
    pub fn hasV2(self: *const Capabilities, name: []const u8) bool {
        return self.v2_caps.contains(name);
    }

    /// Get the value associated with a v2 capability.
    pub fn getV2Value(self: *const Capabilities, name: []const u8) ?[]const u8 {
        if (self.v2_caps.get(name)) |maybe_val| {
            return maybe_val;
        }
        return null;
    }

    /// Parse capabilities from a space-separated string (protocol v1).
    /// This is typically the text after a NUL byte on the first ref advertisement line.
    pub fn parse(self: *Capabilities, cap_string: []const u8) !void {
        var iter = std.mem.splitScalar(u8, cap_string, ' ');
        while (iter.next()) |token| {
            if (token.len == 0) continue;
            try self.addCap(token);
        }
    }

    /// Parse v2 capabilities from individual lines.
    pub fn parseV2Line(self: *Capabilities, line: []const u8) !void {
        if (line.len == 0) return;

        // Strip trailing newline
        var trimmed = line;
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\n') {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }

        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
            const name = trimmed[0..eq_pos];
            const value = trimmed[eq_pos + 1 ..];
            const name_copy = try self.allocator.alloc(u8, name.len);
            @memcpy(name_copy, name);
            const value_copy = try self.allocator.alloc(u8, value.len);
            @memcpy(value_copy, value);
            try self.v2_caps.put(name_copy, value_copy);
        } else {
            const name_copy = try self.allocator.alloc(u8, trimmed.len);
            @memcpy(name_copy, trimmed);
            try self.v2_caps.put(name_copy, null);
        }
    }

    /// Add a single capability token (may contain = for value).
    fn addCap(self: *Capabilities, token: []const u8) !void {
        if (std.mem.indexOfScalar(u8, token, '=')) |eq_pos| {
            const name = token[0..eq_pos];
            const value = token[eq_pos + 1 ..];
            const name_copy = try self.allocator.alloc(u8, name.len);
            @memcpy(name_copy, name);
            const value_copy = try self.allocator.alloc(u8, value.len);
            @memcpy(value_copy, value);
            try self.caps.put(name_copy, value_copy);
        } else {
            const name_copy = try self.allocator.alloc(u8, token.len);
            @memcpy(name_copy, token);
            try self.caps.put(name_copy, null);
        }
    }

    /// Build an advertise string for capabilities we want to request from the server.
    /// Used for the client's "want" line in upload-pack negotiation.
    pub fn advertise(self: *const Capabilities, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        var first = true;
        var it = self.caps.iterator();
        while (it.next()) |entry| {
            if (!first) {
                try writer.writeByte(' ');
            }
            try writer.writeAll(entry.key_ptr.*);
            if (entry.value_ptr.*) |val| {
                try writer.writeByte('=');
                try writer.writeAll(val);
            }
            first = false;
        }

        return buf[0..fbs.pos];
    }
};

/// Build a client capability string for upload-pack negotiation.
/// Returns a space-separated list of capabilities we support.
pub fn clientUploadPackCaps(buf: []u8) []const u8 {
    const caps_str = "multi_ack_detailed no-done side-band-64k thin-pack ofs-delta agent=zig-git/0.2.0 no-progress include-tag";
    if (caps_str.len > buf.len) return buf[0..0];
    @memcpy(buf[0..caps_str.len], caps_str);
    return buf[0..caps_str.len];
}

/// Build a client capability string for receive-pack negotiation.
pub fn clientReceivePackCaps(buf: []u8) []const u8 {
    const caps_str = "report-status side-band-64k ofs-delta agent=zig-git/0.2.0 quiet";
    if (caps_str.len > buf.len) return buf[0..0];
    @memcpy(buf[0..caps_str.len], caps_str);
    return buf[0..caps_str.len];
}

/// Extract capabilities from the first line of a ref advertisement.
/// In protocol v1, the first ref line has the format:
///   OID SP refname NUL capability-list LF
/// Returns the capability string (after NUL) or null if not present.
pub fn extractCapsFromFirstLine(line: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, line, 0)) |nul_pos| {
        if (nul_pos + 1 < line.len) {
            var end = line.len;
            if (end > 0 and line[end - 1] == '\n') {
                end -= 1;
            }
            return line[nul_pos + 1 .. end];
        }
    }
    return null;
}

/// Parse a ref from a v1 advertisement line.
/// Format: OID SP refname (NUL caps on first line only)
/// Returns the OID hex string and the ref name.
pub const RefAdEntry = struct {
    oid_hex: []const u8,
    ref_name: []const u8,
};

pub fn parseRefLine(line: []const u8) ?RefAdEntry {
    // Strip trailing LF
    var l = line;
    if (l.len > 0 and l[l.len - 1] == '\n') {
        l = l[0 .. l.len - 1];
    }

    // Must have at least OID_HEX_LEN + 1 (space) + 1 (name char) = 42
    if (l.len < 42) return null;

    // Find the space after the OID
    if (l[40] != ' ') return null;

    const oid_hex = l[0..40];
    var ref_name = l[41..];

    // Strip capabilities (everything after NUL)
    if (std.mem.indexOfScalar(u8, ref_name, 0)) |nul_pos| {
        ref_name = ref_name[0..nul_pos];
    }

    return RefAdEntry{
        .oid_hex = oid_hex,
        .ref_name = ref_name,
    };
}

// --- Tests ---

test "Capabilities parse" {
    var caps = Capabilities.init(std.testing.allocator);
    defer caps.deinit();

    try caps.parse("multi_ack thin-pack side-band-64k ofs-delta agent=git/2.40.0 symref=HEAD:refs/heads/main");

    try std.testing.expect(caps.has("multi_ack"));
    try std.testing.expect(caps.has("thin-pack"));
    try std.testing.expect(caps.has("side-band-64k"));
    try std.testing.expect(caps.has("ofs-delta"));
    try std.testing.expect(caps.has("agent"));
    try std.testing.expect(caps.has("symref"));

    try std.testing.expectEqualStrings("git/2.40.0", caps.getValue("agent").?);
    try std.testing.expectEqualStrings("HEAD:refs/heads/main", caps.getValue("symref").?);

    try std.testing.expect(!caps.has("no-progress"));
}

test "extractCapsFromFirstLine" {
    const line = "0000000000000000000000000000000000000000 capabilities^{}\x00multi_ack thin-pack\n";
    const caps_str = extractCapsFromFirstLine(line).?;
    try std.testing.expectEqualStrings("multi_ack thin-pack", caps_str);
}

test "parseRefLine" {
    const line = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 refs/heads/main\n";
    const entry = parseRefLine(line).?;
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", entry.oid_hex);
    try std.testing.expectEqualStrings("refs/heads/main", entry.ref_name);
}

test "parseRefLine with caps" {
    const line = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 refs/heads/main\x00multi_ack\n";
    const entry = parseRefLine(line).?;
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", entry.oid_hex);
    try std.testing.expectEqualStrings("refs/heads/main", entry.ref_name);
}

test "Cap toString roundtrip" {
    try std.testing.expectEqualStrings("side-band-64k", Cap.side_band_64k.toString());
    try std.testing.expectEqual(Cap.side_band_64k, Cap.fromString("side-band-64k").?);
}

test "CapV2 fromString" {
    try std.testing.expectEqual(CapV2.ls_refs, CapV2.fromString("ls-refs").?);
    try std.testing.expectEqual(CapV2.fetch, CapV2.fromString("fetch").?);
    try std.testing.expect(CapV2.fromString("unknown-cap") == null);
}

test "clientUploadPackCaps" {
    var buf: [256]u8 = undefined;
    const caps_str = clientUploadPackCaps(&buf);
    try std.testing.expect(caps_str.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, caps_str, "side-band-64k") != null);
}
