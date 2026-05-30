//! Tests for JSON-RPC 2.0 message serialization and RequestId semantics.
//! Pins: ID equality across all variants, JSON round-trip for integer/string/null IDs,
//! correct envelope shapes for response/error/notification/request, and ErrorCode values.
const std = @import("std");
const json_rpc = @import("json_rpc.zig");

const RequestId = json_rpc.RequestId;
const ErrorCode = json_rpc.ErrorCode;
const writeResponse = json_rpc.writeResponse;
const writeError = json_rpc.writeError;
const writeNotification = json_rpc.writeNotification;
const writeRequest = json_rpc.writeRequest;

test "RequestId integer equality" {
    const a = RequestId{ .integer = 42 };
    const b = RequestId{ .integer = 42 };
    const c = RequestId{ .integer = 99 };
    try std.testing.expect(RequestId.eql(a, b));
    try std.testing.expect(!RequestId.eql(a, c));
}

test "RequestId string equality" {
    const a = RequestId{ .string = "abc" };
    const b = RequestId{ .string = "abc" };
    const c = RequestId{ .string = "xyz" };
    try std.testing.expect(RequestId.eql(a, b));
    try std.testing.expect(!RequestId.eql(a, c));
}

test "RequestId none equality" {
    const a = RequestId.none;
    const b = RequestId.none;
    try std.testing.expect(RequestId.eql(a, b));
}

test "RequestId cross-type inequality" {
    const int_id = RequestId{ .integer = 1 };
    const str_id = RequestId{ .string = "1" };
    const none_id = RequestId.none;
    try std.testing.expect(!RequestId.eql(int_id, str_id));
    try std.testing.expect(!RequestId.eql(int_id, none_id));
    try std.testing.expect(!RequestId.eql(str_id, none_id));
}

test "RequestId integer JSON serialization" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    const id = RequestId{ .integer = 42 };
    try RequestId.jsonStringify(id, &jw);
    const out = try aw.toOwnedSlice();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("42", out);
}

test "RequestId string JSON serialization" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    const id = RequestId{ .string = "req-1" };
    try RequestId.jsonStringify(id, &jw);
    const out = try aw.toOwnedSlice();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("\"req-1\"", out);
}

test "RequestId none JSON serialization" {
    const alloc = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    const id = RequestId.none;
    try RequestId.jsonStringify(id, &jw);
    const out = try aw.toOwnedSlice();
    defer alloc.free(out);
    try std.testing.expectEqualStrings("null", out);
}

test "writeResponse with integer id" {
    const alloc = std.testing.allocator;
    const resp = try writeResponse(alloc, .{ .integer = 1 }, "hello");
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("id").?.integer);
    try std.testing.expectEqualStrings("hello", obj.get("result").?.string);
}

test "writeResponse with null result" {
    const alloc = std.testing.allocator;
    const resp = try writeResponse(alloc, .{ .integer = 5 }, null);
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("result").? == .null);
}

test "writeError produces valid JSON-RPC error" {
    const alloc = std.testing.allocator;
    const resp = try writeError(alloc, .{ .integer = 7 }, ErrorCode.method_not_found, "not found");
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 7), obj.get("id").?.integer);
    const err_obj = obj.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err_obj.get("code").?.integer);
    try std.testing.expectEqualStrings("not found", err_obj.get("message").?.string);
}

test "writeError with null id" {
    const alloc = std.testing.allocator;
    const resp = try writeError(alloc, null, ErrorCode.parse_error, "bad json");
    defer alloc.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, resp, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("id").? == .null);
}

test "writeNotification has no id field" {
    const alloc = std.testing.allocator;
    const notif = try writeNotification(alloc, "textDocument/didOpen", .{ .uri = "file:///a.zig" });
    defer alloc.free(notif);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, notif, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("id") == null);
    try std.testing.expectEqualStrings("textDocument/didOpen", obj.get("method").?.string);
    const params = obj.get("params").?.object;
    try std.testing.expectEqualStrings("file:///a.zig", params.get("uri").?.string);
}

test "writeRequest has id and method" {
    const alloc = std.testing.allocator;
    const req = try writeRequest(alloc, .{ .integer = 10 }, "textDocument/hover", .{ .line = @as(i64, 5) });
    defer alloc.free(req);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, req, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 10), obj.get("id").?.integer);
    try std.testing.expectEqualStrings("textDocument/hover", obj.get("method").?.string);
    try std.testing.expect(obj.get("params") != null);
}

test "ErrorCode constants" {
    try std.testing.expectEqual(@as(i64, -32700), ErrorCode.parse_error);
    try std.testing.expectEqual(@as(i64, -32600), ErrorCode.invalid_request);
    try std.testing.expectEqual(@as(i64, -32601), ErrorCode.method_not_found);
    try std.testing.expectEqual(@as(i64, -32602), ErrorCode.invalid_params);
    try std.testing.expectEqual(@as(i64, -32603), ErrorCode.internal_error);
}
