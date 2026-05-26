//! Environment, adoption, and trust MCP adapters that preserve app workflow
//! JSON result shapes and normalize use-case failures.
const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const environment = @import("../../../app/usecases/environment/workflows.zig");
const adoption = @import("../../../app/usecases/environment/adoption.zig");
const trust = @import("../../../app/usecases/environment/trust.zig");
const ports = @import("../../../app/ports.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

/// Handles MCP `zigar_setup_elicit` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarSetupElicit(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_setup_elicit", environment.zigarSetupElicit);
}

/// Handles MCP `zigar_profile_elicit` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarProfileElicit(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_profile_elicit", environment.zigarProfileElicit);
}

/// Handles MCP `zigar_backend_elicit` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarBackendElicit(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_backend_elicit", environment.zigarBackendElicit);
}

/// Handles MCP `zigar_project_profile_v2` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarProjectProfileV2(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_project_profile_v2", environment.zigarProjectProfileV2);
}

/// Handles MCP `zigar_profile_validate` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarProfileValidate(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_profile_validate", environment.zigarProfileValidate);
}

/// Handles MCP `zigar_profile_read` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarProfileRead(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_profile_read", environment.zigarProfileRead);
}

/// Handles MCP `zigar_profile_bootstrap` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarProfileBootstrap(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_profile_bootstrap", environment.zigarProfileBootstrap);
}

/// Handles MCP `zigar_profile_import` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarProfileImport(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_profile_import", environment.zigarProfileImport);
}

/// Handles MCP `zigar_profile_diff` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarProfileDiff(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_profile_diff", environment.zigarProfileDiff);
}

/// Handles MCP `zigar_env_pack` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarEnvPack(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_env_pack", environment.zigarEnvPack);
}

/// Handles MCP `zigar_env_export` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarEnvExport(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_env_export", environment.zigarEnvExport);
}

/// Handles MCP `zigar_zvm_probe` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarZvmProbe(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_zvm_probe", environment.zigarZvmProbe);
}

/// Handles MCP `zigar_zvm_install_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarZvmInstallPlan(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_zvm_install_plan", environment.zigarZvmInstallPlan);
}

/// Handles MCP `zigar_zvm_switch_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarZvmSwitchPlan(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_zvm_switch_plan", environment.zigarZvmSwitchPlan);
}

/// Handles MCP `zig_zls_match_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigZlsMatchCheck(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zig_zls_match_check", environment.zigZlsMatchCheck);
}

/// Handles MCP `zig_toolchain_pin` requests by delegating to app logic and shaping owned results/errors.
pub fn zigToolchainPin(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zig_toolchain_pin", environment.zigToolchainPin);
}

/// Handles MCP `zig_toolchain_pin_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigToolchainPinCheck(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zig_toolchain_pin_check", environment.zigToolchainPinCheck);
}

/// Handles MCP `zigar_backend_install_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarBackendInstallPlan(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_backend_install_plan", environment.zigarBackendInstallPlan);
}

/// Handles MCP `zigar_backend_verify` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarBackendVerify(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_backend_verify", environment.zigarBackendVerify);
}

/// Handles MCP `zigar_dev_env_generate` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarDevEnvGenerate(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_dev_env_generate", environment.zigarDevEnvGenerate);
}

/// Handles MCP `zigar_backend_conformance` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarBackendConformance(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_backend_conformance", environment.zigarBackendConformance);
}

/// Handles MCP `zigar_backend_evidence_pack` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarBackendEvidencePack(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_backend_evidence_pack", environment.zigarBackendEvidencePack);
}

/// Handles MCP `zigar_adoption_pack` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarAdoptionPack(allocator: std.mem.Allocator, context: app_context.AdoptionContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeAdoption(allocator, context, args, "zigar_adoption_pack", adoption.zigarAdoptionPack);
}

/// Handles MCP `zigar_client_config_generate` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarClientConfigGenerate(allocator: std.mem.Allocator, context: app_context.AdoptionContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeAdoption(allocator, context, args, "zigar_client_config_generate", adoption.zigarClientConfigGenerate);
}

/// Handles MCP `zigar_smoke_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarSmokePlan(allocator: std.mem.Allocator, context: app_context.AdoptionContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeAdoption(allocator, context, args, "zigar_smoke_plan", adoption.zigarSmokePlan);
}

/// Handles MCP `zigar_conformance_report` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarConformanceReport(allocator: std.mem.Allocator, context: app_context.AdoptionContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeAdoption(allocator, context, args, "zigar_conformance_report", adoption.zigarConformanceReport);
}

/// Handles MCP `zigar_trust_report` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarTrustReport(allocator: std.mem.Allocator, context: app_context.TrustContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeTrust(allocator, context, args, "zigar_trust_report", trust.zigarTrustReport);
}

/// Handles MCP `zigar_command_provenance` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarCommandProvenance(allocator: std.mem.Allocator, context: app_context.TrustContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeTrust(allocator, context, args, "zigar_command_provenance", trust.zigarCommandProvenance);
}

/// Handles MCP `zigar_risk_audit` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarRiskAudit(allocator: std.mem.Allocator, context: app_context.TrustContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeTrust(allocator, context, args, "zigar_risk_audit", trust.zigarRiskAudit);
}

/// Handles MCP `zigar_clean_tree_gate` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarCleanTreeGate(allocator: std.mem.Allocator, context: app_context.TrustContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeTrust(allocator, context, args, "zigar_clean_tree_gate", trust.zigarCleanTreeGate);
}

/// Invokes an environment-profile workflow with adapter-owned error shaping.
fn invokeEnvironment(
    allocator: std.mem.Allocator,
    context: app_context.EnvironmentContext,
    args: ?std.json.Value,
    comptime tool_name: []const u8,
    comptime func: anytype,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var app = environment.App.init(context, allocator);
    return finish(allocator, tool_name, "environment_workflow", func(&app, allocator, args));
}

/// Invokes adoption workflows that generate client/setup guidance payloads.
fn invokeAdoption(
    allocator: std.mem.Allocator,
    context: app_context.AdoptionContext,
    args: ?std.json.Value,
    comptime tool_name: []const u8,
    comptime func: anytype,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var app = adoption.App.init(context, allocator);
    return finish(allocator, tool_name, "adoption_workflow", func(&app, allocator, args));
}

/// Invokes trust workflows that may inspect command provenance or tree state.
fn invokeTrust(
    allocator: std.mem.Allocator,
    context: app_context.TrustContext,
    args: ?std.json.Value,
    comptime tool_name: []const u8,
    comptime func: anytype,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var app = trust.App.init(context, allocator);
    return finish(allocator, tool_name, "trust_workflow", func(&app, allocator, args));
}

/// Converts workflow Result values into MCP ToolResult ownership contracts.
fn finish(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, maybe_result: anyerror!environment.Result) mcp.tools.ToolError!mcp.tools.ToolResult {
    const result = maybe_result catch |err| return usecaseError(allocator, tool_name, operation, err);
    if (result.is_error) {
        defer mcp_result.deinitOwnedValue(allocator, result.value);
        return mcp_result.structuredError(allocator, result.value);
    }
    return mcp_result.structuredOwned(allocator, result.value);
}

/// Normalizes non-OOM workflow failures into stable MCP error metadata.
fn usecaseError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "run_usecase",
        .code = "environment_usecase_failed",
        .category = "environment",
        .resolution = "Retry after confirming workspace paths, toolchain arguments, backend selections, and optional evidence payloads.",
    }, err);
}

const fakes = @import("../../../testing/fakes/root.zig");
const manifest_catalog = @import("../../../bootstrap/manifest_catalog.zig");

test "environment adapter covers elicit and structured error wrappers" {
    const test_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var commands = fakes.FakeCommandRunner.init(test_allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(test_allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(test_allocator);
    defer scanner.deinit();

    try workspace.expectExists(.{ .path = ".zigar/profile.json", .for_output = false, .provenance = "arch111-workflow-exists" }, .{ .exists = false });
    try workspace.expectExists(.{ .path = ".zigar/profile.json", .for_output = false, .provenance = "arch111-workflow-exists" }, .{ .exists = false });
    try workspace.expectExists(.{ .path = ".zigar/profile.json", .for_output = false, .provenance = "arch111-workflow-exists" }, .{ .exists = false });
    const context = testEnvironmentContext(commands.port(), workspace.port(), scanner.port());

    const setup = try zigarSetupElicit(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, setup);
    try std.testing.expectEqualStrings("zigar_setup_elicit", setup.structuredContent.?.object.get("kind").?.string);

    const profile = try zigarProfileElicit(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, profile);
    try std.testing.expectEqualStrings("zigar_profile_elicit", profile.structuredContent.?.object.get("kind").?.string);

    const backend = try zigarBackendElicit(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, backend);
    try std.testing.expectEqualStrings("zigar_backend_elicit", backend.structuredContent.?.object.get("kind").?.string);

    const missing_import = try zigarProfileImport(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, missing_import);
    try std.testing.expect(missing_import.is_error);

    try commands.verify();
    try workspace.verify();
}

test "environment adapter covers export pin check and backend verify wrappers" {
    const test_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var commands = fakes.FakeCommandRunner.init(test_allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(test_allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(test_allocator);
    defer scanner.deinit();

    try workspace.expectReadError(.{ .path = ".zigar/toolchain.json", .max_bytes = 2 * 1024 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
    try workspace.expectReadError(.{ .path = ".zigversion", .max_bytes = 128 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
    try workspace.expectReadError(.{ .path = ".tool-versions", .max_bytes = 256 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
    try workspace.expectReadError(.{ .path = "mise.toml", .max_bytes = 256 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
    try workspace.expectReadError(.{ .path = "build.zig.zon", .max_bytes = 256 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
    try workspace.expectReadError(.{ .path = ".zigar-cache/env/pack.json", .max_bytes = 16 * 1024 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
    try workspace.expectResolve(.{ .path = ".zigar-cache/env/pack.json", .for_output = true, .provenance = "arch110-workflow-resolve-output" }, "/workspace/.zigar-cache/env/pack.json");
    try workspace.expectReadError(.{ .path = ".zigar/toolchain.json", .max_bytes = 2 * 1024 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
    try commands.expectRun(.{
        .argv = &.{ "/bin/zlint", "--help" },
        .cwd = "/workspace",
        .timeout_ms = 111,
        .max_stdout_bytes = 1024 * 1024,
        .max_stderr_bytes = 1024 * 1024,
        .provenance = "arch110-workflow-command",
    }, .{ .exit_code = 0, .stdout = "zlint ok\n", .stderr = "", .duration_ms = 3, .provenance = "fake" });
    const context = testEnvironmentContext(commands.port(), workspace.port(), scanner.port());

    const export_args = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "{\"include_hashes\":false,\"probe_backends\":false}", .{});
    const exported = try zigarEnvExport(allocator, context, export_args.value);
    defer mcp_result.deinitToolResult(allocator, exported);
    try std.testing.expectEqualStrings("zigar_env_export", exported.structuredContent.?.object.get("kind").?.string);

    const missing_pin = try zigToolchainPinCheck(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, missing_pin);
    try std.testing.expectEqualStrings("pin_missing", missing_pin.structuredContent.?.object.get("status").?.string);

    const verify_args = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "{\"backend\":\"zlint\",\"timeout_ms\":111}", .{});
    const verified = try zigarBackendVerify(allocator, context, verify_args.value);
    defer mcp_result.deinitToolResult(allocator, verified);
    try std.testing.expectEqualStrings("zigar_backend_verify", verified.structuredContent.?.object.get("kind").?.string);

    try commands.verify();
    try workspace.verify();
}

test "environment adapter covers trust wrappers and raw usecase errors" {
    const test_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(test_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var commands = fakes.FakeCommandRunner.init(test_allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(test_allocator);
    defer workspace.deinit();
    var catalog = manifest_catalog.Catalog{};
    const context = testTrustContext(commands.port(), workspace.port(), catalog.port());

    try workspace.expectReadError(.{ .path = "build.zig.zon", .max_bytes = 1024 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
    try commands.expectRun(.{
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = "/workspace",
        .timeout_ms = 5000,
        .max_stdout_bytes = 1024 * 1024,
        .max_stderr_bytes = 1024 * 1024,
        .provenance = "arch110-workflow-command",
    }, .{ .exit_code = 0, .stdout = "", .stderr = "", .duration_ms = 2, .provenance = "fake" });

    const report = try zigarTrustReport(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, report);
    try std.testing.expectEqualStrings("zigar_trust_report", report.structuredContent.?.object.get("kind").?.string);

    const gate = try zigarCleanTreeGate(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, gate);
    try std.testing.expect(gate.structuredContent.?.object.get("clean").?.bool);

    try std.testing.expectError(error.OutOfMemory, finish(allocator, "test_tool", "test_operation", error.OutOfMemory));
    const port_error = try finish(allocator, "test_tool", "test_operation", error.AccessDenied);
    defer mcp_result.deinitToolResult(allocator, port_error);
    try std.testing.expect(port_error.is_error);

    try commands.verify();
    try workspace.verify();
}

fn testEnvironmentContext(command_runner: ports.CommandRunner, workspace_store: ports.WorkspaceStore, workspace_scanner: ports.WorkspaceScanner) app_context.EnvironmentContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .tool_paths = .{
            .zig = "/bin/zig",
            .zls = "/bin/zls",
            .zlint = "/bin/zlint",
            .zwanzig = "/bin/zwanzig",
            .zflame = "/bin/zflame",
            .diff_folded = "/bin/diff-folded",
        },
        .timeouts = .{ .command_ms = 12_000, .zls_ms = 30_000 },
        .command_runner = command_runner,
        .workspace_store = workspace_store,
        .workspace_scanner = workspace_scanner,
    };
}

fn testTrustContext(command_runner: ports.CommandRunner, workspace_store: ports.WorkspaceStore, tool_manifest: ports.ToolManifestCatalog) app_context.TrustContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .tool_paths = .{},
        .timeouts = .{ .command_ms = 12_000, .zls_ms = 30_000 },
        .command_runner = command_runner,
        .workspace_store = workspace_store,
        .tool_manifest = tool_manifest,
    };
}
