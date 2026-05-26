//! MCP tasks capability bridge over runtime job state, cancellation, and progress views.
const std = @import("std");
const mcp = @import("mcp");

const jsonrpc = mcp.jsonrpc;
const pagination = @import("pagination.zig");

/// Borrowed view of a runtime job exposed through MCP task endpoints.
pub const JobView = struct {
    id: []const u8,
    label: []const u8,
    status: []const u8,
    ok: bool,
    stdout_tail: []const u8,
    stderr_tail: []const u8,
    stdout_truncated: bool,
    stderr_truncated: bool,
    created_sequence: u64,
    updated_sequence: u64,
};

/// Runtime-owned task state bridge used by server task handlers.
pub const State = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Backing state remains runtime-owned; the adapter only calls through this vtable.
    pub const VTable = struct {
        job_count: *const fn (*anyopaque) usize,
        job_at: *const fn (*anyopaque, usize) ?JobView,
        job_by_id: *const fn (*anyopaque, []const u8) ?JobView,
        cancel_job: *const fn (*anyopaque, []const u8, []const u8) ?JobView,
    };

    /// Wraps a runtime task store without taking ownership of it.
    pub fn init(backing: anytype) State {
        const BackingPtr = @TypeOf(backing);
        return .{
            .ptr = backing,
            .vtable = &.{
                .job_count = struct {
                    /// Bridges the typed helper into the callback signature expected by the MCP adapter.
                    fn call(ptr: *anyopaque) usize {
                        const state: BackingPtr = @ptrCast(@alignCast(ptr));
                        return state.job_count;
                    }
                }.call,
                .job_at = struct {
                    /// Bridges the typed helper into the callback signature expected by the MCP adapter.
                    fn call(ptr: *anyopaque, index: usize) ?JobView {
                        const state: BackingPtr = @ptrCast(@alignCast(ptr));
                        if (index >= state.job_count) return null;
                        return jobView(&state.jobs[index]);
                    }
                }.call,
                .job_by_id = struct {
                    /// Bridges the typed helper into the callback signature expected by the MCP adapter.
                    fn call(ptr: *anyopaque, id: []const u8) ?JobView {
                        const state: BackingPtr = @ptrCast(@alignCast(ptr));
                        const job = state.jobById(id) orelse return null;
                        return jobView(job);
                    }
                }.call,
                .cancel_job = struct {
                    /// Bridges the typed helper into the callback signature expected by the MCP adapter.
                    fn call(ptr: *anyopaque, id: []const u8, reason: []const u8) ?JobView {
                        const state: BackingPtr = @ptrCast(@alignCast(ptr));
                        const job = state.cancelJob(id, reason) orelse return null;
                        return jobView(job);
                    }
                }.call,
            },
        };
    }

    /// Returns the number of retained jobs.
    pub fn jobCount(self: State) usize {
        return self.vtable.job_count(self.ptr);
    }

    /// Returns a borrowed job view by list index.
    pub fn jobAt(self: State, index: usize) ?JobView {
        return self.vtable.job_at(self.ptr, index);
    }

    /// Returns a borrowed job view by task/job id.
    pub fn jobById(self: State, id: []const u8) ?JobView {
        return self.vtable.job_by_id(self.ptr, id);
    }

    /// Requests runtime cancellation and returns the updated job when found.
    pub fn cancelJob(self: State, id: []const u8, reason: []const u8) ?JobView {
        return self.vtable.cancel_job(self.ptr, id, reason);
    }
};

/// Projects a concrete runtime job into the protocol-facing borrowed view.
fn jobView(job: anytype) JobView {
    return .{
        .id = job.id.slice(),
        .label = job.label.slice(),
        .status = job.status.text(),
        .ok = job.ok,
        .stdout_tail = job.stdout_tail.slice(),
        .stderr_tail = job.stderr_tail.slice(),
        .stdout_truncated = job.stdout_truncated,
        .stderr_truncated = job.stderr_truncated,
        .created_sequence = job.created_sequence,
        .updated_sequence = job.updated_sequence,
    };
}

/// Handles tasks/get for a single retained runtime job.
pub fn handleGet(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    const state = server.task_state orelse return server.sendInvalidParams(io, allocator, request.id, "Tasks are not enabled");
    const task_id = taskIdFromParams(request.params) orelse return server.sendInvalidParams(io, allocator, request.id, "tasks/get requires params.taskId");
    const job = state.jobById(task_id) orelse return server.sendInvalidParams(io, allocator, request.id, "Task not found");
    try sendTask(server, io, allocator, request.id, job);
}

/// Handles tasks/result with task metadata and retained stdout/stderr tails.
pub fn handleResult(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    const state = server.task_state orelse return server.sendInvalidParams(io, allocator, request.id, "Tasks are not enabled");
    const task_id = taskIdFromParams(request.params) orelse return server.sendInvalidParams(io, allocator, request.id, "tasks/result requires params.taskId");
    const job = state.jobById(task_id) orelse return server.sendInvalidParams(io, allocator, request.id, "Task not found");

    var response_arena = std.heap.ArenaAllocator.init(allocator);
    defer response_arena.deinit();
    const a = response_arena.allocator();
    var result: std.json.ObjectMap = .empty;
    try result.put(a, "task", try taskValue(a, job));
    try result.put(a, "job_id", .{ .string = job.id });
    try result.put(a, "status", .{ .string = job.status });
    try result.put(a, "ok", .{ .bool = job.ok });
    try result.put(a, "stdout_tail", .{ .string = job.stdout_tail });
    try result.put(a, "stderr_tail", .{ .string = job.stderr_tail });
    try result.put(a, "stdout_truncated", .{ .bool = job.stdout_truncated });
    try result.put(a, "stderr_truncated", .{ .bool = job.stderr_truncated });
    try server.sendResponse(io, allocator, .{ .response = jsonrpc.createResponse(request.id, .{ .object = result }) });
}

/// Handles tasks/list with optional cursor pagination.
pub fn handleList(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    const state = server.task_state orelse return server.sendInvalidParams(io, allocator, request.id, "Tasks are not enabled");
    var response_arena = std.heap.ArenaAllocator.init(allocator);
    defer response_arena.deinit();
    const a = response_arena.allocator();
    const page = pagination.fromParams(request.params);

    var tasks = std.json.Array.init(a);
    const job_count = state.jobCount();
    var index: usize = 0;
    while (index < job_count) : (index += 1) {
        if (!pagination.shouldIncludeIndex(page, index)) continue;
        const job = state.jobAt(index) orelse continue;
        try tasks.append(try taskValue(a, job));
    }

    var result: std.json.ObjectMap = .empty;
    try result.put(a, "tasks", .{ .array = tasks });
    try pagination.maybePutNextCursor(a, &result, page, job_count);
    try server.sendResponse(io, allocator, .{ .response = jsonrpc.createResponse(request.id, .{ .object = result }) });
}

/// Handles tasks/cancel and forwards the side effect to runtime job state.
pub fn handleCancel(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    const state = server.task_state orelse return server.sendInvalidParams(io, allocator, request.id, "Tasks are not enabled");
    const task_id = taskIdFromParams(request.params) orelse return server.sendInvalidParams(io, allocator, request.id, "tasks/cancel requires params.taskId");
    const job = state.cancelJob(task_id, "tasks/cancel") orelse return server.sendInvalidParams(io, allocator, request.id, "Task not found");
    try sendTask(server, io, allocator, request.id, job);
}

/// Sends a task view as a JSON-RPC result with response-arena-owned fields.
fn sendTask(server: anytype, io: std.Io, allocator: std.mem.Allocator, id: mcp.types.RequestId, job: JobView) !void {
    var response_arena = std.heap.ArenaAllocator.init(allocator);
    defer response_arena.deinit();
    const a = response_arena.allocator();
    try server.sendResponse(io, allocator, .{ .response = jsonrpc.createResponse(id, try taskValue(a, job)) });
}

/// Reads `task_id` from JSON-RPC task params when present and string-typed.
fn taskIdFromParams(params: ?std.json.Value) ?[]const u8 {
    const obj = switch (params orelse .null) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get("taskId") orelse .null) {
        .string => |s| s,
        else => null,
    };
}

/// Builds the MCP task JSON object for status polling.
fn taskValue(allocator: std.mem.Allocator, job: JobView) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "taskId", .{ .string = job.id });
    try obj.put(allocator, "status", .{ .string = taskStatusText(job.status) });
    try obj.put(allocator, "statusMessage", .{ .string = job.label });
    try obj.put(allocator, "createdAt", .{ .string = try std.fmt.allocPrint(allocator, "process-sequence-{d}", .{job.created_sequence}) });
    try obj.put(allocator, "lastUpdatedAt", .{ .string = try std.fmt.allocPrint(allocator, "process-sequence-{d}", .{job.updated_sequence}) });
    try obj.put(allocator, "ttl", .null);
    try obj.put(allocator, "pollInterval", .{ .integer = 500 });
    return .{ .object = obj };
}

/// Normalizes internal task status strings for MCP progress responses.
fn taskStatusText(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "queued") or std.mem.eql(u8, status, "running")) return "working";
    return status;
}

test "task value maps queued and running status to working" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const queued = try taskValue(allocator, .{
        .id = "queued-job",
        .label = "Queued job",
        .status = "queued",
        .ok = true,
        .stdout_tail = "",
        .stderr_tail = "",
        .stdout_truncated = false,
        .stderr_truncated = false,
        .created_sequence = 10,
        .updated_sequence = 11,
    });
    try std.testing.expectEqualStrings("working", queued.object.get("status").?.string);
    try std.testing.expectEqualStrings("process-sequence-10", queued.object.get("createdAt").?.string);
    try std.testing.expectEqual(@as(i64, 500), queued.object.get("pollInterval").?.integer);

    const completed = try taskValue(allocator, .{
        .id = "done-job",
        .label = "Done job",
        .status = "completed",
        .ok = true,
        .stdout_tail = "",
        .stderr_tail = "",
        .stdout_truncated = false,
        .stderr_truncated = false,
        .created_sequence = 12,
        .updated_sequence = 13,
    });
    try std.testing.expectEqualStrings("completed", completed.object.get("status").?.string);
    try std.testing.expectEqualStrings("working", taskStatusText("running"));
}
