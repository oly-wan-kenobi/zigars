const std = @import("std");
const zigar = @import("zigar");

const common = @import("common.zig");

const App = common.App;
const ZlsDocument = common.ZlsDocument;
const json_result = zigar.json_result;
const lsp_edits = zigar.lsp_edits;
const uri_util = zigar.uri;
const putOwnedKey = common.putOwnedKey;
const responseResult = common.responseResult;
const source_read_limit = common.source_read_limit;

pub fn textEditToolValue(a: *App, allocator: std.mem.Allocator, file_uri: []const u8, response: []const u8, apply: bool) !std.json.Value {
    const path = try uri_util.uriToPath(allocator, file_uri);
    defer allocator.free(path);
    const safe_path = try a.workspace.resolve(path);
    defer allocator.free(safe_path);
    const rel_view = a.workspace.relative(safe_path);
    const rel = try allocator.dupe(u8, rel_view);
    defer allocator.free(rel);
    const source = try a.workspace.readFileAlloc(a.io, rel, source_read_limit);
    defer allocator.free(source);
    return textEditToolValueForSource(a, allocator, rel, source, "disk", response, apply);
}

pub fn textEditToolValueForDocument(a: *App, allocator: std.mem.Allocator, doc: ZlsDocument, response: []const u8, apply: bool) !std.json.Value {
    return textEditToolValueForSource(a, allocator, doc.rel_path, doc.source, doc.sourceKindName(), response, apply);
}

fn textEditToolValueForSource(a: *App, allocator: std.mem.Allocator, rel_path: []const u8, source: []const u8, source_kind: []const u8, response: []const u8, apply: bool) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = responseResult(parsed.value) orelse .null;
    const updated = if (result == .null) try allocator.dupe(u8, source) else try lsp_edits.applyTextEdits(allocator, source, result);
    var updated_moved = false;
    defer if (!updated_moved) allocator.free(updated);
    const diff = try lsp_edits.unifiedDiff(allocator, rel_path, source, updated);
    if (apply) try a.workspace.writeFile(a.io, rel_path, updated);

    var obj = std.json.ObjectMap.empty;
    errdefer json_result.deinitOwnedValue(allocator, .{ .object = obj });
    try putOwnedKey(allocator, &obj, "backend", .{ .string = try allocator.dupe(u8, "zls") });
    try putOwnedKey(allocator, &obj, "method", .{ .string = try allocator.dupe(u8, "textDocument/formatting") });
    try putOwnedKey(allocator, &obj, "applied", .{ .bool = apply });
    try putOwnedKey(allocator, &obj, "file", .{ .string = try allocator.dupe(u8, rel_path) });
    try putOwnedKey(allocator, &obj, "edit_count", .{ .integer = @intCast(lsp_edits.textEditCount(result)) });
    try putOwnedKey(allocator, &obj, "source_hash", .{ .string = try lsp_edits.hashHex(allocator, source) });
    try putOwnedKey(allocator, &obj, "updated_hash", .{ .string = try lsp_edits.hashHex(allocator, updated) });
    try putOwnedKey(allocator, &obj, "source_kind", .{ .string = try allocator.dupe(u8, source_kind) });
    try putOwnedKey(allocator, &obj, "diff", .{ .string = diff });
    try putOwnedKey(allocator, &obj, "edits", try json_result.cloneValue(allocator, result));
    if (!apply) {
        try putOwnedKey(allocator, &obj, "formatted", .{ .string = updated });
        updated_moved = true;
    }
    return .{ .object = obj };
}

pub fn previewTextEditResponse(a: *App, allocator: std.mem.Allocator, file_uri: []const u8, response: []const u8) ![]u8 {
    const path = try uri_util.uriToPath(allocator, file_uri);
    defer allocator.free(path);
    const safe_path = try a.workspace.resolve(path);
    defer allocator.free(safe_path);
    const rel = a.workspace.relative(safe_path);
    const source = try a.workspace.readFileAlloc(a.io, rel, source_read_limit);
    defer allocator.free(source);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = responseResult(parsed.value) orelse return allocator.dupe(u8, source);
    if (result == .null) return allocator.dupe(u8, source);
    return lsp_edits.applyTextEdits(allocator, source, result);
}

pub fn applyTextEditResponseToFile(a: *App, allocator: std.mem.Allocator, file_uri: []const u8, response: []const u8) ![]u8 {
    const path = try uri_util.uriToPath(allocator, file_uri);
    defer allocator.free(path);
    const safe_path = try a.workspace.resolve(path);
    defer allocator.free(safe_path);
    const rel = a.workspace.relative(safe_path);
    const updated = try previewTextEditResponse(a, allocator, file_uri, response);
    defer allocator.free(updated);
    try a.workspace.writeFile(a.io, rel, updated);
    return std.fmt.allocPrint(allocator, "applied edits to {s}\n", .{rel});
}
