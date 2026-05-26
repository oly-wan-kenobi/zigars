//! In-memory runtime-session fake for MCP/runtime tests.
//! It models jobs, events, subscriptions, and workspace roots in one fixture.

const std = @import("std");

const ports = @import("../../app/ports.zig");

/// Runtime session fake that records submitted jobs and lifecycle events.
pub const FakeRuntimeSession = struct {
    jobs: std.ArrayList(ports.RuntimeJobSnapshot) = .empty,
    events: std.ArrayList(ports.RuntimeEventSnapshot) = .empty,
    roots: std.ArrayList(ports.RuntimeRootSnapshot) = .empty,
    subscriptions: std.ArrayList(ports.RuntimeSubscriptionSnapshot) = .empty,
    owned_strings: std.ArrayList([]const u8) = .empty,
    next_job: u64 = 1,
    next_subscription: u64 = 1,
    selected_root: usize = 0,

    /// Releases owned allocations/resources; callers must not use the value afterward.
    pub fn deinit(self: *FakeRuntimeSession, allocator: std.mem.Allocator) void {
        self.jobs.deinit(allocator);
        self.events.deinit(allocator);
        self.roots.deinit(allocator);
        self.subscriptions.deinit(allocator);
        for (self.owned_strings.items) |value| allocator.free(value);
        self.owned_strings.deinit(allocator);
    }

    /// Exposes this implementation through its application port vtable.
    pub fn port(self: *FakeRuntimeSession) ports.RuntimeSession {
        return .{
            .ptr = self,
            .vtable = &.{
                .ensure_default_root = ensureDefaultRoot,
                .start_job = startJob,
                .finish_job = finishJob,
                .fail_job = failJob,
                .cancel_job = cancelJob,
                .job_by_id = jobById,
                .job_count = jobCount,
                .job_at = jobAt,
                .event_count = eventCount,
                .event_at_sequence = eventAtSequence,
                .subscribe = subscribe,
                .unsubscribe = unsubscribe,
                .sync_roots = syncRoots,
                .select_root = selectRoot,
                .root_count = rootCount,
                .selected_root_index = selectedRootIndex,
                .root_at = rootAt,
            },
        };
    }

    /// Ensures runtime state has a default workspace root.
    fn ensureDefaultRoot(ptr: *anyopaque, workspace_root: []const u8) ports.PortError!void {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        if (self.roots.items.len > 0) return;
        try self.roots.append(std.testing.allocator, try self.rootSnapshot("root-1", workspace_root, true));
        self.selected_root = 0;
    }

    /// Starts a runtime job and records its initial event.
    fn startJob(ptr: *anyopaque, label: []const u8, command_text: []const u8, timeout_ms: i64) ports.PortError!ports.RuntimeJobSnapshot {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        const id = try self.allocPrint("job-{d}", .{self.next_job});
        self.next_job += 1;
        const job = ports.RuntimeJobSnapshot{
            .id = id,
            .label = label,
            .command = command_text,
            .status = .running,
            .ok = false,
            .created_sequence = @intCast(self.events.items.len + 1),
            .updated_sequence = @intCast(self.events.items.len + 1),
            .duration_ms = 0,
            .timeout_ms = timeout_ms,
            .term = "",
            .exit_code = null,
            .stdout_tail = "",
            .stderr_tail = "",
            .stdout_truncated = false,
            .stderr_truncated = false,
            .cancellation_requested = false,
            .cancellation_reason = "",
        };
        try self.jobs.append(std.testing.allocator, job);
        try self.appendEvent(job.id, "started", "", "job started", "");
        return self.jobs.items[self.jobs.items.len - 1];
    }

    /// Marks a runtime job complete and records its event.
    fn finishJob(ptr: *anyopaque, job_id: []const u8, finish: ports.RuntimeJobFinish) ports.PortError!ports.RuntimeJobSnapshot {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        const job = self.jobPtr(job_id) orelse return error.NotFound;
        job.status = finish.status;
        job.ok = finish.ok;
        job.duration_ms = finish.duration_ms;
        job.term = finish.term;
        job.exit_code = finish.exit_code;
        job.stdout_tail = finish.stdout_tail;
        job.stderr_tail = finish.stderr_tail;
        job.stdout_truncated = finish.stdout_truncated;
        job.stderr_truncated = finish.stderr_truncated;
        try self.appendEvent(job.id, "finished", "", "job finished", "");
        return job.*;
    }

    /// Marks a runtime job failed and records its event.
    fn failJob(ptr: *anyopaque, job_id: []const u8, err_name: []const u8, duration_ms: i64) ports.PortError!ports.RuntimeJobSnapshot {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        const job = self.jobPtr(job_id) orelse return error.NotFound;
        job.status = .failed;
        job.ok = false;
        job.duration_ms = duration_ms;
        job.stderr_tail = err_name;
        try self.appendEvent(job.id, "failed", "stderr", err_name, err_name);
        return job.*;
    }

    /// Cancels a runtime job and records its event.
    fn cancelJob(ptr: *anyopaque, job_id: []const u8, reason: []const u8) ports.PortError!ports.RuntimeJobSnapshot {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        const job = self.jobPtr(job_id) orelse return error.NotFound;
        job.cancellation_requested = true;
        job.cancellation_reason = reason;
        if (!job.status.terminal()) job.status = .cancelled;
        try self.appendEvent(job.id, "cancelled", "", reason, reason);
        return job.*;
    }

    /// Returns a runtime job snapshot by identifier.
    fn jobById(ptr: *anyopaque, job_id: []const u8) ports.PortError!ports.RuntimeJobSnapshot {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        return (self.jobPtr(job_id) orelse return error.NotFound).*;
    }

    /// Returns the number of tracked runtime jobs.
    fn jobCount(ptr: *anyopaque) ports.PortError!usize {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        return self.jobs.items.len;
    }

    /// Returns a runtime job snapshot by index.
    fn jobAt(ptr: *anyopaque, index: usize) ports.PortError!ports.RuntimeJobSnapshot {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        if (index >= self.jobs.items.len) return error.NotFound;
        return self.jobs.items[index];
    }

    /// Returns the number of recorded runtime events.
    fn eventCount(ptr: *anyopaque) ports.PortError!u64 {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        return @intCast(self.events.items.len);
    }

    /// Returns a runtime event by sequence number.
    fn eventAtSequence(ptr: *anyopaque, sequence: u64) ports.PortError!ports.RuntimeEventSnapshot {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        if (sequence == 0 or sequence > self.events.items.len) return error.NotFound;
        return self.events.items[@intCast(sequence - 1)];
    }

    /// Registers a runtime event subscription.
    fn subscribe(ptr: *anyopaque, uri: []const u8) ports.PortError!ports.RuntimeSubscriptionSnapshot {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        const id = try self.allocPrint("sub-{d}", .{self.next_subscription});
        self.next_subscription += 1;
        const sub = ports.RuntimeSubscriptionSnapshot{ .id = id, .uri = uri, .active = true, .created_sequence = @intCast(self.events.items.len + 1) };
        try self.subscriptions.append(std.testing.allocator, sub);
        return sub;
    }

    /// Removes a runtime event subscription.
    fn unsubscribe(ptr: *anyopaque, id: []const u8, uri: ?[]const u8) ports.PortError!ports.RuntimeSubscriptionSnapshot {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        for (self.subscriptions.items) |*sub| {
            if ((id.len > 0 and std.mem.eql(u8, sub.id, id)) or (uri != null and std.mem.eql(u8, sub.uri, uri.?))) {
                sub.active = false;
                return sub.*;
            }
        }
        return error.NotFound;
    }

    /// Synchronizes workspace roots with runtime state.
    fn syncRoots(ptr: *anyopaque, workspace_root: []const u8, roots_text: []const u8, apply: bool) ports.PortError!void {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        if (!apply) return;
        self.roots.clearRetainingCapacity();
        var tokens = std.mem.tokenizeAny(u8, roots_text, "\n\r\t ");
        var count: usize = 0;
        while (tokens.next()) |token| {
            count += 1;
            // Accept both plain paths and file:// URIs to mirror client payloads.
            const path = if (std.mem.startsWith(u8, token, "file://")) token["file://".len..] else token;
            const id = try self.allocPrint("root-{d}", .{count});
            try self.roots.append(std.testing.allocator, try self.rootSnapshot(id, path, count == 1));
        }
        if (self.roots.items.len == 0) try self.roots.append(std.testing.allocator, try self.rootSnapshot("root-1", workspace_root, true));
        // Sync always resets selection to the first root to keep deterministic state.
        self.selected_root = 0;
    }

    /// Selects the active runtime root.
    fn selectRoot(ptr: *anyopaque, root_id: []const u8, apply: bool) ports.PortError!ports.RuntimeRootSnapshot {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        for (self.roots.items, 0..) |*root, index| {
            if (std.mem.eql(u8, root.id, root_id) or std.mem.eql(u8, root.path, root_id)) {
                if (apply) {
                    for (self.roots.items) |*item| item.selected = false;
                    root.selected = true;
                    self.selected_root = index;
                }
                return root.*;
            }
        }
        return error.NotFound;
    }

    /// Returns the number of tracked runtime roots.
    fn rootCount(ptr: *anyopaque) ports.PortError!usize {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        return self.roots.items.len;
    }

    /// Returns the selected runtime root index.
    fn selectedRootIndex(ptr: *anyopaque) ports.PortError!usize {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        return self.selected_root;
    }

    /// Returns a runtime root snapshot by index.
    fn rootAt(ptr: *anyopaque, index: usize) ports.PortError!ports.RuntimeRootSnapshot {
        const self: *FakeRuntimeSession = @ptrCast(@alignCast(ptr));
        if (index >= self.roots.items.len) return error.NotFound;
        return self.roots.items[index];
    }

    /// Returns mutable state for a tracked runtime job.
    fn jobPtr(self: *FakeRuntimeSession, job_id: []const u8) ?*ports.RuntimeJobSnapshot {
        for (self.jobs.items) |*job| {
            if (std.mem.eql(u8, job.id, job_id)) return job;
        }
        return null;
    }

    /// Appends a lifecycle event and assigns its sequence number.
    fn appendEvent(self: *FakeRuntimeSession, job_id: []const u8, event: []const u8, stream: []const u8, message: []const u8, text: []const u8) ports.PortError!void {
        try self.events.append(std.testing.allocator, .{
            .sequence = @intCast(self.events.items.len + 1),
            .job_id = job_id,
            .event = event,
            .stream = stream,
            .message = message,
            .text = text,
            .elapsed_ms = 0,
        });
    }

    /// Builds an allocator-owned snapshot of a runtime root.
    fn rootSnapshot(self: *FakeRuntimeSession, id: []const u8, path: []const u8, selected: bool) ports.PortError!ports.RuntimeRootSnapshot {
        const uri = try self.allocPrint("file://{s}", .{path});
        return .{
            .id = id,
            .path = path,
            .uri = uri,
            .name = std.fs.path.basename(path),
            .selected = selected,
        };
    }

    /// Formats test-owned text with the fake allocator.
    fn allocPrint(self: *FakeRuntimeSession, comptime fmt: []const u8, args: anytype) ports.PortError![]const u8 {
        const value = std.fmt.allocPrint(std.testing.allocator, fmt, args) catch return error.OutOfMemory;
        var value_owned = true;
        defer if (value_owned) std.testing.allocator.free(value);
        try self.owned_strings.append(std.testing.allocator, value);
        value_owned = false;
        return value;
    }
};

test "fake runtime session covers job and root state" {
    var fake = FakeRuntimeSession{};
    defer fake.deinit(std.testing.allocator);
    const port = fake.port();

    try port.ensureDefaultRoot("/repo");
    const job = try port.startJob("check", "zig ast-check src/main.zig", 1000);
    _ = try port.finishJob(job.id, .{
        .status = .completed,
        .ok = true,
        .duration_ms = 5,
        .term = "exited",
        .exit_code = 0,
        .stdout_tail = "",
        .stderr_tail = "",
        .stdout_truncated = false,
        .stderr_truncated = false,
    });

    try std.testing.expectEqual(@as(usize, 1), try port.jobCount());
    try std.testing.expectEqual(@as(u64, 2), try port.eventCount());
    try std.testing.expectEqualStrings("/repo", (try port.rootAt(0)).path);
    try std.testing.expectError(error.NotFound, port.jobById("missing-job"));
}
