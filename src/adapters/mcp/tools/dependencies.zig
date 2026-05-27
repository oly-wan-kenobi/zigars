//! Dependency and supply-chain MCP adapters over release workflow use cases.
//! Results preserve workflow-owned JSON shapes and normalize thrown errors.
const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const dependency_workflows = @import("../../../app/usecases/dependencies/workflows.zig");
const workflows = @import("../../../app/usecases/release/workflows.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

/// Handles MCP `zig_dependency_update_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDependencyUpdatePlan(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_update_plan", workflows.zigDependencyUpdatePlan);
}

/// Handles MCP `zig_dependency_fetch_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDependencyFetchCheck(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_fetch_check", workflows.zigDependencyFetchCheck);
}

/// Handles MCP `zig_dependency_lock_audit` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDependencyLockAudit(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_lock_audit", workflows.zigDependencyLockAudit);
}

/// Handles MCP `zig_dependency_impact` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDependencyImpact(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_impact", workflows.zigDependencyImpact);
}

/// Handles MCP `zig_sbom` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSbom(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_sbom", workflows.zigSbom);
}

/// Handles MCP `zig_zat_scan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigZatScan(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_zat_scan", workflows.zigZatScan);
}

/// Handles MCP `zig_osv_scan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigOsvScan(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_osv_scan", workflows.zigOsvScan);
}

/// Handles MCP `zig_dependency_security_report` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDependencySecurityReport(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_security_report", workflows.zigDependencySecurityReport);
}

/// Handles MCP `zig_dependency_provenance` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDependencyProvenance(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_provenance", workflows.zigDependencyProvenance);
}

/// Handles MCP `zig_dependency_license_summary` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDependencyLicenseSummary(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_license_summary", workflows.zigDependencyLicenseSummary);
}

/// Handles MCP `zig_github_dependency_submit_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigGithubDependencySubmitPlan(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_github_dependency_submit_plan", workflows.zigGithubDependencySubmitPlan);
}

/// Handles MCP `zig_zon_dep_sync` requests with preview/apply patch-session semantics.
pub fn zigZonDepSync(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_zon_dep_sync", dependency_workflows.zigZonDepSync);
}

/// Handles MCP `zig_deps_add` requests with preview/apply patch-session semantics.
pub fn zigDepsAdd(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_deps_add", dependency_workflows.zigDepsAdd);
}

/// Handles MCP `zig_deps_remove` requests with preview/apply patch-session semantics.
pub fn zigDepsRemove(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_deps_remove", dependency_workflows.zigDepsRemove);
}

/// Handles MCP `zig_deps_upgrade` requests with preview/apply patch-session semantics.
pub fn zigDepsUpgrade(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_deps_upgrade", dependency_workflows.zigDepsUpgrade);
}

/// Handles MCP `zig_pkg_search` requests.
pub fn zigPkgSearch(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_pkg_search", dependency_workflows.zigPkgSearch);
}

/// Handles MCP `zig_pkg_info` requests.
pub fn zigPkgInfo(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_pkg_info", dependency_workflows.zigPkgInfo);
}

/// Handles MCP `zig_pkg_versions` requests.
pub fn zigPkgVersions(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_pkg_versions", dependency_workflows.zigPkgVersions);
}

/// Handles MCP `zig_pkg_readme` requests.
pub fn zigPkgReadme(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_pkg_readme", dependency_workflows.zigPkgReadme);
}

/// Handles MCP `zig_dependency_migrate` requests.
pub fn zigDependencyMigrate(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_migrate", dependency_workflows.zigDependencyMigrate);
}

/// Runs a release/dependency workflow and maps structured failures to MCP errors.
fn invoke(
    allocator: std.mem.Allocator,
    context: app_context.ReleaseWorkflowContext,
    args: ?std.json.Value,
    comptime tool_name: []const u8,
    comptime func: anytype,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var app = workflows.App.init(context, allocator);
    const result = func(&app, allocator, args) catch |err| return usecaseError(allocator, tool_name, err);
    if (result.is_error) {
        defer mcp_result.deinitOwnedValue(allocator, result.value);
        return mcp_result.structuredError(allocator, result.value);
    }
    return mcp_result.structuredOwned(allocator, result.value);
}

/// Maps usecase error failures to structured MCP errors.
fn usecaseError(allocator: std.mem.Allocator, tool_name: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = "dependency_workflow",
        .phase = "run_usecase",
        .code = "dependency_usecase_failed",
        .category = "dependencies",
        .resolution = "Retry after confirming manifest paths, supplied scanner evidence, and workspace inputs.",
    }, err);
}

const fakes = @import("../../../testing/fakes/root.zig");
const manifest_catalog = @import("../../../bootstrap/manifest_catalog.zig");

test "dependency adapter maps structured and thrown usecase failures" {
    const Stub = struct {
        /// Test stub that returns a structured tool failure.
        fn structuredFailure(_: *workflows.App, allocator: std.mem.Allocator, _: ?std.json.Value) !workflows.Result {
            var obj = std.json.ObjectMap.empty;
            const key = try allocator.dupe(u8, "kind");
            var key_owned = true;
            defer if (key_owned) allocator.free(key);
            const value = try allocator.dupe(u8, "dependency_failure");
            var value_owned = true;
            defer if (value_owned) allocator.free(value);
            try obj.put(allocator, key, .{ .string = value });
            key_owned = false;
            value_owned = false;
            return .{ .value = .{ .object = obj }, .is_error = true };
        }

        /// Test stub that throws a tool failure error.
        fn thrownFailure(_: *workflows.App, _: std.mem.Allocator, _: ?std.json.Value) !workflows.Result {
            return error.AccessDenied;
        }

        /// Test stub that simulates allocation failure.
        fn oomFailure(_: *workflows.App, _: std.mem.Allocator, _: ?std.json.Value) !workflows.Result {
            return error.OutOfMemory;
        }
    };

    var runner = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer runner.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var catalog = manifest_catalog.Catalog{};
    const context: app_context.ReleaseWorkflowContext = .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .tool_paths = .{},
        .timeouts = .{},
        .command_runner = runner.port(),
        .workspace_store = workspace.port(),
        .workspace_scanner = scanner.port(),
        .tool_manifest = catalog.port(),
    };

    const structured = try invoke(std.testing.allocator, context, null, "zig_dependency_update_plan", Stub.structuredFailure);
    defer mcp_result.deinitToolResult(std.testing.allocator, structured);
    try std.testing.expect(structured.is_error);
    try std.testing.expectEqualStrings("dependency_failure", structured.structuredContent.?.object.get("kind").?.string);

    const thrown = try invoke(std.testing.allocator, context, null, "zig_dependency_update_plan", Stub.thrownFailure);
    defer mcp_result.deinitToolResult(std.testing.allocator, thrown);
    try std.testing.expect(thrown.is_error);
    try std.testing.expectEqualStrings("tool_error", thrown.structuredContent.?.object.get("kind").?.string);

    try std.testing.expectError(error.OutOfMemory, invoke(std.testing.allocator, context, null, "zig_dependency_update_plan", Stub.oomFailure));
}
