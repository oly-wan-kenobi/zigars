const std = @import("std");
const zigar = @import("zigar");

const core = @import("shared_core.zig");

const App = core.App;
const DocumentState = zigar.document_state.DocumentState;
const backendProbeCacheValue = core.backendProbeCacheValue;

pub fn metricsValue(a: *App, allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "command_calls", .{ .integer = @intCast(a.command_calls) });
    try obj.put(allocator, "zls_requests", .{ .integer = @intCast(a.zls_requests) });
    try obj.put(allocator, "tool_errors", .{ .integer = @intCast(a.tool_errors) });
    try obj.put(allocator, "zls_status", .{ .string = a.zls_status });
    try obj.put(allocator, "zls", try zlsStatusValue(allocator, a));
    try obj.put(allocator, "zls_running", .{ .bool = if (a.lsp_client) |client| client.isRunning() else false });
    try obj.put(allocator, "zls_restart_attempts", .{ .integer = @intCast(a.zls_restart_attempts) });
    if (a.zls_last_failure) |failure| {
        try obj.put(allocator, "zls_last_failure", .{ .string = failure });
    } else if (a.lsp_client) |client| {
        if (try client.lastError(allocator)) |err| {
            try obj.put(allocator, "zls_last_failure", .{ .string = err });
        } else {
            try obj.put(allocator, "zls_last_failure", .null);
        }
    } else {
        try obj.put(allocator, "zls_last_failure", .null);
    }
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "backend_probe_cache", try backendProbeCacheValue(allocator, a.backend_probe_cache));
    try obj.put(allocator, "analysis_cache", try analysisCacheStatusValue(allocator, a));
    return .{ .object = obj };
}

pub fn analysisCacheStatusValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "present", .{ .bool = a.analysis_cache.index_json != null });
    try obj.put(allocator, "signature", .{ .string = try std.fmt.allocPrint(allocator, "{x:0>16}", .{a.analysis_cache.signature}) });
    try obj.put(allocator, "hits", .{ .integer = @intCast(a.analysis_cache.hits) });
    try obj.put(allocator, "refreshes", .{ .integer = @intCast(a.analysis_cache.refreshes) });
    if (a.analysis_cache.index_json) |bytes| {
        try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes.len) });
    } else {
        try obj.put(allocator, "bytes", .{ .integer = 0 });
    }
    return .{ .object = obj };
}

pub fn zlsStatusValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    const running = if (a.lsp_client) |client| client.isRunning() else false;
    try obj.put(allocator, "status", .{ .string = a.zls_status });
    try obj.put(allocator, "configured_path", .{ .string = a.config.zls_path });
    try obj.put(allocator, "request_timeout_ms", .{ .integer = a.config.zls_timeout_ms });
    try obj.put(allocator, "restart_attempts", .{ .integer = @intCast(a.zls_restart_attempts) });
    try obj.put(allocator, "running", .{ .bool = running });
    try obj.put(allocator, "document_sync", .{ .bool = a.doc_state != null });
    if (a.doc_state) |doc_state| {
        try obj.put(allocator, "document_state", try zlsDocumentStateSummaryValue(allocator, doc_state.summary()));
    } else {
        try obj.put(allocator, "document_state", .null);
    }
    if (a.lsp_client) |client| {
        const diagnostics = client.diagnosticsStatus();
        try obj.put(allocator, "diagnostics_cached_files", .{ .integer = @intCast(diagnostics.files) });
        try obj.put(allocator, "diagnostics_retained_bytes", .{ .integer = @intCast(diagnostics.retained_bytes) });
        try obj.put(allocator, "max_diagnostics_bytes", .{ .integer = @intCast(diagnostics.max_bytes) });
        try obj.put(allocator, "diagnostics_evicted_files", .{ .integer = @intCast(diagnostics.evicted_files) });
        try obj.put(allocator, "diagnostics_evicted_bytes", .{ .integer = @intCast(diagnostics.evicted_bytes) });
        try obj.put(allocator, "diagnostics_dropped_oversized", .{ .integer = @intCast(diagnostics.dropped_oversized) });
    }
    try obj.put(allocator, "initialize_response_present", .{ .bool = a.zls_initialize_response != null });
    if (a.zls_last_failure) |failure| {
        try obj.put(allocator, "last_failure", .{ .string = failure });
    } else if (a.lsp_client) |client| {
        if (try client.lastError(allocator)) |err| {
            try obj.put(allocator, "last_failure", .{ .string = err });
        } else {
            try obj.put(allocator, "last_failure", .null);
        }
    } else {
        try obj.put(allocator, "last_failure", .null);
    }
    try obj.put(allocator, "resolution", .{ .string = if (running)
        "ZLS-backed tools are available"
    else
        "confirm --zls-path points to a compatible ZLS binary; command-backed Zig tools remain available" });
    return .{ .object = obj };
}

pub fn zlsDocumentStateSummaryValue(allocator: std.mem.Allocator, summary: DocumentState.Summary) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "open_documents", .{ .integer = @intCast(summary.open_documents) });
    try obj.put(allocator, "dirty_documents", .{ .integer = @intCast(summary.dirty_documents) });
    try obj.put(allocator, "retained_content_bytes", .{ .integer = @intCast(summary.retained_content_bytes) });
    try obj.put(allocator, "max_document_bytes", .{ .integer = @intCast(summary.max_document_bytes) });
    try obj.put(allocator, "max_retained_content_bytes", .{ .integer = @intCast(summary.max_retained_content_bytes) });
    try obj.put(allocator, "max_open_documents", .{ .integer = @intCast(summary.max_open_documents) });
    try obj.put(allocator, "last_reopen", try zlsReopenSummaryValue(allocator, summary.last_reopen));
    return .{ .object = obj };
}

fn zlsReopenSummaryValue(allocator: std.mem.Allocator, summary: DocumentState.ReopenSummary) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "attempted", .{ .integer = @intCast(summary.attempted) });
    try obj.put(allocator, "succeeded", .{ .integer = @intCast(summary.succeeded) });
    try obj.put(allocator, "skipped", .{ .integer = @intCast(summary.skipped) });
    try obj.put(allocator, "failed", .{ .integer = @intCast(summary.failed) });
    return .{ .object = obj };
}

test "ZLS document state summary value exposes aggregate replay state" {
    const allocator = std.testing.allocator;
    var value = try zlsDocumentStateSummaryValue(allocator, .{
        .open_documents = 3,
        .dirty_documents = 2,
        .retained_content_bytes = 64,
        .max_document_bytes = 1024,
        .max_retained_content_bytes = 4096,
        .max_open_documents = 16,
        .last_reopen = .{ .attempted = 3, .succeeded = 2, .skipped = 0, .failed = 1 },
    });
    defer {
        var reopen = value.object.get("last_reopen").?.object;
        reopen.deinit(allocator);
        value.object.deinit(allocator);
    }

    const obj = value.object;
    try std.testing.expectEqual(@as(i64, 3), obj.get("open_documents").?.integer);
    try std.testing.expectEqual(@as(i64, 2), obj.get("dirty_documents").?.integer);
    try std.testing.expectEqual(@as(i64, 64), obj.get("retained_content_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 16), obj.get("max_open_documents").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("last_reopen").?.object.get("failed").?.integer);
}
