const std = @import("std");
const mcp = @import("mcp");

const analysis_contract = @import("../../../domain/zig/static_analysis_contracts.zig");
const app_context = @import("../../../app/context.zig");
const source_summary_usecase = @import("../../../app/usecases/static_analysis/source_summary.zig");
const zig_analysis = @import("../../../domain/zig/analysis.zig");
const ports = @import("../../../app/ports.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

pub const ReadSourceError = source_summary_usecase.SourceError || error{
    MissingFile,
};

pub fn zigDeclSummary(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceFromArgs(allocator, context, args) catch |err| return readSourceArgError(allocator, context, "zig_decl_summary", args, err);
    defer source.deinit(allocator);
    const output = source_summary_usecase.textSummary(allocator, .decl_summary, .{ .file = source.file, .contents = source.bytes }) catch return error.OutOfMemory;
    defer allocator.free(output);
    return staticTextResult(allocator, "zig_decl_summary", output);
}

pub fn zigDeclSummaryJson(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceFromArgs(allocator, context, args) catch |err| return readSourceArgError(allocator, context, "zig_decl_summary_json", args, err);
    defer source.deinit(allocator);
    var declarations = source_summary_usecase.heuristicDeclarations(allocator, .{ .file = source.file, .contents = source.bytes }) catch return error.OutOfMemory;
    defer declarations.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return mcp_result.structured(allocator, declSummaryValue(arena.allocator(), source.file, declarations) catch return error.OutOfMemory);
}

pub fn zigAstImports(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceFromArgs(allocator, context, args) catch |err| return readSourceArgError(allocator, context, "zig_ast_imports", args, err);
    defer source.deinit(allocator);
    var summary = source_summary_usecase.parserSummary(allocator, .{ .file = source.file, .contents = source.bytes }) catch |err| return analysisToolError(allocator, "zig_ast_imports", "parse_ast_imports", err);
    defer summary.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return mcp_result.structured(allocator, astImportsValue(arena.allocator(), source.file, summary) catch return error.OutOfMemory);
}

pub fn zigAstDeclSummary(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceFromArgs(allocator, context, args) catch |err| return readSourceArgError(allocator, context, "zig_ast_decl_summary", args, err);
    defer source.deinit(allocator);
    var summary = source_summary_usecase.parserSummary(allocator, .{ .file = source.file, .contents = source.bytes }) catch |err| return analysisToolError(allocator, "zig_ast_decl_summary", "parse_ast_declarations", err);
    defer summary.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return mcp_result.structured(allocator, astDeclSummaryValue(arena.allocator(), source.file, summary) catch return error.OutOfMemory);
}

pub fn zigAllocations(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceFromArgs(allocator, context, args) catch |err| return readSourceArgError(allocator, context, "zig_allocations", args, err);
    defer source.deinit(allocator);
    const output = source_summary_usecase.textSummary(allocator, .allocations, .{ .file = source.file, .contents = source.bytes }) catch return error.OutOfMemory;
    defer allocator.free(output);
    return staticTextResult(allocator, "zig_allocations", output);
}

pub fn zigErrorSets(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceFromArgs(allocator, context, args) catch |err| return readSourceArgError(allocator, context, "zig_error_sets", args, err);
    defer source.deinit(allocator);
    const output = source_summary_usecase.textSummary(allocator, .error_sets, .{ .file = source.file, .contents = source.bytes }) catch return error.OutOfMemory;
    defer allocator.free(output);
    return staticTextResult(allocator, "zig_error_sets", output);
}

pub fn zigPublicApi(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceFromArgs(allocator, context, args) catch |err| return readSourceArgError(allocator, context, "zig_public_api", args, err);
    defer source.deinit(allocator);
    const output = source_summary_usecase.textSummary(allocator, .public_api, .{ .file = source.file, .contents = source.bytes }) catch return error.OutOfMemory;
    defer allocator.free(output);
    return staticTextResult(allocator, "zig_public_api", output);
}

pub fn zigDeadDeclCandidates(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceFromArgs(allocator, context, args) catch |err| return readSourceArgError(allocator, context, "zig_dead_decl_candidates", args, err);
    defer source.deinit(allocator);
    const output = source_summary_usecase.textSummary(allocator, .dead_decl_candidates, .{ .file = source.file, .contents = source.bytes }) catch return error.OutOfMemory;
    defer allocator.free(output);
    return staticTextResult(allocator, "zig_dead_decl_candidates", output);
}

pub fn zigAstTests(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceFromArgs(allocator, context, args) catch |err| return readSourceArgError(allocator, context, "zig_ast_tests", args, err);
    defer source.deinit(allocator);
    var summary = source_summary_usecase.parserSummary(allocator, .{ .file = source.file, .contents = source.bytes }) catch |err| return analysisToolError(allocator, "zig_ast_tests", "parse_ast_tests", err);
    defer summary.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return mcp_result.structured(allocator, astTestsValue(arena.allocator(), source.file, summary) catch return error.OutOfMemory);
}

pub fn readSourceFromArgs(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    args: ?std.json.Value,
) ReadSourceError!source_summary_usecase.SourceRead {
    const file = argString(args, "file") orelse return error.MissingFile;
    return source_summary_usecase.readSource(allocator, context, .{ .file = file });
}

pub fn staticTextValue(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    body: []const u8,
) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try analysis_contract.putMetadata(allocator, &obj, tool_name);
    try obj.put(allocator, "text", .{ .string = body });
    return .{ .object = obj };
}

pub fn declSummaryValue(
    allocator: std.mem.Allocator,
    file: []const u8,
    declarations: zig_analysis.DeclarationList,
) !std.json.Value {
    var decls = std.json.Array.init(allocator);
    for (declarations.items) |decl| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "line", .{ .integer = @intCast(decl.line) });
        try item.put(allocator, "kind", try ownedString(allocator, decl.kind));
        try item.put(allocator, "public", .{ .bool = decl.public });
        try item.put(allocator, "text", try ownedString(allocator, decl.signature));
        try decls.append(.{ .object = item });
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try analysis_contract.putMetadata(allocator, &obj, "zig_decl_summary_json");
    try obj.put(allocator, "declarations", .{ .array = decls });
    return .{ .object = obj };
}

pub fn astImportsValue(
    allocator: std.mem.Allocator,
    file: []const u8,
    summary: zig_analysis.SourceSummary,
) !std.json.Value {
    var imports = std.json.Array.init(allocator);
    for (summary.imports) |import_item| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try ownedString(allocator, import_item.file));
        try item.put(allocator, "line", .{ .integer = @intCast(import_item.line) });
        try item.put(allocator, "import", try ownedString(allocator, import_item.import));
        try item.put(allocator, "alias", if (import_item.alias) |alias| try ownedString(allocator, alias) else .null);
        try item.put(allocator, "declaration", try ownedString(allocator, import_item.declaration));
        try imports.append(.{ .object = item });
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_ast_imports" });
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try analysis_contract.putMetadata(allocator, &obj, "zig_ast_imports");
    try putParseMetadata(allocator, &obj, summary.parse);
    try obj.put(allocator, "imports", .{ .array = imports });
    try obj.put(allocator, "skipped_files", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "skipped_file_count", .{ .integer = 0 });
    return .{ .object = obj };
}

pub fn astDeclSummaryValue(
    allocator: std.mem.Allocator,
    file: []const u8,
    summary: zig_analysis.SourceSummary,
) !std.json.Value {
    var declarations = std.json.Array.init(allocator);
    for (summary.declarations) |decl| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "line", .{ .integer = @intCast(decl.line) });
        try item.put(allocator, "kind", try ownedString(allocator, decl.kind));
        try item.put(allocator, "name", if (decl.name) |name| try ownedString(allocator, name) else .null);
        try item.put(allocator, "public", .{ .bool = decl.public });
        try item.put(allocator, "comptime", .{ .bool = decl.is_comptime });
        try item.put(allocator, "depth", .{ .integer = @intCast(decl.depth) });
        try item.put(allocator, "signature", try ownedString(allocator, decl.signature));
        try declarations.append(.{ .object = item });
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_ast_decl_summary" });
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try analysis_contract.putMetadata(allocator, &obj, "zig_ast_decl_summary");
    try putParseMetadata(allocator, &obj, summary.parse);
    try obj.put(allocator, "declarations", .{ .array = declarations });
    try obj.put(allocator, "skipped_files", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "skipped_file_count", .{ .integer = 0 });
    return .{ .object = obj };
}

pub fn astTestsValue(
    allocator: std.mem.Allocator,
    file: []const u8,
    summary: zig_analysis.SourceSummary,
) !std.json.Value {
    var tests = std.json.Array.init(allocator);
    for (summary.tests) |test_item| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try ownedString(allocator, test_item.file));
        try item.put(allocator, "line", .{ .integer = @intCast(test_item.line) });
        try item.put(allocator, "name", if (test_item.name) |name| try ownedString(allocator, name) else .null);
        try item.put(allocator, "declaration", try ownedString(allocator, test_item.declaration));
        try item.put(allocator, "command", try ownedString(allocator, test_item.command));
        try tests.append(.{ .object = item });
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_ast_tests" });
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try analysis_contract.putMetadata(allocator, &obj, "zig_ast_tests");
    try putParseMetadata(allocator, &obj, summary.parse);
    try obj.put(allocator, "tests", .{ .array = tests });
    try obj.put(allocator, "skipped_files", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "skipped_file_count", .{ .integer = 0 });
    return .{ .object = obj };
}

fn putParseMetadata(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    parse: zig_analysis.ParseMetadata,
) !void {
    try obj.put(allocator, "parse_status", .{ .string = zig_analysis.parseStatusName(parse.status) });
    try obj.put(allocator, "partial_result", .{ .bool = parse.partial_result });
    try obj.put(allocator, "result_complete", .{ .bool = parse.result_complete });
    try obj.put(allocator, "parse_error_count", .{ .integer = parse.parse_error_count });
}

fn argString(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    const value = args orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

fn readSourceArgError(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    tool_name: []const u8,
    args: ?std.json.Value,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.InvalidArguments, error.MissingFile => mcp_errors.missingArgument(allocator, tool_name, "file", "workspace-relative Zig source path"),
        error.PathOutsideWorkspace, error.EmptyPath => if (argString(args, "file")) |file|
            mcp_errors.workspacePath(allocator, tool_name, file, context.workspace.root, err)
        else
            mcp_errors.missingArgument(allocator, tool_name, "file", "workspace-relative Zig source path"),
        error.SkippedWorkspacePath => if (argString(args, "file")) |file|
            workspaceFileError(allocator, tool_name, file, err, "Skip generated/cache paths and pass a workspace source file path instead.")
        else
            mcp_errors.missingArgument(allocator, tool_name, "file", "workspace-relative Zig source path"),
        error.OutOfMemory => error.OutOfMemory,
        else => workspaceFileError(allocator, tool_name, argString(args, "file") orelse "<missing>", err, "Pass a readable workspace file or provide the content through a tool that explicitly supports inline content."),
    };
}

fn analysisToolError(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    operation: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "static_analysis",
        .code = "analysis_failed",
        .category = "analysis",
        .resolution = "Retry with a smaller limit or inspect the workspace files for syntax that the heuristic analyzer cannot scan.",
    }, err);
}

fn workspaceFileError(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    file: []const u8,
    err: anyerror,
    resolution: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = "read_workspace_file",
        .phase = "workspace_read",
        .code = "read_failed",
        .category = "filesystem",
        .resolution = resolution,
        .details = &.{.{ .key = "file", .value = .{ .string = file } }},
    }, err);
}

fn staticTextResult(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    body: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return mcp_result.structured(allocator, staticTextValue(arena.allocator(), tool_name, body) catch return error.OutOfMemory);
}

const fakes = @import("../../../testing/fakes/root.zig");

test "static source summary adapters read workspace source and return structured outputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    const source =
        \\const std = @import("std");
        \\pub const Thing = struct {
        \\    pub fn make(allocator: std.mem.Allocator) ![]u8 {
        \\        return try allocator.alloc(u8, 1);
        \\    }
        \\};
        \\pub const Failure = error{Bad};
        \\fn privateThing() void {}
        \\test "Thing.make" {}
        \\
    ;
    const args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"src/main.zig\"}", .{});
    const context = staticSummaryContext(workspace.port(), scanner.port());

    inline for (.{
        "zig_decl_summary",
        "zig_decl_summary_json",
        "zig_ast_imports",
        "zig_ast_decl_summary",
        "zig_allocations",
        "zig_error_sets",
        "zig_public_api",
        "zig_dead_decl_candidates",
        "zig_ast_tests",
    }) |_| {
        try workspace.expectRead(.{ .path = "src/main.zig", .max_bytes = source_summary_usecase.default_source_read_limit, .provenance = source_summary_usecase.provenance }, source);
    }

    const decl_text = try zigDeclSummary(allocator, context, args.value);
    try expectStructuredKind(decl_text, "zig_decl_summary");
    try std.testing.expect(std.mem.indexOf(u8, decl_text.structuredContent.?.object.get("text").?.string, "Thing") != null);

    const decl_json = try zigDeclSummaryJson(allocator, context, args.value);
    try std.testing.expectEqualStrings("src/main.zig", decl_json.structuredContent.?.object.get("file").?.string);
    try std.testing.expect(decl_json.structuredContent.?.object.get("declarations").?.array.items.len > 0);

    const imports = try zigAstImports(allocator, context, args.value);
    try expectStructuredKind(imports, "zig_ast_imports");
    try std.testing.expect(imports.structuredContent.?.object.get("imports").?.array.items.len > 0);

    const ast_decls = try zigAstDeclSummary(allocator, context, args.value);
    try expectStructuredKind(ast_decls, "zig_ast_decl_summary");
    try std.testing.expect(ast_decls.structuredContent.?.object.get("declarations").?.array.items.len > 0);

    const allocations = try zigAllocations(allocator, context, args.value);
    try expectStructuredKind(allocations, "zig_allocations");
    try std.testing.expect(std.mem.indexOf(u8, allocations.structuredContent.?.object.get("text").?.string, "alloc") != null);

    const errors = try zigErrorSets(allocator, context, args.value);
    try expectStructuredKind(errors, "zig_error_sets");
    try std.testing.expect(std.mem.indexOf(u8, errors.structuredContent.?.object.get("text").?.string, "Failure") != null);

    const public_api = try zigPublicApi(allocator, context, args.value);
    try expectStructuredKind(public_api, "zig_public_api");
    try std.testing.expect(std.mem.indexOf(u8, public_api.structuredContent.?.object.get("text").?.string, "pub const Thing") != null);

    const dead_decls = try zigDeadDeclCandidates(allocator, context, args.value);
    try expectStructuredKind(dead_decls, "zig_dead_decl_candidates");
    try std.testing.expect(std.mem.indexOf(u8, dead_decls.structuredContent.?.object.get("text").?.string, "privateThing") != null);

    const tests = try zigAstTests(allocator, context, args.value);
    try expectStructuredKind(tests, "zig_ast_tests");
    try std.testing.expect(tests.structuredContent.?.object.get("tests").?.array.items.len > 0);

    try workspace.verify();
    try scanner.verify();
}

test "static source summary argument errors cover missing skipped workspace and analysis failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    const context = staticSummaryContext(workspace.port(), scanner.port());

    const no_args = try readSourceArgError(allocator, context, "zig_decl_summary", null, error.MissingFile);
    try std.testing.expect(no_args.is_error);

    const empty_obj = try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    const outside_without_file = try readSourceArgError(allocator, context, "zig_decl_summary", empty_obj.value, error.PathOutsideWorkspace);
    try std.testing.expect(outside_without_file.is_error);

    const outside_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"../escape.zig\"}", .{});
    const outside = try readSourceArgError(allocator, context, "zig_decl_summary", outside_args.value, error.PathOutsideWorkspace);
    try std.testing.expect(outside.is_error);

    const skipped_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"zig-cache/generated.zig\"}", .{});
    const skipped = try readSourceArgError(allocator, context, "zig_decl_summary", skipped_args.value, error.SkippedWorkspacePath);
    try std.testing.expect(skipped.is_error);

    const skipped_missing = try readSourceArgError(allocator, context, "zig_decl_summary", empty_obj.value, error.SkippedWorkspacePath);
    try std.testing.expect(skipped_missing.is_error);

    const read_failed = try readSourceArgError(allocator, context, "zig_decl_summary", outside_args.value, error.FileNotFound);
    try std.testing.expect(read_failed.is_error);

    const malformed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":123}", .{});
    try std.testing.expect(argString(malformed.value, "file") == null);
    try std.testing.expect(argString(.{ .string = "not-object" }, "file") == null);
    try std.testing.expect(argString(null, "file") == null);

    const analysis_error = try analysisToolError(allocator, "zig_ast_imports", "parse_ast_imports", error.InvalidRequest);
    try std.testing.expect(analysis_error.is_error);
}

test "static source summary value builders clean up partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseStaticSummaryValueBuilders, .{});
    try exerciseAstValueBuilderFixedBufferFailures();
}

fn exerciseStaticSummaryValueBuilders(backing_allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    _ = try staticTextValue(allocator, "zig_decl_summary", "pub const Thing = struct {};");

    var decls = [_]zig_analysis.Declaration{
        .{ .line = 1, .kind = "const", .name = "Thing", .public = true, .signature = "pub const Thing = struct {};" },
    };
    _ = try declSummaryValue(allocator, "src/main.zig", .{ .items = decls[0..] });

    var imports = [_]zig_analysis.Import{
        .{ .file = "src/main.zig", .line = 1, .import = "std", .alias = "std", .declaration = "const std = @import(\"std\");" },
    };
    var ast_decls = [_]zig_analysis.Declaration{
        .{ .line = 2, .kind = "fn", .name = "main", .public = true, .is_comptime = false, .depth = 0, .signature = "pub fn main() void {}" },
    };
    var tests = [_]zig_analysis.TestDecl{
        .{ .file = "src/main.zig", .line = 3, .name = "unit", .declaration = "test \"unit\" {}", .command = "zig test src/main.zig --test-filter unit" },
    };
    const summary = zig_analysis.SourceSummary{
        .parse = .{ .status = .syntax_errors, .partial_result = true, .result_complete = false, .parse_error_count = 1 },
        .declarations = ast_decls[0..],
        .imports = imports[0..],
        .tests = tests[0..],
    };
    _ = try astImportsValue(allocator, "src/main.zig", summary);
    _ = try astDeclSummaryValue(allocator, "src/main.zig", summary);
    _ = try astTestsValue(allocator, "src/main.zig", summary);
}

fn exerciseAstValueBuilderFixedBufferFailures() !void {
    var imports = [_]zig_analysis.Import{
        .{ .file = "src/main.zig", .line = 1, .import = "std", .alias = "std", .declaration = "const std = @import(\"std\");" },
    };
    var ast_decls = [_]zig_analysis.Declaration{
        .{ .line = 2, .kind = "fn", .name = "main", .public = true, .is_comptime = false, .depth = 0, .signature = "pub fn main() void {}" },
    };
    var tests = [_]zig_analysis.TestDecl{
        .{ .file = "src/main.zig", .line = 3, .name = "unit", .declaration = "test \"unit\" {}", .command = "zig test src/main.zig --test-filter unit" },
    };
    const summary = zig_analysis.SourceSummary{
        .parse = .{ .status = .syntax_errors, .partial_result = true, .result_complete = false, .parse_error_count = 1 },
        .declarations = ast_decls[0..],
        .imports = imports[0..],
        .tests = tests[0..],
    };

    var storage: [4096]u8 = undefined;
    for (0..storage.len) |cap| {
        var fba = std.heap.FixedBufferAllocator.init(storage[0..cap]);
        _ = astDeclSummaryValue(fba.allocator(), "src/main.zig", summary) catch |err| switch (err) {
            error.OutOfMemory => continue,
        };
    }
    for (0..storage.len) |cap| {
        var fba = std.heap.FixedBufferAllocator.init(storage[0..cap]);
        _ = astTestsValue(fba.allocator(), "src/main.zig", summary) catch |err| switch (err) {
            error.OutOfMemory => continue,
        };
    }
}

fn staticSummaryContext(workspace_store: ports.WorkspaceStore, workspace_scanner: ports.WorkspaceScanner) app_context.StaticAnalysisContext {
    return .{
        .workspace = .{
            .root = "/repo",
            .cache_root = "/repo/.zigar-cache",
            .transport = "stdio",
        },
        .workspace_store = workspace_store,
        .workspace_scanner = workspace_scanner,
    };
}

fn expectStructuredKind(result: mcp.tools.ToolResult, expected: []const u8) !void {
    try std.testing.expect(result.structuredContent != null);
    try std.testing.expectEqualStrings(expected, result.structuredContent.?.object.get("kind").?.string);
}
