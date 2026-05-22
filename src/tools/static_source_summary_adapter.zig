const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const analysis_contract = zigar.analysis_contract;
const source_summary_usecase = zigar.app.usecases.static_analysis.source_summary;
const common = @import("common.zig");
const docs_tools = @import("docs.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const missingArgumentResult = common.missingArgumentResult;
const toolErrorFromError = common.toolErrorFromError;
const workspacePathErrorResult = common.workspacePathErrorResult;
const ownedString = common.ownedString;
const readSourceArg = docs_tools.readSourceArg;

pub fn zigDeclSummary(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_decl_summary", args, err);
    defer allocator.free(source.bytes);
    const output = source_summary_usecase.textSummary(allocator, .decl_summary, .{ .file = source.name, .contents = source.bytes }) catch return error.OutOfMemory;
    defer allocator.free(output);
    return staticTextResult(allocator, "zig_decl_summary", output);
}

pub fn zigDeclSummaryJson(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_decl_summary_json", args, err);
    defer allocator.free(source.bytes);
    var declarations = source_summary_usecase.heuristicDeclarations(allocator, .{ .file = source.name, .contents = source.bytes }) catch return error.OutOfMemory;
    defer declarations.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return structured(allocator, analysis.declSummaryJsonFromDomain(arena.allocator(), source.name, declarations) catch return error.OutOfMemory);
}

pub fn zigAstImports(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_ast_imports", args, err);
    defer allocator.free(source.bytes);
    var summary = source_summary_usecase.parserSummary(allocator, .{ .file = source.name, .contents = source.bytes }) catch |err| return analysisToolError(allocator, "zig_ast_imports", "parse_ast_imports", err);
    defer summary.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return structured(allocator, analysis.astImportsJsonFromDomain(arena.allocator(), source.name, summary) catch return error.OutOfMemory);
}

pub fn zigAstDeclSummary(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_ast_decl_summary", args, err);
    defer allocator.free(source.bytes);
    var summary = source_summary_usecase.parserSummary(allocator, .{ .file = source.name, .contents = source.bytes }) catch |err| return analysisToolError(allocator, "zig_ast_decl_summary", "parse_ast_declarations", err);
    defer summary.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return structured(allocator, analysis.astDeclSummaryJsonFromDomain(arena.allocator(), source.name, summary) catch return error.OutOfMemory);
}

pub fn zigAllocations(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_allocations", args, err);
    defer allocator.free(source.bytes);
    const output = source_summary_usecase.textSummary(allocator, .allocations, .{ .file = source.name, .contents = source.bytes }) catch return error.OutOfMemory;
    defer allocator.free(output);
    return staticTextResult(allocator, "zig_allocations", output);
}

pub fn zigErrorSets(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_error_sets", args, err);
    defer allocator.free(source.bytes);
    const output = source_summary_usecase.textSummary(allocator, .error_sets, .{ .file = source.name, .contents = source.bytes }) catch return error.OutOfMemory;
    defer allocator.free(output);
    return staticTextResult(allocator, "zig_error_sets", output);
}

pub fn zigPublicApi(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_public_api", args, err);
    defer allocator.free(source.bytes);
    const output = source_summary_usecase.textSummary(allocator, .public_api, .{ .file = source.name, .contents = source.bytes }) catch return error.OutOfMemory;
    defer allocator.free(output);
    return staticTextResult(allocator, "zig_public_api", output);
}

pub fn zigDeadDeclCandidates(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_dead_decl_candidates", args, err);
    defer allocator.free(source.bytes);
    const output = source_summary_usecase.textSummary(allocator, .dead_decl_candidates, .{ .file = source.name, .contents = source.bytes }) catch return error.OutOfMemory;
    defer allocator.free(output);
    return staticTextResult(allocator, "zig_dead_decl_candidates", output);
}

pub fn zigAstTests(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const source = readSourceArg(a, allocator, args) catch |err| return readSourceArgError(a, allocator, "zig_ast_tests", args, err);
    defer allocator.free(source.bytes);
    var summary = source_summary_usecase.parserSummary(allocator, .{ .file = source.name, .contents = source.bytes }) catch |err| return analysisToolError(allocator, "zig_ast_tests", "parse_ast_tests", err);
    defer summary.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return structured(allocator, analysis.astTestsJsonFromDomain(arena.allocator(), source.name, summary) catch return error.OutOfMemory);
}

fn readSourceArgError(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.InvalidArguments, error.MissingFile => missingArgumentResult(allocator, tool_name, "file", "workspace-relative Zig source path"),
        error.PathOutsideWorkspace, error.EmptyPath => if (argString(args, "file")) |file|
            workspacePathErrorResult(a, allocator, tool_name, file, err)
        else
            missingArgumentResult(allocator, tool_name, "file", "workspace-relative Zig source path"),
        error.OutOfMemory => error.OutOfMemory,
        else => workspaceFileError(allocator, tool_name, argString(args, "file") orelse "<missing>", err, "Pass a readable workspace file or provide the content through a tool that explicitly supports inline content."),
    };
}

fn analysisToolError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "static_analysis",
        .code = "analysis_failed",
        .category = "analysis",
        .resolution = "Retry with a smaller limit or inspect the workspace files for syntax that the heuristic analyzer cannot scan.",
    }, err);
}

fn workspaceFileError(allocator: std.mem.Allocator, tool_name: []const u8, file: []const u8, err: anyerror, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = "read_workspace_file",
        .phase = "workspace_read",
        .code = "read_failed",
        .category = "filesystem",
        .resolution = resolution,
        .details = &.{.{ .key = "file", .value = .{ .string = file } }},
    }, err);
}

fn staticTextResult(allocator: std.mem.Allocator, tool_name: []const u8, body: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = tool_name });
    try analysis_contract.putMetadata(scratch, &obj, tool_name);
    try obj.put(scratch, "text", .{ .string = body });
    return structured(allocator, .{ .object = obj });
}
