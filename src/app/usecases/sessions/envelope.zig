//! Shared persistent session envelope and cache-local JSONL event store.
//! Provides token validation, path construction, JSON envelope building, and
//! bounded append+view helpers. The workspace store port enforces the sandbox;
//! every path written here must also pass the store's sandbox check.
const std = @import("std");

const ports = @import("../../ports.zig");
const support = @import("../usecase_support.zig");

/// Current schema version for persisted session snapshots.
pub const schema_version: i64 = 1;
/// Workspace-relative root used by persistent workflow sessions.
pub const session_root = ".zigars-cache/sessions";
/// Bounded maximum session JSONL bytes read or rewritten by the shared store.
pub const max_session_bytes: usize = 512 * 1024;
/// Bounded maximum JSONL records returned by a session view.
pub const max_records: usize = 128;

/// Shared envelope creation inputs. Optional fields default to empty arrays or
/// objects in the serialized output so the schema stays stable across workflow
/// kinds that do not use every section.
pub const EnvelopeInput = struct {
    id: []const u8,
    kind: []const u8,
    status: []const u8,
    workspace_root: []const u8,
    created_at: i64,
    updated_at: i64,
    preimages: ?std.json.Value = null,
    artifacts: ?std.json.Value = null,
    events: ?std.json.Value = null,
    validation: ?std.json.Value = null,
};

/// Guards a session `kind`/`id` before it becomes a path segment: rejects empty,
/// over-long, "."/".." and any character outside [A-Za-z0-9._-]. This blocks
/// path traversal and separator injection so session files stay under
/// `.zigars-cache/sessions` even before the workspace store re-checks the path.
pub fn validateToken(token: []const u8) !void {
    if (token.len == 0 or token.len > 128) return error.InvalidSessionToken;
    if (std.mem.eql(u8, token, ".") or std.mem.eql(u8, token, "..")) return error.InvalidSessionToken;
    for (token) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return error.InvalidSessionToken,
    };
}

/// Returns `.zigars-cache/sessions/<kind>`.
pub fn kindDir(allocator: std.mem.Allocator, kind: []const u8) ![]u8 {
    try validateToken(kind);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ session_root, kind });
}

/// Returns `.zigars-cache/sessions/<kind>/<id>.jsonl`.
pub fn sessionPath(allocator: std.mem.Allocator, kind: []const u8, id: []const u8) ![]u8 {
    try validateToken(kind);
    try validateToken(id);
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}.jsonl", .{ session_root, kind, id });
}

/// Builds a JSON-native session envelope with the shared required fields.
/// Validates `kind` and `id` tokens before building; allocation failures and
/// invalid tokens propagate. The returned value is owned by `allocator`.
pub fn envelopeValue(allocator: std.mem.Allocator, input: EnvelopeInput) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    try validateToken(input.kind);
    try validateToken(input.id);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "id", .{ .string = input.id });
    try obj.put(allocator, "kind", .{ .string = input.kind });
    try obj.put(allocator, "status", .{ .string = input.status });
    try obj.put(allocator, "workspace_root", .{ .string = input.workspace_root });
    try obj.put(allocator, "created_at", .{ .integer = input.created_at });
    try obj.put(allocator, "updated_at", .{ .integer = input.updated_at });
    try obj.put(allocator, "preimages", input.preimages orelse emptyArray(allocator));
    try obj.put(allocator, "artifacts", input.artifacts orelse emptyArray(allocator));
    try obj.put(allocator, "events", input.events orelse emptyArray(allocator));
    try obj.put(allocator, "validation", input.validation orelse emptyObject());
    return .{ .object = obj };
}

/// Builds a compact `{event, message, at}` session event object.
/// `at_ms` is a Unix epoch millisecond timestamp. Owned by `allocator`.
pub fn eventValue(allocator: std.mem.Allocator, event: []const u8, message: []const u8, at_ms: i64) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "event", .{ .string = event });
    try obj.put(allocator, "message", .{ .string = message });
    try obj.put(allocator, "at", .{ .integer = at_ms });
    return .{ .object = obj };
}

/// Appends one JSON snapshot line to a workspace-local session JSONL file and
/// returns the workspace-relative session path (owned by `allocator`; the caller
/// must free it). The write is implemented as read+rewrite because the workspace
/// store port intentionally exposes whole-file writes only. Fails with
/// DocumentTooLarge when the result would exceed `max_session_bytes`.
pub fn appendSnapshot(
    allocator: std.mem.Allocator,
    store: ports.WorkspaceStore,
    kind: []const u8,
    id: []const u8,
    snapshot: std.json.Value,
    provenance: []const u8,
) ![]u8 {
    const dir = try kindDir(allocator, kind);
    defer allocator.free(dir);
    const path = try sessionPath(allocator, kind, id);
    errdefer allocator.free(path);
    _ = try store.ensureDir(.{ .path = dir, .provenance = provenance });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const existing: ?ports.WorkspaceReadResult = store.read(allocator, .{
        .path = path,
        .max_bytes = max_session_bytes,
        .provenance = provenance,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotFound => null,
        else => return err,
    };
    if (existing) |read| {
        defer read.deinit(allocator);
        if (read.bytes.len >= max_session_bytes) return error.DocumentTooLarge;
        try out.appendSlice(allocator, read.bytes);
        // Force a record boundary if the prior file lacked a trailing newline,
        // so a partially written last line cannot merge with the new snapshot.
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
    }
    try support.serializeValue(allocator, &out, snapshot);
    try out.append(allocator, '\n');
    if (out.items.len > max_session_bytes) return error.DocumentTooLarge;
    _ = try store.write(.{
        .path = path,
        .bytes = out.items,
        .create_parent_dirs = true,
        .replace_existing = true,
        .provenance = provenance,
    });
    return path;
}

/// Reads a session JSONL file into a bounded, inspectable JSON object. Records
/// beyond `max_records` are counted but not returned (`truncated` is set);
/// unparseable lines bump `malformed_records` and rows with a non-matching
/// `schema_version` bump `unsupported_versions`, neither aborting the read. The
/// last valid object is exposed as `envelope` (latest snapshot wins). The whole
/// returned value, including cloned records and `raw_jsonl`, is owned by
/// `allocator`. Read-only: this never writes or mutates session state.
pub fn view(
    allocator: std.mem.Allocator,
    store: ports.WorkspaceStore,
    kind: []const u8,
    id: []const u8,
    provenance: []const u8,
) !std.json.Value {
    const path = try sessionPath(allocator, kind, id);
    const read = try store.read(allocator, .{
        .path = path,
        .max_bytes = max_session_bytes,
        .provenance = provenance,
    });
    defer read.deinit(allocator);

    var records = std.json.Array.init(allocator);
    var last: std.json.Value = .null;
    var malformed: i64 = 0;
    var unsupported: i64 = 0;
    var total: i64 = 0;

    var lines = std.mem.splitScalar(u8, read.bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        total += 1;
        if (records.items.len >= max_records) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            malformed += 1;
            continue;
        };
        defer parsed.deinit();
        if (versionOf(parsed.value)) |version| {
            if (version != schema_version) unsupported += 1;
        } else {
            unsupported += 1;
        }
        const cloned = try support.cloneValue(allocator, parsed.value);
        if (cloned == .object) {
            // Keep an independent copy as the running "envelope" so it can be
            // owned separately from the records array; drop the prior candidate.
            if (last != .null) support.deinitOwnedValue(allocator, last);
            last = try support.cloneValue(allocator, cloned);
        }
        try records.append(cloned);
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "id", .{ .string = id });
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "record_count", .{ .integer = total });
    try obj.put(allocator, "returned_record_count", .{ .integer = @intCast(records.items.len) });
    try obj.put(allocator, "truncated", .{ .bool = total > max_records });
    try obj.put(allocator, "malformed_records", .{ .integer = malformed });
    try obj.put(allocator, "unsupported_versions", .{ .integer = unsupported });
    try obj.put(allocator, "raw_jsonl", .{ .string = try allocator.dupe(u8, read.bytes) });
    try obj.put(allocator, "envelope", last);
    try obj.put(allocator, "records", .{ .array = records });
    return .{ .object = obj };
}

/// Returns a record's `schema_version`, or null when it is absent or not an
/// integer, so the view can flag unsupported or unversioned rows.
fn versionOf(value: std.json.Value) ?i64 {
    if (value != .object) return null;
    const raw = value.object.get("schema_version") orelse return null;
    return switch (raw) {
        .integer => |i| i,
        else => null,
    };
}

/// Returns a freshly allocated empty JSON array for use in envelope optional
/// sections. The array is backed by `allocator` and transfered into the
/// containing object map, which owns it from that point.
fn emptyArray(allocator: std.mem.Allocator) std.json.Value {
    return .{ .array = std.json.Array.init(allocator) };
}

/// Returns an empty JSON object literal (no allocator needed; the map is
/// zero-length and owns no heap memory).
fn emptyObject() std.json.Value {
    return .{ .object = std.json.ObjectMap.empty };
}

const fakes = @import("../../../testing/fakes/root.zig");

test "session path rejects path traversal tokens" {
    try std.testing.expectError(error.InvalidSessionToken, sessionPath(std.testing.allocator, "../bad", "id"));
    try std.testing.expectError(error.InvalidSessionToken, sessionPath(std.testing.allocator, "kind", "../id"));
    const path = try sessionPath(std.testing.allocator, "bench_regression_gate", "session-1");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(".zigars-cache/sessions/bench_regression_gate/session-1.jsonl", path);
}

test "session JSONL append and view are workspace bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();

    var events = std.json.Array.init(scratch);
    try events.append(try eventValue(scratch, "created", "created session", 1));
    const envelope = try envelopeValue(scratch, .{
        .id = "session-1",
        .kind = "bench_regression_gate",
        .status = "created",
        .workspace_root = "/workspace",
        .created_at = 1,
        .updated_at = 1,
        .events = .{ .array = events },
    });
    var serialized: std.ArrayList(u8) = .empty;
    defer serialized.deinit(std.testing.allocator);
    try support.serializeValue(std.testing.allocator, &serialized, envelope);
    try serialized.append(std.testing.allocator, '\n');

    try workspace.expectEnsureDir(.{ .path = ".zigars-cache/sessions/bench_regression_gate", .provenance = "test.session" }, .{});
    try workspace.expectReadError(.{ .path = ".zigars-cache/sessions/bench_regression_gate/session-1.jsonl", .max_bytes = max_session_bytes, .provenance = "test.session" }, error.FileNotFound);
    try workspace.expectWrite(.{ .path = ".zigars-cache/sessions/bench_regression_gate/session-1.jsonl", .bytes = serialized.items, .provenance = "test.session" }, .{ .bytes_written = serialized.items.len });
    const path = try appendSnapshot(std.testing.allocator, workspace.port(), "bench_regression_gate", "session-1", envelope, "test.session");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(".zigars-cache/sessions/bench_regression_gate/session-1.jsonl", path);

    try workspace.expectRead(.{ .path = ".zigars-cache/sessions/bench_regression_gate/session-1.jsonl", .max_bytes = max_session_bytes, .provenance = "test.view" }, serialized.items);
    const viewed = try view(scratch, workspace.port(), "bench_regression_gate", "session-1", "test.view");
    try std.testing.expectEqual(@as(i64, 1), viewed.object.get("record_count").?.integer);
    try std.testing.expectEqualStrings("created", viewed.object.get("envelope").?.object.get("status").?.string);
    try workspace.verify();
}

test "session view reports malformed and unsupported records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    const mixed =
        "{\"schema_version\":99,\"id\":\"s\",\"kind\":\"k\",\"status\":\"old\"}\n" ++
        "{not json}\n" ++
        "{\"schema_version\":1,\"id\":\"s\",\"kind\":\"k\",\"status\":\"ok\"}\n";
    try workspace.expectRead(.{ .path = ".zigars-cache/sessions/k/s.jsonl", .max_bytes = max_session_bytes, .provenance = "test.view" }, mixed);
    const viewed = try view(scratch, workspace.port(), "k", "s", "test.view");
    try std.testing.expectEqual(@as(i64, 3), viewed.object.get("record_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), viewed.object.get("malformed_records").?.integer);
    try std.testing.expectEqual(@as(i64, 1), viewed.object.get("unsupported_versions").?.integer);
    try std.testing.expectEqualStrings("ok", viewed.object.get("envelope").?.object.get("status").?.string);
    try workspace.verify();
}
