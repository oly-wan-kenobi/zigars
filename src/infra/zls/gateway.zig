//! ZLS gateway: port facade over the live ZLS session.
//! Adapts the session/document/client layer to the ZlsGateway port vtable
//! consumed by use-case code. All file arguments are resolved through the
//! workspace sandbox before reaching the document layer.
const std = @import("std");

const ports = @import("../../app/ports.zig");
const zls_session = @import("session.zig");
const Workspace = @import("../workspace/workspace.zig").Workspace;

/// Concrete ZlsGateway implementation backed by a live ZLS process and document state.
/// All slot/state pointers are borrowed — the caller (bootstrap/runtime composition)
/// owns the storage and must outlive the Gateway.
pub const Gateway = struct {
    allocator: std.mem.Allocator,
    workspace: *Workspace,
    state: *zls_session.State,
    slots: zls_session.Slots,
    config: zls_session.Config,
    request_counter: ?*usize = null,
    cancellation_token: ?ports.CancellationToken = null,

    const Self = @This();

    /// Construction settings for a gateway; slot pointers are borrowed.
    pub const Options = struct {
        allocator: std.mem.Allocator,
        workspace: *Workspace,
        state: *zls_session.State,
        slots: zls_session.Slots = .{},
        config: zls_session.Config,
        request_counter: ?*usize = null,
        cancellation_token: ?ports.CancellationToken = null,
    };

    /// Stores borrowed workspace/session pointers and request counter.
    pub fn init(options: Options) Self {
        // Capture all required dependencies up front so later calls can stay predictable.
        return .{
            .allocator = options.allocator,
            .workspace = options.workspace,
            .state = options.state,
            .slots = options.slots,
            .config = options.config,
            .request_counter = options.request_counter,
            .cancellation_token = options.cancellation_token,
        };
    }

    /// Exposes this gateway through the ZlsGateway vtable.
    pub fn port(self: *Self) ports.ZlsGateway {
        // Keep this logic centralized so callers observe one consistent behavior path.
        return .{
            .ptr = self,
            .vtable = &.{
                .capability = capability,
                .sync = sync,
                .request = request,
                .diagnostics = diagnostics,
            },
        };
    }

    /// Queries a named LSP capability from the cached initialize response.
    /// Returns Unavailable when no client is connected or the response is absent.
    fn capability(ptr: *anyopaque, request_value: ports.ZlsCapabilityRequest) ports.PortError!ports.ZlsCapabilityResult {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.state.client == null) return error.Unavailable;
        const response = self.state.initialize_response orelse return error.Unavailable;
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch return error.Unavailable;
        defer parsed.deinit();
        const result = responseResult(parsed.value) orelse return error.Unavailable;
        const result_obj = switch (result) {
            .object => |object| object,
            else => return error.Unavailable,
        };
        const caps = switch (result_obj.get("capabilities") orelse .null) {
            .object => |object| object,
            else => return error.Unavailable,
        };
        const value = caps.get(request_value.capability) orelse return .{
            .capability = request_value.capability,
            .supported = false,
            .basis = "initialize_response",
        };
        return .{
            .capability = request_value.capability,
            .supported = switch (value) {
                .bool => |supported| supported,
                .object, .array => true,
                else => false,
            },
            .basis = "initialize_response",
        };
    }

    /// Syncs a file with ZLS: with content → syncText (dirty); without → ensureOpen (disk).
    /// Ensures session readiness before the sync; resolves the file path through workspace.
    fn sync(ptr: *anyopaque, allocator: std.mem.Allocator, request_value: ports.ZlsSyncRequest) ports.PortError!ports.ZlsSyncResult {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.isCancelled()) return error.Cancelled;
        zls_session.ensureReady(self.state, self.slots, self.config) catch |err| return mapZlsError(err);
        const client = self.state.client orelse return error.Unavailable;
        const doc_state = self.state.documents orelse return error.Unavailable;
        const resolved = self.workspace.resolve(request_value.file) catch |err| return mapZlsError(err);
        defer self.allocator.free(resolved);
        const uri = if (request_value.content) |content|
            doc_state.syncText(client, resolved, content, allocator) catch |err| return mapZlsError(err)
        else
            doc_state.ensureOpen(client, resolved, allocator) catch |err| return mapZlsError(err);
        return .{
            .uri = uri,
            .basis = if (request_value.content != null) "sync_text" else "ensure_open",
            .owns_uri = true,
        };
    }

    /// Forwards a raw JSON-RPC request to ZLS and returns the raw response payload.
    /// Increments the request counter when one is configured. Supports cancellation.
    fn request(ptr: *anyopaque, allocator: std.mem.Allocator, request_value: ports.ZlsRequest) ports.PortError!ports.ZlsResponse {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.isCancelled()) return error.Cancelled;
        const client = self.state.client orelse return error.Unavailable;
        const params_bytes = if (request_value.payload.len == 0) "{}" else request_value.payload;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, params_bytes, .{}) catch return error.InvalidRequest;
        defer parsed.deinit();
        if (self.request_counter) |counter| counter.* += 1;
        const response = if (self.cancellation_token) |token|
            client.sendRequestCancellable(allocator, request_value.method, parsed.value, token) catch |err| return mapZlsError(err)
        else
            client.sendRequest(allocator, request_value.method, parsed.value) catch |err| return mapZlsError(err);
        return .{
            .method = request_value.method,
            .payload = response,
            .owns_payload = true,
        };
    }

    /// Returns an allocator-owned snapshot of all diagnostics collected by the live ZLS client.
    fn diagnostics(ptr: *anyopaque, allocator: std.mem.Allocator) ports.PortError!ports.ZlsDiagnosticsSnapshot {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const self: *Self = @ptrCast(@alignCast(ptr));
        const client = self.state.client orelse return error.Unavailable;
        const messages = client.diagnosticsSnapshot(allocator) catch |err| return mapZlsError(err);
        const status = client.diagnosticsStatus();
        return .{
            .messages = messages,
            .owns_messages = true,
            .status = .{
                .files = status.files,
                .retained_bytes = status.retained_bytes,
                .max_bytes = status.max_bytes,
                .evicted_files = status.evicted_files,
                .evicted_bytes = status.evicted_bytes,
                .dropped_oversized = status.dropped_oversized,
            },
        };
    }

    /// Returns whether the active request has been cancelled.
    fn isCancelled(self: *Self) bool {
        return if (self.cancellation_token) |token| token.isCancelled() else false;
    }
};

/// Extracts the "result" field from a JSON-RPC response object, if present.
fn responseResult(value: std.json.Value) ?std.json.Value {
    const obj = switch (value) {
        .object => |object| object,
        else => return null,
    };
    return obj.get("result");
}

/// Maps internal ZLS errors to the port-facing PortError set.
/// Errors not explicitly listed collapse to Unavailable rather than leaking internal names.
fn mapZlsError(err: anyerror) ports.PortError {
    // Preserve a single error-shaping path so callers receive consistent metadata.
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotConnected => error.Unavailable,
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.PathOutsideWorkspace => error.PathOutsideWorkspace,
        error.EmptyPath => error.EmptyPath,
        error.DocumentTooLarge => error.DocumentTooLarge,
        error.OpenDocumentLimitExceeded => error.OpenDocumentLimitExceeded,
        error.RetainedContentLimitExceeded => error.RetainedContentLimitExceeded,
        error.RequestTimeout => error.RequestTimeout,
        error.NoResponse => error.NoResponse,
        error.EndOfStream => error.EndOfStream,
        error.BrokenPipe => error.BrokenPipe,
        error.Cancelled => error.Cancelled,
        error.ZlsRestartLimitReached => error.Unavailable,
        else => error.Unavailable,
    };
}
