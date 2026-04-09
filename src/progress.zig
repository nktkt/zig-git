const std = @import("std");

/// Progress reporting for long-running operations.
///
/// Displays progress information to stderr, with throttling to avoid
/// excessive updates. When stderr is a TTY, uses carriage returns for
/// in-place updates. Otherwise, prints periodic status lines.
///
/// Display format: "Title: 42% (420/1000), 1234 objects/sec"
/// On completion: "Title: 100% (1000/1000), done."

/// Progress display state.
pub const Progress = struct {
    title: [256]u8,
    title_len: usize,
    total: u64,
    current: u64,
    start_time: u64,
    last_update_time: u64,
    last_display_current: u64,
    is_tty: bool,
    enabled: bool,
    finished: bool,
    /// Minimum interval between display updates in nanoseconds.
    /// Default: 100ms (10 updates/sec max).
    throttle_ns: u64,
    /// Whether we've displayed anything yet.
    displayed: bool,

    const DEFAULT_THROTTLE_NS = 100_000_000; // 100ms

    /// Start a new progress display.
    /// `title` is the operation name (e.g., "Receiving objects").
    /// `total` is the expected total count (0 for unknown).
    pub fn start(title: []const u8, total: u64) Progress {
        var p = Progress{
            .title = undefined,
            .title_len = @min(title.len, 256),
            .total = total,
            .current = 0,
            .start_time = now(),
            .last_update_time = 0,
            .last_display_current = 0,
            .is_tty = detectTty(),
            .enabled = true,
            .finished = false,
            .throttle_ns = DEFAULT_THROTTLE_NS,
            .displayed = false,
        };
        @memcpy(p.title[0..p.title_len], title[0..p.title_len]);
        return p;
    }

    /// Start progress with explicit enable/disable.
    pub fn startWithOpts(title: []const u8, total: u64, enabled: bool) Progress {
        var p = start(title, total);
        p.enabled = enabled;
        return p;
    }

    /// Update the progress counter.
    /// Throttles display updates to avoid excessive output.
    pub fn update(self: *Progress, current: u64) void {
        if (!self.enabled or self.finished) return;
        self.current = current;

        const t = now();
        if (t -| self.last_update_time < self.throttle_ns) return;
        self.last_update_time = t;

        self.display();
    }

    /// Increment progress by 1.
    pub fn inc(self: *Progress) void {
        self.update(self.current + 1);
    }

    /// Increment progress by a given amount.
    pub fn incBy(self: *Progress, amount: u64) void {
        self.update(self.current + amount);
    }

    /// Complete the progress display.
    pub fn finish(self: *Progress) void {
        if (!self.enabled or self.finished) return;
        self.finished = true;
        self.displayFinal();
    }

    /// Complete with a custom current value.
    pub fn finishWith(self: *Progress, final_current: u64) void {
        self.current = final_current;
        self.finish();
    }

    /// Get the current rate (items per second).
    pub fn rate(self: *const Progress) f64 {
        const elapsed_ns = now() -| self.start_time;
        if (elapsed_ns == 0) return 0;
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(self.current)) / elapsed_sec;
    }

    /// Get estimated time remaining in seconds.
    pub fn eta(self: *const Progress) ?f64 {
        if (self.total == 0) return null;
        if (self.current == 0) return null;

        const elapsed_ns = now() -| self.start_time;
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const progress_frac = @as(f64, @floatFromInt(self.current)) / @as(f64, @floatFromInt(self.total));
        if (progress_frac <= 0) return null;

        const total_estimated = elapsed_sec / progress_frac;
        const remaining = total_estimated - elapsed_sec;
        return if (remaining > 0) remaining else 0;
    }

    /// Get the percentage complete (0-100).
    pub fn percentage(self: *const Progress) ?u8 {
        if (self.total == 0) return null;
        const pct = (self.current * 100) / self.total;
        return @intCast(@min(pct, 100));
    }

    // --- Display ---

    fn display(self: *Progress) void {
        var buf: [512]u8 = undefined;
        const line = self.formatLine(&buf) catch return;

        const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };
        if (self.is_tty) {
            // Use carriage return for in-place update
            stderr.writeAll("\r") catch {};
            stderr.writeAll(line) catch {};
            // Clear rest of line
            stderr.writeAll("\x1b[K") catch {};
        } else if (!self.displayed) {
            stderr.writeAll(line) catch {};
            stderr.writeAll("\n") catch {};
        }
        self.displayed = true;
        self.last_display_current = self.current;
    }

    fn displayFinal(self: *Progress) void {
        var buf: [512]u8 = undefined;
        const line = self.formatFinalLine(&buf) catch return;

        const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };
        if (self.is_tty) {
            stderr.writeAll("\r") catch {};
            stderr.writeAll(line) catch {};
            stderr.writeAll("\x1b[K") catch {};
            stderr.writeAll("\n") catch {};
        } else {
            stderr.writeAll(line) catch {};
            stderr.writeAll("\n") catch {};
        }
    }

    fn formatLine(self: *const Progress, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        try writer.writeAll(self.title[0..self.title_len]);
        try writer.writeAll(": ");

        if (self.total > 0) {
            const pct = (self.current * 100) / self.total;
            try writer.print("{d}% ({d}/{d})", .{ pct, self.current, self.total });
        } else {
            try writer.print("{d}", .{self.current});
        }

        // Rate
        const r = self.rate();
        if (r > 0) {
            if (r >= 1000) {
                try writer.print(", {d:.0}/sec", .{r});
            } else {
                try writer.print(", {d:.1}/sec", .{r});
            }
        }

        return buf[0..fbs.pos];
    }

    fn formatFinalLine(self: *const Progress, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        try writer.writeAll(self.title[0..self.title_len]);
        try writer.writeAll(": ");

        if (self.total > 0) {
            try writer.print("100% ({d}/{d}), done.", .{ self.current, self.total });
        } else {
            try writer.print("{d}, done.", .{self.current});
        }

        return buf[0..fbs.pos];
    }
};

/// Detect if stderr is connected to a terminal.
fn detectTty() bool {
    return std.posix.isatty(std.posix.STDERR_FILENO);
}

/// Get current time in nanoseconds (monotonic).
fn now() u64 {
    return @intCast(@as(u128, @bitCast(std.time.nanoTimestamp())) & 0xFFFFFFFFFFFFFFFF);
}

/// Simple throughput tracker for data transfer progress.
pub const Throughput = struct {
    bytes: u64,
    start_time: u64,

    pub fn init() Throughput {
        return .{
            .bytes = 0,
            .start_time = now(),
        };
    }

    pub fn add(self: *Throughput, nbytes: u64) void {
        self.bytes += nbytes;
    }

    /// Get throughput in bytes per second.
    pub fn bytesPerSec(self: *const Throughput) f64 {
        const elapsed_ns = now() -| self.start_time;
        if (elapsed_ns == 0) return 0;
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(self.bytes)) / elapsed_sec;
    }

    /// Format throughput as a human-readable string.
    pub fn format(self: *const Throughput, buf: []u8) ![]const u8 {
        const bps = self.bytesPerSec();
        var fbs = std.io.fixedBufferStream(buf);
        const writer = fbs.writer();

        if (bps >= 1024 * 1024 * 1024) {
            try writer.print("{d:.2} GiB/s", .{bps / (1024 * 1024 * 1024)});
        } else if (bps >= 1024 * 1024) {
            try writer.print("{d:.2} MiB/s", .{bps / (1024 * 1024)});
        } else if (bps >= 1024) {
            try writer.print("{d:.2} KiB/s", .{bps / 1024});
        } else {
            try writer.print("{d:.0} B/s", .{bps});
        }

        return buf[0..fbs.pos];
    }
};

/// Format a byte count as human-readable.
pub fn formatBytes(buf: []u8, bytes: u64) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    const b = @as(f64, @floatFromInt(bytes));

    if (b >= 1024 * 1024 * 1024) {
        try writer.print("{d:.2} GiB", .{b / (1024 * 1024 * 1024)});
    } else if (b >= 1024 * 1024) {
        try writer.print("{d:.2} MiB", .{b / (1024 * 1024)});
    } else if (b >= 1024) {
        try writer.print("{d:.2} KiB", .{b / 1024});
    } else {
        try writer.print("{d} bytes", .{bytes});
    }

    return buf[0..fbs.pos];
}

/// Format a duration in seconds as human-readable.
pub fn formatDuration(buf: []u8, seconds: f64) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    if (seconds < 1.0) {
        const ms = seconds * 1000;
        try writer.print("{d:.0}ms", .{ms});
    } else if (seconds < 60.0) {
        try writer.print("{d:.1}s", .{seconds});
    } else if (seconds < 3600.0) {
        const mins = @as(u64, @intFromFloat(seconds)) / 60;
        const secs = @as(u64, @intFromFloat(seconds)) % 60;
        try writer.print("{d}m{d}s", .{ mins, secs });
    } else {
        const hours = @as(u64, @intFromFloat(seconds)) / 3600;
        const mins = (@as(u64, @intFromFloat(seconds)) % 3600) / 60;
        try writer.print("{d}h{d}m", .{ hours, mins });
    }

    return buf[0..fbs.pos];
}

/// Multi-phase progress: tracks multiple sequential phases.
pub const MultiProgress = struct {
    phases: [8]PhaseInfo,
    phase_count: usize,
    current_phase: usize,

    const PhaseInfo = struct {
        title: [128]u8,
        title_len: usize,
        total: u64,
        completed: bool,
    };

    pub fn init() MultiProgress {
        return .{
            .phases = undefined,
            .phase_count = 0,
            .current_phase = 0,
        };
    }

    /// Add a phase. Returns the phase index.
    pub fn addPhase(self: *MultiProgress, title: []const u8, total: u64) usize {
        if (self.phase_count >= 8) return self.phase_count - 1;
        const idx = self.phase_count;
        const len = @min(title.len, 128);
        @memcpy(self.phases[idx].title[0..len], title[0..len]);
        self.phases[idx].title_len = len;
        self.phases[idx].total = total;
        self.phases[idx].completed = false;
        self.phase_count += 1;
        return idx;
    }

    /// Start a phase as a Progress instance.
    pub fn startPhase(self: *MultiProgress, phase_idx: usize) Progress {
        if (phase_idx >= self.phase_count) {
            return Progress.start("unknown", 0);
        }
        self.current_phase = phase_idx;
        const p = &self.phases[phase_idx];
        return Progress.start(p.title[0..p.title_len], p.total);
    }

    /// Mark a phase as completed.
    pub fn completePhase(self: *MultiProgress, phase_idx: usize) void {
        if (phase_idx < self.phase_count) {
            self.phases[phase_idx].completed = true;
        }
    }

    /// Get overall completion percentage.
    pub fn overallPercentage(self: *const MultiProgress) u8 {
        if (self.phase_count == 0) return 0;
        var completed: usize = 0;
        for (self.phases[0..self.phase_count]) |*p| {
            if (p.completed) completed += 1;
        }
        return @intCast((completed * 100) / self.phase_count);
    }
};

// --- Tests ---

test "Progress start" {
    const p = Progress.start("Counting objects", 100);
    try std.testing.expectEqual(@as(u64, 100), p.total);
    try std.testing.expectEqual(@as(u64, 0), p.current);
    try std.testing.expect(p.enabled);
    try std.testing.expect(!p.finished);
}

test "Progress percentage" {
    var p = Progress.start("Test", 200);
    p.current = 50;
    try std.testing.expectEqual(@as(u8, 25), p.percentage().?);
    p.current = 200;
    try std.testing.expectEqual(@as(u8, 100), p.percentage().?);
}

test "Progress percentage unknown total" {
    const p = Progress.start("Test", 0);
    try std.testing.expect(p.percentage() == null);
}

test "Progress formatLine with total" {
    var p = Progress.start("Receiving objects", 1000);
    p.current = 420;
    var buf: [512]u8 = undefined;
    const line = try p.formatLine(&buf);
    try std.testing.expect(std.mem.indexOf(u8, line, "Receiving objects") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "42%") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "420/1000") != null);
}

test "Progress formatLine without total" {
    var p = Progress.start("Counting", 0);
    p.current = 42;
    var buf: [512]u8 = undefined;
    const line = try p.formatLine(&buf);
    try std.testing.expect(std.mem.indexOf(u8, line, "42") != null);
}

test "Progress formatFinalLine" {
    var p = Progress.start("Test", 100);
    p.current = 100;
    var buf: [512]u8 = undefined;
    const line = try p.formatFinalLine(&buf);
    try std.testing.expect(std.mem.indexOf(u8, line, "done.") != null);
}

test "Progress disabled" {
    var p = Progress.startWithOpts("Test", 100, false);
    p.update(50);
    p.finish();
    try std.testing.expect(!p.enabled);
}

test "Throughput init" {
    const t = Throughput.init();
    try std.testing.expectEqual(@as(u64, 0), t.bytes);
}

test "Throughput add" {
    var t = Throughput.init();
    t.add(1024);
    t.add(2048);
    try std.testing.expectEqual(@as(u64, 3072), t.bytes);
}

test "formatBytes" {
    var buf: [64]u8 = undefined;

    const b1 = try formatBytes(&buf, 500);
    try std.testing.expect(std.mem.indexOf(u8, b1, "500 bytes") != null);

    const b2 = try formatBytes(&buf, 2048);
    try std.testing.expect(std.mem.indexOf(u8, b2, "KiB") != null);

    const b3 = try formatBytes(&buf, 5 * 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, b3, "MiB") != null);
}

test "formatDuration" {
    var buf: [64]u8 = undefined;

    const d1 = try formatDuration(&buf, 0.5);
    try std.testing.expect(std.mem.indexOf(u8, d1, "ms") != null);

    const d2 = try formatDuration(&buf, 30.5);
    try std.testing.expect(std.mem.indexOf(u8, d2, "s") != null);

    const d3 = try formatDuration(&buf, 125.0);
    try std.testing.expect(std.mem.indexOf(u8, d3, "m") != null);
}

test "MultiProgress" {
    var mp = MultiProgress.init();
    const idx = mp.addPhase("Phase 1", 100);
    _ = mp.addPhase("Phase 2", 200);

    try std.testing.expectEqual(@as(usize, 2), mp.phase_count);
    try std.testing.expectEqual(@as(u8, 0), mp.overallPercentage());

    mp.completePhase(idx);
    try std.testing.expectEqual(@as(u8, 50), mp.overallPercentage());
}

test "MultiProgress startPhase" {
    var mp = MultiProgress.init();
    _ = mp.addPhase("Download", 500);
    const p = mp.startPhase(0);
    try std.testing.expectEqual(@as(u64, 500), p.total);
}
