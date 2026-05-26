const std = @import("std");

const ports = @import("../../app/ports.zig");
const command = @import("../process/command.zig");

/// ToolchainEnv port backed by `zig env`.
/// Returned values are caller-owned when the port reports `owns_value`.
pub const Env = struct {
    io: std.Io,
    cwd: []const u8,
    zig_path: []const u8,
    timeout_ms: i64,

    const Self = @This();

    /// Stores borrowed paths and timeout defaults used for each env lookup.
    pub fn init(io: std.Io, cwd: []const u8, zig_path: []const u8, timeout_ms: i64) Self {
        return .{
            .io = io,
            .cwd = cwd,
            .zig_path = zig_path,
            .timeout_ms = timeout_ms,
        };
    }

    /// Exposes this adapter through the ToolchainEnv vtable.
    pub fn port(self: *Self) ports.ToolchainEnv {
        return .{
            .ptr = self,
            .vtable = &.{
                .get = get,
            },
        };
    }

    /// Reads the requested environment value through this port implementation.
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

/// Maps port error into the port-facing representation without taking ownership unless documented by the result.
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

test "toolchain env maps filesystem and timeout errors" {
    try std.testing.expectEqual(error.AccessDenied, mapPortError(error.AccessDenied));
    try std.testing.expectEqual(error.PermissionDenied, mapPortError(error.PermissionDenied));
    try std.testing.expectEqual(error.Unavailable, mapPortError(error.BrokenPipe));
}
