const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const workflows = @import("workflows.zig");
const support = @import("../usecase_support.zig");
const fakes = @import("../../../testing/fakes/root.zig");
const manifest_catalog = @import("../../../bootstrap/manifest_catalog.zig");

const manifest =
    \\.{
    \\    .name = .fixture,
    \\    .version = "0.1.0",
    \\    .dependencies = .{
    \\        .alpha = .{
    \\            .url = "https://example.invalid/alpha.tar.gz",
    \\            .hash = "oldhash",
    \\        },
    \\    },
    \\}
    \\
;

test "zig_deps_add preview is apply gated and writes nothing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.workspace.expectRead(.{ .path = "build.zig.zon", .max_bytes = 2 * 1024 * 1024, .provenance = "zig_deps_add" }, manifest);
    try fixture.workspace.expectRead(.{ .path = "build.zig.zon", .max_bytes = 10 * 1024 * 1024, .provenance = "patch_session_snapshot" }, manifest);

    var args_tree = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"dependency":"beta","url":"https://example.invalid/beta.tar.gz","hash":"betahash"}
    , .{});
    defer args_tree.deinit();

    var app = workflows.App.init(fixture.context(), std.testing.allocator);
    const result = try workflows.zigDepsAdd(&app, std.testing.allocator, args_tree.value);
    defer deinitResult(std.testing.allocator, result);
    const obj = result.value.object;
    try std.testing.expectEqual(false, obj.get("applied").?.bool);
    try std.testing.expectEqual(true, obj.get("requires_apply").?.bool);
    try std.testing.expectEqual(@as(usize, 0), fixture.workspace.writeCalls().len);
    try fixture.workspace.verify();
}

test "zig_zon_dep_sync records exact zig fetch argv and previews hash replacement" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.workspace.expectRead(.{ .path = "build.zig.zon", .max_bytes = 2 * 1024 * 1024, .provenance = "zig_zon_dep_sync" }, manifest);
    try fixture.runner.expectRun(.{
        .argv = &.{ "zig", "fetch", "https://example.invalid/alpha.tar.gz" },
        .cwd = "/workspace",
        .timeout_ms = 30_000,
        .max_stdout_bytes = 1024 * 1024,
        .max_stderr_bytes = 1024 * 1024,
        .provenance = "arch110-workflow-command",
    }, .{ .exit_code = 0, .stdout = "hash: newhash\n" });
    try fixture.workspace.expectRead(.{ .path = "build.zig.zon", .max_bytes = 10 * 1024 * 1024, .provenance = "patch_session_snapshot" }, manifest);

    var args_tree = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"dependency\":\"alpha\"}", .{});
    defer args_tree.deinit();

    var app = workflows.App.init(fixture.context(), std.testing.allocator);
    const result = try workflows.zigZonDepSync(&app, std.testing.allocator, args_tree.value);
    defer deinitResult(std.testing.allocator, result);
    const obj = result.value.object;
    try std.testing.expectEqualStrings("newhash", obj.get("fetched_hash").?.string);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("unified_diff").?.string, "newhash") != null);
    try fixture.runner.verify();
    try fixture.workspace.verify();
}

test "zig_pkg_search returns structured unavailable provider state" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var args_tree = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"query\":\"alpha\",\"provider\":\"zigistry\",\"offline\":true}", .{});
    defer args_tree.deinit();

    var app = workflows.App.init(fixture.context(), std.testing.allocator);
    const result = try workflows.zigPkgSearch(&app, std.testing.allocator, args_tree.value);
    defer deinitResult(std.testing.allocator, result);
    const obj = result.value.object;
    try std.testing.expectEqual(true, obj.get("unavailable").?.bool);
    try std.testing.expectEqualStrings("zigistry", obj.get("provider").?.object.get("id").?.string);
}

const Fixture = struct {
    runner: fakes.FakeCommandRunner,
    workspace: fakes.FakeWorkspaceStore,
    scanner: fakes.FakeWorkspaceScanner,
    clock: fakes.FakeClockAndIds,
    catalog: manifest_catalog.Catalog,

    fn init() !Fixture {
        return .{
            .runner = fakes.FakeCommandRunner.init(std.testing.allocator),
            .workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator),
            .scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator),
            .clock = fakes.FakeClockAndIds.init(std.testing.allocator),
            .catalog = .{},
        };
    }

    fn deinit(self: *Fixture) void {
        self.runner.deinit();
        self.workspace.deinit();
        self.scanner.deinit();
        self.clock.deinit();
    }

    fn context(self: *Fixture) app_context.ReleaseWorkflowContext {
        return .{
            .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
            .tool_paths = .{},
            .timeouts = .{},
            .command_runner = self.runner.port(),
            .workspace_store = self.workspace.port(),
            .workspace_scanner = self.scanner.port(),
            .tool_manifest = self.catalog.port(),
            .clock_and_ids = self.clock.port(),
        };
    }
};

fn deinitResult(allocator: std.mem.Allocator, result: workflows.Result) void {
    support.deinitOwnedValue(allocator, result.value);
}
