const std = @import("std");
const mcp = @import("mcp");

const analysis_contract = @import("../../../domain/zig/static_analysis_contracts.zig");
const app_context = @import("../../../app/context.zig");
const source_summary_usecase = @import("../../../app/usecases/static_analysis/source_summary.zig");
const zig_analysis = @import("../../../domain/zig/analysis.zig");
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
