const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const core = @import("shared_core.zig");

const App = core.App;
const argString = core.argString;
const source_read_limit = core.source_read_limit;
const toolErrorResult = core.toolErrorResult;
const zls_session = zigar.zls_session;

pub const Source = enum {
    disk,
    provided_content,
};

pub const Document = struct {
    uri: []const u8,
    rel_path: []const u8,
    source: []const u8,
    source_kind: Source,
    content_matches_disk: bool,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.rel_path);
        allocator.free(self.source);
        self.* = undefined;
    }

    pub fn sourceKindName(self: Document) []const u8 {
        return switch (self.source_kind) {
            .disk => "disk",
            .provided_content => "provided_content",
        };
    }

    pub fn canApplyToDisk(self: Document) bool {
        return self.source_kind == .disk or self.content_matches_disk;
    }
};

pub fn fromArgs(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Document {
    const file = argString(args, "file") orelse return error.MissingFile;
    try zls_session.ensureReady(a);
    const client = a.lsp_client orelse return error.NotConnected;
    const doc_state = a.doc_state orelse return error.NotConnected;

    const resolved = try a.workspace.resolve(file);
    defer allocator.free(resolved);
    const rel_view = a.workspace.relative(resolved);
    const rel_path = try allocator.dupe(u8, rel_view);
    errdefer allocator.free(rel_path);

    const disk_content = try a.workspace.readFileAlloc(a.io, rel_path, source_read_limit);
    defer allocator.free(disk_content);

    if (argString(args, "content")) |content| {
        const source = try allocator.dupe(u8, content);
        errdefer allocator.free(source);
        const uri = try doc_state.syncText(client, resolved, content, allocator);
        errdefer allocator.free(uri);
        return .{
            .uri = uri,
            .rel_path = rel_path,
            .source = source,
            .source_kind = .provided_content,
            .content_matches_disk = std.mem.eql(u8, content, disk_content),
        };
    }

    const source = try allocator.dupe(u8, disk_content);
    errdefer allocator.free(source);
    const uri = try doc_state.syncDiskText(client, resolved, disk_content, allocator);
    errdefer allocator.free(uri);
    return .{
        .uri = uri,
        .rel_path = rel_path,
        .source = source,
        .source_kind = .disk,
        .content_matches_disk = true,
    };
}

pub fn unsavedApplyError(allocator: std.mem.Allocator, tool: []const u8, operation: []const u8, doc: Document) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorResult(allocator, .{
        .tool = tool,
        .operation = operation,
        .phase = "validate_apply_base",
        .code = "unsaved_content_apply_rejected",
        .category = "document_state",
        .resolution = "Preview without apply=true, save the provided content to disk first, or retry with content that matches the current disk file.",
        .details = &.{
            .{ .key = "file", .value = .{ .string = doc.rel_path } },
            .{ .key = "source_kind", .value = .{ .string = doc.sourceKindName() } },
            .{ .key = "content_matches_disk", .value = .{ .bool = doc.content_matches_disk } },
        },
    });
}

test "ZlsDocument rejects apply for unsaved content that differs from disk" {
    var doc = Document{
        .uri = try std.testing.allocator.dupe(u8, "file:///tmp/main.zig"),
        .rel_path = try std.testing.allocator.dupe(u8, "main.zig"),
        .source = try std.testing.allocator.dupe(u8, "const unsaved = true;\n"),
        .source_kind = .provided_content,
        .content_matches_disk = false,
    };
    defer doc.deinit(std.testing.allocator);
    try std.testing.expect(!doc.canApplyToDisk());

    doc.content_matches_disk = true;
    try std.testing.expect(doc.canApplyToDisk());
    doc.source_kind = .disk;
    doc.content_matches_disk = false;
    try std.testing.expect(doc.canApplyToDisk());
}
