//! In-memory cache for the static-analysis index JSON.  Owned by runtime
//! composition; the Cache facade exposes it through the StaticCache vtable.
//! The signature field lets callers detect stale cache entries without
//! comparing the full JSON payload.
const std = @import("std");

const ports = @import("../../app/ports.zig");

const Allocator = std.mem.Allocator;

/// Shared in-memory analysis-cache state owned by runtime composition.
pub const State = struct {
    signature: u64 = 0,
    index_json: ?[]u8 = null,
    hits: usize = 0,
    refreshes: usize = 0,

    /// Releases any cached JSON bytes and resets counters.
    pub fn deinit(self: *State, allocator: Allocator) void {
        if (self.index_json) |bytes| allocator.free(bytes);
        self.* = .{};
    }
};

/// StaticCache port facade over shared in-memory cache state.
pub const Cache = struct {
    allocator: Allocator,
    state: *State,

    const Self = @This();

    /// Stores the allocator that owns cached bytes.
    /// `state` must outlive this Cache; ownership remains with the caller.
    pub fn init(allocator: Allocator, state: *State) Self {
        return .{ .allocator = allocator, .state = state };
    }

    /// Exposes this cache through the StaticCache vtable.
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

    /// Returns the cached status snapshot for this implementation.
    fn status(ptr: *anyopaque) ports.PortError!ports.StaticCacheStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.currentStatus();
    }

    /// Loads a cached value for this implementation.
    fn load(ptr: *anyopaque, _: Allocator) ports.PortError!ports.StaticCacheLoadResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return .{
            .status = self.currentStatus(),
            .bytes = self.state.index_json,
        };
    }

    /// Stores a cached value for this implementation.
    /// Duplicates `request.bytes` using the Cache's own allocator; frees any
    /// previously cached bytes before replacing them so there is no leak.
    fn store(ptr: *anyopaque, _: Allocator, request: ports.StaticCacheStoreRequest) ports.PortError!ports.StaticCacheStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const bytes = self.allocator.dupe(u8, request.bytes) catch return error.OutOfMemory;
        // Free before assigning; on dupe failure the old bytes are still valid.
        if (self.state.index_json) |old| self.allocator.free(old);
        self.state.index_json = bytes;
        self.state.signature = request.signature;
        self.state.refreshes += 1;
        return self.currentStatus();
    }

    /// Records a cache hit for this implementation.
    fn recordHit(ptr: *anyopaque) ports.PortError!ports.StaticCacheStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.state.hits += 1;
        return self.currentStatus();
    }

    /// Returns the current cache status snapshot.
    fn currentStatus(self: *Self) ports.StaticCacheStatus {
        return cacheStatus(self.state.*);
    }
};

/// Public snapshot of cache hit, miss, and storage counters.
fn cacheStatus(cache: anytype) ports.StaticCacheStatus {
    return .{
        .cached = cache.index_json != null,
        .signature = cache.signature,
        .hits = cache.hits,
        .refreshes = cache.refreshes,
        .bytes_len = if (cache.index_json) |bytes| bytes.len else 0,
    };
}
