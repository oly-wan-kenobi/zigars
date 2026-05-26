const std = @import("std");

const ports = @import("../../app/ports.zig");

pub const Runner = struct {
    command_runner: ports.CommandRunner,
    default_cwd: []const u8,
    default_timeout_ms: i64,

    const Self = @This();

    pub fn init(command_runner: ports.CommandRunner, default_cwd: []const u8, default_timeout_ms: i64) Self {
        return .{
            .command_runner = command_runner,
            .default_cwd = default_cwd,
            .default_timeout_ms = default_timeout_ms,
        };
    }

    pub fn port(self: *Self) ports.BackendProbe {
        return .{
            .ptr = self,
            .vtable = &.{ .check = check },
        };
    }

    fn check(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.BackendProbeRequest) ports.PortError!ports.BackendAvailability {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (request.argv.len == 0) return unavailable(allocator, request.backend, "missing probe argv", "backend probe request did not include an argv");
        const result = self.command_runner.run(allocator, .{
            .argv = request.argv,
            .cwd = request.cwd orelse self.default_cwd,
            .timeout_ms = request.timeout_ms orelse @intCast(@max(1, self.default_timeout_ms)),
            .max_stdout_bytes = 64 * 1024,
            .max_stderr_bytes = 64 * 1024,
            .provenance = if (request.provenance.len > 0) request.provenance else "backend_probe",
        }) catch |err| return unavailable(allocator, request.backend, @errorName(err), "confirm the configured backend path and executable permissions");
        defer result.deinit(allocator);
        if (result.effectiveTerm().failed() or result.timed_out) {
            return unavailable(allocator, request.backend, result.effectiveTerm().name(), "backend command exited non-zero; run the configured command directly to inspect stderr");
        }
        const backend = try allocator.dupe(u8, request.backend);
        var backend_owned = true;
        defer if (backend_owned) allocator.free(backend);
        const basis = try allocator.dupe(u8, "backend command completed");
        var basis_owned = true;
        defer if (basis_owned) allocator.free(basis);
        backend_owned = false;
        basis_owned = false;
        return .{
            .backend = backend,
            .available = true,
            .basis = basis,
            .owns_memory = true,
        };
    }
};

fn unavailable(allocator: std.mem.Allocator, backend: []const u8, reason: []const u8, basis: []const u8) ports.PortError!ports.BackendAvailability {
    const owned_backend = try allocator.dupe(u8, backend);
    var backend_owned = true;
    defer if (backend_owned) allocator.free(owned_backend);
    const owned_reason = try allocator.dupe(u8, reason);
    var reason_owned = true;
    defer if (reason_owned) allocator.free(owned_reason);
    const owned_basis = try allocator.dupe(u8, basis);
    var basis_owned = true;
    defer if (basis_owned) allocator.free(owned_basis);
    backend_owned = false;
    reason_owned = false;
    basis_owned = false;
    return .{
        .backend = owned_backend,
        .available = false,
        .unavailable_reason = owned_reason,
        .basis = owned_basis,
        .owns_memory = true,
    };
}
