const std = @import("std");

const ports = @import("../../app/ports.zig");

const Allocator = std.mem.Allocator;

pub const State = struct {
    signature: u64 = 0,
    index_json: ?[]u8 = null,
    hits: usize = 0,
    refreshes: usize = 0,

    pub fn deinit(self: *State, allocator: Allocator) void {
        if (self.index_json) |bytes| allocator.free(bytes);
        self.* = .{};
    }
};

pub const Cache = struct {
    allocator: Allocator,
    state: *State,

    const Self = @This();

    pub fn init(allocator: Allocator, state: *State) Self {
        return .{ .allocator = allocator, .state = state };
    }

    pub fn port(self: *Self) ports.StaticCache {
        return .{
            .ptr = self,
            .vtable = &.{
                .status = status,
                .load = load,
                .store = store,
                .record_hit = recordHit,
            },
        };
    }

    fn status(ptr: *anyopaque) ports.PortError!ports.StaticCacheStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.currentStatus();
    }

    fn load(ptr: *anyopaque, _: Allocator) ports.PortError!ports.StaticCacheLoadResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return .{
            .status = self.currentStatus(),
            .bytes = self.state.index_json,
        };
    }

    fn store(ptr: *anyopaque, _: Allocator, request: ports.StaticCacheStoreRequest) ports.PortError!ports.StaticCacheStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const bytes = self.allocator.dupe(u8, request.bytes) catch return error.OutOfMemory;
        if (self.state.index_json) |old| self.allocator.free(old);
        self.state.index_json = bytes;
        self.state.signature = request.signature;
        self.state.refreshes += 1;
        return self.currentStatus();
    }

    fn recordHit(ptr: *anyopaque) ports.PortError!ports.StaticCacheStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.state.hits += 1;
        return self.currentStatus();
    }

    fn currentStatus(self: *Self) ports.StaticCacheStatus {
        return cacheStatus(self.state.*);
    }
};

fn cacheStatus(cache: anytype) ports.StaticCacheStatus {
    return .{
        .cached = cache.index_json != null,
        .signature = cache.signature,
        .hits = cache.hits,
        .refreshes = cache.refreshes,
        .bytes_len = if (cache.index_json) |bytes| bytes.len else 0,
    };
}

test "static cache stores bytes and records hits" {
    var state = State{};
    defer state.deinit(std.testing.allocator);

    var cache = Cache.init(std.testing.allocator, &state);
    const stored = try cache.port().store(std.testing.allocator, .{ .signature = 7, .bytes = "{}" });
    try std.testing.expect(stored.cached);
    try std.testing.expectEqual(@as(u64, 7), stored.signature);
    try std.testing.expectEqual(@as(usize, 1), stored.refreshes);

    const hit = try cache.port().recordHit();
    try std.testing.expectEqual(@as(usize, 1), hit.hits);
    const loaded = try cache.port().load(std.testing.allocator);
    try std.testing.expectEqualStrings("{}", loaded.bytes.?);
}
