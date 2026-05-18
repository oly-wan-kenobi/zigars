const std = @import("std");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const command = zigar.command;
const common = @import("common.zig");
const core = @import("core.zig");
const static_analysis = @import("static_analysis.zig");

const App = common.App;
const appendPathTokens = common.appendPathTokens;
const appendUniqueCommand = common.appendUniqueCommand;
const appendWorkspaceFormatCheckCommand = common.appendWorkspaceFormatCheckCommand;
const buildWorkspaceValue = static_analysis.buildWorkspaceValue;
const buildZigObject = static_analysis.buildZigObject;
const commandErrorValue = common.commandErrorValue;
const commandResultValue = common.commandResultValue;
const commandString = common.commandString;
const compilerErrorIndexValue = core.compilerErrorIndexValue;
const declName = static_analysis.declName;
const dependencyInspectionValue = static_analysis.dependencyInspectionValue;
const freeStringList = common.freeStringList;
const jsonArrayLen = common.jsonArrayLen;
const ownedString = common.ownedString;
const stringListContains = common.stringListContains;
const testFailureTriageValue = static_analysis.testFailureTriageValue;
const testMapValue = static_analysis.testMapValue;
const workspacePathExists = static_analysis.workspacePathExists;

pub fn contextWorkspaceValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "root", .{ .string = a.workspace.root });
    try obj.put(allocator, "cache", .{ .string = a.workspace.cache_root });
    try obj.put(allocator, "strict_workspace", .{ .bool = a.config.strict_workspace });
    try obj.put(allocator, "transport", .{ .string = switch (a.config.transport) {
        .stdio => "stdio",
        .http => "http",
    } });
    try obj.put(allocator, "zig_path", .{ .string = a.config.zig_path });
    try obj.put(allocator, "zls_status", .{ .string = a.zls_status });
    try obj.put(allocator, "zls_running", .{ .bool = if (a.lsp_client) |client| client.isRunning() else false });
    return .{ .object = obj };
}

pub fn projectTypeValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    const graph = buildWorkspaceValue(allocator, a) catch .null;
    const build_obj = buildZigObject(graph);
    const artifact_count = if (build_obj) |o| jsonArrayLen(o.get("artifacts") orelse .null) else 0;
    const module_count = if (build_obj) |o| jsonArrayLen(o.get("modules") orelse .null) else 0;
    const test_count = if (build_obj) |o| jsonArrayLen(o.get("tests") orelse .null) else 0;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = if (artifact_count > 0 and module_count > 0)
        "multi_artifact_package"
    else if (artifact_count > 0)
        "artifact_project"
    else if (module_count > 0)
        "library_or_module_project"
    else if (workspacePathExists(allocator, a, "build.zig"))
        "build_script_project"
    else
        "source_tree" });
    try obj.put(allocator, "artifact_count", .{ .integer = @intCast(artifact_count) });
    try obj.put(allocator, "module_count", .{ .integer = @intCast(module_count) });
    try obj.put(allocator, "build_test_count", .{ .integer = @intCast(test_count) });
    try obj.put(allocator, "confidence", .{ .string = if (workspacePathExists(allocator, a, "build.zig")) "medium" else "low" });
    return .{ .object = obj };
}

pub fn dependencyContextValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    if (a.workspace.readFileAlloc(a.io, "build.zig.zon", 1024 * 1024) catch null) |bytes| {
        defer allocator.free(bytes);
        return dependencyInspectionValue(allocator, a, bytes);
    }
    return .null;
}

pub fn sourceMapValue(allocator: std.mem.Allocator, a: *App, limit: usize) !std.json.Value {
    var files = std.json.Array.init(allocator);
    var dirs = std.json.Array.init(allocator);
    var seen_dirs = std.ArrayList([]const u8).empty;
    defer seen_dirs.deinit(allocator);
    defer freeStringList(allocator, seen_dirs.items);
    var dir = try std.Io.Dir.openDirAbsolute(a.io, a.workspace.root, .{ .iterate = true });
    defer dir.close(a.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var seen: usize = 0;
    while ((walker.next(a.io) catch null)) |entry| {
        if (seen >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or analysis.skipWorkspacePath(entry.path)) continue;
        seen += 1;
        try files.append(try ownedString(allocator, entry.path));
        if (std.fs.path.dirname(entry.path)) |dirname| {
            if (!stringListContains(seen_dirs.items, dirname)) {
                try seen_dirs.append(allocator, try allocator.dupe(u8, dirname));
                try dirs.append(try ownedString(allocator, dirname));
            }
        }
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "analysis_kind", .{ .string = "workspace_file_scan" });
    try obj.put(allocator, "file_count", .{ .integer = @intCast(seen) });
    try obj.put(allocator, "dirs", .{ .array = dirs });
    try obj.put(allocator, "files", .{ .array = files });
    return .{ .object = obj };
}

pub fn qualityCommandsValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var commands = std.json.Array.init(allocator);
    try appendWorkspaceFormatCheckCommand(allocator, a, &commands);
    try appendUniqueCommand(allocator, &commands, "zig build test");
    try appendUniqueCommand(allocator, &commands, "zigar_validate_patch");
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "default_commands", .{ .array = commands });
    try obj.put(allocator, "final_gate", .{ .string = "zigar_validate_patch" });
    return .{ .object = obj };
}

pub fn contextLimitsValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "source_writes", .{ .string = "only tools with apply=true write source" });
    try obj.put(allocator, "analysis", .{ .string = "heuristic unless a ZLS/command-backed field says otherwise" });
    try obj.put(allocator, "stdout", .{ .string = "MCP JSON-RPC only; logs go to stderr" });
    return .{ .object = obj };
}

pub fn agentRulesValue(allocator: std.mem.Allocator, client: []const u8, task: []const u8) !std.json.Value {
    var rules = std.json.Array.init(allocator);
    try rules.append(try ownedString(allocator, "Call zigar_context_pack first when entering an unfamiliar Zig workspace."));
    try rules.append(try ownedString(allocator, "Use zig_format or zig_format_check for formatting; do not fall back to raw zig fmt unless zigar is unavailable."));
    try rules.append(try ownedString(allocator, "Use zig_compile_error_index or zigar_failure_fusion before interpreting compiler stderr manually."));
    try rules.append(try ownedString(allocator, "Use zigar_validate_patch as the final readiness gate before handing work back."));
    try rules.append(try ownedString(allocator, "Source-writing zigar tools are preview-only unless apply=true is explicit."));
    if (std.mem.eql(u8, client, "claude")) try rules.append(try ownedString(allocator, "Prefer compact JSON fields over long command output when summarizing to the user."));
    if (std.mem.eql(u8, client, "codex")) try rules.append(try ownedString(allocator, "Prefer zigar_patch_guard before broad multi-file edits."));
    if (std.mem.indexOf(u8, task, "profile") != null) try rules.append(try ownedString(allocator, "Use zig_profile_plan before capture and zflame-backed tools only for rendering existing profiler data."));
    return .{ .array = rules };
}

pub fn agentWorkflowHintsValue(allocator: std.mem.Allocator, task: []const u8) !std.json.Value {
    var workflows = std.json.Array.init(allocator);
    try workflows.append(try workflowHintValue(allocator, "orientation", &.{ "zigar_context_pack", "zigar_next_action" }));
    try workflows.append(try workflowHintValue(allocator, "compile_error", &.{ "zig_compile_error_index", "zigar_failure_fusion", "zigar_impact" }));
    try workflows.append(try workflowHintValue(allocator, "tests", &.{ "zig_test_failure_triage", "zig_test_select", "zigar_validate_patch" }));
    try workflows.append(try workflowHintValue(allocator, "patch_readiness", &.{ "zigar_patch_guard", "zigar_validate_patch", "zig_public_api_diff" }));
    if (std.mem.indexOf(u8, task, "api") != null) try workflows.append(try workflowHintValue(allocator, "api_change", &.{ "zig_public_api_diff", "zigar_impact", "zig_test_select" }));
    return .{ .array = workflows };
}

pub fn workflowHintValue(allocator: std.mem.Allocator, name: []const u8, tools: []const []const u8) !std.json.Value {
    var tool_values = std.json.Array.init(allocator);
    for (tools) |tool| try tool_values.append(try ownedString(allocator, tool));
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, name));
    try obj.put(allocator, "tools", .{ .array = tool_values });
    return .{ .object = obj };
}

pub fn agentToolAliasesValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "fmt", .{ .string = "zig_format" });
    try obj.put(allocator, "formatter", .{ .string = "zig_format" });
    try obj.put(allocator, "errors", .{ .string = "zig_compile_error_index" });
    try obj.put(allocator, "health", .{ .string = "zigar_doctor" });
    try obj.put(allocator, "done", .{ .string = "zigar_validate_patch" });
    try obj.put(allocator, "impact", .{ .string = "zigar_impact" });
    return .{ .object = obj };
}

pub fn nextActionPlanValue(allocator: std.mem.Allocator, goal: []const u8, changed_files: ?[]const u8, last_error: ?[]const u8) !std.json.Value {
    const lower = try static_analysis.asciiLowerAllocLocal(allocator, goal);
    defer allocator.free(lower);
    var steps = std.json.Array.init(allocator);
    if (std.mem.indexOf(u8, lower, "test") != null) {
        try steps.append(try toolStepValue(allocator, "zig_test_failure_triage", "group failing tests and panic clues"));
        try steps.append(try toolStepValue(allocator, "zig_test_select", "choose focused rerun commands for touched files or symbols"));
        try steps.append(try toolStepValue(allocator, "zigar_validate_patch", "confirm the fix with the standard validation gate"));
    } else if (std.mem.indexOf(u8, lower, "compile") != null or std.mem.indexOf(u8, lower, "build") != null or last_error != null) {
        try steps.append(try toolStepValue(allocator, "zig_compile_error_index", "group compiler diagnostics by file"));
        try steps.append(try toolStepValue(allocator, "zigar_failure_fusion", "extract primary failure, rerun command, and suggested tools"));
        try steps.append(try toolStepValue(allocator, "zigar_impact", "find affected importers/tests before editing"));
    } else if (std.mem.indexOf(u8, lower, "format") != null or std.mem.indexOf(u8, lower, "fmt") != null) {
        try steps.append(try toolStepValue(allocator, "zig_format_check", "check formatting without writing"));
        try steps.append(try toolStepValue(allocator, "zig_format", "preview or apply formatting with apply=true"));
    } else if (std.mem.indexOf(u8, lower, "profile") != null or std.mem.indexOf(u8, lower, "flame") != null) {
        try steps.append(try toolStepValue(allocator, "zig_profile_plan", "choose platform capture workflow"));
        try steps.append(try toolStepValue(allocator, "zig_flamegraph", "render captured profiler output through zflame"));
    } else if (std.mem.indexOf(u8, lower, "pr") != null or std.mem.indexOf(u8, lower, "review") != null or std.mem.indexOf(u8, lower, "done") != null) {
        try steps.append(try toolStepValue(allocator, "zigar_validate_patch", "run the final readiness gate"));
        try steps.append(try toolStepValue(allocator, "zig_public_api_diff", "check accidental public API changes"));
    } else {
        try steps.append(try toolStepValue(allocator, "zigar_context_pack", "orient to project shape and validation policy"));
        try steps.append(try toolStepValue(allocator, "zigar_impact", "map touched files or symbols to likely tests"));
        try steps.append(try toolStepValue(allocator, "zigar_validate_patch", "validate before handoff"));
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_next_action" });
    try obj.put(allocator, "goal", try ownedString(allocator, goal));
    if (changed_files) |files| try obj.put(allocator, "changed_files", try ownedString(allocator, files)) else try obj.put(allocator, "changed_files", .null);
    if (last_error) |err| try obj.put(allocator, "last_error", try ownedString(allocator, err)) else try obj.put(allocator, "last_error", .null);
    try obj.put(allocator, "recommended_steps", .{ .array = steps });
    try obj.put(allocator, "stop_when", .{ .string = "stop when zigar_validate_patch passes or the next tool returns a focused source edit blocker" });
    return .{ .object = obj };
}

pub fn toolStepValue(allocator: std.mem.Allocator, tool: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tool", .{ .string = tool });
    try obj.put(allocator, "reason", .{ .string = reason });
    return .{ .object = obj };
}

pub fn appendValidationPhase(allocator: std.mem.Allocator, a: *App, phases: *std.json.Array, name: []const u8, argv: []const []const u8, timeout_ms: i64) !bool {
    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, argv, timeout_ms) catch |err| {
        var phase = std.json.ObjectMap.empty;
        try phase.put(allocator, "name", .{ .string = name });
        try phase.put(allocator, "ok", .{ .bool = false });
        try phase.put(allocator, "command", try commandErrorValue(allocator, name, argv, a.workspace.root, timeout_ms, err));
        try phases.append(.{ .object = phase });
        return false;
    };
    defer result.deinit(allocator);
    const ok = result.succeeded();
    var phase = std.json.ObjectMap.empty;
    try phase.put(allocator, "name", .{ .string = name });
    try phase.put(allocator, "ok", .{ .bool = ok });
    try phase.put(allocator, "command", try commandResultValue(allocator, name, argv, a.workspace.root, timeout_ms, result));
    try phases.append(.{ .object = phase });
    return ok;
}

pub fn appendWorkspaceFormatCheckPhase(allocator: std.mem.Allocator, a: *App, phases: *std.json.Array, timeout_ms: i64, ok: *bool, stop_on_failure: bool) !void {
    const candidates = [_][]const u8{ "build.zig", "build.zig.zon", "src" };
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, a.config.zig_path);
    try argv_list.append(allocator, "fmt");
    try argv_list.append(allocator, "--check");
    var appended = false;
    for (candidates) |candidate| {
        if (!workspacePathExists(allocator, a, candidate)) continue;
        try argv_list.append(allocator, candidate);
        appended = true;
    }
    if (!appended) return;
    const fmt_ok = try appendValidationPhase(allocator, a, phases, "workspace_format_check", argv_list.items, timeout_ms);
    if (!fmt_ok) {
        ok.* = false;
        if (stop_on_failure) return;
    }
}

pub fn validationNextActionValue(allocator: std.mem.Allocator, ok: bool, phases: std.json.Array) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    if (ok) {
        try obj.put(allocator, "status", .{ .string = "ready" });
        try obj.put(allocator, "tool", .null);
        try obj.put(allocator, "reason", .{ .string = "validation phases passed" });
        return .{ .object = obj };
    }
    for (phases.items) |phase_value| {
        const phase = switch (phase_value) {
            .object => |o| o,
            else => continue,
        };
        const phase_ok = switch (phase.get("ok") orelse .null) {
            .bool => |b| b,
            else => true,
        };
        if (phase_ok) continue;
        try obj.put(allocator, "status", .{ .string = "blocked" });
        try obj.put(allocator, "phase", phase.get("name") orelse .null);
        try obj.put(allocator, "tool", .{ .string = "zigar_failure_fusion" });
        try obj.put(allocator, "reason", .{ .string = "inspect the first failing validation phase and primary diagnostic" });
        return .{ .object = obj };
    }
    try obj.put(allocator, "status", .{ .string = "blocked" });
    try obj.put(allocator, "tool", .{ .string = "zigar_validate_patch" });
    try obj.put(allocator, "reason", .{ .string = "validation failed without a command phase" });
    return .{ .object = obj };
}

pub fn failureFusionValue(allocator: std.mem.Allocator, stderr: []const u8, stdout: []const u8, argv: []const []const u8, ok: bool) !std.json.Value {
    const compiler = try compilerErrorIndexValue(allocator, stderr, stdout, argv);
    const tests = try testFailureTriageValue(allocator, stderr, stdout, argv, ok);
    var suggested = std.json.Array.init(allocator);
    try suggested.append(try ownedString(allocator, "zigar_impact"));
    try suggested.append(try ownedString(allocator, "zig_test_select"));
    try suggested.append(try ownedString(allocator, "zigar_validate_patch"));

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_failure_fusion" });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "compiler", compiler);
    try obj.put(allocator, "tests", tests);
    try obj.put(allocator, "primary_failure", try primaryFailureValue(allocator, compiler, tests));
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "rerun_command", .{ .string = try commandString(allocator, argv) });
    return .{ .object = obj };
}

pub fn primaryFailureValue(allocator: std.mem.Allocator, compiler: std.json.Value, tests: std.json.Value) !std.json.Value {
    const compiler_obj = switch (compiler) {
        .object => |o| o,
        else => return .null,
    };
    const summary = compiler_obj.get("summary") orelse .null;
    if (summary == .object) {
        const primary = summary.object.get("primary") orelse .null;
        if (primary != .null) return primary;
    }
    const tests_obj = switch (tests) {
        .object => |o| o,
        else => return .null,
    };
    const failures = tests_obj.get("failures") orelse .null;
    if (failures == .array and failures.array.items.len > 0) return failures.array.items[0];
    _ = allocator;
    return .null;
}

pub fn impactValue(allocator: std.mem.Allocator, a: *App, files_text: ?[]const u8, symbols_text: ?[]const u8, limit: usize) !std.json.Value {
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(allocator);
    defer freeStringList(allocator, files.items);
    try appendPathTokens(allocator, &files, files_text);
    var symbols = std.ArrayList([]const u8).empty;
    defer symbols.deinit(allocator);
    defer freeStringList(allocator, symbols.items);
    try appendPathTokens(allocator, &symbols, symbols_text);

    var importers = std.json.Array.init(allocator);
    var symbol_hits = std.json.Array.init(allocator);
    var public_api = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    var likely_tests = std.json.Array.init(allocator);

    var dir = try std.Io.Dir.openDirAbsolute(a.io, a.workspace.root, .{ .iterate = true });
    defer dir.close(a.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var seen: usize = 0;
    while ((walker.next(a.io) catch null)) |entry| {
        if (seen >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or analysis.skipWorkspacePath(entry.path)) continue;
        const contents = a.workspace.readFileAlloc(a.io, entry.path, 512 * 1024) catch continue;
        defer allocator.free(contents);
        seen += 1;
        for (files.items) |target| {
            if (importsTarget(contents, target)) {
                try importers.append(try impactHitValue(allocator, entry.path, target, "imports_target"));
            }
            if (std.mem.eql(u8, entry.path, target)) {
                try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig ast-check {s}", .{target}));
                try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{target}));
                try appendPublicDeclsForFile(allocator, &public_api, target, contents);
            }
            if (looksLikeTestFile(entry.path) and referencesFileStem(contents, target)) {
                try likely_tests.append(try impactHitValue(allocator, entry.path, target, "test_references_file"));
            }
        }
        for (symbols.items) |symbol| {
            if (std.mem.indexOf(u8, contents, symbol) != null) {
                try symbol_hits.append(try impactHitValue(allocator, entry.path, symbol, "symbol_reference"));
                if (looksLikeTestFile(entry.path)) try likely_tests.append(try impactHitValue(allocator, entry.path, symbol, "test_references_symbol"));
            }
        }
    }
    try appendUniqueCommand(allocator, &commands, "zig build test");

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_impact" });
    try obj.put(allocator, "analysis_kind", .{ .string = "heuristic_import_symbol_test_scan" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "direct_importers", .{ .array = importers });
    try obj.put(allocator, "symbol_hits", .{ .array = symbol_hits });
    try obj.put(allocator, "likely_tests", .{ .array = likely_tests });
    try obj.put(allocator, "public_api", .{ .array = public_api });
    try obj.put(allocator, "recommended_commands", .{ .array = commands });
    return .{ .object = obj };
}

pub fn impactHitValue(allocator: std.mem.Allocator, file: []const u8, target: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "target", try ownedString(allocator, target));
    try obj.put(allocator, "reason", .{ .string = reason });
    return .{ .object = obj };
}

pub fn importsTarget(contents: []const u8, target: []const u8) bool {
    const base = std.fs.path.basename(target);
    return std.mem.indexOf(u8, contents, base) != null or std.mem.indexOf(u8, contents, target) != null;
}

pub fn referencesFileStem(contents: []const u8, target: []const u8) bool {
    const base = std.fs.path.basename(target);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    if (dot == 0) return false;
    return std.mem.indexOf(u8, contents, base[0..dot]) != null;
}

pub fn looksLikeTestFile(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "test") != null or std.mem.endsWith(u8, path, "_test.zig");
}

pub fn appendPublicDeclsForFile(allocator: std.mem.Allocator, out: *std.json.Array, file: []const u8, contents: []const u8) !void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "pub ")) continue;
        if (analysis.declKind(trimmed)) |kind| {
            var obj = std.json.ObjectMap.empty;
            try obj.put(allocator, "file", try ownedString(allocator, file));
            try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
            try obj.put(allocator, "kind", .{ .string = kind });
            try obj.put(allocator, "name", if (declName(trimmed, kind)) |name| try ownedString(allocator, name) else .null);
            try obj.put(allocator, "signature", try ownedString(allocator, trimmed));
            try out.append(.{ .object = obj });
        }
    }
}

pub fn generatedProjectProfileValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = 1 });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "project_type", try projectTypeValue(allocator, a));
    try obj.put(allocator, "quality", try qualityCommandsValue(allocator, a));
    try obj.put(allocator, "generated_dirs", try generatedDirsValue(allocator));
    try obj.put(allocator, "agent_entrypoint", .{ .string = "zigar_context_pack" });
    return .{ .object = obj };
}

pub fn generatedDirsValue(allocator: std.mem.Allocator) !std.json.Value {
    var dirs = std.json.Array.init(allocator);
    for ([_][]const u8{ ".zig-cache", ".zigar-cache", "zig-out", "zig-pkg", "coverage" }) |dir| {
        try dirs.append(try ownedString(allocator, dir));
    }
    return .{ .array = dirs };
}
