const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const environment = @import("../../../app/usecases/environment/workflows.zig");
const adoption = @import("../../../app/usecases/environment/adoption.zig");
const trust = @import("../../../app/usecases/environment/trust.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

pub fn zigarSetupElicit(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_setup_elicit", environment.zigarSetupElicit);
}

pub fn zigarProfileElicit(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_profile_elicit", environment.zigarProfileElicit);
}

pub fn zigarBackendElicit(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_backend_elicit", environment.zigarBackendElicit);
}

pub fn zigarProjectProfileV2(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_project_profile_v2", environment.zigarProjectProfileV2);
}

pub fn zigarProfileValidate(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_profile_validate", environment.zigarProfileValidate);
}

pub fn zigarProfileRead(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_profile_read", environment.zigarProfileRead);
}

pub fn zigarProfileBootstrap(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_profile_bootstrap", environment.zigarProfileBootstrap);
}

pub fn zigarProfileImport(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_profile_import", environment.zigarProfileImport);
}

pub fn zigarProfileDiff(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_profile_diff", environment.zigarProfileDiff);
}

pub fn zigarEnvPack(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_env_pack", environment.zigarEnvPack);
}

pub fn zigarEnvExport(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_env_export", environment.zigarEnvExport);
}

pub fn zigarZvmProbe(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_zvm_probe", environment.zigarZvmProbe);
}

pub fn zigarZvmInstallPlan(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_zvm_install_plan", environment.zigarZvmInstallPlan);
}

pub fn zigarZvmSwitchPlan(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_zvm_switch_plan", environment.zigarZvmSwitchPlan);
}

pub fn zigZlsMatchCheck(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zig_zls_match_check", environment.zigZlsMatchCheck);
}

pub fn zigToolchainPin(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zig_toolchain_pin", environment.zigToolchainPin);
}

pub fn zigToolchainPinCheck(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zig_toolchain_pin_check", environment.zigToolchainPinCheck);
}

pub fn zigarBackendInstallPlan(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_backend_install_plan", environment.zigarBackendInstallPlan);
}

pub fn zigarBackendVerify(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_backend_verify", environment.zigarBackendVerify);
}

pub fn zigarDevEnvGenerate(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_dev_env_generate", environment.zigarDevEnvGenerate);
}

pub fn zigarBackendConformance(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_backend_conformance", environment.zigarBackendConformance);
}

pub fn zigarBackendEvidencePack(allocator: std.mem.Allocator, context: app_context.EnvironmentContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeEnvironment(allocator, context, args, "zigar_backend_evidence_pack", environment.zigarBackendEvidencePack);
}

pub fn zigarAdoptionPack(allocator: std.mem.Allocator, context: app_context.AdoptionContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeAdoption(allocator, context, args, "zigar_adoption_pack", adoption.zigarAdoptionPack);
}

pub fn zigarClientConfigGenerate(allocator: std.mem.Allocator, context: app_context.AdoptionContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeAdoption(allocator, context, args, "zigar_client_config_generate", adoption.zigarClientConfigGenerate);
}

pub fn zigarSmokePlan(allocator: std.mem.Allocator, context: app_context.AdoptionContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeAdoption(allocator, context, args, "zigar_smoke_plan", adoption.zigarSmokePlan);
}

pub fn zigarConformanceReport(allocator: std.mem.Allocator, context: app_context.AdoptionContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeAdoption(allocator, context, args, "zigar_conformance_report", adoption.zigarConformanceReport);
}

pub fn zigarTrustReport(allocator: std.mem.Allocator, context: app_context.TrustContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeTrust(allocator, context, args, "zigar_trust_report", trust.zigarTrustReport);
}

pub fn zigarCommandProvenance(allocator: std.mem.Allocator, context: app_context.TrustContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeTrust(allocator, context, args, "zigar_command_provenance", trust.zigarCommandProvenance);
}

pub fn zigarRiskAudit(allocator: std.mem.Allocator, context: app_context.TrustContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeTrust(allocator, context, args, "zigar_risk_audit", trust.zigarRiskAudit);
}

pub fn zigarCleanTreeGate(allocator: std.mem.Allocator, context: app_context.TrustContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invokeTrust(allocator, context, args, "zigar_clean_tree_gate", trust.zigarCleanTreeGate);
}

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

fn finish(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, maybe_result: anyerror!environment.Result) mcp.tools.ToolError!mcp.tools.ToolResult {
    const result = maybe_result catch |err| return usecaseError(allocator, tool_name, operation, err);
    if (result.is_error) {
        defer mcp_result.deinitOwnedValue(allocator, result.value);
        return mcp_result.structuredError(allocator, result.value);
    }
    return mcp_result.structuredOwned(allocator, result.value);
}

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
