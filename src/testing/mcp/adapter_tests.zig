//! Integration fixture covering the MCP adapter contract surface:
//! argument validation, schema shape, catalog/registry consistency,
//! discovery tool outputs (zigars_schema, zig_command_plan, zig_tool_plan,
//! zigars_toolchain_resolve), structured error fields, and static analysis
//! helpers used across tool handlers.

const std = @import("std");
const zigars = @import("../../root.zig");

const analysis = zigars.domain.zig.analysis;
const catalog = zigars.manifest.tool_catalog_render;
const command = zigars.infra.process.command;
const json_result = zigars.adapters.mcp.result;
const mcp_schema = zigars.adapters.mcp.schema;
const manifest_metadata = zigars.manifest;
const tool_registry = zigars.adapters.mcp.registry;
const tooling = zigars.manifest.tooling;

const mcp_core = zigars.adapters.mcp.core;
const mcp_static_source_summary = zigars.adapters.mcp.static_source_summary;
const usecase_support = zigars.app.usecases.usecase_support;
const app_context = zigars.app.context;
const project_values = zigars.app.usecases.static_analysis.project_values;
const ci_evidence = zigars.app.usecases.release.ci_evidence;
const fake_command = @import("../fakes/command_runner.zig");
const fake_workspace = @import("../fakes/workspace_store.zig");
const tool_test_support = @import("../mcp_tool_test_support.zig");

const App = tool_test_support.App;
const workspacePathErrorMessage = usecase_support.workspacePathErrorMessage;
const commandErrorValue = usecase_support.commandErrorValue;
const backendErrorValue = usecase_support.backendErrorValue;
const parseCompilerLine = usecase_support.parseCompilerLine;
const classifyDiagnosticMessage = usecase_support.classifyDiagnosticMessage;
const appendPatchPaths = usecase_support.appendPatchPaths;
const stringListContains = usecase_support.stringListContains;
const failureSummaryValue = usecase_support.failureSummaryValue;
const compilerInsightsValue = usecase_support.compilerInsightsValue;
const statusLinePath = usecase_support.statusLinePath;
const mcp_discovery = zigars.adapters.mcp.discovery;
const discovery_workflows = zigars.app.usecases.discovery.workflows;
const zigarsSchema = mcp_discovery.zigarsSchema;
const zigCommandPlan = mcp_discovery.zigCommandPlan;
const zigToolPlan = mcp_discovery.zigToolPlan;
const zigToolchainResolve = mcp_discovery.zigToolchainResolve;
const ZigVersionHintStatus = discovery_workflows.ZigVersionHintStatus;
const zigVersionHintStatus = discovery_workflows.zigVersionHintStatus;
const versionMeetsMinimum = discovery_workflows.versionMeetsMinimum;
const parseVersionPrefix = discovery_workflows.parseVersionPrefix;
const compilerErrorIndexValue = mcp_core.compilerErrorIndexValue;
const testAppForCommandPlanning = tool_test_support.appForCommandPlanning;
const zigExplainErrors = tool_test_support.zigExplainErrors;
const zigCompileErrorIndex = tool_test_support.zigCompileErrorIndex;
const zigarsFailureFusion = tool_test_support.zigarsFailureFusion;
const zigTargetMatrixPlan = tool_test_support.zigTargetMatrixPlan;
const zigPublicApiDiff = tool_test_support.zigPublicApiDiff;
const xmlEscape = ci_evidence.xmlEscape;
const ownerVarName = project_values.ownerVarName;
const buildNameFromCall = project_values.buildNameFromCall;
const buildPathFromLine = project_values.buildPathFromLine;
const dependencyNameFromLine = project_values.dependencyNameFromLine;
const optionNameFromLine = project_values.optionNameFromLine;
const optionTypeFromLine = project_values.optionTypeFromLine;
const quotedString = project_values.quotedString;
const relativeImportCandidate = project_values.relativeImportCandidate;
const dependencyBlockNameFromLine = project_values.dependencyBlockNameFromLine;
const declName = project_values.declName;
const targetMatrixNote = project_values.targetMatrixNote;
const testNameFromLine = project_values.testNameFromLine;
const publicApiDiffValue = project_values.publicApiDiffValue;

test "schema with required field" {
    var s = try mcp_schema.buildInputSchema(std.testing.allocator, tooling.schema(&.{.{ "file", "string", true }}));
    defer if (s.required) |required| std.testing.allocator.free(required);
    defer if (s.properties) |*properties| {
        var it = properties.object.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.object.deinit(std.testing.allocator);
        }
        properties.object.deinit(std.testing.allocator);
    };
    try std.testing.expectEqualStrings("object", s.type);
}

test "workspace path error messages distinguish empty and outside paths" {
    const allocator = std.testing.allocator;
    const empty = try workspacePathErrorMessage(allocator, "zig_check", "", "/tmp/workspace", error.EmptyPath);
    defer allocator.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "empty path") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, "/tmp/workspace") != null);

    const outside = try workspacePathErrorMessage(allocator, "zig_check", "../x.zig", "/tmp/workspace", error.PathOutsideWorkspace);
    defer allocator.free(outside);
    try std.testing.expect(std.mem.indexOf(u8, outside, "../x.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, outside, "outside the configured") != null);
}

test "capabilities index exposes formatting discovery keywords" {
    const body = try catalog.text(std.testing.allocator);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"zig_format\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"zig_format_check\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"zigars_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"zigars_doctor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"fmt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"formatter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"zig fmt\"") != null);
}

test "catalog groups match tool registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try catalog.parsed(allocator);

    const root = parsed.value.object;
    const groups = root.get("groups").?.array;
    const tool_arguments = root.get("registry_tool_arguments").?.object;

    var grouped_count: usize = 0;
    for (groups.items) |group_value| {
        const tools = group_value.object.get("tools").?.array;
        for (tools.items) |tool_value| {
            const tool_name = tool_value.string;
            grouped_count += 1;
            try std.testing.expect(manifest_metadata.find(tool_name) != null);
            if (manifest_metadata.find(tool_name)) |spec| {
                if (spec.input_schema.fields.len > 0) {
                    try std.testing.expect(tool_arguments.get(tool_name) != null);
                }
            }
        }
    }
    try std.testing.expectEqual(manifest_metadata.specs.len, grouped_count);
}

test "registry catalog arguments can be derived from tool registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try catalog.parsed(arena.allocator());

    const tool_arguments = parsed.value.object.get("registry_tool_arguments").?.object;
    const zig_format = tool_arguments.get("zig_format").?.object;
    try std.testing.expectEqualStrings("string", zig_format.get("required").?.object.get("file").?.string);
    try std.testing.expectEqualStrings("boolean", zig_format.get("optional").?.object.get("apply").?.string);
    try std.testing.expectEqualStrings("high", zig_format.get("risk").?.object.get("level").?.string);
    try std.testing.expect(zig_format.get("risk").?.object.get("writes_source").?.bool);
    try std.testing.expect(zig_format.get("risk").?.object.get("writes_artifacts").?.bool);
    try std.testing.expect(zig_format.get("risk").?.object.get("writes_require_apply").?.bool);
    try std.testing.expect(zig_format.get("risk").?.object.get("preview_by_default").?.bool);
    const profile_run = tool_arguments.get("zig_profile_run").?.object;
    try std.testing.expect(profile_run.get("risk").?.object.get("executes_user_command").?.bool);
    const matrix_check = tool_arguments.get("zig_matrix_check").?.object;
    try std.testing.expect(matrix_check.get("risk").?.object.get("executes_user_command").?.bool);
    const validate_patch = tool_arguments.get("zigars_validate_patch").?.object;
    try std.testing.expectEqualStrings("medium", validate_patch.get("risk").?.object.get("level").?.string);
    try std.testing.expect(validate_patch.get("risk").?.object.get("executes_project_code").?.bool);
    try std.testing.expect(validate_patch.get("risk").?.object.get("writes_artifacts").?.bool);
}

test "zigars_schema exposes registry-derived risk metadata" {
    const allocator = std.testing.allocator;
    var app = try testAppForCommandPlanning(allocator);
    defer app.workspace.deinit();
    var runtime_ports = zigars.bootstrap.runtime_ports.RuntimePorts.init(&app, .{});
    const result = try zigarsSchema(allocator, runtime_ports.context(), null);
    const body = result.content[0].text.text;
    defer json_result.deinitToolResult(allocator, result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("registry_tool_arguments").?.object;
    const validate_patch = args.get("zigars_validate_patch").?.object;
    try std.testing.expect(validate_patch.get("risk").?.object.get("executes_project_code").?.bool);
}

test "zig_command_plan exposes registry risk metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testAppForCommandPlanning(allocator);
    var runtime_ports = zigars.bootstrap.runtime_ports.RuntimePorts.init(&app, .{ .workspace_read_resolution = .input });

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "tool", .{ .string = "zig_test" });
    const result = try zigCommandPlan(allocator, runtime_ports.context(), .{ .object = args });
    const body = result.content[0].text.text;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    const root = parsed.value.object;
    const risk = root.get("risk").?.object;

    try std.testing.expectEqualStrings("zig_test", root.get("tool").?.string);
    try std.testing.expect(root.get("supported").?.bool);
    try std.testing.expectEqualStrings("exact_command", root.get("plan_kind").?.string);
    try std.testing.expect(root.get("argv_exact").?.bool);
    try std.testing.expectEqualStrings("medium", root.get("risk_level").?.string);
    try std.testing.expectEqualStrings("medium", risk.get("level").?.string);
    try std.testing.expect(risk.get("executes_project_code").?.bool);
    try std.testing.expect(risk.get("writes_artifacts").?.bool);
    try std.testing.expect(!root.get("writes_source").?.bool);
}

test "zig_command_plan reports known non-command tools without invalid argument errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testAppForCommandPlanning(allocator);
    var runtime_ports = zigars.bootstrap.runtime_ports.RuntimePorts.init(&app, .{ .workspace_read_resolution = .input });

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "tool", .{ .string = "zig_hover" });
    const result = try zigCommandPlan(allocator, runtime_ports.context(), .{ .object = args });
    const body = result.content[0].text.text;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("zig_hover", root.get("tool").?.string);
    try std.testing.expect(!root.get("supported").?.bool);
    try std.testing.expectEqualStrings("zls_request", root.get("plan_kind").?.string);
    try std.testing.expectEqualStrings("zig_tool_plan", root.get("use").?.string);
    const supported_tools = root.get("supported_tools").?.array;
    try std.testing.expect(jsonArrayContainsString(supported_tools, "zig_build"));
    try std.testing.expect(jsonArrayContainsString(supported_tools, "zig_format_check"));
}

test "zig_tool_plan exposes broad planning support for ZLS tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testAppForCommandPlanning(allocator);
    var runtime_ports = zigars.bootstrap.runtime_ports.RuntimePorts.init(&app, .{ .workspace_read_resolution = .input });

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "tool", .{ .string = "zig_hover" });
    const result = try zigToolPlan(allocator, runtime_ports.context(), .{ .object = args });
    const body = result.content[0].text.text;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("zig_tool_plan", root.get("kind").?.string);
    try std.testing.expectEqualStrings("zig_hover", root.get("tool").?.string);
    try std.testing.expect(root.get("supported").?.bool);
    try std.testing.expectEqualStrings("zls_request", root.get("plan_kind").?.string);
    try std.testing.expectEqualStrings("zls", root.get("backend").?.string);
    try std.testing.expectEqualStrings("textDocument/hover", root.get("method").?.string);
    try std.testing.expect(root.get("requires_document_sync").?.bool);
}

/// Checks whether a JSON array contains the requested string value.
fn jsonArrayContainsString(array: std.json.Array, needle: []const u8) bool {
    // Keep this logic centralized so callers observe one consistent behavior path.
    for (array.items) |item| {
        switch (item) {
            .string => |value| if (std.mem.eql(u8, value, needle)) return true,
            else => {},
        }
    }
    return false;
}

test "json array string helper reports absent values" {
    var array = std.json.Array.init(std.testing.allocator);
    defer array.deinit();
    try array.append(.{ .string = "present" });
    try std.testing.expect(!jsonArrayContainsString(array, "missing"));
}

test "explain command setup errors use the calling tool name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testAppForCommandPlanning(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "command", .{ .string = "check" });
    try args.put(allocator, "file", .{ .string = "/zigars-outside-workspace.zig" });

    const explain = try zigExplainErrors(&app, allocator, .{ .object = args });
    try std.testing.expect(std.mem.indexOf(u8, explain.content[0].text.text, "zig_explain_errors") != null);

    const index = try zigCompileErrorIndex(&app, allocator, .{ .object = args });
    try std.testing.expect(std.mem.indexOf(u8, index.content[0].text.text, "zig_compile_error_index") != null);

    const fusion = try zigarsFailureFusion(&app, allocator, .{ .object = args });
    try std.testing.expect(std.mem.indexOf(u8, fusion.content[0].text.text, "zigars_failure_fusion") != null);
}

test "catalog derives compact argument hints from registry metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed_catalog = try catalog.parsed(arena.allocator());
    const tool_arguments = parsed_catalog.value.object.get("registry_tool_arguments").?.object;
    const zig_format = tool_arguments.get("zig_format").?.object;
    try std.testing.expectEqualStrings("string", zig_format.get("required").?.object.get("file").?.string);
    try std.testing.expectEqualStrings("boolean", zig_format.get("optional").?.object.get("apply").?.string);
    const doctor_args = tool_arguments.get("zigars_doctor").?.object.get("optional").?.object;
    try std.testing.expectEqualStrings("boolean", doctor_args.get("probe_backends").?.string);
}

test "tool argument validation returns structured errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const spec = manifest_metadata.find("zig_check").?;

    const missing_obj = std.json.ObjectMap.empty;
    const missing = try tool_registry.validateToolArgs(allocator, spec, .{ .object = missing_obj });
    try std.testing.expect(missing != null);
    const missing_error = missing.?.structuredContent.?.object;
    try std.testing.expectEqualStrings("argument_error", missing_error.get("kind").?.string);
    try std.testing.expectEqualStrings("missing_required_argument", missing_error.get("code").?.string);
    try std.testing.expectEqualStrings("file", missing_error.get("field").?.string);

    var wrong_type_obj = std.json.ObjectMap.empty;
    try wrong_type_obj.put(allocator, "file", .{ .integer = 42 });
    const wrong_type = try tool_registry.validateToolArgs(allocator, spec, .{ .object = wrong_type_obj });
    try std.testing.expect(wrong_type != null);
    const wrong_type_error = wrong_type.?.structuredContent.?.object;
    try std.testing.expectEqualStrings("argument_error", wrong_type_error.get("kind").?.string);
    try std.testing.expectEqualStrings("invalid_type", wrong_type_error.get("code").?.string);
    try std.testing.expectEqualStrings("string", wrong_type_error.get("expected").?.string);
    try std.testing.expectEqualStrings("integer", wrong_type_error.get("actual").?.string);

    var valid_obj = std.json.ObjectMap.empty;
    try valid_obj.put(allocator, "file", .{ .string = "src/main.zig" });
    try std.testing.expect((try tool_registry.validateToolArgs(allocator, spec, .{ .object = valid_obj })) == null);
}

test "toolchain resolver defaults to cheap manager checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRun(.{
        .argv = &.{ "zig", "version" },
        .cwd = "/tmp",
        .timeout_ms = 30_000,
        .provenance = "discovery.toolchain_resolve.zig",
    }, .{ .stdout = "0.16.0\n" });
    try commands.expectRun(.{
        .argv = &.{ "zls", "--version" },
        .cwd = "/tmp",
        .timeout_ms = 30_000,
        .provenance = "discovery.toolchain_resolve.zls",
    }, .{ .stdout = "0.16.0\n" });
    try workspace.expectReadError(.{ .path = ".zigversion", .max_bytes = 64 * 1024, .provenance = "discovery.version_hint" }, error.FileNotFound);
    try workspace.expectReadError(.{ .path = ".tool-versions", .max_bytes = 64 * 1024, .provenance = "discovery.tool_versions_hint" }, error.FileNotFound);
    try workspace.expectReadError(.{ .path = "mise.toml", .max_bytes = 128 * 1024, .provenance = "discovery.mise_hint" }, error.FileNotFound);
    try workspace.expectReadError(.{ .path = "build.zig.zon", .max_bytes = 256 * 1024, .provenance = "discovery.build_zon_hint" }, error.FileNotFound);

    const context = app_context.Context{
        .workspace = .{ .root = "/tmp", .cache_root = "/tmp/.zigars-cache" },
        .tool_paths = .{ .zig = "zig", .zls = "zls" },
        .timeouts = .{},
        .ports = .{ .command_runner = commands.port(), .workspace = workspace.port() },
    };
    const result = try zigToolchainResolve(allocator, context, null);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.content[0].text.text, .{});
    const managers = parsed.value.object.get("managers").?.array;
    try std.testing.expect(managers.items.len > 0);
    const first = managers.items[0].object;
    try std.testing.expect(first.get("available").? == .null);
    try std.testing.expect(first.get("version_output").? == .null);
    try commands.verify();
    try workspace.verify();
}

test "command error value declares output limit policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try commandErrorValue(arena.allocator(), "large command", &.{ "zig", "build" }, "/tmp/project", 1000, error.StreamTooLong);
    const obj = value.object;
    try std.testing.expectEqualStrings("command_error", obj.get("kind").?.string);
    try std.testing.expectEqualStrings(command.output_limit_mode, obj.get("output_limit_mode").?.string);
    try std.testing.expect(obj.get("output_limit_exceeded").?.bool);
    try std.testing.expect(obj.get("note") != null);
}

test "backend error value uses stable structured fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try backendErrorValue(arena.allocator(), "zls", "textDocument/hover", error.RequestTimeout, "retry later");
    const obj = value.object;
    try std.testing.expectEqualStrings("backend_error", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("zls", obj.get("backend").?.string);
    try std.testing.expectEqualStrings("textDocument/hover", obj.get("operation").?.string);
    try std.testing.expectEqualStrings("timeout", obj.get("error_kind").?.string);
}

test "skipWorkspacePath ignores generated and vendored paths" {
    try std.testing.expect(analysis.skipWorkspacePath(".zig-cache/o/main.zig"));
    try std.testing.expect(analysis.skipWorkspacePath(".zigars-cache/profile/main.zig"));
    try std.testing.expect(analysis.skipWorkspacePath("zig-out/bin/main.zig"));
    try std.testing.expect(analysis.skipWorkspacePath("zig-pkg/mcp/src/main.zig"));
    try std.testing.expect(!analysis.skipWorkspacePath("src/main.zig"));
}

test "xmlEscape keeps junit output well formed" {
    const escaped = try xmlEscape(std.testing.allocator, "a<b>&\"'");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("a&lt;b&gt;&amp;&quot;&apos;", escaped);
}

test "json serialization emits strings for byte-backed text and escapes controls" {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(std.testing.allocator);
    const bytes = try std.testing.allocator.dupe(u8, "a\x1bb");
    defer std.testing.allocator.free(bytes);
    try obj.put(std.testing.allocator, "text", .{ .string = bytes });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try json_result.serializeValue(std.testing.allocator, &out, .{ .object = obj });
    try std.testing.expectEqualStrings("{\"text\":\"a\\u001bb\"}", out.items);
}

test "parseCompilerLine extracts located Zig errors" {
    const parsed = parseCompilerLine("src/main.zig:12:5: error: expected type 'u8', found 'u16'") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("error", parsed.severity);
    try std.testing.expectEqualStrings("src/main.zig", parsed.path.?);
    try std.testing.expectEqual(@as(i64, 12), parsed.line.?);
    try std.testing.expectEqual(@as(i64, 5), parsed.column.?);
    try std.testing.expectEqualStrings("type_mismatch", classifyDiagnosticMessage(parsed.message));
}

test "parseCompilerLine handles unlocated compiler errors" {
    const parsed = parseCompilerLine("error: the following command failed with 1 compilation errors") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("error", parsed.severity);
    try std.testing.expect(parsed.path == null);
    try std.testing.expectEqualStrings("the following command failed with 1 compilation errors", parsed.message);
}

test "build metadata helpers parse common build.zig patterns" {
    try std.testing.expectEqualStrings("exe", ownerVarName("const exe = b.addExecutable(.{").?);
    try std.testing.expectEqualStrings("test", buildNameFromCall("const test_step = b.step(\"test\", \"Run tests\");").?);
    try std.testing.expectEqualStrings("src/main.zig", buildPathFromLine(".root_source_file = b.path(\"src/main.zig\"),").?);
    try std.testing.expectEqualStrings("mcp", dependencyNameFromLine(".mcp = .{").?);
    try std.testing.expectEqualStrings("target", optionNameFromLine("const t = b.option([]const u8, \"target\", \"Target\");").?);
    try std.testing.expectEqualStrings("[]const u8", optionTypeFromLine("const t = b.option([]const u8, \"target\", \"Target\");").?);
    try std.testing.expectEqualStrings("zigars", quotedString(".name = \"zigars\",").?);
}

test "relativeImportCandidate resolves beside source file" {
    const candidate = try relativeImportCandidate(std.testing.allocator, "src/root.zig", "config.zig");
    defer std.testing.allocator.free(candidate);
    try std.testing.expectEqualStrings("src/config.zig", candidate);
}

test "new planning helpers parse stable text formats" {
    try std.testing.expectEqualStrings("src/new.zig", statusLinePath("R  src/old.zig -> src/new.zig"));
    try std.testing.expectEqualStrings("src/main.zig", statusLinePath(" M src/main.zig"));
    try std.testing.expectEqualStrings("mcp", dependencyBlockNameFromLine(".mcp = .{").?);
    try std.testing.expect(dependencyBlockNameFromLine(".url = \"https://example\"") == null);
    try std.testing.expectEqualStrings("main", declName("pub fn main() void {}", "fn").?);
    try std.testing.expect(std.mem.indexOf(u8, targetMatrixNote("wasm32-freestanding"), "freestanding") != null);
}

test "toolchain version helpers distinguish minimum hints from exact pins" {
    try std.testing.expect(versionMeetsMinimum("0.16.0", "0.15.1"));
    try std.testing.expect(versionMeetsMinimum("0.16.0-dev.732+abc", "0.16.0"));
    try std.testing.expect(!versionMeetsMinimum("0.15.0", "0.16.0"));
    try std.testing.expect(parseVersionPrefix("master") == null);

    var minimum_hint = std.json.ObjectMap.empty;
    defer minimum_hint.deinit(std.testing.allocator);
    try minimum_hint.put(std.testing.allocator, "key", .{ .string = "minimum_zig_version" });
    try minimum_hint.put(std.testing.allocator, "version", .{ .string = "0.16.0" });
    try std.testing.expectEqual(ZigVersionHintStatus.minimum_satisfied, zigVersionHintStatus("0.16.1", minimum_hint));

    var zls_hint = std.json.ObjectMap.empty;
    defer zls_hint.deinit(std.testing.allocator);
    try zls_hint.put(std.testing.allocator, "key", .{ .string = "zls" });
    try zls_hint.put(std.testing.allocator, "version", .{ .string = "0.16.0" });
    try std.testing.expectEqual(ZigVersionHintStatus.ignored, zigVersionHintStatus("0.16.0", zls_hint));
}

test "compiler error index groups findings by file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try compilerErrorIndexValue(arena.allocator(), "src/main.zig:1:2: error: bad\nsrc/main.zig:1:2: note: detail\n", "", &.{"zig"});
    const obj = value.object;
    try std.testing.expectEqualStrings("zig_compile_error_index", obj.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("summary").?.object.get("error_count").?.integer);
    try std.testing.expectEqual(@as(usize, 1), obj.get("files").?.array.items.len);
}

test "agent workflow helpers parse patch paths and test names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("Foo.init handles defaults", testNameFromLine("test \"Foo.init handles defaults\" {").?);

    var paths = std.ArrayList([]const u8).empty;
    try appendPatchPaths(allocator, &paths,
        \\diff --git a/src/old.zig b/src/new.zig
        \\--- a/src/old.zig
        \\+++ b/src/new.zig
        \\
    );
    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    try std.testing.expect(stringListContains(paths.items, "src/old.zig"));
    try std.testing.expect(stringListContains(paths.items, "src/new.zig"));
}

test "public api diff value detects breaking removal and additions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try publicApiDiffValue(arena.allocator(), "src/api.zig",
        \\pub fn oldName() void {}
        \\pub const Same = struct {};
        \\
    ,
        \\pub fn newName() void {}
        \\pub const Same = struct {};
        \\
    );
    const obj = value.object;
    try std.testing.expectEqualStrings("zig_public_api_diff", obj.get("kind").?.string);
    try std.testing.expect(obj.get("breaking_change_risk").?.bool);
    try std.testing.expectEqual(@as(usize, 1), obj.get("removed").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), obj.get("added").?.array.items.len);
}

test "parser-backed static analysis result releases temporary JSON tree" {
    const allocator = std.testing.allocator;
    var summary = try analysis.parseSourceSummary(allocator, "fixture.zig", "pub const Fixture = struct { pub fn run() void {} };");
    defer summary.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try mcp_static_source_summary.astDeclSummaryValue(arena.allocator(), "fixture.zig", summary);
    const result = try zigars.adapters.mcp.result.structured(allocator, value);
    defer json_result.deinitToolResult(allocator, result);

    const structured = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("parser_backed", structured.get("capability_tier").?.string);
    try std.testing.expectEqualStrings("zig_ast_decl_summary", structured.get("kind").?.string);
}

test "static core handler releases temporary JSON tree" {
    const allocator = std.testing.allocator;
    var app = try testAppForCommandPlanning(allocator);
    defer app.workspace.deinit();
    var args = std.json.ObjectMap.empty;
    defer args.deinit(allocator);
    try args.put(allocator, "targets", .{ .string = "native x86_64-linux-gnu" });
    try args.put(allocator, "steps", .{ .string = "test" });

    const result = try zigTargetMatrixPlan(&app, allocator, .{ .object = args });
    defer json_result.deinitToolResult(allocator, result);

    const structured = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zig_target_matrix_plan", structured.get("kind").?.string);
    try std.testing.expectEqualStrings("advisory_orientation", structured.get("capability_tier").?.string);
}

test "static tests handler releases temporary JSON tree" {
    const allocator = std.testing.allocator;
    var app = try testAppForCommandPlanning(allocator);
    defer app.workspace.deinit();
    var args = std.json.ObjectMap.empty;
    defer args.deinit(allocator);
    try args.put(allocator, "before", .{ .string = "pub fn oldName() void {}\n" });
    try args.put(allocator, "after", .{ .string = "pub fn newName() void {}\n" });

    const result = try zigPublicApiDiff(&app, allocator, .{ .object = args });
    defer json_result.deinitToolResult(allocator, result);

    const structured = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zig_public_api_diff", structured.get("kind").?.string);
    try std.testing.expect(structured.get("breaking_change_risk").?.bool);
}

test "failure summary suggests agent diagnostic tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const insights = try compilerInsightsValue(allocator, "", "src/main.zig:1:2: error: expected type 'u8', found 'u16'\n", &.{ "zig", "build" });
    const summary = try failureSummaryValue(allocator, insights, false, &.{ "zig", "build" });
    const obj = summary.object;
    try std.testing.expectEqualStrings("type_mismatch", obj.get("error_class").?.string);
    try std.testing.expectEqualStrings("source_file", obj.get("likely_scope").?.string);
    try std.testing.expect(obj.get("suggested_tools").?.array.items.len >= 2);
}
