const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const workflows = @import("workflows.zig");
const fakes = @import("../../../testing/fakes/root.zig");

const StaticManifest = struct {
    entries: []const ports.ToolManifestEntry,

    fn port(self: *StaticManifest) ports.ToolManifestCatalog {
        return .{
            .ptr = self,
            .vtable = &.{
                .count = count,
                .entry_at = entryAt,
                .find = find,
            },
        };
    }

    fn count(ptr: *anyopaque) usize {
        const self: *StaticManifest = @ptrCast(@alignCast(ptr));
        return self.entries.len;
    }

    fn entryAt(ptr: *anyopaque, index: usize) ?ports.ToolManifestEntry {
        const self: *StaticManifest = @ptrCast(@alignCast(ptr));
        if (index >= self.entries.len) return null;
        return self.entries[index];
    }

    fn find(ptr: *anyopaque, name: []const u8) ?ports.ToolManifestEntry {
        const self: *StaticManifest = @ptrCast(@alignCast(ptr));
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

test "catalog text is retrieved through typed catalog port" {
    var catalog_fake = fakes.FakeToolCatalog.init("{\"tools\":[\"zig_build\"]}");
    const text = try workflows.catalogText(std.testing.allocator, .{
        .ports = .{ .tool_catalog = catalog_fake.port() },
    });
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("{\"tools\":[\"zig_build\"]}", text);
    try std.testing.expectEqual(@as(usize, 1), catalog_fake.calls);
}

test "doctor probes configured backend paths through backend probe port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var backend_fake = fakes.FakeBackendProbe.init(std.testing.allocator);
    defer backend_fake.deinit();

    try backend_fake.expectCheck(.{ .backend = "zig", .argv = &.{ "zig-bin", "version" }, .cwd = "/workspace", .timeout_ms = 123, .provenance = "discovery.doctor_probe" }, .{ .backend = "zig", .available = true, .basis = "zig version ok" });
    try backend_fake.expectCheck(.{ .backend = "zls", .argv = &.{ "zls-bin", "--version" }, .cwd = "/workspace", .timeout_ms = 123, .provenance = "discovery.doctor_probe" }, .{ .backend = "zls", .available = false, .unavailable_reason = "not installed", .basis = "zls missing" });
    try backend_fake.expectCheck(.{ .backend = "zlint", .argv = &.{ "zlint-bin", "--help" }, .cwd = "/workspace", .timeout_ms = 123, .provenance = "discovery.doctor_probe" }, .{ .backend = "zlint", .available = true, .basis = "zlint help ok" });
    try backend_fake.expectCheck(.{ .backend = "zwanzig", .argv = &.{ "zwanzig-bin", "--help" }, .cwd = "/workspace", .timeout_ms = 123, .provenance = "discovery.doctor_probe" }, .{ .backend = "zwanzig", .available = true, .basis = "zwanzig help ok" });
    try backend_fake.expectCheck(.{ .backend = "zflame", .argv = &.{ "zflame-bin", "--help" }, .cwd = "/workspace", .timeout_ms = 123, .provenance = "discovery.doctor_probe" }, .{ .backend = "zflame", .available = true, .basis = "zflame help ok" });
    try backend_fake.expectCheck(.{ .backend = "diff-folded", .argv = &.{ "diff-bin", "--help" }, .cwd = "/workspace", .timeout_ms = 123, .provenance = "discovery.doctor_probe" }, .{ .backend = "diff-folded", .available = true, .basis = "diff-folded help ok" });

    const value = try workflows.doctorValue(arena.allocator(), .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache", .transport = "stdio" },
        .tool_paths = .{
            .zig = "zig-bin",
            .zls = "zls-bin",
            .zlint = "zlint-bin",
            .zwanzig = "zwanzig-bin",
            .zflame = "zflame-bin",
            .diff_folded = "diff-bin",
        },
        .ports = .{ .backend_probe = backend_fake.port() },
    }, true, 123);

    const checks = value.object.get("checks").?.array.items;
    try std.testing.expect(checks.len >= 17);
    try std.testing.expectEqualStrings("zig_probe", checks[11].object.get("name").?.string);
    try std.testing.expectEqualStrings("ok", checks[11].object.get("status").?.string);
    try std.testing.expectEqualStrings("zls_probe", checks[12].object.get("name").?.string);
    try std.testing.expectEqualStrings("not installed", checks[12].object.get("status").?.string);
    try std.testing.expectEqualStrings("zls missing", checks[12].object.get("resolution").?.string);
    try backend_fake.verify();
}

test "toolchain resolve classifies project Zig version hints through ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var command_fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_fake.deinit();
    var workspace_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace_fake.deinit();

    try command_fake.expectRun(.{ .argv = &.{ "zig-bin", "version" }, .cwd = "/workspace", .timeout_ms = 500, .provenance = "discovery.toolchain_resolve.zig" }, .{ .stdout = "0.16.1\n" });
    try command_fake.expectRun(.{ .argv = &.{ "zls-bin", "--version" }, .cwd = "/workspace", .timeout_ms = 500, .provenance = "discovery.toolchain_resolve.zls" }, .{ .stdout = "0.16.0\n" });
    try workspace_fake.expectRead(.{ .path = ".zigversion", .max_bytes = 64 * 1024, .provenance = "discovery.version_hint" }, "0.16.1\n");
    try workspace_fake.expectReadError(.{ .path = ".tool-versions", .max_bytes = 64 * 1024, .provenance = "discovery.tool_versions_hint" }, error.FileNotFound);
    try workspace_fake.expectReadError(.{ .path = "mise.toml", .max_bytes = 128 * 1024, .provenance = "discovery.mise_hint" }, error.FileNotFound);
    try workspace_fake.expectRead(.{ .path = "build.zig.zon", .max_bytes = 256 * 1024, .provenance = "discovery.build_zon_hint" },
        \\.{
        \\    .minimum_zig_version = "0.16.0",
        \\}
    );

    const value = try workflows.toolchainResolveValue(arena.allocator(), .{
        .workspace = .{ .root = "/workspace" },
        .tool_paths = .{ .zig = "zig-bin", .zls = "zls-bin" },
        .ports = .{ .command_runner = command_fake.port(), .workspace = workspace_fake.port() },
    }, false, 500);

    try std.testing.expect(value.object.get("version_match").?.bool);
    try std.testing.expectEqualStrings("exact_match", value.object.get("version_status").?.string);
    try std.testing.expectEqual(@as(i64, 2), value.object.get("zig_hint_count").?.integer);
    try std.testing.expectEqual(@as(usize, 0), value.object.get("issues").?.array.items.len);
    try command_fake.verify();
    try workspace_fake.verify();
}

test "command plan uses typed manifest metadata and workspace resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var workspace_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace_fake.deinit();
    try workspace_fake.expectResolve(.{ .path = "src/main.zig", .provenance = "zig_command_plan" }, "/workspace/src/main.zig");

    const entries = [_]ports.ToolManifestEntry{
        .{
            .name = "zig_check",
            .description = "check a Zig source file",
            .group = "core",
            .plan_kind = "exact_command",
            .plan = .{ .exact_command = .{ .required_file = &.{"ast-check"} } },
        },
    };
    var manifest = StaticManifest{ .entries = entries[0..] };

    const value = try workflows.commandPlanValue(arena.allocator(), .{
        .workspace = .{ .root = "/workspace" },
        .tool_paths = .{ .zig = "zig-bin" },
        .ports = .{ .workspace = workspace_fake.port(), .tool_manifest = manifest.port() },
    }, .{
        .tool = "zig_check",
        .file = "src/main.zig",
        .args = "--color on",
        .timeout_ms = 90_000,
    });

    const argv = value.object.get("argv").?.array.items;
    try std.testing.expectEqualStrings("zig-bin", argv[0].string);
    try std.testing.expectEqualStrings("ast-check", argv[1].string);
    try std.testing.expectEqualStrings("/workspace/src/main.zig", argv[2].string);
    try std.testing.expectEqualStrings("--color", argv[3].string);
    try std.testing.expectEqualStrings("on", argv[4].string);
    try std.testing.expectEqual(@as(i64, 90_000), value.object.get("timeout_ms").?.integer);
    try workspace_fake.verify();
}

test "status read models expose backend workspace metrics and HTTP fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var command_calls: usize = 7;
    var zls_requests: usize = 3;
    var tool_errors: usize = 2;

    const context = app_context.Context{
        .workspace = .{
            .root = "/workspace",
            .cache_root = "/workspace/.zigar-cache",
            .transport = "http",
            .host = "127.0.0.1",
            .port = 9898,
        },
        .tool_paths = .{
            .zig = "zig-bin",
            .zls = "zls-bin",
            .zlint = "zlint-bin",
            .zwanzig = "zwanzig-bin",
            .zflame = "zflame-bin",
            .diff_folded = "diff-bin",
        },
        .timeouts = .{ .command_ms = 1234, .zls_ms = 5678 },
        .zls_state = .{
            .status = "connected",
            .initialize_response = "{\"capabilities\":{}}",
            .running = true,
            .restart_attempts = 1,
        },
        .counters = .{
            .command_calls = &command_calls,
            .zls_requests = &zls_requests,
            .tool_errors = &tool_errors,
        },
        .caches = .{
            .analysis = .{ .cached = true, .signature = 42, .hits = 4, .refreshes = 1, .bytes = 99 },
            .semantic_index = .{ .cached = true, .signature = 84, .hits = 5, .refreshes = 2, .bytes = 199 },
        },
        .trust_probe_cache = .{
            .zlint = .{ .probed = true, .ok = true, .status = "ok", .resolution = "cached" },
            .zwanzig = .{ .probed = true, .ok = false, .status = "missing", .resolution = "install zwanzig" },
        },
    };

    const backend_catalog = try workflows.backendCatalogValue(arena.allocator(), context, true);
    const backends = backend_catalog.object.get("backends").?.array.items;
    try std.testing.expectEqualStrings("zig-bin", backends[0].object.get("configured_path").?.string);
    try std.testing.expectEqualStrings("zlint-bin", backends[2].object.get("probe_argv").?.array.items[0].string);

    const workspace = try workflows.workspaceInfoValue(arena.allocator(), context);
    try std.testing.expectEqualStrings("/workspace", workspace.object.get("workspace").?.string);
    try std.testing.expectEqualStrings("connected", workspace.object.get("zls_status").?.string);
    try std.testing.expectEqualStrings("missing", workspace.object.get("backend_probe_cache").?.object.get("zwanzig").?.object.get("status").?.string);

    const metrics = try workflows.metricsValue(arena.allocator(), context);
    try std.testing.expectEqual(@as(i64, 7), metrics.object.get("command_calls").?.integer);
    try std.testing.expectEqual(@as(i64, 3), metrics.object.get("zls_requests").?.integer);
    try std.testing.expectEqual(@as(i64, 2), metrics.object.get("tool_errors").?.integer);
    try std.testing.expectEqual(@as(i64, 4), metrics.object.get("analysis_cache").?.object.get("hits").?.integer);

    const http = try workflows.httpStatusValue(arena.allocator(), context);
    try std.testing.expectEqualStrings("http", http.object.get("configured_transport").?.string);
    try std.testing.expectEqual(@as(i64, 9898), http.object.get("port").?.integer);
    try std.testing.expect(http.object.get("http_available").?.bool);
}

test "tool plan reports typed policies for non exact manifest entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const entries = [_]ports.ToolManifestEntry{
        .{
            .name = "zig_build",
            .description = "build project",
            .group = "core",
            .plan_kind = "exact_command",
            .plan = .{ .exact_command = .{ .argv = &.{"build"} } },
            .risk = .{ .executes_project_code = true },
        },
        .{
            .name = "zig_env",
            .description = "dynamic env",
            .group = "core",
            .plan_kind = "dynamic_command",
            .plan = .{ .dynamic_command = "argv depends on requested env fields" },
            .risk = .{ .executes_backend = true },
        },
        .{
            .name = "zig_hover",
            .description = "hover",
            .group = "zls",
            .plan_kind = "zls_request",
            .plan = .{ .zls_request = .{
                .method = "textDocument/hover",
                .requires_document_sync = true,
                .mutates_document_state = false,
                .required_capability = "hoverProvider",
            } },
            .risk = .{ .mutates_lsp_state = true },
        },
        .{
            .name = "zig_rename",
            .description = "rename",
            .group = "zls",
            .read_only = false,
            .plan_kind = "apply_gated_mutation",
            .plan = .{ .apply_gated_mutation = "preview workspace edit before apply" },
            .risk = .{
                .writes_source = true,
                .writes_require_apply = true,
                .preview_by_default = true,
                .mutates_lsp_state = true,
            },
        },
        .{
            .name = "zig_flamegraph",
            .description = "render flamegraph",
            .group = "profiling",
            .read_only = false,
            .plan_kind = "workspace_artifact",
            .plan = .{ .workspace_artifact = "writes SVG artifact" },
            .risk = .{ .writes_artifacts = true, .executes_backend = true },
        },
        .{
            .name = "zig_project_scan",
            .description = "scan source",
            .group = "static",
            .plan_kind = "pure_analysis",
            .plan = .{ .pure_analysis = "reads workspace source through ports" },
        },
        .{
            .name = "zig_session_reset",
            .description = "reset session",
            .group = "agent",
            .plan_kind = "not_plannable",
            .plan = .{ .not_plannable = "stateful session operation" },
        },
    };
    var manifest = StaticManifest{ .entries = entries[0..] };
    const context = app_context.Context{
        .workspace = .{ .root = "/workspace" },
        .ports = .{ .tool_manifest = manifest.port() },
    };

    const dynamic = try workflows.toolPlanValue(arena.allocator(), context, .{ .tool = "zig_env" });
    try std.testing.expect(dynamic.object.get("command_backed").?.bool);
    try std.testing.expect(!dynamic.object.get("argv_exact").?.bool);
    try std.testing.expectEqualStrings("low", dynamic.object.get("risk_level").?.string);

    const zls = try workflows.toolPlanValue(arena.allocator(), context, .{ .tool = "zig_hover" });
    try std.testing.expectEqualStrings("zls", zls.object.get("backend").?.string);
    try std.testing.expectEqualStrings("textDocument/hover", zls.object.get("method").?.string);
    try std.testing.expectEqualStrings("medium", zls.object.get("risk_level").?.string);

    const rename = try workflows.toolPlanValue(arena.allocator(), context, .{ .tool = "zig_rename" });
    try std.testing.expect(rename.object.get("apply_gated").?.bool);
    try std.testing.expect(rename.object.get("preview_by_default").?.bool);
    try std.testing.expectEqualStrings("high", rename.object.get("risk_level").?.string);

    const artifact = try workflows.toolPlanValue(arena.allocator(), context, .{ .tool = "zig_flamegraph" });
    try std.testing.expect(artifact.object.get("writes_artifact").?.bool);
    try std.testing.expect(artifact.object.get("command_backed").?.bool);
    try std.testing.expectEqualStrings("medium", artifact.object.get("risk_level").?.string);

    const pure = try workflows.toolPlanValue(arena.allocator(), context, .{ .tool = "zig_project_scan" });
    try std.testing.expect(pure.object.get("supported").?.bool);
    try std.testing.expect(!pure.object.get("command_backed").?.bool);

    const blocked = try workflows.toolPlanValue(arena.allocator(), context, .{ .tool = "zig_session_reset" });
    try std.testing.expect(!blocked.object.get("supported").?.bool);
    try std.testing.expectEqualStrings("not_plannable", blocked.object.get("plan_kind").?.string);

    const unsupported = try workflows.commandPlanValue(arena.allocator(), context, .{ .tool = "zig_env" });
    try std.testing.expect(!unsupported.object.get("supported").?.bool);
    try std.testing.expectEqual(@as(usize, 1), unsupported.object.get("supported_tools").?.array.items.len);
    try std.testing.expectEqualStrings("zig_build", unsupported.object.get("supported_tools").?.array.items[0].string);
}
