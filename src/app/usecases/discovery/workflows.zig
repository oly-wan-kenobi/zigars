//! Discovery workflows for workspace metadata, tool catalogs, and runtime status.
//!
//! Functions project existing app context into allocator-owned JSON without
//! mutating source files.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const backend_contracts = @import("../../../domain/zig/backend_contracts.zig");
const backend_catalog = @import("../environment/backend_catalog.zig");
const env_doctor = @import("../environment/doctor.zig");
const static_project = @import("../static_analysis/project_values.zig");

/// Error set returned by toolchain workflow failures.
pub const ToolchainError = std.mem.Allocator.Error || ports.PortError || app_context.ContextError;

/// Collects failures surfaced by planning operations.
/// MissingTool: `request.tool` was null.
/// UnknownTool: `request.tool` is not in the manifest.
/// MissingFile/MissingPath: a required operand was absent.
/// InvalidExtraArgs: unbalanced quoting or unterminated escape in `request.args`.
pub const PlanError = error{
    MissingTool,
    UnknownTool,
    MissingFile,
    MissingPath,
    InvalidExtraArgs,
} || std.mem.Allocator.Error || ports.PortError || app_context.ContextError;

/// Carries plan request data across use case and port boundaries.
pub const PlanRequest = struct {
    tool: ?[]const u8 = null,
    file: ?[]const u8 = null,
    path: ?[]const u8 = null,
    args: []const u8 = "",
    timeout_ms: i64 = 30_000,
};

/// Carries probe report data across use case and port boundaries.
/// `owns_memory` marks whether `status` and `resolution` were heap-allocated by
/// this module. Callers must call `deinit` to avoid leaks; the guard makes
/// it safe to call unconditionally on both heap and static-string variants.
pub const ProbeReport = struct {
    ok: bool,
    status: []const u8,
    resolution: []const u8,
    owns_memory: bool = false,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: ProbeReport, allocator: std.mem.Allocator) void {
        if (!self.owns_memory) return;
        allocator.free(self.status);
        allocator.free(self.resolution);
    }
};

/// Renders the tool catalog as human-readable text, returned in `allocator`-owned
/// storage. The caller owns the returned slice and must free it. Requires a
/// tool-catalog port; absence surfaces as a context error.
pub fn catalogText(allocator: std.mem.Allocator, context: app_context.Context) ![]u8 {
    const tool_catalog = try context.requireToolCatalog();
    const rendered = try tool_catalog.text(allocator);
    defer rendered.deinit(allocator);
    return try allocator.dupe(u8, rendered.text);
}

/// Serializes backend catalog fields into an allocator-owned JSON value; allocation failures propagate.
pub fn backendCatalogValue(allocator: std.mem.Allocator, context: app_context.Context, include_configured_paths: bool) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return backend_catalog.value(allocator, .{
        .zig_path = context.tool_paths.zig,
        .zls_path = context.tool_paths.zls,
        .zlint_path = context.tool_paths.zlint,
        .zwanzig_path = context.tool_paths.zwanzig,
        .zflame_path = context.tool_paths.zflame,
        .diff_folded_path = context.tool_paths.diff_folded,
    }, include_configured_paths);
}

/// Serializes doctor fields into an allocator-owned JSON value; allocation failures propagate.
pub fn doctorValue(allocator: std.mem.Allocator, context: app_context.Context, probe_backends: bool, probe_timeout_ms: i64) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var checks = std.json.Array.init(allocator);
    try checks.append(try checkValue(allocator, "workspace", true, "configured", context.workspace.root));
    try checks.append(try checkValue(allocator, "cache", true, "configured", context.workspace.cache_root));
    try checks.append(try checkValue(allocator, "workspace_boundary", true, "realpath", "workspace root, existing input paths, existing output files, and output parents are canonicalized; symlink escapes are rejected"));
    try checks.append(try checkValue(allocator, "mcp_dependency", true, "mcp.zig 0.0.5", "use mcp.zig 0.0.5 or newer"));
    try checks.append(try checkValue(allocator, "mcp_tools_list_schema", true, "rich", "tools/list publishes registered inputSchema properties and required fields"));
    try checks.append(try checkValue(allocator, "http_transport", true, "available", "HTTP is available; stdio remains the safest default for Codex sessions"));
    try checks.append(try checkValue(allocator, "zls_session", std.mem.eql(u8, context.zls_state.status, "connected"), context.zls_state.status, if (std.mem.eql(u8, context.zls_state.status, "connected")) "ZLS-backed tools are available" else context.zls_state.last_failure orelse "ZLS-backed tools require a working zls binary"));
    try checks.append(try checkValue(allocator, "zlint_backend_path", true, "configured", context.tool_paths.zlint));
    try checks.append(try checkValue(allocator, "zwanzig_backend_path", true, "configured", context.tool_paths.zwanzig));
    try checks.append(try checkValue(allocator, "zflame_backend_path", true, "configured", context.tool_paths.zflame));
    try checks.append(try checkValue(allocator, "diff_folded_backend_path", true, "configured", context.tool_paths.diff_folded));
    if (probe_backends) {
        try appendProbeCheck(allocator, &checks, "zig_probe", context, .zig, context.tool_paths.zig, probe_timeout_ms);
        try appendProbeCheck(allocator, &checks, "zls_probe", context, .zls, context.tool_paths.zls, probe_timeout_ms);
        try appendProbeCheck(allocator, &checks, "zlint_probe", context, .zlint, context.tool_paths.zlint, probe_timeout_ms);
        try appendProbeCheck(allocator, &checks, "zwanzig_probe", context, .zwanzig, context.tool_paths.zwanzig, probe_timeout_ms);
        try appendProbeCheck(allocator, &checks, "zflame_probe", context, .zflame, context.tool_paths.zflame, probe_timeout_ms);
        try appendProbeCheck(allocator, &checks, "diff_folded_probe", context, .diff_folded, context.tool_paths.diff_folded, probe_timeout_ms);
    }
    try appendZigVersionPreflightCheck(allocator, &checks, context, probe_backends, probe_timeout_ms);

    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_doctor" });
    try obj.put(allocator, "workspace", .{ .string = context.workspace.root });
    try obj.put(allocator, "transport", .{ .string = context.workspace.transport });
    try obj.put(allocator, "zig_path", .{ .string = context.tool_paths.zig });
    try obj.put(allocator, "zls_path", .{ .string = context.tool_paths.zls });
    try obj.put(allocator, "zlint_path", .{ .string = context.tool_paths.zlint });
    try obj.put(allocator, "zwanzig_path", .{ .string = context.tool_paths.zwanzig });
    try obj.put(allocator, "zflame_path", .{ .string = context.tool_paths.zflame });
    try obj.put(allocator, "diff_folded_path", .{ .string = context.tool_paths.diff_folded });
    try obj.put(allocator, "timeout_ms", .{ .integer = context.timeouts.command_ms });
    try obj.put(allocator, "zls_timeout_ms", .{ .integer = context.timeouts.zls_ms });
    try obj.put(allocator, "checks", .{ .array = checks });
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes workspace info fields into an allocator-owned JSON value; allocation failures propagate.
pub fn workspaceInfoValue(allocator: std.mem.Allocator, context: app_context.Context) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "workspace", .{ .string = context.workspace.root });
    try obj.put(allocator, "cache", .{ .string = context.workspace.cache_root });
    try obj.put(allocator, "zig", .{ .string = context.tool_paths.zig });
    try obj.put(allocator, "zls", .{ .string = context.tool_paths.zls });
    try obj.put(allocator, "zls_status", .{ .string = context.zls_state.status });
    try obj.put(allocator, "zls_session", try zlsStatusValue(allocator, context.zls_state));
    if (context.zls_state.last_failure) |failure| {
        try obj.put(allocator, "zls_last_failure", .{ .string = failure });
    } else {
        try obj.put(allocator, "zls_last_failure", .null);
    }
    try obj.put(allocator, "zwanzig", .{ .string = context.tool_paths.zwanzig });
    try obj.put(allocator, "zflame", .{ .string = context.tool_paths.zflame });
    try obj.put(allocator, "diff_folded", .{ .string = context.tool_paths.diff_folded });
    try obj.put(allocator, "optional_backends", try optionalBackendStatusValue(allocator, context));
    try obj.put(allocator, "timeout_ms", .{ .integer = context.timeouts.command_ms });
    try obj.put(allocator, "zls_timeout_ms", .{ .integer = context.timeouts.zls_ms });
    try obj.put(allocator, "workspace_boundary", .{ .string = "realpath" });
    try obj.put(allocator, "symlink_escapes", .{ .string = "rejected" });
    try obj.put(allocator, "backend_probe_cache", try probeCacheValue(allocator, context.trust_probe_cache));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes metrics fields into an allocator-owned JSON value; allocation failures propagate.
pub fn metricsValue(allocator: std.mem.Allocator, context: app_context.Context) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "command_calls", .{ .integer = if (context.counters.command_calls) |counter| @intCast(counter.*) else 0 });
    try obj.put(allocator, "zls_requests", .{ .integer = if (context.counters.zls_requests) |counter| @intCast(counter.*) else 0 });
    try obj.put(allocator, "tool_errors", .{ .integer = if (context.counters.tool_errors) |counter| @intCast(counter.*) else 0 });
    try obj.put(allocator, "zls_status", .{ .string = context.zls_state.status });
    try obj.put(allocator, "zls_session", try zlsStatusValue(allocator, context.zls_state));
    try obj.put(allocator, "backend_probe_cache", try probeCacheValue(allocator, context.trust_probe_cache));
    try obj.put(allocator, "analysis_cache", try cacheStatusValue(allocator, context.caches.analysis));
    try obj.put(allocator, "semantic_index_cache", try cacheStatusValue(allocator, context.caches.semantic_index));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes http status fields into an allocator-owned JSON value; allocation failures propagate.
pub fn httpStatusValue(allocator: std.mem.Allocator, context: app_context.Context) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "configured_transport", .{ .string = context.workspace.transport });
    try obj.put(allocator, "host", .{ .string = context.workspace.host });
    try obj.put(allocator, "port", .{ .integer = context.workspace.port });
    try obj.put(allocator, "http_available", .{ .bool = true });
    try obj.put(allocator, "reason", .{ .string = "HTTP transport and rich tools/list schemas are enabled through mcp.zig 0.0.5; zigars only supports loopback HTTP by default and stdio remains the safest default for Codex" });
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes toolchain resolve fields into an allocator-owned JSON value; allocation failures propagate.
pub fn toolchainResolveValue(
    allocator: std.mem.Allocator,
    context: app_context.Context,
    probe_managers: bool,
    timeout_ms: i64,
) ToolchainError!std.json.Value {
    const runner = try context.requireCommandRunner();
    const workspace = try context.requireWorkspace();
    // Version probes are observational: command failures become unknown fields
    // so project hints can still be reported.
    const zig = runner.run(allocator, .{
        .argv = &.{ context.tool_paths.zig, "version" },
        .cwd = context.workspace.root,
        .timeout_ms = @intCast(timeout_ms),
        .provenance = "discovery.toolchain_resolve.zig",
    }) catch null;
    defer if (zig) |r| r.deinit(allocator);
    const zls = runner.run(allocator, .{
        .argv = &.{ context.tool_paths.zls, "--version" },
        .cwd = context.workspace.root,
        .timeout_ms = @intCast(timeout_ms),
        .provenance = "discovery.toolchain_resolve.zls",
    }) catch null;
    defer if (zls) |r| r.deinit(allocator);

    var expected = std.json.Array.init(allocator);
    tryAppendVersionHint(allocator, workspace, &expected, ".zigversion", "first non-empty line", ".zigversion");
    tryAppendToolVersionsHint(allocator, workspace, &expected);
    tryAppendMiseHint(allocator, workspace, &expected);
    tryAppendBuildZonMinimumHint(allocator, workspace, &expected);

    const active_zig = if (zig) |r| std.mem.trim(u8, r.stdout, " \t\r\n") else "";
    var issues = std.json.Array.init(allocator);
    var zig_hint_count: usize = 0;
    var exact_match_found = false;
    var minimum_satisfied = false;
    var unknown_version_hint = false;
    // Compare active Zig against every discovered hint while preserving the
    // hint objects for the response payload.
    for (expected.items) |hint| {
        const hint_obj = switch (hint) {
            .object => |o| o,
            else => continue,
        };
        switch (zigVersionHintStatus(active_zig, hint_obj)) {
            .ignored => {},
            .exact_match => {
                zig_hint_count += 1;
                exact_match_found = true;
            },
            .minimum_satisfied => {
                zig_hint_count += 1;
                minimum_satisfied = true;
            },
            .mismatch => zig_hint_count += 1,
            .unknown => {
                zig_hint_count += 1;
                unknown_version_hint = true;
            },
        }
    }
    const version_match = zig_hint_count == 0 or exact_match_found or minimum_satisfied;
    const version_status = if (zig_hint_count == 0)
        "no_zig_hints"
    else if (exact_match_found)
        "exact_match"
    else if (minimum_satisfied)
        "minimum_satisfied"
    else if (active_zig.len == 0 or unknown_version_hint)
        "unknown"
    else
        "mismatch";
    if (zig_hint_count > 0 and active_zig.len > 0 and !version_match) {
        try issues.append(.{ .string = try std.fmt.allocPrint(allocator, "active zig version `{s}` does not satisfy any project Zig version hint", .{active_zig}) });
    }
    if (zig == null or zig.?.effectiveTerm().failed()) {
        try issues.append(try ownedString(allocator, "configured --zig-path is not executable or did not return a version"));
    }
    if (zls == null or zls.?.effectiveTerm().failed()) {
        try issues.append(try ownedString(allocator, "configured --zls-path is unavailable; ZLS-backed tools will be limited"));
    }

    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_toolchain_resolve" });
    try obj.put(allocator, "workspace", .{ .string = context.workspace.root });
    try obj.put(allocator, "zig_path", .{ .string = context.tool_paths.zig });
    try obj.put(allocator, "zig_version", if (zig) |r| try ownedString(allocator, std.mem.trim(u8, r.stdout, " \t\r\n")) else .null);
    try obj.put(allocator, "zig_ok", .{ .bool = if (zig) |r| !r.effectiveTerm().failed() else false });
    try obj.put(allocator, "zls_path", .{ .string = context.tool_paths.zls });
    try obj.put(allocator, "zls_version", if (zls) |r| try ownedString(allocator, std.mem.trim(u8, if (r.stdout.len > 0) r.stdout else r.stderr, " \t\r\n")) else .null);
    try obj.put(allocator, "zls_ok", .{ .bool = if (zls) |r| !r.effectiveTerm().failed() else false });
    try obj.put(allocator, "project_version_hints", .{ .array = expected });
    try obj.put(allocator, "version_match", .{ .bool = version_match });
    try obj.put(allocator, "zig_hint_count", .{ .integer = @intCast(zig_hint_count) });
    try obj.put(allocator, "version_status", .{ .string = version_status });
    try obj.put(allocator, "managers", try versionManagersValue(allocator, runner, context.workspace.root, probe_managers, timeout_ms));
    try obj.put(allocator, "issues", .{ .array = issues });
    try obj.put(allocator, "resolution", .{ .string = "Use an existing manager such as mise, asdf, zvm, or zigup to install/select the expected Zig version, then restart zigars with matching --zig-path and --zls-path." });
    obj_owned = false;
    return .{ .object = obj };
}

/// Builds the `zig_command_plan` result: an exact argv/cwd/timeout plan for
/// command-backed tools, or an "unsupported" payload pointing at `zig_tool_plan`
/// for every other plan kind. Plans only: no command is executed here. Returns
/// MissingTool when `request.tool` is null and UnknownTool when it is not
/// registered. The value is owned by `allocator`.
pub fn commandPlanValue(allocator: std.mem.Allocator, context: app_context.Context, request: PlanRequest) PlanError!std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const tool_name = request.tool orelse return error.MissingTool;
    const catalog = try context.requireToolManifest();
    const entry = catalog.find(tool_name) orelse return error.UnknownTool;
    return switch (entry.plan) {
        .exact_command => |plan| try exactCommandPlanValue(allocator, context, request, entry, plan, "zig_command_plan"),
        else => try commandPlanUnsupportedValue(allocator, catalog, entry),
    };
}

/// Builds the `zig_tool_plan` result: an exact argv plan for command-backed
/// tools, otherwise a typed policy describing how the tool is dispatched (ZLS
/// request, apply-gated mutation, workspace artifact, pure analysis, or not
/// plannable). Same MissingTool/UnknownTool semantics as `commandPlanValue`.
pub fn toolPlanValue(allocator: std.mem.Allocator, context: app_context.Context, request: PlanRequest) PlanError!std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const tool_name = request.tool orelse return error.MissingTool;
    const catalog = try context.requireToolManifest();
    const entry = catalog.find(tool_name) orelse return error.UnknownTool;
    return switch (entry.plan) {
        .exact_command => |plan| try exactCommandPlanValue(allocator, context, request, entry, plan, "zig_tool_plan"),
        else => try toolPlanPolicyValue(allocator, entry),
    };
}

/// Assembles the exact argv (zig path first), cwd, and clamped timeout for a
/// command-backed tool. Any file/path operand is resolved through the workspace
/// store so the planned argv only references sandbox-relative paths; a missing
/// required operand yields MissingFile/MissingPath and unbalanced extra-arg
/// quoting yields InvalidExtraArgs. The value is owned by `allocator`.
fn exactCommandPlanValue(
    allocator: std.mem.Allocator,
    context: app_context.Context,
    request: PlanRequest,
    entry: ports.ToolManifestEntry,
    plan: ports.CommandPlan,
    planner_name: []const u8,
) PlanError!std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var resolved_path: ?ports.WorkspaceResolveResult = null;
    defer if (resolved_path) |value| value.deinit(allocator);
    try list.append(allocator, context.tool_paths.zig);
    const workspace = try context.requireWorkspace();

    switch (plan) {
        .argv => |argv| try list.appendSlice(allocator, argv),
        .optional_file => |file_plan| {
            if (request.file) |file| {
                resolved_path = try workspace.resolve(allocator, .{ .path = file, .provenance = planner_name });
                try list.appendSlice(allocator, file_plan.file_args);
                try list.append(allocator, resolved_path.?.path);
            } else {
                try list.appendSlice(allocator, file_plan.fallback_args);
            }
        },
        .required_file => |argv| {
            const file = request.file orelse return error.MissingFile;
            resolved_path = try workspace.resolve(allocator, .{ .path = file, .provenance = planner_name });
            try list.appendSlice(allocator, argv);
            try list.append(allocator, resolved_path.?.path);
        },
        .required_path => |argv| {
            const path = request.path orelse return error.MissingPath;
            resolved_path = try workspace.resolve(allocator, .{ .path = path, .provenance = planner_name });
            try list.appendSlice(allocator, argv);
            try list.append(allocator, resolved_path.?.path);
        },
    }
    const extra = splitArgs(allocator, request.args) catch return error.InvalidExtraArgs;
    defer freeArgList(allocator, extra);
    try list.appendSlice(allocator, extra);

    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try putPlanningBase(allocator, &obj, planner_name, entry, true);
    try obj.put(allocator, "command_backed", .{ .bool = true });
    try obj.put(allocator, "argv_exact", .{ .bool = true });
    try obj.put(allocator, "cwd", .{ .string = context.workspace.root });
    try obj.put(allocator, "argv", try argvValue(allocator, list.items));
    try obj.put(allocator, "timeout_ms", .{ .integer = @max(1, @min(request.timeout_ms, 60 * 60 * 1000)) });
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes command plan unsupported fields into an allocator-owned JSON value; allocation failures propagate.
fn commandPlanUnsupportedValue(allocator: std.mem.Allocator, catalog: ports.ToolManifestCatalog, entry: ports.ToolManifestEntry) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try putPlanningBase(allocator, &obj, "zig_command_plan", entry, false);
    try obj.put(allocator, "command_backed", .{ .bool = false });
    try obj.put(allocator, "argv_exact", .{ .bool = false });
    try obj.put(allocator, "reason", .{ .string = "zig_command_plan only returns exact argv/cwd/timeout plans for command-backed tools." });
    try obj.put(allocator, "use", .{ .string = "zig_tool_plan" });
    try obj.put(allocator, "supported_tools", try supportedCommandToolsValue(allocator, catalog));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes tool plan policy fields into an allocator-owned JSON value; allocation failures propagate.
fn toolPlanPolicyValue(allocator: std.mem.Allocator, entry: ports.ToolManifestEntry) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    const supported = switch (entry.plan) {
        .not_plannable => false,
        else => true,
    };
    try putPlanningBase(allocator, &obj, "zig_tool_plan", entry, supported);
    try putPlanPolicyDetails(allocator, &obj, entry);
    obj_owned = false;
    return .{ .object = obj };
}

/// Writes the fields that every plan response shares: kind, tool name,
/// registration state, support flag, plan kind label, group, description, risk
/// detail object, risk level, source-write flag, and read-only flag.
fn putPlanningBase(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, planner_name: []const u8, entry: ports.ToolManifestEntry, supported: bool) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    try obj.put(allocator, "kind", .{ .string = planner_name });
    try obj.put(allocator, "tool", .{ .string = entry.name });
    try obj.put(allocator, "registered", .{ .bool = true });
    try obj.put(allocator, "supported", .{ .bool = supported });
    try obj.put(allocator, "plan_kind", .{ .string = entry.plan_kind });
    try obj.put(allocator, "group", .{ .string = entry.group });
    try obj.put(allocator, "description", .{ .string = entry.description });
    try obj.put(allocator, "read_only", .{ .bool = entry.read_only });
    try obj.put(allocator, "risk", try riskValue(allocator, entry.risk));
    try obj.put(allocator, "risk_level", .{ .string = riskLevel(entry.risk) });
    try obj.put(allocator, "writes_source", .{ .bool = entry.risk.writes_source });
}

/// Writes plan-kind-specific policy fields into `obj`. Each branch is
/// exclusive; exact_command entries have no extra fields beyond the base.
fn putPlanPolicyDetails(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, entry: ports.ToolManifestEntry) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    switch (entry.plan) {
        .exact_command => return,
        .dynamic_command => |reason| {
            try obj.put(allocator, "command_backed", .{ .bool = true });
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .zls_request => |plan| {
            try obj.put(allocator, "command_backed", .{ .bool = false });
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "backend", .{ .string = "zls" });
            try obj.put(allocator, "method", .{ .string = plan.method });
            try obj.put(allocator, "requires_document_sync", .{ .bool = plan.requires_document_sync });
            try obj.put(allocator, "mutates_document_state", .{ .bool = plan.mutates_document_state });
            try obj.put(allocator, "required_capability", if (plan.required_capability) |capability| .{ .string = capability } else .null);
        },
        .apply_gated_mutation => |reason| {
            try obj.put(allocator, "command_backed", .{ .bool = entry.risk.executes_backend });
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "apply_gated", .{ .bool = true });
            try obj.put(allocator, "preview_by_default", .{ .bool = entry.risk.preview_by_default });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .workspace_artifact => |reason| {
            try obj.put(allocator, "command_backed", .{ .bool = entry.risk.executes_backend });
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "writes_artifact", .{ .bool = true });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .pure_analysis => |reason| {
            try obj.put(allocator, "command_backed", .{ .bool = false });
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .not_plannable => |reason| {
            try obj.put(allocator, "command_backed", .{ .bool = false });
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
    }
}

/// Serializes supported command tools fields into an allocator-owned JSON value; allocation failures propagate.
fn supportedCommandToolsValue(allocator: std.mem.Allocator, catalog: ports.ToolManifestCatalog) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (0..catalog.count()) |index| {
        const entry = catalog.entryAt(index) orelse continue;
        switch (entry.plan) {
            .exact_command => try array.append(.{ .string = entry.name }),
            else => {},
        }
    }
    array_owned = false;
    return .{ .array = array };
}

/// Serializes risk fields into an allocator-owned JSON value; allocation failures propagate.
fn riskValue(allocator: std.mem.Allocator, risk: ports.ToolRisk) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "level", .{ .string = riskLevel(risk) });
    try obj.put(allocator, "writes_source", .{ .bool = risk.writes_source });
    try obj.put(allocator, "writes_artifacts", .{ .bool = risk.writes_artifacts });
    try obj.put(allocator, "writes_require_apply", .{ .bool = risk.writes_require_apply });
    try obj.put(allocator, "preview_by_default", .{ .bool = risk.preview_by_default });
    try obj.put(allocator, "mutates_lsp_state", .{ .bool = risk.mutates_lsp_state });
    try obj.put(allocator, "executes_project_code", .{ .bool = risk.executes_project_code });
    try obj.put(allocator, "executes_user_command", .{ .bool = risk.executes_user_command });
    try obj.put(allocator, "executes_backend", .{ .bool = risk.executes_backend });
    return .{ .object = obj };
}

/// Collapses the structured risk flags into a coarse high/medium/low label:
/// source writes (or apply-gated writes) are high; anything that runs code,
/// writes artifacts, or mutates LSP state is medium; everything else is low.
fn riskLevel(risk: ports.ToolRisk) []const u8 {
    if (risk.writes_source or risk.writes_require_apply) return "high";
    if (risk.executes_project_code or risk.executes_user_command or risk.writes_artifacts or risk.mutates_lsp_state) return "medium";
    return "low";
}

/// Serializes argv fields into an allocator-owned JSON value; allocation failures propagate.
fn argvValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (argv) |arg| try array.append(try ownedString(allocator, arg));
    return .{ .array = array };
}

/// Releases arg list allocations; callers must not reuse freed items.
fn freeArgList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

/// Parses shell-like argument text into an allocator-owned slice of owned
/// argument strings. Supports backslash escaping, single-quoted literals
/// (no escaping inside), and double-quoted literals. An unterminated quote or
/// a trailing backslash returns InvalidArguments. The caller must free the
/// slice and each element with `freeArgList`.
fn splitArgs(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var list: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
        current.deinit(allocator);
    }

    var quote: ?u8 = null;
    var escaping = false;
    var in_token = false;
    for (text) |c| {
        if (escaping) {
            try current.append(allocator, c);
            in_token = true;
            escaping = false;
            continue;
        }
        if (c == '\\') {
            escaping = true;
            in_token = true;
            continue;
        }
        if (quote) |q| {
            if (c == q) {
                quote = null;
            } else {
                try current.append(allocator, c);
            }
            in_token = true;
            continue;
        }
        switch (c) {
            '\'', '"' => {
                quote = c;
                in_token = true;
            },
            ' ', '\t', '\r', '\n' => {
                if (in_token) {
                    try finishArg(allocator, &list, &current);
                    in_token = false;
                }
            },
            else => {
                try current.append(allocator, c);
                in_token = true;
            },
        }
    }
    if (escaping or quote != null) return error.InvalidArguments;
    if (in_token) try finishArg(allocator, &list, &current);
    return list.toOwnedSlice(allocator);
}

/// Moves the in-progress token into the argument list, transferring ownership
/// of the token bytes to `list` (freed by the caller on error via errdefer).
fn finishArg(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), current: *std.ArrayList(u8)) !void {
    const arg = try current.toOwnedSlice(allocator);
    var arg_owned = true;
    defer if (arg_owned) allocator.free(arg);
    try list.append(allocator, arg);
    arg_owned = false;
}

/// Classification of one project Zig version hint relative to the active binary.
pub const ZigVersionHintStatus = enum {
    ignored,
    exact_match,
    minimum_satisfied,
    mismatch,
    unknown,
};

/// Classifies one project version hint against the active Zig version. Hints
/// keyed for ZLS are `.ignored`; a `minimum_zig_version` hint is satisfied when
/// the active version is at least the minimum, otherwise mismatched; any other
/// key requires an exact string match. Unparseable versions yield `.unknown`.
pub fn zigVersionHintStatus(active_zig: []const u8, hint_obj: std.json.ObjectMap) ZigVersionHintStatus {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const key = switch (hint_obj.get("key") orelse .null) {
        .string => |s| s,
        else => return .ignored,
    };
    if (!zigVersionHintAppliesToZig(key)) return .ignored;
    const version_hint = switch (hint_obj.get("version") orelse .null) {
        .string => |s| s,
        else => return .unknown,
    };
    if (active_zig.len == 0) return .unknown;
    if (std.mem.eql(u8, key, "minimum_zig_version")) {
        if (versionMeetsMinimum(active_zig, version_hint)) return .minimum_satisfied;
        if (parseVersionPrefix(active_zig) == null or parseVersionPrefix(version_hint) == null) return .unknown;
        return .mismatch;
    }
    if (std.mem.eql(u8, active_zig, version_hint)) return .exact_match;
    return .mismatch;
}

/// Reports whether a version hint keyed by `key` constrains Zig rather than ZLS.
pub fn zigVersionHintAppliesToZig(key: []const u8) bool {
    return !std.mem.eql(u8, key, "zls");
}

/// Returns true when `active_zig` is at least `minimum_zig` (semver prefix
/// comparison, dev-suffix-aware). Delegates to env_doctor for the comparison
/// logic so version policy stays in one place.
pub fn versionMeetsMinimum(active_zig: []const u8, minimum_zig: []const u8) bool {
    return env_doctor.versionMeetsMinimum(active_zig, minimum_zig);
}

/// Parses the semver prefix (major.minor.patch) from `raw`, ignoring any dev
/// suffix. Returns null when the string cannot be parsed as three numeric
/// components. Exported so tests can exercise version hint classification.
pub fn parseVersionPrefix(raw: []const u8) ?[3]u64 {
    return env_doctor.parseVersionPrefix(raw);
}

/// Serializes probe fields into an allocator-owned JSON value; allocation failures propagate.
fn probeValue(
    allocator: std.mem.Allocator,
    context: app_context.Context,
    id: backend_contracts.BackendId,
    configured_path: []const u8,
    timeout_ms: i64,
) !ProbeReport {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (cachedProbe(context, id)) |probe| return .{
        .ok = probe.ok orelse false,
        .status = probe.status,
        .resolution = probe.resolution,
    };
    const probe = context.ports.backend_probe orelse return .{
        .ok = false,
        .status = "Unavailable",
        .resolution = "backend probe port is unavailable",
    };
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    for (backend_contracts.probeArgv(id), 0..) |arg, index| try argv.append(allocator, if (index == 0) configured_path else arg);
    const availability = probe.check(allocator, .{
        .backend = id.name(),
        .argv = argv.items,
        .cwd = context.workspace.root,
        .timeout_ms = @intCast(timeout_ms),
        .provenance = "discovery.doctor_probe",
    }) catch |err| return .{
        .ok = false,
        .status = @errorName(err),
        .resolution = "confirm the configured backend path and executable permissions",
    };
    defer availability.deinit(allocator);
    return .{
        .ok = availability.available,
        .status = try allocator.dupe(u8, if (availability.available) "ok" else availability.unavailable_reason orelse "unavailable"),
        .resolution = try allocator.dupe(u8, availability.basis),
        .owns_memory = true,
    };
}

/// Appends probe check data into caller-provided storage, propagating allocation failures.
fn appendProbeCheck(
    allocator: std.mem.Allocator,
    checks: *std.json.Array,
    name: []const u8,
    context: app_context.Context,
    id: backend_contracts.BackendId,
    configured_path: []const u8,
    timeout_ms: i64,
) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    const probe = try probeValue(allocator, context, id, configured_path, timeout_ms);
    defer probe.deinit(allocator);
    try checks.append(try probeCheckValue(allocator, name, probe));
}

/// Appends Zig version preflight data into caller-provided storage.
fn appendZigVersionPreflightCheck(
    allocator: std.mem.Allocator,
    checks: *std.json.Array,
    context: app_context.Context,
    probe_backends: bool,
    timeout_ms: i64,
) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    if (!probe_backends) {
        try checks.append(try env_doctor.zigVersionPreflightValue(allocator, .{
            .probe_enabled = false,
            .zig_path = context.tool_paths.zig,
        }));
        return;
    }

    const workspace = context.ports.workspace orelse {
        try checks.append(try env_doctor.zigVersionPreflightValue(allocator, .{
            .zig_path = context.tool_paths.zig,
            .minimum_unavailable_reason = "workspace port unavailable",
        }));
        return;
    };

    const build_zon = workspace.read(allocator, .{
        .path = "build.zig.zon",
        .max_bytes = 256 * 1024,
        .provenance = "discovery.zig_version_preflight",
    }) catch |err| {
        try checks.append(try env_doctor.zigVersionPreflightValue(allocator, .{
            .zig_path = context.tool_paths.zig,
            .minimum_unavailable_reason = @errorName(err),
        }));
        return;
    };
    defer build_zon.deinit(allocator);
    const required_minimum = env_doctor.minimumZigVersionFromBuildZon(build_zon.bytes);
    if (required_minimum == null) {
        try checks.append(try env_doctor.zigVersionPreflightValue(allocator, .{
            .zig_path = context.tool_paths.zig,
            .required_minimum = null,
        }));
        return;
    }

    const runner = context.ports.command_runner orelse {
        try checks.append(try env_doctor.zigVersionPreflightValue(allocator, .{
            .zig_path = context.tool_paths.zig,
            .required_minimum = required_minimum,
            .unavailable_reason = "command runner port unavailable",
        }));
        return;
    };

    const result = runner.run(allocator, .{
        .argv = &.{ context.tool_paths.zig, "version" },
        .cwd = context.workspace.root,
        .timeout_ms = @intCast(@min(timeout_ms, 5000)),
        .max_stdout_bytes = 64 * 1024,
        .max_stderr_bytes = 64 * 1024,
        .provenance = "discovery.zig_version_preflight",
    }) catch |err| {
        try checks.append(try env_doctor.zigVersionPreflightValue(allocator, .{
            .zig_path = context.tool_paths.zig,
            .required_minimum = required_minimum,
            .unavailable_reason = @errorName(err),
        }));
        return;
    };
    defer result.deinit(allocator);

    const stderr_reason = std.mem.trim(u8, if (result.stderr.len > 0) result.stderr else result.effectiveTerm().name(), " \t\r\n");
    try checks.append(try env_doctor.zigVersionPreflightValue(allocator, .{
        .zig_path = context.tool_paths.zig,
        .observed_version = std.mem.trim(u8, result.stdout, " \t\r\n"),
        .required_minimum = required_minimum,
        .unavailable_reason = if (result.effectiveTerm().failed()) stderr_reason else null,
    }));
}

/// Serializes check fields into an allocator-owned JSON value; allocation failures propagate.
fn checkValue(allocator: std.mem.Allocator, name: []const u8, ok: bool, status: []const u8, resolution: []const u8) !std.json.Value {
    // Fail fast on the first mismatch to keep diagnostics deterministic.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "name", try ownedString(allocator, name));
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "status", try ownedString(allocator, status));
    try obj.put(allocator, "resolution", try ownedString(allocator, resolution));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes probe check fields into an allocator-owned JSON value; allocation failures propagate.
fn probeCheckValue(allocator: std.mem.Allocator, name: []const u8, probe: ProbeReport) !std.json.Value {
    return checkValue(allocator, name, probe.ok, probe.status, probe.resolution);
}

/// Returns the cached probe entry for `id`, or null when it has never been probed.
/// Callers that receive null must run a live probe or report the backend as unprobed.
fn cachedProbe(context: app_context.Context, id: backend_contracts.BackendId) ?app_context.CachedBackendProbe {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const probe = switch (id) {
        .zig => context.trust_probe_cache.zig,
        .zls => context.trust_probe_cache.zls,
        .zlint => context.trust_probe_cache.zlint,
        .zwanzig => context.trust_probe_cache.zwanzig,
        .zflame => context.trust_probe_cache.zflame,
        .diff_folded => context.trust_probe_cache.diff_folded,
    };
    return if (probe.probed) probe else null;
}

/// Serializes zls status fields into an allocator-owned JSON value; allocation failures propagate.
fn zlsStatusValue(allocator: std.mem.Allocator, state: app_context.ZlsState) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "status", .{ .string = state.status });
    try obj.put(allocator, "running", .{ .bool = state.running });
    try obj.put(allocator, "restart_attempts", .{ .integer = @intCast(state.restart_attempts) });
    try obj.put(allocator, "initialize_response", if (state.initialize_response) |value| .{ .string = value } else .null);
    try obj.put(allocator, "last_failure", if (state.last_failure) |value| .{ .string = value } else .null);
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes optional backend status fields into an allocator-owned JSON value; allocation failures propagate.
fn optionalBackendStatusValue(allocator: std.mem.Allocator, context: app_context.Context) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "zwanzig", try optionalBackendValue(allocator, context, .zwanzig, context.tool_paths.zwanzig, context.trust_probe_cache.zwanzig));
    try obj.put(allocator, "zflame", try optionalBackendValue(allocator, context, .zflame, context.tool_paths.zflame, context.trust_probe_cache.zflame));
    try obj.put(allocator, "diff_folded", try optionalBackendValue(allocator, context, .diff_folded, context.tool_paths.diff_folded, context.trust_probe_cache.diff_folded));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes optional backend fields into an allocator-owned JSON value; allocation failures propagate.
fn optionalBackendValue(allocator: std.mem.Allocator, context: app_context.Context, id: backend_contracts.BackendId, configured_path: []const u8, probe: app_context.CachedBackendProbe) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    _ = context;
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "name", .{ .string = id.name() });
    try obj.put(allocator, "configured_path", .{ .string = configured_path });
    try obj.put(allocator, "probe_argv", try configuredProbeArgvValue(allocator, id, configured_path));
    try obj.put(allocator, "capabilities", try backendCapabilitiesValue(allocator, id));
    try obj.put(allocator, "probe", try cachedProbeValue(allocator, probe));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes configured probe argv fields into an allocator-owned JSON value; allocation failures propagate.
fn configuredProbeArgvValue(allocator: std.mem.Allocator, id: backend_contracts.BackendId, configured_path: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const probe = backend_contracts.probeArgv(id);
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (probe, 0..) |arg, index| {
        try array.append(.{ .string = if (index == 0) configured_path else arg });
    }
    array_owned = false;
    return .{ .array = array };
}

/// Serializes backend capabilities fields into an allocator-owned JSON value; allocation failures propagate.
/// `zig_flamegraph_diff` is appended a second time when id is zflame because
/// diff-folded is a separate backend but zflame drives the diff rendering step;
/// the duplication reflects that zflame requires both backends in that workflow.
fn backendCapabilitiesValue(allocator: std.mem.Allocator, id: backend_contracts.BackendId) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (backend_contracts.capabilities) |capability| {
        if (capability.backend == id) try array.append(.{ .string = capability.tool });
        if (id == .zflame and std.mem.eql(u8, capability.tool, "zig_flamegraph_diff")) try array.append(.{ .string = capability.tool });
    }
    array_owned = false;
    return .{ .array = array };
}

/// Serializes probe cache fields into an allocator-owned JSON value; allocation failures propagate.
fn probeCacheValue(allocator: std.mem.Allocator, cache: app_context.TrustProbeCache) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "zig", try cachedProbeValue(allocator, cache.zig));
    try obj.put(allocator, "zls", try cachedProbeValue(allocator, cache.zls));
    try obj.put(allocator, "zlint", try cachedProbeValue(allocator, cache.zlint));
    try obj.put(allocator, "zwanzig", try cachedProbeValue(allocator, cache.zwanzig));
    try obj.put(allocator, "zflame", try cachedProbeValue(allocator, cache.zflame));
    try obj.put(allocator, "diff_folded", try cachedProbeValue(allocator, cache.diff_folded));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes cached probe fields into an allocator-owned JSON value; allocation failures propagate.
fn cachedProbeValue(allocator: std.mem.Allocator, probe: app_context.CachedBackendProbe) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "probed", .{ .bool = probe.probed });
    if (probe.probed) {
        try obj.put(allocator, "ok", if (probe.ok) |ok| .{ .bool = ok } else .null);
        try obj.put(allocator, "status", .{ .string = probe.status });
        try obj.put(allocator, "resolution", .{ .string = probe.resolution });
    } else {
        try obj.put(allocator, "ok", .null);
        try obj.put(allocator, "status", .{ .string = "not probed" });
        try obj.put(allocator, "resolution", .{ .string = "call zigars_doctor with probe_backends=true to cache backend availability" });
    }
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes cache status fields into an allocator-owned JSON value; allocation failures propagate.
fn cacheStatusValue(allocator: std.mem.Allocator, cache: app_context.CacheSnapshot) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "cached", .{ .bool = cache.cached });
    try obj.put(allocator, "signature", .{ .integer = @intCast(cache.signature) });
    try obj.put(allocator, "hits", .{ .integer = @intCast(cache.hits) });
    try obj.put(allocator, "refreshes", .{ .integer = @intCast(cache.refreshes) });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(cache.bytes) });
    obj_owned = false;
    return .{ .object = obj };
}

/// Best-effort: reads `path` and appends the first non-empty, non-comment line
/// as a version hint. A missing/unreadable file or allocation failure is
/// swallowed so version discovery degrades gracefully.
fn tryAppendVersionHint(allocator: std.mem.Allocator, workspace: ports.WorkspaceStore, hints: *std.json.Array, path: []const u8, key: []const u8, source: []const u8) void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const read = workspace.read(allocator, .{ .path = path, .max_bytes = 64 * 1024, .provenance = "discovery.version_hint" }) catch return;
    defer read.deinit(allocator);
    var lines = std.mem.splitScalar(u8, read.bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;
        appendVersionHint(allocator, hints, source, key, trimmed) catch return;
        return;
    }
}

/// Best-effort: parses `.tool-versions` and appends hints for the `zig` and
/// `zls` rows only, ignoring unrelated tools. Failures are swallowed.
fn tryAppendToolVersionsHint(allocator: std.mem.Allocator, workspace: ports.WorkspaceStore, hints: *std.json.Array) void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const read = workspace.read(allocator, .{ .path = ".tool-versions", .max_bytes = 64 * 1024, .provenance = "discovery.tool_versions_hint" }) catch return;
    defer read.deinit(allocator);
    var lines = std.mem.splitScalar(u8, read.bytes, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeAny(u8, line, " \t\r\n");
        const tool = parts.next() orelse continue;
        if (!std.mem.eql(u8, tool, "zig") and !std.mem.eql(u8, tool, "zls")) continue;
        const version_hint = parts.next() orelse continue;
        appendVersionHint(allocator, hints, ".tool-versions", tool, version_hint) catch return;
    }
}

/// Best-effort: extracts the quoted `zig = "..."` value from `mise.toml`.
/// Failures are swallowed.
fn tryAppendMiseHint(allocator: std.mem.Allocator, workspace: ports.WorkspaceStore, hints: *std.json.Array) void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const read = workspace.read(allocator, .{ .path = "mise.toml", .max_bytes = 128 * 1024, .provenance = "discovery.mise_hint" }) catch return;
    defer read.deinit(allocator);
    var lines = std.mem.splitScalar(u8, read.bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "zig =")) {
            if (static_project.quotedString(trimmed)) |version_hint| appendVersionHint(allocator, hints, "mise.toml", "zig", version_hint) catch return;
        }
    }
}

/// Best-effort: extracts the quoted `minimum_zig_version` value from
/// `build.zig.zon`. Failures are swallowed.
fn tryAppendBuildZonMinimumHint(allocator: std.mem.Allocator, workspace: ports.WorkspaceStore, hints: *std.json.Array) void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const read = workspace.read(allocator, .{ .path = "build.zig.zon", .max_bytes = 256 * 1024, .provenance = "discovery.build_zon_hint" }) catch return;
    defer read.deinit(allocator);
    var lines = std.mem.splitScalar(u8, read.bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.indexOf(u8, trimmed, "minimum_zig_version") != null) {
            if (static_project.quotedString(trimmed)) |version_hint| appendVersionHint(allocator, hints, "build.zig.zon", "minimum_zig_version", version_hint) catch return;
        }
    }
}

/// Appends a `{source, key, version}` hint object to `hints`. Leading/trailing
/// whitespace and quote characters are stripped from `version_value`; an empty
/// result is silently skipped so blank lines in config files produce no hint.
pub fn appendVersionHint(allocator: std.mem.Allocator, hints: *std.json.Array, source: []const u8, key: []const u8, version_value: []const u8) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    const trimmed = std.mem.trim(u8, version_value, " \t\r\n\"'");
    if (trimmed.len == 0) return;
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "source", try ownedString(allocator, source));
    try obj.put(allocator, "key", try ownedString(allocator, key));
    try obj.put(allocator, "version", try ownedString(allocator, trimmed));
    try hints.append(.{ .object = obj });
}

/// Serializes version managers fields into an allocator-owned JSON value; allocation failures propagate.
fn versionManagersValue(allocator: std.mem.Allocator, runner: ports.CommandRunner, cwd: []const u8, probe: bool, timeout_ms: i64) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var managers = std.json.Array.init(allocator);
    const names = [_][]const u8{ "mise", "asdf", "zvm", "zigup" };
    const args = [_][]const u8{ "--version", "--version", "version", "--version" };
    for (names, args) |name, version_arg| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "name", .{ .string = name });
        if (probe) {
            const result = runner.run(allocator, .{
                .argv = &.{ name, version_arg },
                .cwd = cwd,
                .timeout_ms = @intCast(@min(timeout_ms, 3000)),
                .provenance = "discovery.version_manager_probe",
            }) catch null;
            if (result) |r| {
                defer r.deinit(allocator);
                try obj.put(allocator, "available", .{ .bool = !r.effectiveTerm().failed() });
                try obj.put(allocator, "version_output", try ownedString(allocator, std.mem.trim(u8, if (r.stdout.len > 0) r.stdout else r.stderr, " \t\r\n")));
            } else {
                try obj.put(allocator, "available", .{ .bool = false });
                try obj.put(allocator, "version_output", .null);
            }
        } else {
            try obj.put(allocator, "available", .null);
            try obj.put(allocator, "version_output", .null);
        }
        try managers.append(.{ .object = obj });
    }
    return .{ .array = managers };
}

/// Copies the provided string into allocator-owned storage.
fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

test "version prefix accepts Zig dev version strings" {
    try std.testing.expectEqual([3]u64{ 0, 16, 0 }, parseVersionPrefix("0.16.0-dev.123").?);
    try std.testing.expect(versionMeetsMinimum("0.16.1", "0.16.0"));
}

test "discovery private argument splitting covers shell quoting and cleanup paths" {
    const args = try splitArgs(std.testing.allocator, "alpha\\ beta \"gamma delta\" 'epsilon' zeta\\\n");
    defer freeArgList(std.testing.allocator, args);
    try std.testing.expectEqual(@as(usize, 4), args.len);
    try std.testing.expectEqualStrings("alpha beta", args[0]);
    try std.testing.expectEqualStrings("gamma delta", args[1]);
    try std.testing.expectEqualStrings("epsilon", args[2]);
    try std.testing.expectEqualStrings("zeta\n", args[3]);

    try std.testing.expectError(error.InvalidArguments, splitArgs(std.testing.allocator, "\"unterminated"));
    try std.testing.expectError(error.InvalidArguments, splitArgs(std.testing.allocator, "dangling\\"));

    var index: usize = 0;
    var success_seen = false;
    while (index < 64) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        const maybe = splitArgs(failing.allocator(), "one two") catch continue;
        freeArgList(failing.allocator(), maybe);
        success_seen = true;
        break;
    }
    try std.testing.expect(success_seen);
}

test "discovery private helpers cover exact policy details and allocation errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var exact = std.json.ObjectMap.empty;
    try putPlanPolicyDetails(allocator, &exact, .{
        .name = "zig_build",
        .plan = .{ .exact_command = .{ .argv = &.{"build"} } },
    });
    try std.testing.expectEqual(@as(usize, 0), exact.count());

    var tiny_buffer: [8]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&tiny_buffer);
    try std.testing.expectError(error.OutOfMemory, checkValue(fixed.allocator(), "name", true, "status", "resolution"));

    var array = std.json.Array.init(allocator);
    try std.testing.expectError(error.OutOfMemory, argvValue(fixed.allocator(), &.{"too-large"}));
    try std.testing.expectError(error.OutOfMemory, appendVersionHint(fixed.allocator(), &array, "source", "zig", "0.16.0"));
}
