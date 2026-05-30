//! MCP tasks capability bridge over runtime job state, cancellation, and progress views.
const std = @import("std");
const mcp = @import("mcp");

const jsonrpc = mcp.jsonrpc;
const pagination = @import("pagination.zig");

/// Borrowed snapshot of a runtime job for MCP task endpoints. All slices point
/// into runtime-owned job storage; copy anything that must outlive the handler
/// call, since the backing ring slot may be reused by later jobs.
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
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Orders task views oldest-first by their monotonic creation sequence.
fn lessByCreatedSequence(_: void, lhs: JobView, rhs: JobView) bool {
    return lhs.created_sequence < rhs.created_sequence;
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
    // Translate internal outcomes into protocol-facing responses without leaking internal details.
    const state = server.task_state orelse return server.sendInvalidParams(io, allocator, request.id, "Tasks are not enabled");
    const task_id = taskIdFromParams(request.params) orelse return server.sendInvalidParams(io, allocator, request.id, "tasks/result requires params.taskId");
    const job = state.jobById(task_id) orelse return server.sendInvalidParams(io, allocator, request.id, "Task not found");

    var response_arena = std.heap.ArenaAllocator.init(allocator);
    defer response_arena.deinit();
    const a = response_arena.allocator();
    try server.sendResponse(io, allocator, .{ .response = jsonrpc.createResponse(request.id, try resultValue(a, job)) });
}

/// Handles tasks/list with optional cursor pagination.
pub fn handleList(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    const state = server.task_state orelse return server.sendInvalidParams(io, allocator, request.id, "Tasks are not enabled");
    var response_arena = std.heap.ArenaAllocator.init(allocator);
    defer response_arena.deinit();
    const a = response_arena.allocator();
    const page = pagination.fromParams(request.params) catch return server.sendInvalidParams(io, allocator, request.id, pagination.invalid_cursor_message);

    // Collect retained jobs, then order by created_sequence so the list reads
    // oldest-to-newest regardless of the ring's physical slot rotation.
    const job_count = state.jobCount();
    var jobs = try std.ArrayList(JobView).initCapacity(a, job_count);
    var collected: usize = 0;
    while (collected < job_count) : (collected += 1) {
        if (state.jobAt(collected)) |job| jobs.appendAssumeCapacity(job);
    }
    std.mem.sort(JobView, jobs.items, {}, lessByCreatedSequence);

    var tasks = std.json.Array.init(a);
    for (jobs.items, 0..) |job, index| {
        if (!pagination.shouldIncludeIndex(page, index)) continue;
        try tasks.append(try taskValue(a, job));
    }

    var result: std.json.ObjectMap = .empty;
    try result.put(a, "tasks", .{ .array = tasks });
    try pagination.maybePutNextCursor(a, &result, page, jobs.items.len);
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
    // Keep this logic centralized so callers observe one consistent behavior path.
    const obj = switch (params orelse .null) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get("taskId") orelse .null) {
        .string => |s| s,
        else => null,
    };
}

/// Builds the MCP task JSON object for status polling. Timestamps are reported
/// as synthetic `process-sequence-{n}` strings rather than wall-clock values:
/// jobs are tracked by monotonic sequence, keeping output deterministic.
/// `pollInterval` is a fixed client hint (ms) and `ttl` is left null (no expiry).
fn taskValue(allocator: std.mem.Allocator, job: JobView) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Builds the tasks/result payload with retained tails and a normalized status.
fn resultValue(allocator: std.mem.Allocator, job: JobView) !std.json.Value {
    // The top-level `status` is normalized through the same mapping as
    // `task.status` so the two views never disagree; the raw "queued"/"running"
    // vocabulary previously leaked here and contradicted the normalized task.
    var result: std.json.ObjectMap = .empty;
    try result.put(allocator, "task", try taskValue(allocator, job));
    try result.put(allocator, "job_id", .{ .string = job.id });
    try result.put(allocator, "status", .{ .string = taskStatusText(job.status) });
    try result.put(allocator, "ok", .{ .bool = job.ok });
    try result.put(allocator, "stdout_tail", .{ .string = job.stdout_tail });
    try result.put(allocator, "stderr_tail", .{ .string = job.stderr_tail });
    try result.put(allocator, "stdout_truncated", .{ .bool = job.stdout_truncated });
    try result.put(allocator, "stderr_truncated", .{ .bool = job.stderr_truncated });
    return .{ .object = result };
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

test "tasks/result top-level status agrees with normalized task status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A running job: raw status "running" must surface as "working" both at the
    // top level and inside `task`, never the conflicting raw vocabulary.
    const running = try resultValue(allocator, .{
        .id = "job-7",
        .label = "Build",
        .status = "running",
        .ok = false,
        .stdout_tail = "partial",
        .stderr_tail = "",
        .stdout_truncated = false,
        .stderr_truncated = false,
        .created_sequence = 3,
        .updated_sequence = 4,
    });
    const top_status = running.object.get("status").?.string;
    const task_status = running.object.get("task").?.object.get("status").?.string;
    try std.testing.expectEqualStrings("working", top_status);
    try std.testing.expectEqualStrings(task_status, top_status);
    // The retained result payload still rides along under the same response.
    try std.testing.expectEqualStrings("job-7", running.object.get("job_id").?.string);
    try std.testing.expectEqualStrings("partial", running.object.get("stdout_tail").?.string);

    // A terminal job keeps its concrete status identically in both places.
    const failed = try resultValue(allocator, .{
        .id = "job-8",
        .label = "Test",
        .status = "failed",
        .ok = false,
        .stdout_tail = "",
        .stderr_tail = "boom",
        .stdout_truncated = false,
        .stderr_truncated = false,
        .created_sequence = 5,
        .updated_sequence = 6,
    });
    try std.testing.expectEqualStrings("failed", failed.object.get("status").?.string);
    try std.testing.expectEqualStrings("failed", failed.object.get("task").?.object.get("status").?.string);
}

test "tasks/list projection orders jobs by created_sequence" {
    // Physical ring slot order after wrap is not creation order; the projection
    // must sort by created_sequence so the list reads oldest-to-newest.
    var views = [_]JobView{
        .{ .id = "job-33", .label = "", .status = "completed", .ok = true, .stdout_tail = "", .stderr_tail = "", .stdout_truncated = false, .stderr_truncated = false, .created_sequence = 33, .updated_sequence = 33 },
        .{ .id = "job-3", .label = "", .status = "completed", .ok = true, .stdout_tail = "", .stderr_tail = "", .stdout_truncated = false, .stderr_truncated = false, .created_sequence = 3, .updated_sequence = 3 },
        .{ .id = "job-34", .label = "", .status = "running", .ok = false, .stdout_tail = "", .stderr_tail = "", .stdout_truncated = false, .stderr_truncated = false, .created_sequence = 34, .updated_sequence = 34 },
        .{ .id = "job-10", .label = "", .status = "completed", .ok = true, .stdout_tail = "", .stderr_tail = "", .stdout_truncated = false, .stderr_truncated = false, .created_sequence = 10, .updated_sequence = 10 },
    };

    std.mem.sort(JobView, &views, {}, lessByCreatedSequence);

    const expected_ids = [_][]const u8{ "job-3", "job-10", "job-33", "job-34" };
    for (views, expected_ids) |view, expected_id| {
        try std.testing.expectEqualStrings(expected_id, view.id);
    }
    var previous: u64 = 0;
    for (views) |view| {
        try std.testing.expect(view.created_sequence > previous);
        previous = view.created_sequence;
    }
}
