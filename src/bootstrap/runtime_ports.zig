const std = @import("std");

const app_context = @import("../app/context.zig");
const infra = @import("../infra/root.zig");
const runtime_mod = @import("../runtime.zig");

const app_context_bridge = @import("app_context.zig");

pub const Options = struct {
    workspace_read_resolution: infra.workspace.filesystem.ReadResolution = .input,
    default_read_limit: usize = @import("../command.zig").output_limit,
    non_exited_exit_code: i32 = -1,
    record_command_observability: bool = false,
};

pub const RuntimePorts = struct {
    app: *runtime_mod.App,
    command_runner: infra.process.command_runner.Runner,
    workspace_store: infra.workspace.filesystem.Store,
    clock_and_ids: infra.clock.clock_and_ids.RuntimeClockAndIds,
    artifact_store: infra.artifacts.registry_store.Store,

    const Self = @This();

    pub fn init(app: *runtime_mod.App, options: Options) Self {
        return .{
            .app = app,
            .command_runner = infra.process.command_runner.Runner.init(.{
                .io = app.io,
                .default_cwd = app.workspace.root,
                .default_timeout_ms = app.config.timeout_ms,
                .command_calls = &app.command_calls,
                .tool_errors = &app.tool_errors,
                .observability = &app.observability,
                .non_exited_exit_code = options.non_exited_exit_code,
                .record_observability = options.record_command_observability,
            }),
            .workspace_store = infra.workspace.filesystem.Store.init(&app.workspace, app.io, .{
                .default_read_limit = options.default_read_limit,
                .read_resolution = options.workspace_read_resolution,
            }),
            .clock_and_ids = infra.clock.clock_and_ids.RuntimeClockAndIds.init(app.io, &app.temp_counter),
            .artifact_store = infra.artifacts.registry_store.Store.init(&app.workspace, app.io, .{
                .zig_path = app.config.zig_path,
                .zls_path = app.config.zls_path,
                .zflame_path = app.config.zflame_path,
                .diff_folded_path = app.config.diff_folded_path,
            }),
        };
    }

    pub fn portSet(self: *Self) app_context.PortSet {
        return .{
            .command_runner = self.command_runner.port(),
            .workspace = self.workspace_store.port(),
            .artifact_store = self.artifact_store.port(),
            .clock_and_ids = self.clock_and_ids.port(),
        };
    }

    pub fn context(self: *Self) app_context.Context {
        return app_context_bridge.fromRuntime(self.app, self.portSet());
    }

    pub fn profilingContext(self: *Self) app_context.ContextError!app_context.ProfilingContext {
        return self.context().profiling();
    }

    pub fn coreContext(self: *Self) app_context.ContextError!app_context.CoreCommandContext {
        return self.context().coreCommands();
    }

    pub fn validationContext(self: *Self) app_context.ContextError!app_context.ValidationContext {
        return self.context().validation();
    }

    pub fn editingContext(self: *Self) app_context.ContextError!app_context.EditingContext {
        return self.context().editing();
    }

    pub fn resolveInputPath(self: *Self, path: []const u8) ![]const u8 {
        return self.workspace_store.resolveInputPath(path);
    }

    pub fn resolveOutputPath(self: *Self, path: []const u8) ![]const u8 {
        return self.workspace_store.resolveOutputPath(path);
    }

    pub fn freeResolvedPath(self: *Self, path: []const u8) void {
        self.workspace_store.freeResolvedPath(path);
    }

    pub fn pathAllocator(self: *Self) std.mem.Allocator {
        return self.app.workspace.allocator;
    }
};

test "runtime ports wire reusable infra adapters into app context" {
    var runtime = runtime_mod.App{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .config = .{
            .workspace = "/workspace",
            .zig_path = "/bin/zig",
            .zls_path = "/bin/zls",
            .zflame_path = "/bin/zflame",
            .diff_folded_path = "/bin/diff-folded",
        },
        .workspace = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .root = "/workspace",
            .cache_root = "/workspace/.zigar-cache",
        },
    };

    var runtime_ports = RuntimePorts.init(&runtime, .{ .record_command_observability = true });
    const ctx = runtime_ports.context();
    try std.testing.expect(ctx.ports.command_runner != null);
    try std.testing.expect(ctx.ports.workspace != null);
    try std.testing.expect(ctx.ports.artifact_store != null);
    try std.testing.expect(ctx.ports.clock_and_ids != null);
    try std.testing.expectEqualStrings("/bin/zig", (try runtime_ports.coreContext()).tool_paths.zig);
}
