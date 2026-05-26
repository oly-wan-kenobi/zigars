const std = @import("std");

const ports = @import("../../app/ports.zig");
const zls_session = @import("session.zig");
const Workspace = @import("../workspace/workspace.zig").Workspace;

pub const Gateway = struct {
    allocator: std.mem.Allocator,
    workspace: *Workspace,
    state: *zls_session.State,
    slots: zls_session.Slots,
    config: zls_session.Config,
    request_counter: ?*usize = null,

    const Self = @This();

    pub const Options = struct {
        allocator: std.mem.Allocator,
        workspace: *Workspace,
        state: *zls_session.State,
        slots: zls_session.Slots = .{},
        config: zls_session.Config,
        request_counter: ?*usize = null,
    };

    pub fn init(options: Options) Self {
        return .{
            .allocator = options.allocator,
            .workspace = options.workspace,
            .state = options.state,
            .slots = options.slots,
            .config = options.config,
            .request_counter = options.request_counter,
        };
    }

    pub fn port(self: *Self) ports.ZlsGateway {
        return .{
            .ptr = self,
            .vtable = &.{
                .capability = capability,
                .sync = sync,
                .request = request,
            },
        };
    }

    fn capability(ptr: *anyopaque, request_value: ports.ZlsCapabilityRequest) ports.PortError!ports.ZlsCapabilityResult {
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

    fn sync(ptr: *anyopaque, allocator: std.mem.Allocator, request_value: ports.ZlsSyncRequest) ports.PortError!ports.ZlsSyncResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
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

    fn request(ptr: *anyopaque, allocator: std.mem.Allocator, request_value: ports.ZlsRequest) ports.PortError!ports.ZlsResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const client = self.state.client orelse return error.Unavailable;
        const params_bytes = if (request_value.payload.len == 0) "{}" else request_value.payload;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, params_bytes, .{}) catch return error.InvalidRequest;
        defer parsed.deinit();
        if (self.request_counter) |counter| counter.* += 1;
        const response = client.sendRequest(allocator, request_value.method, parsed.value) catch |err| return mapZlsError(err);
        return .{
            .method = request_value.method,
            .payload = response,
            .owns_payload = true,
        };
    }
};

fn responseResult(value: std.json.Value) ?std.json.Value {
    const obj = switch (value) {
        .object => |object| object,
        else => return null,
    };
    return obj.get("result");
}

fn mapZlsError(err: anyerror) ports.PortError {
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
        else => error.Unavailable,
    };
}
