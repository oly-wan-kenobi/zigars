const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const analysis_contract = zigar.analysis_contract;
const command = zigar.command;
const evidence = zigar.evidence;
const json_result = zigar.json_result;
const common = @import("common.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const argBool = common.argBool;
const argInt = common.argInt;
const missingArgumentResult = common.missingArgumentResult;
const workspacePathErrorResult = common.workspacePathErrorResult;
const backendErrorResult = common.backendErrorResult;
const splitToolArgs = common.splitToolArgs;
const splitToolArgsErrorResult = common.splitToolArgsErrorResult;
const freeArgList = common.freeArgList;
const toolTimeout = common.toolTimeout;

pub const FindingSource = enum { zlint, zwanzig };

const ZlintCommand = struct {
    executable: []const u8,
    path: []const u8,
    config: ?[]const u8 = null,
    rules: ?[]const u8 = null,
    extra: []const []const u8 = &.{},
};

const LintProfile = struct {
    allow_warnings: bool,
    max_warnings: i64,
    require_backend: bool,
};

pub fn buildZlintArgv(allocator: std.mem.Allocator, spec: ZlintCommand) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &.{ spec.executable, "--format", "json" });
    if (spec.config) |config| try list.appendSlice(allocator, &.{ "--config", config });
    if (spec.rules) |rules| try list.appendSlice(allocator, &.{ "--rules", rules });
    try list.append(allocator, spec.path);
    try list.appendSlice(allocator, spec.extra);
    return list.toOwnedSlice(allocator);
}

pub fn buildZlintFixArgv(allocator: std.mem.Allocator, spec: ZlintCommand, dangerous: bool) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &.{ spec.executable, "--format", "json", if (dangerous) "--fix-dangerously" else "--fix" });
    if (spec.config) |config| try list.appendSlice(allocator, &.{ "--config", config });
    if (spec.rules) |rules| try list.appendSlice(allocator, &.{ "--rules", rules });
    try list.append(allocator, spec.path);
    try list.appendSlice(allocator, spec.extra);
    return list.toOwnedSlice(allocator);
}

pub fn zigZlint(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runZlintDiagnostics(a, allocator, args, "zig_zlint", false);
}

pub fn zigZlintSarif(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runZlintDiagnostics(a, allocator, args, "zig_zlint_sarif", true);
}

fn runZlintDiagnostics(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, sarif: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    var resolved_config: ?[]const u8 = null;
    defer if (resolved_config) |path| allocator.free(path);
    if (argString(args, "config")) |path| resolved_config = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, tool_name, path, err);
    const path = argString(args, "path") orelse ".";
    const resolved_path = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, tool_name, path, err);
    defer allocator.free(resolved_path);
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, tool_name, "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    const argv = buildZlintArgv(allocator, .{
        .executable = a.config.zlint_path,
        .path = resolved_path,
        .config = resolved_config,
        .rules = argString(args, "rules"),
        .extra = extra,
    }) catch return error.OutOfMemory;
    defer allocator.free(argv);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    a.command_calls += 1;
    const result = command.run(scratch, a.io, a.workspace.root, argv, toolTimeout(a, args)) catch |err| {
        a.tool_errors += 1;
        return backendErrorResult(allocator, "zlint", "diagnostics", err, "confirm --zlint-path points to an executable ZLint binary or omit ZLint-backed tools");
    };
    if (!result.succeeded()) return structured(allocator, try backendCommandFailedValue(scratch, tool_name, "diagnostics", result.stdout, result.stderr));
    const findings = normalizeFindingsText(scratch, result.stdout, .zlint) catch return structured(allocator, try malformedBackendOutputValue(scratch, tool_name, result.stdout, result.stderr));
    if (sarif) return structured(allocator, try sarifResultValue(scratch, tool_name, findings.array));
    return structured(allocator, try lintFindingsResultValue(scratch, tool_name, "zlint", findings.array));
}

pub fn zigZlintRules(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const help_argv = [_][]const u8{ a.config.zlint_path, "--help" };
    a.command_calls += 1;
    const help = command.run(scratch, a.io, a.workspace.root, help_argv[0..], toolTimeout(a, args)) catch |err| {
        a.tool_errors += 1;
        return backendErrorResult(allocator, "zlint", "rules", err, "confirm --zlint-path points to an executable ZLint binary");
    };
    if (!help.succeeded()) return structured(allocator, try backendCommandFailedValue(scratch, "zig_zlint_rules", "help", help.stdout, help.stderr));
    if (!zlintHelpSupportsRules(help.stdout)) return structured(allocator, try zlintRulesUnavailableValue(scratch, help.stdout));
    const argv = [_][]const u8{ a.config.zlint_path, "--rules", "--format", "json" };
    a.command_calls += 1;
    const result = command.run(scratch, a.io, a.workspace.root, argv[0..], toolTimeout(a, args)) catch |err| {
        a.tool_errors += 1;
        return backendErrorResult(allocator, "zlint", "rules", err, "confirm --zlint-path points to an executable ZLint binary that supports --rules --format json");
    };
    if (!result.succeeded()) return structured(allocator, try backendCommandFailedValue(scratch, "zig_zlint_rules", "rules", result.stdout, result.stderr));
    const rules = normalizeRulesText(scratch, result.stdout) catch return structured(allocator, try malformedBackendOutputValue(scratch, "zig_zlint_rules", result.stdout, result.stderr));
    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zig_zlint_rules" });
    try analysis_contract.putMetadata(scratch, &obj, "zig_zlint_rules");
    try obj.put(scratch, "backend", .{ .string = "zlint" });
    try obj.put(scratch, "optional_backend", .{ .bool = true });
    try obj.put(scratch, "rules", rules);
    try obj.put(scratch, "rule_count", .{ .integer = @intCast(rules.array.items.len) });
    return structured(allocator, .{ .object = obj });
}

pub fn zigZlintFix(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var resolved_config: ?[]const u8 = null;
    defer if (resolved_config) |path| allocator.free(path);
    if (argString(args, "config")) |path| resolved_config = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_zlint_fix", path, err);
    const path = argString(args, "path") orelse ".";
    const resolved_path = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_zlint_fix", path, err);
    defer allocator.free(resolved_path);
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, "zig_zlint_fix", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    const dangerous = argBool(args, "dangerous", false);
    const argv = buildZlintFixArgv(allocator, .{
        .executable = a.config.zlint_path,
        .path = resolved_path,
        .config = resolved_config,
        .rules = argString(args, "rules"),
        .extra = extra,
    }, dangerous) catch return error.OutOfMemory;
    defer allocator.free(argv);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const apply = argBool(args, "apply", false);
    if (!apply) return structured(allocator, try zlintFixPreviewValue(scratch, argv, dangerous));
    a.command_calls += 1;
    const result = command.run(scratch, a.io, a.workspace.root, argv, toolTimeout(a, args)) catch |err| {
        a.tool_errors += 1;
        return backendErrorResult(allocator, "zlint", "fix", err, "confirm --zlint-path points to an executable ZLint binary that supports --fix");
    };
    if (!result.succeeded()) return structured(allocator, try backendCommandFailedValue(scratch, "zig_zlint_fix", "fix", result.stdout, result.stderr));
    const findings = normalizeFindingsText(scratch, result.stdout, .zlint) catch std.json.Value{ .array = std.json.Array.init(scratch) };
    return structured(allocator, try zlintFixAppliedValue(scratch, argv, dangerous, result.stdout, result.stderr, findings.array));
}

pub fn zlintHelpSupportsRules(help: []const u8) bool {
    return std.mem.indexOf(u8, help, "--rules") != null;
}

fn backendCommandFailedValue(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, stdout: []const u8, stderr: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try analysis_contract.putMetadata(allocator, &obj, tool_name);
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = "zlint" });
    try obj.put(allocator, "optional_backend", .{ .bool = true });
    try obj.put(allocator, "operation", try evidence.ownedString(allocator, operation));
    try obj.put(allocator, "error_kind", .{ .string = "command_failed" });
    try obj.put(allocator, "stdout", try evidence.ownedString(allocator, stdout));
    try obj.put(allocator, "stderr", try evidence.ownedString(allocator, stderr));
    try obj.put(allocator, "resolution", .{ .string = "Inspect ZLint stdout/stderr and confirm the selected path, config, and rules are supported by the configured binary." });
    return .{ .object = obj };
}

fn zlintRulesUnavailableValue(allocator: std.mem.Allocator, help: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_zlint_rules" });
    try analysis_contract.putMetadata(allocator, &obj, "zig_zlint_rules");
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "backend", .{ .string = "zlint" });
    try obj.put(allocator, "optional_backend", .{ .bool = true });
    try obj.put(allocator, "rules_available", .{ .bool = false });
    try obj.put(allocator, "rules", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "rule_count", .{ .integer = 0 });
    try obj.put(allocator, "capabilities", try zlintCapabilitiesValue(allocator, help));
    try obj.put(allocator, "resolution", .{ .string = "The configured ZLint binary does not expose a rule-catalog flag; diagnostics, SARIF conversion, AST refs, and apply-gated fixes can still be used when supported." });
    return .{ .object = obj };
}

fn zlintCapabilitiesValue(allocator: std.mem.Allocator, help: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "format_json", .{ .bool = std.mem.indexOf(u8, help, "--format") != null });
    try obj.put(allocator, "fix", .{ .bool = std.mem.indexOf(u8, help, "--fix") != null });
    try obj.put(allocator, "fix_dangerously", .{ .bool = std.mem.indexOf(u8, help, "--fix-dangerously") != null });
    try obj.put(allocator, "print_ast", .{ .bool = std.mem.indexOf(u8, help, "--print-ast") != null });
    try obj.put(allocator, "rules", .{ .bool = zlintHelpSupportsRules(help) });
    try obj.put(allocator, "help_preview", try evidence.ownedString(allocator, help[0..@min(help.len, 2048)]));
    return .{ .object = obj };
}

fn malformedBackendOutputValue(allocator: std.mem.Allocator, tool_name: []const u8, stdout: []const u8, stderr: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try analysis_contract.putMetadata(allocator, &obj, tool_name);
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = "zlint" });
    try obj.put(allocator, "optional_backend", .{ .bool = true });
    try obj.put(allocator, "error_kind", .{ .string = "backend_output_malformed" });
    try obj.put(allocator, "stdout_preview", try evidence.ownedString(allocator, stdout[0..@min(stdout.len, 4096)]));
    try obj.put(allocator, "stderr_preview", try evidence.ownedString(allocator, stderr[0..@min(stderr.len, 4096)]));
    try obj.put(allocator, "resolution", .{ .string = "Confirm the configured ZLint binary emits JSON with a findings, diagnostics, or rules array." });
    return .{ .object = obj };
}

fn lintFindingsResultValue(allocator: std.mem.Allocator, tool_name: []const u8, backend: []const u8, findings: std.json.Array) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try analysis_contract.putMetadata(allocator, &obj, tool_name);
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "backend", try evidence.ownedString(allocator, backend));
    try obj.put(allocator, "optional_backend", .{ .bool = true });
    try obj.put(allocator, "findings", .{ .array = findings });
    try obj.put(allocator, "summary", try evidence.summaryValue(allocator, findings));
    try obj.put(allocator, "evidence_sources", try evidence.sourceArrayValue(allocator, &.{.zlint}));
    return .{ .object = obj };
}

fn zlintFixPreviewValue(allocator: std.mem.Allocator, argv: []const []const u8, dangerous: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_zlint_fix" });
    try analysis_contract.putMetadata(allocator, &obj, "zig_zlint_fix");
    try obj.put(allocator, "backend", .{ .string = "zlint" });
    try obj.put(allocator, "optional_backend", .{ .bool = true });
    try obj.put(allocator, "apply", .{ .bool = false });
    try obj.put(allocator, "applied", .{ .bool = false });
    try obj.put(allocator, "requires_apply", .{ .bool = true });
    try obj.put(allocator, "dangerous", .{ .bool = dangerous });
    try obj.put(allocator, "argv", try evidence.stringArrayValue(allocator, argv));
    try obj.put(allocator, "resolution", .{ .string = "Review the ZLint fix command and rerun with apply=true to let ZLint mutate workspace source files." });
    return .{ .object = obj };
}

fn zlintFixAppliedValue(allocator: std.mem.Allocator, argv: []const []const u8, dangerous: bool, stdout: []const u8, stderr: []const u8, findings: std.json.Array) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_zlint_fix" });
    try analysis_contract.putMetadata(allocator, &obj, "zig_zlint_fix");
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "backend", .{ .string = "zlint" });
    try obj.put(allocator, "optional_backend", .{ .bool = true });
    try obj.put(allocator, "apply", .{ .bool = true });
    try obj.put(allocator, "applied", .{ .bool = true });
    try obj.put(allocator, "dangerous", .{ .bool = dangerous });
    try obj.put(allocator, "argv", try evidence.stringArrayValue(allocator, argv));
    try obj.put(allocator, "stdout_preview", try evidence.ownedString(allocator, stdout[0..@min(stdout.len, 4096)]));
    try obj.put(allocator, "stderr_preview", try evidence.ownedString(allocator, stderr[0..@min(stderr.len, 4096)]));
    try obj.put(allocator, "findings_after_fix", .{ .array = findings });
    try obj.put(allocator, "summary", try evidence.summaryValue(allocator, findings));
    return .{ .object = obj };
}

pub fn normalizeFindingsText(allocator: std.mem.Allocator, text: []const u8, source: FindingSource) !std.json.Value {
    var findings = std.json.Array.init(allocator);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return .{ .array = findings };
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    const raw = findingsArray(parsed.value);
    for (raw.items) |item| try findings.append(try normalizeFindingValue(allocator, item, source));
    return .{ .array = findings };
}

fn findingsArray(value: std.json.Value) std.json.Array {
    switch (value) {
        .array => |array| return array,
        .object => |obj| {
            if (obj.get("findings")) |v| if (v == .array) return v.array;
            if (obj.get("diagnostics")) |v| if (v == .array) return v.array;
            if (obj.get("results")) |v| if (v == .array) return v.array;
        },
        else => {},
    }
    return std.json.Array.init(std.heap.page_allocator);
}

fn normalizeFindingValue(allocator: std.mem.Allocator, value: std.json.Value, source: FindingSource) !std.json.Value {
    const obj = switch (value) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const location = switch (obj.get("location") orelse .null) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const file = evidence.stringField(obj, "path") orelse evidence.stringField(obj, "file") orelse evidence.stringField(location, "file") orelse evidence.stringField(location, "path") orelse "unknown";
    const line: usize = @intCast(@max(evidence.integerField(obj, "line") orelse evidence.integerField(location, "line") orelse 1, 1));
    const column: usize = @intCast(@max(evidence.integerField(obj, "column") orelse evidence.integerField(location, "column") orelse 1, 1));
    const rule = evidence.stringField(obj, "rule") orelse evidence.stringField(obj, "rule_id") orelse evidence.stringField(obj, "code") orelse "unknown";
    const severity = evidence.stringField(obj, "severity") orelse evidence.stringField(obj, "level") orelse "info";
    const message = evidence.stringField(obj, "message") orelse evidence.stringField(obj, "title") orelse evidence.stringField(obj, "detail") orelse "";
    const finding = try evidence.findingValue(allocator, if (source == .zlint) .zlint else .zwanzig, rule, severity, file, line, column, message, .high);
    var out = finding.object;
    try out.put(allocator, "comparison_key", try comparisonKeyValue(allocator, rule, file, line));
    try out.put(allocator, "fingerprint", try evidence.fingerprintValue(allocator, .{ .object = out }));
    return .{ .object = out };
}

fn comparisonKeyValue(allocator: std.mem.Allocator, rule: []const u8, file: []const u8, line: usize) !std.json.Value {
    return .{ .string = try std.fmt.allocPrint(allocator, "{s}:{s}:{d}", .{ rule, file, line }) };
}

pub fn normalizeRulesText(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var rules = std.json.Array.init(allocator);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return .{ .array = rules };
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    const raw = switch (parsed.value) {
        .array => |array| array,
        .object => |obj| switch (obj.get("rules") orelse .null) {
            .array => |array| array,
            else => std.json.Array.init(allocator),
        },
        else => std.json.Array.init(allocator),
    };
    for (raw.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        var rule = std.json.ObjectMap.empty;
        try rule.put(allocator, "id", if (evidence.stringField(obj, "id") orelse evidence.stringField(obj, "rule")) |id| try evidence.ownedString(allocator, id) else .null);
        try rule.put(allocator, "severity", if (evidence.stringField(obj, "severity")) |severity| try evidence.ownedString(allocator, severity) else .{ .string = "info" });
        try rule.put(allocator, "category", if (evidence.stringField(obj, "category")) |category| try evidence.ownedString(allocator, category) else .null);
        try rule.put(allocator, "description", if (evidence.stringField(obj, "description") orelse evidence.stringField(obj, "message")) |description| try evidence.ownedString(allocator, description) else .null);
        try rule.put(allocator, "source", .{ .string = "zlint" });
        try rules.append(.{ .object = rule });
    }
    return .{ .array = rules };
}

fn sarifResultValue(allocator: std.mem.Allocator, tool_name: []const u8, findings: std.json.Array) !std.json.Value {
    var results = std.json.Array.init(allocator);
    for (findings.items) |finding| try results.append(try sarifFindingValue(allocator, finding));
    var driver = std.json.ObjectMap.empty;
    try driver.put(allocator, "name", .{ .string = "ZLint" });
    try driver.put(allocator, "informationUri", .{ .string = "https://github.com/" });
    var tool = std.json.ObjectMap.empty;
    try tool.put(allocator, "driver", .{ .object = driver });
    var run = std.json.ObjectMap.empty;
    try run.put(allocator, "tool", .{ .object = tool });
    try run.put(allocator, "results", .{ .array = results });
    var runs = std.json.Array.init(allocator);
    try runs.append(.{ .object = run });
    var sarif = std.json.ObjectMap.empty;
    try sarif.put(allocator, "version", .{ .string = "2.1.0" });
    try sarif.put(allocator, "$schema", .{ .string = "https://json.schemastore.org/sarif-2.1.0.json" });
    try sarif.put(allocator, "runs", .{ .array = runs });
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try analysis_contract.putMetadata(allocator, &obj, tool_name);
    try obj.put(allocator, "backend", .{ .string = "zlint" });
    try obj.put(allocator, "sarif", .{ .object = sarif });
    try obj.put(allocator, "summary", try evidence.summaryValue(allocator, findings));
    return .{ .object = obj };
}

fn sarifFindingValue(allocator: std.mem.Allocator, finding: std.json.Value) !std.json.Value {
    const obj = finding.object;
    const loc = if (obj.get("location")) |value| switch (value) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    } else std.json.ObjectMap.empty;
    var region = std.json.ObjectMap.empty;
    try region.put(allocator, "startLine", .{ .integer = evidence.integerField(loc, "line") orelse 1 });
    try region.put(allocator, "startColumn", .{ .integer = evidence.integerField(loc, "column") orelse 1 });
    var artifact = std.json.ObjectMap.empty;
    try artifact.put(allocator, "uri", if (evidence.stringField(loc, "file")) |file| try evidence.ownedString(allocator, file) else .{ .string = "unknown" });
    var physical = std.json.ObjectMap.empty;
    try physical.put(allocator, "artifactLocation", .{ .object = artifact });
    try physical.put(allocator, "region", .{ .object = region });
    var location = std.json.ObjectMap.empty;
    try location.put(allocator, "physicalLocation", .{ .object = physical });
    var locations = std.json.Array.init(allocator);
    try locations.append(.{ .object = location });
    var message = std.json.ObjectMap.empty;
    try message.put(allocator, "text", if (evidence.stringField(obj, "message")) |text| try evidence.ownedString(allocator, text) else .{ .string = "" });
    var out = std.json.ObjectMap.empty;
    try out.put(allocator, "ruleId", if (evidence.stringField(obj, "rule")) |rule| try evidence.ownedString(allocator, rule) else .{ .string = "unknown" });
    try out.put(allocator, "level", try evidence.ownedString(allocator, sarifLevel(evidence.stringField(obj, "severity") orelse "info")));
    try out.put(allocator, "message", .{ .object = message });
    try out.put(allocator, "locations", .{ .array = locations });
    return .{ .object = out };
}

fn sarifLevel(severity: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(severity, "error")) return "error";
    if (std.ascii.eqlIgnoreCase(severity, "warning") or std.ascii.eqlIgnoreCase(severity, "warn")) return "warning";
    return "note";
}

pub fn zigLintCompare(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const zlint = normalizeFindingsText(scratch, argString(args, "zlint_findings") orelse "[]", .zlint) catch return missingArgumentResult(allocator, "zig_lint_compare", "zlint_findings", "valid JSON findings");
    const zwanzig = normalizeFindingsText(scratch, argString(args, "zwanzig_findings") orelse "[]", .zwanzig) catch return missingArgumentResult(allocator, "zig_lint_compare", "zwanzig_findings", "valid JSON findings");
    return structured(allocator, try lintCompareValue(scratch, zlint.array, zwanzig.array));
}

pub fn lintCompareValue(allocator: std.mem.Allocator, zlint: std.json.Array, zwanzig: std.json.Array) !std.json.Value {
    var consensus = std.json.Array.init(allocator);
    var disagreements = std.json.Array.init(allocator);
    var zlint_only = std.json.Array.init(allocator);
    var zwanzig_only = std.json.Array.init(allocator);
    for (zlint.items) |left| {
        if (findByComparisonKey(zwanzig, comparisonKey(left))) |right| {
            if (std.mem.eql(u8, severityOf(left), severityOf(right))) {
                var item = std.json.ObjectMap.empty;
                try item.put(allocator, "source", .{ .string = "consensus" });
                try item.put(allocator, "confidence", .{ .string = "high" });
                try item.put(allocator, "zlint", left);
                try item.put(allocator, "zwanzig", right);
                try consensus.append(.{ .object = item });
            } else {
                try disagreements.append(try pairValue(allocator, left, right));
            }
        } else try zlint_only.append(left);
    }
    for (zwanzig.items) |right| if (findByComparisonKey(zlint, comparisonKey(right)) == null) try zwanzig_only.append(right);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_lint_compare" });
    try analysis_contract.putMetadata(allocator, &obj, "zig_lint_compare");
    try obj.put(allocator, "consensus", .{ .array = consensus });
    try obj.put(allocator, "disagreements", .{ .array = disagreements });
    try obj.put(allocator, "zlint_only", .{ .array = zlint_only });
    try obj.put(allocator, "zwanzig_only", .{ .array = zwanzig_only });
    try obj.put(allocator, "summary", try compareSummaryValue(allocator, consensus, disagreements, zlint_only, zwanzig_only));
    return .{ .object = obj };
}

fn pairValue(allocator: std.mem.Allocator, left: std.json.Value, right: std.json.Value) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "source", .{ .string = "disagreement" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "zlint", left);
    try obj.put(allocator, "zwanzig", right);
    return .{ .object = obj };
}

fn compareSummaryValue(allocator: std.mem.Allocator, consensus: std.json.Array, disagreements: std.json.Array, zlint_only: std.json.Array, zwanzig_only: std.json.Array) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "consensus_count", .{ .integer = @intCast(consensus.items.len) });
    try obj.put(allocator, "disagreement_count", .{ .integer = @intCast(disagreements.items.len) });
    try obj.put(allocator, "zlint_only_count", .{ .integer = @intCast(zlint_only.items.len) });
    try obj.put(allocator, "zwanzig_only_count", .{ .integer = @intCast(zwanzig_only.items.len) });
    return .{ .object = obj };
}

fn comparisonKey(value: std.json.Value) []const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return "",
    };
    return evidence.stringField(obj, "comparison_key") orelse "";
}

fn severityOf(value: std.json.Value) []const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return "",
    };
    return evidence.stringField(obj, "severity") orelse "";
}

fn findByComparisonKey(array: std.json.Array, key: []const u8) ?std.json.Value {
    for (array.items) |item| if (std.mem.eql(u8, comparisonKey(item), key)) return item;
    return null;
}

pub fn zigLintProfile(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return structured(allocator, try lintProfileValue(arena.allocator(), argString(args, "profile") orelse "standard"));
}

fn lintProfileValue(allocator: std.mem.Allocator, selected: []const u8) !std.json.Value {
    var profiles = std.json.Array.init(allocator);
    try profiles.append(try profileValue(allocator, "advisory", true, 9999, false));
    try profiles.append(try profileValue(allocator, "standard", false, 25, true));
    try profiles.append(try profileValue(allocator, "strict", false, 0, true));
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_lint_profile" });
    try analysis_contract.putMetadata(allocator, &obj, "zig_lint_profile");
    try obj.put(allocator, "selected", try evidence.ownedString(allocator, selected));
    try obj.put(allocator, "profiles", .{ .array = profiles });
    return .{ .object = obj };
}

fn profileValue(allocator: std.mem.Allocator, name: []const u8, allow_warnings: bool, max_warnings: i64, require_backend: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try evidence.ownedString(allocator, name));
    try obj.put(allocator, "allow_warnings", .{ .bool = allow_warnings });
    try obj.put(allocator, "max_warnings", .{ .integer = max_warnings });
    try obj.put(allocator, "fail_on_error", .{ .bool = true });
    try obj.put(allocator, "require_configured_linter", .{ .bool = require_backend });
    return .{ .object = obj };
}

fn lintProfileDefaults(name: []const u8) LintProfile {
    if (std.mem.eql(u8, name, "advisory")) return .{ .allow_warnings = true, .max_warnings = 9999, .require_backend = false };
    if (std.mem.eql(u8, name, "strict")) return .{ .allow_warnings = false, .max_warnings = 0, .require_backend = true };
    return .{ .allow_warnings = false, .max_warnings = 25, .require_backend = true };
}

fn argHas(args: ?std.json.Value, name: []const u8) bool {
    const value = args orelse return false;
    return switch (value) {
        .object => |obj| obj.get(name) != null,
        else => false,
    };
}

pub fn zigLintGate(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = argString(args, "findings") orelse return missingArgumentResult(allocator, "zig_lint_gate", "findings", "valid JSON findings");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const findings = normalizeFindingsText(scratch, text, .zlint) catch return missingArgumentResult(allocator, "zig_lint_gate", "findings", "valid JSON findings");
    const profile = argString(args, "profile") orelse "standard";
    const defaults = lintProfileDefaults(profile);
    const allow_warnings = if (argHas(args, "allow_warnings")) argBool(args, "allow_warnings", defaults.allow_warnings) else defaults.allow_warnings;
    const max_warnings = if (argHas(args, "max_warnings")) argInt(args, "max_warnings", defaults.max_warnings) else defaults.max_warnings;
    return structured(allocator, try lintGateValue(scratch, findings.array, profile, allow_warnings, max_warnings));
}

fn lintGateValue(allocator: std.mem.Allocator, findings: std.json.Array, profile: []const u8, allow_warnings: bool, max_warnings: i64) !std.json.Value {
    var blocking = std.json.Array.init(allocator);
    var warning_count: i64 = 0;
    for (findings.items) |finding| {
        const severity = severityOf(finding);
        if (std.ascii.eqlIgnoreCase(severity, "error")) try blocking.append(finding);
        if (std.ascii.eqlIgnoreCase(severity, "warning") or std.ascii.eqlIgnoreCase(severity, "warn")) warning_count += 1;
    }
    if (!allow_warnings and warning_count > max_warnings) for (findings.items) |finding| {
        const severity = severityOf(finding);
        if (std.ascii.eqlIgnoreCase(severity, "warning") or std.ascii.eqlIgnoreCase(severity, "warn")) try blocking.append(finding);
    };
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_lint_gate" });
    try analysis_contract.putMetadata(allocator, &obj, "zig_lint_gate");
    try obj.put(allocator, "profile", try evidence.ownedString(allocator, profile));
    try obj.put(allocator, "passed", .{ .bool = blocking.items.len == 0 });
    try obj.put(allocator, "blocking_findings", .{ .array = blocking });
    try obj.put(allocator, "summary", try evidence.summaryValue(allocator, findings));
    return .{ .object = obj };
}

pub fn zigLintFixPlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = argString(args, "findings") orelse return missingArgumentResult(allocator, "zig_lint_fix_plan", "findings", "valid JSON findings");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const findings = normalizeFindingsText(arena.allocator(), text, .zlint) catch return missingArgumentResult(allocator, "zig_lint_fix_plan", "findings", "valid JSON findings");
    return structured(allocator, try fixPlanValue(arena.allocator(), findings.array));
}

fn fixPlanValue(allocator: std.mem.Allocator, findings: std.json.Array) !std.json.Value {
    var safe = std.json.Array.init(allocator);
    var risky = std.json.Array.init(allocator);
    var manual = std.json.Array.init(allocator);
    for (findings.items) |finding| {
        const message = evidence.stringField(finding.object, "message") orelse "";
        if (std.mem.indexOf(u8, message, "format") != null or std.mem.indexOf(u8, message, "unused") != null) try safe.append(finding) else if (std.ascii.eqlIgnoreCase(severityOf(finding), "error")) try risky.append(finding) else try manual.append(finding);
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_lint_fix_plan" });
    try analysis_contract.putMetadata(allocator, &obj, "zig_lint_fix_plan");
    try obj.put(allocator, "preview_only", .{ .bool = true });
    try obj.put(allocator, "apply_supported", .{ .bool = true });
    try obj.put(allocator, "apply_tool", .{ .string = "zig_zlint_fix" });
    try obj.put(allocator, "safe", .{ .array = safe });
    try obj.put(allocator, "risky", .{ .array = risky });
    try obj.put(allocator, "manual", .{ .array = manual });
    return .{ .object = obj };
}

pub fn zigLintBaseline(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = argString(args, "findings") orelse return missingArgumentResult(allocator, "zig_lint_baseline", "findings", "valid JSON findings");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const findings = normalizeFindingsText(scratch, text, .zlint) catch return missingArgumentResult(allocator, "zig_lint_baseline", "findings", "valid JSON findings");
    const baseline = normalizeFindingsText(scratch, argString(args, "baseline") orelse "[]", .zlint) catch std.json.Value{ .array = std.json.Array.init(scratch) };
    const value = try baselineValue(scratch, findings.array, baseline.array);
    if (argBool(args, "apply", false)) {
        const output = argString(args, "output") orelse ".zigar-cache/lint-baseline.json";
        var bytes = std.ArrayList(u8).empty;
        try json_result.serializeValue(scratch, &bytes, value);
        a.workspace.writeFile(a.io, output, bytes.items) catch |err| return workspacePathErrorResult(a, allocator, "zig_lint_baseline", output, err);
    }
    return structured(allocator, value);
}

fn baselineValue(allocator: std.mem.Allocator, findings: std.json.Array, baseline: std.json.Array) !std.json.Value {
    var current = std.json.Array.init(allocator);
    var accepted = std.json.Array.init(allocator);
    var resolved = std.json.Array.init(allocator);
    for (findings.items) |finding| if (findByComparisonKey(baseline, comparisonKey(finding)) == null) try current.append(finding) else try accepted.append(finding);
    for (baseline.items) |old| if (findByComparisonKey(findings, comparisonKey(old)) == null) try resolved.append(old);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_lint_baseline" });
    try analysis_contract.putMetadata(allocator, &obj, "zig_lint_baseline");
    try obj.put(allocator, "new_findings", .{ .array = current });
    try obj.put(allocator, "accepted_findings", .{ .array = accepted });
    try obj.put(allocator, "resolved_findings", .{ .array = resolved });
    try obj.put(allocator, "baseline_count", .{ .integer = @intCast(findings.items.len) });
    return .{ .object = obj };
}

pub fn zigLintSuppressions(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = argString(args, "findings") orelse return missingArgumentResult(allocator, "zig_lint_suppressions", "findings", "valid JSON findings");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const findings = normalizeFindingsText(scratch, text, .zlint) catch return missingArgumentResult(allocator, "zig_lint_suppressions", "findings", "valid JSON findings");
    return structured(allocator, try suppressionsValue(scratch, findings.array, argString(args, "suppressions") orelse "[]"));
}

fn suppressionsValue(allocator: std.mem.Allocator, findings: std.json.Array, suppressions_text: []const u8) !std.json.Value {
    const suppressions = normalizeFindingsText(allocator, suppressions_text, .zlint) catch std.json.Value{ .array = std.json.Array.init(allocator) };
    var suppressed = std.json.Array.init(allocator);
    var active = std.json.Array.init(allocator);
    var stale = std.json.Array.init(allocator);
    for (findings.items) |finding| if (findByComparisonKey(suppressions.array, comparisonKey(finding)) != null) try suppressed.append(finding) else try active.append(finding);
    for (suppressions.array.items) |suppression| if (findByComparisonKey(findings, comparisonKey(suppression)) == null) try stale.append(suppression);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_lint_suppressions" });
    try analysis_contract.putMetadata(allocator, &obj, "zig_lint_suppressions");
    try obj.put(allocator, "suppressed", .{ .array = suppressed });
    try obj.put(allocator, "active", .{ .array = active });
    try obj.put(allocator, "stale_suppressions", .{ .array = stale });
    return .{ .object = obj };
}

pub fn zigLintTrend(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const before_text = argString(args, "before") orelse return missingArgumentResult(allocator, "zig_lint_trend", "before", "valid JSON findings");
    const after_text = argString(args, "after") orelse return missingArgumentResult(allocator, "zig_lint_trend", "after", "valid JSON findings");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const before = normalizeFindingsText(arena.allocator(), before_text, .zlint) catch return missingArgumentResult(allocator, "zig_lint_trend", "before", "valid JSON findings");
    const after = normalizeFindingsText(arena.allocator(), after_text, .zlint) catch return missingArgumentResult(allocator, "zig_lint_trend", "after", "valid JSON findings");
    return structured(allocator, try trendValue(arena.allocator(), before.array, after.array));
}

fn trendValue(allocator: std.mem.Allocator, before: std.json.Array, after: std.json.Array) !std.json.Value {
    var new_findings = std.json.Array.init(allocator);
    var resolved = std.json.Array.init(allocator);
    var persistent = std.json.Array.init(allocator);
    for (after.items) |finding| if (findByComparisonKey(before, comparisonKey(finding)) == null) try new_findings.append(finding) else try persistent.append(finding);
    for (before.items) |finding| if (findByComparisonKey(after, comparisonKey(finding)) == null) try resolved.append(finding);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_lint_trend" });
    try analysis_contract.putMetadata(allocator, &obj, "zig_lint_trend");
    try obj.put(allocator, "new_findings", .{ .array = new_findings });
    try obj.put(allocator, "resolved_findings", .{ .array = resolved });
    try obj.put(allocator, "persistent_findings", .{ .array = persistent });
    try obj.put(allocator, "before_count", .{ .integer = @intCast(before.items.len) });
    try obj.put(allocator, "after_count", .{ .integer = @intCast(after.items.len) });
    return .{ .object = obj };
}

test "normalizes findings and compares consensus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const text = "{\"findings\":[{\"rule\":\"lint.rule\",\"severity\":\"warning\",\"path\":\"src/main.zig\",\"line\":2,\"column\":3,\"message\":\"warn\"}]}";
    const zlint = try normalizeFindingsText(allocator, text, .zlint);
    const zwanzig = try normalizeFindingsText(allocator, text, .zwanzig);
    try std.testing.expectEqual(@as(usize, 1), zlint.array.items.len);
    const compared = try lintCompareValue(allocator, zlint.array, zwanzig.array);
    try std.testing.expectEqual(@as(i64, 1), compared.object.get("summary").?.object.get("consensus_count").?.integer);
}

test "lint gate blocks errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try normalizeFindingsText(arena.allocator(), "[{\"rule\":\"r\",\"severity\":\"error\",\"path\":\"a.zig\",\"line\":1,\"message\":\"bad\"}]", .zlint);
    const gate = try lintGateValue(arena.allocator(), findings.array, "standard", false, 0);
    try std.testing.expect(!gate.object.get("passed").?.bool);
}

test "strict lint profile blocks warnings by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const findings = try normalizeFindingsText(arena.allocator(), "[{\"rule\":\"r\",\"severity\":\"warning\",\"path\":\"a.zig\",\"line\":1,\"message\":\"warn\"}]", .zlint);
    const defaults = lintProfileDefaults("strict");
    const gate = try lintGateValue(arena.allocator(), findings.array, "strict", defaults.allow_warnings, defaults.max_warnings);
    try std.testing.expect(!gate.object.get("passed").?.bool);
}

test "zlint rules fallback reflects help capabilities" {
    try std.testing.expect(!zlintHelpSupportsRules("Usage: zlint [options]\n--fix\n--print-ast <file>\n"));
    try std.testing.expect(zlintHelpSupportsRules("fake\n--rules --format json\n"));
}
