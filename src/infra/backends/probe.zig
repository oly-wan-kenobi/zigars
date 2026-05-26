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

const fakes = @import("../../testing/fakes/root.zig");

test "backend probe reports missing argv without invoking command runner" {
    var command_runner = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_runner.deinit();
    var runner = Runner.init(command_runner.port(), "/repo", 30_000);

    const availability = try runner.port().check(std.testing.allocator, .{ .backend = "zls" });
    defer availability.deinit(std.testing.allocator);
    try std.testing.expect(!availability.available);
    try std.testing.expectEqualStrings("missing probe argv", availability.unavailable_reason.?);
    try command_runner.verify();
}

test "backend probe maps command errors and non-zero exits to unavailable" {
    var command_runner = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_runner.deinit();
    try command_runner.expectRunError(.{
        .argv = &.{ "zls", "--version" },
        .cwd = "/repo",
        .timeout_ms = 10,
        .max_stdout_bytes = 64 * 1024,
        .max_stderr_bytes = 64 * 1024,
        .provenance = "probe-test",
    }, error.FileNotFound);
    try command_runner.expectRun(.{
        .argv = &.{ "zlint", "--version" },
        .cwd = "/repo",
        .timeout_ms = 30_000,
        .max_stdout_bytes = 64 * 1024,
        .max_stderr_bytes = 64 * 1024,
        .provenance = "backend_probe",
    }, .{ .exit_code = 1, .stderr = "bad\n" });
    var runner = Runner.init(command_runner.port(), "/repo", 30_000);

    const missing = try runner.port().check(std.testing.allocator, .{
        .backend = "zls",
        .argv = &.{ "zls", "--version" },
        .timeout_ms = 10,
        .provenance = "probe-test",
    });
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(!missing.available);
    try std.testing.expectEqualStrings("FileNotFound", missing.unavailable_reason.?);

    const nonzero = try runner.port().check(std.testing.allocator, .{
        .backend = "zlint",
        .argv = &.{ "zlint", "--version" },
    });
    defer nonzero.deinit(std.testing.allocator);
    try std.testing.expect(!nonzero.available);
    try std.testing.expectEqualStrings("exited", nonzero.unavailable_reason.?);
    try command_runner.verify();
}

test "backend probe reports successful command completion" {
    var command_runner = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_runner.deinit();
    try command_runner.expectRun(.{
        .argv = &.{ "zls", "--version" },
        .cwd = "/repo",
        .timeout_ms = 30_000,
        .max_stdout_bytes = 64 * 1024,
        .max_stderr_bytes = 64 * 1024,
        .provenance = "backend_probe",
    }, .{ .exit_code = 0, .stdout = "zls\n" });
    var runner = Runner.init(command_runner.port(), "/repo", 30_000);

    const availability = try runner.port().check(std.testing.allocator, .{
        .backend = "zls",
        .argv = &.{ "zls", "--version" },
    });
    defer availability.deinit(std.testing.allocator);
    try std.testing.expect(availability.available);
    try std.testing.expectEqualStrings("backend command completed", availability.basis);
    try command_runner.verify();
}
