const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const trust_domain = @import("../../../domain/trust.zig");
const support = @import("../usecase_support.zig");

/// Aliases the app context wrapper used by this workflow module.
pub const App = support.UsecaseApp(app_context.TrustContext);
/// Aliases the structured result type returned by workflow entrypoints.
pub const Result = support.Result;

const argBool = support.argBool;
const argString = support.argString;
const invalidArgumentResult = support.invalidArgumentResult;
const structured = support.structured;
const toolTimeout = support.toolTimeout;

/// Executes the zigar trust report workflow and returns an allocator-owned structured result.
pub fn zigarTrustReport(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const include_clean_tree = argBool(args, "include_clean_tree", false);
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_trust_report" });
    try obj.put(allocator, "workspace", try workspaceEvidenceValue(allocator, a));
    try obj.put(allocator, "path_policy", try pathPolicyValue(allocator));
    try obj.put(allocator, "backend_identities", try backendIdentitiesValue(allocator, a));
    try obj.put(allocator, "dependency_hashes", try dependencyHashesValue(allocator, a));
    try obj.put(allocator, "risk_audit", try riskAuditValue(allocator, a, false));
    if (include_clean_tree) {
        try obj.put(allocator, "clean_tree_gate", try cleanTreeGateValue(a, allocator, toolTimeout(a, args)));
    } else {
        try obj.put(allocator, "clean_tree_gate", try cleanTreeNotRunValue(allocator));
    }
    try obj.put(allocator, "limitations", try trust_domain.stringArray(allocator, &.{
        "Reports zigar-observed configuration, manifest metadata, and optional git status only.",
        "Backend paths are configured identities unless a separate probe command has populated probe cache evidence.",
        "Release decisions should verify with zigar_validate_patch mode=full, project CI, and any required release-check path.",
    }));
    const result = try structured(allocator, .{ .object = obj });
    obj_owned = false;
    return result;
}

/// Executes the zigar command provenance workflow and returns an allocator-owned structured result.
pub fn zigarCommandProvenance(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const tool = argString(args, "tool");
    const value = commandProvenanceValue(allocator, a, tool) catch |err| switch (err) {
        error.UnknownTool => return invalidArgumentResult(allocator, "zigar_command_provenance", "tool", "registered zigar tool name", tool orelse "", "Call zigar_tool_index or zigar_schema to choose a registered tool name."),
        else => return err,
    };
    return structured(allocator, value);
}

/// Executes the zigar risk audit workflow and returns an allocator-owned structured result.
pub fn zigarRiskAudit(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return structured(allocator, try riskAuditValue(allocator, a, argBool(args, "include_none", false)));
}

/// Executes the zigar clean tree gate workflow and returns an allocator-owned structured result.
pub fn zigarCleanTreeGate(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return structured(allocator, try cleanTreeGateValue(a, allocator, toolTimeout(a, args)));
}

/// Serializes command provenance fields into an allocator-owned JSON value; allocation failures propagate.
pub fn commandProvenanceValue(allocator: std.mem.Allocator, a: *App, tool_name: ?[]const u8) !std.json.Value {
    if (tool_name) |name| {
        const entry = a.context.tool_manifest.find(name) orelse return error.UnknownTool;
        return provenanceEntryValue(allocator, entry);
    }

    var tools = std.json.Array.init(allocator);
    var tools_owned = true;
    defer if (tools_owned) tools.deinit();
    var index: usize = 0;
    while (index < a.context.tool_manifest.count()) : (index += 1) {
        const entry = a.context.tool_manifest.entryAt(index) orelse continue;
        try tools.append(try provenanceEntryValue(allocator, entry));
    }

    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_command_provenance" });
    try obj.put(allocator, "scope", .{ .string = "all_tools" });
    try obj.put(allocator, "source", try trust_domain.evidenceValue(allocator, "compiled_tool_manifest", "src/manifest/mod.zig", "high"));
    try obj.put(allocator, "tools", .{ .array = tools });
    tools_owned = false;
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes risk audit fields into an allocator-owned JSON value; allocation failures propagate.
pub fn riskAuditValue(allocator: std.mem.Allocator, a: *App, include_none: bool) !std.json.Value {
    var counts = std.json.ObjectMap.empty;
    var counts_owned = true;
    defer if (counts_owned) counts.deinit(allocator);
    try counts.put(allocator, "none", .{ .integer = 0 });
    try counts.put(allocator, "low", .{ .integer = 0 });
    try counts.put(allocator, "medium", .{ .integer = 0 });
    try counts.put(allocator, "high", .{ .integer = 0 });

    var tools = std.json.Array.init(allocator);
    var tools_owned = true;
    defer if (tools_owned) tools.deinit();
    var apply_gated: usize = 0;
    var backend_bound: usize = 0;
    var project_code: usize = 0;
    var user_command: usize = 0;

    var index: usize = 0;
    while (index < a.context.tool_manifest.count()) : (index += 1) {
        const entry = a.context.tool_manifest.entryAt(index) orelse continue;
        const level = trust_domain.riskLevel(domainRisk(entry.risk));
        incrementCount(&counts, level);
        if (entry.risk.writes_require_apply) apply_gated += 1;
        if (entry.risk.executes_backend) backend_bound += 1;
        if (entry.risk.executes_project_code) project_code += 1;
        if (entry.risk.executes_user_command) user_command += 1;
        if (include_none or !std.mem.eql(u8, level, "none")) {
            try tools.append(try riskEntryValue(allocator, entry));
        }
    }

    var summary = std.json.ObjectMap.empty;
    var summary_owned = true;
    defer if (summary_owned) summary.deinit(allocator);
    try summary.put(allocator, "apply_gated_mutations", .{ .integer = @intCast(apply_gated) });
    try summary.put(allocator, "backend_bound_tools", .{ .integer = @intCast(backend_bound) });
    try summary.put(allocator, "executes_project_code_tools", .{ .integer = @intCast(project_code) });
    try summary.put(allocator, "executes_user_command_tools", .{ .integer = @intCast(user_command) });

    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_risk_audit" });
    try obj.put(allocator, "source", try trust_domain.evidenceValue(allocator, "compiled_tool_manifest", "src/manifest/mod.zig", "high"));
    try obj.put(allocator, "counts_by_level", .{ .object = counts });
    counts_owned = false;
    try obj.put(allocator, "summary", .{ .object = summary });
    summary_owned = false;
    try obj.put(allocator, "tools", .{ .array = tools });
    tools_owned = false;
    try obj.put(allocator, "limitations", try trust_domain.stringArray(allocator, &.{
        "Risk metadata describes tool contract classes; dynamic runtime arguments can still affect concrete impact.",
        "Read-only MCP hints are withheld when a tool can execute code, mutate LSP state, or write artifacts.",
    }));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes clean tree gate fields into an allocator-owned JSON value; allocation failures propagate.
pub fn cleanTreeGateValue(a: *App, allocator: std.mem.Allocator, timeout_ms: i64) !std.json.Value {
    const argv = &.{ "git", "status", "--porcelain" };
    const result = support.runCommand(allocator, a, argv, @min(timeout_ms, 5000)) catch |err| {
        return cleanTreeBackendErrorValue(allocator, a.workspace.root, err);
    };
    defer result.deinit(allocator);
    return trust_domain.cleanTreeGateFromStatus(allocator, a.workspace.root, result.stdout, result.succeeded(), "git status --porcelain");
}

/// Serializes workspace evidence fields into an allocator-owned JSON value; allocation failures propagate.
fn workspaceEvidenceValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "root", .{ .string = a.workspace.root });
    try obj.put(allocator, "cache_root", .{ .string = a.workspace.cache_root });
    try obj.put(allocator, "evidence", try trust_domain.evidenceValue(allocator, "runtime_config", "app TrustContext.workspace", "high"));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes path policy fields into an allocator-owned JSON value; allocation failures propagate.
fn pathPolicyValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "workspace_boundary", .{ .string = "realpath" });
    try obj.put(allocator, "symlink_escapes", .{ .string = "rejected" });
    try obj.put(allocator, "source_write_gate", .{ .string = "mutating source tools require apply=true and preview by default" });
    try obj.put(allocator, "generated_or_vendored_filter", .{ .string = "domain.zig.analysis.skipWorkspacePath" });
    try obj.put(allocator, "evidence", try trust_domain.stringArray(allocator, &.{ "src/infra/workspace", "src/manifest/mod.zig risk metadata" }));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes backend identities fields into an allocator-owned JSON value; allocation failures propagate.
fn backendIdentitiesValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "zig", try backendIdentityValue(allocator, a.config.zig_path, a.context.probe_cache.zig));
    try obj.put(allocator, "zls", try backendIdentityValue(allocator, a.config.zls_path, a.context.probe_cache.zls));
    try obj.put(allocator, "zlint", try backendIdentityValue(allocator, a.config.zlint_path, a.context.probe_cache.zlint));
    try obj.put(allocator, "zwanzig", try backendIdentityValue(allocator, a.config.zwanzig_path, a.context.probe_cache.zwanzig));
    try obj.put(allocator, "zflame", try backendIdentityValue(allocator, a.config.zflame_path, a.context.probe_cache.zflame));
    try obj.put(allocator, "diff_folded", try backendIdentityValue(allocator, a.config.diff_folded_path, a.context.probe_cache.diff_folded));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes backend identity fields into an allocator-owned JSON value; allocation failures propagate.
fn backendIdentityValue(allocator: std.mem.Allocator, configured_path: []const u8, probe: app_context.CachedBackendProbe) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "configured_path", .{ .string = configured_path });
    if (probe.probed) {
        try obj.put(allocator, "probe_status", .{ .string = probe.status });
        try obj.put(allocator, "probe_ok", if (probe.ok) |ok| .{ .bool = ok } else .null);
        try obj.put(allocator, "confidence", .{ .string = if (probe.ok orelse false) "medium" else "low" });
        try obj.put(allocator, "limitation", .{ .string = "probe status reports command availability, not semantic correctness" });
    } else {
        try obj.put(allocator, "probe_status", .{ .string = "not_probed" });
        try obj.put(allocator, "probe_ok", .null);
        try obj.put(allocator, "confidence", .{ .string = "low" });
        try obj.put(allocator, "limitation", .{ .string = "configured path only; run zigar_doctor probe_backends=true for availability evidence" });
    }
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes dependency hashes fields into an allocator-owned JSON value; allocation failures propagate.
fn dependencyHashesValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    const zon = a.workspace.readFileAlloc(a.io, "build.zig.zon", 1024 * 1024) catch |err| {
        var obj = std.json.ObjectMap.empty;
        var obj_owned = true;
        defer if (obj_owned) obj.deinit(allocator);
        try obj.put(allocator, "source_path", .{ .string = "build.zig.zon" });
        try obj.put(allocator, "available", .{ .bool = false });
        try obj.put(allocator, "error", .{ .string = @errorName(err) });
        try obj.put(allocator, "confidence", .{ .string = "low" });
        obj_owned = false;
        return .{ .object = obj };
    };
    defer allocator.free(zon);

    var hashes = std.json.Array.init(allocator);
    var hashes_owned = true;
    defer if (hashes_owned) hashes.deinit();
    var lines = std.mem.splitScalar(u8, zon, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.indexOf(u8, line, ".hash")) |_| {
            if (trust_domain.quotedValue(line)) |hash| {
                var item = std.json.ObjectMap.empty;
                var item_owned = true;
                defer if (item_owned) item.deinit(allocator);
                try item.put(allocator, "hash", .{ .string = try allocator.dupe(u8, hash) });
                try item.put(allocator, "source_path", .{ .string = "build.zig.zon" });
                try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
                try item.put(allocator, "parser_confidence", .{ .string = "medium" });
                try item.put(allocator, "raw_reference", .{ .string = try allocator.dupe(u8, std.mem.trim(u8, line, " \t\r")) });
                try hashes.append(.{ .object = item });
                item_owned = false;
            }
        }
    }

    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "source_path", .{ .string = "build.zig.zon" });
    try obj.put(allocator, "available", .{ .bool = true });
    try obj.put(allocator, "parser", .{ .string = "line_scan_hash_fields" });
    try obj.put(allocator, "parser_confidence", .{ .string = "medium" });
    try obj.put(allocator, "hashes", .{ .array = hashes });
    hashes_owned = false;
    try obj.put(allocator, "limitation", .{ .string = "line scan records hash fields; use Zig package manager and project CI for dependency resolution proof" });
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes provenance entry fields into an allocator-owned JSON value; allocation failures propagate.
fn provenanceEntryValue(allocator: std.mem.Allocator, entry: ports.ToolManifestEntry) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_command_provenance" });
    try obj.put(allocator, "tool", .{ .string = entry.name });
    try obj.put(allocator, "read_only", .{ .bool = entry.read_only });
    try obj.put(allocator, "mcp_read_only_hint", .{ .bool = entry.mcp_read_only_hint });
    try obj.put(allocator, "plan_kind", .{ .string = entry.plan_kind });
    try obj.put(allocator, "plan", try planValue(allocator, entry.plan_kind));
    try obj.put(allocator, "risk", try riskValue(allocator, entry));
    try obj.put(allocator, "source", try trust_domain.evidenceValue(allocator, "compiled_tool_manifest", "src/manifest/definitions.zig", "high"));
    try obj.put(allocator, "limitations", try provenanceLimitationsValue(allocator, entry));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes risk entry fields into an allocator-owned JSON value; allocation failures propagate.
fn riskEntryValue(allocator: std.mem.Allocator, entry: ports.ToolManifestEntry) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "tool", .{ .string = entry.name });
    try obj.put(allocator, "group", .{ .string = entry.group });
    try obj.put(allocator, "risk_level", .{ .string = trust_domain.riskLevel(domainRisk(entry.risk)) });
    try obj.put(allocator, "plan_kind", .{ .string = entry.plan_kind });
    try obj.put(allocator, "risk", try riskValue(allocator, entry));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes plan fields into an allocator-owned JSON value; allocation failures propagate.
fn planValue(allocator: std.mem.Allocator, plan_kind: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = plan_kind });
    if (std.mem.eql(u8, plan_kind, "apply_gated_mutation")) {
        try obj.put(allocator, "requires_apply", .{ .bool = true });
        try obj.put(allocator, "preview_by_default", .{ .bool = true });
    }
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes risk fields into an allocator-owned JSON value; allocation failures propagate.
fn riskValue(allocator: std.mem.Allocator, entry: ports.ToolManifestEntry) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "level", .{ .string = trust_domain.riskLevel(domainRisk(entry.risk)) });
    try obj.put(allocator, "mcp_read_only_hint", .{ .bool = entry.mcp_read_only_hint });
    try obj.put(allocator, "writes_source", .{ .bool = entry.risk.writes_source });
    try obj.put(allocator, "writes_artifacts", .{ .bool = entry.risk.writes_artifacts });
    try obj.put(allocator, "writes_require_apply", .{ .bool = entry.risk.writes_require_apply });
    try obj.put(allocator, "preview_by_default", .{ .bool = entry.risk.preview_by_default });
    try obj.put(allocator, "mutates_lsp_state", .{ .bool = entry.risk.mutates_lsp_state });
    try obj.put(allocator, "executes_project_code", .{ .bool = entry.risk.executes_project_code });
    try obj.put(allocator, "executes_user_command", .{ .bool = entry.risk.executes_user_command });
    try obj.put(allocator, "executes_backend", .{ .bool = entry.risk.executes_backend });
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes provenance limitations fields into an allocator-owned JSON value; allocation failures propagate.
fn provenanceLimitationsValue(allocator: std.mem.Allocator, entry: ports.ToolManifestEntry) !std.json.Value {
    var out = std.json.Array.init(allocator);
    var out_owned = true;
    defer if (out_owned) out.deinit();
    if (std.mem.eql(u8, entry.plan_kind, "exact_command")) {
        try out.append(.{ .string = "Exact argv suffix is manifest-backed; configured executable path and runtime file arguments are resolved by the handler." });
    } else if (std.mem.eql(u8, entry.plan_kind, "dynamic_command")) {
        try out.append(.{ .string = "Exact argv depends on runtime arguments, workspace state, or configured helper paths." });
    } else if (std.mem.eql(u8, entry.plan_kind, "zls_request")) {
        try out.append(.{ .string = "LSP request provenance depends on current ZLS session state and capabilities." });
    } else if (std.mem.eql(u8, entry.plan_kind, "apply_gated_mutation")) {
        try out.append(.{ .string = "Mutation is preview-first and must be rechecked at apply time." });
    } else {
        try out.append(.{ .string = "No external command provenance is claimed for this tool class." });
    }
    if (entry.risk.executes_user_command) try out.append(.{ .string = "User-supplied command text can change runtime impact." });
    if (entry.risk.executes_project_code) try out.append(.{ .string = "Project build scripts or tests can execute project code." });
    out_owned = false;
    return .{ .array = out };
}

/// Serializes clean tree backend error fields into an allocator-owned JSON value; allocation failures propagate.
fn cleanTreeBackendErrorValue(allocator: std.mem.Allocator, workspace_root: []const u8, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_clean_tree_gate" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "clean", .{ .bool = false });
    try obj.put(allocator, "workspace", .{ .string = workspace_root });
    try obj.put(allocator, "error_kind", .{ .string = support.command.errorKind(err) });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "evidence", try trust_domain.evidenceValue(allocator, "git status --porcelain", "command error", "low"));
    try obj.put(allocator, "resolution", .{ .string = "confirm git is available and the workspace is a git repository, or use project CI as the clean-tree verification path" });
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes clean tree not run fields into an allocator-owned JSON value; allocation failures propagate.
fn cleanTreeNotRunValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_clean_tree_gate" });
    try obj.put(allocator, "ok", .null);
    try obj.put(allocator, "clean", .null);
    try obj.put(allocator, "status", .{ .string = "not_run" });
    try obj.put(allocator, "resolution", .{ .string = "call zigar_clean_tree_gate or set include_clean_tree=true for git status evidence" });
    obj_owned = false;
    return .{ .object = obj };
}

/// Implements increment count workflow logic using caller-owned inputs.
fn incrementCount(counts: *std.json.ObjectMap, level: []const u8) void {
    if (counts.getPtr(level)) |value| value.integer += 1;
}

/// Implements domain risk workflow logic using caller-owned inputs.
fn domainRisk(risk: ports.ToolRisk) trust_domain.ToolRisk {
    return .{
        .writes_source = risk.writes_source,
        .writes_artifacts = risk.writes_artifacts,
        .writes_require_apply = risk.writes_require_apply,
        .preview_by_default = risk.preview_by_default,
        .mutates_lsp_state = risk.mutates_lsp_state,
        .executes_project_code = risk.executes_project_code,
        .executes_user_command = risk.executes_user_command,
        .executes_backend = risk.executes_backend,
    };
}

/// Carries test manifest data across use case and port boundaries.
const TestManifest = struct {
    entries: []const ports.ToolManifestEntry,

    /// Returns the fixture port table used by this test context.
    fn port(self: *TestManifest) ports.ToolManifestCatalog {
        return .{
            .ptr = self,
            .vtable = &.{ .count = count, .entry_at = entryAt, .find = find },
        };
    }

    /// Returns the number of entries exposed by this fixture.
    fn count(ptr: *anyopaque) usize {
        const self: *TestManifest = @ptrCast(@alignCast(ptr));
        return self.entries.len;
    }

    /// Returns the fixture entry at the requested index, or null when out of range.
    fn entryAt(ptr: *anyopaque, index: usize) ?ports.ToolManifestEntry {
        const self: *TestManifest = @ptrCast(@alignCast(ptr));
        if (index >= self.entries.len) return null;
        return self.entries[index];
    }

    /// Finds find data in the provided collection without taking ownership.
    fn find(ptr: *anyopaque, name: []const u8) ?ports.ToolManifestEntry {
        const self: *TestManifest = @ptrCast(@alignCast(ptr));
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

/// Carries test ports data across use case and port boundaries.
const TestPorts = struct {
    /// Implements command runner workflow logic using caller-owned inputs.
    fn commandRunner(self: *TestPorts) ports.CommandRunner {
        return .{ .ptr = self, .vtable = &.{ .run = runCommand } };
    }

    /// Implements workspace store workflow logic using caller-owned inputs.
    fn workspaceStore(self: *TestPorts) ports.WorkspaceStore {
        return .{ .ptr = self, .vtable = &.{ .read = readWorkspace, .write = writeWorkspace } };
    }

    /// Invokes run command with caller-owned inputs; command and allocation failures propagate.
    fn runCommand(_: *anyopaque, _: std.mem.Allocator, _: ports.CommandRequest) ports.PortError!ports.CommandResult {
        return error.UnexpectedCall;
    }

    /// Reads workspace data from the provided context without taking ownership of inputs.
    fn readWorkspace(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
        return error.UnexpectedCall;
    }

    /// Writes workspace fields to the provided JSON stream and propagates writer failures.
    fn writeWorkspace(_: *anyopaque, _: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
        return error.UnexpectedCall;
    }
};

/// Builds a test app fixture with the ports needed by this workflow.
fn testApp(allocator: std.mem.Allocator, manifest: ports.ToolManifestCatalog, test_ports: *TestPorts) App {
    return App.init(.{
        .workspace = .{ .root = "/tmp/work", .cache_root = "/tmp/work/.zigar-cache", .transport = "stdio" },
        .tool_paths = .{},
        .timeouts = .{},
        .command_runner = test_ports.commandRunner(),
        .workspace_store = test_ports.workspaceStore(),
        .tool_manifest = manifest,
    }, allocator);
}

/// Builds a test app fixture with the ports needed by this workflow.
fn testAppWithPorts(allocator: std.mem.Allocator, manifest: ports.ToolManifestCatalog, command_runner: ports.CommandRunner, workspace_store: ports.WorkspaceStore, probe_cache: app_context.TrustProbeCache) App {
    return App.init(.{
        .workspace = .{ .root = "/tmp/work", .cache_root = "/tmp/work/.zigar-cache", .transport = "stdio" },
        .tool_paths = .{
            .zig = "/bin/zig",
            .zls = "/bin/zls",
            .zlint = "/bin/zlint",
            .zwanzig = "/bin/zwanzig",
            .zflame = "/bin/zflame",
            .diff_folded = "/bin/diff-folded",
        },
        .timeouts = .{ .command_ms = 30_000, .zls_ms = 30_000 },
        .command_runner = command_runner,
        .workspace_store = workspace_store,
        .tool_manifest = manifest,
        .probe_cache = probe_cache,
    }, allocator);
}

const fakes = @import("../../../testing/fakes/root.zig");

test "trust report wrapper covers dependency hashes backend identities and clean tree modes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = &.{
        ports.ToolManifestEntry{ .name = "zig_info", .group = "core" },
        ports.ToolManifestEntry{ .name = "zig_mutate", .group = "editing", .plan_kind = "apply_gated_mutation", .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true, .executes_user_command = true } },
    };
    var manifest = TestManifest{ .entries = entries };
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();

    const zon =
        \\.{
        \\  .dependencies = .{
        \\    .dep = .{ .hash = "1220abcdef" },
        \\    .bad = .{ .hash = bare_identifier },
        \\  },
        \\}
    ;
    try workspace.expectRead(.{ .path = "build.zig.zon", .max_bytes = 1024 * 1024, .provenance = "arch110-workflow-read" }, zon);
    try workspace.expectRead(.{ .path = "build.zig.zon", .max_bytes = 1024 * 1024, .provenance = "arch110-workflow-read" }, zon);
    try commands.expectRun(.{
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = "/tmp/work",
        .timeout_ms = 4000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{ .exit_code = 0, .stdout = "", .stderr = "", .duration_ms = 8, .provenance = "fake" });

    var app = testAppWithPorts(allocator, manifest.port(), commands.port(), workspace.port(), .{
        .zig = .{ .probed = true, .ok = true, .status = "ok" },
        .zls = .{ .probed = true, .ok = false, .status = "missing" },
        .zlint = .{ .probed = true, .ok = null, .status = "unknown" },
    });

    const preview_args = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    const preview = try zigarTrustReport(&app, allocator, preview_args.value);
    try std.testing.expectEqualStrings("zigar_trust_report", preview.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("not_run", preview.value.object.get("clean_tree_gate").?.object.get("status").?.string);
    try std.testing.expectEqual(@as(usize, 1), preview.value.object.get("dependency_hashes").?.object.get("hashes").?.array.items.len);
    try std.testing.expectEqualStrings("ok", preview.value.object.get("backend_identities").?.object.get("zig").?.object.get("probe_status").?.string);
    try std.testing.expectEqualStrings("low", preview.value.object.get("backend_identities").?.object.get("zlint").?.object.get("confidence").?.string);

    const clean_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"include_clean_tree\":true,\"timeout_ms\":4000}", .{});
    const clean = try zigarTrustReport(&app, allocator, clean_args.value);
    try std.testing.expectEqualStrings("zigar_clean_tree_gate", clean.value.object.get("clean_tree_gate").?.object.get("kind").?.string);
    try std.testing.expect(clean.value.object.get("clean_tree_gate").?.object.get("clean").?.bool);

    try workspace.verify();
    try commands.verify();
}

test "trust public wrappers handle provenance audit and clean tree errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = &.{
        ports.ToolManifestEntry{ .name = "zig_none", .group = "docs" },
        ports.ToolManifestEntry{ .name = "zig_backend", .group = "runtime", .plan_kind = "dynamic_command", .risk = .{ .executes_backend = true, .executes_project_code = true } },
    };
    var manifest = TestManifest{ .entries = entries };
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();

    try commands.expectRunError(.{
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = "/tmp/work",
        .timeout_ms = 5000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, error.AccessDenied);

    var app = testAppWithPorts(allocator, manifest.port(), commands.port(), workspace.port(), .{});

    const all_provenance = try zigarCommandProvenance(&app, allocator, null);
    try std.testing.expectEqualStrings("zigar_command_provenance", all_provenance.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(usize, 2), all_provenance.value.object.get("tools").?.array.items.len);

    const selected_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"tool\":\"zig_backend\"}", .{});
    const selected = try zigarCommandProvenance(&app, allocator, selected_args.value);
    try std.testing.expectEqualStrings("zig_backend", selected.value.object.get("tool").?.string);

    const unknown_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"tool\":\"missing\"}", .{});
    const unknown = try zigarCommandProvenance(&app, allocator, unknown_args.value);
    try std.testing.expect(unknown.is_error);
    try std.testing.expectEqualStrings("argument_error", unknown.value.object.get("kind").?.string);

    const audit_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"include_none\":true}", .{});
    const audit = try zigarRiskAudit(&app, allocator, audit_args.value);
    try std.testing.expectEqual(@as(usize, 2), audit.value.object.get("tools").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), audit.value.object.get("summary").?.object.get("backend_bound_tools").?.integer);

    const clean_error = try zigarCleanTreeGate(&app, allocator, null);
    try std.testing.expectEqualStrings("zigar_clean_tree_gate", clean_error.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("permission", clean_error.value.object.get("error_kind").?.string);

    try commands.verify();
    try workspace.verify();
}

test "trust dependency and provenance helpers cover fallback branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var manifest = TestManifest{ .entries = &.{} };
    var test_ports = TestPorts{};
    var app = testApp(allocator, manifest.port(), &test_ports);

    const deps = try dependencyHashesValue(allocator, &app);
    try std.testing.expect(!deps.object.get("available").?.bool);
    try std.testing.expectEqualStrings("UnexpectedCall", deps.object.get("error").?.string);

    const plans = [_]ports.ToolManifestEntry{
        ports.ToolManifestEntry{ .name = "dynamic", .plan_kind = "dynamic_command", .risk = .{ .executes_user_command = true } },
        ports.ToolManifestEntry{ .name = "zls", .plan_kind = "zls_request", .risk = .{ .mutates_lsp_state = true } },
        ports.ToolManifestEntry{ .name = "apply", .plan_kind = "apply_gated_mutation", .risk = .{ .writes_require_apply = true, .executes_project_code = true } },
        ports.ToolManifestEntry{ .name = "none", .plan_kind = "not_plannable" },
    };
    for (&plans) |entry| {
        const value = try provenanceEntryValue(allocator, entry);
        try std.testing.expectEqualStrings(entry.name, value.object.get("tool").?.string);
        try std.testing.expect(value.object.get("limitations").?.array.items.len >= 1);
    }

    try std.testing.expect(manifest.port().entryAt(99) == null);
    try std.testing.expectError(error.UnexpectedCall, test_ports.commandRunner().run(allocator, .{ .argv = &.{"git"} }));
    try std.testing.expectError(error.UnexpectedCall, test_ports.workspaceStore().read(allocator, .{ .path = "missing" }));
    try std.testing.expectError(error.UnexpectedCall, test_ports.workspaceStore().write(.{ .path = "out", .bytes = "" }));
}

test "command provenance reports exact command risk metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const entries = &.{
        ports.ToolManifestEntry{
            .name = "zig_build",
            .group = "core",
            .plan_kind = "exact_command",
            .plan = .{ .exact_command = .{ .argv = &.{ "zig", "build" } } },
            .risk = .{ .executes_project_code = true, .executes_backend = true },
        },
    };
    var manifest = TestManifest{ .entries = entries };
    var test_ports = TestPorts{};
    var app = testApp(arena.allocator(), manifest.port(), &test_ports);

    const value = try commandProvenanceValue(arena.allocator(), &app, "zig_build");
    const obj = value.object;
    try std.testing.expectEqualStrings("zigar_command_provenance", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("zig_build", obj.get("tool").?.string);
    try std.testing.expectEqualStrings("exact_command", obj.get("plan_kind").?.string);
    try std.testing.expect(obj.get("risk").?.object.get("executes_project_code").?.bool);
}

test "risk audit summarizes apply gates and command-backed risk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const entries = &.{
        ports.ToolManifestEntry{ .name = "zig_format", .risk = .{ .writes_source = true, .writes_artifacts = true, .writes_require_apply = true } },
        ports.ToolManifestEntry{ .name = "zig_test", .risk = .{ .executes_project_code = true, .executes_backend = true } },
    };
    var manifest = TestManifest{ .entries = entries };
    var test_ports = TestPorts{};
    var app = testApp(arena.allocator(), manifest.port(), &test_ports);

    const value = try riskAuditValue(arena.allocator(), &app, false);
    const obj = value.object;
    try std.testing.expectEqualStrings("zigar_risk_audit", obj.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("summary").?.object.get("apply_gated_mutations").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("summary").?.object.get("executes_project_code_tools").?.integer);
    try std.testing.expectEqual(@as(usize, 2), obj.get("tools").?.array.items.len);
}

test "unknown tool provenance is structured as an error for handlers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var manifest = TestManifest{ .entries = &.{} };
    var test_ports = TestPorts{};
    var app = testApp(arena.allocator(), manifest.port(), &test_ports);
    try std.testing.expectError(error.UnknownTool, commandProvenanceValue(arena.allocator(), &app, "missing_tool"));
}

test "command provenance propagates allocation failures" {
    const entries = &.{ports.ToolManifestEntry{ .name = "zig_alloc", .group = "core" }};
    var manifest = TestManifest{ .entries = entries };
    var test_ports = TestPorts{};
    var app = testApp(std.testing.allocator, manifest.port(), &test_ports);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, zigarCommandProvenance(&app, failing.allocator(), null));
}
