//! Controlled command runner for explicit user profiling commands without shell expansion.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");

/// Per-stream cap (bytes) on captured stdout/stderr from the explicit profiler command.
pub const command_output_limit: usize = 1024 * 1024;

/// Environment variables the profiler child may inherit from the parent. Every
/// other variable — API tokens, cloud credentials, SSH agent vars, etc. — is
/// dropped so secrets in the MCP server's environment never reach the
/// agent-chosen profiler command. Names absent from the parent are skipped.
pub const profiler_env_allowlist = [_][]const u8{
    "PATH",
    "HOME",
    "TMPDIR",
    "TMP",
    "TEMP",
    "USER",
    "LOGNAME",
    "SHELL",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TERM",
    "ZIG_LIB_DIR",
    "ZIG_GLOBAL_CACHE_DIR",
    "ZIG_LOCAL_CACHE_DIR",
};

/// Carries request data across use case and port boundaries.
pub const Request = struct {
    argv: []const []const u8,
    timeout_ms: i64,
    title: []const u8 = "explicit user profiler command (argv split without shell)",
};

/// Carries owned argv data across use case and port boundaries.
pub const OwnedArgv = struct {
    items: [][]const u8,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *OwnedArgv, allocator: std.mem.Allocator) void {
        for (self.items) |arg| allocator.free(arg);
        allocator.free(self.items);
        self.* = undefined;
    }
};

/// Carries command run failure data across use case and port boundaries.
pub const CommandRunFailure = struct {
    err: ports.PortError,
    argv: OwnedArgv,
    cwd: []const u8,
    timeout_ms: i64,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *CommandRunFailure, allocator: std.mem.Allocator) void {
        self.argv.deinit(allocator);
        self.* = undefined;
    }
};

/// Represents result alternatives carried across the workflow boundary.
pub const Result = union(enum) {
    ok: ports.CommandResult,
    err: CommandRunFailure,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |command_result| command_result.deinit(allocator),
            .err => |*failure| failure.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Runs a pre-split profiler argv in the workspace root with no shell, so caller-supplied
/// strings are never word-split or glob/var-expanded by zigars. `request.argv` is passed
/// through verbatim; on a port error the argv is cloned into the failure for evidence.
/// `Result.ok` borrows the command result's buffers (caller `deinit`s the result).
pub fn run(allocator: std.mem.Allocator, context: app_context.ProfilingContext, request: Request) !Result {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var command_result = context.command_runner.run(allocator, .{
        .argv = request.argv,
        .cwd = context.workspace.root,
        .timeout_ms = normalizedTimeout(request.timeout_ms),
        .max_stdout_bytes = command_output_limit,
        .max_stderr_bytes = command_output_limit,
        .provenance = request.title,
        // Untrusted agent-chosen command: scrub the child environment to the
        // allowlist so the server's secrets are never inherited.
        .env = .{ .allowlist = &profiler_env_allowlist },
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

/// Normalizes numeric input into the bounded value used by this workflow.
fn normalizedTimeout(timeout_ms: i64) u64 {
    if (timeout_ms <= 0) return 0;
    return @intCast(timeout_ms);
}

/// Clones argv data into allocator-owned storage.
fn cloneArgv(allocator: std.mem.Allocator, argv: []const []const u8) !OwnedArgv {
    // Keep this logic centralized so callers observe one consistent behavior path.
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
