const std = @import("std");
const diagnostics_cache = @import("diagnostics_cache.zig");

const DiagnosticsCache = diagnostics_cache.DiagnosticsCache;

fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    return threaded.io();
}

fn parseObject(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

fn snapshotDiagnosticsWithAllocator(allocator: std.mem.Allocator) !void {
    const first =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/a.zig","diagnostics":[]}}
    ;
    const second =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/b.zig","diagnostics":[]}}
    ;
    var cache = DiagnosticsCache.init(allocator, testIo(), DiagnosticsCache.default_max_bytes);
    defer cache.deinit();

    const parsed_first = try parseObject(std.testing.allocator, first);
    defer parsed_first.deinit();
    try cache.storeNotification(parsed_first.value.object, first);

    const parsed_second = try parseObject(std.testing.allocator, second);
    defer parsed_second.deinit();
    try cache.storeNotification(parsed_second.value.object, second);

    const snapshot = try cache.snapshot(allocator);
    defer {
        for (snapshot) |item| allocator.free(item);
        allocator.free(snapshot);
    }
}

test "DiagnosticsCache bounds retained diagnostics" {
    const alloc = std.testing.allocator;
    const first =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/a.zig","diagnostics":[]}}
    ;
    const second =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/b.zig","diagnostics":[]}}
    ;
    var cache = DiagnosticsCache.init(alloc, testIo(), first.len + 8);
    defer cache.deinit();

    const parsed_first = try parseObject(alloc, first);
    defer parsed_first.deinit();
    try cache.storeNotification(parsed_first.value.object, first);
    try std.testing.expectEqual(@as(usize, 1), cache.status().files);
    try std.testing.expectEqual(first.len, cache.status().retained_bytes);

    const parsed_second = try parseObject(alloc, second);
    defer parsed_second.deinit();
    try cache.storeNotification(parsed_second.value.object, second);
    const evicted_status = cache.status();
    try std.testing.expectEqual(@as(usize, 1), evicted_status.files);
    try std.testing.expectEqual(second.len, evicted_status.retained_bytes);
    try std.testing.expectEqual(@as(usize, 1), evicted_status.evicted_files);
    try std.testing.expectEqual(first.len, evicted_status.evicted_bytes);
    try std.testing.expect((try cache.get(alloc, "file:///tmp/a.zig")) == null);
    const stored_second = (try cache.get(alloc, "file:///tmp/b.zig")) orelse return error.TestUnexpectedResult;
    defer alloc.free(stored_second);
    try std.testing.expectEqualStrings(second, stored_second);

    cache.setMaxBytes(second.len - 1);
    try cache.storeNotification(parsed_second.value.object, second);
    const oversized_status = cache.status();
    try std.testing.expectEqual(@as(usize, 0), oversized_status.files);
    try std.testing.expectEqual(@as(usize, 0), oversized_status.retained_bytes);
    try std.testing.expectEqual(@as(usize, 1), oversized_status.dropped_oversized);
}

test "oversized diagnostics do not clear unrelated cached diagnostics" {
    const alloc = std.testing.allocator;
    const first =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/a.zig","diagnostics":[]}}
    ;
    const oversized =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/b.zig","diagnostics":[{"message":"this notification is intentionally too large for the cache budget"}]}}
    ;
    var cache = DiagnosticsCache.init(alloc, testIo(), first.len + 4);
    defer cache.deinit();

    const parsed_first = try parseObject(alloc, first);
    defer parsed_first.deinit();
    try cache.storeNotification(parsed_first.value.object, first);

    const parsed_oversized = try parseObject(alloc, oversized);
    defer parsed_oversized.deinit();
    try cache.storeNotification(parsed_oversized.value.object, oversized);

    const status = cache.status();
    try std.testing.expectEqual(@as(usize, 1), status.files);
    try std.testing.expectEqual(first.len, status.retained_bytes);
    try std.testing.expectEqual(@as(usize, 1), status.dropped_oversized);
    const stored_first = (try cache.get(alloc, "file:///tmp/a.zig")) orelse return error.TestUnexpectedResult;
    defer alloc.free(stored_first);
    try std.testing.expectEqualStrings(first, stored_first);
    try std.testing.expect((try cache.get(alloc, "file:///tmp/b.zig")) == null);
}

test "diagnostics snapshot is ordered by update sequence" {
    const alloc = std.testing.allocator;
    const first =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/b.zig","diagnostics":[]}}
    ;
    const second =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/a.zig","diagnostics":[]}}
    ;
    var cache = DiagnosticsCache.init(alloc, testIo(), DiagnosticsCache.default_max_bytes);
    defer cache.deinit();

    const parsed_first = try parseObject(alloc, first);
    defer parsed_first.deinit();
    try cache.storeNotification(parsed_first.value.object, first);

    const parsed_second = try parseObject(alloc, second);
    defer parsed_second.deinit();
    try cache.storeNotification(parsed_second.value.object, second);

    const snapshot = try cache.snapshot(alloc);
    defer {
        for (snapshot) |item| alloc.free(item);
        alloc.free(snapshot);
    }
    try std.testing.expectEqual(@as(usize, 2), snapshot.len);
    try std.testing.expectEqualStrings(first, snapshot[0]);
    try std.testing.expectEqualStrings(second, snapshot[1]);
}

test "diagnostics snapshot cleans cloned values on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, snapshotDiagnosticsWithAllocator, .{});
}
