const std = @import("std");
const ports = @import("../../app/ports.zig");
const runtime_ux = @import("state.zig");
const session_mod = @import("session.zig");

const Session = session_mod.Session;

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
