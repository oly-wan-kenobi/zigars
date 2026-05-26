const std = @import("std");
const Mutex = @import("../process/sync.zig").Mutex;

const DiagnosticEntry = struct {
    value: []const u8,
    sequence: u64,
};

const SnapshotEntry = struct {
    value: []const u8,
    sequence: u64,
};

pub const DiagnosticsCache = struct {
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

    pub const Status = struct {
        files: usize,
        retained_bytes: usize,
        max_bytes: usize,
        evicted_files: usize,
        evicted_bytes: usize,
        dropped_oversized: usize,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, max_bytes: usize) DiagnosticsCache {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = Mutex.init(io),
            .max_bytes = @max(1, max_bytes),
        };
    }

    pub fn deinit(self: *DiagnosticsCache) void {
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

    pub fn setMaxBytes(self: *DiagnosticsCache, max_bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.max_bytes = @max(1, max_bytes);
        self.evictUntilFitsLocked(0);
    }

    pub fn storeNotification(self: *DiagnosticsCache, obj: std.json.ObjectMap, data: []const u8) !void {
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

    pub fn get(self: *DiagnosticsCache, allocator: std.mem.Allocator, uri: []const u8) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stored = self.entries.get(uri) orelse return null;
        return try allocator.dupe(u8, stored.value);
    }

    pub fn snapshot(self: *DiagnosticsCache, allocator: std.mem.Allocator) ![]const []const u8 {
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

    pub fn status(self: *DiagnosticsCache) Status {
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

    fn subtractBytesLocked(self: *DiagnosticsCache, bytes: usize) void {
        if (bytes <= self.retained_bytes) {
            self.retained_bytes -= bytes;
        } else {
            self.retained_bytes = 0;
        }
    }

    fn evictUntilFitsLocked(self: *DiagnosticsCache, incoming_bytes: usize) void {
        while (self.retained_bytes > self.max_bytes -| incoming_bytes) {
            if (!self.evictOldestLocked()) return;
        }
    }

    fn evictOldestLocked(self: *DiagnosticsCache) bool {
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

    fn freeEntryLocked(self: *DiagnosticsCache, key: []const u8, entry: DiagnosticEntry) void {
        self.subtractBytesLocked(entry.value.len);
        self.allocator.free(key);
        self.allocator.free(entry.value);
    }
};

fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    return threaded.io();
}

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
