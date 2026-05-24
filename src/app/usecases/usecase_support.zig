const std = @import("std");

const ports = @import("../ports.zig");
const zig_analysis = @import("../../domain/zig/analysis.zig");
const compiler_output = @import("../../domain/zig/compiler_output.zig");

pub const command_output_limit: usize = 1024 * 1024;
pub const command_output_limit_mode = "truncate_on_limit";
pub const source_read_limit: usize = 1024 * 1024;

pub const Result = struct {
    value: std.json.Value,
    is_error: bool = false,
};

pub const Probe = struct {
    ok: bool,
    status: []const u8,
    resolution: []const u8,
};

pub fn UsecaseApp(comptime Context: type) type {
    return struct {
        context: Context,
        allocator: std.mem.Allocator,
        io: void = {},
        config: Config,
        workspace: Workspace(Context),
        command_calls: usize = 0,
        tool_errors: usize = 0,

        pub fn init(context: Context, allocator: std.mem.Allocator) @This() {
            return .{
                .context = context,
                .allocator = allocator,
                .config = .{
                    .timeout_ms = context.timeouts.command_ms,
                    .zls_timeout_ms = context.timeouts.zls_ms,
                    .zig_path = context.tool_paths.zig,
                    .zls_path = context.tool_paths.zls,
                    .zlint_path = context.tool_paths.zlint,
                    .zwanzig_path = context.tool_paths.zwanzig,
                    .zflame_path = context.tool_paths.zflame,
                    .diff_folded_path = context.tool_paths.diff_folded,
                    .transport = if (std.mem.eql(u8, context.workspace.transport, "http")) .http else .stdio,
                },
                .workspace = Workspace(Context).init(context, allocator),
            };
        }
    };
}

pub const Config = struct {
    pub const Transport = enum { stdio, http };

    timeout_ms: i64,
    zls_timeout_ms: i64,
    zig_path: []const u8,
    zls_path: []const u8,
    zlint_path: []const u8,
    zwanzig_path: []const u8,
    zflame_path: []const u8,
    diff_folded_path: []const u8,
    transport: Transport = .stdio,
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
};

pub fn Workspace(comptime Context: type) type {
    return struct {
        context: Context,
        allocator: std.mem.Allocator,
        root: []const u8,
        cache_root: []const u8,

        const Self = @This();

        pub fn init(context: Context, allocator: std.mem.Allocator) Self {
            return .{
                .context = context,
                .allocator = allocator,
                .root = context.workspace.root,
                .cache_root = context.workspace.cache_root,
            };
        }

        pub fn resolve(self: Self, path: []const u8) ![]u8 {
            const resolved = try self.context.workspace_store.resolve(self.allocator, .{
                .path = path,
                .provenance = "arch110-workflow-resolve",
            });
            return @constCast(resolved.path);
        }

        pub fn resolveOutput(self: Self, path: []const u8) ![]u8 {
            const resolved = try self.context.workspace_store.resolve(self.allocator, .{
                .path = path,
                .for_output = true,
                .provenance = "arch110-workflow-resolve-output",
            });
            return @constCast(resolved.path);
        }

        pub fn readFileAlloc(self: Self, _: anytype, path: []const u8, max_bytes: usize) ![]u8 {
            const read = try self.context.workspace_store.read(self.allocator, .{
                .path = path,
                .max_bytes = max_bytes,
                .provenance = "arch110-workflow-read",
            });
            return @constCast(read.bytes);
        }

        pub fn putFile(self: Self, path: []const u8, bytes: []const u8) !void {
            _ = try self.context.workspace_store.write(.{
                .path = path,
                .bytes = bytes,
                .create_parent_dirs = true,
                .replace_existing = true,
                .provenance = "arch110-workflow-write",
            });
        }

        pub fn scanDirectory(self: Self, allocator: std.mem.Allocator, path: []const u8, max_files: ?usize) !ports.WorkspaceDirectoryScanResult {
            return self.context.workspace_store.scanDirectory(allocator, .{
                .path = path,
                .max_files = max_files,
                .provenance = "arch110-workflow-scan",
            });
        }

        pub fn exists(self: Self, allocator: std.mem.Allocator, path: []const u8, for_output: bool) bool {
            const result = self.context.workspace_store.exists(allocator, .{
                .path = path,
                .for_output = for_output,
                .provenance = "arch111-workflow-exists",
            }) catch return false;
            return result.exists;
        }

        pub fn ensureParentForAbsoluteOutput(self: Self, abs_path: []const u8) !void {
            const parent_abs = std.fs.path.dirname(abs_path) orelse return;
            const rel = relativeFromAbs(self.root, parent_abs) orelse return error.PathOutsideWorkspace;
            _ = try self.context.workspace_store.ensureDir(.{
                .path = rel,
                .provenance = "arch110-workflow-ensure-parent",
            });
        }
    };
}

pub const CommandRunResult = struct {
    term: ports.CommandTerm,
    stdout: []const u8,
    stderr: []const u8,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    duration_ms: i64 = 0,
    owns_stdout: bool = false,
    owns_stderr: bool = false,

    pub fn deinit(self: CommandRunResult, allocator: std.mem.Allocator) void {
        if (self.owns_stdout) allocator.free(self.stdout);
        if (self.owns_stderr) allocator.free(self.stderr);
    }

    pub fn succeeded(self: CommandRunResult) bool {
        return !self.term.failed();
    }
};

pub const command = struct {
    pub const RunResult = CommandRunResult;
    pub const output_limit = command_output_limit;
    pub const output_limit_mode = command_output_limit_mode;

    pub fn errorKind(err: anyerror) []const u8 {
        return kindForError(err);
    }

    pub fn isTimeoutError(err: anyerror) bool {
        return err == error.RequestTimeout or err == error.Timeout;
    }

    pub fn isOutputLimitError(err: anyerror) bool {
        return err == error.StreamTooLong or err == error.OutputLimitExceeded;
    }

    pub fn joinArgv(allocator: std.mem.Allocator, base: []const []const u8, extra: []const []const u8) ![]const []const u8 {
        var out = try std.ArrayList([]const u8).initCapacity(allocator, base.len + extra.len);
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, base);
        try out.appendSlice(allocator, extra);
        return out.toOwnedSlice(allocator);
    }
};

pub fn runCommand(allocator: std.mem.Allocator, app: anytype, argv: []const []const u8, timeout_ms: i64) !CommandRunResult {
    const result = try app.context.command_runner.run(allocator, .{
        .argv = argv,
        .cwd = app.workspace.root,
        .timeout_ms = @intCast(@max(1, timeout_ms)),
        .max_stdout_bytes = command_output_limit,
        .max_stderr_bytes = command_output_limit,
        .provenance = "arch110-workflow-command",
    });
    return .{
        .term = result.effectiveTerm(),
        .stdout = result.stdout,
        .stderr = result.stderr,
        .stdout_truncated = result.stdout_truncated,
        .stderr_truncated = result.stderr_truncated,
        .duration_ms = @intCast(result.duration_ms),
        .owns_stdout = result.owns_stdout,
        .owns_stderr = result.owns_stderr,
    };
}

pub fn checkBackend(app: anytype, allocator: std.mem.Allocator, name: []const u8, argv: []const []const u8, timeout_ms: i64) Probe {
    const backend_port = app.context.backend_probe orelse {
        return .{
            .ok = false,
            .status = "unavailable",
            .resolution = "backend probe port is not configured",
        };
    };
    var availability = backend_port.check(allocator, .{
        .backend = name,
        .argv = argv,
        .cwd = app.workspace.root,
        .timeout_ms = @intCast(@max(1, timeout_ms)),
        .provenance = "arch110-workflow-backend-check",
    }) catch |err| return .{
        .ok = false,
        .status = @errorName(err),
        .resolution = "confirm the configured backend path and executable permissions",
    };
    defer availability.deinit(allocator);
    return .{
        .ok = availability.available,
        .status = availability.unavailable_reason orelse if (availability.available) "ok" else "unavailable",
        .resolution = availability.basis,
    };
}

pub fn structured(allocator: std.mem.Allocator, value: std.json.Value) !Result {
    return .{ .value = try cloneValue(allocator, value) };
}

pub fn structuredError(allocator: std.mem.Allocator, value: std.json.Value) !Result {
    return .{ .value = try cloneValue(allocator, value), .is_error = true };
}

pub fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    const value = argValue(args, name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

pub fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    const value = argValue(args, name) orelse return default;
    return switch (value) {
        .bool => |b| b,
        else => default,
    };
}

pub fn argInt(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    const value = argValue(args, name) orelse return default;
    return switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch default,
        else => default,
    };
}

fn argValue(args: ?std.json.Value, name: []const u8) ?std.json.Value {
    const root = args orelse return null;
    if (root != .object) return null;
    return root.object.get(name);
}

pub fn toolTimeout(app: anytype, args: ?std.json.Value) i64 {
    return @max(1, @min(argInt(args, "timeout_ms", app.config.timeout_ms), 60 * 60 * 1000));
}

pub fn scratchApp(app: anytype, allocator: std.mem.Allocator) @TypeOf(app.*) {
    var copy = app.*;
    copy.allocator = allocator;
    copy.workspace.allocator = allocator;
    return copy;
}

pub fn missingArgumentResult(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, expected: []const u8) !Result {
    return structuredError(allocator, try argumentValue(allocator, tool_name, "missing_required_argument", field, expected, "missing"));
}

pub fn invalidArgumentResult(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, expected: []const u8, actual: []const u8, resolution: []const u8) !Result {
    return structuredError(allocator, try invalidArgumentValue(allocator, tool_name, field, expected, actual, resolution));
}

pub fn splitToolArgsErrorResult(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, actual: []const u8, err: anyerror) !Result {
    if (err == error.InvalidArguments) {
        return structuredError(allocator, try invalidArgumentValue(
            allocator,
            tool_name,
            field,
            "shell-style argument string",
            actual,
            "Quote arguments the same way you would in a shell command, or omit the field when no extra arguments are needed.",
        ));
    }
    return toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = "parse_arguments",
        .phase = "split_extra_arguments",
        .code = "argument_parse_failed",
        .category = "argument",
        .resolution = "Inspect the extra argument string and retry with valid shell-style quoting.",
    }, err);
}

pub fn workspacePathErrorResult(app: anytype, allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8, err: anyerror) !Result {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "workspace_path_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "tool", .{ .string = tool_name });
    try obj.put(allocator, "operation", .{ .string = "resolve_workspace_path" });
    try obj.put(allocator, "phase", .{ .string = if (err == error.EmptyPath) "validate_path" else "workspace_boundary" });
    try obj.put(allocator, "code", .{ .string = if (err == error.EmptyPath) "empty_path" else "path_outside_workspace" });
    try obj.put(allocator, "category", .{ .string = "workspace_path" });
    try obj.put(allocator, "resolution", .{ .string = "Run zigar_workspace_info to confirm the active workspace, then retry with a workspace-relative path inside that root." });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "workspace", .{ .string = app.workspace.root });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = "workspace_path" });
    return structuredError(allocator, .{ .object = obj });
}

pub fn workspacePathErrorMessage(allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8, root: []const u8, err: anyerror) ![]u8 {
    if (err == error.EmptyPath) {
        return std.fmt.allocPrint(
            allocator,
            "{s}: rejected an empty path.\n\nRun zigar_workspace_info to confirm the active workspace `{s}`. Pass a workspace-relative path, or restart/configure zigar with --workspace set to the Zig project you are editing.",
            .{ tool_name, root },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}: rejected path `{s}` because it is outside the configured zigar workspace `{s}`.\n\nRun zigar_workspace_info to confirm the active workspace. Pass a workspace-relative path, or restart/configure zigar with --workspace set to the Zig project you are editing.",
        .{ tool_name, path, root },
    );
}

pub const ToolErrorSpec = struct {
    tool: []const u8,
    operation: []const u8,
    phase: []const u8,
    code: []const u8,
    category: []const u8,
    resolution: []const u8,
    details: []const ToolErrorDetail = &.{},
};

pub const ToolErrorDetail = struct {
    key: []const u8,
    value: std.json.Value,
};

pub fn toolErrorFromError(allocator: std.mem.Allocator, spec: ToolErrorSpec, err: anyerror) !Result {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "tool_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "tool", .{ .string = spec.tool });
    try obj.put(allocator, "operation", .{ .string = spec.operation });
    try obj.put(allocator, "phase", .{ .string = spec.phase });
    try obj.put(allocator, "code", .{ .string = spec.code });
    try obj.put(allocator, "category", .{ .string = spec.category });
    try obj.put(allocator, "retryable", .{ .bool = false });
    try obj.put(allocator, "resolution", .{ .string = spec.resolution });
    for (spec.details) |detail| try obj.put(allocator, detail.key, detail.value);
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = kindForError(err) });
    return structuredError(allocator, .{ .object = obj });
}

fn argumentValue(allocator: std.mem.Allocator, tool_name: []const u8, code: []const u8, field: []const u8, expected: []const u8, actual: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "argument_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "tool", .{ .string = tool_name });
    try obj.put(allocator, "operation", .{ .string = "parse_arguments" });
    try obj.put(allocator, "phase", .{ .string = "validate_argument" });
    try obj.put(allocator, "code", .{ .string = code });
    try obj.put(allocator, "category", .{ .string = "argument" });
    try obj.put(allocator, "retryable", .{ .bool = false });
    try obj.put(allocator, "resolution", .{ .string = "Inspect the tools/list inputSchema or zigar_schema catalog, then retry with the registered argument names and JSON types." });
    try obj.put(allocator, "field", .{ .string = field });
    try obj.put(allocator, "expected", .{ .string = expected });
    try obj.put(allocator, "actual", .{ .string = actual });
    return .{ .object = obj };
}

fn invalidArgumentValue(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, expected: []const u8, actual: []const u8, resolution: []const u8) !std.json.Value {
    var value = try argumentValue(allocator, tool_name, "invalid_argument", field, expected, actual);
    try value.object.put(allocator, "resolution", .{ .string = resolution });
    return value;
}

pub fn backendUnavailableResult(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, configured_path: []const u8, status: []const u8, resolution: []const u8) !Result {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend_name });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = "Unavailable" });
    try obj.put(allocator, "error_kind", .{ .string = "unavailable" });
    try obj.put(allocator, "configured_path", .{ .string = configured_path });
    try obj.put(allocator, "status", .{ .string = status });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return structured(allocator, .{ .object = obj });
}

pub fn backendErrorResult(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) !Result {
    return structured(allocator, try backendErrorValue(allocator, backend_name, operation, err, resolution));
}

pub fn backendErrorValue(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend_name });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = kindForError(err) });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return .{ .object = obj };
}

fn kindForError(err: anyerror) []const u8 {
    return switch (err) {
        error.RequestTimeout, error.Timeout => "timeout",
        error.NotConnected, error.EndOfStream, error.BrokenPipe => "unavailable",
        error.FileNotFound => "not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        error.StreamTooLong => "output_limit",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        error.InvalidArguments => "invalid_data",
        else => "execution_failed",
    };
}

pub fn splitToolArgs(allocator: std.mem.Allocator, text_value: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    errdefer {
        freeStringList(allocator, list.items);
        list.deinit(allocator);
        current.deinit(allocator);
    }
    if (text_value) |value| {
        var quote: ?u8 = null;
        var escaping = false;
        var in_token = false;
        for (value) |c| {
            if (escaping) {
                try current.append(allocator, c);
                in_token = true;
                escaping = false;
                continue;
            }
            if (c == '\\') {
                escaping = true;
                in_token = true;
                continue;
            }
            if (quote) |q| {
                if (c == q) {
                    quote = null;
                } else {
                    try current.append(allocator, c);
                    in_token = true;
                }
                continue;
            }
            switch (c) {
                '\'', '"' => {
                    quote = c;
                    in_token = true;
                },
                ' ', '\t', '\r', '\n' => {
                    if (in_token) {
                        try list.append(allocator, try current.toOwnedSlice(allocator));
                        current = .empty;
                        in_token = false;
                    }
                },
                else => {
                    try current.append(allocator, c);
                    in_token = true;
                },
            }
        }
        if (escaping or quote != null) return error.InvalidArguments;
        if (in_token) try list.append(allocator, try current.toOwnedSlice(allocator));
    }
    current.deinit(allocator);
    return list.toOwnedSlice(allocator);
}

pub fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
}

pub const freeArgList = freeStringList;

pub fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

pub fn argvValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (argv) |arg| try array.append(.{ .string = arg });
    return .{ .array = array };
}

pub fn commandResultValue(
    allocator: std.mem.Allocator,
    title: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    timeout_ms: i64,
    result: CommandRunResult,
) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "command" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = result.succeeded() });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "duration_ms", .{ .integer = result.duration_ms });
    try obj.put(allocator, "term", try commandTermValue(allocator, result.term));
    try obj.put(allocator, "stdout", .{ .string = result.stdout });
    try obj.put(allocator, "stderr", .{ .string = result.stderr });
    try obj.put(allocator, "stdout_text", .{ .string = result.stdout });
    try obj.put(allocator, "stderr_text", .{ .string = result.stderr });
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(command_output_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(command_output_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = command_output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = result.stdout_truncated or result.stderr_truncated });
    try obj.put(allocator, "diagnostics", try emptyDiagnosticsValue(allocator));
    try obj.put(allocator, "failure_summary", .null);
    return .{ .object = obj };
}

pub fn commandErrorValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "command_error" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = kindForError(err) });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(command_output_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(command_output_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = command_output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = command.isOutputLimitError(err) });
    try obj.put(allocator, "stdout_truncated", .{ .bool = false });
    try obj.put(allocator, "stderr_truncated", .{ .bool = false });
    if (command.isOutputLimitError(err)) {
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigar's capture limit before zigar could retain a bounded prefix. Narrow the command or run it directly when full output is needed." });
    }
    try obj.put(allocator, "failure_summary", try commandErrorSummaryValue(allocator, err, argv));
    return .{ .object = obj };
}

pub fn commandRunErrorResult(allocator: std.mem.Allocator, spec: anytype) !Result {
    const value = commandErrorValue(allocator, spec.operation, spec.argv, spec.cwd, spec.timeout_ms, spec.err) catch return error.OutOfMemory;
    return structured(allocator, value);
}

fn commandTermValue(allocator: std.mem.Allocator, term: ports.CommandTerm) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = term.name() });
    if (term.exitCode()) |code| try obj.put(allocator, "code", .{ .integer = code });
    return .{ .object = obj };
}

fn emptyDiagnosticsValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "error_count", .{ .integer = 0 });
    try obj.put(allocator, "warning_count", .{ .integer = 0 });
    try obj.put(allocator, "hints", .{ .array = std.json.Array.init(allocator) });
    return .{ .object = obj };
}

pub const CompilerLine = compiler_output.CompilerLine;
pub const parseCompilerLine = compiler_output.parseCompilerLine;
pub const classifyDiagnosticMessage = compiler_output.classifyDiagnosticMessage;

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

pub fn compilerInsightsValue(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8, argv: []const []const u8) !std.json.Value {
    var findings = std.json.Array.init(allocator);
    var error_count: i64 = 0;
    var warning_count: i64 = 0;
    var note_count: i64 = 0;
    var primary: ?CompilerLine = null;
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
        try obj.put(allocator, "category", .{ .string = classifyDiagnosticMessage(p.message) });
        try obj.put(allocator, "next_command", .{ .string = try commandString(allocator, argv) });
    } else {
        try obj.put(allocator, "primary", .null);
        try obj.put(allocator, "category", .{ .string = "none" });
        try obj.put(allocator, "next_command", .null);
    }
    return .{ .object = obj };
}

fn collectCompilerLines(
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

fn compilerLineValue(allocator: std.mem.Allocator, parsed: CompilerLine) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "severity", try ownedString(allocator, parsed.severity));
    try obj.put(allocator, "message", try ownedString(allocator, parsed.message));
    try obj.put(allocator, "raw", try ownedString(allocator, parsed.raw));
    if (parsed.path) |path| try obj.put(allocator, "path", try ownedString(allocator, path)) else try obj.put(allocator, "path", .null);
    if (parsed.line) |line_no| try obj.put(allocator, "line", .{ .integer = line_no }) else try obj.put(allocator, "line", .null);
    if (parsed.column) |column| try obj.put(allocator, "column", .{ .integer = column }) else try obj.put(allocator, "column", .null);
    return .{ .object = obj };
}

pub fn failureSummaryValue(allocator: std.mem.Allocator, insights: std.json.Value, ok: bool, argv: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "ok", .{ .bool = ok });
    const insights_obj = switch (insights) {
        .object => |o| o,
        else => {
            try obj.put(allocator, "primary", .null);
            return .{ .object = obj };
        },
    };
    try obj.put(allocator, "primary", insights_obj.get("primary") orelse .null);
    try obj.put(allocator, "error_class", insights_obj.get("category") orelse .{ .string = "none" });
    try obj.put(allocator, "rerun_command", insights_obj.get("next_command") orelse .{ .string = try commandString(allocator, argv) });
    var suggested = std.json.Array.init(allocator);
    if (!ok) {
        try suggested.append(try ownedString(allocator, "zig_compile_error_index"));
        if (argvContains(argv, "test")) try suggested.append(try ownedString(allocator, "zig_test_failure_triage"));
        try suggested.append(try ownedString(allocator, "zigar_failure_fusion"));
        try suggested.append(try ownedString(allocator, "zigar_impact"));
    }
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", try likelyFailureScopeValue(allocator, insights_obj.get("primary") orelse .null));
    return .{ .object = obj };
}

pub fn commandErrorSummaryValue(allocator: std.mem.Allocator, err: anyerror, argv: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "primary", .null);
    try obj.put(allocator, "error_class", .{ .string = kindForError(err) });
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

pub fn changedPathList(allocator: std.mem.Allocator, app: anytype, explicit_files: ?[]const u8, timeout_ms: i64) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        freeStringList(allocator, list.items);
        list.deinit(allocator);
    }
    try appendPathTokens(allocator, &list, explicit_files);
    if (list.items.len > 0) return list;
    const run = runCommand(allocator, app, &.{ "git", "status", "--porcelain" }, @min(timeout_ms, 5000)) catch return list;
    defer run.deinit(allocator);
    var lines = std.mem.splitScalar(u8, run.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const path = statusLinePath(line);
        if (path.len == 0 or zig_analysis.skipWorkspacePath(path)) continue;
        try appendUniqueString(allocator, &list, path);
    }
    return list;
}

pub fn statusLinePath(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, if (line.len > 3) line[3..] else "", " \t");
    if (std.mem.indexOf(u8, trimmed, " -> ")) |arrow| return trimmed[arrow + " -> ".len ..];
    return trimmed;
}

pub fn appendPatchPaths(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), patch_text: ?[]const u8) !void {
    const patch = patch_text orelse return;
    var lines = std.mem.splitScalar(u8, patch, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            var tokens = std.mem.tokenizeScalar(u8, line, ' ');
            _ = tokens.next();
            _ = tokens.next();
            while (tokens.next()) |token| {
                if (std.mem.startsWith(u8, token, "a/") or std.mem.startsWith(u8, token, "b/")) {
                    try appendUniqueString(allocator, list, token[2..]);
                }
            }
        } else if (std.mem.startsWith(u8, line, "+++ b/") or std.mem.startsWith(u8, line, "--- a/")) {
            try appendUniqueString(allocator, list, line[6..]);
        }
    }
}

pub fn stringListContains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

fn appendPathTokens(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), text_value: ?[]const u8) !void {
    const text_input = text_value orelse return;
    var tokens = std.mem.tokenizeAny(u8, text_input, ", \t\r\n");
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        try appendUniqueString(allocator, list, token);
    }
}

fn appendUniqueString(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |item| if (std.mem.eql(u8, item, value)) return;
    try list.append(allocator, try allocator.dupe(u8, value));
}

pub fn lineNumberLocal(text_value: []const u8, index: usize) usize {
    var line: usize = 1;
    for (text_value[0..@min(index, text_value.len)]) |ch| {
        if (ch == '\n') line += 1;
    }
    return line;
}

pub fn serializeAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return try out.toOwnedSlice();
}

pub fn serializeValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
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

pub fn serializeString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789abcdef";
    try out.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0c => try out.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                try out.appendSlice(allocator, "\\u00");
                try out.append(allocator, hex[c >> 4]);
                try out.append(allocator, hex[c & 0x0f]);
            },
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

pub fn cloneValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |array| blk: {
            var cloned = std.json.Array.init(allocator);
            for (array.items) |item| try cloned.append(try cloneValue(allocator, item));
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned = std.json.ObjectMap.empty;
            var it = object.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                try cloned.put(allocator, key, try cloneValue(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = cloned };
        },
    };
}

pub fn deinitOwnedValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |array| {
            var mutable = array;
            for (mutable.items) |item| deinitOwnedValue(allocator, item);
            mutable.deinit();
        },
        .object => |object| {
            var mutable = object;
            var it = mutable.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitOwnedValue(allocator, entry.value_ptr.*);
            }
            mutable.deinit(allocator);
        },
        else => {},
    }
}

pub const artifacts = struct {
    pub const default_registry_path = ".zigar-cache/artifacts/registry.jsonl";

    pub const Toolchain = struct {
        zig_path: []const u8,
        zls_path: []const u8 = "",
        zflame_path: []const u8 = "",
        diff_folded_path: []const u8 = "",
    };

    pub const Provenance = struct {
        producer: []const u8,
        artifact_kind: []const u8,
        command_argv: []const []const u8 = &.{},
        backend_name: []const u8 = "",
        backend_version: []const u8 = "",
        target: []const u8 = "",
        baseline_identity: []const u8 = "",
        notes: []const u8 = "",
        toolchain: Toolchain,
    };

    pub const FileIdentity = struct {
        path: []const u8,
        abs_path: []const u8,
        bytes: usize,
        sha256: []const u8,
    };

    pub const RegistryEntry = struct {
        identity: FileIdentity,
        provenance: Provenance,
        indexed_at_unix_ms: i64,
        parser_confidence: []const u8 = "high",
        raw_reference: []const u8 = "workspace_file",
    };

    pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        return allocator.dupe(u8, &hex);
    }

    pub fn identityFromBytes(allocator: std.mem.Allocator, path: []const u8, abs_path: []const u8, bytes: []const u8) !FileIdentity {
        return .{
            .path = path,
            .abs_path = abs_path,
            .bytes = bytes.len,
            .sha256 = try sha256Hex(allocator, bytes),
        };
    }

    pub fn entryValue(allocator: std.mem.Allocator, entry: RegistryEntry) !std.json.Value {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "path", .{ .string = entry.identity.path });
        try obj.put(allocator, "abs_path", .{ .string = entry.identity.abs_path });
        try obj.put(allocator, "bytes", .{ .integer = @intCast(entry.identity.bytes) });
        try obj.put(allocator, "sha256", .{ .string = entry.identity.sha256 });
        try obj.put(allocator, "indexed_at_unix_ms", .{ .integer = entry.indexed_at_unix_ms });
        try obj.put(allocator, "parser_confidence", .{ .string = entry.parser_confidence });
        try obj.put(allocator, "raw_reference", .{ .string = entry.raw_reference });
        try obj.put(allocator, "provenance", try provenanceValue(allocator, entry.provenance));
        return .{ .object = obj };
    }

    fn provenanceValue(allocator: std.mem.Allocator, provenance: Provenance) !std.json.Value {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "producer", .{ .string = provenance.producer });
        try obj.put(allocator, "artifact_kind", .{ .string = provenance.artifact_kind });
        try obj.put(allocator, "backend_name", .{ .string = provenance.backend_name });
        try obj.put(allocator, "backend_version", .{ .string = provenance.backend_version });
        try obj.put(allocator, "target", .{ .string = provenance.target });
        try obj.put(allocator, "baseline_identity", .{ .string = provenance.baseline_identity });
        try obj.put(allocator, "notes", .{ .string = provenance.notes });
        try obj.put(allocator, "command_argv", try argvValue(allocator, provenance.command_argv));
        try obj.put(allocator, "toolchain", try toolchainValue(allocator, provenance.toolchain));
        return .{ .object = obj };
    }

    fn toolchainValue(allocator: std.mem.Allocator, toolchain: Toolchain) !std.json.Value {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "zig_path", .{ .string = toolchain.zig_path });
        try obj.put(allocator, "zls_path", .{ .string = toolchain.zls_path });
        try obj.put(allocator, "zflame_path", .{ .string = toolchain.zflame_path });
        try obj.put(allocator, "diff_folded_path", .{ .string = toolchain.diff_folded_path });
        return .{ .object = obj };
    }
};

pub fn recordArtifact(app: anytype, allocator: std.mem.Allocator, entry: artifacts.RegistryEntry) !void {
    const store = app.context.artifact_store orelse return error.Unavailable;
    const ref = try store.recordWorkspace(allocator, .{
        .path = entry.identity.path,
        .bytes = null,
        .producer = entry.provenance.producer,
        .artifact_kind = entry.provenance.artifact_kind,
        .command_argv = entry.provenance.command_argv,
        .backend_name = entry.provenance.backend_name,
        .backend_version = entry.provenance.backend_version,
        .target = entry.provenance.target,
        .baseline_identity = entry.provenance.baseline_identity,
        .notes = entry.provenance.notes,
        .toolchain = .{
            .zig_path = entry.provenance.toolchain.zig_path,
            .zls_path = entry.provenance.toolchain.zls_path,
            .zflame_path = entry.provenance.toolchain.zflame_path,
            .diff_folded_path = entry.provenance.toolchain.diff_folded_path,
        },
        .indexed_at_unix_ms = entry.indexed_at_unix_ms,
    });
    ref.deinit(allocator);
}

pub fn recordWrittenArtifact(app: anytype, allocator: std.mem.Allocator, entry: artifacts.RegistryEntry, bytes: []const u8) !void {
    const store = app.context.artifact_store orelse return error.Unavailable;
    const ref = try store.recordWorkspace(allocator, .{
        .path = entry.identity.path,
        .bytes = bytes,
        .producer = entry.provenance.producer,
        .artifact_kind = entry.provenance.artifact_kind,
        .command_argv = entry.provenance.command_argv,
        .backend_name = entry.provenance.backend_name,
        .backend_version = entry.provenance.backend_version,
        .target = entry.provenance.target,
        .baseline_identity = entry.provenance.baseline_identity,
        .notes = entry.provenance.notes,
        .toolchain = .{
            .zig_path = entry.provenance.toolchain.zig_path,
            .zls_path = entry.provenance.toolchain.zls_path,
            .zflame_path = entry.provenance.toolchain.zflame_path,
            .diff_folded_path = entry.provenance.toolchain.diff_folded_path,
        },
        .indexed_at_unix_ms = entry.indexed_at_unix_ms,
    });
    ref.deinit(allocator);
}

pub fn unixMs(app: anytype) i64 {
    if (app.context.clock_and_ids) |clock| {
        const instant = clock.now() catch return 0;
        return instant.unix_ms;
    }
    return 0;
}

fn relativeFromAbs(root: []const u8, abs_path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, root, abs_path)) return ".";
    if (!std.mem.startsWith(u8, abs_path, root)) return null;
    if (abs_path.len <= root.len or abs_path[root.len] != std.fs.path.sep) return null;
    return abs_path[root.len + 1 ..];
}

test "workflow support workspace facade delegates through workspace store port" {
    const Stub = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, request: ports.WorkspaceResolveRequest) ports.PortError!ports.WorkspaceResolveResult {
            if (request.for_output) return .{ .path = "/workspace/out/report.json" };
            return .{ .path = "/workspace/src/main.zig" };
        }

        fn read(_: *anyopaque, _: std.mem.Allocator, request: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            if (!std.mem.eql(u8, "src/main.zig", request.path)) return error.StaleArguments;
            return .{ .bytes = "pub fn main() void {}" };
        }

        fn write(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            if (!request.create_parent_dirs or !request.replace_existing) return error.StaleArguments;
            return .{ .bytes_written = request.bytes.len };
        }

        fn ensureDir(_: *anyopaque, request: ports.WorkspaceEnsureDirRequest) ports.PortError!ports.WorkspaceEnsureDirResult {
            if (!std.mem.eql(u8, "out", request.path)) return error.StaleArguments;
            return .{};
        }

        const vtable = ports.WorkspaceStore.VTable{
            .resolve = resolve,
            .read = read,
            .write = write,
            .ensure_dir = ensureDir,
        };
    };

    var token: u8 = 0;
    const Context = struct {
        workspace: struct { root: []const u8, cache_root: []const u8 },
        workspace_store: ports.WorkspaceStore,
    };
    const ctx = Context{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .workspace_store = .{ .ptr = &token, .vtable = &Stub.vtable },
    };
    const workspace = Workspace(Context).init(ctx, std.testing.allocator);
    try std.testing.expectEqualStrings("/workspace/src/main.zig", try workspace.resolve("src/main.zig"));
    try std.testing.expectEqualStrings("/workspace/out/report.json", try workspace.resolveOutput("out/report.json"));
    try std.testing.expectEqualStrings("pub fn main() void {}", try workspace.readFileAlloc({}, "src/main.zig", 1024));
    try workspace.putFile("out/report.json", "{}");
    try workspace.ensureParentForAbsoluteOutput("/workspace/out/report.json");
}

test "workflow support command and changed path helpers use command runner port" {
    const Stub = struct {
        fn run(_: *anyopaque, allocator: std.mem.Allocator, request: ports.CommandRequest) ports.PortError!ports.CommandResult {
            if (!std.mem.eql(u8, "/workspace", request.cwd orelse "")) return error.StaleArguments;
            if (!std.mem.eql(u8, "arch110-workflow-command", request.provenance)) return error.StaleArguments;
            const stdout = try allocator.dupe(u8, " M src/main.zig\nR  src/old.zig -> src/new.zig\n?? .zigar-cache/tmp\n");
            errdefer allocator.free(stdout);
            const stderr = try allocator.dupe(u8, "");
            errdefer allocator.free(stderr);
            return .{
                .exit_code = 0,
                .stdout = stdout,
                .stderr = stderr,
                .duration_ms = 12,
                .owns_stdout = true,
                .owns_stderr = true,
            };
        }

        const vtable = ports.CommandRunner.VTable{ .run = run };
    };

    var token: u8 = 0;
    const app = .{
        .context = .{ .command_runner = ports.CommandRunner{ .ptr = &token, .vtable = &Stub.vtable } },
        .workspace = .{ .root = "/workspace" },
    };
    const run = try runCommand(std.testing.allocator, app, &.{ "git", "status", "--porcelain" }, 5000);
    defer run.deinit(std.testing.allocator);
    try std.testing.expect(run.succeeded());
    try std.testing.expectEqual(@as(i64, 12), run.duration_ms);

    var changed = try changedPathList(std.testing.allocator, app, null, 5000);
    defer {
        freeStringList(std.testing.allocator, changed.items);
        changed.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), changed.items.len);
    try std.testing.expectEqualStrings("src/main.zig", changed.items[0]);
    try std.testing.expectEqualStrings("src/new.zig", changed.items[1]);
}

test "workflow support result helpers clone and classify structured errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = "report" });
    try obj.put(allocator, "count", .{ .number_string = "42" });
    const result = try structured(allocator, .{ .object = obj });
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("report", result.value.object.get("name").?.string);
    try std.testing.expectEqualStrings("{\"name\":\"report\",\"count\":42}", try serializeAlloc(allocator, result.value));

    const missing = try missingArgumentResult(allocator, "zig_tool", "field", "value");
    try std.testing.expect(missing.is_error);
    try std.testing.expectEqualStrings("argument_error", missing.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("missing_required_argument", missing.value.object.get("code").?.string);

    const invalid = try splitToolArgsErrorResult(allocator, "zig_tool", "extra", "\"unterminated", error.InvalidArguments);
    try std.testing.expect(invalid.is_error);
    try std.testing.expectEqualStrings("invalid_argument", invalid.value.object.get("code").?.string);
    try std.testing.expectEqual(@as(i64, 42), argInt(.{ .object = obj }, "count", 0));
    try std.testing.expectEqual(@as(usize, 3), lineNumberLocal("a\nb\nc", 4));
}

test "workflow support backend and workspace error helpers expose stable fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const app = .{ .workspace = .{ .root = "/workspace" } };

    const path_error = try workspacePathErrorResult(app, allocator, "zig_tool", "../escape", error.PathOutsideWorkspace);
    try std.testing.expect(path_error.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", path_error.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("path_outside_workspace", path_error.value.object.get("code").?.string);

    const backend_error = try backendErrorResult(allocator, "tool", "run", error.FileNotFound, "install tool");
    try std.testing.expect(!backend_error.is_error);
    try std.testing.expectEqualStrings("backend_error", backend_error.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("not_found", backend_error.value.object.get("error_kind").?.string);

    const unavailable = try backendUnavailableResult(allocator, "tool", "run", "/bin/tool", "missing", "install tool");
    try std.testing.expectEqualStrings("missing", unavailable.value.object.get("status").?.string);
}
