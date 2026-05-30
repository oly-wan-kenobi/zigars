//! Bounded in-memory cache of raw `textDocument/publishDiagnostics` notifications
//! keyed by file URI. Retains the most recently received payload per file up to
//! a configurable byte budget, evicting oldest entries (by insertion sequence)
//! when the budget is exceeded. Oversized single messages are dropped without
//! evicting existing entries. All operations are thread-safe.
const std = @import("std");
const Mutex = @import("../process/sync.zig").Mutex;

/// One cached diagnostic payload plus the sequence used for stable snapshots.
const DiagnosticEntry = struct {
    value: []const u8,
    sequence: u64,
};

/// Owned diagnostic payload and ordering metadata returned to callers.
const SnapshotEntry = struct {
    value: []const u8,
    sequence: u64,
};

/// Thread-safe bounded cache of raw publishDiagnostics notifications by URI.
pub const DiagnosticsCache = struct {
    /// Default retained byte budget for diagnostics JSON.
    pub const default_max_bytes: usize = 16 * 1024 * 1024;

    allocator: std.mem.Allocator,
    io: std.Io,
    entries: std.StringHashMapUnmanaged(DiagnosticEntry) = .empty,
    mutex: Mutex,
    retained_bytes: usize = 0,
    max_bytes: usize,
    sequence: u64 = 0,
    evicted_files: usize = 0,
    evicted_bytes: usize = 0,
    dropped_oversized: usize = 0,

    /// Snapshot of cache size and eviction/drop counters.
    pub const Status = struct {
        files: usize,
        retained_bytes: usize,
        max_bytes: usize,
        evicted_files: usize,
        evicted_bytes: usize,
        dropped_oversized: usize,
    };

    /// Creates an empty cache and clamps the byte budget to at least one.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, max_bytes: usize) DiagnosticsCache {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = Mutex.init(io),
            .max_bytes = @max(1, max_bytes),
        };
    }

    /// Frees all retained notification payloads and map keys.
    pub fn deinit(self: *DiagnosticsCache) void {
        // Only release owned state here to avoid invalidating borrowed data.
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }
        self.entries.deinit(self.allocator);
        self.entries = .empty;
        self.retained_bytes = 0;
    }

    /// Shrink or grow the byte budget at runtime, evicting immediately if needed.
    pub fn setMaxBytes(self: *DiagnosticsCache, max_bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.max_bytes = @max(1, max_bytes);
        self.evictUntilFitsLocked(0);
    }

    /// Store a raw publishDiagnostics payload for the URI found in `obj.params.uri`.
    /// Replaces any existing entry for the same URI and evicts the oldest entry
    /// if the budget is exceeded. A payload larger than max_bytes alone is dropped
    /// (dropped_oversized is incremented) without displacing existing entries.
    pub fn storeNotification(self: *DiagnosticsCache, obj: std.json.ObjectMap, data: []const u8) !void {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const params = switch (obj.get("params") orelse return) {
            .object => |o| o,
            else => return,
        };
        const uri = switch (params.get("uri") orelse return) {
            .string => |s| s,
            else => return,
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.fetchRemove(uri)) |old| self.freeEntryLocked(old.key, old.value);
        if (data.len > self.max_bytes) {
            self.dropped_oversized += 1;
            return;
        }

        const key = try self.allocator.dupe(u8, uri);
        var key_owned = true;
        defer if (key_owned) self.allocator.free(key);
        const value = try self.allocator.dupe(u8, data);
        var value_owned = true;
        defer if (value_owned) self.allocator.free(value);

        self.evictUntilFitsLocked(value.len);
        self.sequence +%= 1;
        try self.entries.put(self.allocator, key, .{
            .value = value,
            .sequence = self.sequence,
        });
        key_owned = false;
        value_owned = false;
        self.retained_bytes += value.len;
    }

    /// Returns an allocator-owned copy of the stored payload for `uri`, or null if absent.
    pub fn get(self: *DiagnosticsCache, allocator: std.mem.Allocator, uri: []const u8) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stored = self.entries.get(uri) orelse return null;
        return try allocator.dupe(u8, stored.value);
    }

    /// Return all retained payloads sorted by insertion sequence (oldest first).
    /// The outer slice and each inner slice are allocator-owned; the caller frees both.
    pub fn snapshot(self: *DiagnosticsCache, allocator: std.mem.Allocator) ![]const []const u8 {
        // Keep this logic centralized so callers observe one consistent behavior path.
        self.mutex.lock();
        defer self.mutex.unlock();

        var list: std.ArrayList(SnapshotEntry) = .empty;
        var list_owned = true;
        defer if (list_owned) {
            for (list.items) |item| allocator.free(item.value);
            list.deinit(allocator);
        };
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const value = try allocator.dupe(u8, entry.value_ptr.value);
            var value_owned = true;
            defer if (value_owned) allocator.free(value);
            try list.append(allocator, .{
                .value = value,
                .sequence = entry.value_ptr.sequence,
            });
            value_owned = false;
        }
        std.mem.sort(SnapshotEntry, list.items, {}, struct {
            fn lessThan(_: void, a: SnapshotEntry, b: SnapshotEntry) bool {
                return a.sequence < b.sequence;
            }
        }.lessThan);

        const result = try allocator.alloc([]const u8, list.items.len);
        for (list.items, 0..) |item, index| result[index] = item.value;
        list_owned = false;
        list.deinit(allocator);
        return result;
    }

    /// Return a snapshot of cache size and eviction counters; no allocation.
    pub fn status(self: *DiagnosticsCache) Status {
        // Keep this logic centralized so callers observe one consistent behavior path.
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .files = self.entries.count(),
            .retained_bytes = self.retained_bytes,
            .max_bytes = self.max_bytes,
            .evicted_files = self.evicted_files,
            .evicted_bytes = self.evicted_bytes,
            .dropped_oversized = self.dropped_oversized,
        };
    }

    /// Subtract `bytes` from retained_bytes, clamping to zero on underflow.
    /// Underflow is possible when entries are removed outside the normal store path
    /// (e.g. in tests that manipulate entries directly).
    fn subtractBytesLocked(self: *DiagnosticsCache, bytes: usize) void {
        if (bytes <= self.retained_bytes) {
            self.retained_bytes -= bytes;
        } else {
            self.retained_bytes = 0;
        }
    }

    /// Remove oldest entries until there is room for `incoming_bytes`.
    /// Uses saturating subtraction so a very large `incoming_bytes` saturates to 0.
    fn evictUntilFitsLocked(self: *DiagnosticsCache, incoming_bytes: usize) void {
        while (self.retained_bytes > self.max_bytes -| incoming_bytes) {
            if (!self.evictOldestLocked()) return;
        }
    }

    /// Remove the entry with the smallest sequence number. Returns false when the cache is empty.
    /// Linear scan is acceptable because the expected file count is small (< hundreds).
    fn evictOldestLocked(self: *DiagnosticsCache) bool {
        // Keep this logic centralized so callers observe one consistent behavior path.
        var oldest_key: ?[]const u8 = null;
        var oldest_sequence: u64 = 0;

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (oldest_key == null or entry.value_ptr.sequence < oldest_sequence) {
                oldest_key = entry.key_ptr.*;
                oldest_sequence = entry.value_ptr.sequence;
            }
        }

        const key = oldest_key orelse return false;
        const removed = self.entries.fetchRemove(key) orelse return false;
        self.evicted_files += 1;
        self.evicted_bytes += removed.value.value.len;
        self.freeEntryLocked(removed.key, removed.value);
        return true;
    }

    /// Free the key and value slices belonging to `entry` and update retained_bytes.
    /// Caller must hold the mutex.
    fn freeEntryLocked(self: *DiagnosticsCache, key: []const u8, entry: DiagnosticEntry) void {
        self.subtractBytesLocked(entry.value.len);
        self.allocator.free(key);
        self.allocator.free(entry.value);
    }
};

// Unit tests inline with the module pin the byte-accounting and clamping behavior.

fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    return threaded.io();
}

/// Parses object from caller-owned input and reports malformed data without taking ownership.
fn parseObject(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

test "diagnostics cache clamps stale retained byte accounting when freeing" {
    const alloc = std.testing.allocator;
    const data =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/a.zig","diagnostics":[]}}
    ;
    var cache = DiagnosticsCache.init(alloc, testIo(), DiagnosticsCache.default_max_bytes);
    defer cache.deinit();

    const parsed = try parseObject(alloc, data);
    defer parsed.deinit();
    try cache.storeNotification(parsed.value.object, data);

    const removed = cache.entries.fetchRemove("file:///tmp/a.zig") orelse return error.TestUnexpectedResult;
    cache.retained_bytes = 0;
    cache.freeEntryLocked(removed.key, removed.value);
    try std.testing.expectEqual(@as(usize, 0), cache.retained_bytes);
}
