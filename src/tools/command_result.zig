const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const command = zigar.command;
const command_output = zigar.command_output;

fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

pub fn commandTermValue(allocator: std.mem.Allocator, term: std.process.Child.Term) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    switch (term) {
        .exited => |code| {
            try obj.put(allocator, "kind", .{ .string = "exited" });
            try obj.put(allocator, "code", .{ .integer = @intCast(code) });
        },
        .signal => {
            try obj.put(allocator, "kind", .{ .string = "signal" });
        },
        .stopped => {
            try obj.put(allocator, "kind", .{ .string = "stopped" });
        },
        .unknown => {
            try obj.put(allocator, "kind", .{ .string = "unknown" });
        },
    }
    return .{ .object = obj };
}

pub fn commandResultValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, result: command.RunResult) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "command" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = result.succeeded() });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "term", try commandTermValue(allocator, result.term));
    const stdout = try command_output.safeTextAlloc(allocator, result.stdout);
    const stderr = try command_output.safeTextAlloc(allocator, result.stderr);
    try command_output.putStreamFields(allocator, &obj, "stdout", stdout);
    try command_output.putStreamFields(allocator, &obj, "stderr", stderr);
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(result.stdout_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(result.stderr_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = command.output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = result.stdout_truncated or result.stderr_truncated });
    if (result.stdout_truncated or result.stderr_truncated) {
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigar's capture limit. zigar returned the captured prefix and marked the truncated stream so the result remains inspectable." });
    }
    const insights = try compilerInsightsValue(allocator, stdout.text, stderr.text, argv);
    try obj.put(allocator, "diagnostics", insights);
    try obj.put(allocator, "failure_summary", try failureSummaryValue(allocator, insights, result.succeeded(), argv));
    return .{ .object = obj };
}

pub fn commandErrorValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "command_error" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = command.errorKind(err) });
    try obj.put(allocator, "stdout_limit", .{ .integer = command.output_limit });
    try obj.put(allocator, "stderr_limit", .{ .integer = command.output_limit });
    try obj.put(allocator, "output_limit_mode", .{ .string = command.output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = command.isOutputLimitError(err) });
    try obj.put(allocator, "stdout_truncated", .{ .bool = false });
    try obj.put(allocator, "stderr_truncated", .{ .bool = false });
    if (command.isOutputLimitError(err)) {
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigar's capture limit before zigar could retain a bounded prefix. Narrow the command or run it directly when full output is needed." });
    }
    try obj.put(allocator, "failure_summary", try commandErrorSummaryValue(allocator, err, argv));
    return .{ .object = obj };
}

pub fn failureSummaryValue(allocator: std.mem.Allocator, insights: std.json.Value, ok: bool, argv: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
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

pub fn commandErrorSummaryValue(allocator: std.mem.Allocator, err: anyerror, argv: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "primary", .null);
    try obj.put(allocator, "error_class", .{ .string = command.errorKind(err) });
    try obj.put(allocator, "rerun_command", .{ .string = try commandString(allocator, argv) });
    var suggested = std.json.Array.init(allocator);
    try suggested.append(try ownedString(allocator, "zigar_doctor"));
    try suggested.append(try ownedString(allocator, "zigar_context_pack"));
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", .{ .string = if (command.isTimeoutError(err)) "command_timeout" else "tool_or_backend_configuration" });
    return .{ .object = obj };
}

pub fn likelyFailureScopeValue(allocator: std.mem.Allocator, primary: std.json.Value) !std.json.Value {
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

pub const CompilerLine = struct {
    severity: []const u8,
    path: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
    message: []const u8,
    raw: []const u8,
};

pub fn compilerInsightsValue(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8, argv: []const []const u8) !std.json.Value {
    var findings = std.json.Array.init(allocator);
    var error_count: i64 = 0;
    var warning_count: i64 = 0;
    var note_count: i64 = 0;
    var primary: ?CompilerLine = null;

    try collectCompilerLines(allocator, &findings, stderr, &primary, &error_count, &warning_count, &note_count);
    try collectCompilerLines(allocator, &findings, stdout, &primary, &error_count, &warning_count, &note_count);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try obj.put(allocator, "error_count", .{ .integer = error_count });
    try obj.put(allocator, "warning_count", .{ .integer = warning_count });
    try obj.put(allocator, "note_count", .{ .integer = note_count });
    try obj.put(allocator, "findings", .{ .array = findings });
    if (primary) |p| {
        try obj.put(allocator, "primary", try compilerLineValue(allocator, p));
        try obj.put(allocator, "category", .{ .string = classifyDiagnosticMessage(p.message) });
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

pub fn collectCompilerLines(
    allocator: std.mem.Allocator,
    findings: *std.json.Array,
    text_value: []const u8,
    primary: *?CompilerLine,
    error_count: *i64,
    warning_count: *i64,
    note_count: *i64,
) !void {
    var lines = std.mem.splitScalar(u8, text_value, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        const parsed = parseCompilerLine(line) orelse continue;
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

pub fn parseCompilerLine(line: []const u8) ?CompilerLine {
    if (parseLocatedCompilerLine(line, "error")) |parsed| return parsed;
    if (parseLocatedCompilerLine(line, "warning")) |parsed| return parsed;
    if (parseLocatedCompilerLine(line, "note")) |parsed| return parsed;
    if (std.mem.startsWith(u8, line, "error: ")) return .{ .severity = "error", .message = line["error: ".len..], .raw = line };
    if (std.mem.startsWith(u8, line, "warning: ")) return .{ .severity = "warning", .message = line["warning: ".len..], .raw = line };
    if (std.mem.startsWith(u8, line, "note: ")) return .{ .severity = "note", .message = line["note: ".len..], .raw = line };
    return null;
}

pub fn parseLocatedCompilerLine(line: []const u8, severity: []const u8) ?CompilerLine {
    var token_buf: [16]u8 = undefined;
    const token = std.fmt.bufPrint(&token_buf, ": {s}: ", .{severity}) catch return null;
    const severity_pos = std.mem.indexOf(u8, line, token) orelse return null;
    const prefix = line[0..severity_pos];
    const message = line[severity_pos + token.len ..];
    const col_sep = std.mem.lastIndexOfScalar(u8, prefix, ':') orelse return .{ .severity = severity, .message = message, .raw = line };
    const line_prefix = prefix[0..col_sep];
    const line_sep = std.mem.lastIndexOfScalar(u8, line_prefix, ':') orelse return .{ .severity = severity, .message = message, .raw = line };
    const line_no = std.fmt.parseInt(i64, line_prefix[line_sep + 1 ..], 10) catch return .{ .severity = severity, .message = message, .raw = line };
    const col_no = std.fmt.parseInt(i64, prefix[col_sep + 1 ..], 10) catch return .{ .severity = severity, .message = message, .raw = line };
    return .{
        .severity = severity,
        .path = line_prefix[0..line_sep],
        .line = line_no,
        .column = col_no,
        .message = message,
        .raw = line,
    };
}

pub fn compilerLineValue(allocator: std.mem.Allocator, parsed: CompilerLine) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "severity", .{ .string = parsed.severity });
    try obj.put(allocator, "message", try ownedString(allocator, parsed.message));
    try obj.put(allocator, "raw", try ownedString(allocator, parsed.raw));
    if (parsed.path) |path| {
        try obj.put(allocator, "path", try ownedString(allocator, path));
    } else {
        try obj.put(allocator, "path", .null);
    }
    if (parsed.line) |line_no| {
        try obj.put(allocator, "line", .{ .integer = line_no });
    } else {
        try obj.put(allocator, "line", .null);
    }
    if (parsed.column) |col_no| {
        try obj.put(allocator, "column", .{ .integer = col_no });
    } else {
        try obj.put(allocator, "column", .null);
    }
    return .{ .object = obj };
}

pub fn classifyDiagnosticMessage(message: []const u8) []const u8 {
    if (std.mem.indexOf(u8, message, "expected type") != null) return "type_mismatch";
    if (std.mem.indexOf(u8, message, "expected ") != null and std.mem.indexOf(u8, message, "found ") != null) return "syntax_or_type_mismatch";
    if (std.mem.indexOf(u8, message, "expected ") != null) return "syntax_error";
    if (std.mem.indexOf(u8, message, "use of undeclared identifier") != null) return "undeclared_identifier";
    if (std.mem.indexOf(u8, message, "no field named") != null) return "missing_field";
    if (std.mem.indexOf(u8, message, "unable to load") != null or std.mem.indexOf(u8, message, "FileNotFound") != null) return "missing_file_or_import";
    if (std.mem.indexOf(u8, message, "unused") != null) return "unused_code";
    if (std.mem.indexOf(u8, message, "invalid token") != null) return "syntax_error";
    return "compiler_error";
}

pub fn compilerNextCommand(allocator: std.mem.Allocator, primary: CompilerLine, argv: []const []const u8) !std.json.Value {
    const zig = if (argv.len > 0) argv[0] else "zig";
    const path = primary.path orelse return .{ .string = try commandString(allocator, argv) };
    if (path.len > 0 and std.mem.endsWith(u8, path, ".zig")) {
        if (argvContains(argv, "test")) {
            return .{ .string = try std.fmt.allocPrint(allocator, "{s} test {s}", .{ zig, path }) };
        }
        return .{ .string = try std.fmt.allocPrint(allocator, "{s} ast-check {s}", .{ zig, path }) };
    }
    return .{ .string = try commandString(allocator, argv) };
}

pub fn compilerNextActions(allocator: std.mem.Allocator, primary: CompilerLine, note_count: i64) !std.json.Value {
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
    if (note_count > 0) {
        try actions.append(try ownedString(allocator, "Review compiler note entries before editing; Zig often puts the fix-relevant type or declaration context there."));
    }
    if (std.mem.eql(u8, classifyDiagnosticMessage(primary.message), "missing_file_or_import")) {
        try actions.append(try ownedString(allocator, "Run zig_import_resolve for the failing @import name, then check build.zig addImport and build.zig.zon dependency wiring."));
    }
    try actions.append(try ownedString(allocator, "Rerun the next_command after the focused edit."));
    return .{ .array = actions };
}

pub fn commandString(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    if (argv.len == 0) return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

pub fn argvContains(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

pub fn argvValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (argv) |arg| try array.append(.{ .string = arg });
    return .{ .array = array };
}

test "commandResultValue sanitizes invalid UTF-8 command streams and diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stderr = try allocator.dupe(u8, "src/main.zig:1:1: error: bad \xff\n");
    const result = command.RunResult{
        .term = .{ .exited = 1 },
        .stdout = try allocator.dupe(u8, "ok\n"),
        .stderr = stderr,
    };
    const value = try commandResultValue(allocator, "zig test", &.{ "zig", "test" }, ".", 1000, result);
    const obj = value.object;

    try std.testing.expectEqualStrings("ok\n", obj.get("stdout").?.string);
    try std.testing.expect(!obj.get("stdout_invalid_utf8").?.bool);
    try std.testing.expect(obj.get("stderr_invalid_utf8").?.bool);
    try std.testing.expectEqualStrings("utf-8-lossy", obj.get("stderr_encoding").?.string);
    try std.testing.expect(std.unicode.utf8ValidateSlice(obj.get("stderr").?.string));

    const primary = obj.get("diagnostics").?.object.get("primary").?.object;
    try std.testing.expect(std.unicode.utf8ValidateSlice(primary.get("message").?.string));
    try std.testing.expect(std.mem.indexOf(u8, primary.get("message").?.string, &std.unicode.replacement_character_utf8) != null);

    const bytes = try zigar.json_result.serializeAlloc(allocator, value);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bytes));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("stderr_invalid_utf8").?.bool);
}

const CommandResultTestTransport = struct {
    messages: []const []const u8,
    index: usize = 0,
    sent: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *CommandResultTestTransport, allocator: std.mem.Allocator) void {
        for (self.sent.items) |message| allocator.free(message);
        self.sent.deinit(allocator);
    }

    fn transport(self: *CommandResultTestTransport) mcp.transport.Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = sendVtable,
                .receive = receiveVtable,
                .close = closeVtable,
            },
        };
    }

    fn sendVtable(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator, message: []const u8) mcp.transport.Transport.SendError!void {
        const self: *CommandResultTestTransport = @ptrCast(@alignCast(ptr));
        const owned = allocator.dupe(u8, message) catch return error.OutOfMemory;
        self.sent.append(allocator, owned) catch {
            allocator.free(owned);
            return error.OutOfMemory;
        };
    }

    fn receiveVtable(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator) mcp.transport.Transport.ReceiveError!?[]const u8 {
        const self: *CommandResultTestTransport = @ptrCast(@alignCast(ptr));
        if (self.index >= self.messages.len) return error.EndOfStream;
        const message = self.messages[self.index];
        self.index += 1;
        return message;
    }

    fn closeVtable(_: *anyopaque) void {}
};

fn invalidUtf8CommandToolHandler(_: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) !mcp.tools.ToolResult {
    const result = command.RunResult{
        .term = .{ .exited = 0 },
        .stdout = try allocator.dupe(u8, "ok \xff\n"),
        .stderr = try allocator.dupe(u8, ""),
    };
    defer result.deinit(allocator);
    const value = try commandResultValue(allocator, "invalid utf8 fixture", &.{"fixture"}, ".", 1000, result);
    return zigar.json_result.structured(allocator, value);
}

test "MCP command-backed tool response parses with invalid UTF-8 output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: zigar.mcp_server.Server = .init(allocator, .{
        .name = "utf8-server",
        .version = "1.0.0",
    });
    defer server.deinit();
    try server.addTool(.{
        .name = "invalid_utf8_tool",
        .description = "Returns invalid command bytes",
        .handler = invalidUtf8CommandToolHandler,
    });

    const messages = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"tester\",\"version\":\"1\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"invalid_utf8_tool\"}}",
    };
    var transport: CommandResultTestTransport = .{ .messages = messages[0..] };
    defer transport.deinit(allocator);

    try server.runWithTransport(std.testing.io, allocator, transport.transport());

    var saw_invalid_marker = false;
    for (transport.sent.items) |message| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(message));
        if (std.mem.indexOf(u8, message, "\"stdout_invalid_utf8\":true") != null) saw_invalid_marker = true;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, message, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("2.0", parsed.value.object.get("jsonrpc").?.string);
    }
    try std.testing.expect(saw_invalid_marker);
}
