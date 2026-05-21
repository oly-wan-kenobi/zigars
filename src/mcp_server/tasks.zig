const std = @import("std");
const mcp = @import("mcp");

const jsonrpc = mcp.jsonrpc;
const pagination = @import("pagination.zig");
const runtime_ux = @import("../runtime_ux.zig");

pub fn handleGet(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    const state = server.task_state orelse return server.sendInvalidParams(io, allocator, request.id, "Tasks are not enabled");
    const task_id = taskIdFromParams(request.params) orelse return server.sendInvalidParams(io, allocator, request.id, "tasks/get requires params.taskId");
    const job = state.jobById(task_id) orelse return server.sendInvalidParams(io, allocator, request.id, "Task not found");
    try sendTask(server, io, allocator, request.id, job);
}

pub fn handleResult(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    const state = server.task_state orelse return server.sendInvalidParams(io, allocator, request.id, "Tasks are not enabled");
    const task_id = taskIdFromParams(request.params) orelse return server.sendInvalidParams(io, allocator, request.id, "tasks/result requires params.taskId");
    const job = state.jobById(task_id) orelse return server.sendInvalidParams(io, allocator, request.id, "Task not found");

    var response_arena = std.heap.ArenaAllocator.init(allocator);
    defer response_arena.deinit();
    const a = response_arena.allocator();
    var result: std.json.ObjectMap = .empty;
    try result.put(a, "task", try taskValue(a, job));
    try result.put(a, "job_id", .{ .string = job.id.slice() });
    try result.put(a, "status", .{ .string = job.status.text() });
    try result.put(a, "ok", .{ .bool = job.ok });
    try result.put(a, "stdout_tail", .{ .string = job.stdout_tail.slice() });
    try result.put(a, "stderr_tail", .{ .string = job.stderr_tail.slice() });
    try result.put(a, "stdout_truncated", .{ .bool = job.stdout_truncated });
    try result.put(a, "stderr_truncated", .{ .bool = job.stderr_truncated });
    try server.sendResponse(io, allocator, .{ .response = jsonrpc.createResponse(request.id, .{ .object = result }) });
}

pub fn handleList(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    const state = server.task_state orelse return server.sendInvalidParams(io, allocator, request.id, "Tasks are not enabled");
    var response_arena = std.heap.ArenaAllocator.init(allocator);
    defer response_arena.deinit();
    const a = response_arena.allocator();
    const page = pagination.fromParams(request.params);

    var tasks = std.json.Array.init(a);
    for (state.jobs[0..state.job_count], 0..) |*job, index| {
        if (!pagination.shouldIncludeIndex(page, index)) continue;
        try tasks.append(try taskValue(a, job));
    }

    var result: std.json.ObjectMap = .empty;
    try result.put(a, "tasks", .{ .array = tasks });
    try pagination.maybePutNextCursor(a, &result, page, state.job_count);
    try server.sendResponse(io, allocator, .{ .response = jsonrpc.createResponse(request.id, .{ .object = result }) });
}

pub fn handleCancel(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    const state = server.task_state orelse return server.sendInvalidParams(io, allocator, request.id, "Tasks are not enabled");
    const task_id = taskIdFromParams(request.params) orelse return server.sendInvalidParams(io, allocator, request.id, "tasks/cancel requires params.taskId");
    const job = state.cancelJob(task_id, "tasks/cancel") orelse return server.sendInvalidParams(io, allocator, request.id, "Task not found");
    try sendTask(server, io, allocator, request.id, job);
}

fn sendTask(server: anytype, io: std.Io, allocator: std.mem.Allocator, id: mcp.types.RequestId, job: *const runtime_ux.JobRecord) !void {
    var response_arena = std.heap.ArenaAllocator.init(allocator);
    defer response_arena.deinit();
    const a = response_arena.allocator();
    try server.sendResponse(io, allocator, .{ .response = jsonrpc.createResponse(id, try taskValue(a, job)) });
}

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

fn taskValue(allocator: std.mem.Allocator, job: *const runtime_ux.JobRecord) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "taskId", .{ .string = job.id.slice() });
    try obj.put(allocator, "status", .{ .string = taskStatusText(job.status) });
    try obj.put(allocator, "statusMessage", .{ .string = job.label.slice() });
    try obj.put(allocator, "createdAt", .{ .string = try std.fmt.allocPrint(allocator, "process-sequence-{d}", .{job.created_sequence}) });
    try obj.put(allocator, "lastUpdatedAt", .{ .string = try std.fmt.allocPrint(allocator, "process-sequence-{d}", .{job.updated_sequence}) });
    try obj.put(allocator, "ttl", .null);
    try obj.put(allocator, "pollInterval", .{ .integer = 500 });
    return .{ .object = obj };
}

fn taskStatusText(status: runtime_ux.JobStatus) []const u8 {
    return switch (status) {
        .queued, .running => "working",
        .completed => "completed",
        .failed => "failed",
        .cancelled => "cancelled",
    };
}
