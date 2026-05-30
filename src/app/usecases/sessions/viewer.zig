//! Read-only shared session inspection use case.
const std = @import("std");

const app_context = @import("../../context.zig");
const envelope = @import("envelope.zig");

/// Request for a workspace-local persistent session view.
pub const ViewRequest = struct {
    kind: []const u8,
    id: []const u8,
};

/// Builds the public `zigars_session_view` result: it wraps `envelope.view` and
/// adds read-only/lifecycle-scope metadata plus stated confidence and
/// limitations. Inspect-only by contract; resume/close/cancel/cleanup and any
/// source mutation stay owned by each workflow-specific tool. The inner session
/// value is embedded directly, so the whole result is owned by `allocator`.
pub fn viewValue(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    request: ViewRequest,
) !std.json.Value {
    const session = try envelope.view(allocator, context.workspace_store, request.kind, request.id, "sessions.view");
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigars_session_view" });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "read_only", .{ .bool = true });
    try obj.put(allocator, "lifecycle_scope", .{ .string = "inspect_only" });
    try obj.put(allocator, "session_kind", .{ .string = request.kind });
    try obj.put(allocator, "session_id", .{ .string = request.id });
    try obj.put(allocator, "session_path", .{ .string = session.object.get("path").?.string });
    try obj.put(allocator, "workspace", .{ .string = context.workspace.root });
    try obj.put(allocator, "schema_version", .{ .integer = envelope.schema_version });
    try obj.put(allocator, "record_count", session.object.get("record_count").?);
    try obj.put(allocator, "returned_record_count", session.object.get("returned_record_count").?);
    try obj.put(allocator, "truncated", session.object.get("truncated").?);
    try obj.put(allocator, "malformed_records", session.object.get("malformed_records").?);
    try obj.put(allocator, "unsupported_versions", session.object.get("unsupported_versions").?);
    try obj.put(allocator, "session", session);
    try obj.put(allocator, "evidence_source", .{ .string = "workspace_session_jsonl" });
    try obj.put(allocator, "confidence", .{ .string = "high" });
    try obj.put(allocator, "limitations", .{ .string = "This tool inspects shared session JSONL only; resume, close, cancel, cleanup, and source mutation remain owned by each workflow-specific tool." });
    try obj.put(allocator, "resolution", .{ .string = "Use the workflow-specific tool for semantic lifecycle actions such as resume, close, cancel, apply, or rollback." });
    return .{ .object = obj };
}

const fakes = @import("../../../testing/fakes/root.zig");

test "public session view reads bounded shared JSONL without lifecycle mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();

    const jsonl =
        \\{"schema_version":1,"id":"gate-1","kind":"bench_regression_gate","status":"failed","workspace_root":"/workspace","created_at":1,"updated_at":1,"preimages":[],"artifacts":[],"events":[],"validation":{"passed":false}}
        \\
    ;
    try workspace.expectRead(.{
        .path = ".zigars-cache/sessions/bench_regression_gate/gate-1.jsonl",
        .max_bytes = envelope.max_session_bytes,
        .provenance = "sessions.view",
    }, jsonl);

    const context = app_context.ArtifactContext{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .workspace_store = workspace.port(),
    };
    const viewed = try viewValue(allocator, context, .{ .kind = "bench_regression_gate", .id = "gate-1" });
    try std.testing.expectEqualStrings("zigars_session_view", viewed.object.get("kind").?.string);
    try std.testing.expectEqualStrings("inspect_only", viewed.object.get("lifecycle_scope").?.string);
    try std.testing.expectEqualStrings("bench_regression_gate", viewed.object.get("session_kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), viewed.object.get("record_count").?.integer);
    try std.testing.expectEqualStrings("failed", viewed.object.get("session").?.object.get("envelope").?.object.get("status").?.string);
    try workspace.verify();
}
