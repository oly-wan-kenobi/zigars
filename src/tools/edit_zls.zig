const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const command = zigar.command;
const json_result = zigar.json_result;
const lsp_edits = zigar.lsp_edits;
const uri_util = zigar.uri;
const zls_session = zigar.zls_session;
const common = @import("common.zig");
const core = @import("core.zig");
const edit_diagnostics = @import("edit_zls_diagnostics.zig");
const edit_edits = @import("edit_zls_edits.zig");
const static_analysis = @import("static_analysis.zig");
const zls_document = @import("zls_document.zig");

const App = common.App;
const LspClient = common.LspClient;
const structured = common.structured;
const structuredOwned = common.structuredOwned;
const argString = common.argString;
const argBool = common.argBool;
const argInt = common.argInt;
const workspacePathErrorResult = common.workspacePathErrorResult;
const toolErrorResult = common.toolErrorResult;
const toolErrorFromError = common.toolErrorFromError;
const missingArgumentResult = common.missingArgumentResult;
const runAndFormatTimeout = common.runAndFormatTimeout;
const toolTimeout = common.toolTimeout;
const commandResultValue = common.commandResultValue;
const backendErrorResult = common.backendErrorResult;
const commandResultErrorResult = common.commandResultErrorResult;
const structuredText = common.structuredText;
const requireZlsCapability = common.requireZlsCapability;
const zlsUnavailable = common.zlsUnavailable;
const zlsFileUriFromArgs = common.zlsFileUriFromArgs;
const zlsDocumentFromArgs = common.zlsDocumentFromArgs;
const zlsSetupErrorResult = common.zlsSetupErrorResult;
const lspStructuredValue = common.lspStructuredValue;
const lspStructuredTool = common.lspStructuredTool;
const lspHasError = common.lspHasError;
const responseResult = common.responseResult;
const zigCheck = core.zigCheck;
const zigDeclSummary = static_analysis.zigDeclSummary;
const diagnosticWaitMs = edit_diagnostics.diagnosticWaitMs;
const diagnosticsStructuredValue = edit_diagnostics.diagnosticsStructuredValue;
const waitForDiagnostics = edit_diagnostics.waitForDiagnostics;
const textEditToolValueForDocument = edit_edits.textEditToolValueForDocument;
const workspaceEditValueForDocument = edit_edits.workspaceEditValueForDocument;

pub fn zigFormat(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_format", "file", "string");
    const apply = argBool(args, "apply", false);

    if (a.lsp_client != null and a.doc_state != null) {
        return zigFormatZls(a, allocator, args, apply);
    }

    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_format", file, err);
    defer allocator.free(resolved);
    if (apply) {
        return runAndFormatTimeout(a, allocator, &.{ a.config.zig_path, "fmt", resolved }, "zig fmt apply", toolTimeout(a, args));
    }

    const rel = a.workspace.relative(resolved);
    const preview_path = std.fs.path.join(allocator, &.{ ".zigar-cache", "format-preview", rel }) catch return error.OutOfMemory;
    defer allocator.free(preview_path);
    const input = a.workspace.readFileAlloc(a.io, file, 4 * 1024 * 1024) catch |err| return fileToolError(allocator, "zig_format", "format_preview", "read_source", "read_failed", "filesystem", file, err, "Confirm the file exists inside the zigar workspace and retry.");
    defer allocator.free(input);
    a.workspace.writeFile(a.io, preview_path, input) catch |err| return fileToolError(allocator, "zig_format", "format_preview", "write_preview", "preview_write_failed", "filesystem", preview_path, err, "Confirm zigar can write to .zigar-cache in the configured workspace and retry.");
    const preview_abs = a.workspace.resolve(preview_path) catch |err| return fileToolError(allocator, "zig_format", "format_preview", "resolve_preview", "preview_resolve_failed", "workspace_path", preview_path, err, "Confirm the preview path resolves inside the zigar workspace and retry.");
    defer allocator.free(preview_abs);
    defer std.Io.Dir.cwd().deleteFile(a.io, preview_abs) catch {};
    const fmt = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zig_path, "fmt", preview_abs }, a.config.timeout_ms) catch |err| {
        return backendErrorResult(allocator, "zig", "fmt_preview", err, "confirm --zig-path is executable and zig fmt can run in the configured workspace");
    };
    defer fmt.deinit(allocator);
    if (!fmt.succeeded()) {
        return commandResultErrorResult(allocator, .{
            .tool = "zig_format",
            .operation = "format_preview",
            .phase = "run_zig_fmt",
            .code = "zig_fmt_preview_failed",
            .backend = "zig",
            .argv = &.{ a.config.zig_path, "fmt", preview_abs },
            .cwd = a.workspace.root,
            .timeout_ms = a.config.timeout_ms,
            .result = fmt,
            .resolution = "Inspect stdout/stderr, fix the preview source so zig fmt can parse it, then retry.",
        });
    }
    const formatted = a.workspace.readFileAlloc(a.io, preview_path, 4 * 1024 * 1024) catch |err| return fileToolError(allocator, "zig_format", "format_preview", "read_formatted_preview", "formatted_preview_read_failed", "filesystem", preview_path, err, "Retry after confirming zig fmt wrote the preview file.");
    defer allocator.free(formatted);
    const diff = lsp_edits.unifiedDiff(allocator, file, input, formatted) catch |err| return fileToolError(allocator, "zig_format", "format_preview", "build_diff", "diff_failed", "diff", file, err, "Retry with a text Zig source file that can be diffed.");
    defer allocator.free(diff);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "applied", .{ .bool = false }) catch return error.OutOfMemory;
    obj.put(allocator, "file", .{ .string = file }) catch return error.OutOfMemory;
    obj.put(allocator, "source_hash", .{ .string = lsp_edits.hashHex(allocator, input) catch return error.OutOfMemory }) catch return error.OutOfMemory;
    obj.put(allocator, "updated_hash", .{ .string = lsp_edits.hashHex(allocator, formatted) catch return error.OutOfMemory }) catch return error.OutOfMemory;
    obj.put(allocator, "diff", .{ .string = diff }) catch return error.OutOfMemory;
    obj.put(allocator, "formatted", .{ .string = formatted }) catch return error.OutOfMemory;
    obj.put(allocator, "preview_retained", .{ .bool = false }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigFormatCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = argString(args, "path") orelse return missingArgumentResult(allocator, "zig_format_check", "path", "string");
    const resolved = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_format_check", path, err);
    defer allocator.free(resolved);
    return runAndFormatTimeout(a, allocator, &.{ a.config.zig_path, "fmt", "--check", resolved }, "zig fmt --check", toolTimeout(a, args));
}

pub fn zigPatchPreview(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_patch_preview", "file", "string");
    const content = argString(args, "content") orelse return missingArgumentResult(allocator, "zig_patch_preview", "content", "string");
    const apply = argBool(args, "apply", false);
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_patch_preview", file, err);
    defer allocator.free(resolved);
    const rel = a.workspace.relative(resolved);
    const source = a.workspace.readFileAlloc(a.io, rel, 4 * 1024 * 1024) catch |err| return fileToolError(allocator, "zig_patch_preview", "patch_preview", "read_source", "read_failed", "filesystem", rel, err, "Confirm the file exists inside the zigar workspace and retry.");
    defer allocator.free(source);
    const diff = lsp_edits.unifiedDiff(allocator, rel, source, content) catch |err| return fileToolError(allocator, "zig_patch_preview", "patch_preview", "build_diff", "diff_failed", "diff", rel, err, "Retry with text content that can be diffed against the source file.");
    defer allocator.free(diff);
    if (apply) a.workspace.writeFile(a.io, rel, content) catch |err| return fileToolError(allocator, "zig_patch_preview", "patch_preview", "write_patch", "write_failed", "filesystem", rel, err, "Confirm zigar can write the target file and retry.");

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_patch_preview" });
    try obj.put(allocator, "applied", .{ .bool = apply });
    try obj.put(allocator, "preview_only", .{ .bool = !apply });
    try obj.put(allocator, "requires_apply", .{ .bool = !apply });
    try obj.put(allocator, "file", .{ .string = rel });
    try obj.put(allocator, "source_hash", .{ .string = try lsp_edits.hashHex(allocator, source) });
    try obj.put(allocator, "updated_hash", .{ .string = try lsp_edits.hashHex(allocator, content) });
    try obj.put(allocator, "changed", .{ .bool = !std.mem.eql(u8, source, content) });
    try obj.put(allocator, "would_write", .{ .bool = !apply and !std.mem.eql(u8, source, content) });
    try obj.put(allocator, "diff", .{ .string = diff });
    return structured(allocator, .{ .object = obj });
}

pub fn zigHover(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zlsPositionRequest(a, allocator, args, "textDocument/hover");
}

pub fn zigDefinition(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zlsPositionRequest(a, allocator, args, "textDocument/definition");
}

pub fn zigReferences(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (requireZlsCapability(a, allocator, "textDocument/references")) |result| return result;
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "textDocument/references", argString(args, "file"), err);
    defer allocator.free(file_uri);
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
        context: struct { includeDeclaration: bool },
    };
    a.zls_requests += 1;
    const response = client.sendRequest(allocator, "textDocument/references", Params{
        .textDocument = .{ .uri = file_uri },
        .position = .{ .line = argInt(args, "line", 0), .character = argInt(args, "character", 0) },
        .context = .{ .includeDeclaration = argBool(args, "include_declaration", true) },
    }) catch |err| return backendErrorResult(allocator, "zls", "textDocument/references", err, "ZLS request failed; check zigar_workspace_info and zigar_doctor for session status");
    defer allocator.free(response);
    return lspStructuredTool(allocator, "textDocument/references", response);
}

pub fn zigCompletion(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zlsPositionRequest(a, allocator, args, "textDocument/completion");
}

pub fn zigSignatureHelp(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return zlsPositionRequest(a, allocator, args, "textDocument/signatureHelp");
}

pub fn zlsPositionRequest(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, method: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (requireZlsCapability(a, allocator, method)) |result| return result;
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, method, argString(args, "file"), err);
    defer allocator.free(file_uri);
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
    };
    a.zls_requests += 1;
    const response = client.sendRequest(allocator, method, Params{
        .textDocument = .{ .uri = file_uri },
        .position = .{ .line = argInt(args, "line", 0), .character = argInt(args, "character", 0) },
    }) catch |err| return backendErrorResult(allocator, "zls", method, err, "ZLS request failed; check zigar_workspace_info and zigar_doctor for session status");
    defer allocator.free(response);
    return lspStructuredTool(allocator, method, response);
}

pub fn zigDocumentSymbols(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (requireZlsCapability(a, allocator, "textDocument/documentSymbol")) |result| return result;
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "textDocument/documentSymbol", argString(args, "file"), err);
    defer allocator.free(file_uri);
    const client = a.lsp_client orelse return zigDeclSummary(a, allocator, args);
    const Params = struct { textDocument: struct { uri: []const u8 } };
    a.zls_requests += 1;
    const response = client.sendRequest(allocator, "textDocument/documentSymbol", Params{ .textDocument = .{ .uri = file_uri } }) catch |err| return backendErrorResult(allocator, "zls", "textDocument/documentSymbol", err, "ZLS request failed; fall back to zig_decl_summary_json if symbols are unavailable");
    defer allocator.free(response);
    return lspStructuredTool(allocator, "textDocument/documentSymbol", response);
}

pub fn zigCodeActions(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (requireZlsCapability(a, allocator, "textDocument/codeAction")) |result| return result;
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "textDocument/codeAction", argString(args, "file"), err);
    defer allocator.free(file_uri);
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        range: struct {
            start: struct { line: i64, character: i64 },
            end: struct { line: i64, character: i64 },
        },
        context: struct { diagnostics: []const std.json.Value = &.{} },
    };
    a.zls_requests += 1;
    const response = client.sendRequest(allocator, "textDocument/codeAction", Params{
        .textDocument = .{ .uri = file_uri },
        .range = .{
            .start = .{ .line = argInt(args, "start_line", 0), .character = argInt(args, "start_char", 0) },
            .end = .{ .line = argInt(args, "end_line", 0), .character = argInt(args, "end_char", 0) },
        },
        .context = .{},
    }) catch |err| return backendErrorResult(allocator, "zls", "textDocument/codeAction", err, "ZLS request failed; check whether ZLS supports code actions for this file");
    defer allocator.free(response);
    return lspStructuredTool(allocator, "textDocument/codeAction", response);
}

pub fn zigCodeActionApply(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (requireZlsCapability(a, allocator, "textDocument/codeAction")) |result| return result;
    var doc = zlsDocumentFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "textDocument/codeAction", argString(args, "file"), err);
    defer doc.deinit(allocator);
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        range: struct {
            start: struct { line: i64, character: i64 },
            end: struct { line: i64, character: i64 },
        },
        context: struct { diagnostics: []const std.json.Value = &.{} },
    };
    a.zls_requests += 1;
    const response = client.sendRequest(allocator, "textDocument/codeAction", Params{
        .textDocument = .{ .uri = doc.uri },
        .range = .{
            .start = .{ .line = argInt(args, "start_line", 0), .character = argInt(args, "start_char", 0) },
            .end = .{ .line = argInt(args, "end_line", 0), .character = argInt(args, "end_char", 0) },
        },
        .context = .{},
    }) catch |err| return backendErrorResult(allocator, "zls", "textDocument/codeAction", err, "ZLS request failed; check whether ZLS supports code actions for this file");
    defer allocator.free(response);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch |err| return lspToolError(allocator, "zig_code_action_apply", "textDocument/codeAction", "parse_response", "malformed_backend_response", err, "Retry after checking the ZLS session; the response was not valid JSON.");
    defer parsed.deinit();
    const result = responseResult(parsed.value) orelse return lspShapeError(allocator, "zig_code_action_apply", "textDocument/codeAction", "read_result", "missing_result", "ZLS returned a response without a result field; retry after checking the ZLS session.");
    const actions = switch (result) {
        .array => |array| array,
        else => return lspShapeError(allocator, "zig_code_action_apply", "textDocument/codeAction", "read_actions", "invalid_result_shape", "ZLS codeAction result must be an array before an action can be selected."),
    };
    const action_index = argInt(args, "action_index", -1);
    if (action_index < 0 or action_index >= actions.items.len) return toolErrorResult(allocator, .{
        .tool = "zig_code_action_apply",
        .operation = "select_code_action",
        .phase = "validate_action_index",
        .code = "invalid_action_index",
        .category = "argument",
        .resolution = "Call zig_code_actions first, then retry with an action_index within the returned action list.",
        .details = &.{
            .{ .key = "action_index", .value = .{ .integer = action_index } },
            .{ .key = "action_count", .value = .{ .integer = @intCast(actions.items.len) } },
        },
    });
    const action = actions.items[@intCast(action_index)];
    const action_obj = switch (action) {
        .object => |o| o,
        else => return lspShapeError(allocator, "zig_code_action_apply", "textDocument/codeAction", "read_selected_action", "invalid_action_shape", "The selected ZLS code action was not an object; choose a different action_index or inspect zig_code_actions output."),
    };

    var out = std.json.ObjectMap.empty;
    errdefer out.deinit(allocator);
    out.put(allocator, "selected_index", .{ .integer = action_index }) catch return error.OutOfMemory;
    out.put(allocator, "action", json_result.cloneValue(allocator, action) catch return error.OutOfMemory) catch return error.OutOfMemory;
    out.put(allocator, "applied", .{ .bool = argBool(args, "apply", false) }) catch return error.OutOfMemory;

    if (action_obj.get("edit")) |edit| {
        const apply = argBool(args, "apply", false);
        if (apply and !doc.canApplyToDisk()) return zls_document.unsavedApplyError(allocator, "zig_code_action_apply", "workspaceEdit", doc);
        out.put(allocator, "workspace_edit", workspaceEditValueForDocument(a, allocator, edit, apply, doc) catch |err| return lspToolError(allocator, "zig_code_action_apply", "workspaceEdit", "preview_or_apply_edit", "workspace_edit_failed", err, "Inspect the code action edit and retry with paths that remain inside the zigar workspace.")) catch return error.OutOfMemory;
    } else if (action_obj.get("command")) |cmd| {
        out.put(allocator, "command", json_result.cloneValue(allocator, cmd) catch return error.OutOfMemory) catch return error.OutOfMemory;
        const cmd_obj = switch (cmd) {
            .object => |o| o,
            else => {
                out.put(allocator, "note", .{ .string = "code action command has an invalid shape" }) catch return error.OutOfMemory;
                return structured(allocator, .{ .object = out });
            },
        };
        const command_name = switch (cmd_obj.get("command") orelse .null) {
            .string => |s| s,
            else => "",
        };
        if (argBool(args, "apply", false) and !doc.canApplyToDisk()) {
            return zls_document.unsavedApplyError(allocator, "zig_code_action_apply", "workspace/executeCommand", doc);
        } else if (argBool(args, "apply", false) and isAllowedZlsCommand(command_name)) {
            const ExecuteParams = struct {
                command: []const u8,
                arguments: ?std.json.Value = null,
            };
            a.zls_requests += 1;
            const exec_response = client.sendRequest(allocator, "workspace/executeCommand", ExecuteParams{
                .command = command_name,
                .arguments = cmd_obj.get("arguments"),
            }) catch |err| return backendErrorResult(allocator, "zls", "workspace/executeCommand", err, "ZLS command execution failed; retry after checking the ZLS session status");
            defer allocator.free(exec_response);
            out.put(allocator, "execute_response", lspStructuredValue(allocator, "workspace/executeCommand", exec_response) catch |err| return lspToolError(allocator, "zig_code_action_apply", "workspace/executeCommand", "parse_execute_response", "malformed_backend_response", err, "Retry after checking the ZLS session; the executeCommand response was not valid structured JSON.")) catch return error.OutOfMemory;
        } else if (argBool(args, "apply", false)) {
            out.put(allocator, "note", .{ .string = "code action command is not on zigar's explicit allowlist" }) catch return error.OutOfMemory;
        } else {
            out.put(allocator, "note", .{ .string = "code action contains a command; pass apply=true to execute only if it is allowlisted" }) catch return error.OutOfMemory;
        }
    } else {
        out.put(allocator, "note", .{ .string = "code action has no workspace edit" }) catch return error.OutOfMemory;
    }
    return structured(allocator, .{ .object = out });
}

pub fn isAllowedZlsCommand(command_name: []const u8) bool {
    return std.mem.eql(u8, command_name, "source.organizeImports") or
        std.mem.eql(u8, command_name, "zls.organizeImports") or
        std.mem.eql(u8, command_name, "zls.applyCodeAction");
}

fn fileToolError(
    allocator: std.mem.Allocator,
    tool: []const u8,
    operation: []const u8,
    phase: []const u8,
    code: []const u8,
    category: []const u8,
    file: []const u8,
    err: anyerror,
    resolution: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorFromError(allocator, .{
        .tool = tool,
        .operation = operation,
        .phase = phase,
        .code = code,
        .category = category,
        .resolution = resolution,
        .details = &.{.{ .key = "file", .value = .{ .string = file } }},
    }, err);
}

fn lspToolError(allocator: std.mem.Allocator, tool: []const u8, operation: []const u8, phase: []const u8, code: []const u8, err: anyerror, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorFromError(allocator, .{ .tool = tool, .operation = operation, .phase = phase, .code = code, .category = "lsp", .resolution = resolution }, err);
}

fn lspShapeError(allocator: std.mem.Allocator, tool: []const u8, operation: []const u8, phase: []const u8, code: []const u8, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorResult(allocator, .{ .tool = tool, .operation = operation, .phase = phase, .code = code, .category = "lsp", .resolution = resolution });
}

pub fn zigDocumentOpen(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_document_open", "file", "string");
    const content = argString(args, "content") orelse return missingArgumentResult(allocator, "zig_document_open", "content", "string");
    zls_session.ensureReady(a) catch |err| return backendErrorResult(allocator, "zls", "zig_document_open", err, "confirm --zls-path points to a compatible ZLS binary before opening unsaved document content");
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const doc_state = a.doc_state orelse return zlsUnavailable(a, allocator);
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_document_open", file, err);
    defer allocator.free(resolved);
    const uri = doc_state.syncText(client, resolved, content, allocator) catch |err| return zlsSetupErrorResult(a, allocator, "zig_document_open", file, err);
    defer allocator.free(uri);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "uri", .{ .string = uri }) catch return error.OutOfMemory;
    obj.put(allocator, "version", .{ .integer = doc_state.versionForUri(uri) orelse 0 }) catch return error.OutOfMemory;
    obj.put(allocator, "open", .{ .bool = true }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigDocumentClose(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_document_close", "file", "string");
    zls_session.ensureReady(a) catch |err| return backendErrorResult(allocator, "zls", "zig_document_close", err, "confirm --zls-path points to a compatible ZLS binary before closing document state");
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const doc_state = a.doc_state orelse return zlsUnavailable(a, allocator);
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_document_close", file, err);
    defer allocator.free(resolved);
    const uri = uri_util.pathToUri(allocator, resolved) catch return error.OutOfMemory;
    defer allocator.free(uri);
    doc_state.closeDoc(client, uri) catch |err| return lspToolError(allocator, "zig_document_close", "textDocument/didClose", "notify_close", "document_close_failed", err, "Check the ZLS session status, then retry closing the document.");

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "uri", .{ .string = uri }) catch return error.OutOfMemory;
    obj.put(allocator, "open", .{ .bool = false }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigDocumentStatus(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_document_status", "file", "string");
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_document_status", file, err);
    defer allocator.free(resolved);
    const uri = uri_util.pathToUri(allocator, resolved) catch return error.OutOfMemory;
    defer allocator.free(uri);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "file", .{ .string = file }) catch return error.OutOfMemory;
    obj.put(allocator, "uri", .{ .string = uri }) catch return error.OutOfMemory;
    if (a.doc_state) |doc_state| {
        if (doc_state.statusForUri(uri)) |status| {
            obj.put(allocator, "open", .{ .bool = true }) catch return error.OutOfMemory;
            obj.put(allocator, "version", .{ .integer = status.version }) catch return error.OutOfMemory;
            obj.put(allocator, "dirty", .{ .bool = status.dirty }) catch return error.OutOfMemory;
            obj.put(allocator, "content_hash", .{ .string = std.fmt.allocPrint(allocator, "{x:0>16}", .{status.content_hash}) catch return error.OutOfMemory }) catch return error.OutOfMemory;
            obj.put(allocator, "content_bytes", .{ .integer = @intCast(status.content_bytes) }) catch return error.OutOfMemory;
            obj.put(allocator, "retained_content_bytes", .{ .integer = @intCast(status.retained_content_bytes) }) catch return error.OutOfMemory;
            obj.put(allocator, "open_documents", .{ .integer = @intCast(status.open_documents) }) catch return error.OutOfMemory;
            obj.put(allocator, "max_document_bytes", .{ .integer = @intCast(status.max_document_bytes) }) catch return error.OutOfMemory;
            obj.put(allocator, "max_retained_content_bytes", .{ .integer = @intCast(status.max_retained_content_bytes) }) catch return error.OutOfMemory;
            obj.put(allocator, "max_open_documents", .{ .integer = @intCast(status.max_open_documents) }) catch return error.OutOfMemory;
            obj.put(allocator, "last_reopen", reopenSummaryValue(allocator, status.last_reopen) catch return error.OutOfMemory) catch return error.OutOfMemory;
            return structured(allocator, .{ .object = obj });
        }
    }
    obj.put(allocator, "open", .{ .bool = false }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn reopenSummaryValue(allocator: std.mem.Allocator, summary: zigar.document_state.DocumentState.ReopenSummary) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "attempted", .{ .integer = @intCast(summary.attempted) });
    try obj.put(allocator, "succeeded", .{ .integer = @intCast(summary.succeeded) });
    try obj.put(allocator, "skipped", .{ .integer = @intCast(summary.skipped) });
    try obj.put(allocator, "failed", .{ .integer = @intCast(summary.failed) });
    return .{ .object = obj };
}

pub fn zigRename(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (requireZlsCapability(a, allocator, "textDocument/rename")) |result| return result;
    const new_name = argString(args, "new_name") orelse return missingArgumentResult(allocator, "zig_rename", "new_name", "string");
    var doc = zlsDocumentFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "textDocument/rename", argString(args, "file"), err);
    defer doc.deinit(allocator);
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        position: struct { line: i64, character: i64 },
        newName: []const u8,
    };
    a.zls_requests += 1;
    const response = client.sendRequest(allocator, "textDocument/rename", Params{
        .textDocument = .{ .uri = doc.uri },
        .position = .{ .line = argInt(args, "line", 0), .character = argInt(args, "character", 0) },
        .newName = new_name,
    }) catch |err| return backendErrorResult(allocator, "zls", "textDocument/rename", err, "ZLS rename failed; confirm the symbol location and ZLS session status");
    defer allocator.free(response);

    if (argBool(args, "apply", false)) {
        if (!doc.canApplyToDisk()) return zls_document.unsavedApplyError(allocator, "zig_rename", "textDocument/rename", doc);
        return workspaceEditToolResultForDocument(a, allocator, response, true, doc);
    }

    return workspaceEditToolResultForDocument(a, allocator, response, false, doc);
}

pub fn zigDiagnostics(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_diagnostics", "file", "string");
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "zig_diagnostics", file, err);
    defer allocator.free(file_uri);
    const client = a.lsp_client orelse return zigCheck(a, allocator, args);

    const Params = struct { textDocument: struct { uri: []const u8 } };
    const pull = client.sendRequest(allocator, "textDocument/diagnostic", Params{ .textDocument = .{ .uri = file_uri } }) catch null;
    if (pull) |response| {
        defer allocator.free(response);
        if (!lspHasError(allocator, response)) {
            return lspStructuredTool(allocator, "textDocument/diagnostic", response);
        }
    }

    const wait_ms = diagnosticWaitMs(args);
    waitForDiagnostics(a, client, file_uri, wait_ms);
    if (client.getDiagnostics(allocator, file_uri) catch null) |diagnostics| {
        defer allocator.free(diagnostics);
        const value = diagnosticsStructuredValue(allocator, diagnostics) catch |err| return lspToolError(allocator, "zig_diagnostics", "textDocument/publishDiagnostics", "parse_notification", "malformed_diagnostics", err, "Retry after checking the ZLS session; the diagnostics notification was not valid JSON.");
        return structured(allocator, value);
    }
    return zigCheck(a, allocator, args);
}

pub fn zigDiagnosticsAll(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_diagnostics_all", "file", "string");
    const file_uri = zlsFileUriFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "zig_diagnostics_all", file, err);
    defer allocator.free(file_uri);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "file", .{ .string = file }) catch return error.OutOfMemory;
    obj.put(allocator, "uri", .{ .string = file_uri }) catch return error.OutOfMemory;
    var sources = std.json.Array.init(allocator);

    if (a.lsp_client) |client| {
        const Params = struct { textDocument: struct { uri: []const u8 } };
        const pull = client.sendRequest(allocator, "textDocument/diagnostic", Params{ .textDocument = .{ .uri = file_uri } }) catch null;
        if (pull) |response| {
            defer allocator.free(response);
            sources.append(lspStructuredValue(allocator, "textDocument/diagnostic", response) catch |err| return lspToolError(allocator, "zig_diagnostics_all", "textDocument/diagnostic", "parse_response", "malformed_backend_response", err, "Retry after checking the ZLS session; the diagnostics response was not valid structured JSON.")) catch return error.OutOfMemory;
        }

        const wait_ms = diagnosticWaitMs(args);
        waitForDiagnostics(a, client, file_uri, wait_ms);
        if (client.getDiagnostics(allocator, file_uri) catch null) |diagnostics| {
            defer allocator.free(diagnostics);
            sources.append(diagnosticsStructuredValue(allocator, diagnostics) catch |err| return lspToolError(allocator, "zig_diagnostics_all", "textDocument/publishDiagnostics", "parse_notification", "malformed_diagnostics", err, "Retry after checking the ZLS session; the diagnostics notification was not valid JSON.")) catch return error.OutOfMemory;
        }
    }

    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_diagnostics_all", file, err);
    defer allocator.free(resolved);
    const ast = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zig_path, "ast-check", resolved }, toolTimeout(a, args)) catch |err| {
        var err_obj = std.json.ObjectMap.empty;
        err_obj.put(allocator, "method", .{ .string = "zig ast-check" }) catch return error.OutOfMemory;
        err_obj.put(allocator, "ok", .{ .bool = false }) catch return error.OutOfMemory;
        err_obj.put(allocator, "error", .{ .string = @errorName(err) }) catch return error.OutOfMemory;
        sources.append(.{ .object = err_obj }) catch return error.OutOfMemory;
        obj.put(allocator, "sources", .{ .array = sources }) catch return error.OutOfMemory;
        return structured(allocator, .{ .object = obj });
    };
    defer ast.deinit(allocator);
    sources.append(commandResultValue(allocator, "zig ast-check", &.{ a.config.zig_path, "ast-check", resolved }, a.workspace.root, toolTimeout(a, args), ast) catch return error.OutOfMemory) catch return error.OutOfMemory;
    obj.put(allocator, "sources", .{ .array = sources }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigDiagnosticsWorkspace(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const client = a.lsp_client orelse return structuredText(allocator, "zig_diagnostics_workspace", "ZLS session is unavailable; no workspace diagnostics cache exists.");
    const snapshot = client.diagnosticsSnapshot(allocator) catch |err| return lspToolError(allocator, "zig_diagnostics_workspace", "textDocument/publishDiagnostics", "read_snapshot", "diagnostics_snapshot_failed", err, "Retry after checking the ZLS session diagnostics cache.");
    defer {
        for (snapshot) |item| allocator.free(item);
        allocator.free(snapshot);
    }

    var files = std.json.Array.init(allocator);
    var total: usize = 0;
    var errors: usize = 0;
    var warnings: usize = 0;
    var info: usize = 0;
    var hints: usize = 0;

    for (snapshot) |notification| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, notification, .{}) catch continue;
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };
        const params = switch (obj.get("params") orelse .null) {
            .object => |o| o,
            else => continue,
        };
        const uri = switch (params.get("uri") orelse .null) {
            .string => |s| s,
            else => "",
        };
        const diagnostics = switch (params.get("diagnostics") orelse .null) {
            .array => |array| array,
            else => continue,
        };
        var file_errors: usize = 0;
        var file_warnings: usize = 0;
        var file_info: usize = 0;
        var file_hints: usize = 0;
        for (diagnostics.items) |diag| {
            total += 1;
            const diag_obj = switch (diag) {
                .object => |o| o,
                else => continue,
            };
            const severity = switch (diag_obj.get("severity") orelse .null) {
                .integer => |i| i,
                else => 0,
            };
            switch (severity) {
                1 => {
                    errors += 1;
                    file_errors += 1;
                },
                2 => {
                    warnings += 1;
                    file_warnings += 1;
                },
                3 => {
                    info += 1;
                    file_info += 1;
                },
                4 => {
                    hints += 1;
                    file_hints += 1;
                },
                else => {},
            }
        }
        var file_obj = std.json.ObjectMap.empty;
        file_obj.put(allocator, "uri", .{ .string = uri }) catch return error.OutOfMemory;
        file_obj.put(allocator, "total", .{ .integer = @intCast(diagnostics.items.len) }) catch return error.OutOfMemory;
        file_obj.put(allocator, "errors", .{ .integer = @intCast(file_errors) }) catch return error.OutOfMemory;
        file_obj.put(allocator, "warnings", .{ .integer = @intCast(file_warnings) }) catch return error.OutOfMemory;
        file_obj.put(allocator, "information", .{ .integer = @intCast(file_info) }) catch return error.OutOfMemory;
        file_obj.put(allocator, "hints", .{ .integer = @intCast(file_hints) }) catch return error.OutOfMemory;
        files.append(.{ .object = file_obj }) catch return error.OutOfMemory;
    }

    var out = std.json.ObjectMap.empty;
    errdefer out.deinit(allocator);
    out.put(allocator, "files", .{ .array = files }) catch return error.OutOfMemory;
    out.put(allocator, "total", .{ .integer = @intCast(total) }) catch return error.OutOfMemory;
    out.put(allocator, "errors", .{ .integer = @intCast(errors) }) catch return error.OutOfMemory;
    out.put(allocator, "warnings", .{ .integer = @intCast(warnings) }) catch return error.OutOfMemory;
    out.put(allocator, "information", .{ .integer = @intCast(info) }) catch return error.OutOfMemory;
    out.put(allocator, "hints", .{ .integer = @intCast(hints) }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = out });
}

pub fn zigFormatZls(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, apply: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (requireZlsCapability(a, allocator, "textDocument/formatting")) |result| return result;
    var doc = zlsDocumentFromArgs(a, allocator, args) catch |err| return zlsSetupErrorResult(a, allocator, "textDocument/formatting", argString(args, "file"), err);
    defer doc.deinit(allocator);
    const client = a.lsp_client orelse return zlsUnavailable(a, allocator);
    const doc_state = a.doc_state orelse return zlsUnavailable(a, allocator);
    const Params = struct {
        textDocument: struct { uri: []const u8 },
        options: struct { tabSize: i64 = 4, insertSpaces: bool = true },
    };
    a.zls_requests += 1;
    const response = client.sendRequest(allocator, "textDocument/formatting", Params{
        .textDocument = .{ .uri = doc.uri },
        .options = .{},
    }) catch |err| return backendErrorResult(allocator, "zls", "textDocument/formatting", err, "ZLS formatting failed; zig_format can fall back to zig fmt when the ZLS session is unavailable");
    defer allocator.free(response);

    if (apply) {
        if (!doc.canApplyToDisk()) return zls_document.unsavedApplyError(allocator, "zig_format", "textDocument/formatting", doc);
        const value = textEditToolValueForDocument(a, allocator, doc, response, true) catch |err| return lspToolError(allocator, "zig_format", "textDocument/formatting", "apply_text_edits", "text_edit_apply_failed", err, "Retry with a ZLS-openable file whose URI resolves inside the zigar workspace.");
        doc_state.closeDoc(client, doc.uri) catch {};
        return structuredOwned(allocator, value);
    }

    const value = textEditToolValueForDocument(a, allocator, doc, response, false) catch |err| return lspToolError(allocator, "zig_format", "textDocument/formatting", "preview_text_edits", "text_edit_preview_failed", err, "Retry with a ZLS-openable file whose URI resolves inside the zigar workspace.");
    return structuredOwned(allocator, value);
}

pub fn workspaceEditToolResult(a: *App, allocator: std.mem.Allocator, response: []const u8, apply: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    return workspaceEditToolResultForDocument(a, allocator, response, apply, null);
}

pub fn workspaceEditToolResultForDocument(a: *App, allocator: std.mem.Allocator, response: []const u8, apply: bool, primary_doc: ?common.ZlsDocument) mcp.tools.ToolError!mcp.tools.ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch |err| return lspToolError(allocator, "workspace_edit", "workspace/applyEdit", "parse_response", "malformed_backend_response", err, "Retry after checking the ZLS session; the workspace edit response was not valid JSON.");
    defer parsed.deinit();
    const result = responseResult(parsed.value) orelse .null;
    const value = workspaceEditValueForDocument(a, allocator, result, apply, primary_doc) catch |err| return lspToolError(allocator, "workspace_edit", "workspace/applyEdit", "preview_or_apply_edit", "workspace_edit_failed", err, "Inspect the workspace edit and retry with paths that remain inside the zigar workspace.");
    return structuredOwned(allocator, value);
}

pub fn zigWorkspaceSymbols(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const query = argString(args, "query") orelse return missingArgumentResult(allocator, "zig_workspace_symbols", "query", "string");
    if (a.lsp_client) |client| {
        if (requireZlsCapability(a, allocator, "workspace/symbol")) |result| return result;
        const Params = struct { query: []const u8 };
        a.zls_requests += 1;
        const response = client.sendRequest(allocator, "workspace/symbol", Params{ .query = query }) catch |err| return backendErrorResult(allocator, "zls", "workspace/symbol", err, "ZLS workspace symbol search failed; zigar will use heuristic analysis when no ZLS client is available");
        defer allocator.free(response);
        return lspStructuredTool(allocator, "workspace/symbol", response);
    }
    const graph = analysis.importGraph(allocator, a.io, a.workspace.root, @intCast(@max(1, argInt(args, "limit", 200)))) catch |err| return toolErrorFromError(allocator, .{
        .tool = "zig_workspace_symbols",
        .operation = "heuristic_symbol_search",
        .phase = "build_import_graph",
        .code = "heuristic_search_failed",
        .category = "analysis",
        .resolution = "Run zig_import_graph_json or configure ZLS, then retry workspace symbol search.",
    }, err);
    defer allocator.free(graph);
    const msg = std.fmt.allocPrint(allocator, "Heuristic workspace symbol search for `{s}` is currently import/declaration text based.\n\n{s}", .{ query, graph }) catch return error.OutOfMemory;
    defer allocator.free(msg);
    return structuredText(allocator, "zig_workspace_symbols_fallback", msg);
}
