const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

pub const FakeCommandRunner = struct {
    allocator: Allocator,
    expected_runs: std.ArrayList(ExpectedRun) = .empty,
    call_records: std.ArrayList(ports.CommandRequest) = .empty,
    next_run: usize = 0,

    const Self = @This();

    const ExpectedRun = struct {
        request: ports.CommandRequest,
        result: ExpectedRunResult,

        fn deinit(self: ExpectedRun, allocator: Allocator) void {
            freeRequest(allocator, self.request);
            self.result.deinit(allocator);
        }
    };

    const ExpectedRunResult = union(enum) {
        ok: ports.CommandResult,
        err: ports.PortError,

        fn deinit(self: ExpectedRunResult, allocator: Allocator) void {
            switch (self) {
                .ok => |result| {
                    allocator.free(result.stdout);
                    allocator.free(result.stderr);
                    allocator.free(result.provenance);
                },
                .err => {},
            }
        }
    };

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.expected_runs.items) |expected| expected.deinit(self.allocator);
        self.expected_runs.deinit(self.allocator);

        for (self.call_records.items) |record| freeRequest(self.allocator, record);
        self.call_records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn port(self: *Self) ports.CommandRunner {
        return .{
            .ptr = self,
            .vtable = &.{
                .run = run,
            },
        };
    }

    pub fn expectRun(self: *Self, request: ports.CommandRequest, result: ports.CommandResult) !void {
        const owned_request = try cloneRequest(self.allocator, request);
        errdefer freeRequest(self.allocator, owned_request);

        const owned_stdout = try common.dupString(self.allocator, result.stdout);
        errdefer self.allocator.free(owned_stdout);
        const owned_stderr = try common.dupString(self.allocator, result.stderr);
        errdefer self.allocator.free(owned_stderr);
        const owned_provenance = try common.dupString(self.allocator, result.provenance);
        errdefer self.allocator.free(owned_provenance);

        try self.expected_runs.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = .{
                .exit_code = result.exit_code,
                .term = result.effectiveTerm(),
                .stdout = owned_stdout,
                .stderr = owned_stderr,
                .duration_ms = result.duration_ms,
                .timed_out = result.timed_out,
                .stdout_truncated = result.stdout_truncated,
                .stderr_truncated = result.stderr_truncated,
                .provenance = owned_provenance,
            } },
        });
    }

    pub fn expectRunError(self: *Self, request: ports.CommandRequest, err: ports.PortError) !void {
        const owned_request = try cloneRequest(self.allocator, request);
        errdefer freeRequest(self.allocator, owned_request);
        try self.expected_runs.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
    }

    pub fn calls(self: *const Self) []const ports.CommandRequest {
        return self.call_records.items;
    }

    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_run != self.expected_runs.items.len) return error.MissingExpectedCall;
    }

    fn run(ptr: *anyopaque, allocator: Allocator, request: ports.CommandRequest) ports.PortError!ports.CommandResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneRequest(self.allocator, request);
        var record_owned = false;
        errdefer if (!record_owned) freeRequest(self.allocator, owned_call);
        try self.call_records.append(self.allocator, owned_call);
        record_owned = true;

        if (self.next_run >= self.expected_runs.items.len) return error.UnexpectedCall;
        const expected = self.expected_runs.items[self.next_run];
        if (!common.stringListsEqual(expected.request.argv, request.argv)) return error.StaleArguments;
        if (!requestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_run += 1;

        const expected_result = switch (expected.result) {
            .ok => |result| result,
            .err => |err| return err,
        };

        const stdout = try common.dupString(allocator, expected_result.stdout);
        errdefer allocator.free(stdout);
        const stderr = try common.dupString(allocator, expected_result.stderr);
        errdefer allocator.free(stderr);

        return .{
            .exit_code = expected_result.exit_code,
            .term = expected_result.term,
            .stdout = stdout,
            .stderr = stderr,
            .duration_ms = expected_result.duration_ms,
            .timed_out = expected_result.timed_out,
            .stdout_truncated = expected_result.stdout_truncated,
            .stderr_truncated = expected_result.stderr_truncated,
            .provenance = expected_result.provenance,
            .owns_stdout = true,
            .owns_stderr = true,
        };
    }

    fn cloneRequest(allocator: Allocator, request: ports.CommandRequest) !ports.CommandRequest {
        const argv = try common.dupStringList(allocator, request.argv);
        errdefer common.freeStringList(allocator, argv);
        const cwd = try common.dupOptionalString(allocator, request.cwd);
        errdefer common.freeOptionalString(allocator, cwd);
        const provenance = try common.dupString(allocator, request.provenance);
        errdefer allocator.free(provenance);

        return .{
            .argv = argv,
            .cwd = cwd,
            .timeout_ms = request.timeout_ms,
            .max_stdout_bytes = request.max_stdout_bytes,
            .max_stderr_bytes = request.max_stderr_bytes,
            .provenance = provenance,
        };
    }

    fn freeRequest(allocator: Allocator, request: ports.CommandRequest) void {
        common.freeStringList(allocator, request.argv);
        common.freeOptionalString(allocator, request.cwd);
        allocator.free(request.provenance);
    }

    fn requestsEqual(expected: ports.CommandRequest, actual: ports.CommandRequest) bool {
        return common.stringListsEqual(expected.argv, actual.argv) and
            common.optionalStringsEqual(expected.cwd, actual.cwd) and
            expected.timeout_ms == actual.timeout_ms and
            expected.max_stdout_bytes == actual.max_stdout_bytes and
            expected.max_stderr_bytes == actual.max_stderr_bytes and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }
};

test "command runner returns expected output and records calls" {
    var fake = FakeCommandRunner.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectRun(.{
        .argv = &.{ "zig", "build", "test" },
        .cwd = ".",
        .timeout_ms = 30_000,
        .provenance = "use-case",
    }, .{
        .exit_code = 0,
        .stdout = "ok\n",
        .stderr = "",
        .duration_ms = 12,
    });

    const result = try fake.port().run(std.testing.allocator, .{
        .argv = &.{ "zig", "build", "test" },
        .cwd = ".",
        .timeout_ms = 30_000,
        .provenance = "use-case",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqualStrings("ok\n", result.stdout);
    try std.testing.expectEqual(@as(usize, 1), fake.calls().len);
    try std.testing.expectEqualStrings("build", fake.calls()[0].argv[1]);
    try fake.verify();
}

test "command runner rejects stale argv and records the attempted call" {
    var fake = FakeCommandRunner.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectRun(.{ .argv = &.{ "zig", "build", "test" } }, .{ .exit_code = 0 });

    try std.testing.expectError(error.StaleArguments, fake.port().run(std.testing.allocator, .{
        .argv = &.{ "zig", "build", "smoke" },
    }));
    try std.testing.expectEqual(@as(usize, 1), fake.calls().len);
    try std.testing.expectError(error.MissingExpectedCall, fake.verify());
}

test "command runner rejects stale non-argv arguments" {
    var fake = FakeCommandRunner.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectRun(.{
        .argv = &.{ "zig", "build", "test" },
        .cwd = ".",
        .timeout_ms = 30_000,
    }, .{ .exit_code = 0 });

    try std.testing.expectError(error.StaleArguments, fake.port().run(std.testing.allocator, .{
        .argv = &.{ "zig", "build", "test" },
        .cwd = ".",
        .timeout_ms = 1,
    }));
    try std.testing.expectEqual(@as(usize, 1), fake.calls().len);
    try std.testing.expectError(error.MissingExpectedCall, fake.verify());
}

test "command runner fails unexpected calls" {
    var fake = FakeCommandRunner.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(error.UnexpectedCall, fake.port().run(std.testing.allocator, .{
        .argv = &.{ "zig", "build", "test" },
    }));
}
