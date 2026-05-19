const std = @import("std");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const catalog = zigar.catalog;
const command = zigar.command;
const json_result = zigar.json_result;
const tool_metadata = zigar.tool_metadata;
const tool_registry = zigar.tool_registry;
const tooling = zigar.tooling;
const workspace_mod = zigar.workspace;

const common = @import("tools/common.zig");
const discovery = @import("tools/discovery.zig");
const agent = @import("tools/agent.zig");
const core = @import("tools/core.zig");
const static_analysis = @import("tools/static_analysis.zig");
const ci = @import("tools/ci.zig");

const App = common.App;
const workspacePathErrorMessage = common.workspacePathErrorMessage;
const commandErrorValue = common.commandErrorValue;
const backendErrorValue = common.backendErrorValue;
const parseCompilerLine = common.parseCompilerLine;
const classifyDiagnosticMessage = common.classifyDiagnosticMessage;
const appendPatchPaths = common.appendPatchPaths;
const stringListContains = common.stringListContains;
const failureSummaryValue = common.failureSummaryValue;
const compilerInsightsValue = common.compilerInsightsValue;
const statusLinePath = common.statusLinePath;
const zigarSchema = discovery.zigarSchema;
const zigCommandPlan = discovery.zigCommandPlan;
const zigToolPlan = discovery.zigToolPlan;
const zigToolchainResolve = discovery.zigToolchainResolve;
const ZigVersionHintStatus = discovery.ZigVersionHintStatus;
const zigVersionHintStatus = discovery.zigVersionHintStatus;
const versionMeetsMinimum = discovery.versionMeetsMinimum;
const parseVersionPrefix = discovery.parseVersionPrefix;
const zigarFailureFusion = agent.zigarFailureFusion;
const zigExplainErrors = core.zigExplainErrors;
const zigCompileErrorIndex = core.zigCompileErrorIndex;
const compilerErrorIndexValue = core.compilerErrorIndexValue;
const xmlEscape = ci.xmlEscape;
const ownerVarName = static_analysis.ownerVarName;
const buildNameFromCall = static_analysis.buildNameFromCall;
const buildPathFromLine = static_analysis.buildPathFromLine;
const dependencyNameFromLine = static_analysis.dependencyNameFromLine;
const optionNameFromLine = static_analysis.optionNameFromLine;
const optionTypeFromLine = static_analysis.optionTypeFromLine;
const quotedString = static_analysis.quotedString;
const relativeImportCandidate = static_analysis.relativeImportCandidate;
const dependencyBlockNameFromLine = static_analysis.dependencyBlockNameFromLine;
const declName = static_analysis.declName;
const targetMatrixNote = static_analysis.targetMatrixNote;
const testNameFromLine = static_analysis.testNameFromLine;
const publicApiDiffValue = static_analysis.publicApiDiffValue;

test "schema with required field" {
    var s = try tooling.buildInputSchema(std.testing.allocator, tooling.schema(&.{.{ "file", "string", true }}));
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
    try std.testing.expect(std.mem.indexOf(u8, body, "\"zigar_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"zigar_doctor\"") != null);
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
            try std.testing.expect(tool_metadata.find(tool_name) != null);
            if (tool_metadata.find(tool_name)) |spec| {
                if (spec.input_schema.fields.len > 0) {
                    try std.testing.expect(tool_arguments.get(tool_name) != null);
                }
            }
        }
    }
    try std.testing.expectEqual(tool_metadata.specs.len, grouped_count);
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
    const validate_patch = tool_arguments.get("zigar_validate_patch").?.object;
    try std.testing.expectEqualStrings("medium", validate_patch.get("risk").?.object.get("level").?.string);
    try std.testing.expect(validate_patch.get("risk").?.object.get("executes_project_code").?.bool);
    try std.testing.expect(validate_patch.get("risk").?.object.get("writes_artifacts").?.bool);
}

test "zigar_schema exposes registry-derived risk metadata" {
    const allocator = std.testing.allocator;
    const result = try zigarSchema(allocator, null);
    defer allocator.free(result.content);
    const body = result.content[0].text.text;
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const args = parsed.value.object.get("registry_tool_arguments").?.object;
    const validate_patch = args.get("zigar_validate_patch").?.object;
    try std.testing.expect(validate_patch.get("risk").?.object.get("executes_project_code").?.bool);
}

fn testAppForCommandPlanning(allocator: std.mem.Allocator) !App {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .config = .{ .workspace = "/tmp", .zig_path = "zig" },
        .workspace = try workspace_mod.Workspace.init(allocator, std.testing.io, "/tmp", null),
    };
}

test "zig_command_plan exposes registry risk metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testAppForCommandPlanning(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "tool", .{ .string = "zig_test" });
    const result = try zigCommandPlan(&app, allocator, .{ .object = args });
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

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "tool", .{ .string = "zig_hover" });
    const result = try zigCommandPlan(&app, allocator, .{ .object = args });
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

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "tool", .{ .string = "zig_hover" });
    const result = try zigToolPlan(&app, allocator, .{ .object = args });
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

fn jsonArrayContainsString(array: std.json.Array, needle: []const u8) bool {
    for (array.items) |item| {
        switch (item) {
            .string => |value| if (std.mem.eql(u8, value, needle)) return true,
            else => {},
        }
    }
    return false;
}

test "explain command setup errors use the calling tool name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testAppForCommandPlanning(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "command", .{ .string = "check" });
    try args.put(allocator, "file", .{ .string = "/zigar-outside-workspace.zig" });

    const explain = try zigExplainErrors(&app, allocator, .{ .object = args });
    try std.testing.expect(std.mem.indexOf(u8, explain.content[0].text.text, "zig_explain_errors") != null);

    const index = try zigCompileErrorIndex(&app, allocator, .{ .object = args });
    try std.testing.expect(std.mem.indexOf(u8, index.content[0].text.text, "zig_compile_error_index") != null);

    const fusion = try zigarFailureFusion(&app, allocator, .{ .object = args });
    try std.testing.expect(std.mem.indexOf(u8, fusion.content[0].text.text, "zigar_failure_fusion") != null);
}

test "catalog derives compact argument hints from registry metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed_catalog = try catalog.parsed(arena.allocator());
    const tool_arguments = parsed_catalog.value.object.get("registry_tool_arguments").?.object;
    const zig_format = tool_arguments.get("zig_format").?.object;
    try std.testing.expectEqualStrings("string", zig_format.get("required").?.object.get("file").?.string);
    try std.testing.expectEqualStrings("boolean", zig_format.get("optional").?.object.get("apply").?.string);
    const doctor_args = tool_arguments.get("zigar_doctor").?.object.get("optional").?.object;
    try std.testing.expectEqualStrings("boolean", doctor_args.get("probe_backends").?.string);
}

test "tool argument validation returns structured errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const spec = tool_metadata.find("zig_check").?;

    const missing_obj = std.json.ObjectMap.empty;
    const missing = try tool_registry.validateToolArgs(allocator, spec, .{ .object = missing_obj });
    try std.testing.expect(missing != null);

    var wrong_type_obj = std.json.ObjectMap.empty;
    try wrong_type_obj.put(allocator, "file", .{ .integer = 42 });
    const wrong_type = try tool_registry.validateToolArgs(allocator, spec, .{ .object = wrong_type_obj });
    try std.testing.expect(wrong_type != null);

    var valid_obj = std.json.ObjectMap.empty;
    try valid_obj.put(allocator, "file", .{ .string = "src/main.zig" });
    try std.testing.expect((try tool_registry.validateToolArgs(allocator, spec, .{ .object = valid_obj })) == null);
}

test "toolchain resolver defaults to cheap manager checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testAppForCommandPlanning(allocator);

    const result = try zigToolchainResolve(&app, allocator, null);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.content[0].text.text, .{});
    const managers = parsed.value.object.get("managers").?.array;
    try std.testing.expect(managers.items.len > 0);
    const first = managers.items[0].object;
    try std.testing.expect(first.get("available").? == .null);
    try std.testing.expect(first.get("version_output").? == .null);
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
    try std.testing.expect(analysis.skipWorkspacePath(".zigar-cache/profile/main.zig"));
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
    try std.testing.expectEqualStrings("zigar", quotedString(".name = \"zigar\",").?);
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

test "public api diff detects breaking removal and additions" {
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
    try std.testing.expectEqualStrings("heuristic_public_decl_diff", obj.get("analysis_kind").?.string);
    try std.testing.expectEqualStrings("advisory", obj.get("confidence_class").?.string);
    try std.testing.expect(obj.get("limitations").?.array.items.len > 0);
    try std.testing.expect(obj.get("breaking_change_risk").?.bool);
    try std.testing.expectEqual(@as(usize, 1), obj.get("removed").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), obj.get("added").?.array.items.len);
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
