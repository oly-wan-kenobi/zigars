//! ZLS code-intel adapter for position and workspace symbol protocol requests.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");

/// Provenance tag attached to workspace reads from this workflow.
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

/// Implements position workflow logic using caller-owned inputs.
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

/// Implements file only workflow logic using caller-owned inputs.
pub fn fileOnly(allocator: std.mem.Allocator, context: app_context.ZlsContext, request: FileRequest) !PositionOutcome {
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

/// Implements workspace symbols workflow logic using caller-owned inputs.
pub fn workspaceSymbols(allocator: std.mem.Allocator, context: app_context.ZlsContext, request: WorkspaceSymbolRequest) !PositionOutcome {
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

/// Implements capability for method workflow logic using caller-owned inputs.
pub fn capabilityForMethod(method: []const u8) ?[]const u8 {
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

/// Implements position payload workflow logic using caller-owned inputs.
fn positionPayload(allocator: std.mem.Allocator, uri: []const u8, line: i64, character: i64) std.mem.Allocator.Error![]u8 {
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

/// Reports whether payload matches the caller-provided data.
fn referencesPayload(allocator: std.mem.Allocator, uri: []const u8, line: i64, character: i64, include_declaration: bool) std.mem.Allocator.Error![]u8 {
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

/// Implements file only payload workflow logic using caller-owned inputs.
fn fileOnlyPayload(allocator: std.mem.Allocator, uri: []const u8) std.mem.Allocator.Error![]u8 {
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

/// Implements workspace symbol payload workflow logic using caller-owned inputs.
fn workspaceSymbolPayload(allocator: std.mem.Allocator, query: []const u8) std.mem.Allocator.Error![]u8 {
    const Params = struct { query: []const u8 };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    std.json.Stringify.value(Params{ .query = query }, .{}, &aw.writer) catch return error.OutOfMemory;
    const bytes = try aw.toOwnedSlice();
    aw_owned = false;
    return bytes;
}
