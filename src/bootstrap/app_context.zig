const std = @import("std");

const app_context = @import("../app/context.zig");
const runtime_mod = @import("../runtime.zig");

pub const RuntimeFieldConcern = enum {
    bootstrap,
    app_context,
    infra_state,
    counter,
    cache_state,
};

pub const RuntimeFieldRecord = struct {
    name: []const u8,
    concern: RuntimeFieldConcern,
    migration_note: []const u8,
};

pub const runtime_field_inventory = [_]RuntimeFieldRecord{
    .{ .name = "allocator", .concern = .bootstrap, .migration_note = "owned by process bootstrap; app use cases receive allocator parameters explicitly" },
    .{ .name = "io", .concern = .bootstrap, .migration_note = "owned by startup and concrete infra adapters, not app use cases" },
    .{ .name = "logger", .concern = .bootstrap, .migration_note = "startup/infra logging concern; app code uses observability ports" },
    .{ .name = "config", .concern = .app_context, .migration_note = "tool paths and timeouts project into app context; transport host/port stay bootstrap-only" },
    .{ .name = "workspace", .concern = .app_context, .migration_note = "workspace roots project into app context; concrete workspace IO moves behind WorkspaceStore" },
    .{ .name = "zls_process_slot", .concern = .bootstrap, .migration_note = "startup lifecycle slot used by runtime compatibility object" },
    .{ .name = "lsp_client_slot", .concern = .bootstrap, .migration_note = "startup lifecycle slot used by runtime compatibility object" },
    .{ .name = "doc_state_slot", .concern = .bootstrap, .migration_note = "startup lifecycle slot used by runtime compatibility object" },
    .{ .name = "zls_process", .concern = .infra_state, .migration_note = "concrete ZLS process state; future use cases should depend on ZlsGateway" },
    .{ .name = "lsp_client", .concern = .infra_state, .migration_note = "concrete LSP client; future use cases should depend on ZlsGateway" },
    .{ .name = "doc_state", .concern = .infra_state, .migration_note = "concrete document sync state; future use cases should depend on ZlsGateway" },
    .{ .name = "zls_status", .concern = .app_context, .migration_note = "read-only status projects into app context for migrated ZLS-aware slices" },
    .{ .name = "zls_initialize_response", .concern = .infra_state, .migration_note = "owned runtime response buffer; app context receives only borrowed read-only status" },
    .{ .name = "zls_last_failure", .concern = .app_context, .migration_note = "read-only failure status projects into app context" },
    .{ .name = "zls_restart_attempts", .concern = .counter, .migration_note = "runtime counter visible through app ZLS status snapshot" },
    .{ .name = "command_calls", .concern = .counter, .migration_note = "legacy counter bridge; app code should prefer ObservabilitySink events" },
    .{ .name = "zls_requests", .concern = .counter, .migration_note = "legacy counter bridge; app code should prefer ZlsGateway and ObservabilitySink events" },
    .{ .name = "tool_errors", .concern = .counter, .migration_note = "legacy counter bridge retained for public metrics compatibility" },
    .{ .name = "backend_probe_cache", .concern = .cache_state, .migration_note = "legacy optional backend cache; app context exposes cache status only" },
    .{ .name = "analysis_cache", .concern = .cache_state, .migration_note = "legacy static-analysis cache; future static use cases need a typed cache port" },
    .{ .name = "semantic_index_cache", .concern = .cache_state, .migration_note = "legacy semantic-index cache; future static use cases need a typed cache port" },
    .{ .name = "observability", .concern = .infra_state, .migration_note = "concrete metrics state; migrated code should use ObservabilitySink" },
    .{ .name = "runtime_ux", .concern = .bootstrap, .migration_note = "server task/job state remains runtime/bootstrap compatibility state" },
    .{ .name = "temp_counter", .concern = .infra_state, .migration_note = "legacy temporary id state; migrated code should use ClockAndIds" },
};

pub fn runtimeFieldConcern(name: []const u8) ?RuntimeFieldConcern {
    for (runtime_field_inventory) |record| {
        if (std.mem.eql(u8, record.name, name)) return record.concern;
    }
    return null;
}

pub fn fromRuntime(runtime: *runtime_mod.App, port_bindings: app_context.PortSet) app_context.Context {
    return .{
        .workspace = .{
            .root = runtime.workspace.root,
            .cache_root = runtime.workspace.cache_root,
        },
        .tool_paths = .{
            .zig = runtime.config.zig_path,
            .zls = runtime.config.zls_path,
            .zlint = runtime.config.zlint_path,
            .zwanzig = runtime.config.zwanzig_path,
            .zflame = runtime.config.zflame_path,
            .diff_folded = runtime.config.diff_folded_path,
        },
        .timeouts = .{
            .command_ms = runtime.config.timeout_ms,
            .zls_ms = runtime.config.zls_timeout_ms,
        },
        .zls_state = .{
            .status = runtime.zls_status,
            .initialize_response = runtime.zls_initialize_response,
            .last_failure = runtime.zls_last_failure,
            .restart_attempts = runtime.zls_restart_attempts,
        },
        .ports = port_bindings,
        .counters = .{
            .command_calls = &runtime.command_calls,
            .zls_requests = &runtime.zls_requests,
            .tool_errors = &runtime.tool_errors,
        },
        .caches = .{
            .backend_probe = .{
                .zig = runtime.backend_probe_cache.zig != null,
                .zls = runtime.backend_probe_cache.zls != null,
                .zlint = runtime.backend_probe_cache.zlint != null,
                .zwanzig = runtime.backend_probe_cache.zwanzig != null,
                .zflame = runtime.backend_probe_cache.zflame != null,
                .diff_folded = runtime.backend_probe_cache.diff_folded != null,
            },
            .analysis = .{
                .cached = runtime.analysis_cache.index_json != null,
                .signature = runtime.analysis_cache.signature,
                .hits = runtime.analysis_cache.hits,
                .refreshes = runtime.analysis_cache.refreshes,
            },
            .semantic_index = .{
                .cached = runtime.semantic_index_cache.index_json != null,
                .signature = runtime.semantic_index_cache.signature,
                .hits = runtime.semantic_index_cache.hits,
                .refreshes = runtime.semantic_index_cache.refreshes,
            },
        },
    };
}

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
            .cache_root = "/workspace/.zigar-cache",
        },
        .zls_status = "connected",
        .zls_last_failure = "previous",
        .zls_restart_attempts = 2,
        .command_calls = 3,
        .zls_requests = 4,
        .tool_errors = 5,
        .analysis_cache = .{ .signature = 10, .index_json = analysis_json[0..], .hits = 11, .refreshes = 12 },
        .semantic_index_cache = .{ .signature = 20, .index_json = semantic_json[0..], .hits = 21, .refreshes = 22 },
    };

    const ctx = fromRuntime(&runtime, .{});
    try std.testing.expectEqualStrings("/workspace", ctx.workspace.root);
    try std.testing.expectEqualStrings("/workspace/.zigar-cache", ctx.workspace.cache_root);
    try std.testing.expectEqualStrings("/bin/zig", ctx.tool_paths.zig);
    try std.testing.expectEqualStrings("/bin/zflame", ctx.tool_paths.zflame);
    try std.testing.expectEqual(@as(i64, 12_000), ctx.timeouts.command_ms);
    try std.testing.expect(ctx.zls_state.connected());
    try std.testing.expectEqual(@as(usize, 2), ctx.zls_state.restart_attempts);
    try std.testing.expect(ctx.caches.analysis.cached);
    try std.testing.expectEqual(@as(usize, 11), ctx.caches.analysis.hits);

    ctx.counters.incrementCommandCalls();
    try std.testing.expectEqual(@as(usize, 4), runtime.command_calls);
}
