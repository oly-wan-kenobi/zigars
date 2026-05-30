//! Fake implementation of the `ports.ToolchainEnv` port.
//! Simulates environment variable lookups (e.g. `std_dir`, `zig_version`) used
//! by toolchain-aware use cases. Use `expectGetError` to inject missing-key or
//! access-denied failures without modifying the process environment.

const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

/// ToolchainEnv fake with ordered key/provenance expectations.
pub const FakeToolchainEnv = struct {
    allocator: Allocator,
    expected_gets: std.ArrayList(ExpectedGet) = .empty,
    call_records: std.ArrayList(ports.ToolchainEnvRequest) = .empty,
    next_get: usize = 0,

    const Self = @This();

    /// Expected env lookup and either an owned value or port error.
    const ExpectedGet = struct {
        request: ports.ToolchainEnvRequest,
        result: ExpectedResult,

        /// Frees the cloned env request and stored result.
        fn deinit(self: ExpectedGet, allocator: Allocator) void {
            freeRequest(allocator, self.request);
            self.result.deinit(allocator);
        }
    };

    /// Stored result for one expected env lookup.
    const ExpectedResult = union(enum) {
        ok: []const u8,
        err: ports.PortError,

        /// Releases the owned env value for successful outcomes.
        fn deinit(self: ExpectedResult, allocator: Allocator) void {
            switch (self) {
                .ok => |value| allocator.free(value),
                .err => {},
            }
        }
    };

    /// Creates an empty fake that owns expectations with `allocator`.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Frees expectations and recorded call snapshots.
    pub fn deinit(self: *Self) void {
        for (self.expected_gets.items) |expected| expected.deinit(self.allocator);
        self.expected_gets.deinit(self.allocator);
        for (self.call_records.items) |request| freeRequest(self.allocator, request);
        self.call_records.deinit(self.allocator);
        self.* = undefined;
    }

    /// Exposes this fake through the ToolchainEnv vtable.
    pub fn port(self: *Self) ports.ToolchainEnv {
        return .{
            .ptr = self,
            .vtable = &.{
                .get = get,
            },
        };
    }

    /// Adds an ordered successful env lookup expectation.
    pub fn expectGet(self: *Self, request: ports.ToolchainEnvRequest, value: []const u8) !void {
        const owned_request = try cloneRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeRequest(self.allocator, owned_request);
        try self.expected_gets.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = try common.dupString(self.allocator, value) },
        });
        request_owned = false;
    }

    /// Adds an ordered failing env lookup expectation.
    pub fn expectGetError(self: *Self, request: ports.ToolchainEnvRequest, err: ports.PortError) !void {
        const owned_request = try cloneRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeRequest(self.allocator, owned_request);
        try self.expected_gets.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
        request_owned = false;
    }

    /// Fails if any ordered expectation was not consumed.
    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_get != self.expected_gets.items.len) return error.MissingExpectedCall;
    }

    /// Reads the requested environment value through this port implementation.
    fn get(ptr: *anyopaque, allocator: Allocator, request: ports.ToolchainEnvRequest) ports.PortError!ports.ToolchainEnvValue {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneRequest(self.allocator, request);
        var call_record_owned = false;
        errdefer if (!call_record_owned) freeRequest(self.allocator, owned_call);
        try self.call_records.append(self.allocator, owned_call);
        call_record_owned = true;

        if (self.next_get >= self.expected_gets.items.len) return error.UnexpectedCall;
        const expected = self.expected_gets.items[self.next_get];
        if (!requestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_get += 1;

        return switch (expected.result) {
            .ok => |value| .{
                .value = try common.dupString(allocator, value),
                .owns_value = true,
            },
            .err => |err| err,
        };
    }

    /// Clones request into allocator-owned storage.
    fn cloneRequest(allocator: Allocator, request: ports.ToolchainEnvRequest) !ports.ToolchainEnvRequest {
        return .{
            .key = try common.dupString(allocator, request.key),
            .provenance = try common.dupString(allocator, request.provenance),
        };
    }

    /// Releases allocator-owned fields held by the cloned request.
    fn freeRequest(allocator: Allocator, request: ports.ToolchainEnvRequest) void {
        allocator.free(request.key);
        allocator.free(request.provenance);
    }

    /// Compares requests by the fields that affect behavior.
    fn requestsEqual(expected: ports.ToolchainEnvRequest, actual: ports.ToolchainEnvRequest) bool {
        return std.mem.eql(u8, expected.key, actual.key) and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }
};

test "toolchain env fake returns expected values" {
    var fake = FakeToolchainEnv.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectGet(.{ .key = "std_dir", .provenance = "docs" }, "/zig/lib/std");
    const result = try fake.port().get(std.testing.allocator, .{ .key = "std_dir", .provenance = "docs" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/zig/lib/std", result.value);
    try fake.verify();
}
