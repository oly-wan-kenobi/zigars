//! Fake implementation of the `ports.ClockAndIds` port.
//! Returns deterministic timestamps and identifier strings from caller-supplied
//! queues, enabling reproducible ordering and naming in use-case tests without
//! real clock or UUID dependencies.

const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

/// ClockAndIds fake that returns deterministic instants and IDs in order.
pub const FakeClockAndIds = struct {
    allocator: Allocator,
    instants: std.ArrayList(ports.Instant) = .empty,
    expected_ids: std.ArrayList(ExpectedId) = .empty,
    id_records: std.ArrayList(ports.IdRequest) = .empty,
    next_instant: usize = 0,
    next_id: usize = 0,
    now_call_count: usize = 0,

    const Self = @This();

    /// Expected ID request and owned string returned by nextId.
    const ExpectedId = struct {
        request: ports.IdRequest,
        id: []const u8,

        /// Frees the cloned ID prefix and queued ID result.
        fn deinit(self: ExpectedId, allocator: Allocator) void {
            allocator.free(self.request.prefix);
            allocator.free(self.id);
        }
    };

    /// Creates an empty fake that owns expected IDs with `allocator`.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Frees expected IDs and recorded request snapshots.
    pub fn deinit(self: *Self) void {
        self.instants.deinit(self.allocator);
        for (self.expected_ids.items) |expected| expected.deinit(self.allocator);
        self.expected_ids.deinit(self.allocator);
        for (self.id_records.items) |record| allocatorFreeIdRequest(self.allocator, record);
        self.id_records.deinit(self.allocator);
        self.* = undefined;
    }

    /// Exposes this fake through the ClockAndIds vtable.
    pub fn port(self: *Self) ports.ClockAndIds {
        return .{
            .ptr = self,
            .vtable = &.{
                .now = now,
                .nextId = nextId,
            },
        };
    }

    /// Queues the next instant returned by `now`.
    pub fn pushInstant(self: *Self, instant: ports.Instant) !void {
        try self.instants.append(self.allocator, instant);
    }

    /// Queues the next ID response and clones the expected prefix.
    pub fn expectId(self: *Self, request: ports.IdRequest, id: []const u8) !void {
        const prefix = try common.dupString(self.allocator, request.prefix);
        var prefix_owned = true;
        defer if (prefix_owned) self.allocator.free(prefix);
        const owned_id = try common.dupString(self.allocator, id);
        var id_owned = true;
        defer if (id_owned) self.allocator.free(owned_id);
        try self.expected_ids.append(self.allocator, .{
            .request = .{ .prefix = prefix },
            .id = owned_id,
        });
        prefix_owned = false;
        id_owned = false;
    }

    /// Returns the number of attempted `now` calls.
    pub fn nowCalls(self: *const Self) usize {
        return self.now_call_count;
    }

    /// Returns immutable snapshots of attempted ID calls.
    pub fn idCalls(self: *const Self) []const ports.IdRequest {
        return self.id_records.items;
    }

    /// Fails if any queued instant or ID expectation was not consumed.
    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_instant != self.instants.items.len) return error.MissingExpectedCall;
        if (self.next_id != self.expected_ids.items.len) return error.MissingExpectedCall;
    }

    /// Returns the current test or system timestamp.
    fn now(ptr: *anyopaque) ports.PortError!ports.Instant {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.now_call_count += 1;
        if (self.next_instant >= self.instants.items.len) return error.UnexpectedCall;
        const instant = self.instants.items[self.next_instant];
        self.next_instant += 1;
        return instant;
    }

    /// Allocates the next deterministic identifier.
    fn nextId(ptr: *anyopaque, allocator: Allocator, request: ports.IdRequest) ports.PortError![]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_request = try cloneIdRequest(self.allocator, request);
        var record_owned = false;
        errdefer if (!record_owned) allocatorFreeIdRequest(self.allocator, owned_request);
        try self.id_records.append(self.allocator, owned_request);
        record_owned = true;

        if (self.next_id >= self.expected_ids.items.len) return error.UnexpectedCall;
        const expected = self.expected_ids.items[self.next_id];
        if (!idRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_id += 1;
        return try common.dupString(allocator, expected.id);
    }

    /// Clones id request into allocator-owned storage.
    fn cloneIdRequest(allocator: Allocator, request: ports.IdRequest) !ports.IdRequest {
        return .{ .prefix = try common.dupString(allocator, request.prefix) };
    }

    /// Releases an allocator-owned ID request prefix.
    fn allocatorFreeIdRequest(allocator: Allocator, request: ports.IdRequest) void {
        allocator.free(request.prefix);
    }

    /// Compares id requests by the fields that affect behavior.
    fn idRequestsEqual(expected: ports.IdRequest, actual: ports.IdRequest) bool {
        return std.mem.eql(u8, expected.prefix, actual.prefix);
    }
};

test "clock and ids return deterministic sequences" {
    var fake = FakeClockAndIds.init(std.testing.allocator);
    defer fake.deinit();

    try fake.pushInstant(.{ .unix_ms = 1_700_000_000_001, .monotonic_ms = 10 });
    try fake.pushInstant(.{ .unix_ms = 1_700_000_000_002, .monotonic_ms = 11 });
    try fake.expectId(.{ .prefix = "artifact" }, "artifact-0001");

    const first = try fake.port().now();
    const second = try fake.port().now();
    try std.testing.expectEqual(@as(i64, 1_700_000_000_001), first.unix_ms);
    try std.testing.expectEqual(@as(u64, 11), second.monotonic_ms);

    const id = try fake.port().nextId(std.testing.allocator, .{ .prefix = "artifact" });
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("artifact-0001", id);
    try std.testing.expectEqual(@as(usize, 2), fake.nowCalls());
    try std.testing.expectEqualStrings("artifact", fake.idCalls()[0].prefix);
    try fake.verify();
}

test "clock and ids fail when deterministic values are exhausted" {
    var fake = FakeClockAndIds.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(error.UnexpectedCall, fake.port().now());
    try std.testing.expectError(error.UnexpectedCall, fake.port().nextId(std.testing.allocator, .{ .prefix = "tmp" }));
}
