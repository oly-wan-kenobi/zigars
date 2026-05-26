//! Controlled command runner for explicit user profiling commands without shell expansion.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");

pub const command_output_limit: usize = 1024 * 1024;

pub const Request = struct {
    argv: []const []const u8,
    timeout_ms: i64,
    title: []const u8 = "explicit user profiler command (argv split without shell)",
};

pub const OwnedArgv = struct {
    items: [][]const u8,

    pub fn deinit(self: *OwnedArgv, allocator: std.mem.Allocator) void {
        for (self.items) |arg| allocator.free(arg);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const CommandRunFailure = struct {
    err: ports.PortError,
    argv: OwnedArgv,
    cwd: []const u8,
    timeout_ms: i64,

    pub fn deinit(self: *CommandRunFailure, allocator: std.mem.Allocator) void {
        self.argv.deinit(allocator);
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    ok: ports.CommandResult,
    err: CommandRunFailure,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |command_result| command_result.deinit(allocator),
            .err => |*failure| failure.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub fn run(allocator: std.mem.Allocator, context: app_context.ProfilingContext, request: Request) !Result {
    var command_result = context.command_runner.run(allocator, .{
        .argv = request.argv,
        .cwd = context.workspace.root,
        .timeout_ms = normalizedTimeout(request.timeout_ms),
        .max_stdout_bytes = command_output_limit,
        .max_stderr_bytes = command_output_limit,
        .provenance = request.title,
    }) catch |err| {
        var owned_argv = try cloneArgv(allocator, request.argv);
        errdefer owned_argv.deinit(allocator);
        return .{ .err = .{
            .err = err,
            .argv = owned_argv,
            .cwd = context.workspace.root,
            .timeout_ms = request.timeout_ms,
        } };
    };
    command_result.provenance = request.title;
    return .{ .ok = command_result };
}

fn normalizedTimeout(timeout_ms: i64) u64 {
    if (timeout_ms <= 0) return 0;
    return @intCast(timeout_ms);
}

fn cloneArgv(allocator: std.mem.Allocator, argv: []const []const u8) !OwnedArgv {
    const items = try allocator.alloc([]const u8, argv.len);
    var items_owned = true;
    var filled: usize = 0;
    defer if (items_owned) {
        for (items[0..filled]) |arg| allocator.free(arg);
        allocator.free(items);
    };
    for (argv, 0..) |arg, index| {
        items[index] = try allocator.dupe(u8, arg);
        filled += 1;
    }
    items_owned = false;
    return .{ .items = items };
}

test "profiling run argv cloning cleans partial allocations" {
    for (0..8) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const cloned = cloneArgv(failing.allocator(), &.{ "zflame", "flamegraph", "profile.folded" }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        var mutable = cloned;
        mutable.deinit(failing.allocator());
    }
}
