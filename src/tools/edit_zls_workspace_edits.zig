const std = @import("std");
const zigar = @import("zigar");

const common = @import("common.zig");

const App = common.App;
const ZlsDocument = common.ZlsDocument;
const json_result = zigar.json_result;
const lsp_edits = zigar.lsp_edits;
const uri_util = zigar.uri;
const putOwnedKey = common.putOwnedKey;
const source_read_limit = common.source_read_limit;

pub const WorkspaceEditProvenance = struct {
    backend: []const u8 = "zls",
    method: []const u8,
};

pub fn workspaceEditValue(a: *App, allocator: std.mem.Allocator, result: std.json.Value, apply: bool) !std.json.Value {
    return workspaceEditValueForDocument(a, allocator, result, apply, null);
}

pub fn workspaceEditValueForDocument(a: *App, allocator: std.mem.Allocator, result: std.json.Value, apply: bool, primary_doc: ?ZlsDocument) !std.json.Value {
    return workspaceEditValueForDocumentWithProvenance(a, allocator, result, apply, primary_doc, null);
}

pub fn workspaceEditValueForDocumentWithProvenance(a: *App, allocator: std.mem.Allocator, result: std.json.Value, apply: bool, primary_doc: ?ZlsDocument, provenance: ?WorkspaceEditProvenance) !std.json.Value {
    if (result == .null) {
        var empty = std.json.ObjectMap.empty;
        errdefer json_result.deinitOwnedValue(allocator, .{ .object = empty });
        try putWorkspaceEditProvenance(allocator, &empty, provenance);
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
    errdefer json_result.deinitOwnedValue(allocator, .{ .object = obj });
    try putWorkspaceEditProvenance(allocator, &obj, provenance);
    try putOwnedKey(allocator, &obj, "applied", .{ .bool = apply });
    try putOwnedKey(allocator, &obj, "affected_files", .{ .array = files });
    try putOwnedKey(allocator, &obj, "total_edits", .{ .integer = @intCast(total_edits) });
    try putOwnedKey(allocator, &obj, "edit", try json_result.cloneValue(allocator, result));
    return .{ .object = obj };
}

fn putWorkspaceEditProvenance(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, provenance: ?WorkspaceEditProvenance) !void {
    const info = provenance orelse return;
    try putOwnedKey(allocator, obj, "backend", .{ .string = try allocator.dupe(u8, info.backend) });
    try putOwnedKey(allocator, obj, "method", .{ .string = try allocator.dupe(u8, info.method) });
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
