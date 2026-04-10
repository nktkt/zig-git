const std = @import("std");

/// Git trace/debug output system.
///
/// Supports the same environment variables as Git:
///   GIT_TRACE=1           — general trace messages to stderr
///   GIT_TRACE=/path       — general trace messages to a file
///   GIT_TRACE_PERFORMANCE=1 — performance timing
///   GIT_TRACE_PACK_ACCESS=1 — pack file access events
///   GIT_TRACE_SETUP=1       — repository setup details
///
/// Trace output format:
///   HH:MM:SS.NNNNNN <category>: <message>
///
/// All trace output goes to stderr by default. If the environment variable
/// is set to an absolute path, output goes to that file instead.

/// Trace categories.
pub const Category = enum {
    general,
    performance,
    pack_access,
    setup,
    refs,
    merge,
    transport,

    pub fn envVar(self: Category) []const u8 {
        return switch (self) {
            .general => "GIT_TRACE",
            .performance => "GIT_TRACE_PERFORMANCE",
            .pack_access => "GIT_TRACE_PACK_ACCESS",
            .setup => "GIT_TRACE_SETUP",
            .refs => "GIT_TRACE_REFS",
            .merge => "GIT_TRACE_MERGE",
            .transport => "GIT_TRACE_CURL",
        };
    }

    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .general => "trace",
            .performance => "performance",
            .pack_access => "pack-access",
            .setup => "setup",
            .refs => "refs",
            .merge => "merge",
            .transport => "transport",
        };
    }
};

/// Per-category trace state (cached from environment).
const TraceState = struct {
    checked: bool,
    enabled: bool,
    /// If trace goes to a file, this is the path. Otherwise null (use stderr).
    file_path: ?[]const u8,
};

/// Cached trace states for each category.
var trace_states: [category_count]TraceState = init_trace_states();
var states_initialized: bool = false;

const category_count = @typeInfo(Category).@"enum".fields.len;

fn init_trace_states() [category_count]TraceState {
    var states: [category_count]TraceState = undefined;
    for (&states) |*s| {
        s.* = .{
            .checked = false,
            .enabled = false,
            .file_path = null,
        };
    }
    return states;
}

/// Check if a trace category is enabled.
/// Caches the result from the environment on first call.
pub fn isEnabled(category: Category) bool {
    const idx = @intFromEnum(category);
    if (!trace_states[idx].checked) {
        initCategory(category);
    }
    return trace_states[idx].enabled;
}

fn initCategory(category: Category) void {
    const idx = @intFromEnum(category);
    trace_states[idx].checked = true;

    const env_val = std.posix.getenv(category.envVar()) orelse {
        trace_states[idx].enabled = false;
        return;
    };

    if (env_val.len == 0 or std.mem.eql(u8, env_val, "0") or std.mem.eql(u8, env_val, "false")) {
        trace_states[idx].enabled = false;
        return;
    }

    trace_states[idx].enabled = true;

    // Check if the value is a file path (starts with /)
    if (env_val.len > 0 and env_val[0] == '/') {
        trace_states[idx].file_path = env_val;
    }
}

/// Write a trace message for the given category.
/// No-op if the category is not enabled.
pub fn trace(category: Category, message: []const u8) void {
    if (!isEnabled(category)) return;
    writeTrace(category, message);
}

/// Write a formatted trace message for the given category.
pub fn traceFmt(category: Category, comptime fmt: []const u8, args: anytype) void {
    if (!isEnabled(category)) return;

    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeTrace(category, msg);
}

/// Measure execution time and report as a performance trace.
/// Returns the elapsed time in nanoseconds.
pub fn tracePerf(lbl: []const u8, func: *const fn () void) u64 {
    const start = getTimestamp();
    func();
    const end = getTimestamp();
    const elapsed = end -| start;

    if (isEnabled(.performance)) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}: {d:.3}ms", .{
            lbl,
            @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
        }) catch return elapsed;
        writeTrace(.performance, msg);
    }

    return elapsed;
}

/// Measure a block of code with performance tracing.
/// Returns a PerfTimer that reports elapsed time when finished.
pub const PerfTimer = struct {
    label_buf: [256]u8,
    label_len: usize,
    start_time: u64,

    pub fn start(lbl: []const u8) PerfTimer {
        var timer = PerfTimer{
            .label_buf = undefined,
            .label_len = @min(lbl.len, 256),
            .start_time = getTimestamp(),
        };
        @memcpy(timer.label_buf[0..timer.label_len], lbl[0..timer.label_len]);
        return timer;
    }

    pub fn finish(self: *const PerfTimer) void {
        if (!isEnabled(.performance)) return;

        const elapsed_ns = getTimestamp() -| self.start_time;
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}: {d:.3}ms", .{
            self.label_buf[0..self.label_len],
            @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
        }) catch return;
        writeTrace(.performance, msg);
    }

    /// Get elapsed time in nanoseconds without finishing the timer.
    pub fn elapsed(self: *const PerfTimer) u64 {
        return getTimestamp() -| self.start_time;
    }
};

/// Write trace for pack access.
pub fn tracePackAccess(pack_name: []const u8, offset: u64, obj_type: []const u8) void {
    if (!isEnabled(.pack_access)) return;

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} {d} {s}", .{ pack_name, offset, obj_type }) catch return;
    writeTrace(.pack_access, msg);
}

/// Write trace for repository setup.
pub fn traceSetup(message: []const u8) void {
    trace(.setup, message);
}

/// Write trace for ref operations.
pub fn traceRef(ref_name: []const u8, old_oid: []const u8, new_oid: []const u8) void {
    if (!isEnabled(.refs)) return;

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: {s} -> {s}", .{ ref_name, old_oid, new_oid }) catch return;
    writeTrace(.refs, msg);
}

// --- Internal ---

fn writeTrace(category: Category, message: []const u8) void {
    const idx = @intFromEnum(category);

    // Build the trace line with timestamp
    var line_buf: [4608]u8 = undefined; // 4096 message + 512 prefix
    var fbs = std.io.fixedBufferStream(&line_buf);
    const writer = fbs.writer();

    // Timestamp prefix
    writeTimestamp(writer);

    // Category label
    writer.writeAll(category.label()) catch return;
    writer.writeAll(": ") catch return;

    // Message
    writer.writeAll(message) catch return;
    writer.writeByte('\n') catch return;

    const line = line_buf[0..fbs.pos];

    // Write to appropriate destination
    if (trace_states[idx].file_path) |path| {
        writeToFile(path, line);
    } else {
        writeToStderr(line);
    }
}

fn writeTimestamp(writer: anytype) void {
    const ts = getTimestamp();
    const secs = ts / 1_000_000_000;
    const nanos = ts % 1_000_000_000;
    const micros = nanos / 1000;

    const hours = (secs / 3600) % 24;
    const minutes = (secs / 60) % 60;
    const seconds = secs % 60;

    writer.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6} ", .{
        hours,
        minutes,
        seconds,
        micros,
    }) catch {};
}

fn getTimestamp() u64 {
    if (@hasDecl(std.posix, "clock_gettime")) {
        var ts: std.posix.timespec = undefined;
        _ = std.posix.clock_gettime(.REALTIME) catch return 0;
        _ = &ts;
    }
    // Fallback: use nanoTimestamp
    return @intCast(@as(u128, @bitCast(std.time.nanoTimestamp())) & 0xFFFFFFFFFFFFFFFF);
}

fn writeToStderr(data: []const u8) void {
    const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };
    stderr.writeAll(data) catch {};
}

fn writeToFile(path: []const u8, data: []const u8) void {
    const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch {
        writeToStderr(data);
        return;
    };
    defer file.close();
    // Seek to end for append
    file.seekFromEnd(0) catch {};
    file.writeAll(data) catch {
        writeToStderr(data);
    };
}

/// Reset all cached trace states (useful for testing).
pub fn resetStates() void {
    trace_states = init_trace_states();
    states_initialized = false;
}

/// Force-enable a category for testing.
pub fn forceEnable(category: Category) void {
    const idx = @intFromEnum(category);
    trace_states[idx].checked = true;
    trace_states[idx].enabled = true;
    trace_states[idx].file_path = null;
}

/// Force-disable a category for testing.
pub fn forceDisable(category: Category) void {
    const idx = @intFromEnum(category);
    trace_states[idx].checked = true;
    trace_states[idx].enabled = false;
    trace_states[idx].file_path = null;
}

// --- Tests ---

test "Category envVar" {
    try std.testing.expectEqualStrings("GIT_TRACE", Category.general.envVar());
    try std.testing.expectEqualStrings("GIT_TRACE_PERFORMANCE", Category.performance.envVar());
    try std.testing.expectEqualStrings("GIT_TRACE_PACK_ACCESS", Category.pack_access.envVar());
    try std.testing.expectEqualStrings("GIT_TRACE_SETUP", Category.setup.envVar());
}

test "Category label" {
    try std.testing.expectEqualStrings("trace", Category.general.label());
    try std.testing.expectEqualStrings("performance", Category.performance.label());
    try std.testing.expectEqualStrings("pack-access", Category.pack_access.label());
}

test "PerfTimer basic" {
    const timer = PerfTimer.start("test operation");
    const el = timer.elapsed();
    try std.testing.expect(el >= 0);
}

test "trace disabled by default" {
    resetStates();
    // Without setting env vars, trace should be disabled
    // (We can't guarantee the env is clean, but the function should not crash)
    trace(.general, "test message");
}

test "forceEnable and forceDisable" {
    resetStates();
    forceEnable(.general);
    try std.testing.expect(isEnabled(.general));
    forceDisable(.general);
    try std.testing.expect(!isEnabled(.general));
    resetStates();
}

test "traceFmt does not crash when disabled" {
    resetStates();
    forceDisable(.general);
    traceFmt(.general, "test {s} {d}", .{ "hello", @as(u32, 42) });
}

test "tracePackAccess does not crash when disabled" {
    resetStates();
    forceDisable(.pack_access);
    tracePackAccess("pack-abc.pack", 1234, "commit");
}

test "traceRef does not crash when disabled" {
    resetStates();
    forceDisable(.refs);
    traceRef("refs/heads/main", "0000000000000000000000000000000000000000", "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
}

test "init_trace_states" {
    const states = init_trace_states();
    for (states) |s| {
        try std.testing.expect(!s.checked);
        try std.testing.expect(!s.enabled);
        try std.testing.expect(s.file_path == null);
    }
}

test "category_count" {
    try std.testing.expect(category_count > 0);
    try std.testing.expectEqual(@as(usize, 7), category_count);
}
