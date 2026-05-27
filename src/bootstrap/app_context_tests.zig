const std = @import("std");
const runtime_mod = @import("runtime_state.zig");
const subject = @import("app_context.zig");
const RuntimeFieldConcern = subject.RuntimeFieldConcern;
const RuntimeFieldRecord = subject.RuntimeFieldRecord;
const runtime_field_inventory = subject.runtime_field_inventory;
const runtimeFieldConcern = subject.runtimeFieldConcern;
const fromRuntime = subject.fromRuntime;

test "runtime field inventory covers current App fields" {
    const fields = @typeInfo(runtime_mod.App).@"struct".fields;
    try std.testing.expectEqual(fields.len, runtime_field_inventory.len);

    inline for (fields) |field| {
        try std.testing.expect(runtimeFieldConcern(field.name) != null);
    }
    for (runtime_field_inventory) |record| {
        var found = false;
        inline for (fields) |field| {
            if (std.mem.eql(u8, record.name, field.name)) found = true;
        }
        try std.testing.expect(found);
        try std.testing.expect(record.migration_note.len > 0);
    }
    try std.testing.expect(runtimeFieldConcern("not_a_runtime_field") == null);
}
test "runtime bridge projects app context without changing runtime ownership" {
    var analysis_json = [_]u8{ '{', '}' };
    var semantic_json = [_]u8{ '[', ']' };
    var runtime = runtime_mod.App{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .config = .{
            .workspace = "/workspace",
            .zig_path = "/bin/zig",
            .zls_path = "/bin/zls",
            .zlint_path = "/bin/zlint",
            .zwanzig_path = "/bin/zwanzig",
            .zflame_path = "/bin/zflame",
            .diff_folded_path = "/bin/diff-folded",
            .timeout_ms = 12_000,
            .zls_timeout_ms = 34_000,
        },
        .workspace = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .root = "/workspace",
            .cache_root = "/workspace/.zigars-cache",
        },
        .zls = .{
            .status = "connected",
            .last_failure = "previous",
            .restart_attempts = 2,
        },
        .command_calls = 3,
        .zls_requests = 4,
        .tool_errors = 5,
        .backend_probe_cache = .{
            .zig = .{ .ok = true, .status = "ok", .resolution = "ready" },
        },
        .analysis_cache = .{ .signature = 10, .index_json = analysis_json[0..], .hits = 11, .refreshes = 12 },
        .semantic_index_cache = .{ .signature = 20, .index_json = semantic_json[0..], .hits = 21, .refreshes = 22 },
    };

    const ctx = fromRuntime(&runtime, .{});
    try std.testing.expectEqualStrings("/workspace", ctx.workspace.root);
    try std.testing.expectEqualStrings("/workspace/.zigars-cache", ctx.workspace.cache_root);
    try std.testing.expectEqualStrings("127.0.0.1", ctx.workspace.host);
    try std.testing.expectEqual(@as(u16, 8080), ctx.workspace.port);
    try std.testing.expectEqualStrings("/bin/zig", ctx.tool_paths.zig);
    try std.testing.expectEqualStrings("/bin/zflame", ctx.tool_paths.zflame);
    try std.testing.expectEqual(@as(i64, 12_000), ctx.timeouts.command_ms);
    try std.testing.expect(ctx.zls_state.connected());
    try std.testing.expectEqual(@as(usize, 2), ctx.zls_state.restart_attempts);
    try std.testing.expect(ctx.caches.analysis.cached);
    try std.testing.expectEqual(@as(usize, 11), ctx.caches.analysis.hits);
    try std.testing.expect(ctx.caches.backend_probe.zig);
    try std.testing.expect(ctx.trust_probe_cache.zig.probed);
    try std.testing.expect(ctx.trust_probe_cache.zig.ok.?);
    try std.testing.expectEqualStrings("ok", ctx.trust_probe_cache.zig.status);
    try std.testing.expectEqualStrings("ready", ctx.trust_probe_cache.zig.resolution);

    ctx.counters.incrementCommandCalls();
    try std.testing.expectEqual(@as(usize, 4), runtime.command_calls);
}
