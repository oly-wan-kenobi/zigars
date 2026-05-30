//! Tests for MCP tasks/* method routing (tasks/list, tasks/get, tasks/result,
//! tasks/cancel) through a server with and without task support enabled.
//! Pins that missing task support returns a structured error, that pagination
//! cursors advance correctly, and that cancel propagates the cancellation reason.

const std = @import("std");
const mcp = @import("mcp");

const server_mod = @import("../../adapters/mcp/server.zig");

const Server = server_mod.Server;

/// Scripted transport that feeds task requests and records outgoing responses.
const ScriptTransport = struct {
    messages: []const []const u8,
    index: usize = 0,
    sent: std.ArrayList([]const u8) = .empty,

    /// Releases owned allocations/resources; callers must not use the value afterward.
    fn deinit(self: *ScriptTransport, allocator: std.mem.Allocator) void {
        for (self.sent.items) |message| allocator.free(message);
        self.sent.deinit(allocator);
    }

    /// Returns the transport vtable used by this test double.
    fn transport(self: *ScriptTransport) mcp.transport.Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = sendVtable,
                .receive = receiveVtable,
                .close = closeVtable,
            },
        };
    }

    /// Sends a JSON-RPC message through the transport vtable.
    fn sendVtable(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator, message: []const u8) mcp.transport.Transport.SendError!void {
        const self: *ScriptTransport = @ptrCast(@alignCast(ptr));
        const owned = allocator.dupe(u8, message) catch return error.OutOfMemory;
        self.sent.append(allocator, owned) catch {
            allocator.free(owned);
            return error.OutOfMemory;
        };
    }

    /// Receives a JSON-RPC message through the transport vtable.
    fn receiveVtable(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator) mcp.transport.Transport.ReceiveError!?[]const u8 {
        const self: *ScriptTransport = @ptrCast(@alignCast(ptr));
        if (self.index >= self.messages.len) return error.EndOfStream;
        const message = self.messages[self.index];
        self.index += 1;
        return message;
    }

    /// Closes the transport through the transport vtable.
    fn closeVtable(_: *anyopaque) void {}
};

test "task script transport frees messages when recording send fails" {
    var transport = ScriptTransport{ .messages = &.{} };
    defer transport.deinit(std.testing.allocator);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, transport.transport().send(std.testing.io, failing.allocator(), "message"));
    transport.transport().close();
}

/// Joins captured transport sends into a single owned buffer.
fn joinedSent(allocator: std.mem.Allocator, transport: *ScriptTransport) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (transport.sent.items) |message| {
        try out.appendSlice(allocator, message);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

/// Borrowed job slice wrapper used by the task-state fixture.
const FixtureSlice = struct {
    value: []const u8,

    /// Returns the borrowed fixture job slice.
    pub fn slice(self: FixtureSlice) []const u8 {
        return self.value;
    }
};

/// Borrowed task status text exposed through the job view.
const FixtureStatus = struct {
    value: []const u8,

    /// Returns borrowed catalog text for this entry.
    pub fn text(self: FixtureStatus) []const u8 {
        return self.value;
    }
};

/// Static task job fixture returned by ID and index lookups.
const FixtureJob = struct {
    id: FixtureSlice,
    label: FixtureSlice,
    status: FixtureStatus,
    ok: bool,
    stdout_tail: FixtureSlice,
    stderr_tail: FixtureSlice,
    stdout_truncated: bool,
    stderr_truncated: bool,
    created_sequence: u64,
    updated_sequence: u64,
};

/// Task state facade used to exercise task list, get, and cancel handlers.
const FixtureTaskState = struct {
    jobs: [3]FixtureJob,
    job_count: usize,
    canceled_reason: ?[]const u8 = null,

    /// Returns a runtime job snapshot by identifier.
    pub fn jobById(self: *FixtureTaskState, id: []const u8) ?*FixtureJob {
        for (self.jobs[0..self.job_count]) |*job| {
            if (std.mem.eql(u8, job.id.value, id)) return job;
        }
        return null;
    }

    /// Cancels a runtime job and records its event.
    pub fn cancelJob(self: *FixtureTaskState, id: []const u8, reason: []const u8) ?*FixtureJob {
        const job = self.jobById(id) orelse return null;
        self.canceled_reason = reason;
        job.status = .{ .value = "cancelled" };
        job.ok = false;
        return job;
    }
};

/// Builds a task-state facade backed by static fixture jobs.
fn fixtureTaskState() FixtureTaskState {
    return .{
        .jobs = .{
            .{
                .id = .{ .value = "job-1" },
                .label = .{ .value = "Compile" },
                .status = .{ .value = "queued" },
                .ok = true,
                .stdout_tail = .{ .value = "stdout 1" },
                .stderr_tail = .{ .value = "" },
                .stdout_truncated = false,
                .stderr_truncated = false,
                .created_sequence = 1,
                .updated_sequence = 2,
            },
            .{
                .id = .{ .value = "job-2" },
                .label = .{ .value = "Test" },
                .status = .{ .value = "running" },
                .ok = true,
                .stdout_tail = .{ .value = "stdout 2" },
                .stderr_tail = .{ .value = "stderr 2" },
                .stdout_truncated = true,
                .stderr_truncated = true,
                .created_sequence = 3,
                .updated_sequence = 4,
            },
            .{
                .id = .{ .value = "job-3" },
                .label = .{ .value = "Done" },
                .status = .{ .value = "completed" },
                .ok = true,
                .stdout_tail = .{ .value = "done" },
                .stderr_tail = .{ .value = "" },
                .stdout_truncated = false,
                .stderr_truncated = false,
                .created_sequence = 5,
                .updated_sequence = 6,
            },
        },
        .job_count = 3,
    };
}

test "Server routes MCP tasks through retained job state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = fixtureTaskState();
    var server: Server = .init(allocator, .{
        .name = "task-server",
        .version = "1.0.0",
    });
    defer server.deinit();
    server.enableTasks(&state);

    const state_view = server.task_state.?;
    try std.testing.expectEqual(@as(usize, 3), state_view.jobCount());
    try std.testing.expectEqualStrings("job-1", state_view.jobAt(0).?.id);
    try std.testing.expect(state_view.jobAt(99) == null);
    try std.testing.expectEqualStrings("job-2", state_view.jobById("job-2").?.id);
    try std.testing.expectEqualStrings("cancelled", state_view.cancelJob("job-3", "direct").?.status);
    try std.testing.expect(state_view.cancelJob("missing", "direct") == null);

    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"tester\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tasks/list\",\"params\":{\"cursor\":\"1\",\"limit\":1}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tasks/get\",\"params\":{\"taskId\":\"job-1\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tasks/result\",\"params\":{\"taskId\":\"job-2\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tasks/cancel\",\"params\":{\"taskId\":\"job-2\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tasks/get\",\"params\":{\"taskId\":\"missing\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tasks/result\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tasks/cancel\",\"params\":{\"taskId\":42}}",
    };
    var transport: ScriptTransport = .{ .messages = messages[0..] };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());

    const sent = try joinedSent(allocator, &transport);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"tasks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"requests\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"nextCursor\":\"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"taskId\":\"job-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"job_id\":\"job-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"stdout_truncated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"status\":\"cancelled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "Task not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "tasks/result requires params.taskId") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "tasks/cancel requires params.taskId") != null);
    try std.testing.expectEqualStrings("tasks/cancel", state.canceled_reason.?);
}

test "Server task methods reject missing task support" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = .init(allocator, .{
        .name = "taskless-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"tester\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tasks/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tasks/get\",\"params\":{\"taskId\":\"job\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tasks/result\",\"params\":{\"taskId\":\"job\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tasks/cancel\",\"params\":{\"taskId\":\"job\"}}",
    };
    var transport: ScriptTransport = .{ .messages = messages[0..] };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());

    const sent = try joinedSent(allocator, &transport);
    try std.testing.expect(std.mem.indexOf(u8, sent, "Tasks are not enabled") != null);
}
