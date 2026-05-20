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
    errdefer obj.deinit(allocator);
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

pub fn workspaceEditValue(a: *App, allocator: std.mem.Allocator, result: std.json.Value, apply: bool) !std.json.Value {
    return workspaceEditValueForDocument(a, allocator, result, apply, null);
}

pub fn workspaceEditValueForDocument(a: *App, allocator: std.mem.Allocator, result: std.json.Value, apply: bool, primary_doc: ?ZlsDocument) !std.json.Value {
    if (result == .null) {
        var empty = std.json.ObjectMap.empty;
        try putOwnedKey(allocator, &empty, "applied", .{ .bool = apply });
        try putOwnedKey(allocator, &empty, "affected_files", .{ .array = std.json.Array.init(allocator) });
        try putOwnedKey(allocator, &empty, "total_edits", .{ .integer = 0 });
        try putOwnedKey(allocator, &empty, "edit", .null);
        return .{ .object = empty };
    }
    const edit_obj = switch (result) {
        .object => |o| o,
        else => return error.InvalidTextEdit,
    };

    var files = std.json.Array.init(allocator);
    var total_edits: usize = 0;

    if (edit_obj.get("changes")) |changes| {
        if (changes == .object) {
            var it = changes.object.iterator();
            while (it.next()) |entry| {
                total_edits += lsp_edits.textEditCount(entry.value_ptr.*);
                try files.append(try workspaceEditFileValueForDocument(a, allocator, entry.key_ptr.*, entry.value_ptr.*, apply, primary_doc));
            }
        }
    }

    if (edit_obj.get("documentChanges")) |document_changes| {
        if (document_changes == .array) {
            for (document_changes.array.items) |change| {
                const change_obj = switch (change) {
                    .object => |o| o,
                    else => continue,
                };
                const text_doc = switch (change_obj.get("textDocument") orelse .null) {
                    .object => |o| o,
                    else => continue,
                };
                const uri = switch (text_doc.get("uri") orelse .null) {
                    .string => |s| s,
                    else => continue,
                };
                const edits = change_obj.get("edits") orelse continue;
                total_edits += lsp_edits.textEditCount(edits);
                try files.append(try workspaceEditFileValueForDocument(a, allocator, uri, edits, apply, primary_doc));
            }
        }
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try putOwnedKey(allocator, &obj, "applied", .{ .bool = apply });
    try putOwnedKey(allocator, &obj, "affected_files", .{ .array = files });
    try putOwnedKey(allocator, &obj, "total_edits", .{ .integer = @intCast(total_edits) });
    try putOwnedKey(allocator, &obj, "edit", try json_result.cloneValue(allocator, result));
    return .{ .object = obj };
}

pub fn workspaceEditFileValue(a: *App, allocator: std.mem.Allocator, uri: []const u8, edits: std.json.Value, apply: bool) !std.json.Value {
    return workspaceEditFileValueForDocument(a, allocator, uri, edits, apply, null);
}

pub fn workspaceEditFileValueForDocument(a: *App, allocator: std.mem.Allocator, uri: []const u8, edits: std.json.Value, apply: bool, primary_doc: ?ZlsDocument) !std.json.Value {
    const path = try uri_util.uriToPath(allocator, uri);
    defer allocator.free(path);
    const safe_path = try a.workspace.resolve(path);
    defer allocator.free(safe_path);
    const rel_view = a.workspace.relative(safe_path);
    const rel = try allocator.dupe(u8, rel_view);
    var owned_source: ?[]u8 = null;
    defer if (owned_source) |source| allocator.free(source);
    const source: []const u8 = if (primary_doc) |doc| blk: {
        if (std.mem.eql(u8, uri, doc.uri)) break :blk doc.source;
        owned_source = try a.workspace.readFileAlloc(a.io, rel, source_read_limit);
        break :blk owned_source.?;
    } else blk: {
        owned_source = try a.workspace.readFileAlloc(a.io, rel, source_read_limit);
        break :blk owned_source.?;
    };
    const source_kind = if (primary_doc) |doc|
        if (std.mem.eql(u8, uri, doc.uri)) doc.sourceKindName() else "disk"
    else
        "disk";
    const updated = try lsp_edits.applyTextEdits(allocator, source, edits);
    defer allocator.free(updated);
    const diff = try lsp_edits.unifiedDiff(allocator, rel, source, updated);
    if (apply) {
        try a.workspace.writeFile(a.io, rel, updated);
        if (a.lsp_client) |client| {
            if (a.doc_state) |doc_state| doc_state.closeDoc(client, uri) catch |err| {
                a.logger.warn("zls", "failed to close edited document {s}: {}", .{ uri, err });
            };
        }
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try putOwnedKey(allocator, &obj, "file", .{ .string = rel });
    try putOwnedKey(allocator, &obj, "edit_count", .{ .integer = @intCast(lsp_edits.textEditCount(edits)) });
    try putOwnedKey(allocator, &obj, "source_hash", .{ .string = try lsp_edits.hashHex(allocator, source) });
    try putOwnedKey(allocator, &obj, "updated_hash", .{ .string = try lsp_edits.hashHex(allocator, updated) });
    try putOwnedKey(allocator, &obj, "source_kind", .{ .string = try allocator.dupe(u8, source_kind) });
    try putOwnedKey(allocator, &obj, "diff", .{ .string = diff });
    return .{ .object = obj };
}

pub fn applyEditsForUri(a: *App, allocator: std.mem.Allocator, uri: []const u8, edits: std.json.Value) !void {
    const path = try uri_util.uriToPath(allocator, uri);
    defer allocator.free(path);
    const safe_path = try a.workspace.resolve(path);
    defer allocator.free(safe_path);
    const rel = a.workspace.relative(safe_path);
    const source = try a.workspace.readFileAlloc(a.io, rel, source_read_limit);
    defer allocator.free(source);
    const updated = try lsp_edits.applyTextEdits(allocator, source, edits);
    defer allocator.free(updated);
    try a.workspace.writeFile(a.io, rel, updated);
    if (a.lsp_client) |client| {
        if (a.doc_state) |doc_state| doc_state.closeDoc(client, uri) catch |err| {
            a.logger.warn("zls", "failed to close edited document {s}: {}", .{ uri, err });
        };
    }
}
