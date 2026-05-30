//! Lightweight stderr logger and correlation-prefix helpers.
//! All log output goes to stderr; stdout is reserved for MCP JSON-RPC.

const std = @import("std");

/// Borrowed request correlation fields used in compact diagnostic prefixes.
pub const CorrelationFields = struct {
    trace_id: []const u8,
    request_id: []const u8,
    method: []const u8,
    tool_name: ?[]const u8 = null,
};

/// Formats a compact request correlation prefix for stderr diagnostics.
/// Writes into `buffer` and returns a slice of it; the slice is valid only
/// while `buffer` is in scope.  Falls back to a static unavailable string on
/// format overflow.
pub fn formatCorrelationPrefix(buffer: []u8, fields: CorrelationFields) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (fields.tool_name) |tool_name| {
        return std.fmt.bufPrint(buffer, "trace={s} req={s} method={s} tool={s}", .{
            fields.trace_id,
            fields.request_id,
            fields.method,
            tool_name,
        }) catch "trace=unavailable req=unavailable method=unavailable";
    }
    return std.fmt.bufPrint(buffer, "trace={s} req={s} method={s}", .{
        fields.trace_id,
        fields.request_id,
        fields.method,
    }) catch "trace=unavailable req=unavailable method=unavailable";
}

/// Log severity threshold used by the lightweight process logger.
/// Numeric values allow monotonic comparison: a message is emitted when its
/// level integer is >= the configured minimum.  `off` disables all output.
pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    off = 4,

    /// Returns the static label for this log level.
    fn label(self: Level) []const u8 {
        // Keep this logic centralized so callers observe one consistent behavior path.
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
            .off => "off",
        };
    }
};

/// Small stderr/discard logger used where observability state is unavailable.
/// This type owns no memory and is safe to copy.  All output goes to stderr;
/// use `Sink.discard` when no I/O handle is available (e.g. in tests).
pub const Logger = struct {
    /// Output target for formatted log lines.
    pub const Sink = enum {
        stderr,
        discard,
    };

    io: ?std.Io = null,
    min_level: Level = .info,
    sink: Sink = .discard,

    /// Creates a logger that writes to stderr using the supplied I/O handle.
    pub fn stderr(io: std.Io) Logger {
        return .{ .io = io, .sink = .stderr };
    }

    /// Creates a logger that drops every message.
    pub fn disabled() Logger {
        return .{};
    }

    /// Returns a copy with a different minimum level.
    pub fn withLevel(self: Logger, min_level: Level) Logger {
        var copy = self;
        copy.min_level = min_level;
        return copy;
    }

    /// Logs a debug message if enabled.
    pub fn debug(self: Logger, component: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, component, fmt, args);
    }

    /// Logs an info message if enabled.
    pub fn info(self: Logger, component: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, component, fmt, args);
    }

    /// Logs a warning message if enabled.
    pub fn warn(self: Logger, component: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, component, fmt, args);
    }

    /// Logs an error message if enabled.
    pub fn err(self: Logger, component: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, component, fmt, args);
    }

    /// Formats and writes one log line to stderr, swallowing I/O failures.
    /// Logging must never interrupt the MCP JSON-RPC stream on stdout.
    pub fn log(self: Logger, level: Level, component: []const u8, comptime fmt: []const u8, args: anytype) void {
        // Keep this logic centralized so callers observe one consistent behavior path.
        if (!self.enabled(level)) return;
        if (self.sink != .stderr) return;
        const io = self.io orelse return;

        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &buffer);
        writer.interface.print("[zigars/{s}] {s}: ", .{ component, level.label() }) catch return;
        writer.interface.print(fmt, args) catch return;
        writer.interface.writeByte('\n') catch return;
        writer.interface.flush() catch return;
    }

    /// Reports whether messages at this level should be emitted.
    fn enabled(self: Logger, level: Level) bool {
        if (self.min_level == .off) return false;
        return @intFromEnum(level) >= @intFromEnum(self.min_level);
    }
};

test "logger level filtering is monotonic" {
    const logger = Logger.disabled().withLevel(.warn);
    try std.testing.expect(!logger.enabled(.debug));
    try std.testing.expect(!logger.enabled(.info));
    try std.testing.expect(logger.enabled(.warn));
    try std.testing.expect(logger.enabled(.err));
}
