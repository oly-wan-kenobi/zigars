const std = @import("std");

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    off = 4,

    fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
            .off => "off",
        };
    }
};

pub const Logger = struct {
    pub const Sink = enum {
        stderr,
        discard,
    };

    io: ?std.Io = null,
    min_level: Level = .info,
    sink: Sink = .discard,

    pub fn stderr(io: std.Io) Logger {
        return .{ .io = io, .sink = .stderr };
    }

    pub fn disabled() Logger {
        return .{};
    }

    pub fn withLevel(self: Logger, min_level: Level) Logger {
        var copy = self;
        copy.min_level = min_level;
        return copy;
    }

    pub fn debug(self: Logger, component: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, component, fmt, args);
    }

    pub fn info(self: Logger, component: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, component, fmt, args);
    }

    pub fn warn(self: Logger, component: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, component, fmt, args);
    }

    pub fn err(self: Logger, component: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, component, fmt, args);
    }

    pub fn log(self: Logger, level: Level, component: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (!self.enabled(level)) return;
        if (self.sink != .stderr) return;
        const io = self.io orelse return;

        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &buffer);
        writer.interface.print("[zigar/{s}] {s}: ", .{ component, level.label() }) catch return;
        writer.interface.print(fmt, args) catch return;
        writer.interface.writeByte('\n') catch return;
        writer.interface.flush() catch return;
    }

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
