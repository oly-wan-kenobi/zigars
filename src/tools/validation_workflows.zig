const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const analysis_contract = zigar.analysis_contract;
const artifacts = zigar.artifacts;
const command = zigar.command;
const evidence = zigar.evidence;
const json_result = zigar.json_result;
const tool_manifest = zigar.tool_manifest;
const common = @import("common.zig");
const agent_values = @import("agent_values.zig");
const static_analysis = @import("static_analysis.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const argBool = common.argBool;
const argInt = common.argInt;
const missingArgumentResult = common.missingArgumentResult;
const invalidArgumentResult = common.invalidArgumentResult;
const workspacePathErrorResult = common.workspacePathErrorResult;
const toolErrorFromError = common.toolErrorFromError;
const splitToolArgs = common.splitToolArgs;
const splitToolArgsErrorResult = common.splitToolArgsErrorResult;
const freeArgList = common.freeArgList;
const toolTimeout = common.toolTimeout;
const ownedString = common.ownedString;
const appendPathTokens = common.appendPathTokens;
const appendPatchPaths = common.appendPatchPaths;
const appendUniqueCommand = common.appendUniqueCommand;
const appendUniqueString = common.appendUniqueString;
const stringListContains = common.stringListContains;
const freeStringList = common.freeStringList;
const commandResultValue = common.commandResultValue;
const commandErrorValue = common.commandErrorValue;
const commandString = common.commandString;
const compilerInsightsValue = common.compilerInsightsValue;
const scratchApp = common.scratchApp;

const semantic_limit_default = 500;
const history_path_default = ".zigar-cache/validation/history.jsonl";
const memory_path_default = ".zigar/project-memory.jsonl";
const schema_version = 1;

const ValidationPhase = struct {
    id: []const u8,
    kind: []const u8,
    tool: ?[]const u8 = null,
    command: ?[]const []const u8 = null,
    reason: []const u8,
    required: bool,
    risk: []const u8,
};

const ParsedHistory = struct {
    runs: std.json.Array,
    unavailable: bool = false,
};

pub fn zigImpactSemantic(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return semanticImpactTool(a, allocator, args, "zig_impact_semantic");
}

pub fn zigTestSelectSemantic(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var scratch_app = scratchApp(a, arena.allocator());
    const impact = semanticImpactValue(arena.allocator(), &scratch_app, args, "zig_test_select_semantic") catch |err| return semanticWorkflowError(allocator, "zig_test_select_semantic", "select_tests", err);
    const impact_obj = switch (impact) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };

    var commands = std.json.Array.init(arena.allocator());
    var reasons = std.json.Array.init(arena.allocator());
    try appendCommandsForImpact(arena.allocator(), &commands, &reasons, impact_obj.get("directly_touched_files") orelse .null, "changed Zig file");
    try appendCommandsForImpact(arena.allocator(), &commands, &reasons, impact_obj.get("affected_tests") orelse .null, "semantic test match");
    try appendUniqueCommand(arena.allocator(), &commands, "zig build test");

    var skipped = std.json.Array.init(arena.allocator());
    try skipped.append(try skippedStepValue(arena.allocator(), "coverage", "No coverage backend is run by this selector; use project CI or coverage tooling for release proof."));
    try skipped.append(try skippedStepValue(arena.allocator(), "performance", "No benchmark/profile evidence is collected by this selector."));

    var obj = std.json.ObjectMap.empty;
    try obj.put(arena.allocator(), "kind", .{ .string = "zig_test_select_semantic" });
    try analysis_contract.putMetadata(arena.allocator(), &obj, "zig_test_select_semantic");
    try obj.put(arena.allocator(), "schema_version", .{ .integer = schema_version });
    try obj.put(arena.allocator(), "impact", impact);
    try obj.put(arena.allocator(), "commands", .{ .array = commands });
    try obj.put(arena.allocator(), "reasons", .{ .array = reasons });
    try obj.put(arena.allocator(), "selection_basis", .{ .string = "parser-backed semantic impact plus conservative fallback" });
    try obj.put(arena.allocator(), "fallback", .{ .string = "zig build test" });
    try obj.put(arena.allocator(), "selection_complete", .{ .bool = false });
    try obj.put(arena.allocator(), "skipped_validation", .{ .array = skipped });
    try obj.put(arena.allocator(), "stop_condition", .{ .string = "Stop only after the focused commands pass and a release-appropriate full gate such as zig build test or project CI passes." });
    return structured(allocator, .{ .object = obj });
}

fn semanticImpactTool(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var scratch_app = scratchApp(a, arena.allocator());
    const value = semanticImpactValue(arena.allocator(), &scratch_app, args, tool_name) catch |err| return semanticWorkflowError(allocator, tool_name, "impact", err);
    return structured(allocator, value);
}

fn semanticImpactValue(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value, tool_name: []const u8) !std.json.Value {
    const limit: usize = @intCast(@max(1, argInt(args, "limit", semantic_limit_default)));
    const index = try static_analysis.semanticIndexValue(allocator, a, limit, "zig_semantic_index_build");
    const root = switch (index) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };

    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(allocator);
    defer freeStringList(allocator, files.items);
    try appendPathTokens(allocator, &files, argString(args, "files"));
    try appendPatchPaths(allocator, &files, argString(args, "diff"));

    var symbols = std.ArrayList([]const u8).empty;
    defer symbols.deinit(allocator);
    defer freeStringList(allocator, symbols.items);
    try appendPathTokens(allocator, &symbols, argString(args, "symbols"));

    var touched = std.json.Array.init(allocator);
    var importers = std.json.Array.init(allocator);
    var declarations = std.json.Array.init(allocator);
    var tests = std.json.Array.init(allocator);
    var public_api = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    var inferred = std.json.Array.init(allocator);
    var unknowns = std.json.Array.init(allocator);

    for (files.items) |file| {
        if (file.len == 0 or std.mem.eql(u8, file, "/dev/null")) continue;
        try appendUniqueFileObject(allocator, &touched, file, "input_changed_file", .high);
        if (std.mem.endsWith(u8, file, ".zig")) {
            try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig ast-check {s}", .{file}));
            try appendUniqueCommand(allocator, &commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{file}));
        }
        try collectImportersForFile(allocator, root.get("imports") orelse .null, &importers, file);
        try collectTestsForFile(allocator, root.get("tests") orelse .null, &tests, file);
        try collectPublicApiForFile(allocator, root.get("declarations") orelse .null, &public_api, file);
    }

    for (symbols.items) |symbol| {
        if (symbol.len == 0) continue;
        try collectDeclarationsForSymbol(allocator, root.get("declarations") orelse .null, &declarations, symbol);
        try collectTestsForSymbol(allocator, root.get("tests") orelse .null, &tests, symbol);
    }

    try appendCommandsFromMatches(allocator, &commands, tests);
    try appendUniqueCommand(allocator, &commands, "zig build test");
    if (files.items.len == 0 and symbols.items.len == 0) {
        try unknowns.append(try ownedString(allocator, "No files, symbols, or diff paths were supplied; result falls back to workspace-level validation."));
    }
    try inferred.append(try ownedString(allocator, "Importers are inferred from parser-backed @import declarations when available and basename matching otherwise."));
    try inferred.append(try ownedString(allocator, "Affected tests are selected from parser-backed test declarations and file/symbol name matches."));

    var inspected = std.json.ObjectMap.empty;
    try inspected.put(allocator, "semantic_index_format", root.get("format") orelse .{ .string = "zigar.semantic_index" });
    try inspected.put(allocator, "file_count", root.get("file_count") orelse .{ .integer = 0 });
    try inspected.put(allocator, "declaration_count", root.get("declaration_count") orelse .{ .integer = 0 });
    try inspected.put(allocator, "import_count", root.get("import_count") orelse .{ .integer = 0 });
    try inspected.put(allocator, "test_count", root.get("test_count") orelse .{ .integer = 0 });
    try inspected.put(allocator, "partial_result", root.get("partial_result") orelse .{ .bool = true });
    try inspected.put(allocator, "parse_status", root.get("parse_status") orelse .{ .string = "unknown" });

    var skipped = std.json.Array.init(allocator);
    try skipped.append(try skippedStepValue(allocator, "runtime_execution", "Semantic impact reads source evidence only; it does not run tests or builds."));
    try skipped.append(try skippedStepValue(allocator, "coverage", "No coverage data is inspected, so unselected tests are not proven safe to skip."));

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", try ownedString(allocator, tool_name));
    try analysis_contract.putMetadata(allocator, &obj, tool_name);
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "evidence_sources", try evidence.sourceArrayValue(allocator, &.{ .parser, .heuristic }));
    try obj.put(allocator, "inspected", .{ .object = inspected });
    try obj.put(allocator, "directly_touched_files", .{ .array = touched });
    try obj.put(allocator, "affected_importers", .{ .array = importers });
    try obj.put(allocator, "affected_declarations", .{ .array = declarations });
    try obj.put(allocator, "affected_tests", .{ .array = tests });
    try obj.put(allocator, "public_api", .{ .array = public_api });
    try obj.put(allocator, "recommended_checks", .{ .array = commands });
    try obj.put(allocator, "inferences", .{ .array = inferred });
    try obj.put(allocator, "unknowns", .{ .array = unknowns });
    try obj.put(allocator, "skipped_validation", .{ .array = skipped });
    try obj.put(allocator, "result_complete", .{ .bool = false });
    try obj.put(allocator, "stop_condition", .{ .string = "Stop only after recommended checks and any project release gate pass; impact analysis alone is advisory." });
    return .{ .object = obj };
}

pub fn zigarValidationPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var scratch_app = scratchApp(a, arena.allocator());
    const value = validationPlanValue(arena.allocator(), &scratch_app, args) catch |err| return validationWorkflowError(allocator, "zigar_validation_plan", "plan", err);
    return structured(allocator, value);
}

pub fn zigarValidationRun(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const plan = validationPlanValue(scratch, a, args) catch |err| return validationWorkflowError(allocator, "zigar_validation_run", "plan", err);
    const plan_obj = switch (plan) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const timeout_ms = toolTimeout(a, args);
    const stop_on_failure = argBool(args, "stop_on_failure", false);
    var phases = std.json.Array.init(scratch);
    var skipped = std.json.Array.init(scratch);
    var ok = true;
    var executed_count: usize = 0;

    const plan_phases = switch (plan_obj.get("phases") orelse .null) {
        .array => |array| array,
        else => std.json.Array.init(scratch),
    };
    for (plan_phases.items) |phase_value| {
        const phase_obj = switch (phase_value) {
            .object => |o| o,
            else => continue,
        };
        const phase_kind = stringField(phase_obj, "kind") orelse "";
        if (std.mem.eql(u8, phase_kind, "tool_only")) {
            try skipped.append(try skippedStepValue(scratch, stringField(phase_obj, "id") orelse "tool_only", "Validation runner executes command phases only; call the named tool separately for read-only evidence."));
            continue;
        }
        const argv_value = phase_obj.get("argv") orelse .null;
        const argv = try argvFromValue(scratch, argv_value);
        if (argv.len == 0) {
            try skipped.append(try skippedStepValue(scratch, stringField(phase_obj, "id") orelse "missing_argv", "Phase has no executable argv."));
            continue;
        }
        executed_count += 1;
        const phase_ok = try runValidationPhase(scratch, a, &phases, stringField(phase_obj, "id") orelse "phase", argv, timeout_ms);
        if (!phase_ok) {
            ok = false;
            if (stop_on_failure) break;
        }
    }
    if (executed_count == 0) {
        try skipped.append(try skippedStepValue(scratch, "commands", "No command phases were selected by the validation plan."));
    }

    const history_record = try validationHistoryRecordValue(scratch, a, plan, phases, skipped, ok);
    const output = argString(args, "output") orelse history_path_default;
    const apply = argBool(args, "apply", false);
    const preimage = preimageIdentityForPath(a, scratch, output) catch .null;
    if (apply) {
        const line = try jsonLineForRecord(scratch, history_record);
        const existing = a.workspace.readFileAlloc(a.io, output, 8 * 1024 * 1024) catch "";
        const existing_owned = existing.len > 0;
        defer if (existing_owned) scratch.free(existing);
        var bytes: std.ArrayList(u8) = .empty;
        try bytes.appendSlice(scratch, existing);
        if (bytes.items.len > 0 and bytes.items[bytes.items.len - 1] != '\n') try bytes.append(scratch, '\n');
        try bytes.appendSlice(scratch, line);
        try bytes.append(scratch, '\n');
        a.workspace.writeFile(a.io, output, bytes.items) catch |err| return workspacePathErrorResult(a, allocator, "zigar_validation_run", output, err);
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zigar_validation_run" });
    try obj.put(scratch, "schema_version", .{ .integer = schema_version });
    try obj.put(scratch, "ok", .{ .bool = ok });
    try obj.put(scratch, "plan", plan);
    try obj.put(scratch, "phases", .{ .array = phases });
    try obj.put(scratch, "skipped_phases", .{ .array = skipped });
    try obj.put(scratch, "history_record", history_record);
    try obj.put(scratch, "history_path", try ownedString(scratch, output));
    try obj.put(scratch, "history_applied", .{ .bool = apply });
    try obj.put(scratch, "requires_apply_for_history", .{ .bool = !apply });
    try obj.put(scratch, "preimage_identity", preimage);
    try obj.put(scratch, "next_action", try validationRunNextActionValue(scratch, ok, phases));
    try obj.put(scratch, "stop_condition", .{ .string = "Stop when all selected phases pass and skipped_phases are acceptable for the change risk." });
    return structured(allocator, .{ .object = obj });
}

pub fn zigBuildEvents(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return commandEventsTool(a, allocator, args, "zig_build_events", .build);
}

pub fn zigTestEvents(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return commandEventsTool(a, allocator, args, "zig_test_events", .test_cmd);
}

pub fn zigTestTiming(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = argString(args, "text") orelse return missingArgumentResult(allocator, "zig_test_timing", "text", "captured Zig test output");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const timing = timingValue(arena.allocator(), text) catch return error.OutOfMemory;
    var obj = std.json.ObjectMap.empty;
    try obj.put(arena.allocator(), "kind", .{ .string = "zig_test_timing" });
    try obj.put(arena.allocator(), "schema_version", .{ .integer = schema_version });
    try obj.put(arena.allocator(), "timings", timing);
    try obj.put(arena.allocator(), "parsing_basis", .{ .string = "captured text timing markers" });
    try obj.put(arena.allocator(), "confidence", .{ .string = "medium" });
    return structured(allocator, .{ .object = obj });
}

const EventCommandKind = enum { build, test_cmd };

fn commandEventsTool(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, kind: EventCommandKind) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    if (argString(args, "text")) |text| {
        const value = buildEventsValue(scratch, tool_name, text, "", &.{}, false, "captured_text") catch return error.OutOfMemory;
        return structured(allocator, value);
    }
    const argv = buildEventArgv(scratch, a, args, kind) catch |err| return validationWorkflowError(allocator, tool_name, "build_argv", err);
    a.command_calls += 1;
    const result = command.run(scratch, a.io, a.workspace.root, argv, toolTimeout(a, args)) catch |err| {
        const value = commandErrorEventsValue(scratch, tool_name, argv, a.workspace.root, toolTimeout(a, args), err) catch return error.OutOfMemory;
        return structured(allocator, value);
    };
    const value = buildEventsValue(scratch, tool_name, result.stderr, result.stdout, argv, result.succeeded(), "executed_command") catch return error.OutOfMemory;
    return structured(allocator, value);
}

pub fn zigarValidationHistory(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return historyTool(a, allocator, args, "zigar_validation_history", .runs);
}

pub fn zigTestFlakeHistory(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return historyTool(a, allocator, args, "zig_test_flake_history", .flakes);
}

pub fn zigFailureHistory(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return historyTool(a, allocator, args, "zig_failure_history", .failures);
}

const HistoryView = enum { runs, flakes, failures };

fn historyTool(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, view: HistoryView) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parsed = parseHistory(scratch, a, args) catch |err| return validationWorkflowError(allocator, tool_name, "parse_history", err);
    const value = switch (view) {
        .runs => validationHistoryValue(scratch, tool_name, parsed),
        .flakes => flakeHistoryValue(scratch, tool_name, parsed),
        .failures => failureHistoryValue(scratch, tool_name, parsed),
    } catch return error.OutOfMemory;
    return structured(allocator, value);
}

pub fn zigarSessionSnapshot(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var scratch_app = scratchApp(a, arena.allocator());
    const value = sessionSnapshotValue(arena.allocator(), &scratch_app, args, "zigar_session_snapshot") catch |err| return validationWorkflowError(allocator, "zigar_session_snapshot", "snapshot", err);
    return structured(allocator, value);
}

pub fn zigarHandoffPack(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var scratch_app = scratchApp(a, arena.allocator());
    const snapshot = sessionSnapshotValue(arena.allocator(), &scratch_app, args, "zigar_handoff_pack") catch |err| return validationWorkflowError(allocator, "zigar_handoff_pack", "snapshot", err);
    var steps = std.json.Array.init(arena.allocator());
    try steps.append(try agent_values.toolStepValue(arena.allocator(), "zigar_validation_history", "read recent validation state before rerunning expensive checks"));
    try steps.append(try agent_values.toolStepValue(arena.allocator(), "zigar_capability_match", "route the next goal to a focused tool sequence"));
    try steps.append(try agent_values.toolStepValue(arena.allocator(), "zigar_validation_plan", "recompute checks after any additional edits"));
    var obj = std.json.ObjectMap.empty;
    try obj.put(arena.allocator(), "kind", .{ .string = "zigar_handoff_pack" });
    try obj.put(arena.allocator(), "schema_version", .{ .integer = schema_version });
    try obj.put(arena.allocator(), "snapshot", snapshot);
    try obj.put(arena.allocator(), "recommended_next_steps", .{ .array = steps });
    try obj.put(arena.allocator(), "portable", .{ .bool = true });
    try obj.put(arena.allocator(), "limitations", .{ .string = "Handoff packs summarize observed state; they do not freeze the workspace or prove that unrun validation passed." });
    return structured(allocator, .{ .object = obj });
}

pub fn zigarDecisionRecord(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const title = argString(args, "title") orelse return missingArgumentResult(allocator, "zigar_decision_record", "title", "short decision title");
    const decision = argString(args, "decision") orelse return missingArgumentResult(allocator, "zigar_decision_record", "decision", "decision text");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const path = argString(args, "path") orelse memory_path_default;
    const apply = argBool(args, "apply", false);
    const record = try decisionRecordValue(scratch, a, title, decision, argString(args, "rationale"), argString(args, "category") orelse "architecture");
    const preimage = preimageIdentityForPath(a, scratch, path) catch .null;
    if (apply) {
        const line = try jsonLineForRecord(scratch, record);
        const existing = a.workspace.readFileAlloc(a.io, path, 4 * 1024 * 1024) catch "";
        const existing_owned = existing.len > 0;
        defer if (existing_owned) scratch.free(existing);
        var bytes: std.ArrayList(u8) = .empty;
        try bytes.appendSlice(scratch, existing);
        if (bytes.items.len > 0 and bytes.items[bytes.items.len - 1] != '\n') try bytes.append(scratch, '\n');
        try bytes.appendSlice(scratch, line);
        try bytes.append(scratch, '\n');
        a.workspace.writeFile(a.io, path, bytes.items) catch |err| return workspacePathErrorResult(a, allocator, "zigar_decision_record", path, err);
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zigar_decision_record" });
    try obj.put(scratch, "record", record);
    try obj.put(scratch, "path", try ownedString(scratch, path));
    try obj.put(scratch, "applied", .{ .bool = apply });
    try obj.put(scratch, "requires_apply", .{ .bool = !apply });
    try obj.put(scratch, "preimage_identity", preimage);
    return structured(allocator, .{ .object = obj });
}

pub fn zigarProjectNotes(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return projectMemoryTool(a, allocator, args, "zigar_project_notes", false);
}

pub fn zigarProjectMemory(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return projectMemoryTool(a, allocator, args, "zigar_project_memory", true);
}

fn projectMemoryTool(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, include_builtins: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const path = argString(args, "path") orelse memory_path_default;
    const notes = loadJsonLines(scratch, a, argString(args, "content"), path, @intCast(@max(1, argInt(args, "limit", 100)))) catch |err| return validationWorkflowError(allocator, tool_name, "read_memory", err);
    const query = argString(args, "query");
    const category = argString(args, "category");
    const filtered = try filterRecords(scratch, notes, query, category, @intCast(@max(1, argInt(args, "limit", 100))));
    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", try ownedString(scratch, tool_name));
    try obj.put(scratch, "path", try ownedString(scratch, path));
    try obj.put(scratch, "notes", filtered);
    try obj.put(scratch, "note_count", .{ .integer = @intCast(filtered.array.items.len) });
    try obj.put(scratch, "memory_available", .{ .bool = notes.array.items.len > 0 });
    if (include_builtins) try obj.put(scratch, "built_in_project_policies", try builtInProjectPoliciesValue(scratch));
    try obj.put(scratch, "write_tool", .{ .string = "zigar_decision_record" });
    return structured(allocator, .{ .object = obj });
}

pub fn zigarCapabilityMatch(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const goal = argString(args, "goal") orelse argString(args, "error") orelse argString(args, "diff") orelse return missingArgumentResult(allocator, "zigar_capability_match", "goal", "goal, error, or diff text");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = capabilityMatchValue(arena.allocator(), goal, @intCast(@max(1, argInt(args, "limit", 8)))) catch return error.OutOfMemory;
    return structured(allocator, value);
}

pub fn zigarToolSequencePlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const goal = argString(args, "goal") orelse argString(args, "error") orelse argString(args, "diff") orelse return missingArgumentResult(allocator, "zigar_tool_sequence_plan", "goal", "goal, error, or diff text");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = toolSequencePlanValue(arena.allocator(), goal, argString(args, "changed_files")) catch return error.OutOfMemory;
    return structured(allocator, value);
}

fn validationPlanValue(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value) !std.json.Value {
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(allocator);
    defer freeStringList(allocator, paths.items);
    try appendPathTokens(allocator, &paths, argString(args, "changed_files"));
    try appendPatchPaths(allocator, &paths, argString(args, "diff"));

    var phases = std.json.Array.init(allocator);
    var skipped = std.json.Array.init(allocator);
    var facts = std.json.Array.init(allocator);
    var unknowns = std.json.Array.init(allocator);
    var saw_zig = false;
    var saw_build = false;
    var saw_docs = false;
    for (paths.items) |path| {
        if (std.mem.endsWith(u8, path, ".zig")) saw_zig = true;
        if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) saw_build = true;
        if (std.mem.endsWith(u8, path, ".md")) saw_docs = true;
        try facts.append(try ownedString(allocator, path));
    }
    const mode = argString(args, "mode") orelse "standard";
    const include_semantic = argBool(args, "include_semantic", true);
    if (include_semantic) try phases.append(try phaseValue(allocator, .{ .id = "semantic_impact", .kind = "tool_only", .tool = "zig_impact_semantic", .reason = "Map touched files and symbols to importers, declarations, tests, and public API.", .required = true, .risk = "none" }));
    if (paths.items.len > 0) try phases.append(try phaseValue(allocator, .{ .id = "patch_guard", .kind = "tool_only", .tool = "zigar_patch_guard", .reason = "Check workspace boundaries and generated-path policy before validating edits.", .required = true, .risk = "none" }));
    if (saw_zig) {
        for (paths.items) |path| {
            if (!std.mem.endsWith(u8, path, ".zig")) continue;
            if (!workspacePathExists(allocator, a, path)) continue;
            try phases.append(try phaseValue(allocator, .{ .id = "format_check", .kind = "command", .command = &.{ a.config.zig_path, "fmt", "--check", path }, .reason = "Touched Zig source requires formatting verification.", .required = true, .risk = "project_code" }));
            try phases.append(try phaseValue(allocator, .{ .id = "ast_check", .kind = "command", .command = &.{ a.config.zig_path, "ast-check", path }, .reason = "Touched Zig source requires compiler syntax validation.", .required = true, .risk = "project_code" }));
        }
        try phases.append(try phaseValue(allocator, .{ .id = "semantic_test_select", .kind = "tool_only", .tool = "zig_test_select_semantic", .reason = "Select focused tests from semantic index evidence.", .required = true, .risk = "none" }));
    } else {
        try skipped.append(try skippedStepValue(allocator, "source_file_checks", "No changed Zig source files were supplied."));
    }
    if (!std.mem.eql(u8, mode, "quick") or saw_build or paths.items.len == 0) {
        try phases.append(try phaseValue(allocator, .{ .id = "build_test", .kind = "command", .command = &.{ a.config.zig_path, "build", "test" }, .reason = if (saw_build) "Build configuration changed." else "Standard/full validation includes the project build test gate.", .required = true, .risk = "project_code" }));
    } else {
        try skipped.append(try skippedStepValue(allocator, "build_test", "quick mode skipped the project build test; do not treat this as pass evidence."));
    }
    if (saw_docs) try phases.append(try phaseValue(allocator, .{ .id = "docs_check", .kind = "command", .command = &.{ a.config.zig_path, "build", "docs-check" }, .reason = "Product documentation changed.", .required = true, .risk = "project_code" }));
    if (paths.items.len == 0) try unknowns.append(try ownedString(allocator, "No changed_files or diff were supplied; plan uses workspace-level fallback checks."));

    var risk = std.json.ObjectMap.empty;
    try risk.put(allocator, "changed_file_count", .{ .integer = @intCast(paths.items.len) });
    try risk.put(allocator, "touches_zig_source", .{ .bool = saw_zig });
    try risk.put(allocator, "touches_build_config", .{ .bool = saw_build });
    try risk.put(allocator, "touches_docs", .{ .bool = saw_docs });
    try risk.put(allocator, "level", .{ .string = if (saw_build) "high" else if (saw_zig) "medium" else "low" });

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_validation_plan" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "plan_id", try planIdValue(allocator, paths.items, mode));
    try obj.put(allocator, "mode", try ownedString(allocator, mode));
    try obj.put(allocator, "goal", if (argString(args, "goal")) |goal| try ownedString(allocator, goal) else .null);
    try obj.put(allocator, "facts", .{ .array = facts });
    try obj.put(allocator, "risk", .{ .object = risk });
    try obj.put(allocator, "phases", .{ .array = phases });
    try obj.put(allocator, "skipped_phases", .{ .array = skipped });
    try obj.put(allocator, "unknowns", .{ .array = unknowns });
    try obj.put(allocator, "execution_policy", .{ .string = "plan-first; no environment installs or source writes are performed by this planner" });
    try obj.put(allocator, "stop_condition", .{ .string = "Run required phases until they pass or the first blocking failure is understood." });
    try obj.put(allocator, "next_action", try agent_values.toolStepValue(allocator, "zigar_validation_run", "execute command phases and retain structured events/history"));
    return .{ .object = obj };
}

fn phaseValue(allocator: std.mem.Allocator, phase: ValidationPhase) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "id", try ownedString(allocator, phase.id));
    try obj.put(allocator, "kind", try ownedString(allocator, phase.kind));
    if (phase.tool) |tool| try obj.put(allocator, "tool", try ownedString(allocator, tool)) else try obj.put(allocator, "tool", .null);
    if (phase.command) |argv| try obj.put(allocator, "argv", try common.argvValue(allocator, argv)) else try obj.put(allocator, "argv", .null);
    try obj.put(allocator, "reason", try ownedString(allocator, phase.reason));
    try obj.put(allocator, "required", .{ .bool = phase.required });
    try obj.put(allocator, "risk", try ownedString(allocator, phase.risk));
    return .{ .object = obj };
}

fn runValidationPhase(allocator: std.mem.Allocator, a: *App, phases: *std.json.Array, name: []const u8, argv: []const []const u8, timeout_ms: i64) !bool {
    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, argv, timeout_ms) catch |err| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "name", try ownedString(allocator, name));
        try obj.put(allocator, "ok", .{ .bool = false });
        try obj.put(allocator, "command", try commandErrorValue(allocator, name, argv, a.workspace.root, timeout_ms, err));
        try obj.put(allocator, "events", try commandErrorEventsValue(allocator, "validation_phase", argv, a.workspace.root, timeout_ms, err));
        try phases.append(.{ .object = obj });
        return false;
    };
    defer result.deinit(allocator);
    const ok = result.succeeded();
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, name));
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "command", try commandResultValue(allocator, name, argv, a.workspace.root, timeout_ms, result));
    try obj.put(allocator, "events", try buildEventsValue(allocator, "validation_phase", result.stderr, result.stdout, argv, ok, "executed_command"));
    try phases.append(.{ .object = obj });
    return ok;
}

fn buildEventsValue(allocator: std.mem.Allocator, tool_name: []const u8, stderr: []const u8, stdout: []const u8, argv: []const []const u8, ok: bool, basis: []const u8) !std.json.Value {
    var events = std.json.Array.init(allocator);
    try collectLineEvents(allocator, &events, stderr, "stderr");
    try collectLineEvents(allocator, &events, stdout, "stdout");
    const compiler = try compilerInsightsValue(allocator, stdout, stderr, argv);
    const tests = try static_analysis.testFailureTriageValue(allocator, stderr, stdout, argv, ok);
    var timings = try timingValue(allocator, stderr);
    const stdout_timings = try timingValue(allocator, stdout);
    try timings.array.appendSlice(stdout_timings.array.items);
    const compiler_error_count: i64 = if (compiler.object.get("error_count")) |value| switch (value) {
        .integer => |n| n,
        else => 0,
    } else 0;
    const test_failure_count: usize = if (tests.object.get("failures")) |value| switch (value) {
        .array => |failures| failures.items.len,
        else => 0,
    } else 0;
    var summary = std.json.ObjectMap.empty;
    try summary.put(allocator, "event_count", .{ .integer = @intCast(events.items.len) });
    try summary.put(allocator, "compiler_error_count", .{ .integer = compiler_error_count });
    try summary.put(allocator, "test_failure_count", .{ .integer = @intCast(test_failure_count) });
    try summary.put(allocator, "timing_count", .{ .integer = @intCast(timings.array.items.len) });

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", try ownedString(allocator, tool_name));
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "argv", try common.argvValue(allocator, argv));
    try obj.put(allocator, "parsing_basis", try ownedString(allocator, basis));
    try obj.put(allocator, "events", .{ .array = events });
    try obj.put(allocator, "compiler", compiler);
    try obj.put(allocator, "tests", tests);
    try obj.put(allocator, "timings", timings);
    try obj.put(allocator, "summary", .{ .object = summary });
    try obj.put(allocator, "confidence", .{ .string = if (std.mem.eql(u8, basis, "executed_command")) "high" else "medium" });
    try obj.put(allocator, "limitations", .{ .string = "Event parsing is best-effort over Zig stdout/stderr; raw command output remains the audit source." });
    return .{ .object = obj };
}

fn commandErrorEventsValue(allocator: std.mem.Allocator, tool_name: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", try ownedString(allocator, tool_name));
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "command", try commandErrorValue(allocator, tool_name, argv, cwd, timeout_ms, err));
    try obj.put(allocator, "events", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "error_kind", .{ .string = command.errorKind(err) });
    try obj.put(allocator, "resolution", .{ .string = "Confirm the configured Zig executable and workspace command can run, or pass captured output as text." });
    return .{ .object = obj };
}

fn collectLineEvents(allocator: std.mem.Allocator, events: *std.json.Array, text: []const u8, stream: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 1;
    while (lines.next()) |raw| : (line_no += 1) {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const event_type = classifyEventLine(line);
        if (std.mem.eql(u8, event_type, "output")) continue;
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
        try obj.put(allocator, "stream", try ownedString(allocator, stream));
        try obj.put(allocator, "event", try ownedString(allocator, event_type));
        try obj.put(allocator, "message", try ownedString(allocator, line));
        try events.append(.{ .object = obj });
    }
}

fn classifyEventLine(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, ": error: ") != null or std.mem.startsWith(u8, line, "error: ")) return "compiler_error";
    if (std.mem.indexOf(u8, line, ": warning: ") != null or std.mem.startsWith(u8, line, "warning: ")) return "compiler_warning";
    if (std.mem.indexOf(u8, line, "FAIL") != null or std.mem.indexOf(u8, line, "failed") != null) return "test_failure";
    if (std.mem.indexOf(u8, line, "PASS") != null or std.mem.indexOf(u8, line, "passed") != null) return "test_pass";
    if (std.mem.indexOf(u8, line, "Step ") != null) return "build_step";
    return "output";
}

fn timingValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var timings = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (parseDurationMs(line)) |ms| {
            var obj = std.json.ObjectMap.empty;
            try obj.put(allocator, "name", try ownedString(allocator, line));
            try obj.put(allocator, "duration_ms", .{ .integer = ms });
            try obj.put(allocator, "source", .{ .string = "text" });
            try timings.append(.{ .object = obj });
        }
    }
    return .{ .array = timings };
}

fn parseDurationMs(line: []const u8) ?i64 {
    if (std.mem.indexOf(u8, line, "ms")) |ms_pos| {
        var start = ms_pos;
        while (start > 0 and std.ascii.isDigit(line[start - 1])) start -= 1;
        if (start < ms_pos) return std.fmt.parseInt(i64, line[start..ms_pos], 10) catch null;
    }
    return null;
}

fn buildEventArgv(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value, kind: EventCommandKind) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(allocator, a.config.zig_path);
    const command_name = argString(args, "command") orelse switch (kind) {
        .build => "build-test",
        .test_cmd => "test",
    };
    if (std.mem.eql(u8, command_name, "build")) {
        try list.append(allocator, "build");
    } else if (std.mem.eql(u8, command_name, "build-test")) {
        try list.append(allocator, "build");
        try list.append(allocator, "test");
    } else if (std.mem.eql(u8, command_name, "check")) {
        try list.append(allocator, "ast-check");
        const file = argString(args, "file") orelse return error.MissingFile;
        const resolved = try a.workspace.resolve(file);
        try list.append(allocator, resolved);
    } else if (std.mem.eql(u8, command_name, "fmt-check")) {
        try list.append(allocator, "fmt");
        try list.append(allocator, "--check");
        if (argString(args, "file")) |file| try list.append(allocator, file) else try list.append(allocator, "src");
    } else if (std.mem.eql(u8, command_name, "test")) {
        try list.append(allocator, "test");
        if (argString(args, "file")) |file| {
            const resolved = try a.workspace.resolve(file);
            try list.append(allocator, resolved);
        } else {
            return error.MissingFile;
        }
        if (argString(args, "filter")) |filter| {
            try list.append(allocator, "--test-filter");
            try list.append(allocator, filter);
        }
    } else return error.InvalidCommand;
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return err;
    defer freeArgList(allocator, extra);
    try list.appendSlice(allocator, extra);
    return list.toOwnedSlice(allocator);
}

fn validationHistoryRecordValue(allocator: std.mem.Allocator, a: *App, plan: std.json.Value, phases: std.json.Array, skipped: std.json.Array, ok: bool) !std.json.Value {
    var failures = std.json.Array.init(allocator);
    var slow = std.json.Array.init(allocator);
    for (phases.items) |phase_value| {
        const phase_obj = switch (phase_value) {
            .object => |o| o,
            else => continue,
        };
        const phase_ok = boolField(phase_obj, "ok") orelse true;
        if (!phase_ok) try failures.append(try failureRecordFromPhase(allocator, phase_obj));
        if (phaseDurationMs(phase_obj) > 1000) try slow.append(try slowPhaseRecordValue(allocator, phase_obj));
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    const recorded_unix_ms: i64 = @intCast(@divTrunc(std.Io.Clock.now(.real, a.io).nanoseconds, std.time.ns_per_ms));
    try obj.put(allocator, "recorded_unix_ms", .{ .integer = recorded_unix_ms });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "plan_id", switch (plan) {
        .object => |o| o.get("plan_id") orelse .null,
        else => .null,
    });
    try obj.put(allocator, "phase_count", .{ .integer = @intCast(phases.items.len) });
    try obj.put(allocator, "skipped_count", .{ .integer = @intCast(skipped.items.len) });
    try obj.put(allocator, "failures", .{ .array = failures });
    try obj.put(allocator, "slow_phases", .{ .array = slow });
    try obj.put(allocator, "phases", .{ .array = phases });
    try obj.put(allocator, "skipped_phases", .{ .array = skipped });
    return .{ .object = obj };
}

fn validationHistoryValue(allocator: std.mem.Allocator, tool_name: []const u8, parsed: ParsedHistory) !std.json.Value {
    var last_good: std.json.Value = .null;
    var last_run: std.json.Value = .null;
    for (parsed.runs.items) |run| {
        last_run = run;
        const obj = switch (run) {
            .object => |o| o,
            else => continue,
        };
        if (boolField(obj, "ok") orelse false) last_good = run;
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", try ownedString(allocator, tool_name));
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "history_available", .{ .bool = !parsed.unavailable });
    try obj.put(allocator, "run_count", .{ .integer = @intCast(parsed.runs.items.len) });
    try obj.put(allocator, "last_run", last_run);
    try obj.put(allocator, "last_good", last_good);
    try obj.put(allocator, "runs", .{ .array = parsed.runs });
    try obj.put(allocator, "failure_summary", try failureGroupsValue(allocator, parsed.runs));
    try obj.put(allocator, "limitations", .{ .string = "History reflects records supplied to or written by zigar validation tools; it is not a complete CI database." });
    return .{ .object = obj };
}

fn flakeHistoryValue(allocator: std.mem.Allocator, tool_name: []const u8, parsed: ParsedHistory) !std.json.Value {
    const failures = try failureGroupsValue(allocator, parsed.runs);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", try ownedString(allocator, tool_name));
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "history_available", .{ .bool = !parsed.unavailable });
    try obj.put(allocator, "flakes", failures);
    try obj.put(allocator, "confidence", .{ .string = if (parsed.runs.items.len >= 3) "medium" else "low" });
    try obj.put(allocator, "limitations", .{ .string = "Flake detection is recurrence over retained validation records; confirm with repeated test runs before suppressing failures." });
    return .{ .object = obj };
}

fn failureHistoryValue(allocator: std.mem.Allocator, tool_name: []const u8, parsed: ParsedHistory) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", try ownedString(allocator, tool_name));
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "history_available", .{ .bool = !parsed.unavailable });
    try obj.put(allocator, "recurring_failures", try failureGroupsValue(allocator, parsed.runs));
    try obj.put(allocator, "run_count", .{ .integer = @intCast(parsed.runs.items.len) });
    return .{ .object = obj };
}

fn parseHistory(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value) !ParsedHistory {
    const limit: usize = @intCast(@max(1, argInt(args, "limit", 50)));
    const path = argString(args, "path") orelse history_path_default;
    const runs = std.json.Array.init(allocator);
    if (argString(args, "history")) |history| {
        return .{ .runs = try parseJsonLinesOrArray(allocator, history, limit), .unavailable = false };
    }
    const bytes = a.workspace.readFileAlloc(a.io, path, 8 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{ .runs = runs, .unavailable = true },
        else => return err,
    };
    return .{ .runs = try parseJsonLinesOrArray(allocator, bytes, limit), .unavailable = false };
}

fn parseJsonLinesOrArray(allocator: std.mem.Allocator, text: []const u8, limit: usize) !std.json.Array {
    var out = std.json.Array.init(allocator);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return out;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed[0] == '[') {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
        defer parsed.deinit();
        const array = switch (parsed.value) {
            .array => |a| a,
            else => return out,
        };
        for (array.items) |item| {
            if (out.items.len >= limit) break;
            try out.append(try json_result.cloneValue(allocator, item));
        }
        return out;
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (out.items.len >= limit) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try out.append(try json_result.cloneValue(allocator, parsed.value));
    }
    return out;
}

fn loadJsonLines(allocator: std.mem.Allocator, a: *App, content: ?[]const u8, path: []const u8, limit: usize) !std.json.Value {
    if (content) |text| return .{ .array = try parseJsonLinesOrArray(allocator, text, limit) };
    const bytes = a.workspace.readFileAlloc(a.io, path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{ .array = std.json.Array.init(allocator) },
        else => return err,
    };
    return .{ .array = try parseJsonLinesOrArray(allocator, bytes, limit) };
}

fn sessionSnapshotValue(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value, kind: []const u8) !std.json.Value {
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(allocator);
    defer freeStringList(allocator, paths.items);
    try appendPathTokens(allocator, &paths, argString(args, "changed_files"));
    try appendPatchPaths(allocator, &paths, argString(args, "diff"));
    var files = std.json.Array.init(allocator);
    for (paths.items) |path| try files.append(try ownedString(allocator, path));
    const validation = if (argString(args, "validation")) |text| parseJsonValueOrString(allocator, text) catch try ownedString(allocator, text) else .null;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", try ownedString(allocator, kind));
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "goal", if (argString(args, "goal")) |goal| try ownedString(allocator, goal) else .null);
    try obj.put(allocator, "changed_files", .{ .array = files });
    try obj.put(allocator, "validation", validation);
    try obj.put(allocator, "last_error", if (argString(args, "last_error")) |err| try ownedString(allocator, err) else .null);
    try obj.put(allocator, "workspace", try agent_values.contextWorkspaceValue(allocator, a));
    try obj.put(allocator, "profile_state", try profileStateValue(allocator, a));
    try obj.put(allocator, "recommended_next_action", try agent_values.nextActionPlanValue(allocator, argString(args, "goal") orelse "continue validation", argString(args, "changed_files"), argString(args, "last_error")));
    try obj.put(allocator, "limitations", .{ .string = "Snapshot is a point-in-time summary over caller-supplied state and current workspace metadata." });
    return .{ .object = obj };
}

fn profileStateValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "profile_v2_path", .{ .string = ".zigar/profile.v2.json" });
    if (a.workspace.readFileAlloc(a.io, ".zigar/profile.v2.json", 1024 * 1024) catch null) |bytes| {
        defer allocator.free(bytes);
        try obj.put(allocator, "profile_v2_present", .{ .bool = true });
        const hash = try artifacts.sha256Hex(allocator, bytes);
        try obj.put(allocator, "sha256", .{ .string = hash });
    } else {
        try obj.put(allocator, "profile_v2_present", .{ .bool = false });
        try obj.put(allocator, "sha256", .null);
    }
    return .{ .object = obj };
}

fn decisionRecordValue(allocator: std.mem.Allocator, a: *App, title: []const u8, decision: []const u8, rationale: ?[]const u8, category: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "id", try ownedString(allocator, try std.fmt.allocPrint(allocator, "decision-{d}", .{@divTrunc(std.Io.Clock.now(.real, a.io).nanoseconds, std.time.ns_per_ms)})));
    try obj.put(allocator, "category", try ownedString(allocator, category));
    try obj.put(allocator, "title", try ownedString(allocator, title));
    try obj.put(allocator, "decision", try ownedString(allocator, decision));
    try obj.put(allocator, "rationale", if (rationale) |value| try ownedString(allocator, value) else .null);
    try obj.put(allocator, "source", .{ .string = "zigar_decision_record" });
    return .{ .object = obj };
}

fn capabilityMatchValue(allocator: std.mem.Allocator, goal: []const u8, limit: usize) !std.json.Value {
    const lower = try std.ascii.allocLowerString(allocator, goal);
    var matches = std.json.Array.init(allocator);
    for (tool_manifest.entries) |entry| {
        const score = matchScore(allocator, lower, entry) catch 0;
        if (score == 0) continue;
        try appendCapabilityMatch(allocator, &matches, entry, score);
    }
    sortMatches(&matches);
    while (matches.items.len > limit) _ = matches.pop();
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_capability_match" });
    try obj.put(allocator, "goal", try ownedString(allocator, goal));
    try obj.put(allocator, "matches", .{ .array = matches });
    try obj.put(allocator, "confidence", .{ .string = if (matches.items.len > 0) "medium" else "low" });
    try obj.put(allocator, "limitations", .{ .string = "Capability matching uses manifest descriptions, groups, and keywords; it does not execute tools or inspect all project state." });
    return .{ .object = obj };
}

fn toolSequencePlanValue(allocator: std.mem.Allocator, goal: []const u8, changed_files: ?[]const u8) !std.json.Value {
    const lower = try std.ascii.allocLowerString(allocator, goal);
    var steps = std.json.Array.init(allocator);
    if (std.mem.indexOf(u8, lower, "test") != null or std.mem.indexOf(u8, lower, "fail") != null) {
        try steps.append(try sequenceStepValue(allocator, "zig_test_events", "Parse failing test output or run a focused test command.", false));
        try steps.append(try sequenceStepValue(allocator, "zig_failure_history", "Check whether the failure is recurring.", false));
        try steps.append(try sequenceStepValue(allocator, "zigar_validation_plan", "Plan the post-fix validation gate.", false));
        try steps.append(try sequenceStepValue(allocator, "zigar_validation_run", "Execute selected command phases.", true));
    } else if (std.mem.indexOf(u8, lower, "impact") != null or changed_files != null) {
        try steps.append(try sequenceStepValue(allocator, "zig_impact_semantic", "Map changed files to semantic impact.", false));
        try steps.append(try sequenceStepValue(allocator, "zig_test_select_semantic", "Choose focused tests from semantic evidence.", false));
        try steps.append(try sequenceStepValue(allocator, "zigar_validation_plan", "Escalate to risk-aware validation.", false));
    } else if (std.mem.indexOf(u8, lower, "handoff") != null or std.mem.indexOf(u8, lower, "resume") != null) {
        try steps.append(try sequenceStepValue(allocator, "zigar_session_snapshot", "Capture current workspace and validation state.", false));
        try steps.append(try sequenceStepValue(allocator, "zigar_handoff_pack", "Package recommended next steps.", false));
    } else {
        try steps.append(try sequenceStepValue(allocator, "zigar_capability_match", "Find the strongest zigar tools for the goal.", false));
        try steps.append(try sequenceStepValue(allocator, "zigar_validation_plan", "Plan checks before handing work back.", false));
        try steps.append(try sequenceStepValue(allocator, "zigar_validation_run", "Run selected checks when ready.", true));
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_tool_sequence_plan" });
    try obj.put(allocator, "goal", try ownedString(allocator, goal));
    try obj.put(allocator, "changed_files", if (changed_files) |files| try ownedString(allocator, files) else .null);
    try obj.put(allocator, "sequence", .{ .array = steps });
    try obj.put(allocator, "stop_condition", .{ .string = "Stop after the first blocking tool result or after validation_run reports ok=true with acceptable skipped phases." });
    return .{ .object = obj };
}

fn semanticWorkflowError(allocator: std.mem.Allocator, tool_name: []const u8, phase: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = "semantic_validation_workflow",
        .phase = phase,
        .code = "semantic_workflow_failed",
        .category = "static_analysis",
        .resolution = "Retry with a smaller limit or provide explicit files/symbols; inspect unreadable Zig files if the failure repeats.",
    }, err);
}

fn validationWorkflowError(allocator: std.mem.Allocator, tool_name: []const u8, phase: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = "validation_workflow",
        .phase = phase,
        .code = "validation_workflow_failed",
        .category = "agent_workflow",
        .resolution = "Inspect tool arguments and workspace paths; pass captured text for parsing-only workflows when command execution is unavailable.",
    }, err);
}

fn skippedStepValue(allocator: std.mem.Allocator, name: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, name));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    return .{ .object = obj };
}

fn appendUniqueFileObject(allocator: std.mem.Allocator, out: *std.json.Array, file: []const u8, reason: []const u8, confidence: evidence.Confidence) !void {
    for (out.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (std.mem.eql(u8, stringField(obj, "file") orelse "", file)) return;
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    try obj.put(allocator, "confidence", .{ .string = evidence.confidenceName(confidence) });
    try out.append(.{ .object = obj });
}

fn collectImportersForFile(allocator: std.mem.Allocator, imports_value: std.json.Value, out: *std.json.Array, target: []const u8) !void {
    const imports = switch (imports_value) {
        .array => |a| a,
        else => return,
    };
    for (imports.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const imported = stringField(obj, "import") orelse "";
        if (!importMatchesTarget(imported, target)) continue;
        const file = stringField(obj, "file") orelse continue;
        try appendImpactMatch(allocator, out, file, target, "imports_changed_file", .parser, .high);
    }
}

fn collectTestsForFile(allocator: std.mem.Allocator, tests_value: std.json.Value, out: *std.json.Array, target: []const u8) !void {
    const tests = switch (tests_value) {
        .array => |a| a,
        else => return,
    };
    for (tests.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const file = stringField(obj, "file") orelse continue;
        if (std.mem.eql(u8, file, target) or agent_values.referencesFileStem(stringField(obj, "name") orelse "", target)) {
            try appendImpactMatch(allocator, out, file, target, "test_matches_changed_file", .parser, .high);
        }
    }
}

fn collectPublicApiForFile(allocator: std.mem.Allocator, decls_value: std.json.Value, out: *std.json.Array, target: []const u8) !void {
    const decls = switch (decls_value) {
        .array => |a| a,
        else => return,
    };
    for (decls.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (!std.mem.eql(u8, stringField(obj, "file") orelse "", target)) continue;
        if (!(boolField(obj, "public") orelse false)) continue;
        try out.append(try json_result.cloneValue(allocator, item));
    }
}

fn collectDeclarationsForSymbol(allocator: std.mem.Allocator, decls_value: std.json.Value, out: *std.json.Array, symbol: []const u8) !void {
    const decls = switch (decls_value) {
        .array => |a| a,
        else => return,
    };
    for (decls.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = stringField(obj, "name") orelse "";
        const signature = stringField(obj, "signature") orelse "";
        if (std.mem.indexOf(u8, name, symbol) == null and std.mem.indexOf(u8, signature, symbol) == null) continue;
        try out.append(try json_result.cloneValue(allocator, item));
    }
}

fn collectTestsForSymbol(allocator: std.mem.Allocator, tests_value: std.json.Value, out: *std.json.Array, symbol: []const u8) !void {
    const tests = switch (tests_value) {
        .array => |a| a,
        else => return,
    };
    for (tests.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = stringField(obj, "name") orelse "";
        const file = stringField(obj, "file") orelse "";
        if (std.mem.indexOf(u8, name, symbol) == null and std.mem.indexOf(u8, file, symbol) == null) continue;
        try appendImpactMatch(allocator, out, file, symbol, "test_matches_symbol", .parser, .high);
    }
}

fn appendImpactMatch(allocator: std.mem.Allocator, out: *std.json.Array, file: []const u8, target: []const u8, reason: []const u8, source: evidence.Source, confidence: evidence.Confidence) !void {
    for (out.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (std.mem.eql(u8, stringField(obj, "file") orelse "", file) and std.mem.eql(u8, stringField(obj, "target") orelse "", target) and std.mem.eql(u8, stringField(obj, "reason") orelse "", reason)) return;
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "target", try ownedString(allocator, target));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    try obj.put(allocator, "source", .{ .string = evidence.sourceName(source) });
    try obj.put(allocator, "confidence", .{ .string = evidence.confidenceName(confidence) });
    try out.append(.{ .object = obj });
}

fn appendCommandsFromMatches(allocator: std.mem.Allocator, commands: *std.json.Array, matches: std.json.Array) !void {
    for (matches.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const file = stringField(obj, "file") orelse continue;
        if (std.mem.endsWith(u8, file, ".zig")) try appendUniqueCommand(allocator, commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{file}));
    }
}

fn appendCommandsForImpact(allocator: std.mem.Allocator, commands: *std.json.Array, reasons: *std.json.Array, value: std.json.Value, reason: []const u8) !void {
    const array = switch (value) {
        .array => |a| a,
        else => return,
    };
    for (array.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const file = stringField(obj, "file") orelse continue;
        if (!std.mem.endsWith(u8, file, ".zig")) continue;
        try appendUniqueCommand(allocator, commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{file}));
        try reasons.append(try ownedString(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ file, reason })));
    }
}

fn importMatchesTarget(imported: []const u8, target: []const u8) bool {
    const base = std.fs.path.basename(target);
    return std.mem.eql(u8, imported, target) or
        std.mem.eql(u8, imported, base) or
        std.mem.indexOf(u8, imported, base) != null;
}

fn workspacePathExists(allocator: std.mem.Allocator, a: *App, path: []const u8) bool {
    return static_analysis.workspacePathExists(allocator, a, path);
}

fn argvFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    const array = switch (value) {
        .array => |a| a,
        else => return &.{},
    };
    var list: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        const s = switch (item) {
            .string => |v| v,
            else => continue,
        };
        try list.append(allocator, s);
    }
    return list.toOwnedSlice(allocator);
}

fn planIdValue(allocator: std.mem.Allocator, files: []const []const u8, mode: []const u8) !std.json.Value {
    var hasher = std.hash.Wyhash.init(4);
    hasher.update(mode);
    for (files) |file| hasher.update(file);
    return .{ .string = try std.fmt.allocPrint(allocator, "validation-{x}", .{hasher.final()}) };
}

fn validationRunNextActionValue(allocator: std.mem.Allocator, ok: bool, phases: std.json.Array) !std.json.Value {
    if (ok) return agent_values.validationNextActionValue(allocator, true, phases);
    return agent_values.validationNextActionValue(allocator, false, phases);
}

fn failureRecordFromPhase(allocator: std.mem.Allocator, phase_obj: std.json.ObjectMap) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    const name = stringField(phase_obj, "name") orelse "phase";
    try obj.put(allocator, "phase", try ownedString(allocator, name));
    try obj.put(allocator, "fingerprint", try ownedString(allocator, try std.fmt.allocPrint(allocator, "phase:{s}", .{name})));
    const command_value = phase_obj.get("command") orelse .null;
    try obj.put(allocator, "command", command_value);
    return .{ .object = obj };
}

fn slowPhaseRecordValue(allocator: std.mem.Allocator, phase_obj: std.json.ObjectMap) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "phase", try ownedString(allocator, stringField(phase_obj, "name") orelse "phase"));
    try obj.put(allocator, "duration_ms", .{ .integer = phaseDurationMs(phase_obj) });
    return .{ .object = obj };
}

fn phaseDurationMs(phase_obj: std.json.ObjectMap) i64 {
    const command_value = phase_obj.get("command") orelse .null;
    const command_obj = switch (command_value) {
        .object => |o| o,
        else => return 0,
    };
    return integerField(command_obj, "duration_ms") orelse 0;
}

fn failureGroupsValue(allocator: std.mem.Allocator, runs: std.json.Array) !std.json.Value {
    var groups = std.json.Array.init(allocator);
    for (runs.items) |run| {
        const run_obj = switch (run) {
            .object => |o| o,
            else => continue,
        };
        const failures = switch (run_obj.get("failures") orelse .null) {
            .array => |a| a,
            else => continue,
        };
        for (failures.items) |failure| {
            const failure_obj = switch (failure) {
                .object => |o| o,
                else => continue,
            };
            const fingerprint = stringField(failure_obj, "fingerprint") orelse stringField(failure_obj, "phase") orelse "unknown";
            try incrementGroup(allocator, &groups, fingerprint, failure);
        }
    }
    return .{ .array = groups };
}

fn incrementGroup(allocator: std.mem.Allocator, groups: *std.json.Array, fingerprint: []const u8, sample: std.json.Value) !void {
    for (groups.items) |*item| {
        const obj = switch (item.*) {
            .object => |*o| o,
            else => continue,
        };
        if (!std.mem.eql(u8, stringField(obj.*, "fingerprint") orelse "", fingerprint)) continue;
        const count = integerField(obj.*, "count") orelse 0;
        try obj.put(allocator, "count", .{ .integer = count + 1 });
        return;
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "fingerprint", try ownedString(allocator, fingerprint));
    try obj.put(allocator, "count", .{ .integer = 1 });
    try obj.put(allocator, "sample", sample);
    try groups.append(.{ .object = obj });
}

fn jsonLineForRecord(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try json_result.serializeValue(allocator, &out, value);
    return out.toOwnedSlice(allocator);
}

fn preimageIdentityForPath(a: *App, allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    const resolved = a.workspace.resolveOutput(path) catch return preimageValue(allocator, false, 0, "");
    defer allocator.free(resolved);
    const bytes = std.Io.Dir.cwd().readFileAlloc(a.io, resolved, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return preimageValue(allocator, false, 0, ""),
        else => return preimageValue(allocator, false, 0, ""),
    };
    defer allocator.free(bytes);
    const hash = try artifacts.sha256Hex(allocator, bytes);
    return preimageValue(allocator, true, bytes.len, hash);
}

fn preimageValue(allocator: std.mem.Allocator, exists: bool, bytes: usize, sha256: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exists", .{ .bool = exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes) });
    try obj.put(allocator, "sha256", if (sha256.len > 0) try ownedString(allocator, sha256) else .null);
    return .{ .object = obj };
}

fn parseJsonValueOrString(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return ownedString(allocator, text);
    defer parsed.deinit();
    return json_result.cloneValue(allocator, parsed.value);
}

fn filterRecords(allocator: std.mem.Allocator, records: std.json.Value, query: ?[]const u8, category: ?[]const u8, limit: usize) !std.json.Value {
    const array = switch (records) {
        .array => |a| a,
        else => return .{ .array = std.json.Array.init(allocator) },
    };
    const lower_query = if (query) |q| try std.ascii.allocLowerString(allocator, q) else "";
    var out = std.json.Array.init(allocator);
    for (array.items) |item| {
        if (out.items.len >= limit) break;
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (category) |cat| if (!std.mem.eql(u8, stringField(obj, "category") orelse "", cat)) continue;
        if (query != null) {
            const hay = try std.ascii.allocLowerString(allocator, try searchableRecordText(allocator, obj));
            if (std.mem.indexOf(u8, hay, lower_query) == null) continue;
        }
        try out.append(try json_result.cloneValue(allocator, item));
    }
    return .{ .array = out };
}

fn searchableRecordText(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{
        stringField(obj, "title") orelse "",
        stringField(obj, "decision") orelse "",
        stringField(obj, "rationale") orelse "",
        stringField(obj, "category") orelse "",
    });
}

fn builtInProjectPoliciesValue(allocator: std.mem.Allocator) !std.json.Value {
    var array = std.json.Array.init(allocator);
    try array.append(try policyValue(allocator, "generated_paths", "Do not edit generated/cache outputs directly; change source or regeneration steps.", &.{ ".zig-cache", ".zigar-cache", "zig-out", "coverage" }));
    try array.append(try policyValue(allocator, "validation", "Treat skipped phases as unknown, not passed.", &.{ "zigar_validation_plan", "zigar_validation_run" }));
    try array.append(try policyValue(allocator, "writes", "Source and project-memory writes require explicit apply=true.", &.{"zigar_decision_record"}));
    return .{ .array = array };
}

fn policyValue(allocator: std.mem.Allocator, name: []const u8, policy: []const u8, values: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, name));
    try obj.put(allocator, "policy", try ownedString(allocator, policy));
    try obj.put(allocator, "values", try evidence.stringArrayValue(allocator, values));
    return .{ .object = obj };
}

fn matchScore(allocator: std.mem.Allocator, lower_goal: []const u8, entry: tool_manifest.ToolEntry) !i64 {
    var score: i64 = 0;
    const lower_name = try std.ascii.allocLowerString(allocator, entry.name);
    if (std.mem.indexOf(u8, lower_goal, lower_name) != null) score += 10;
    const lower_desc = try std.ascii.allocLowerString(allocator, entry.meta.description);
    var tokens = std.mem.tokenizeAny(u8, lower_goal, " \t\r\n,.;:/_-");
    while (tokens.next()) |token| {
        if (token.len < 3) continue;
        if (std.mem.indexOf(u8, lower_name, token) != null) score += 3;
        if (std.mem.indexOf(u8, lower_desc, token) != null) score += 1;
    }
    for (tool_manifest.groupKeywords(entry.group)) |keyword| {
        const lower_keyword = try std.ascii.allocLowerString(allocator, keyword);
        if (std.mem.indexOf(u8, lower_goal, lower_keyword) != null) score += 2;
    }
    return score;
}

fn appendCapabilityMatch(allocator: std.mem.Allocator, matches: *std.json.Array, entry: tool_manifest.ToolEntry, score: i64) !void {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tool", try ownedString(allocator, entry.name));
    try obj.put(allocator, "score", .{ .integer = score });
    try obj.put(allocator, "confidence", .{ .string = if (score >= 8) "high" else if (score >= 3) "medium" else "low" });
    try obj.put(allocator, "group", .{ .string = tool_manifest.groupName(entry.group) });
    try obj.put(allocator, "risk", try tool_manifest.riskValue(allocator, entry.meta));
    try obj.put(allocator, "plan_kind", .{ .string = tool_manifest.planKind(entry.plan) });
    try obj.put(allocator, "description", try ownedString(allocator, entry.meta.description));
    try matches.append(.{ .object = obj });
}

fn sortMatches(matches: *std.json.Array) void {
    std.mem.sort(std.json.Value, matches.items, {}, struct {
        fn lessThan(_: void, lhs: std.json.Value, rhs: std.json.Value) bool {
            const left = switch (lhs) {
                .object => |o| integerField(o, "score") orelse 0,
                else => 0,
            };
            const right = switch (rhs) {
                .object => |o| integerField(o, "score") orelse 0,
                else => 0,
            };
            return left > right;
        }
    }.lessThan);
}

fn sequenceStepValue(allocator: std.mem.Allocator, tool: []const u8, reason: []const u8, executes: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tool", try ownedString(allocator, tool));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    try obj.put(allocator, "executes_project_code", .{ .bool = executes });
    return .{ .object = obj };
}

fn boolField(obj: std.json.ObjectMap, field: []const u8) ?bool {
    return switch (obj.get(field) orelse .null) {
        .bool => |b| b,
        else => null,
    };
}

fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return evidence.stringField(obj, field);
}

fn integerField(obj: std.json.ObjectMap, field: []const u8) ?i64 {
    return evidence.integerField(obj, field);
}
