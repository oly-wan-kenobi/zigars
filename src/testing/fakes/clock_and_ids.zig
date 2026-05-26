const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

pub const FakeClockAndIds = struct {
    allocator: Allocator,
    instants: std.ArrayList(ports.Instant) = .empty,
    expected_ids: std.ArrayList(ExpectedId) = .empty,
    id_records: std.ArrayList(ports.IdRequest) = .empty,
    next_instant: usize = 0,
    next_id: usize = 0,
    now_call_count: usize = 0,

    const Self = @This();

    const ExpectedId = struct {
        request: ports.IdRequest,
        id: []const u8,

        fn deinit(self: ExpectedId, allocator: Allocator) void {
            allocator.free(self.request.prefix);
            allocator.free(self.id);
        }
    };

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.instants.deinit(self.allocator);
        for (self.expected_ids.items) |expected| expected.deinit(self.allocator);
        self.expected_ids.deinit(self.allocator);
        for (self.id_records.items) |record| allocatorFreeIdRequest(self.allocator, record);
        self.id_records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn port(self: *Self) ports.ClockAndIds {
        return .{
            .ptr = self,
            .vtable = &.{
                .now = now,
                .nextId = nextId,
            },
        };
    }

    pub fn pushInstant(self: *Self, instant: ports.Instant) !void {
        try self.instants.append(self.allocator, instant);
    }

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

    pub fn nowCalls(self: *const Self) usize {
        return self.now_call_count;
    }

    pub fn idCalls(self: *const Self) []const ports.IdRequest {
        return self.id_records.items;
    }

    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_instant != self.instants.items.len) return error.MissingExpectedCall;
        if (self.next_id != self.expected_ids.items.len) return error.MissingExpectedCall;
    }

    fn now(ptr: *anyopaque) ports.PortError!ports.Instant {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.now_call_count += 1;
        if (self.next_instant >= self.instants.items.len) return error.UnexpectedCall;
        const instant = self.instants.items[self.next_instant];
        self.next_instant += 1;
        return instant;
    }

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

    fn cloneIdRequest(allocator: Allocator, request: ports.IdRequest) !ports.IdRequest {
        return .{ .prefix = try common.dupString(allocator, request.prefix) };
    }

    fn allocatorFreeIdRequest(allocator: Allocator, request: ports.IdRequest) void {
        allocator.free(request.prefix);
    }

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
