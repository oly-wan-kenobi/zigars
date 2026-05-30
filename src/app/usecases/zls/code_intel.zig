//! ZLS code-intel use cases for position, range, file, and workspace-symbol LSP
//! requests. Every handler runs the same contract: gate on the method's ZLS
//! capability, sync the document through the gateway, then issue the raw LSP
//! request. rename and codeAction return ZLS workspace-edit previews only; this
//! layer never writes source, so it has no apply gate of its own.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");

/// Provenance tag stamped on the gateway document sync so trust/audit trails
/// attribute the in-memory ZLS upload to this use case.
pub const provenance = "zls.code_intel";

/// Carries position request data across use case and port boundaries.
pub const PositionRequest = struct {
    method: []const u8,
    file: ?[]const u8 = null,
    content: ?[]const u8 = null,
    line: i64 = 0,
    character: i64 = 0,
    include_declaration: bool = true,
};

/// Carries range request data across use case and port boundaries.
pub const RangeRequest = struct {
    method: []const u8,
    file: ?[]const u8 = null,
    content: ?[]const u8 = null,
    start_line: i64 = 0,
    start_character: i64 = 0,
    end_line: i64 = 0,
    end_character: i64 = 0,
};

/// Carries rename request data across use case and port boundaries.
pub const RenameRequest = struct {
    file: ?[]const u8 = null,
    content: ?[]const u8 = null,
    line: i64 = 0,
    character: i64 = 0,
    new_name: []const u8,
};

/// Carries code-action selection request data across use case and port boundaries.
pub const CodeActionSelectionRequest = struct {
    file: ?[]const u8 = null,
    content: ?[]const u8 = null,
    start_line: i64 = 0,
    start_character: i64 = 0,
    end_line: i64 = 0,
    end_character: i64 = 0,
    action_index: i64 = 0,
};

/// Carries file request data across use case and port boundaries.
pub const FileRequest = struct {
    method: []const u8,
    file: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

/// Carries workspace symbol request data across use case and port boundaries.
pub const WorkspaceSymbolRequest = struct {
    query: []const u8,
};

/// Carries position response data across use case and port boundaries.
pub const PositionResponse = struct {
    method: []const u8,
    payload: []const u8,
    owns_payload: bool = false,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: PositionResponse, allocator: std.mem.Allocator) void {
        if (self.owns_payload) allocator.free(self.payload);
    }
};

/// Represents failure alternatives carried across the workflow boundary.
pub const Failure = union(enum) {
    unavailable: []const u8,
    unsupported_capability: []const u8,
    missing_file,
    invalid_action_index: struct { index: i64, count: usize },
    invalid_response: []const u8,
    sync_failed: PortFailure,
    request_failed: PortFailure,
};

/// Carries port failure data across use case and port boundaries.
pub const PortFailure = struct {
    err: ports.PortError,
    file: ?[]const u8 = null,
};

/// Represents position outcome alternatives carried across the workflow boundary.
pub const PositionOutcome = union(enum) {
    ok: PositionResponse,
    err: Failure,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: PositionOutcome, allocator: std.mem.Allocator) void {
        switch (self) {
            .ok => |response| response.deinit(allocator),
            .err => {},
        }
    }
};

/// Runs a position-based LSP request (hover, definition, completion, references,
/// ...): capability-gate, sync the document, then send the request. Returns an
/// .err outcome for unsupported/unavailable capability, missing file, or port
/// failure; only OutOfMemory escapes as a hard error. Caller owns the resulting
/// payload via PositionOutcome.deinit.
pub fn position(allocator: std.mem.Allocator, context: app_context.ZlsContext, request: PositionRequest) !PositionOutcome {
    const gateway = context.zls_gateway;
    if (capabilityForMethod(request.method)) |capability| {
        const capability_result = gateway.capability(.{ .capability = capability }) catch |err| return .{ .err = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => .{ .unavailable = capability },
        } };
        if (!capability_result.supported) {
            return .{ .err = .{ .unsupported_capability = capability_result.capability } };
        }
    }

    const file = request.file orelse return .{ .err = .missing_file };
    const sync_result = gateway.sync(allocator, .{
        .file = file,
        .content = request.content,
        .provenance = provenance,
    }) catch |err| return .{ .err = .{ .sync_failed = .{ .err = err, .file = file } } };
    defer sync_result.deinit(allocator);

    // references needs the extra includeDeclaration context object; every other
    // position method takes the bare textDocument+position payload.
    const payload = if (std.mem.eql(u8, request.method, "textDocument/references"))
        try referencesPayload(allocator, sync_result.uri, request.line, request.character, request.include_declaration)
    else
        try positionPayload(allocator, sync_result.uri, request.line, request.character);
    defer allocator.free(payload);
    const response = gateway.request(allocator, .{
        .method = request.method,
        .uri = sync_result.uri,
        .payload = payload,
    }) catch |err| return .{ .err = .{ .request_failed = .{ .err = err, .file = file } } };
    return .{ .ok = .{
        .method = request.method,
        .payload = response.payload,
        .owns_payload = response.owns_payload,
    } };
}

/// Runs a range-based LSP request (e.g. codeAction): capability-gate, sync the
/// document, then send the request with an empty diagnostics context. Same
/// outcome and ownership contract as `position`.
pub fn range(allocator: std.mem.Allocator, context: app_context.ZlsContext, request: RangeRequest) !PositionOutcome {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const gateway = context.zls_gateway;
    if (capabilityForMethod(request.method)) |capability| {
        const capability_result = gateway.capability(.{ .capability = capability }) catch |err| return .{ .err = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => .{ .unavailable = capability },
        } };
        if (!capability_result.supported) return .{ .err = .{ .unsupported_capability = capability_result.capability } };
    }

    const file = request.file orelse return .{ .err = .missing_file };
    const sync_result = gateway.sync(allocator, .{
        .file = file,
        .content = request.content,
        .provenance = provenance,
    }) catch |err| return .{ .err = .{ .sync_failed = .{ .err = err, .file = file } } };
    defer sync_result.deinit(allocator);

    const payload = try rangePayload(allocator, sync_result.uri, request.start_line, request.start_character, request.end_line, request.end_character);
    defer allocator.free(payload);
    const response = gateway.request(allocator, .{
        .method = request.method,
        .uri = sync_result.uri,
        .payload = payload,
    }) catch |err| return .{ .err = .{ .request_failed = .{ .err = err, .file = file } } };
    return .{ .ok = .{
        .method = request.method,
        .payload = response.payload,
        .owns_payload = response.owns_payload,
    } };
}

/// Requests a ZLS rename workspace-edit preview without applying source writes.
pub fn rename(allocator: std.mem.Allocator, context: app_context.ZlsContext, request: RenameRequest) !PositionOutcome {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const gateway = context.zls_gateway;
    if (capabilityForMethod("textDocument/rename")) |capability| {
        const capability_result = gateway.capability(.{ .capability = capability }) catch |err| return .{ .err = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => .{ .unavailable = capability },
        } };
        if (!capability_result.supported) return .{ .err = .{ .unsupported_capability = capability_result.capability } };
    }

    const file = request.file orelse return .{ .err = .missing_file };
    const sync_result = gateway.sync(allocator, .{
        .file = file,
        .content = request.content,
        .provenance = provenance,
    }) catch |err| return .{ .err = .{ .sync_failed = .{ .err = err, .file = file } } };
    defer sync_result.deinit(allocator);

    const payload = try renamePayload(allocator, sync_result.uri, request.line, request.character, request.new_name);
    defer allocator.free(payload);
    const response = gateway.request(allocator, .{
        .method = "textDocument/rename",
        .uri = sync_result.uri,
        .payload = payload,
    }) catch |err| return .{ .err = .{ .request_failed = .{ .err = err, .file = file } } };
    return .{ .ok = .{
        .method = "textDocument/rename",
        .payload = response.payload,
        .owns_payload = response.owns_payload,
    } };
}

/// Requests code actions and returns the selected action as a preview payload.
pub fn codeActionSelection(allocator: std.mem.Allocator, context: app_context.ZlsContext, request: CodeActionSelectionRequest) !PositionOutcome {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var actions = try range(allocator, context, .{
        .method = "textDocument/codeAction",
        .file = request.file,
        .content = request.content,
        .start_line = request.start_line,
        .start_character = request.start_character,
        .end_line = request.end_line,
        .end_character = request.end_character,
    });
    switch (actions) {
        .ok => |response| {
            const selected = selectCodeActionPayload(allocator, response.payload, request.action_index) catch |err| {
                const count = codeActionCount(allocator, response.payload) catch 0;
                actions.deinit(allocator);
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.InvalidActionIndex => .{ .err = .{ .invalid_action_index = .{ .index = request.action_index, .count = count } } },
                    else => .{ .err = .{ .invalid_response = "ZLS codeAction response did not contain an array result" } },
                };
            };
            actions.deinit(allocator);
            return .{ .ok = .{
                .method = "textDocument/codeAction",
                .payload = selected,
                .owns_payload = true,
            } };
        },
        .err => return actions,
    }
}

/// Runs a whole-file LSP request (e.g. documentSymbol, formatting) whose payload
/// is just the textDocument URI: capability-gate, sync, then request. Same
/// outcome and ownership contract as `position`.
pub fn fileOnly(allocator: std.mem.Allocator, context: app_context.ZlsContext, request: FileRequest) !PositionOutcome {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const gateway = context.zls_gateway;
    if (capabilityForMethod(request.method)) |capability| {
        const capability_result = gateway.capability(.{ .capability = capability }) catch |err| return .{ .err = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => .{ .unavailable = capability },
        } };
        if (!capability_result.supported) return .{ .err = .{ .unsupported_capability = capability_result.capability } };
    }
    const file = request.file orelse return .{ .err = .missing_file };
    const sync_result = gateway.sync(allocator, .{
        .file = file,
        .content = request.content,
        .provenance = provenance,
    }) catch |err| return .{ .err = .{ .sync_failed = .{ .err = err, .file = file } } };
    defer sync_result.deinit(allocator);
    const payload = try fileOnlyPayload(allocator, sync_result.uri);
    defer allocator.free(payload);
    const response = gateway.request(allocator, .{
        .method = request.method,
        .uri = sync_result.uri,
        .payload = payload,
    }) catch |err| return .{ .err = .{ .request_failed = .{ .err = err, .file = file } } };
    return .{ .ok = .{
        .method = request.method,
        .payload = response.payload,
        .owns_payload = response.owns_payload,
    } };
}

/// Runs a workspace/symbol query. Unlike the per-document handlers this skips
/// the sync step (the query spans the workspace, not one file) and sends the
/// request with no URI. Same outcome and ownership contract as `position`.
pub fn workspaceSymbols(allocator: std.mem.Allocator, context: app_context.ZlsContext, request: WorkspaceSymbolRequest) !PositionOutcome {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const gateway = context.zls_gateway;
    if (capabilityForMethod("workspace/symbol")) |capability| {
        const capability_result = gateway.capability(.{ .capability = capability }) catch |err| return .{ .err = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => .{ .unavailable = capability },
        } };
        if (!capability_result.supported) return .{ .err = .{ .unsupported_capability = capability_result.capability } };
    }
    const payload = try workspaceSymbolPayload(allocator, request.query);
    defer allocator.free(payload);
    const response = gateway.request(allocator, .{
        .method = "workspace/symbol",
        .payload = payload,
    }) catch |err| return .{ .err = .{ .request_failed = .{ .err = err, .file = null } } };
    return .{ .ok = .{
        .method = "workspace/symbol",
        .payload = response.payload,
        .owns_payload = response.owns_payload,
    } };
}

/// Maps an LSP method to the ZLS server-capability key that must be advertised
/// before it is sent; null means the method is not capability-gated here.
pub fn capabilityForMethod(method: []const u8) ?[]const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (std.mem.eql(u8, method, "textDocument/hover")) return "hoverProvider";
    if (std.mem.eql(u8, method, "textDocument/definition")) return "definitionProvider";
    if (std.mem.eql(u8, method, "textDocument/references")) return "referencesProvider";
    if (std.mem.eql(u8, method, "textDocument/completion")) return "completionProvider";
    if (std.mem.eql(u8, method, "textDocument/signatureHelp")) return "signatureHelpProvider";
    if (std.mem.eql(u8, method, "textDocument/documentSymbol")) return "documentSymbolProvider";
    if (std.mem.eql(u8, method, "textDocument/formatting")) return "documentFormattingProvider";
    if (std.mem.eql(u8, method, "textDocument/rename")) return "renameProvider";
    if (std.mem.eql(u8, method, "textDocument/codeAction")) return "codeActionProvider";
    if (std.mem.eql(u8, method, "workspace/symbol")) return "workspaceSymbolProvider";
    return null;
}

/// Builds the textDocument+position LSP params JSON; caller owns the bytes.
fn positionPayload(allocator: std.mem.Allocator, uri: []const u8, line: i64, character: i64) std.mem.Allocator.Error![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    std.json.Stringify.value(Params{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = line, .character = character },
    }, .{}, &aw.writer) catch return error.OutOfMemory;
    const bytes = try aw.toOwnedSlice();
    aw_owned = false;
    return bytes;
}

/// Builds the textDocument/references LSP params JSON, adding the
/// includeDeclaration context flag; caller owns the bytes.
fn referencesPayload(allocator: std.mem.Allocator, uri: []const u8, line: i64, character: i64, include_declaration: bool) std.mem.Allocator.Error![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
        context: struct { includeDeclaration: bool },
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    std.json.Stringify.value(Params{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = line, .character = character },
        .context = .{ .includeDeclaration = include_declaration },
    }, .{}, &aw.writer) catch return error.OutOfMemory;
    const bytes = try aw.toOwnedSlice();
    aw_owned = false;
    return bytes;
}

/// Builds a range-based LSP payload with an empty diagnostics context.
fn rangePayload(allocator: std.mem.Allocator, uri: []const u8, start_line: i64, start_character: i64, end_line: i64, end_character: i64) std.mem.Allocator.Error![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const Diagnostic = struct {};
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        range: struct {
            start: struct { line: i64, character: i64 },
            end: struct { line: i64, character: i64 },
        },
        context: struct { diagnostics: []const Diagnostic },
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    std.json.Stringify.value(Params{
        .textDocument = .{ .uri = uri },
        .range = .{
            .start = .{ .line = start_line, .character = start_character },
            .end = .{ .line = end_line, .character = end_character },
        },
        .context = .{ .diagnostics = &.{} },
    }, .{}, &aw.writer) catch return error.OutOfMemory;
    const bytes = try aw.toOwnedSlice();
    aw_owned = false;
    return bytes;
}

/// Builds a rename LSP payload including the requested new symbol name.
fn renamePayload(allocator: std.mem.Allocator, uri: []const u8, line: i64, character: i64, new_name: []const u8) std.mem.Allocator.Error![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
        newName: []const u8,
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    std.json.Stringify.value(Params{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = line, .character = character },
        .newName = new_name,
    }, .{}, &aw.writer) catch return error.OutOfMemory;
    const bytes = try aw.toOwnedSlice();
    aw_owned = false;
    return bytes;
}

/// Returns the number of actions in a code-action response payload.
fn codeActionCount(allocator: std.mem.Allocator, payload: []const u8) !usize {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const array = actionArray(parsed.value) orelse return error.InvalidActionResponse;
    return array.items.len;
}

/// Selects one code action and wraps it as an LSP-shaped result payload.
fn selectCodeActionPayload(allocator: std.mem.Allocator, payload: []const u8, action_index: i64) ![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (action_index < 0) return error.InvalidActionIndex;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const array = actionArray(parsed.value) orelse return error.InvalidActionResponse;
    const index: usize = @intCast(action_index);
    if (index >= array.items.len) return error.InvalidActionIndex;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    try aw.writer.writeAll("{\"result\":");
    std.json.Stringify.value(array.items[index], .{}, &aw.writer) catch return error.OutOfMemory;
    try aw.writer.writeAll("}");
    const bytes = try aw.toOwnedSlice();
    aw_owned = false;
    return bytes;
}

/// Returns the result array from a direct array or JSON-RPC response object.
fn actionArray(value: std.json.Value) ?std.json.Array {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (value) {
        .array => |array| array,
        .object => |object| switch (object.get("result") orelse .null) {
            .array => |array| array,
            else => null,
        },
        else => null,
    };
}

/// Builds an LSP params JSON carrying only the textDocument URI; caller owns the
/// bytes.
fn fileOnlyPayload(allocator: std.mem.Allocator, uri: []const u8) std.mem.Allocator.Error![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const Params = struct {
        textDocument: struct { uri: []const u8 },
    };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    std.json.Stringify.value(Params{ .textDocument = .{ .uri = uri } }, .{}, &aw.writer) catch return error.OutOfMemory;
    const bytes = try aw.toOwnedSlice();
    aw_owned = false;
    return bytes;
}

/// Builds the workspace/symbol LSP params JSON from the query; caller owns the
/// bytes.
fn workspaceSymbolPayload(allocator: std.mem.Allocator, query: []const u8) std.mem.Allocator.Error![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const Params = struct { query: []const u8 };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    std.json.Stringify.value(Params{ .query = query }, .{}, &aw.writer) catch return error.OutOfMemory;
    const bytes = try aw.toOwnedSlice();
    aw_owned = false;
    return bytes;
}
