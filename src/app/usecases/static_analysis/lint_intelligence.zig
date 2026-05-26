//! Lint intelligence adapter that runs linters and reconciles normalized findings.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const backend_contracts = @import("../../../domain/zig/backend_contracts.zig");
const compiler_output = @import("../../../domain/zig/compiler_output.zig");

/// Command output limit applied when collecting workflow evidence.
pub const command_output_limit: usize = 1024 * 1024;
/// Command output limit mode applied when collecting workflow evidence.
pub const command_output_limit_mode = "truncate_on_limit";

/// Error set returned by lint workflow failures.
pub const LintError = ports.PortError || error{
    MissingCommandRunner,
};

/// Defines the allowed finding source variants accepted by this workflow.
pub const FindingSource = enum { zlint, zwanzig };

/// Carries zlint command data across use case and port boundaries.
pub const ZlintCommand = struct {
    executable: []const u8,
    path: []const u8,
    config: ?[]const u8 = null,
    rules: ?[]const u8 = null,
    extra: []const []const u8 = &.{},
};

/// Carries zlint diagnostics request data across use case and port boundaries.
pub const ZlintDiagnosticsRequest = struct {
    tool_name: []const u8,
    path: []const u8 = ".",
    config: ?[]const u8 = null,
    rules: ?[]const u8 = null,
    extra: []const []const u8 = &.{},
    timeout_ms: ?u64 = null,
    sarif: bool = false,
};

/// Carries zlint rules request data across use case and port boundaries.
pub const ZlintRulesRequest = struct {
    timeout_ms: ?u64 = null,
};

/// Carries zlint fix request data across use case and port boundaries.
pub const ZlintFixRequest = struct {
    path: []const u8 = ".",
    config: ?[]const u8 = null,
    rules: ?[]const u8 = null,
    extra: []const []const u8 = &.{},
    dangerous: bool = false,
    apply: bool = false,
    timeout_ms: ?u64 = null,
};

/// Carries zwanzig lint command data across use case and port boundaries.
pub const ZwanzigLintCommand = struct {
    executable: []const u8,
    format: backend_contracts.ZwanzigLintFormat,
    path: []const u8,
    config: ?[]const u8 = null,
    rules_do: ?[]const u8 = null,
    rules_skip: ?[]const u8 = null,
    extra: []const []const u8 = &.{},
};

/// Carries zwanzig graph command data across use case and port boundaries.
pub const ZwanzigGraphCommand = struct {
    executable: []const u8,
    mode: backend_contracts.ZwanzigGraphMode,
    source_path: []const u8,
    output_dir: []const u8,
    extra: []const []const u8 = &.{},
};

/// Carries zwanzig lint request data across use case and port boundaries.
pub const ZwanzigLintRequest = struct {
    tool_name: []const u8,
    format: backend_contracts.ZwanzigLintFormat,
    path: []const u8 = ".",
    config: ?[]const u8 = null,
    rules_do: ?[]const u8 = null,
    rules_skip: ?[]const u8 = null,
    extra: []const []const u8 = &.{},
    timeout_ms: ?u64 = null,
};

/// Carries zwanzig graph request data across use case and port boundaries.
pub const ZwanzigGraphRequest = struct {
    mode: backend_contracts.ZwanzigGraphMode,
    path: []const u8,
    output: []const u8,
    extra: []const []const u8 = &.{},
    timeout_ms: ?u64 = null,
};

/// Represents graph outcome alternatives carried across the workflow boundary.
pub const GraphOutcome = union(enum) {
    value: std.json.Value,
    error_value: std.json.Value,
};

/// Carries lint profile data across use case and port boundaries.
pub const LintProfile = struct {
    allow_warnings: bool,
    max_warnings: i64,
    require_backend: bool,
};

/// Constructs zlint argv data from caller-owned inputs, propagating allocation failures.
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

/// Constructs zlint fix argv data from caller-owned inputs, propagating allocation failures.
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

/// Constructs zwanzig lint argv data from caller-owned inputs, propagating allocation failures.
pub fn buildZwanzigLintArgv(allocator: std.mem.Allocator, spec: ZwanzigLintCommand) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &.{ spec.executable, "--format", spec.format.name() });
    if (spec.config) |config| try list.appendSlice(allocator, &.{ "--config", config });
    if (spec.rules_do) |rules| try list.appendSlice(allocator, &.{ "--do", rules });
    if (spec.rules_skip) |rules| try list.appendSlice(allocator, &.{ "--skip", rules });
    try list.append(allocator, spec.path);
    try list.appendSlice(allocator, spec.extra);
    return list.toOwnedSlice(allocator);
}

/// Constructs zwanzig graph argv data from caller-owned inputs, propagating allocation failures.
pub fn buildZwanzigGraphArgv(allocator: std.mem.Allocator, spec: ZwanzigGraphCommand) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, &.{ spec.executable, spec.mode.flag(), spec.output_dir, spec.source_path });
    try list.appendSlice(allocator, spec.extra);
    return list.toOwnedSlice(allocator);
}

/// Invokes run zlint diagnostics with caller-owned inputs; command and allocation failures propagate.
pub fn runZlintDiagnostics(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: ZlintDiagnosticsRequest) LintError!std.json.Value {
    const command_runner = try requireCommandRunner(context);
    const resolved_config = if (request.config) |path| try context.workspace_store.resolve(allocator, .{ .path = path, .provenance = "static_analysis.zlint_config" }) else null;
    defer if (resolved_config) |resolved| resolved.deinit(allocator);
    const resolved_path = try context.workspace_store.resolve(allocator, .{ .path = request.path, .provenance = "static_analysis.zlint_path" });
    defer resolved_path.deinit(allocator);

    const argv = try buildZlintArgv(allocator, .{
        .executable = context.tool_paths.zlint,
        .path = resolved_path.path,
        .config = if (resolved_config) |resolved| resolved.path else null,
        .rules = request.rules,
        .extra = request.extra,
    });
    defer allocator.free(argv);

    const result = command_runner.run(allocator, .{
        .argv = argv,
        .cwd = context.workspace.root,
        .timeout_ms = request.timeout_ms,
        .provenance = "static_analysis.zlint",
    }) catch |err| return backendErrorValue(allocator, "zlint", "diagnostics", err, "confirm --zlint-path points to an executable ZLint binary or omit ZLint-backed tools");
    defer result.deinit(allocator);
    if (result.effectiveTerm().failed() or result.timed_out) return backendCommandFailedValue(allocator, request.tool_name, "diagnostics", result.stdout, result.stderr);
    const findings = normalizeFindingsText(allocator, result.stdout, .zlint) catch return malformedBackendOutputValue(allocator, request.tool_name, result.stdout, result.stderr);
    if (request.sarif) return sarifResultValue(allocator, request.tool_name, findings.array);
    return lintFindingsResultValue(allocator, request.tool_name, "zlint", findings.array);
}

/// Invokes run zlint rules with caller-owned inputs; command and allocation failures propagate.
pub fn runZlintRules(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: ZlintRulesRequest) LintError!std.json.Value {
    const command_runner = try requireCommandRunner(context);
    const help_argv = [_][]const u8{ context.tool_paths.zlint, "--help" };
    const help = command_runner.run(allocator, .{
        .argv = help_argv[0..],
        .cwd = context.workspace.root,
        .timeout_ms = request.timeout_ms,
        .provenance = "static_analysis.zlint_rules_help",
    }) catch |err| return backendErrorValue(allocator, "zlint", "rules", err, "confirm --zlint-path points to an executable ZLint binary");
    defer help.deinit(allocator);
    if (help.effectiveTerm().failed() or help.timed_out) return backendCommandFailedValue(allocator, "zig_zlint_rules", "help", help.stdout, help.stderr);
    if (!zlintHelpSupportsRules(help.stdout)) return zlintRulesUnavailableValue(allocator, help.stdout);

    const argv = [_][]const u8{ context.tool_paths.zlint, "--rules", "--format", "json" };
    const result = command_runner.run(allocator, .{
        .argv = argv[0..],
        .cwd = context.workspace.root,
        .timeout_ms = request.timeout_ms,
        .provenance = "static_analysis.zlint_rules",
    }) catch |err| return backendErrorValue(allocator, "zlint", "rules", err, "confirm --zlint-path points to an executable ZLint binary that supports --rules --format json");
    defer result.deinit(allocator);
    if (result.effectiveTerm().failed() or result.timed_out) return backendCommandFailedValue(allocator, "zig_zlint_rules", "rules", result.stdout, result.stderr);
    const rules = normalizeRulesText(allocator, result.stdout) catch return malformedBackendOutputValue(allocator, "zig_zlint_rules", result.stdout, result.stderr);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_zlint_rules" });
    try obj.put(allocator, "backend", .{ .string = "zlint" });
    try obj.put(allocator, "optional_backend", .{ .bool = true });
    try obj.put(allocator, "rules", rules);
    try obj.put(allocator, "rule_count", .{ .integer = @intCast(rules.array.items.len) });
    return .{ .object = obj };
}

/// Invokes run zlint fix with caller-owned inputs; command and allocation failures propagate.
pub fn runZlintFix(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: ZlintFixRequest) LintError!std.json.Value {
    const resolved_config = if (request.config) |path| try context.workspace_store.resolve(allocator, .{ .path = path, .provenance = "static_analysis.zlint_fix_config" }) else null;
    defer if (resolved_config) |resolved| resolved.deinit(allocator);
    const resolved_path = try context.workspace_store.resolve(allocator, .{ .path = request.path, .provenance = "static_analysis.zlint_fix_path" });
    defer resolved_path.deinit(allocator);
    const argv = try buildZlintFixArgv(allocator, .{
        .executable = context.tool_paths.zlint,
        .path = resolved_path.path,
        .config = if (resolved_config) |resolved| resolved.path else null,
        .rules = request.rules,
        .extra = request.extra,
    }, request.dangerous);
    defer allocator.free(argv);
    if (!request.apply) return zlintFixPreviewValue(allocator, argv, request.dangerous);

    const command_runner = try requireCommandRunner(context);
    const result = command_runner.run(allocator, .{
        .argv = argv,
        .cwd = context.workspace.root,
        .timeout_ms = request.timeout_ms,
        .provenance = "static_analysis.zlint_fix",
    }) catch |err| return backendErrorValue(allocator, "zlint", "fix", err, "confirm --zlint-path points to an executable ZLint binary that supports --fix");
    defer result.deinit(allocator);
    if (result.effectiveTerm().failed() or result.timed_out) return backendCommandFailedValue(allocator, "zig_zlint_fix", "fix", result.stdout, result.stderr);
    const findings = normalizeFindingsText(allocator, result.stdout, .zlint) catch std.json.Value{ .array = std.json.Array.init(allocator) };
    return zlintFixAppliedValue(allocator, argv, request.dangerous, result.stdout, result.stderr, findings.array);
}

/// Invokes run zwanzig lint with caller-owned inputs; command and allocation failures propagate.
pub fn runZwanzigLint(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: ZwanzigLintRequest) LintError!std.json.Value {
    const command_runner = try requireCommandRunner(context);
    const resolved_config = if (request.config) |path| try context.workspace_store.resolve(allocator, .{ .path = path, .provenance = "static_analysis.zwanzig_config" }) else null;
    defer if (resolved_config) |resolved| resolved.deinit(allocator);
    const resolved_path = try context.workspace_store.resolve(allocator, .{ .path = request.path, .provenance = "static_analysis.zwanzig_path" });
    defer resolved_path.deinit(allocator);
    const argv = try buildZwanzigLintArgv(allocator, .{
        .executable = context.tool_paths.zwanzig,
        .format = request.format,
        .path = resolved_path.path,
        .config = if (resolved_config) |resolved| resolved.path else null,
        .rules_do = request.rules_do,
        .rules_skip = request.rules_skip,
        .extra = request.extra,
    });
    defer allocator.free(argv);
    return runZwanzigCommand(allocator, context, command_runner, argv, "zwanzig lint", request.tool_name, request.timeout_ms);
}

/// Invokes run zwanzig rules with caller-owned inputs; command and allocation failures propagate.
pub fn runZwanzigRules(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, timeout_ms: ?u64) LintError!std.json.Value {
    const command_runner = try requireCommandRunner(context);
    return runZwanzigCommand(allocator, context, command_runner, &.{ context.tool_paths.zwanzig, "--help" }, "zwanzig rules/help", "zig_lint_rules", timeout_ms);
}

/// Invokes run zwanzig command with caller-owned inputs; command and allocation failures propagate.
fn runZwanzigCommand(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    command_runner: ports.CommandRunner,
    argv: []const []const u8,
    title: []const u8,
    tool_name: []const u8,
    requested_timeout_ms: ?u64,
) LintError!std.json.Value {
    const timeout_ms = commandTimeout(context, requested_timeout_ms);
    const result = command_runner.run(allocator, .{
        .argv = argv,
        .cwd = context.workspace.root,
        .timeout_ms = timeout_ms,
        .provenance = "static_analysis.zwanzig",
    }) catch |err| return zwanzigResultWithMetadata(allocator, try commandErrorValue(allocator, title, argv, context.workspace.root, timeout_ms, err), tool_name);
    defer result.deinit(allocator);
    return zwanzigResultWithMetadata(allocator, try commandResultValue(allocator, title, argv, context.workspace.root, timeout_ms, result), tool_name);
}

/// Implements zwanzig result with metadata workflow logic using caller-owned inputs.
fn zwanzigResultWithMetadata(allocator: std.mem.Allocator, value: std.json.Value, tool_name: []const u8) !std.json.Value {
    var obj = switch (value) {
        .object => |o| o,
        else => return value,
    };
    try obj.put(allocator, "tool", .{ .string = tool_name });
    try obj.put(allocator, "backend", .{ .string = "zwanzig" });
    try obj.put(allocator, "optional_backend", .{ .bool = true });
    return .{ .object = obj };
}

/// Invokes run zwanzig graph with caller-owned inputs; command and allocation failures propagate.
pub fn runZwanzigGraph(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: ZwanzigGraphRequest) LintError!GraphOutcome {
    const command_runner = try requireCommandRunner(context);
    const resolved_path = try context.workspace_store.resolve(allocator, .{ .path = request.path, .provenance = "static_analysis.zwanzig_graph_path" });
    defer resolved_path.deinit(allocator);
    const resolved_output = try context.workspace_store.resolve(allocator, .{ .path = request.output, .for_output = true, .provenance = "static_analysis.zwanzig_graph_output" });
    defer resolved_output.deinit(allocator);
    _ = try context.workspace_store.ensureDir(.{ .path = request.output, .provenance = "static_analysis.zwanzig_graph_output" });
    const argv = try buildZwanzigGraphArgv(allocator, .{
        .executable = context.tool_paths.zwanzig,
        .mode = request.mode,
        .source_path = resolved_path.path,
        .output_dir = resolved_output.path,
        .extra = request.extra,
    });
    defer allocator.free(argv);
    const timeout_ms = commandTimeout(context, request.timeout_ms);
    const result = command_runner.run(allocator, .{
        .argv = argv,
        .cwd = context.workspace.root,
        .timeout_ms = timeout_ms,
        .provenance = "static_analysis.zwanzig_graph",
    }) catch |err| return .{ .value = try backendErrorValue(allocator, "zwanzig", "analysis_graphs", err, "confirm --zwanzig-path points to an executable zwanzig binary and the source path is readable") };
    defer result.deinit(allocator);
    if (result.effectiveTerm().failed() or result.timed_out) {
        return .{ .error_value = try graphCommandFailedValue(allocator, argv, context.workspace.root, timeout_ms, result) };
    }
    const dot_scan = context.workspace_store.scanDirectory(allocator, .{ .path = request.output, .suffix = ".dot", .provenance = "static_analysis.zwanzig_graph_verify" }) catch |err| {
        return .{ .error_value = try graphOutputInspectErrorValue(allocator, request.output, err) };
    };
    defer dot_scan.deinit(allocator);
    if (dot_scan.entries.len == 0) return .{ .error_value = try graphOutputMissingValue(allocator, request.output) };

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_analysis_graphs" });
    try obj.put(allocator, "backend", .{ .string = "zwanzig" });
    try obj.put(allocator, "optional_backend", .{ .bool = true });
    try obj.put(allocator, "mode", .{ .string = request.mode.name() });
    try obj.put(allocator, "mode_flag", .{ .string = request.mode.flag() });
    try obj.put(allocator, "path", try ownedString(allocator, request.path));
    try obj.put(allocator, "output", try ownedString(allocator, request.output));
    try obj.put(allocator, "output_abs", try ownedString(allocator, resolved_output.path));
    return .{ .value = .{ .object = obj } };
}

/// Implements zlint help supports rules workflow logic using caller-owned inputs.
pub fn zlintHelpSupportsRules(help: []const u8) bool {
    return std.mem.indexOf(u8, help, "--rules") != null;
}

/// Serializes backend command failed fields into an allocator-owned JSON value; allocation failures propagate.
fn backendCommandFailedValue(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, stdout: []const u8, stderr: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = "zlint" });
    try obj.put(allocator, "optional_backend", .{ .bool = true });
    try obj.put(allocator, "operation", try ownedString(allocator, operation));
    try obj.put(allocator, "error_kind", .{ .string = "command_failed" });
    try obj.put(allocator, "stdout", try ownedString(allocator, stdout));
    try obj.put(allocator, "stderr", try ownedString(allocator, stderr));
    try obj.put(allocator, "resolution", .{ .string = "Inspect ZLint stdout/stderr and confirm the selected path, config, and rules are supported by the configured binary." });
    return .{ .object = obj };
}

/// Serializes zlint rules unavailable fields into an allocator-owned JSON value; allocation failures propagate.
fn zlintRulesUnavailableValue(allocator: std.mem.Allocator, help: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_zlint_rules" });
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

/// Serializes zlint capabilities fields into an allocator-owned JSON value; allocation failures propagate.
fn zlintCapabilitiesValue(allocator: std.mem.Allocator, help: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "format_json", .{ .bool = std.mem.indexOf(u8, help, "--format") != null });
    try obj.put(allocator, "fix", .{ .bool = std.mem.indexOf(u8, help, "--fix") != null });
    try obj.put(allocator, "fix_dangerously", .{ .bool = std.mem.indexOf(u8, help, "--fix-dangerously") != null });
    try obj.put(allocator, "print_ast", .{ .bool = std.mem.indexOf(u8, help, "--print-ast") != null });
    try obj.put(allocator, "rules", .{ .bool = zlintHelpSupportsRules(help) });
    try obj.put(allocator, "help_preview", try ownedString(allocator, help[0..@min(help.len, 2048)]));
    return .{ .object = obj };
}

/// Serializes malformed backend output fields into an allocator-owned JSON value; allocation failures propagate.
fn malformedBackendOutputValue(allocator: std.mem.Allocator, tool_name: []const u8, stdout: []const u8, stderr: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = "zlint" });
    try obj.put(allocator, "optional_backend", .{ .bool = true });
    try obj.put(allocator, "error_kind", .{ .string = "backend_output_malformed" });
    try obj.put(allocator, "stdout_preview", try ownedString(allocator, stdout[0..@min(stdout.len, 4096)]));
    try obj.put(allocator, "stderr_preview", try ownedString(allocator, stderr[0..@min(stderr.len, 4096)]));
    try obj.put(allocator, "resolution", .{ .string = "Confirm the configured ZLint binary emits JSON with a findings, diagnostics, or rules array." });
    return .{ .object = obj };
}

/// Serializes lint findings result fields into an allocator-owned JSON value; allocation failures propagate.
fn lintFindingsResultValue(allocator: std.mem.Allocator, tool_name: []const u8, backend: []const u8, findings: std.json.Array) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "backend", try ownedString(allocator, backend));
    try obj.put(allocator, "optional_backend", .{ .bool = true });
    try obj.put(allocator, "findings", .{ .array = findings });
    try obj.put(allocator, "summary", try summaryValue(allocator, findings));
    try obj.put(allocator, "evidence_sources", try stringArrayValue(allocator, &.{"zlint"}));
    return .{ .object = obj };
}

/// Serializes zlint fix preview fields into an allocator-owned JSON value; allocation failures propagate.
fn zlintFixPreviewValue(allocator: std.mem.Allocator, argv: []const []const u8, dangerous: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_zlint_fix" });
    try obj.put(allocator, "backend", .{ .string = "zlint" });
    try obj.put(allocator, "optional_backend", .{ .bool = true });
    try obj.put(allocator, "apply", .{ .bool = false });
    try obj.put(allocator, "applied", .{ .bool = false });
    try obj.put(allocator, "requires_apply", .{ .bool = true });
    try obj.put(allocator, "dangerous", .{ .bool = dangerous });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "resolution", .{ .string = "Review the ZLint fix command and rerun with apply=true to let ZLint mutate workspace source files." });
    return .{ .object = obj };
}

/// Serializes zlint fix applied fields into an allocator-owned JSON value; allocation failures propagate.
fn zlintFixAppliedValue(allocator: std.mem.Allocator, argv: []const []const u8, dangerous: bool, stdout: []const u8, stderr: []const u8, findings: std.json.Array) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_zlint_fix" });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "backend", .{ .string = "zlint" });
    try obj.put(allocator, "optional_backend", .{ .bool = true });
    try obj.put(allocator, "apply", .{ .bool = true });
    try obj.put(allocator, "applied", .{ .bool = true });
    try obj.put(allocator, "dangerous", .{ .bool = dangerous });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "stdout_preview", try ownedString(allocator, stdout[0..@min(stdout.len, 4096)]));
    try obj.put(allocator, "stderr_preview", try ownedString(allocator, stderr[0..@min(stderr.len, 4096)]));
    try obj.put(allocator, "findings_after_fix", .{ .array = findings });
    try obj.put(allocator, "summary", try summaryValue(allocator, findings));
    return .{ .object = obj };
}

/// Normalizes findings text data into the representation consumed by this workflow.
pub fn normalizeFindingsText(allocator: std.mem.Allocator, text: []const u8, source: FindingSource) !std.json.Value {
    var findings = std.json.Array.init(allocator);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return .{ .array = findings };
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    const raw = findingsArray(parsed.value);
    for (raw.items) |item| try findings.append(try normalizeFindingValue(allocator, item, source));
    return .{ .array = findings };
}

/// Implements findings array workflow logic using caller-owned inputs.
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

/// Serializes normalize finding fields into an allocator-owned JSON value; allocation failures propagate.
fn normalizeFindingValue(allocator: std.mem.Allocator, value: std.json.Value, source: FindingSource) !std.json.Value {
    const obj = switch (value) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const location = switch (obj.get("location") orelse .null) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const file = stringField(obj, "path") orelse stringField(obj, "file") orelse stringField(location, "file") orelse stringField(location, "path") orelse "unknown";
    const line: usize = @intCast(@max(integerField(obj, "line") orelse integerField(location, "line") orelse 1, 1));
    const column: usize = @intCast(@max(integerField(obj, "column") orelse integerField(location, "column") orelse 1, 1));
    const rule = stringField(obj, "rule") orelse stringField(obj, "rule_id") orelse stringField(obj, "code") orelse "unknown";
    const severity = stringField(obj, "severity") orelse stringField(obj, "level") orelse "info";
    const message = stringField(obj, "message") orelse stringField(obj, "title") orelse stringField(obj, "detail") orelse "";
    const finding = try findingValue(allocator, if (source == .zlint) "zlint" else "zwanzig", rule, severity, file, line, column, message, "high");
    var out = finding.object;
    try out.put(allocator, "comparison_key", .{ .string = try std.fmt.allocPrint(allocator, "{s}:{s}:{d}", .{ rule, file, line }) });
    try out.put(allocator, "fingerprint", try fingerprintValue(allocator, .{ .object = out }));
    return .{ .object = out };
}

/// Normalizes rules text data into the representation consumed by this workflow.
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
        try rule.put(allocator, "id", if (stringField(obj, "id") orelse stringField(obj, "rule")) |id| try ownedString(allocator, id) else .null);
        try rule.put(allocator, "severity", if (stringField(obj, "severity")) |severity| try ownedString(allocator, severity) else .{ .string = "info" });
        try rule.put(allocator, "category", if (stringField(obj, "category")) |category| try ownedString(allocator, category) else .null);
        try rule.put(allocator, "description", if (stringField(obj, "description") orelse stringField(obj, "message")) |description| try ownedString(allocator, description) else .null);
        try rule.put(allocator, "source", .{ .string = "zlint" });
        try rules.append(.{ .object = rule });
    }
    return .{ .array = rules };
}

/// Serializes sarif result fields into an allocator-owned JSON value; allocation failures propagate.
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
    try obj.put(allocator, "backend", .{ .string = "zlint" });
    try obj.put(allocator, "sarif", .{ .object = sarif });
    try obj.put(allocator, "summary", try summaryValue(allocator, findings));
    return .{ .object = obj };
}

/// Serializes sarif finding fields into an allocator-owned JSON value; allocation failures propagate.
fn sarifFindingValue(allocator: std.mem.Allocator, finding: std.json.Value) !std.json.Value {
    const obj = finding.object;
    const loc = if (obj.get("location")) |value| switch (value) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    } else std.json.ObjectMap.empty;
    var region = std.json.ObjectMap.empty;
    try region.put(allocator, "startLine", .{ .integer = integerField(loc, "line") orelse 1 });
    try region.put(allocator, "startColumn", .{ .integer = integerField(loc, "column") orelse 1 });
    var artifact = std.json.ObjectMap.empty;
    try artifact.put(allocator, "uri", if (stringField(loc, "file")) |file| try ownedString(allocator, file) else .{ .string = "unknown" });
    var physical = std.json.ObjectMap.empty;
    try physical.put(allocator, "artifactLocation", .{ .object = artifact });
    try physical.put(allocator, "region", .{ .object = region });
    var location = std.json.ObjectMap.empty;
    try location.put(allocator, "physicalLocation", .{ .object = physical });
    var locations = std.json.Array.init(allocator);
    try locations.append(.{ .object = location });
    var message = std.json.ObjectMap.empty;
    try message.put(allocator, "text", if (stringField(obj, "message")) |text| try ownedString(allocator, text) else .{ .string = "" });
    var out = std.json.ObjectMap.empty;
    try out.put(allocator, "ruleId", if (stringField(obj, "rule")) |rule| try ownedString(allocator, rule) else .{ .string = "unknown" });
    try out.put(allocator, "level", try ownedString(allocator, sarifLevel(stringField(obj, "severity") orelse "info")));
    try out.put(allocator, "message", .{ .object = message });
    try out.put(allocator, "locations", .{ .array = locations });
    return .{ .object = out };
}

/// Implements sarif level workflow logic using caller-owned inputs.
fn sarifLevel(severity: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(severity, "error")) return "error";
    if (std.ascii.eqlIgnoreCase(severity, "warning") or std.ascii.eqlIgnoreCase(severity, "warn")) return "warning";
    return "note";
}

/// Serializes lint compare fields into an allocator-owned JSON value; allocation failures propagate.
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
    try obj.put(allocator, "consensus", .{ .array = consensus });
    try obj.put(allocator, "disagreements", .{ .array = disagreements });
    try obj.put(allocator, "zlint_only", .{ .array = zlint_only });
    try obj.put(allocator, "zwanzig_only", .{ .array = zwanzig_only });
    try obj.put(allocator, "summary", try compareSummaryValue(allocator, consensus, disagreements, zlint_only, zwanzig_only));
    return .{ .object = obj };
}

/// Serializes pair fields into an allocator-owned JSON value; allocation failures propagate.
fn pairValue(allocator: std.mem.Allocator, left: std.json.Value, right: std.json.Value) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "source", .{ .string = "disagreement" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "zlint", left);
    try obj.put(allocator, "zwanzig", right);
    return .{ .object = obj };
}

/// Serializes compare summary fields into an allocator-owned JSON value; allocation failures propagate.
fn compareSummaryValue(allocator: std.mem.Allocator, consensus: std.json.Array, disagreements: std.json.Array, zlint_only: std.json.Array, zwanzig_only: std.json.Array) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "consensus_count", .{ .integer = @intCast(consensus.items.len) });
    try obj.put(allocator, "disagreement_count", .{ .integer = @intCast(disagreements.items.len) });
    try obj.put(allocator, "zlint_only_count", .{ .integer = @intCast(zlint_only.items.len) });
    try obj.put(allocator, "zwanzig_only_count", .{ .integer = @intCast(zwanzig_only.items.len) });
    return .{ .object = obj };
}

/// Serializes lint profile fields into an allocator-owned JSON value; allocation failures propagate.
pub fn lintProfileValue(allocator: std.mem.Allocator, selected: []const u8) !std.json.Value {
    var profiles = std.json.Array.init(allocator);
    try profiles.append(try profileValue(allocator, "advisory", true, 9999, false));
    try profiles.append(try profileValue(allocator, "standard", false, 25, true));
    try profiles.append(try profileValue(allocator, "strict", false, 0, true));
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_lint_profile" });
    try obj.put(allocator, "selected", try ownedString(allocator, selected));
    try obj.put(allocator, "profiles", .{ .array = profiles });
    return .{ .object = obj };
}

/// Serializes profile fields into an allocator-owned JSON value; allocation failures propagate.
fn profileValue(allocator: std.mem.Allocator, name: []const u8, allow_warnings: bool, max_warnings: i64, require_backend: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, name));
    try obj.put(allocator, "allow_warnings", .{ .bool = allow_warnings });
    try obj.put(allocator, "max_warnings", .{ .integer = max_warnings });
    try obj.put(allocator, "fail_on_error", .{ .bool = true });
    try obj.put(allocator, "require_configured_linter", .{ .bool = require_backend });
    return .{ .object = obj };
}

/// Implements lint profile defaults workflow logic using caller-owned inputs.
pub fn lintProfileDefaults(name: []const u8) LintProfile {
    if (std.mem.eql(u8, name, "advisory")) return .{ .allow_warnings = true, .max_warnings = 9999, .require_backend = false };
    if (std.mem.eql(u8, name, "strict")) return .{ .allow_warnings = false, .max_warnings = 0, .require_backend = true };
    return .{ .allow_warnings = false, .max_warnings = 25, .require_backend = true };
}

/// Serializes lint gate fields into an allocator-owned JSON value; allocation failures propagate.
pub fn lintGateValue(allocator: std.mem.Allocator, findings: std.json.Array, profile: []const u8, allow_warnings: bool, max_warnings: i64) !std.json.Value {
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
    try obj.put(allocator, "profile", try ownedString(allocator, profile));
    try obj.put(allocator, "passed", .{ .bool = blocking.items.len == 0 });
    try obj.put(allocator, "blocking_findings", .{ .array = blocking });
    try obj.put(allocator, "summary", try summaryValue(allocator, findings));
    return .{ .object = obj };
}

/// Serializes fix plan fields into an allocator-owned JSON value; allocation failures propagate.
pub fn fixPlanValue(allocator: std.mem.Allocator, findings: std.json.Array) !std.json.Value {
    var safe = std.json.Array.init(allocator);
    var risky = std.json.Array.init(allocator);
    var manual = std.json.Array.init(allocator);
    for (findings.items) |finding| {
        const message = stringField(finding.object, "message") orelse "";
        if (std.mem.indexOf(u8, message, "format") != null or std.mem.indexOf(u8, message, "unused") != null) try safe.append(finding) else if (std.ascii.eqlIgnoreCase(severityOf(finding), "error")) try risky.append(finding) else try manual.append(finding);
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_lint_fix_plan" });
    try obj.put(allocator, "preview_only", .{ .bool = true });
    try obj.put(allocator, "apply_supported", .{ .bool = true });
    try obj.put(allocator, "apply_tool", .{ .string = "zig_zlint_fix" });
    try obj.put(allocator, "safe", .{ .array = safe });
    try obj.put(allocator, "risky", .{ .array = risky });
    try obj.put(allocator, "manual", .{ .array = manual });
    return .{ .object = obj };
}

/// Implements lint baseline workflow logic using caller-owned inputs.
pub fn lintBaseline(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, findings: std.json.Array, baseline: std.json.Array, apply: bool, output: []const u8) LintError!std.json.Value {
    const value = try baselineValue(allocator, findings, baseline);
    if (apply) {
        const bytes = try serializeAlloc(allocator, value);
        defer allocator.free(bytes);
        _ = try context.workspace_store.write(.{
            .path = output,
            .bytes = bytes,
            .provenance = "static_analysis.lint_baseline",
        });
    }
    return value;
}

/// Serializes baseline fields into an allocator-owned JSON value; allocation failures propagate.
pub fn baselineValue(allocator: std.mem.Allocator, findings: std.json.Array, baseline: std.json.Array) !std.json.Value {
    var current = std.json.Array.init(allocator);
    var accepted = std.json.Array.init(allocator);
    var resolved = std.json.Array.init(allocator);
    for (findings.items) |finding| if (findByComparisonKey(baseline, comparisonKey(finding)) == null) try current.append(finding) else try accepted.append(finding);
    for (baseline.items) |old| if (findByComparisonKey(findings, comparisonKey(old)) == null) try resolved.append(old);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_lint_baseline" });
    try obj.put(allocator, "new_findings", .{ .array = current });
    try obj.put(allocator, "accepted_findings", .{ .array = accepted });
    try obj.put(allocator, "resolved_findings", .{ .array = resolved });
    try obj.put(allocator, "baseline_count", .{ .integer = @intCast(findings.items.len) });
    return .{ .object = obj };
}

/// Serializes suppressions fields into an allocator-owned JSON value; allocation failures propagate.
pub fn suppressionsValue(allocator: std.mem.Allocator, findings: std.json.Array, suppressions_text: []const u8) !std.json.Value {
    const suppressions = normalizeFindingsText(allocator, suppressions_text, .zlint) catch std.json.Value{ .array = std.json.Array.init(allocator) };
    var suppressed = std.json.Array.init(allocator);
    var active = std.json.Array.init(allocator);
    var stale = std.json.Array.init(allocator);
    for (findings.items) |finding| if (findByComparisonKey(suppressions.array, comparisonKey(finding)) != null) try suppressed.append(finding) else try active.append(finding);
    for (suppressions.array.items) |suppression| if (findByComparisonKey(findings, comparisonKey(suppression)) == null) try stale.append(suppression);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_lint_suppressions" });
    try obj.put(allocator, "suppressed", .{ .array = suppressed });
    try obj.put(allocator, "active", .{ .array = active });
    try obj.put(allocator, "stale_suppressions", .{ .array = stale });
    return .{ .object = obj };
}

/// Serializes trend fields into an allocator-owned JSON value; allocation failures propagate.
pub fn trendValue(allocator: std.mem.Allocator, before: std.json.Array, after: std.json.Array) !std.json.Value {
    var new_findings = std.json.Array.init(allocator);
    var resolved = std.json.Array.init(allocator);
    var persistent = std.json.Array.init(allocator);
    for (after.items) |finding| if (findByComparisonKey(before, comparisonKey(finding)) == null) try new_findings.append(finding) else try persistent.append(finding);
    for (before.items) |finding| if (findByComparisonKey(after, comparisonKey(finding)) == null) try resolved.append(finding);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_lint_trend" });
    try obj.put(allocator, "new_findings", .{ .array = new_findings });
    try obj.put(allocator, "resolved_findings", .{ .array = resolved });
    try obj.put(allocator, "persistent_findings", .{ .array = persistent });
    try obj.put(allocator, "before_count", .{ .integer = @intCast(before.items.len) });
    try obj.put(allocator, "after_count", .{ .integer = @intCast(after.items.len) });
    return .{ .object = obj };
}

/// Implements require command runner workflow logic using caller-owned inputs.
fn requireCommandRunner(context: app_context.StaticAnalysisContext) LintError!ports.CommandRunner {
    return context.command_runner orelse error.MissingCommandRunner;
}

/// Converts timing input into the duration unit used by result payloads.
fn commandTimeout(context: app_context.StaticAnalysisContext, requested_timeout_ms: ?u64) u64 {
    if (requested_timeout_ms) |value| return @max(value, 1);
    return @intCast(@max(context.timeouts.command_ms, 1));
}

/// Serializes backend error fields into an allocator-owned JSON value; allocation failures propagate.
fn backendErrorValue(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend_name });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = backendErrorKind(err) });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return .{ .object = obj };
}

/// Implements backend error kind workflow logic using caller-owned inputs.
fn backendErrorKind(err: anyerror) []const u8 {
    return switch (err) {
        error.RequestTimeout, error.Timeout => "timeout",
        error.FileNotFound => "executable_not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        error.OutputLimitExceeded, error.StreamTooLong => "output_limit",
        error.Unavailable, error.EndOfStream, error.BrokenPipe => "unavailable",
        else => "execution",
    };
}

/// Serializes graph command failed fields into an allocator-owned JSON value; allocation failures propagate.
fn graphCommandFailedValue(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8, timeout_ms: u64, result: ports.CommandResult) !std.json.Value {
    const command_text = try commandString(allocator, argv);
    const stdout = try safeTextAlloc(allocator, result.stdout);
    const stderr = try safeTextAlloc(allocator, result.stderr);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "tool_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "tool", .{ .string = "zig_analysis_graphs" });
    try obj.put(allocator, "operation", .{ .string = "generate_analysis_graphs" });
    try obj.put(allocator, "phase", .{ .string = "run_zwanzig_graph" });
    try obj.put(allocator, "code", .{ .string = "zwanzig_graph_command_failed" });
    try obj.put(allocator, "category", .{ .string = "backend" });
    try obj.put(allocator, "retryable", .{ .bool = false });
    try obj.put(allocator, "resolution", .{ .string = "Inspect stdout/stderr, confirm the selected graph mode is supported by the configured zwanzig binary, and retry." });
    try obj.put(allocator, "backend", .{ .string = "zwanzig" });
    try obj.put(allocator, "command", .{ .string = command_text });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "timeout_ms", .{ .integer = @intCast(timeout_ms) });
    try obj.put(allocator, "term", .{ .string = result.effectiveTerm().name() });
    try obj.put(allocator, "exit_code", if (result.effectiveTerm().exitCode()) |code| .{ .integer = code } else .null);
    try obj.put(allocator, "stdout", .{ .string = stdout.text });
    try obj.put(allocator, "stderr", .{ .string = stderr.text });
    try obj.put(allocator, "stdout_invalid_utf8", .{ .bool = stdout.invalid_utf8 });
    try obj.put(allocator, "stderr_invalid_utf8", .{ .bool = stderr.invalid_utf8 });
    try obj.put(allocator, "stdout_encoding", .{ .string = stdout.encoding });
    try obj.put(allocator, "stderr_encoding", .{ .string = stderr.encoding });
    try obj.put(allocator, "stdout_byte_count", .{ .integer = @intCast(stdout.byte_count) });
    try obj.put(allocator, "stderr_byte_count", .{ .integer = @intCast(stderr.byte_count) });
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    try obj.put(allocator, "output_limit_mode", .{ .string = command_output_limit_mode });
    return .{ .object = obj };
}

/// Serializes graph output inspect error fields into an allocator-owned JSON value; allocation failures propagate.
fn graphOutputInspectErrorValue(allocator: std.mem.Allocator, output: []const u8, err: anyerror) !std.json.Value {
    var obj = try graphOutputBaseErrorValue(allocator, output, "inspect_output_directory", "backend_output_malformed", "Confirm zwanzig wrote DOT graph files to the requested workspace output directory.");
    try obj.object.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.object.put(allocator, "error_kind", .{ .string = backendErrorKind(err) });
    return obj;
}

/// Serializes graph output missing fields into an allocator-owned JSON value; allocation failures propagate.
fn graphOutputMissingValue(allocator: std.mem.Allocator, output: []const u8) !std.json.Value {
    return graphOutputBaseErrorValue(allocator, output, "inspect_output_directory", "backend_output_malformed", "The zwanzig command completed but no .dot graph files were found in the requested output directory.");
}

/// Serializes graph output base error fields into an allocator-owned JSON value; allocation failures propagate.
fn graphOutputBaseErrorValue(allocator: std.mem.Allocator, output: []const u8, phase: []const u8, code: []const u8, resolution: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "tool_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "tool", .{ .string = "zig_analysis_graphs" });
    try obj.put(allocator, "operation", .{ .string = "verify_graph_output" });
    try obj.put(allocator, "phase", .{ .string = phase });
    try obj.put(allocator, "code", .{ .string = code });
    try obj.put(allocator, "category", .{ .string = "backend_output" });
    try obj.put(allocator, "retryable", .{ .bool = false });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    try obj.put(allocator, "output", try ownedString(allocator, output));
    return .{ .object = obj };
}

/// Serializes command result fields into an allocator-owned JSON value; allocation failures propagate.
fn commandResultValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: u64, result: ports.CommandResult) !std.json.Value {
    const term = result.effectiveTerm();
    const ok = !term.failed() and !result.timed_out;
    const stdout = try safeTextAlloc(allocator, result.stdout);
    const stderr = try safeTextAlloc(allocator, result.stderr);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "command" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = @intCast(timeout_ms) });
    try obj.put(allocator, "duration_ms", .{ .integer = @intCast(result.duration_ms) });
    try obj.put(allocator, "term", try commandTermValue(allocator, term));
    try putStreamFields(allocator, &obj, "stdout", stdout);
    try putStreamFields(allocator, &obj, "stderr", stderr);
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(command_output_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(command_output_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = command_output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = result.stdout_truncated or result.stderr_truncated });
    if (result.stdout_truncated or result.stderr_truncated) {
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigar's capture limit. zigar returned the captured prefix and marked the truncated stream so the result remains inspectable." });
    }
    const insights = try compilerInsightsValue(allocator, stdout.text, stderr.text, argv);
    try obj.put(allocator, "diagnostics", insights);
    try obj.put(allocator, "failure_summary", try failureSummaryValue(allocator, insights, ok, argv));
    return .{ .object = obj };
}

/// Serializes command error fields into an allocator-owned JSON value; allocation failures propagate.
fn commandErrorValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: u64, err: ports.PortError) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "command_error" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = @intCast(timeout_ms) });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = backendErrorKind(err) });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(command_output_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(command_output_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = command_output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = err == error.OutputLimitExceeded or err == error.StreamTooLong });
    try obj.put(allocator, "stdout_truncated", .{ .bool = false });
    try obj.put(allocator, "stderr_truncated", .{ .bool = false });
    try obj.put(allocator, "failure_summary", try commandErrorSummaryValue(allocator, err, argv));
    return .{ .object = obj };
}

/// Serializes command term fields into an allocator-owned JSON value; allocation failures propagate.
fn commandTermValue(allocator: std.mem.Allocator, term: ports.CommandTerm) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    switch (term) {
        .exited => |code| {
            try obj.put(allocator, "kind", .{ .string = "exited" });
            try obj.put(allocator, "code", .{ .integer = @intCast(code) });
        },
        .signal => try obj.put(allocator, "kind", .{ .string = "signal" }),
        .stopped => try obj.put(allocator, "kind", .{ .string = "stopped" }),
        .unknown => try obj.put(allocator, "kind", .{ .string = "unknown" }),
    }
    return .{ .object = obj };
}

/// Serializes compiler insights fields into an allocator-owned JSON value; allocation failures propagate.
fn compilerInsightsValue(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8, argv: []const []const u8) !std.json.Value {
    var findings = std.json.Array.init(allocator);
    var error_count: i64 = 0;
    var warning_count: i64 = 0;
    var note_count: i64 = 0;
    var primary: ?compiler_output.CompilerLine = null;
    try collectCompilerLines(allocator, &findings, stderr, &primary, &error_count, &warning_count, &note_count);
    try collectCompilerLines(allocator, &findings, stdout, &primary, &error_count, &warning_count, &note_count);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try obj.put(allocator, "error_count", .{ .integer = error_count });
    try obj.put(allocator, "warning_count", .{ .integer = warning_count });
    try obj.put(allocator, "note_count", .{ .integer = note_count });
    try obj.put(allocator, "findings", .{ .array = findings });
    if (primary) |p| {
        try obj.put(allocator, "primary", try compilerLineValue(allocator, p));
        try obj.put(allocator, "category", .{ .string = compiler_output.classifyDiagnosticMessage(p.message) });
        try obj.put(allocator, "next_command", try compilerNextCommand(allocator, p, argv));
        try obj.put(allocator, "next_actions", try compilerNextActions(allocator, p, note_count));
    } else {
        try obj.put(allocator, "primary", .null);
        try obj.put(allocator, "category", .{ .string = "none" });
        try obj.put(allocator, "next_command", .null);
        try obj.put(allocator, "next_actions", .{ .array = std.json.Array.init(allocator) });
    }
    return .{ .object = obj };
}

/// Collects compiler lines data into caller-provided output storage without taking ownership of inputs.
fn collectCompilerLines(allocator: std.mem.Allocator, findings: *std.json.Array, text_value: []const u8, primary: *?compiler_output.CompilerLine, error_count: *i64, warning_count: *i64, note_count: *i64) !void {
    var lines = std.mem.splitScalar(u8, text_value, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        const parsed = compiler_output.parseCompilerLine(line) orelse continue;
        if (std.mem.eql(u8, parsed.severity, "error")) {
            error_count.* += 1;
            if (primary.* == null) primary.* = parsed;
        } else if (std.mem.eql(u8, parsed.severity, "warning")) {
            warning_count.* += 1;
            if (primary.* == null) primary.* = parsed;
        } else if (std.mem.eql(u8, parsed.severity, "note")) {
            note_count.* += 1;
        }
        try findings.append(try compilerLineValue(allocator, parsed));
    }
}

/// Serializes compiler line fields into an allocator-owned JSON value; allocation failures propagate.
fn compilerLineValue(allocator: std.mem.Allocator, parsed: compiler_output.CompilerLine) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "severity", .{ .string = parsed.severity });
    try obj.put(allocator, "message", try ownedString(allocator, parsed.message));
    try obj.put(allocator, "raw", try ownedString(allocator, parsed.raw));
    try obj.put(allocator, "path", if (parsed.path) |path| try ownedString(allocator, path) else .null);
    try obj.put(allocator, "line", if (parsed.line) |line_no| .{ .integer = line_no } else .null);
    try obj.put(allocator, "column", if (parsed.column) |col_no| .{ .integer = col_no } else .null);
    return .{ .object = obj };
}

/// Implements compiler next command workflow logic using caller-owned inputs.
fn compilerNextCommand(allocator: std.mem.Allocator, primary: compiler_output.CompilerLine, argv: []const []const u8) !std.json.Value {
    const zig = if (argv.len > 0) argv[0] else "zig";
    const path = primary.path orelse return .{ .string = try commandString(allocator, argv) };
    if (path.len > 0 and std.mem.endsWith(u8, path, ".zig")) {
        if (argvContains(argv, "test")) return .{ .string = try std.fmt.allocPrint(allocator, "{s} test {s}", .{ zig, path }) };
        return .{ .string = try std.fmt.allocPrint(allocator, "{s} ast-check {s}", .{ zig, path }) };
    }
    return .{ .string = try commandString(allocator, argv) };
}

/// Implements compiler next actions workflow logic using caller-owned inputs.
fn compilerNextActions(allocator: std.mem.Allocator, primary: compiler_output.CompilerLine, note_count: i64) !std.json.Value {
    var actions = std.json.Array.init(allocator);
    if (primary.path) |path| {
        if (primary.line) |line_no| {
            if (primary.column) |col_no| {
                try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Open {s}:{d}:{d} and address the primary {s}: {s}", .{ path, line_no, col_no, primary.severity, primary.message }) });
            } else {
                try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Open {s}:{d} and address the primary {s}: {s}", .{ path, line_no, primary.severity, primary.message }) });
            }
        } else {
            try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Inspect {s} and address the primary {s}: {s}", .{ path, primary.severity, primary.message }) });
        }
    } else {
        try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Address the primary {s}: {s}", .{ primary.severity, primary.message }) });
    }
    if (note_count > 0) try actions.append(try ownedString(allocator, "Review compiler note entries before editing; Zig often puts the fix-relevant type or declaration context there."));
    if (std.mem.eql(u8, compiler_output.classifyDiagnosticMessage(primary.message), "missing_file_or_import")) {
        try actions.append(try ownedString(allocator, "Run zig_import_resolve for the failing @import name, then check build.zig addImport and build.zig.zon dependency wiring."));
    }
    try actions.append(try ownedString(allocator, "Rerun the next_command after the focused edit."));
    return .{ .array = actions };
}

/// Serializes failure summary fields into an allocator-owned JSON value; allocation failures propagate.
fn failureSummaryValue(allocator: std.mem.Allocator, insights: std.json.Value, ok: bool, argv: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "ok", .{ .bool = ok });
    const insights_obj = switch (insights) {
        .object => |o| o,
        else => {
            try obj.put(allocator, "primary", .null);
            return .{ .object = obj };
        },
    };
    const primary = insights_obj.get("primary") orelse .null;
    try obj.put(allocator, "primary", primary);
    try obj.put(allocator, "error_class", insights_obj.get("category") orelse .{ .string = "none" });
    try obj.put(allocator, "rerun_command", insights_obj.get("next_command") orelse .null);
    var suggested = std.json.Array.init(allocator);
    if (!ok) {
        try suggested.append(try ownedString(allocator, "zig_compile_error_index"));
        if (argvContains(argv, "test")) try suggested.append(try ownedString(allocator, "zig_test_failure_triage"));
        try suggested.append(try ownedString(allocator, "zigar_failure_fusion"));
        try suggested.append(try ownedString(allocator, "zigar_impact"));
    }
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", try likelyFailureScopeValue(allocator, primary));
    return .{ .object = obj };
}

/// Serializes command error summary fields into an allocator-owned JSON value; allocation failures propagate.
fn commandErrorSummaryValue(allocator: std.mem.Allocator, err: anyerror, argv: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "primary", .null);
    try obj.put(allocator, "error_class", .{ .string = backendErrorKind(err) });
    try obj.put(allocator, "rerun_command", .{ .string = try commandString(allocator, argv) });
    var suggested = std.json.Array.init(allocator);
    try suggested.append(try ownedString(allocator, "zigar_doctor"));
    try suggested.append(try ownedString(allocator, "zigar_context_pack"));
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", .{ .string = if (err == error.Timeout or err == error.RequestTimeout) "command_timeout" else "tool_or_backend_configuration" });
    return .{ .object = obj };
}

/// Serializes likely failure scope fields into an allocator-owned JSON value; allocation failures propagate.
fn likelyFailureScopeValue(allocator: std.mem.Allocator, primary: std.json.Value) !std.json.Value {
    const primary_obj = switch (primary) {
        .object => |o| o,
        else => return .{ .string = "none" },
    };
    const path = switch (primary_obj.get("path") orelse .null) {
        .string => |s| s,
        else => return .{ .string = "workspace_or_build" },
    };
    if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) return .{ .string = "build_configuration" };
    if (std.mem.endsWith(u8, path, ".zig")) return .{ .string = "source_file" };
    return .{ .string = try std.fmt.allocPrint(allocator, "path:{s}", .{path}) };
}

const SafeText = struct {
    text: []const u8,
    invalid_utf8: bool,
    encoding: []const u8,
    byte_count: usize,
};

/// Copies bounded text into allocator-owned storage for result payloads.
fn safeTextAlloc(allocator: std.mem.Allocator, bytes: []const u8) !SafeText {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        return .{ .text = try allocator.dupe(u8, bytes), .invalid_utf8 = false, .encoding = "utf-8", .byte_count = bytes.len };
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
            try out.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
            continue;
        };
        if (index + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[index .. index + len])) {
            try out.appendSlice(allocator, bytes[index .. index + len]);
            index += len;
        } else {
            try out.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
        }
    }
    return .{ .text = try out.toOwnedSlice(allocator), .invalid_utf8 = true, .encoding = "utf-8-lossy", .byte_count = bytes.len };
}

/// Implements put stream fields workflow logic using caller-owned inputs.
fn putStreamFields(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, name: []const u8, safe: SafeText) !void {
    try obj.put(allocator, name, .{ .string = safe.text });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_invalid_utf8", .{name}), .{ .bool = safe.invalid_utf8 });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_encoding", .{name}), .{ .string = safe.encoding });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_byte_count", .{name}), .{ .integer = @intCast(safe.byte_count) });
}

/// Serializes finding fields into an allocator-owned JSON value; allocation failures propagate.
fn findingValue(allocator: std.mem.Allocator, source: []const u8, rule: []const u8, severity: []const u8, file: []const u8, line: usize, column: usize, message: []const u8, confidence: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "source", .{ .string = source });
    try obj.put(allocator, "rule", try ownedString(allocator, rule));
    try obj.put(allocator, "severity", try ownedString(allocator, severity));
    try obj.put(allocator, "location", try locationValue(allocator, file, line, column));
    try obj.put(allocator, "message", try ownedString(allocator, message));
    try obj.put(allocator, "confidence", .{ .string = confidence });
    try obj.put(allocator, "recommended_cross_check", try stringArrayValue(allocator, &.{ "zig_lint_compare", "zig build test" }));
    return .{ .object = obj };
}

/// Serializes summary fields into an allocator-owned JSON value; allocation failures propagate.
fn summaryValue(allocator: std.mem.Allocator, findings: std.json.Array) !std.json.Value {
    var errors: usize = 0;
    var warnings: usize = 0;
    var infos: usize = 0;
    for (findings.items) |finding| {
        const obj = switch (finding) {
            .object => |o| o,
            else => continue,
        };
        const severity = stringField(obj, "severity") orelse continue;
        if (std.ascii.eqlIgnoreCase(severity, "error")) errors += 1 else if (std.ascii.eqlIgnoreCase(severity, "warning") or std.ascii.eqlIgnoreCase(severity, "warn")) warnings += 1 else infos += 1;
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try obj.put(allocator, "error_count", .{ .integer = @intCast(errors) });
    try obj.put(allocator, "warning_count", .{ .integer = @intCast(warnings) });
    try obj.put(allocator, "info_count", .{ .integer = @intCast(infos) });
    return .{ .object = obj };
}

/// Serializes location fields into an allocator-owned JSON value; allocation failures propagate.
fn locationValue(allocator: std.mem.Allocator, file: []const u8, line: usize, column: usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "line", .{ .integer = @intCast(@max(line, 1)) });
    try obj.put(allocator, "column", .{ .integer = @intCast(@max(column, 1)) });
    return .{ .object = obj };
}

/// Serializes fingerprint fields into an allocator-owned JSON value; allocation failures propagate.
fn fingerprintValue(allocator: std.mem.Allocator, finding: std.json.Value) !std.json.Value {
    const obj = switch (finding) {
        .object => |o| o,
        else => return ownedString(allocator, "unknown"),
    };
    const source = stringField(obj, "source") orelse "unknown";
    const rule = stringField(obj, "rule") orelse "unknown";
    const message = stringField(obj, "message") orelse "";
    const location = switch (obj.get("location") orelse .null) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const file = stringField(location, "file") orelse "unknown";
    const line = integerField(location, "line") orelse 0;
    return .{ .string = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}:{d}:{s}", .{ source, rule, file, line, message }) };
}

/// Implements comparison key workflow logic using caller-owned inputs.
fn comparisonKey(value: std.json.Value) []const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return "",
    };
    return stringField(obj, "comparison_key") orelse "";
}

/// Implements severity of workflow logic using caller-owned inputs.
fn severityOf(value: std.json.Value) []const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return "",
    };
    return stringField(obj, "severity") orelse "";
}

/// Finds by comparison key data in the provided collection without taking ownership.
fn findByComparisonKey(array: std.json.Array, key: []const u8) ?std.json.Value {
    for (array.items) |item| if (std.mem.eql(u8, comparisonKey(item), key)) return item;
    return null;
}

/// Extracts string field data from JSON input without taking ownership of borrowed values.
fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return switch (obj.get(field) orelse .null) {
        .string => |s| s,
        else => null,
    };
}

/// Extracts integer field data from JSON input without taking ownership of borrowed values.
fn integerField(obj: std.json.ObjectMap, field: []const u8) ?i64 {
    return switch (obj.get(field) orelse .null) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Copies the provided string into allocator-owned storage.
fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

/// Serializes string array fields into an allocator-owned JSON value; allocation failures propagate.
fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(try ownedString(allocator, value));
    return .{ .array = array };
}

/// Serializes argv fields into an allocator-owned JSON value; allocation failures propagate.
fn argvValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (argv) |arg| try array.append(try ownedString(allocator, arg));
    return .{ .array = array };
}

/// Formats argv entries into display command text.
fn commandString(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    if (argv.len == 0) return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

/// Reads the argv contains argument from JSON input without taking ownership of borrowed strings.
fn argvContains(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| if (std.mem.eql(u8, arg, needle)) return true;
    return false;
}

/// Serializes alloc data into allocator-owned JSON text.
fn serializeAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try serializeValue(allocator, &bytes, value);
    return bytes.toOwnedSlice(allocator);
}

/// Serializes serialize fields into an allocator-owned JSON value; allocation failures propagate.
fn serializeValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| try out.print(allocator, "{d}", .{i}),
        .float => |f| try out.print(allocator, "{d}", .{f}),
        .number_string => |s| try out.appendSlice(allocator, s),
        .string => |s| try serializeString(allocator, out, s),
        .array => |array| {
            try out.append(allocator, '[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try out.append(allocator, ',');
                try serializeValue(allocator, out, item);
            }
            try out.append(allocator, ']');
        },
        .object => |object| {
            try out.append(allocator, '{');
            var it = object.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.append(allocator, ',');
                first = false;
                try serializeString(allocator, out, entry.key_ptr.*);
                try out.append(allocator, ':');
                try serializeValue(allocator, out, entry.value_ptr.*);
            }
            try out.append(allocator, '}');
        },
    }
}

/// Serializes string data into allocator-owned JSON text.
fn serializeString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789abcdef";
    try out.append(allocator, '"');
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        0...8, 11...12, 14...0x1f => {
            try out.appendSlice(allocator, "\\u00");
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0f]);
        },
        else => try out.append(allocator, c),
    };
    try out.append(allocator, '"');
}

const command_runner_fake = @import("../../../testing/fakes/command_runner.zig");
const workspace_store_fake = @import("../../../testing/fakes/workspace_store.zig");
const workspace_scanner_fake = @import("../../../testing/fakes/workspace_scanner.zig");

test "zlint diagnostics rules and fixes exercise command-backed outcomes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var commands = command_runner_fake.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var store = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer store.deinit();
    var scanner = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    const context = testStaticContext(&commands, &store, &scanner);

    try store.expectResolve(.{ .path = "zlint.json", .provenance = "static_analysis.zlint_config" }, "/workspace/zlint.json");
    try store.expectResolve(.{ .path = "src", .provenance = "static_analysis.zlint_path" }, "/workspace/src");
    try commands.expectRun(.{
        .argv = &.{ "zlint-test", "--format", "json", "--config", "/workspace/zlint.json", "--rules", "style", "/workspace/src", "--extra" },
        .cwd = "/workspace",
        .timeout_ms = 55,
        .provenance = "static_analysis.zlint",
    }, .{
        .stdout =
        \\{"diagnostics":[{"rule_id":"style.warn","level":"warn","location":{"path":"src/main.zig","line":4,"column":2},"title":"format this"}]}
        ,
    });
    const diagnostics = try runZlintDiagnostics(allocator, context, .{
        .tool_name = "zig_zlint",
        .path = "src",
        .config = "zlint.json",
        .rules = "style",
        .extra = &.{"--extra"},
        .timeout_ms = 55,
        .sarif = true,
    });
    try std.testing.expectEqualStrings("zig_zlint", diagnostics.object.get("kind").?.string);
    try std.testing.expect(diagnostics.object.get("sarif") != null);

    try commands.expectRun(.{
        .argv = &.{ "zlint-test", "--help" },
        .cwd = "/workspace",
        .timeout_ms = 77,
        .provenance = "static_analysis.zlint_rules_help",
    }, .{ .stdout = "Usage\n--rules\n--format\n--fix\n--fix-dangerously\n--print-ast\n" });
    try commands.expectRun(.{
        .argv = &.{ "zlint-test", "--rules", "--format", "json" },
        .cwd = "/workspace",
        .timeout_ms = 77,
        .provenance = "static_analysis.zlint_rules",
    }, .{ .stdout = "{\"rules\":[{\"rule\":\"style.warn\",\"severity\":\"warning\",\"category\":\"style\",\"message\":\"Keep style tidy\"}]}" });
    const rules = try runZlintRules(allocator, context, .{ .timeout_ms = 77 });
    try std.testing.expectEqual(@as(i64, 1), rules.object.get("rule_count").?.integer);

    try store.expectResolve(.{ .path = "src/main.zig", .provenance = "static_analysis.zlint_fix_path" }, "/workspace/src/main.zig");
    const preview = try runZlintFix(allocator, context, .{
        .path = "src/main.zig",
        .rules = "style",
        .dangerous = true,
        .apply = false,
    });
    try std.testing.expect(!preview.object.get("applied").?.bool);
    try std.testing.expect(preview.object.get("dangerous").?.bool);

    try store.expectResolve(.{ .path = "src/main.zig", .provenance = "static_analysis.zlint_fix_path" }, "/workspace/src/main.zig");
    try commands.expectRun(.{
        .argv = &.{ "zlint-test", "--format", "json", "--fix", "--rules", "style", "/workspace/src/main.zig" },
        .cwd = "/workspace",
        .timeout_ms = 88,
        .provenance = "static_analysis.zlint_fix",
    }, .{ .stdout = "[{\"rule\":\"style.warn\",\"severity\":\"info\",\"path\":\"src/main.zig\",\"line\":1,\"message\":\"fixed\"}]", .stderr = "fixed one\n" });
    const applied = try runZlintFix(allocator, context, .{
        .path = "src/main.zig",
        .rules = "style",
        .apply = true,
        .timeout_ms = 88,
    });
    try std.testing.expect(applied.object.get("applied").?.bool);

    try commands.verify();
    try store.verify();
    try scanner.verify();
}

test "lint backends report failures malformed output and zwanzig command metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var commands = command_runner_fake.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var store = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer store.deinit();
    var scanner = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    const context = testStaticContext(&commands, &store, &scanner);

    try store.expectResolve(.{ .path = "bad", .provenance = "static_analysis.zlint_path" }, "/workspace/bad");
    try commands.expectRun(.{
        .argv = &.{ "zlint-test", "--format", "json", "/workspace/bad" },
        .cwd = "/workspace",
        .timeout_ms = null,
        .provenance = "static_analysis.zlint",
    }, .{ .stdout = "not json", .stderr = "\xffbad", .exit_code = 1, .term = .{ .exited = 1 }, .timed_out = true });
    const failed = try runZlintDiagnostics(allocator, context, .{ .tool_name = "zig_zlint", .path = "bad" });
    try std.testing.expectEqualStrings("command_failed", failed.object.get("error_kind").?.string);

    try store.expectResolve(.{ .path = "malformed", .provenance = "static_analysis.zlint_path" }, "/workspace/malformed");
    try commands.expectRun(.{
        .argv = &.{ "zlint-test", "--format", "json", "/workspace/malformed" },
        .cwd = "/workspace",
        .timeout_ms = null,
        .provenance = "static_analysis.zlint",
    }, .{ .stdout = "{not-json", .stderr = "backend wrote junk" });
    const malformed = try runZlintDiagnostics(allocator, context, .{ .tool_name = "zig_zlint", .path = "malformed" });
    try std.testing.expectEqualStrings("backend_output_malformed", malformed.object.get("error_kind").?.string);

    try commands.expectRunError(.{
        .argv = &.{ "zwanzig-test", "--help" },
        .cwd = "/workspace",
        .timeout_ms = 1,
        .provenance = "static_analysis.zwanzig",
    }, error.FileNotFound);
    const rules = try runZwanzigRules(allocator, context, 0);
    try std.testing.expectEqualStrings("command_error", rules.object.get("kind").?.string);
    try std.testing.expectEqualStrings("zig_lint_rules", rules.object.get("tool").?.string);

    try store.expectResolve(.{ .path = "zwanzig.json", .provenance = "static_analysis.zwanzig_config" }, "/workspace/zwanzig.json");
    try store.expectResolve(.{ .path = "src", .provenance = "static_analysis.zwanzig_path" }, "/workspace/src");
    try commands.expectRun(.{
        .argv = &.{ "zwanzig-test", "--format", "json", "--config", "/workspace/zwanzig.json", "--do", "safety", "--skip", "style", "/workspace/src", "--trace" },
        .cwd = "/workspace",
        .timeout_ms = 66,
        .provenance = "static_analysis.zwanzig",
    }, .{
        .stdout = "src/main.zig:1:1: error: bad\nsrc/main.zig:2:1: note: context\n",
        .stderr = "\xff",
        .duration_ms = 9,
        .stdout_truncated = true,
        .stderr_truncated = true,
    });
    const zwanzig = try runZwanzigLint(allocator, context, .{
        .tool_name = "zig_zwanzig_lint",
        .format = .json,
        .path = "src",
        .config = "zwanzig.json",
        .rules_do = "safety",
        .rules_skip = "style",
        .extra = &.{"--trace"},
        .timeout_ms = 66,
    });
    try std.testing.expectEqualStrings("command", zwanzig.object.get("kind").?.string);
    try std.testing.expect(zwanzig.object.get("stdout_truncated").?.bool);
    try std.testing.expect(zwanzig.object.get("failure_summary").?.object.get("suggested_tools").?.array.items.len == 0);

    try commands.verify();
    try store.verify();
    try scanner.verify();
}

test "lint planning values classify baselines suppressions trends and serialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const findings = try normalizeFindingsText(allocator,
        \\{"results":[
        \\{"code":"fmt","severity":"warning","file":"src/a.zig","line":"1","column":"2","detail":"format needed"},
        \\{"rule":"panic","severity":"error","path":"src/b.zig","line":3,"message":"panic risk"},
        \\{"rule":"info","severity":"info","path":"README.md","line":1,"message":"manual review"}
        \\]}
    , .zlint);
    const baseline = try normalizeFindingsText(allocator,
        \\[{"rule":"panic","severity":"error","path":"src/b.zig","line":3,"message":"panic risk"},{"rule":"old","severity":"warning","path":"old.zig","line":1,"message":"old"}]
    , .zlint);

    const profiles = try lintProfileValue(allocator, "advisory");
    try std.testing.expectEqual(@as(usize, 3), profiles.object.get("profiles").?.array.items.len);
    const advisory = lintProfileDefaults("advisory");
    try std.testing.expect(advisory.allow_warnings);
    const standard = lintProfileDefaults("standard");
    try std.testing.expect(standard.max_warnings == 25);

    const plan = try fixPlanValue(allocator, findings.array);
    try std.testing.expectEqual(@as(usize, 1), plan.object.get("safe").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), plan.object.get("risky").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), plan.object.get("manual").?.array.items.len);

    const base = try baselineValue(allocator, findings.array, baseline.array);
    try std.testing.expectEqual(@as(usize, 2), base.object.get("new_findings").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), base.object.get("accepted_findings").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), base.object.get("resolved_findings").?.array.items.len);

    const suppressions = try suppressionsValue(allocator, findings.array,
        \\{"findings":[{"rule":"fmt","severity":"warning","path":"src/a.zig","line":1,"message":"format needed"},{"rule":"stale","severity":"info","path":"stale.zig","line":2,"message":"gone"}]}
    );
    try std.testing.expectEqual(@as(usize, 1), suppressions.object.get("suppressed").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), suppressions.object.get("active").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), suppressions.object.get("stale_suppressions").?.array.items.len);

    const trend = try trendValue(allocator, baseline.array, findings.array);
    try std.testing.expectEqual(@as(usize, 2), trend.object.get("new_findings").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), trend.object.get("resolved_findings").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), trend.object.get("persistent_findings").?.array.items.len);

    var store = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer store.deinit();
    var commands = command_runner_fake.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var scanner = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    const expected_baseline_bytes = try serializeAlloc(allocator, base);
    try store.expectWrite(.{
        .path = ".zigar-cache/lint-baseline.json",
        .bytes = expected_baseline_bytes,
        .provenance = "static_analysis.lint_baseline",
    }, .{ .bytes_written = 1 });
    const context = testStaticContext(&commands, &store, &scanner);
    _ = try lintBaseline(allocator, context, findings.array, baseline.array, true, ".zigar-cache/lint-baseline.json");
    try store.verify();
}

test "zwanzig graph errors include command and output metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var commands = command_runner_fake.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var store = workspace_store_fake.FakeWorkspaceStore.init(std.testing.allocator);
    defer store.deinit();
    var scanner = workspace_scanner_fake.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    const context = testStaticContext(&commands, &store, &scanner);

    try store.expectResolve(.{ .path = "src/main.zig", .provenance = "static_analysis.zwanzig_graph_path" }, "/workspace/src/main.zig");
    try store.expectResolve(.{ .path = ".zigar-cache/graphs", .for_output = true, .provenance = "static_analysis.zwanzig_graph_output" }, "/workspace/.zigar-cache/graphs");
    try store.expectEnsureDir(.{ .path = ".zigar-cache/graphs", .provenance = "static_analysis.zwanzig_graph_output" }, .{});
    try commands.expectRun(.{
        .argv = &.{ "zwanzig-test", "--dump-cfg", "/workspace/.zigar-cache/graphs", "/workspace/src/main.zig", "--trace" },
        .cwd = "/workspace",
        .timeout_ms = 42,
        .provenance = "static_analysis.zwanzig_graph",
    }, .{
        .exit_code = 2,
        .term = .{ .exited = 2 },
        .stdout = "bad\xffgraph",
        .stderr = "mode unsupported",
        .stdout_truncated = true,
        .stderr_truncated = true,
    });
    const failed = try runZwanzigGraph(allocator, context, .{
        .mode = .cfg,
        .path = "src/main.zig",
        .output = ".zigar-cache/graphs",
        .extra = &.{"--trace"},
    });
    try std.testing.expect(failed == .error_value);
    const failed_value = failed.error_value;
    try std.testing.expectEqualStrings("zwanzig_graph_command_failed", failed_value.object.get("code").?.string);
    try std.testing.expectEqualStrings("zwanzig-test --dump-cfg /workspace/.zigar-cache/graphs /workspace/src/main.zig --trace", failed_value.object.get("command").?.string);
    try std.testing.expectEqual(@as(i64, 42), failed_value.object.get("timeout_ms").?.integer);
    try std.testing.expect(failed_value.object.get("stdout_invalid_utf8").?.bool);
    try std.testing.expect(failed_value.object.get("stdout_truncated").?.bool);

    try store.expectResolve(.{ .path = "src/scan.zig", .provenance = "static_analysis.zwanzig_graph_path" }, "/workspace/src/scan.zig");
    try store.expectResolve(.{ .path = ".zigar-cache/scan", .for_output = true, .provenance = "static_analysis.zwanzig_graph_output" }, "/workspace/.zigar-cache/scan");
    try store.expectEnsureDir(.{ .path = ".zigar-cache/scan", .provenance = "static_analysis.zwanzig_graph_output" }, .{});
    try commands.expectRun(.{
        .argv = &.{ "zwanzig-test", "--dump-cfg", "/workspace/.zigar-cache/scan", "/workspace/src/scan.zig" },
        .cwd = "/workspace",
        .timeout_ms = 7,
        .provenance = "static_analysis.zwanzig_graph",
    }, .{});
    try store.expectScanDirectoryError(.{
        .path = ".zigar-cache/scan",
        .suffix = ".dot",
        .provenance = "static_analysis.zwanzig_graph_verify",
    }, error.AccessDenied);
    const inspect_failed = try runZwanzigGraph(allocator, context, .{
        .mode = .cfg,
        .path = "src/scan.zig",
        .output = ".zigar-cache/scan",
        .timeout_ms = 7,
    });
    try std.testing.expect(inspect_failed == .error_value);
    const inspect_value = inspect_failed.error_value;
    try std.testing.expectEqualStrings("inspect_output_directory", inspect_value.object.get("phase").?.string);
    try std.testing.expectEqualStrings("permission", inspect_value.object.get("error_kind").?.string);

    try store.expectResolve(.{ .path = "src/empty.zig", .provenance = "static_analysis.zwanzig_graph_path" }, "/workspace/src/empty.zig");
    try store.expectResolve(.{ .path = ".zigar-cache/empty", .for_output = true, .provenance = "static_analysis.zwanzig_graph_output" }, "/workspace/.zigar-cache/empty");
    try store.expectEnsureDir(.{ .path = ".zigar-cache/empty", .provenance = "static_analysis.zwanzig_graph_output" }, .{});
    try commands.expectRun(.{
        .argv = &.{ "zwanzig-test", "--dump-cfg", "/workspace/.zigar-cache/empty", "/workspace/src/empty.zig" },
        .cwd = "/workspace",
        .timeout_ms = 9,
        .provenance = "static_analysis.zwanzig_graph",
    }, .{});
    try store.expectScanDirectory(.{
        .path = ".zigar-cache/empty",
        .suffix = ".dot",
        .provenance = "static_analysis.zwanzig_graph_verify",
    }, &.{});
    const missing = try runZwanzigGraph(allocator, context, .{
        .mode = .cfg,
        .path = "src/empty.zig",
        .output = ".zigar-cache/empty",
        .timeout_ms = 9,
    });
    try std.testing.expect(missing == .error_value);
    const missing_value = missing.error_value;
    try std.testing.expectEqualStrings("backend_output_malformed", missing_value.object.get("code").?.string);
    try std.testing.expectEqualStrings(".zigar-cache/empty", missing_value.object.get("output").?.string);

    try commands.verify();
    try store.verify();
    try scanner.verify();
}

test "lint helper edge branches normalize fallback values and command insight metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const no_findings = try normalizeFindingsText(allocator, "42", .zlint);
    try std.testing.expectEqual(@as(usize, 0), no_findings.array.items.len);

    var finding_obj = std.json.ObjectMap.empty;
    try finding_obj.put(allocator, "rule", .{ .string = "style.note" });
    try finding_obj.put(allocator, "severity", .{ .string = "info" });
    const sarif = try sarifFindingValue(allocator, .{ .object = finding_obj });
    try std.testing.expectEqualStrings("note", sarif.object.get("level").?.string);

    const fingerprint = try fingerprintValue(allocator, .{ .object = finding_obj });
    try std.testing.expectEqualStrings("unknown:style.note:unknown:0:", fingerprint.string);
    try std.testing.expectEqualStrings("", comparisonKey(.null));
    try std.testing.expectEqualStrings("", severityOf(.{ .bool = false }));

    var numbered = std.json.ObjectMap.empty;
    try numbered.put(allocator, "line", .{ .number_string = "17" });
    try numbered.put(allocator, "bad", .{ .number_string = "nan" });
    try std.testing.expectEqual(@as(i64, 17), integerField(numbered, "line").?);
    try std.testing.expect(integerField(numbered, "bad") == null);

    const warning_insights = try compilerInsightsValue(allocator, "", "src/warn.zig:3:2: warning: expected optional\n", &.{ "zig", "build" });
    try std.testing.expectEqual(@as(i64, 1), warning_insights.object.get("warning_count").?.integer);
    try std.testing.expectEqualStrings("zig ast-check src/warn.zig", warning_insights.object.get("next_command").?.string);

    const plain_command = try compilerNextCommand(allocator, .{
        .severity = "warning",
        .path = "README.md",
        .message = "review docs",
        .raw = "README.md: warning: review docs",
    }, &.{ "zig", "build" });
    try std.testing.expectEqualStrings("zig build", plain_command.string);

    const global_actions = try compilerNextActions(allocator, .{
        .severity = "warning",
        .path = null,
        .message = "global warning",
        .raw = "warning: global warning",
    }, 0);
    try std.testing.expect(std.mem.startsWith(u8, global_actions.array.items[0].string, "Address the primary warning"));

    const plain_summary = try failureSummaryValue(allocator, .null, false, &.{ "zig", "build" });
    try std.testing.expect(plain_summary.object.get("primary").? == .null);
    const path_scope = try likelyFailureScopeValue(allocator, .{ .object = blk: {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "path", .{ .string = "README.md" });
        break :blk obj;
    } });
    try std.testing.expectEqualStrings("path:README.md", path_scope.string);

    try std.testing.expectEqual(@as(u64, 42), commandTimeout(.{
        .workspace = .{ .root = "/workspace" },
        .timeouts = .{ .command_ms = 42 },
        .workspace_store = undefined,
        .workspace_scanner = undefined,
    }, null));

    const signal_term = try commandTermValue(allocator, .signal);
    const stopped_term = try commandTermValue(allocator, .stopped);
    const unknown_term = try commandTermValue(allocator, .unknown);
    try std.testing.expectEqualStrings("signal", signal_term.object.get("kind").?.string);
    try std.testing.expectEqualStrings("stopped", stopped_term.object.get("kind").?.string);
    try std.testing.expectEqualStrings("unknown", unknown_term.object.get("kind").?.string);
}

test "lint serializers and safe text handle lossy bytes and escaped JSON primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lossy = try safeTextAlloc(allocator, "a\xff\xe2\x82\xac\xe2");
    try std.testing.expect(lossy.invalid_utf8);
    try std.testing.expectEqual(@as(usize, 6), lossy.byte_count);
    try std.testing.expect(std.mem.indexOf(u8, lossy.text, &std.unicode.replacement_character_utf8) != null);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try serializeValue(allocator, &out, .null);
    try out.append(allocator, ' ');
    try serializeValue(allocator, &out, .{ .bool = true });
    try out.append(allocator, ' ');
    try serializeValue(allocator, &out, .{ .float = 1.5 });
    try out.append(allocator, ' ');
    try serializeValue(allocator, &out, .{ .number_string = "27" });
    try std.testing.expectEqualStrings("null true 1.5 27", out.items);

    const escaped = try serializeAlloc(allocator, .{ .string = "\"\\\n\r\t\x01" });
    try std.testing.expectEqualStrings("\"\\\"\\\\\\n\\r\\t\\u0001\"", escaped);
}

test "lint builders and temporary buffers clean up after allocator failure" {
    var argv_buf: [1]u8 = undefined;
    var zlint_fba = std.heap.FixedBufferAllocator.init(&argv_buf);
    try std.testing.expectError(error.OutOfMemory, buildZlintArgv(zlint_fba.allocator(), .{
        .executable = "zlint",
        .path = "src",
        .config = "zlint.json",
        .rules = "style",
        .extra = &.{"--extra"},
    }));

    var fix_fba = std.heap.FixedBufferAllocator.init(&argv_buf);
    try std.testing.expectError(error.OutOfMemory, buildZlintFixArgv(fix_fba.allocator(), .{
        .executable = "zlint",
        .path = "src",
        .config = "zlint.json",
        .rules = "style",
        .extra = &.{"--extra"},
    }, true));

    var lint_fba = std.heap.FixedBufferAllocator.init(&argv_buf);
    try std.testing.expectError(error.OutOfMemory, buildZwanzigLintArgv(lint_fba.allocator(), .{
        .executable = "zwanzig",
        .format = .json,
        .path = "src",
        .config = "zwanzig.json",
        .rules_do = "safety",
        .rules_skip = "style",
        .extra = &.{"--extra"},
    }));

    var graph_fba = std.heap.FixedBufferAllocator.init(&argv_buf);
    try std.testing.expectError(error.OutOfMemory, buildZwanzigGraphArgv(graph_fba.allocator(), .{
        .executable = "zwanzig",
        .mode = .cfg,
        .source_path = "src/main.zig",
        .output_dir = ".zigar-cache/graphs",
        .extra = &.{"--extra"},
    }));

    var text_buf: [2]u8 = undefined;
    var text_fba = std.heap.FixedBufferAllocator.init(&text_buf);
    try std.testing.expectError(error.OutOfMemory, safeTextAlloc(text_fba.allocator(), "\xff"));

    var command_buf: [2]u8 = undefined;
    var command_fba = std.heap.FixedBufferAllocator.init(&command_buf);
    try std.testing.expectError(error.OutOfMemory, commandString(command_fba.allocator(), &.{ "zig", "build" }));

    var serialize_buf: [1]u8 = undefined;
    var serialize_fba = std.heap.FixedBufferAllocator.init(&serialize_buf);
    try std.testing.expectError(error.OutOfMemory, serializeAlloc(serialize_fba.allocator(), .{ .string = "long" }));
}

/// Implements test static context workflow logic using caller-owned inputs.
fn testStaticContext(
    commands: *command_runner_fake.FakeCommandRunner,
    store: *workspace_store_fake.FakeWorkspaceStore,
    scanner: *workspace_scanner_fake.FakeWorkspaceScanner,
) app_context.StaticAnalysisContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .tool_paths = .{ .zlint = "zlint-test", .zwanzig = "zwanzig-test" },
        .timeouts = .{ .command_ms = 42 },
        .command_runner = commands.port(),
        .workspace_store = store.port(),
        .workspace_scanner = scanner.port(),
    };
}
