const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const fakes = @import("../../../testing/fakes/root.zig");
const validation = @import("workflows.zig");

const TestPorts = struct {
    command: *fakes.FakeCommandRunner,
    workspace: ports.WorkspaceStore,
    clock: *fakes.FakeClockAndIds,

    fn context(self: TestPorts) app_context.ValidationContext {
        return .{
            .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache" },
            .tool_paths = .{ .zig = "zig" },
            .timeouts = .{ .command_ms = 30_000, .zls_ms = 30_000 },
            .command_runner = self.command.port(),
            .workspace_store = self.workspace,
            .clock_and_ids = self.clock.port(),
        };
    }
};

test "validation plan selects command phases and skipped build gate" {
    var command = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = 0,
        .provenance = "zigar_validation_plan path probe",
    }, "");
    const ctx = (TestPorts{ .command = &command, .workspace = workspace.port(), .clock = &clock }).context();

    var result = try validation.plan(std.testing.allocator, ctx, .{
        .mode = "quick",
        .changed_paths = &.{ "src/main.zig", "README.md" },
        .include_semantic = false,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("quick", result.mode);
    try std.testing.expect(result.risk.touches_zig_source);
    try std.testing.expect(result.risk.touches_docs);
    try std.testing.expectEqual(@as(usize, 5), result.phases.len);
    try std.testing.expectEqual(validation.PhaseKind.tool_only, result.phases[0].kind);
    try std.testing.expectEqualStrings("patch_guard", result.phases[0].id);
    try std.testing.expectEqualStrings("format_check", result.phases[1].id);
    try std.testing.expectEqualStrings("zig", result.phases[1].argv.?.items[0]);
    try std.testing.expectEqualStrings("docs_check", result.phases[4].id);
    try std.testing.expectEqual(@as(usize, 1), result.skipped_phases.len);
    try workspace.verify();
    try command.verify();
    try clock.verify();
}

test "validation run previews skipped command phases without history write" {
    var command = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    try clock.pushInstant(.{ .unix_ms = 1_700_000_000_000, .monotonic_ms = 1 });
    try workspace.expectReadError(.{
        .path = validation.history_path_default,
        .max_bytes = validation.history_max_bytes,
        .provenance = "zigar_validation_run history preimage",
    }, error.FileNotFound);
    const ctx = (TestPorts{ .command = &command, .workspace = workspace.port(), .clock = &clock }).context();

    var outcome = try validation.run(std.testing.allocator, ctx, .{
        .plan = .{ .mode = "quick", .changed_paths = &.{"notes.txt"} },
        .apply = false,
    });
    defer outcome.deinit(std.testing.allocator);
    const report = outcome.ok;

    try std.testing.expect(report.ok);
    try std.testing.expect(!report.history_applied);
    try std.testing.expect(report.requires_apply_for_history);
    try std.testing.expectEqual(@as(usize, 0), report.phases.len);
    try std.testing.expect(report.skipped_phases.len >= 1);
    try std.testing.expectEqual(@as(usize, 0), workspace.writeCalls().len);
    try workspace.verify();
    try command.verify();
    try clock.verify();
}

test "validation run records command failure and timeout as typed phase outcomes" {
    var command = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    try clock.pushInstant(.{ .unix_ms = 1_700_000_000_001, .monotonic_ms = 1 });
    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = 0,
        .provenance = "zigar_validation_plan path probe",
    }, "");
    try workspace.expectReadError(.{
        .path = validation.history_path_default,
        .max_bytes = validation.history_max_bytes,
        .provenance = "zigar_validation_run history preimage",
    }, error.FileNotFound);
    try command.expectRun(.{
        .argv = &.{ "zig", "fmt", "--check", "src/main.zig" },
        .cwd = "/repo",
        .timeout_ms = 10,
        .max_stdout_bytes = validation.command_output_limit,
        .max_stderr_bytes = validation.command_output_limit,
        .provenance = "zigar_validation_run phase",
    }, .{
        .exit_code = 1,
        .term = .{ .exited = 1 },
        .stderr = "src/main.zig:1:1: error: bad format\n",
        .duration_ms = 5,
    });
    try command.expectRunError(.{
        .argv = &.{ "zig", "ast-check", "src/main.zig" },
        .cwd = "/repo",
        .timeout_ms = 10,
        .max_stdout_bytes = validation.command_output_limit,
        .max_stderr_bytes = validation.command_output_limit,
        .provenance = "zigar_validation_run phase",
    }, error.Timeout);
    const ctx = (TestPorts{ .command = &command, .workspace = workspace.port(), .clock = &clock }).context();

    var outcome = try validation.run(std.testing.allocator, ctx, .{
        .plan = .{ .mode = "quick", .changed_paths = &.{"src/main.zig"}, .include_semantic = false },
        .apply = false,
        .timeout_ms = 10,
    });
    defer outcome.deinit(std.testing.allocator);
    const report = outcome.ok;

    try std.testing.expect(!report.ok);
    try std.testing.expectEqual(@as(usize, 2), report.phases.len);
    try std.testing.expectEqualStrings("format_check", report.phases[0].name);
    try std.testing.expect(!report.phases[0].ok);
    try std.testing.expectEqual(ports.CommandTerm{ .exited = 1 }, report.phases[0].outcome.result.term);
    try std.testing.expectEqual(error.Timeout, report.phases[1].outcome.port_error);
    try std.testing.expectEqual(@as(usize, 2), report.history_record.failures.len);
    try workspace.verify();
    try command.verify();
    try clock.verify();
}

test "validation run applies history writes through workspace port" {
    var command = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command.deinit();
    var workspace = RecordingWorkspace.init();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    try clock.pushInstant(.{ .unix_ms = 1_700_000_000_002, .monotonic_ms = 1 });
    const ctx = (TestPorts{ .command = &command, .workspace = workspace.port(), .clock = &clock }).context();

    var outcome = try validation.run(std.testing.allocator, ctx, .{
        .plan = .{ .mode = "quick", .changed_paths = &.{"notes.txt"} },
        .apply = true,
    });
    defer outcome.deinit(std.testing.allocator);
    const report = outcome.ok;

    try std.testing.expect(report.history_applied);
    try std.testing.expectEqual(@as(usize, 2), workspace.read_count);
    try std.testing.expectEqual(@as(usize, 1), workspace.write_count);
    try std.testing.expect(std.mem.indexOf(u8, workspace.last_write_bytes, "\"recorded_unix_ms\":1700000000002") != null);
    try std.testing.expect(std.mem.indexOf(u8, workspace.last_write_bytes, "\"ok\":true") != null);
    try command.verify();
    try clock.verify();
}

test "validation run persists command and event details for failing history records" {
    var command = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command.deinit();
    var workspace = RecordingWorkspace.init();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    try clock.pushInstant(.{ .unix_ms = 1_700_000_000_003, .monotonic_ms = 1 });
    try command.expectRun(.{
        .argv = &.{ "zig", "fmt", "--check", "src/main.zig" },
        .cwd = "/repo",
        .timeout_ms = 10,
        .max_stdout_bytes = validation.command_output_limit,
        .max_stderr_bytes = validation.command_output_limit,
        .provenance = "zigar_validation_run phase",
    }, .{
        .exit_code = 1,
        .term = .{ .exited = 1 },
        .stderr = "src/main.zig:1:1: error: bad format\n",
        .duration_ms = 5,
    });
    const ctx = (TestPorts{ .command = &command, .workspace = workspace.port(), .clock = &clock }).context();

    var outcome = try validation.run(std.testing.allocator, ctx, .{
        .plan = .{ .mode = "quick", .changed_paths = &.{"src/main.zig"}, .include_semantic = false },
        .apply = true,
        .stop_on_failure = true,
        .timeout_ms = 10,
    });
    defer outcome.deinit(std.testing.allocator);
    const report = outcome.ok;

    try std.testing.expect(!report.ok);
    try std.testing.expect(report.history_applied);
    try std.testing.expectEqual(@as(usize, 3), workspace.read_count);
    try std.testing.expectEqual(@as(usize, 1), workspace.write_count);

    const line = std.mem.trim(u8, workspace.last_write_bytes, "\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const failures = root.get("failures").?.array;
    try std.testing.expectEqual(@as(usize, 1), failures.items.len);
    const failure = failures.items[0].object;
    const failure_command = failure.get("command").?.object;
    try std.testing.expectEqualStrings("command", failure_command.get("kind").?.string);
    try std.testing.expectEqualStrings("format_check", failure_command.get("title").?.string);
    try std.testing.expectEqualStrings("src/main.zig:1:1: error: bad format\n", failure_command.get("stderr").?.string);

    const phases = root.get("phases").?.array;
    try std.testing.expectEqual(@as(usize, 1), phases.items.len);
    const phase = phases.items[0].object;
    const phase_command = phase.get("command").?.object;
    try std.testing.expectEqualStrings("command", phase_command.get("kind").?.string);
    const events = phase.get("events").?.object;
    try std.testing.expectEqualStrings("validation_phase", events.get("kind").?.string);
    const event_items = events.get("events").?.array;
    try std.testing.expectEqual(@as(usize, 1), event_items.items.len);
    const event = event_items.items[0].object;
    try std.testing.expectEqualStrings("compiler_error", event.get("event").?.string);
    try std.testing.expectEqualStrings("src/main.zig:1:1: error: bad format", event.get("message").?.string);

    try command.verify();
    try clock.verify();
}

test "validation history summarizes supplied records without MCP result shapes" {
    var command = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();
    const ctx = (TestPorts{ .command = &command, .workspace = workspace.port(), .clock = &clock }).context();

    var outcome = try validation.history(std.testing.allocator, ctx, .{
        .view = .runs,
        .history_text =
        \\{"ok":false,"failures":[{"fingerprint":"src/main.zig:1:error","message":"boom"}],"slow_phases":[]}
        \\{"ok":true,"failures":[],"slow_phases":[]}
        \\
        ,
    });
    defer outcome.deinit(std.testing.allocator);
    const result = outcome.ok;

    try std.testing.expect(result.history_available);
    try std.testing.expectEqual(@as(usize, 2), result.runs.len);
    try std.testing.expectEqual(@as(?usize, 1), result.last_good_index);
    try std.testing.expectEqual(@as(usize, 1), result.failure_groups.len);
    try std.testing.expectEqualStrings("src/main.zig:1:error", result.failure_groups[0].fingerprint);
    try workspace.verify();
    try command.verify();
    try clock.verify();
}

const RecordingWorkspace = struct {
    read_count: usize = 0,
    write_count: usize = 0,
    last_write_path: []const u8 = "",
    last_write_bytes: []const u8 = "",
    buffer: [4096]u8 = undefined,

    fn init() RecordingWorkspace {
        return .{};
    }

    fn port(self: *RecordingWorkspace) ports.WorkspaceStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .read = read,
                .write = write,
            },
        };
    }

    fn read(ptr: *anyopaque, _: std.mem.Allocator, request: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
        const self: *RecordingWorkspace = @ptrCast(@alignCast(ptr));
        self.read_count += 1;
        if (std.mem.eql(u8, request.path, "src/main.zig")) return .{ .bytes = "" };
        return error.FileNotFound;
    }

    fn write(ptr: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
        const self: *RecordingWorkspace = @ptrCast(@alignCast(ptr));
        self.write_count += 1;
        self.last_write_path = request.path;
        const len = @min(self.buffer.len, request.bytes.len);
        @memcpy(self.buffer[0..len], request.bytes[0..len]);
        self.last_write_bytes = self.buffer[0..len];
        return .{ .bytes_written = request.bytes.len };
    }
};
