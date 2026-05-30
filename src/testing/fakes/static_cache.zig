//! Fake implementation of the `ports.StaticCache` port.
//! Holds one allocator-owned JSON payload in memory. Use `seed` to pre-populate
//! without counting as a store call, then assert `store_calls`/`hits` counters
//! to verify cache-management behavior in use-case tests.

const std = @import("std");

const ports = @import("../../app/ports.zig");

const Allocator = std.mem.Allocator;

/// StaticCache fake that stores one owned JSON payload in memory.
pub const FakeStaticCache = struct {
    allocator: Allocator,
    signature: u64 = 0,
    bytes: ?[]u8 = null,
    hits: usize = 0,
    refreshes: usize = 0,
    load_calls: usize = 0,
    store_calls: usize = 0,

    const Self = @This();

    /// Creates an empty cache fake.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Frees the seeded or stored payload.
    pub fn deinit(self: *Self) void {
        if (self.bytes) |bytes| self.allocator.free(bytes);
        self.* = undefined;
    }

    /// Seeds the cache without counting as a store call.
    pub fn seed(self: *Self, signature: u64, bytes: []const u8) !void {
        if (self.bytes) |old| self.allocator.free(old);
        self.bytes = try self.allocator.dupe(u8, bytes);
        self.signature = signature;
    }

    /// Exposes this fake through the StaticCache vtable.
    pub fn port(self: *Self) ports.StaticCache {
        // Keep this logic centralized so callers observe one consistent behavior path.
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

    /// Returns the cached status snapshot for this implementation.
    fn status(ptr: *anyopaque) ports.PortError!ports.StaticCacheStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.currentStatus();
    }

    /// Loads a cached value for this implementation.
    fn load(ptr: *anyopaque, _: Allocator) ports.PortError!ports.StaticCacheLoadResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.load_calls += 1;
        return .{
            .status = self.currentStatus(),
            .bytes = self.bytes,
        };
    }

    /// Stores a cached value for this implementation.
    fn store(ptr: *anyopaque, _: Allocator, request: ports.StaticCacheStoreRequest) ports.PortError!ports.StaticCacheStatus {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned = self.allocator.dupe(u8, request.bytes) catch return error.OutOfMemory;
        if (self.bytes) |old| self.allocator.free(old);
        self.bytes = owned;
        self.signature = request.signature;
        self.refreshes += 1;
        self.store_calls += 1;
        return self.currentStatus();
    }

    /// Records a cache hit for this implementation.
    fn recordHit(ptr: *anyopaque) ports.PortError!ports.StaticCacheStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.hits += 1;
        return self.currentStatus();
    }

    /// Returns the current cache status snapshot.
    fn currentStatus(self: *const Self) ports.StaticCacheStatus {
        // Keep this logic centralized so callers observe one consistent behavior path.
        return .{
            .cached = self.bytes != null,
            .signature = self.signature,
            .hits = self.hits,
            .refreshes = self.refreshes,
            .bytes_len = if (self.bytes) |bytes| bytes.len else 0,
        };
    }
};

test "fake static cache stores and loads bytes" {
    var cache = FakeStaticCache.init(std.testing.allocator);
    defer cache.deinit();

    _ = try cache.port().store(std.testing.allocator, .{ .signature = 3, .bytes = "abc" });
    const loaded = try cache.port().load(std.testing.allocator);
    try std.testing.expectEqualStrings("abc", loaded.bytes.?);
    const hit = try cache.port().recordHit();
    try std.testing.expectEqual(@as(usize, 1), hit.hits);
    try std.testing.expectEqual(@as(usize, 1), cache.store_calls);
}
