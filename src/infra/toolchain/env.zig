const std = @import("std");

const ports = @import("../../app/ports.zig");
const command = @import("../process/command.zig");

pub const Env = struct {
    io: std.Io,
    cwd: []const u8,
    zig_path: []const u8,
    timeout_ms: i64,

    const Self = @This();

    pub fn init(io: std.Io, cwd: []const u8, zig_path: []const u8, timeout_ms: i64) Self {
        return .{
            .io = io,
            .cwd = cwd,
            .zig_path = zig_path,
            .timeout_ms = timeout_ms,
        };
    }

    pub fn port(self: *Self) ports.ToolchainEnv {
        return .{
            .ptr = self,
            .vtable = &.{
                .get = get,
            },
        };
    }

    fn get(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.ToolchainEnvRequest) ports.PortError!ports.ToolchainEnvValue {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const result = command.run(allocator, self.io, self.cwd, &.{ self.zig_path, "env" }, self.timeout_ms) catch |err| return mapPortError(err);
        defer result.deinit(allocator);
        const needle = std.fmt.allocPrint(allocator, ".{s} = \"", .{request.key}) catch return error.OutOfMemory;
        defer allocator.free(needle);
        const start_needle = std.mem.indexOf(u8, result.stdout, needle) orelse return error.NotFound;
        const start = start_needle + needle.len;
        const end = std.mem.indexOfScalarPos(u8, result.stdout, start, '"') orelse return error.NotFound;
        return .{
            .value = allocator.dupe(u8, result.stdout[start..end]) catch return error.OutOfMemory,
            .owns_value = true,
        };
    }
};

fn mapPortError(err: anyerror) ports.PortError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Timeout => error.Timeout,
        error.RequestTimeout => error.RequestTimeout,
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.StreamTooLong => error.StreamTooLong,
        error.NotFound => error.NotFound,
        else => error.Unavailable,
    };
}
