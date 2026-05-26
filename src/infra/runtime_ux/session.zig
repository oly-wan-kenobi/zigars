const std = @import("std");

const ports = @import("../../app/ports.zig");
const runtime_ux = @import("state.zig");

pub const Session = struct {
    state: *runtime_ux.State,

    const Self = @This();

    pub fn init(state: *runtime_ux.State) Self {
        return .{ .state = state };
    }

    pub fn port(self: *Self) ports.RuntimeSession {
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

    fn ensureDefaultRoot(ptr: *anyopaque, workspace_root: []const u8) ports.PortError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.state.ensureDefaultRoot(workspace_root);
    }

    fn startJob(ptr: *anyopaque, label: []const u8, command_text: []const u8, timeout_ms: i64) ports.PortError!ports.RuntimeJobSnapshot {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return jobSnapshot(self.state.startJob(label, command_text, timeout_ms));
    }

    fn finishJob(ptr: *anyopaque, job_id: []const u8, finish: ports.RuntimeJobFinish) ports.PortError!ports.RuntimeJobSnapshot {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const job = self.state.jobById(job_id) orelse return error.NotFound;
        self.state.finishJob(job, statusToRuntime(finish.status), finish.ok, finish.duration_ms, finish.term, finish.exit_code, finish.stdout_tail, finish.stderr_tail, finish.stdout_truncated, finish.stderr_truncated);
        return jobSnapshot(job);
    }

    fn failJob(ptr: *anyopaque, job_id: []const u8, err_name: []const u8, duration_ms: i64) ports.PortError!ports.RuntimeJobSnapshot {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const job = self.state.jobById(job_id) orelse return error.NotFound;
        self.state.failJob(job, err_name, duration_ms);
        return jobSnapshot(job);
    }

    fn cancelJob(ptr: *anyopaque, job_id: []const u8, reason: []const u8) ports.PortError!ports.RuntimeJobSnapshot {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const job = self.state.cancelJob(job_id, reason) orelse return error.NotFound;
        return jobSnapshot(job);
    }

    fn jobById(ptr: *anyopaque, job_id: []const u8) ports.PortError!ports.RuntimeJobSnapshot {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return jobSnapshot(self.state.jobById(job_id) orelse return error.NotFound);
    }

    fn jobCount(ptr: *anyopaque) ports.PortError!usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.state.job_count;
    }

    fn jobAt(ptr: *anyopaque, index: usize) ports.PortError!ports.RuntimeJobSnapshot {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (index >= self.state.job_count) return error.NotFound;
        return jobSnapshot(&self.state.jobs[index]);
    }

    fn eventCount(ptr: *anyopaque) ports.PortError!u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.state.event_count;
    }

    fn eventAtSequence(ptr: *anyopaque, sequence: u64) ports.PortError!ports.RuntimeEventSnapshot {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (sequence == 0) return error.NotFound;
        const first_available: u64 = if (self.state.event_count > runtime_ux.max_events) self.state.event_count - runtime_ux.max_events + 1 else 1;
        if (sequence < first_available or sequence > self.state.event_count) return error.NotFound;
        return eventSnapshot(&self.state.events[runtime_ux.ringIndex(sequence, runtime_ux.max_events)]);
    }

    fn subscribe(ptr: *anyopaque, uri: []const u8) ports.PortError!ports.RuntimeSubscriptionSnapshot {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return subscriptionSnapshot(self.state.subscribe(uri));
    }

    fn unsubscribe(ptr: *anyopaque, id: []const u8, uri: ?[]const u8) ports.PortError!ports.RuntimeSubscriptionSnapshot {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return subscriptionSnapshot(self.state.unsubscribe(id, uri) orelse return error.NotFound);
    }

    fn syncRoots(ptr: *anyopaque, workspace_root: []const u8, roots_text: []const u8, apply: bool) ports.PortError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.state.syncRoots(workspace_root, roots_text, apply);
    }

    fn selectRoot(ptr: *anyopaque, root_id: []const u8, apply: bool) ports.PortError!ports.RuntimeRootSnapshot {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return rootSnapshot(self.state.selectRoot(root_id, apply) orelse return error.NotFound);
    }

    fn rootCount(ptr: *anyopaque) ports.PortError!usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.state.root_count;
    }

    fn selectedRootIndex(ptr: *anyopaque) ports.PortError!usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.state.selected_root;
    }

    fn rootAt(ptr: *anyopaque, index: usize) ports.PortError!ports.RuntimeRootSnapshot {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (index >= self.state.root_count) return error.NotFound;
        return rootSnapshot(&self.state.roots[index]);
    }
};

fn jobSnapshot(job: *const runtime_ux.JobRecord) ports.RuntimeJobSnapshot {
    return .{
        .id = job.id.slice(),
        .label = job.label.slice(),
        .command = job.command.slice(),
        .status = statusFromRuntime(job.status),
        .ok = job.ok,
        .created_sequence = job.created_sequence,
        .updated_sequence = job.updated_sequence,
        .duration_ms = job.duration_ms,
        .timeout_ms = job.timeout_ms,
        .term = job.term.slice(),
        .exit_code = job.exit_code,
        .stdout_tail = job.stdout_tail.slice(),
        .stderr_tail = job.stderr_tail.slice(),
        .stdout_truncated = job.stdout_truncated,
        .stderr_truncated = job.stderr_truncated,
        .cancellation_requested = job.cancellation_requested,
        .cancellation_reason = job.cancellation_reason.slice(),
    };
}

fn eventSnapshot(event: *const runtime_ux.EventRecord) ports.RuntimeEventSnapshot {
    return .{
        .sequence = event.sequence,
        .job_id = event.job_id.slice(),
        .event = event.event.slice(),
        .stream = event.stream.slice(),
        .message = event.message.slice(),
        .text = event.text.slice(),
        .elapsed_ms = event.elapsed_ms,
    };
}

fn subscriptionSnapshot(sub: *const runtime_ux.Subscription) ports.RuntimeSubscriptionSnapshot {
    return .{
        .id = sub.id.slice(),
        .uri = sub.uri.slice(),
        .active = sub.active,
        .created_sequence = sub.created_sequence,
    };
}

fn rootSnapshot(root: *const runtime_ux.WorkspaceRoot) ports.RuntimeRootSnapshot {
    return .{
        .id = root.id.slice(),
        .path = root.path.slice(),
        .uri = root.uri.slice(),
        .name = root.name.slice(),
        .selected = root.selected,
    };
}

fn statusFromRuntime(status: runtime_ux.JobStatus) ports.RuntimeJobStatus {
    return switch (status) {
        .queued => .queued,
        .running => .running,
        .completed => .completed,
        .failed => .failed,
        .cancelled => .cancelled,
    };
}

fn statusToRuntime(status: ports.RuntimeJobStatus) runtime_ux.JobStatus {
    return switch (status) {
        .queued => .queued,
        .running => .running,
        .completed => .completed,
        .failed => .failed,
        .cancelled => .cancelled,
    };
}

test "runtime UX session port exposes job lifecycle snapshots" {
    var state: runtime_ux.State = .{};
    var session = Session.init(&state);
    const port = session.port();

    const started = try port.startJob("build", "zig build", 1000);
    try std.testing.expectEqualStrings("job-1", started.id);
    try std.testing.expectEqual(ports.RuntimeJobStatus.running, started.status);

    const finished = try port.finishJob(started.id, .{
        .status = .completed,
        .ok = true,
        .duration_ms = 12,
        .term = "exited",
        .exit_code = 0,
        .stdout_tail = "ok",
        .stderr_tail = "",
        .stdout_truncated = false,
        .stderr_truncated = false,
    });
    try std.testing.expectEqual(ports.RuntimeJobStatus.completed, finished.status);
    try std.testing.expectEqual(@as(u64, 3), try port.eventCount());
}

test "runtime UX session port covers roots subscriptions events and failures" {
    var state: runtime_ux.State = .{};
    var session = Session.init(&state);
    const port = session.port();

    try port.ensureDefaultRoot("/workspace");
    try std.testing.expectEqual(@as(usize, 1), try port.rootCount());
    try std.testing.expectEqual(@as(usize, 0), try port.selectedRootIndex());
    try std.testing.expectEqualStrings("/workspace", (try port.rootAt(0)).path);
    try std.testing.expectError(error.NotFound, port.rootAt(1));

    try port.syncRoots("/workspace", "file:///workspace/a\n/workspace/b", false);
    try std.testing.expectEqual(@as(usize, 1), try port.rootCount());
    try port.syncRoots("/workspace", "file:///workspace/a\n/workspace/b", true);
    try std.testing.expectEqual(@as(usize, 2), try port.rootCount());
    const preview = try port.selectRoot("root-2", false);
    try std.testing.expect(!preview.selected);
    const selected = try port.selectRoot("/workspace/b", true);
    try std.testing.expect(selected.selected);
    try std.testing.expectEqual(@as(usize, 1), try port.selectedRootIndex());
    try std.testing.expectError(error.NotFound, port.selectRoot("missing", true));

    const subscription = try port.subscribe("zigar://jobs");
    try std.testing.expectEqualStrings("sub-1", subscription.id);
    try std.testing.expect(subscription.active);
    const unsubscribed = try port.unsubscribe("missing", "zigar://jobs");
    try std.testing.expect(!unsubscribed.active);
    try std.testing.expectError(error.NotFound, port.unsubscribe("missing", null));

    const failed_job = try port.startJob("check", "zig ast-check src/main.zig", 5000);
    const failed = try port.failJob(failed_job.id, "Timeout", 44);
    try std.testing.expectEqual(ports.RuntimeJobStatus.failed, failed.status);
    try std.testing.expectEqualStrings("Timeout", failed.stderr_tail);
    const terminal_cancel = try port.cancelJob(failed_job.id, "audit");
    try std.testing.expectEqual(ports.RuntimeJobStatus.failed, terminal_cancel.status);
    try std.testing.expect(terminal_cancel.cancellation_requested);
    try std.testing.expectError(error.NotFound, port.cancelJob("job-missing", "none"));
    try std.testing.expectError(error.NotFound, port.jobById("job-missing"));

    const running = try port.startJob("build", "zig build", 1000);
    const cancelled = try port.cancelJob(running.id, "client requested");
    try std.testing.expectEqual(ports.RuntimeJobStatus.cancelled, cancelled.status);
    try std.testing.expectEqualStrings("client requested", cancelled.cancellation_reason);
    try std.testing.expectEqualStrings(running.id, (try port.jobById(running.id)).id);
    try std.testing.expectEqualStrings(failed_job.id, (try port.jobAt(0)).id);
    try std.testing.expectError(error.NotFound, port.jobAt(99));

    const event_count = try port.eventCount();
    try std.testing.expect(event_count >= 5);
    try std.testing.expectError(error.NotFound, port.eventAtSequence(0));
    try std.testing.expectEqual(@as(u64, 1), (try port.eventAtSequence(1)).sequence);
    try std.testing.expectEqual(event_count, (try port.eventAtSequence(event_count)).sequence);
}
