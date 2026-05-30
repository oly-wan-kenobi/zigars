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

/// Handles MCP `zigars_setup_guidance` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsSetupGuidance(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_setup_guidance", environment.zigarsSetupGuidance);
}

/// Handles MCP `zigars_profile_guidance` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsProfileGuidance(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_profile_guidance", environment.zigarsProfileGuidance);
}

/// Handles MCP `zigars_backend_guidance` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsBackendGuidance(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_backend_guidance", environment.zigarsBackendGuidance);
}

/// Handles MCP `zigars_setup_elicit` compatibility requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsSetupElicit(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_setup_elicit", environment.zigarsSetupElicit);
}

/// Handles MCP `zigars_profile_elicit` compatibility requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsProfileElicit(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_profile_elicit", environment.zigarsProfileElicit);
}

/// Handles MCP `zigars_backend_elicit` compatibility requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsBackendElicit(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_backend_elicit", environment.zigarsBackendElicit);
}

/// Handles MCP `zigars_project_profile_v2` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsProjectProfileV2(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_project_profile_v2", environment.zigarsProjectProfileV2);
}

/// Handles MCP `zigars_profile_validate` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsProfileValidate(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_profile_validate", environment.zigarsProfileValidate);
}

/// Handles MCP `zigars_profile_read` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsProfileRead(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_profile_read", environment.zigarsProfileRead);
}

/// Handles MCP `zigars_profile_bootstrap` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsProfileBootstrap(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_profile_bootstrap", environment.zigarsProfileBootstrap);
}

/// Handles MCP `zigars_profile_import` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsProfileImport(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_profile_import", environment.zigarsProfileImport);
}

/// Handles MCP `zigars_profile_diff` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsProfileDiff(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_profile_diff", environment.zigarsProfileDiff);
}

/// Handles MCP `zigars_env_pack` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsEnvPack(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_env_pack", environment.zigarsEnvPack);
}

/// Handles MCP `zigars_env_export` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsEnvExport(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_env_export", environment.zigarsEnvExport);
}

/// Handles MCP `zigars_zvm_probe` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsZvmProbe(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_zvm_probe", environment.zigarsZvmProbe);
}

/// Handles MCP `zigars_zvm_install_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsZvmInstallPlan(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_zvm_install_plan", environment.zigarsZvmInstallPlan);
}

/// Handles MCP `zigars_zvm_switch_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsZvmSwitchPlan(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_zvm_switch_plan", environment.zigarsZvmSwitchPlan);
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

/// Handles MCP `zigars_backend_install_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsBackendInstallPlan(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_backend_install_plan", environment.zigarsBackendInstallPlan);
}

/// Handles MCP `zigars_backend_verify` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsBackendVerify(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_backend_verify", environment.zigarsBackendVerify);
}

/// Handles MCP `zigars_dev_env_generate` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsDevEnvGenerate(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_dev_env_generate", environment.zigarsDevEnvGenerate);
}

/// Handles MCP `zigars_backend_conformance` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsBackendConformance(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_backend_conformance", environment.zigarsBackendConformance);
}

/// Handles MCP `zigars_backend_evidence_pack` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsBackendEvidencePack(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigars_backend_evidence_pack", environment.zigarsBackendEvidencePack);
}

/// Handles MCP `zigars_adoption_pack` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsAdoptionPack(allocator: std.mem.Allocator, context: app_context.AdoptionContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeAdoption(allocator, context, args, "zigars_adoption_pack", adoption.zigarsAdoptionPack);
}

/// Handles MCP `zigars_client_config_generate` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsClientConfigGenerate(allocator: std.mem.Allocator, context: app_context.AdoptionContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeAdoption(allocator, context, args, "zigars_client_config_generate", adoption.zigarsClientConfigGenerate);
}

/// Handles MCP `zigars_smoke_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsSmokePlan(allocator: std.mem.Allocator, context: app_context.AdoptionContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeAdoption(allocator, context, args, "zigars_smoke_plan", adoption.zigarsSmokePlan);
}

/// Handles MCP `zigars_conformance_report` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsConformanceReport(allocator: std.mem.Allocator, context: app_context.AdoptionContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeAdoption(allocator, context, args, "zigars_conformance_report", adoption.zigarsConformanceReport);
}

/// Handles MCP `zigars_trust_report` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsTrustReport(allocator: std.mem.Allocator, context: app_context.TrustContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeTrust(allocator, context, args, "zigars_trust_report", trust.zigarsTrustReport);
}

/// Handles MCP `zigars_command_provenance` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsCommandProvenance(allocator: std.mem.Allocator, context: app_context.TrustContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeTrust(allocator, context, args, "zigars_command_provenance", trust.zigarsCommandProvenance);
}

/// Handles MCP `zigars_risk_audit` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsRiskAudit(allocator: std.mem.Allocator, context: app_context.TrustContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeTrust(allocator, context, args, "zigars_risk_audit", trust.zigarsRiskAudit);
}

/// Handles MCP `zigars_clean_tree_gate` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsCleanTreeGate(allocator: std.mem.Allocator, context: app_context.TrustContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeTrust(allocator, context, args, "zigars_clean_tree_gate", trust.zigarsCleanTreeGate);
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

/// Converts a workflow Result into an MCP ToolResult. On the error path the
/// owned value is copied into a structured error and then freed here; on the
/// success path structuredOwned takes ownership, so the value must not be
/// double-freed across the two branches.
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

    try workspace.expectExists(.{ .path = ".zigars/profile.json", .for_output = false, .provenance = "arch111-workflow-exists" }, .{ .exists = false });
    try workspace.expectExists(.{ .path = ".zigars/profile.json", .for_output = false, .provenance = "arch111-workflow-exists" }, .{ .exists = false });
    try workspace.expectExists(.{ .path = ".zigars/profile.json", .for_output = false, .provenance = "arch111-workflow-exists" }, .{ .exists = false });
    try workspace.expectExists(.{ .path = ".zigars/profile.json", .for_output = false, .provenance = "arch111-workflow-exists" }, .{ .exists = false });
    try workspace.expectExists(.{ .path = ".zigars/profile.json", .for_output = false, .provenance = "arch111-workflow-exists" }, .{ .exists = false });
    try workspace.expectExists(.{ .path = ".zigars/profile.json", .for_output = false, .provenance = "arch111-workflow-exists" }, .{ .exists = false });
    const context = testEnvironmentContext(commands.port(), workspace.port(), scanner.port());

    const setup_guidance = try zigarsSetupGuidance(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, setup_guidance);
    try std.testing.expectEqualStrings("zigars_setup_guidance", setup_guidance.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqual(false, setup_guidance.structuredContent.?.object.get("elicitation_used").?.bool);

    const setup = try zigarsSetupElicit(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, setup);
    try std.testing.expectEqualStrings("zigars_setup_elicit", setup.structuredContent.?.object.get("kind").?.string);

    const profile_guidance = try zigarsProfileGuidance(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, profile_guidance);
    try std.testing.expectEqualStrings("zigars_profile_guidance", profile_guidance.structuredContent.?.object.get("kind").?.string);

    const profile = try zigarsProfileElicit(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, profile);
    try std.testing.expectEqualStrings("zigars_profile_elicit", profile.structuredContent.?.object.get("kind").?.string);

    const backend_guidance = try zigarsBackendGuidance(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, backend_guidance);
    try std.testing.expectEqualStrings("zigars_backend_guidance", backend_guidance.structuredContent.?.object.get("kind").?.string);

    const backend = try zigarsBackendElicit(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, backend);
    try std.testing.expectEqualStrings("zigars_backend_elicit", backend.structuredContent.?.object.get("kind").?.string);

    const missing_import = try zigarsProfileImport(allocator, context, null);
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

    try workspace.expectReadError(.{ .path = ".zigars/toolchain.json", .max_bytes = 2 * 1024 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
    try workspace.expectReadError(.{ .path = ".zigversion", .max_bytes = 128 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
    try workspace.expectReadError(.{ .path = ".tool-versions", .max_bytes = 256 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
    try workspace.expectReadError(.{ .path = "mise.toml", .max_bytes = 256 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
    try workspace.expectReadError(.{ .path = "build.zig.zon", .max_bytes = 256 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
    try workspace.expectReadError(.{ .path = ".zigars-cache/env/pack.json", .max_bytes = 16 * 1024 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
    try workspace.expectResolve(.{ .path = ".zigars-cache/env/pack.json", .for_output = true, .provenance = "arch110-workflow-resolve-output" }, "/workspace/.zigars-cache/env/pack.json");
    try workspace.expectReadError(.{ .path = ".zigars/toolchain.json", .max_bytes = 2 * 1024 * 1024, .provenance = "arch110-workflow-read" }, error.FileNotFound);
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
    const exported = try zigarsEnvExport(allocator, context, export_args.value);
    defer mcp_result.deinitToolResult(allocator, exported);
    try std.testing.expectEqualStrings("zigars_env_export", exported.structuredContent.?.object.get("kind").?.string);

    const missing_pin = try zigToolchainPinCheck(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, missing_pin);
    try std.testing.expectEqualStrings("pin_missing", missing_pin.structuredContent.?.object.get("status").?.string);

    const verify_args = try std.json.parseFromSlice(std.json.Value, arena.allocator(), "{\"backend\":\"zlint\",\"timeout_ms\":111}", .{});
    const verified = try zigarsBackendVerify(allocator, context, verify_args.value);
    defer mcp_result.deinitToolResult(allocator, verified);
    try std.testing.expectEqualStrings("zigars_backend_verify", verified.structuredContent.?.object.get("kind").?.string);

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

    const report = try zigarsTrustReport(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, report);
    try std.testing.expectEqualStrings("zigars_trust_report", report.structuredContent.?.object.get("kind").?.string);

    const gate = try zigarsCleanTreeGate(allocator, context, null);
    defer mcp_result.deinitToolResult(allocator, gate);
    try std.testing.expect(gate.structuredContent.?.object.get("clean").?.bool);

    try std.testing.expectError(error.OutOfMemory, finish(allocator, "test_tool", "test_operation", error.OutOfMemory));
    const port_error = try finish(allocator, "test_tool", "test_operation", error.AccessDenied);
    defer mcp_result.deinitToolResult(allocator, port_error);
    try std.testing.expect(port_error.is_error);

    try commands.verify();
    try workspace.verify();
}

/// Creates test environment context from the ports required by the adapter.
fn testEnvironmentContext(command_runner: ports.CommandRunner, workspace_store: ports.WorkspaceStore, workspace_scanner: ports.WorkspaceScanner) app_context.EnvironmentContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
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

/// Creates test trust context from the ports required by the adapter.
fn testTrustContext(command_runner: ports.CommandRunner, workspace_store: ports.WorkspaceStore, tool_manifest: ports.ToolManifestCatalog) app_context.TrustContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .tool_paths = .{},
        .timeouts = .{ .command_ms = 12_000, .zls_ms = 30_000 },
        .command_runner = command_runner,
        .workspace_store = workspace_store,
        .tool_manifest = tool_manifest,
    };
}
