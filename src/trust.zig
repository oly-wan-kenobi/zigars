const std = @import("std");

const analysis = @import("analysis.zig");
const command = @import("command.zig");
const runtime = @import("runtime.zig");
const tool_manifest = @import("tool_manifest.zig");

pub const CleanTreeOptions = struct {
    timeout_ms: i64,
};

pub fn trustReport(allocator: std.mem.Allocator, app: *runtime.App, include_clean_tree: bool, timeout_ms: i64) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_trust_report" });
    try obj.put(allocator, "workspace", try workspaceEvidenceValue(allocator, app));
    try obj.put(allocator, "path_policy", try pathPolicyValue(allocator));
    try obj.put(allocator, "backend_identities", try backendIdentitiesValue(allocator, app));
    try obj.put(allocator, "dependency_hashes", try dependencyHashesValue(allocator, app));
    try obj.put(allocator, "risk_audit", try riskAudit(allocator, false));
    if (include_clean_tree) {
        try obj.put(allocator, "clean_tree_gate", try cleanTreeGate(allocator, app, .{ .timeout_ms = timeout_ms }));
    } else {
        try obj.put(allocator, "clean_tree_gate", try cleanTreeNotRunValue(allocator));
    }
    try obj.put(allocator, "limitations", try stringArray(allocator, &.{
        "Reports zigar-observed configuration, manifest metadata, and optional git status only.",
        "Backend paths are configured identities unless a separate probe command has populated probe cache evidence.",
        "Release decisions should verify with zigar_validate_patch mode=full, project CI, and any required release-check path.",
    }));
    return .{ .object = obj };
}

pub fn commandProvenance(allocator: std.mem.Allocator, tool_name: ?[]const u8) !std.json.Value {
    if (tool_name) |name| {
        const entry = tool_manifest.findEntry(name) orelse return error.UnknownTool;
        return provenanceEntryValue(allocator, entry);
    }

    var tools = std.json.Array.init(allocator);
    errdefer tools.deinit();
    for (tool_manifest.entries) |entry| {
        try tools.append(try provenanceEntryValue(allocator, entry));
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_command_provenance" });
    try obj.put(allocator, "scope", .{ .string = "all_tools" });
    try obj.put(allocator, "source", try evidenceValue(allocator, "compiled_tool_manifest", "src/tool_manifest.zig", "high"));
    try obj.put(allocator, "tools", .{ .array = tools });
    return .{ .object = obj };
}

pub fn riskAudit(allocator: std.mem.Allocator, include_none: bool) !std.json.Value {
    var counts = std.json.ObjectMap.empty;
    errdefer counts.deinit(allocator);
    try counts.put(allocator, "none", .{ .integer = 0 });
    try counts.put(allocator, "low", .{ .integer = 0 });
    try counts.put(allocator, "medium", .{ .integer = 0 });
    try counts.put(allocator, "high", .{ .integer = 0 });

    var tools = std.json.Array.init(allocator);
    errdefer tools.deinit();
    var apply_gated: usize = 0;
    var backend_bound: usize = 0;
    var project_code: usize = 0;
    var user_command: usize = 0;

    for (tool_manifest.entries) |entry| {
        const risk = entry.risk;
        const level = tool_manifest.riskLevel(risk);
        incrementCount(&counts, level);
        if (risk.writes_require_apply) apply_gated += 1;
        if (risk.executes_backend) backend_bound += 1;
        if (risk.executes_project_code) project_code += 1;
        if (risk.executes_user_command) user_command += 1;
        if (include_none or !std.mem.eql(u8, level, "none")) {
            try tools.append(try riskEntryValue(allocator, entry));
        }
    }

    var summary = std.json.ObjectMap.empty;
    errdefer summary.deinit(allocator);
    try summary.put(allocator, "apply_gated_mutations", .{ .integer = @intCast(apply_gated) });
    try summary.put(allocator, "backend_bound_tools", .{ .integer = @intCast(backend_bound) });
    try summary.put(allocator, "executes_project_code_tools", .{ .integer = @intCast(project_code) });
    try summary.put(allocator, "executes_user_command_tools", .{ .integer = @intCast(user_command) });

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_risk_audit" });
    try obj.put(allocator, "source", try evidenceValue(allocator, "compiled_tool_manifest", "src/tool_manifest.zig", "high"));
    try obj.put(allocator, "counts_by_level", .{ .object = counts });
    try obj.put(allocator, "summary", .{ .object = summary });
    try obj.put(allocator, "tools", .{ .array = tools });
    try obj.put(allocator, "limitations", try stringArray(allocator, &.{
        "Risk metadata describes tool contract classes; dynamic runtime arguments can still affect concrete impact.",
        "Read-only MCP hints are withheld when a tool can execute code, mutate LSP state, or write artifacts.",
    }));
    return .{ .object = obj };
}

pub fn cleanTreeGate(allocator: std.mem.Allocator, app: *runtime.App, options: CleanTreeOptions) !std.json.Value {
    const argv = &.{ "git", "status", "--porcelain" };
    app.command_calls += 1;
    const started_ns = std.Io.Clock.now(.real, app.io).nanoseconds;
    const result = command.run(allocator, app.io, app.workspace.root, argv, @min(options.timeout_ms, 5000)) catch |err| {
        app.observability.recordCommand("git status clean-tree gate", argv, elapsedMs(app.io, started_ns), false, @errorName(err));
        app.tool_errors += 1;
        return cleanTreeBackendErrorValue(allocator, app.workspace.root, err);
    };
    defer result.deinit(allocator);
    app.observability.recordCommand("git status clean-tree gate", argv, result.duration_ms, result.succeeded(), null);
    return cleanTreeGateFromStatus(allocator, app.workspace.root, result.stdout, result.succeeded(), "git status --porcelain");
}

fn elapsedMs(io: std.Io, started_ns: anytype) i64 {
    const duration_ns = std.Io.Clock.now(.real, io).nanoseconds - started_ns;
    if (duration_ns <= 0) return 0;
    return @intCast(@divTrunc(duration_ns, std.time.ns_per_ms));
}

pub fn cleanTreeGateFromStatus(allocator: std.mem.Allocator, workspace_root: []const u8, stdout: []const u8, git_ok: bool, evidence_command: []const u8) !std.json.Value {
    var paths = std.json.Array.init(allocator);
    errdefer paths.deinit();
    var untracked: usize = 0;
    var generated_or_vendored: usize = 0;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const path = statusLinePath(line);
        if (path.len == 0) continue;
        const generated = analysis.skipWorkspacePath(path);
        if (generated) generated_or_vendored += 1;
        if (std.mem.startsWith(u8, line, "??")) untracked += 1;
        var item = std.json.ObjectMap.empty;
        errdefer item.deinit(allocator);
        try item.put(allocator, "path", .{ .string = try allocator.dupe(u8, path) });
        try item.put(allocator, "status", .{ .string = try allocator.dupe(u8, std.mem.trim(u8, line[0..2], " ")) });
        try item.put(allocator, "generated_or_vendored", .{ .bool = generated });
        try paths.append(.{ .object = item });
    }

    const clean = git_ok and paths.items.len == 0;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_clean_tree_gate" });
    try obj.put(allocator, "ok", .{ .bool = clean });
    try obj.put(allocator, "clean", .{ .bool = clean });
    try obj.put(allocator, "workspace", .{ .string = workspace_root });
    try obj.put(allocator, "changed_count", .{ .integer = @intCast(paths.items.len) });
    try obj.put(allocator, "untracked_count", .{ .integer = @intCast(untracked) });
    try obj.put(allocator, "generated_or_vendored_count", .{ .integer = @intCast(generated_or_vendored) });
    try obj.put(allocator, "changed_paths", .{ .array = paths });
    try obj.put(allocator, "evidence", try evidenceValue(allocator, evidence_command, "git status --porcelain stdout", if (git_ok) "high" else "low"));
    try obj.put(allocator, "resolution", .{ .string = if (clean) "workspace tree is clean according to git status" else "review, commit, stash, or intentionally account for changed paths before release decisions" });
    return .{ .object = obj };
}

fn workspaceEvidenceValue(allocator: std.mem.Allocator, app: *runtime.App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "root", .{ .string = app.workspace.root });
    try obj.put(allocator, "cache_root", .{ .string = app.workspace.cache_root });
    try obj.put(allocator, "evidence", try evidenceValue(allocator, "runtime_config", "src/runtime.zig App.workspace", "high"));
    return .{ .object = obj };
}

fn pathPolicyValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "workspace_boundary", .{ .string = "realpath" });
    try obj.put(allocator, "symlink_escapes", .{ .string = "rejected" });
    try obj.put(allocator, "source_write_gate", .{ .string = "mutating source tools require apply=true and preview by default" });
    try obj.put(allocator, "generated_or_vendored_filter", .{ .string = "analysis.skipWorkspacePath" });
    try obj.put(allocator, "evidence", try stringArray(allocator, &.{ "src/workspace.zig", "src/tools/agent.zig zigar_patch_guard", "src/tool_manifest.zig risk metadata" }));
    return .{ .object = obj };
}

fn backendIdentitiesValue(allocator: std.mem.Allocator, app: *runtime.App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig", try backendIdentityValue(allocator, app.config.zig_path, app.backend_probe_cache.zig));
    try obj.put(allocator, "zls", try backendIdentityValue(allocator, app.config.zls_path, app.backend_probe_cache.zls));
    try obj.put(allocator, "zwanzig", try backendIdentityValue(allocator, app.config.zwanzig_path, app.backend_probe_cache.zwanzig));
    try obj.put(allocator, "zflame", try backendIdentityValue(allocator, app.config.zflame_path, app.backend_probe_cache.zflame));
    try obj.put(allocator, "diff_folded", try backendIdentityValue(allocator, app.config.diff_folded_path, app.backend_probe_cache.diff_folded));
    return .{ .object = obj };
}

fn backendIdentityValue(allocator: std.mem.Allocator, configured_path: []const u8, probe: ?@import("doctor.zig").Probe) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "configured_path", .{ .string = configured_path });
    if (probe) |p| {
        try obj.put(allocator, "probe_status", .{ .string = p.status });
        try obj.put(allocator, "probe_ok", .{ .bool = p.ok });
        try obj.put(allocator, "confidence", .{ .string = if (p.ok) "medium" else "low" });
        try obj.put(allocator, "limitation", .{ .string = "probe status reports command availability, not semantic correctness" });
    } else {
        try obj.put(allocator, "probe_status", .{ .string = "not_probed" });
        try obj.put(allocator, "probe_ok", .null);
        try obj.put(allocator, "confidence", .{ .string = "low" });
        try obj.put(allocator, "limitation", .{ .string = "configured path only; run zigar_doctor probe_backends=true for availability evidence" });
    }
    return .{ .object = obj };
}

fn dependencyHashesValue(allocator: std.mem.Allocator, app: *runtime.App) !std.json.Value {
    const zon = readWorkspaceFile(app, allocator, "build.zig.zon", 1024 * 1024) catch |err| {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "source_path", .{ .string = "build.zig.zon" });
        try obj.put(allocator, "available", .{ .bool = false });
        try obj.put(allocator, "error", .{ .string = @errorName(err) });
        try obj.put(allocator, "confidence", .{ .string = "low" });
        return .{ .object = obj };
    };
    defer allocator.free(zon);

    var hashes = std.json.Array.init(allocator);
    errdefer hashes.deinit();
    var lines = std.mem.splitScalar(u8, zon, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.indexOf(u8, line, ".hash")) |_| {
            if (quotedValue(line)) |hash| {
                var item = std.json.ObjectMap.empty;
                errdefer item.deinit(allocator);
                try item.put(allocator, "hash", .{ .string = try allocator.dupe(u8, hash) });
                try item.put(allocator, "source_path", .{ .string = "build.zig.zon" });
                try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
                try item.put(allocator, "parser_confidence", .{ .string = "medium" });
                try item.put(allocator, "raw_reference", .{ .string = try allocator.dupe(u8, std.mem.trim(u8, line, " \t\r")) });
                try hashes.append(.{ .object = item });
            }
        }
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "source_path", .{ .string = "build.zig.zon" });
    try obj.put(allocator, "available", .{ .bool = true });
    try obj.put(allocator, "parser", .{ .string = "line_scan_hash_fields" });
    try obj.put(allocator, "parser_confidence", .{ .string = "medium" });
    try obj.put(allocator, "hashes", .{ .array = hashes });
    try obj.put(allocator, "limitation", .{ .string = "line scan records hash fields; use Zig package manager and project CI for dependency resolution proof" });
    return .{ .object = obj };
}

fn readWorkspaceFile(app: *runtime.App, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const resolved = try app.workspace.resolve(path);
    defer app.workspace.allocator.free(resolved);
    return std.Io.Dir.cwd().readFileAlloc(app.io, resolved, allocator, .limited(max_bytes));
}

fn provenanceEntryValue(allocator: std.mem.Allocator, entry: tool_manifest.ToolEntry) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_command_provenance" });
    try obj.put(allocator, "tool", .{ .string = entry.name });
    try obj.put(allocator, "read_only", .{ .bool = entry.meta.read_only });
    try obj.put(allocator, "mcp_read_only_hint", .{ .bool = tool_manifest.readOnlyHintFor(entry.meta) });
    try obj.put(allocator, "plan_kind", .{ .string = tool_manifest.planKind(entry.plan) });
    try obj.put(allocator, "plan", try planValue(allocator, entry.plan));
    try obj.put(allocator, "risk", try tool_manifest.riskValue(allocator, entry.meta));
    try obj.put(allocator, "source", try evidenceValue(allocator, "compiled_tool_manifest", "src/tool_manifest/definitions.zig", "high"));
    try obj.put(allocator, "limitations", try provenanceLimitationsValue(allocator, entry));
    return .{ .object = obj };
}

fn riskEntryValue(allocator: std.mem.Allocator, entry: tool_manifest.ToolEntry) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "tool", .{ .string = entry.name });
    try obj.put(allocator, "group", .{ .string = tool_manifest.groupName(entry.group) });
    try obj.put(allocator, "risk_level", .{ .string = tool_manifest.riskLevel(entry.risk) });
    try obj.put(allocator, "plan_kind", .{ .string = tool_manifest.planKind(entry.plan) });
    try obj.put(allocator, "risk", try tool_manifest.riskValue(allocator, entry.meta));
    return .{ .object = obj };
}

fn planValue(allocator: std.mem.Allocator, plan: tool_manifest.PlanPolicy) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    switch (plan) {
        .exact_command => |command_plan| {
            try obj.put(allocator, "kind", .{ .string = "exact_command" });
            try obj.put(allocator, "command", try commandPlanValue(allocator, command_plan));
        },
        .dynamic_command => |reason| {
            try obj.put(allocator, "kind", .{ .string = "dynamic_command" });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .zls_request => |zls| {
            try obj.put(allocator, "kind", .{ .string = "zls_request" });
            try obj.put(allocator, "method", .{ .string = zls.method });
            try obj.put(allocator, "requires_document_sync", .{ .bool = zls.requires_document_sync });
            try obj.put(allocator, "mutates_document_state", .{ .bool = zls.mutates_document_state });
            if (zls.required_capability) |capability| try obj.put(allocator, "required_capability", .{ .string = capability }) else try obj.put(allocator, "required_capability", .null);
        },
        .apply_gated_mutation => |reason| {
            try obj.put(allocator, "kind", .{ .string = "apply_gated_mutation" });
            try obj.put(allocator, "requires_apply", .{ .bool = true });
            try obj.put(allocator, "preview_by_default", .{ .bool = true });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .workspace_artifact => |reason| {
            try obj.put(allocator, "kind", .{ .string = "workspace_artifact" });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .pure_analysis => |reason| {
            try obj.put(allocator, "kind", .{ .string = "pure_analysis" });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .not_plannable => |reason| {
            try obj.put(allocator, "kind", .{ .string = "not_plannable" });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
    }
    return .{ .object = obj };
}

fn commandPlanValue(allocator: std.mem.Allocator, plan: tool_manifest.CommandPlan) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    switch (plan) {
        .argv => |argv| {
            try obj.put(allocator, "mode", .{ .string = "fixed_argv" });
            try obj.put(allocator, "argv_suffix", try stringArray(allocator, argv));
        },
        .optional_file => |file_plan| {
            try obj.put(allocator, "mode", .{ .string = "optional_file" });
            try obj.put(allocator, "file_args", try stringArray(allocator, file_plan.file_args));
            try obj.put(allocator, "fallback_args", try stringArray(allocator, file_plan.fallback_args));
        },
        .required_file => |argv| {
            try obj.put(allocator, "mode", .{ .string = "required_file" });
            try obj.put(allocator, "argv_prefix", try stringArray(allocator, argv));
        },
        .required_path => |argv| {
            try obj.put(allocator, "mode", .{ .string = "required_path" });
            try obj.put(allocator, "argv_prefix", try stringArray(allocator, argv));
        },
    }
    try obj.put(allocator, "argv_executable", .{ .string = "configured zig path unless the handler documents another backend" });
    return .{ .object = obj };
}

fn provenanceLimitationsValue(allocator: std.mem.Allocator, entry: tool_manifest.ToolEntry) !std.json.Value {
    var out = std.json.Array.init(allocator);
    errdefer out.deinit();
    switch (entry.plan) {
        .exact_command => try out.append(.{ .string = "Exact argv suffix is manifest-backed; configured executable path and runtime file arguments are resolved by the handler." }),
        .dynamic_command => try out.append(.{ .string = "Exact argv depends on runtime arguments, workspace state, or configured helper paths." }),
        .zls_request => try out.append(.{ .string = "LSP request provenance depends on current ZLS session state and capabilities." }),
        .apply_gated_mutation => try out.append(.{ .string = "Mutation is preview-first and must be rechecked at apply time." }),
        else => try out.append(.{ .string = "No external command provenance is claimed for this tool class." }),
    }
    if (entry.risk.executes_user_command) try out.append(.{ .string = "User-supplied command text can change runtime impact." });
    if (entry.risk.executes_project_code) try out.append(.{ .string = "Project build scripts or tests can execute project code." });
    return .{ .array = out };
}

fn cleanTreeBackendErrorValue(allocator: std.mem.Allocator, workspace_root: []const u8, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_clean_tree_gate" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "clean", .{ .bool = false });
    try obj.put(allocator, "workspace", .{ .string = workspace_root });
    try obj.put(allocator, "error_kind", .{ .string = command.errorKind(err) });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "evidence", try evidenceValue(allocator, "git status --porcelain", "command error", "low"));
    try obj.put(allocator, "resolution", .{ .string = "confirm git is available and the workspace is a git repository, or use project CI as the clean-tree verification path" });
    return .{ .object = obj };
}

fn cleanTreeNotRunValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_clean_tree_gate" });
    try obj.put(allocator, "ok", .null);
    try obj.put(allocator, "clean", .null);
    try obj.put(allocator, "status", .{ .string = "not_run" });
    try obj.put(allocator, "resolution", .{ .string = "call zigar_clean_tree_gate or set include_clean_tree=true for git status evidence" });
    return .{ .object = obj };
}

fn evidenceValue(allocator: std.mem.Allocator, source: []const u8, reference: []const u8, confidence: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "source", .{ .string = source });
    try obj.put(allocator, "reference", .{ .string = reference });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    return .{ .object = obj };
}

fn stringArray(allocator: std.mem.Allocator, items: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (items) |item| try array.append(.{ .string = try allocator.dupe(u8, item) });
    return .{ .array = array };
}

fn incrementCount(counts: *std.json.ObjectMap, level: []const u8) void {
    if (counts.getPtr(level)) |value| {
        value.integer += 1;
    }
}

fn statusLinePath(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, if (line.len > 3) line[3..] else "", " \t");
    if (std.mem.indexOf(u8, trimmed, " -> ")) |arrow| return trimmed[arrow + " -> ".len ..];
    return trimmed;
}

fn quotedValue(line: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const rest = line[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..second];
}

test "command provenance reports exact command risk metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try commandProvenance(arena.allocator(), "zig_build");
    const obj = value.object;
    try std.testing.expectEqualStrings("zigar_command_provenance", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("zig_build", obj.get("tool").?.string);
    try std.testing.expectEqualStrings("exact_command", obj.get("plan_kind").?.string);
    try std.testing.expect(obj.get("risk").?.object.get("executes_project_code").?.bool);
}

test "risk audit summarizes apply gates and command-backed risk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try riskAudit(arena.allocator(), false);
    const obj = value.object;
    try std.testing.expectEqualStrings("zigar_risk_audit", obj.get("kind").?.string);
    try std.testing.expect(obj.get("summary").?.object.get("apply_gated_mutations").?.integer > 0);
    try std.testing.expect(obj.get("summary").?.object.get("executes_project_code_tools").?.integer > 0);
    try std.testing.expect(obj.get("tools").?.array.items.len > 0);
}

test "clean tree gate parses porcelain status with generated path evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try cleanTreeGateFromStatus(arena.allocator(), "/tmp/work", " M src/main.zig\n?? zig-out/bin/app\n", true, "fixture");
    const obj = value.object;
    try std.testing.expectEqualStrings("zigar_clean_tree_gate", obj.get("kind").?.string);
    try std.testing.expect(!obj.get("clean").?.bool);
    try std.testing.expectEqual(@as(i64, 2), obj.get("changed_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("untracked_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("generated_or_vendored_count").?.integer);
}

test "unknown tool provenance is structured as an error for handlers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownTool, commandProvenance(arena.allocator(), "missing_tool"));
}
