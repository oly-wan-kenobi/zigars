//! Shared helpers for usecase execution: workspace access, command launching,
//! and common JSON/argument utilities across tool handlers.
const std = @import("std");

const ports = @import("../ports.zig");
const zig_analysis = @import("../../domain/zig/analysis.zig");
const compiler_output = @import("../../domain/zig/compiler_output.zig");

/// Maximum stdout/stderr bytes captured by shared command helpers.
pub const command_output_limit: usize = 1024 * 1024;
/// Policy label reported when command output reaches the shared byte limit.
pub const command_output_limit_mode = "truncate_on_limit";
/// Maximum source bytes read by shared workspace helpers.
pub const source_read_limit: usize = 1024 * 1024;

/// JSON result wrapper used by usecase handlers before MCP transport encoding.
pub const Result = struct {
    value: std.json.Value,
    is_error: bool = false,
};

/// Backend probe summary with caller-owned status/resolution when allocated by checkBackend.
pub const Probe = struct {
    ok: bool,
    status: []const u8,
    resolution: []const u8,
};

/// Builds the lightweight app facade used by JSON-oriented usecase handlers.
pub fn UsecaseApp(comptime Context: type) type {
    return struct {
        context: Context,
        allocator: std.mem.Allocator,
        io: void = {},
        config: Config,
        workspace: Workspace(Context),
        command_calls: usize = 0,
        tool_errors: usize = 0,

        /// Creates a facade over an injected app context without taking ownership of it.
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

/// Minimal runtime config projection consumed by shared usecase helpers.
pub const Config = struct {
    /// Transport projection used by shared usecase helpers.
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

/// Builds the workspace facade for a specific injected context type.
pub fn Workspace(comptime Context: type) type {
    return struct {
        context: Context,
        allocator: std.mem.Allocator,
        root: []const u8,
        cache_root: []const u8,

        const Self = @This();

        /// Creates a workspace facade over borrowed context state.
        pub fn init(context: Context, allocator: std.mem.Allocator) Self {
            return .{
                .context = context,
                .allocator = allocator,
                .root = context.workspace.root,
                .cache_root = context.workspace.cache_root,
            };
        }

        /// Resolves an input path through the workspace port.
        pub fn resolve(self: Self, path: []const u8) ![]u8 {
            // Existing usecases expect mutable path slices after port resolution.
            const resolved = try self.context.workspace_store.resolve(self.allocator, .{
                .path = path,
                .provenance = "arch110-workflow-resolve",
            });
            return @constCast(resolved.path);
        }

        /// Resolves an output path through the workspace port.
        pub fn resolveOutput(self: Self, path: []const u8) ![]u8 {
            const resolved = try self.context.workspace_store.resolve(self.allocator, .{
                .path = path,
                .for_output = true,
                .provenance = "arch110-workflow-resolve-output",
            });
            return @constCast(resolved.path);
        }

        /// Reads workspace bytes through the port using the facade allocator.
        pub fn readFileAlloc(self: Self, _: anytype, path: []const u8, max_bytes: usize) ![]u8 {
            const read = try self.context.workspace_store.read(self.allocator, .{
                .path = path,
                .max_bytes = max_bytes,
                .provenance = "arch110-workflow-read",
            });
            return @constCast(read.bytes);
        }

        /// Writes workspace bytes, creating parent directories when needed.
        pub fn putFile(self: Self, path: []const u8, bytes: []const u8) !void {
            _ = try self.context.workspace_store.write(.{
                .path = path,
                .bytes = bytes,
                .create_parent_dirs = true,
                .replace_existing = true,
                .provenance = "arch110-workflow-write",
            });
        }

        /// Scans a workspace directory and returns the port-owned result contract.
        pub fn scanDirectory(self: Self, allocator: std.mem.Allocator, path: []const u8, max_files: ?usize) !ports.WorkspaceDirectoryScanResult {
            return self.context.workspace_store.scanDirectory(allocator, .{
                .path = path,
                .max_files = max_files,
                .provenance = "arch110-workflow-scan",
            });
        }

        /// Best-effort existence check that treats port failures as not found.
        pub fn exists(self: Self, allocator: std.mem.Allocator, path: []const u8, for_output: bool) bool {
            const result = self.context.workspace_store.exists(allocator, .{
                .path = path,
                .for_output = for_output,
                .provenance = "arch111-workflow-exists",
            }) catch return false;
            return result.exists;
        }

        /// Ensures the parent directory for an absolute workspace output exists.
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

/// Command result normalized for shared usecase JSON builders.
pub const CommandRunResult = struct {
    term: ports.CommandTerm,
    stdout: []const u8,
    stderr: []const u8,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    duration_ms: i64 = 0,
    owns_stdout: bool = false,
    owns_stderr: bool = false,

    /// Frees stdout/stderr only when ownership was transferred by the command port.
    pub fn deinit(self: CommandRunResult, allocator: std.mem.Allocator) void {
        if (self.owns_stdout) allocator.free(self.stdout);
        if (self.owns_stderr) allocator.free(self.stderr);
    }

    /// True when the command termination does not represent failure.
    pub fn succeeded(self: CommandRunResult) bool {
        return !self.term.failed();
    }
};

/// Namespace for command helper aliases and classifiers.
pub const command = struct {
    /// Stable public alias for command run results.
    pub const RunResult = CommandRunResult;
    /// Stable public alias for the shared command output limit.
    pub const output_limit = command_output_limit;
    /// Stable public alias for the shared output limit policy.
    pub const output_limit_mode = command_output_limit_mode;

    /// Maps command errors to stable JSON error classes.
    pub fn errorKind(err: anyerror) []const u8 {
        return kindForError(err);
    }

    /// True for timeout-class command errors.
    pub fn isTimeoutError(err: anyerror) bool {
        return err == error.RequestTimeout or err == error.Timeout;
    }

    /// True for output-limit command errors.
    pub fn isOutputLimitError(err: anyerror) bool {
        return err == error.StreamTooLong or err == error.OutputLimitExceeded;
    }

    /// Allocates a concatenated argv slice; argument strings remain borrowed.
    pub fn joinArgv(allocator: std.mem.Allocator, base: []const []const u8, extra: []const []const u8) ![]const []const u8 {
        const out = try allocator.alloc([]const u8, base.len + extra.len);
        @memcpy(out[0..base.len], base);
        @memcpy(out[base.len..], extra);
        return out;
    }
};

/// Runs a command through the injected command port with shared output limits.
pub fn runCommand(allocator: std.mem.Allocator, app: anytype, argv: []const []const u8, timeout_ms: i64) !CommandRunResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Checks backend availability, returning an unavailable probe (rather than an
/// error) when no port is bound or the check itself fails. On success the
/// caller owns the duped status/resolution strings (see Probe).
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
    // Probe is not an error union, so OOM while duping out of the soon-to-be-freed
    // availability buffers cannot be propagated; treat it as fatal rather than
    // returning dangling borrows.
    const raw_status = availability.unavailable_reason orelse if (availability.available) "ok" else "unavailable";
    const status = allocator.dupe(u8, raw_status) catch @panic("out of memory cloning backend probe status");
    const resolution = allocator.dupe(u8, availability.basis) catch @panic("out of memory cloning backend probe resolution");
    return .{
        .ok = availability.available,
        .status = status,
        .resolution = resolution,
    };
}

/// Clones a JSON value into a non-error handler result.
pub fn structured(allocator: std.mem.Allocator, value: std.json.Value) !Result {
    return .{ .value = try cloneValue(allocator, value) };
}

/// Clones a JSON value into an error handler result.
pub fn structuredError(allocator: std.mem.Allocator, value: std.json.Value) !Result {
    return .{ .value = try cloneValue(allocator, value), .is_error = true };
}

/// Adds deterministic Phase 6 elicitation fallback metadata to an object result.
pub fn putElicitationUnavailable(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, reason: []const u8) !void {
    try obj.put(allocator, "elicitation_used", .{ .bool = false });
    try obj.put(allocator, "elicitation_unavailable_reason", .{ .string = reason });
}

/// Adds deterministic Phase 6 sampling fallback metadata to an object result.
pub fn putSamplingUnavailable(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, reason: []const u8) !void {
    try obj.put(allocator, "sampling_used", .{ .bool = false });
    try obj.put(allocator, "summary_unavailable_reason", .{ .string = reason });
}

/// Reads an optional string field from object-shaped tool args.
pub fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    const value = argValue(args, name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// Reads an optional bool field from object-shaped tool args.
pub fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    const value = argValue(args, name) orelse return default;
    return switch (value) {
        .bool => |b| b,
        else => default,
    };
}

/// Reads an optional integer field from object-shaped tool args.
pub fn argInt(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const value = argValue(args, name) orelse return default;
    return switch (value) {
        .integer => |i| i,
        .float => |f| floatToInt(f, default),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch default,
        else => default,
    };
}

fn floatToInt(value: f64, default: i64) i64 {
    if (!std.math.isFinite(value)) return default;
    const max: f64 = @floatFromInt(std.math.maxInt(i64));
    const min: f64 = @floatFromInt(std.math.minInt(i64));
    if (value >= max or value < min) return default;
    return @intFromFloat(value);
}

/// Looks up a named field in object-shaped tool args; returns null when args is
/// absent, not an object, or lacks the field. Borrows from args, allocates nothing.
fn argValue(args: ?std.json.Value, name: []const u8) ?std.json.Value {
    const root = args orelse return null;
    if (root != .object) return null;
    return root.object.get(name);
}

/// Returns a bounded timeout from tool args or the app default.
pub fn toolTimeout(app: anytype, args: ?std.json.Value) i64 {
    return @max(1, @min(argInt(args, "timeout_ms", app.config.timeout_ms), 60 * 60 * 1000));
}

/// Copies a facade while swapping in a scratch allocator.
pub fn scratchApp(app: anytype, allocator: std.mem.Allocator) @TypeOf(app.*) {
    var copy = app.*;
    copy.allocator = allocator;
    copy.workspace.allocator = allocator;
    return copy;
}

/// Builds a structured missing-argument error result.
pub fn missingArgumentResult(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, expected: []const u8) !Result {
    return structuredError(allocator, try argumentValue(allocator, tool_name, "missing_required_argument", field, expected, "missing"));
}

/// Builds a structured invalid-argument error result.
pub fn invalidArgumentResult(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, expected: []const u8, actual: []const u8, resolution: []const u8) !Result {
    return structuredError(allocator, try invalidArgumentValue(allocator, tool_name, field, expected, actual, resolution));
}

/// Converts shell-style argument splitting failures into structured errors.
pub fn splitToolArgsErrorResult(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, actual: []const u8, err: anyerror) !Result {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Builds a structured workspace path error result.
pub fn workspacePathErrorResult(app: anytype, allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8, err: anyerror) !Result {
    // Normalize and constrain path handling here before any downstream filesystem action.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "workspace_path_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "tool", .{ .string = tool_name });
    try obj.put(allocator, "operation", .{ .string = "resolve_workspace_path" });
    try obj.put(allocator, "phase", .{ .string = if (err == error.EmptyPath) "validate_path" else "workspace_boundary" });
    try obj.put(allocator, "code", .{ .string = if (err == error.EmptyPath) "empty_path" else "path_outside_workspace" });
    try obj.put(allocator, "category", .{ .string = "workspace_path" });
    try obj.put(allocator, "resolution", .{ .string = "Run zigars_workspace_info to confirm the active workspace, then retry with a workspace-relative path inside that root." });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "workspace", .{ .string = app.workspace.root });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = "workspace_path" });
    return structuredError(allocator, .{ .object = obj });
}

/// Allocates a human-readable workspace path error message.
pub fn workspacePathErrorMessage(allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8, root: []const u8, err: anyerror) ![]u8 {
    // Normalize and constrain path handling here before any downstream filesystem action.
    if (err == error.EmptyPath) {
        return std.fmt.allocPrint(
            allocator,
            "{s}: rejected an empty path.\n\nRun zigars_workspace_info to confirm the active workspace `{s}`. Pass a workspace-relative path, or restart/configure zigars with --workspace set to the Zig project you are editing.",
            .{ tool_name, root },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}: rejected path `{s}` because it is outside the configured zigars workspace `{s}`.\n\nRun zigars_workspace_info to confirm the active workspace. Pass a workspace-relative path, or restart/configure zigars with --workspace set to the Zig project you are editing.",
        .{ tool_name, path, root },
    );
}

/// Structured tool error template.
pub const ToolErrorSpec = struct {
    tool: []const u8,
    operation: []const u8,
    phase: []const u8,
    code: []const u8,
    category: []const u8,
    resolution: []const u8,
    details: []const ToolErrorDetail = &.{},
};

/// Extra structured field attached to a tool error.
pub const ToolErrorDetail = struct {
    key: []const u8,
    value: std.json.Value,
};

/// Builds a structured tool error result from an error value.
pub fn toolErrorFromError(allocator: std.mem.Allocator, spec: ToolErrorSpec, err: anyerror) !Result {
    // Preserve a single error-shaping path so callers receive consistent metadata.
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

/// Serializes argument fields into an allocator-owned JSON value; allocation failures propagate.
fn argumentValue(allocator: std.mem.Allocator, tool_name: []const u8, code: []const u8, field: []const u8, expected: []const u8, actual: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "argument_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "tool", .{ .string = tool_name });
    try obj.put(allocator, "operation", .{ .string = "parse_arguments" });
    try obj.put(allocator, "phase", .{ .string = "validate_argument" });
    try obj.put(allocator, "code", .{ .string = code });
    try obj.put(allocator, "category", .{ .string = "argument" });
    try obj.put(allocator, "retryable", .{ .bool = false });
    try obj.put(allocator, "resolution", .{ .string = "Inspect the tools/list inputSchema or zigars_schema catalog, then retry with the registered argument names and JSON types." });
    try obj.put(allocator, "field", .{ .string = field });
    try obj.put(allocator, "expected", .{ .string = expected });
    try obj.put(allocator, "actual", .{ .string = actual });
    return .{ .object = obj };
}

/// Serializes invalid argument fields into an allocator-owned JSON value; allocation failures propagate.
fn invalidArgumentValue(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, expected: []const u8, actual: []const u8, resolution: []const u8) !std.json.Value {
    var value = try argumentValue(allocator, tool_name, "invalid_argument", field, expected, actual);
    try value.object.put(allocator, "resolution", .{ .string = resolution });
    return value;
}

/// Builds a structured backend-unavailable result.
pub fn backendUnavailableResult(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, configured_path: []const u8, status: []const u8, resolution: []const u8) !Result {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Builds a structured backend error result from an error value.
pub fn backendErrorResult(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) !Result {
    return structured(allocator, try backendErrorValue(allocator, backend_name, operation, err, resolution));
}

/// Allocates the JSON object used by backend error results.
pub fn backendErrorValue(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Maps a Zig error value to the stable error_kind string surfaced in structured
/// tool results (timeout, unavailable, not_found, permission, output_limit,
/// workspace_path, invalid_data); anything unmapped becomes execution_failed.
fn kindForError(err: anyerror) []const u8 {
    // Preserve a single error-shaping path so callers receive consistent metadata.
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

/// Splits shell-style argument text into owned argv fragments.
pub fn splitToolArgs(allocator: std.mem.Allocator, text_value: ?[]const u8) ![]const []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Frees a list of allocator-owned strings.
pub fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
}

/// Stable public alias for freeing split argv fragments.
pub const freeArgList = freeStringList;

/// Allocates a JSON string value by cloning the input.
pub fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

/// Allocates a JSON array from borrowed argv strings.
pub fn argvValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (argv) |arg| try array.append(.{ .string = arg });
    return .{ .array = array };
}

/// Allocates the standard JSON command result object.
pub fn commandResultValue(
    allocator: std.mem.Allocator,
    title: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    timeout_ms: i64,
    result: CommandRunResult,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Allocates the standard JSON command error object.
pub fn commandErrorValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, err: anyerror) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigars' capture limit before zigars could retain a bounded prefix. Narrow the command or run it directly when full output is needed." });
    }
    try obj.put(allocator, "failure_summary", try commandErrorSummaryValue(allocator, err, argv));
    return .{ .object = obj };
}

/// Wraps commandErrorValue in a handler result.
pub fn commandRunErrorResult(allocator: std.mem.Allocator, spec: anytype) !Result {
    const value = commandErrorValue(allocator, spec.operation, spec.argv, spec.cwd, spec.timeout_ms, spec.err) catch return error.OutOfMemory;
    return structured(allocator, value);
}

/// Serializes command term fields into an allocator-owned JSON value; allocation failures propagate.
fn commandTermValue(allocator: std.mem.Allocator, term: ports.CommandTerm) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = term.name() });
    if (term.exitCode()) |code| try obj.put(allocator, "code", .{ .integer = code });
    return .{ .object = obj };
}

/// Serializes empty diagnostics fields into an allocator-owned JSON value; allocation failures propagate.
fn emptyDiagnosticsValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "error_count", .{ .integer = 0 });
    try obj.put(allocator, "warning_count", .{ .integer = 0 });
    try obj.put(allocator, "hints", .{ .array = std.json.Array.init(allocator) });
    return .{ .object = obj };
}

/// Re-exported parsed compiler diagnostic line type.
pub const CompilerLine = compiler_output.CompilerLine;
/// Re-exported compiler diagnostic parser.
pub const parseCompilerLine = compiler_output.parseCompilerLine;
/// Re-exported diagnostic classifier.
pub const classifyDiagnosticMessage = compiler_output.classifyDiagnosticMessage;

/// Allocates a space-joined command string for reporting.
pub fn commandString(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (argv.len == 0) return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

/// Returns true when argv contains an exact argument.
pub fn argvContains(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

/// Allocates compiler diagnostic insight JSON from command stdout/stderr.
pub fn compilerInsightsValue(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8, argv: []const []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Collects compiler lines data into caller-provided output storage without taking ownership of inputs.
fn collectCompilerLines(
    allocator: std.mem.Allocator,
    findings: *std.json.Array,
    text_value: []const u8,
    primary: *?CompilerLine,
    error_count: *i64,
    warning_count: *i64,
    note_count: *i64,
) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Serializes compiler line fields into an allocator-owned JSON value; allocation failures propagate.
fn compilerLineValue(allocator: std.mem.Allocator, parsed: CompilerLine) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "severity", try ownedString(allocator, parsed.severity));
    try obj.put(allocator, "message", try ownedString(allocator, parsed.message));
    try obj.put(allocator, "raw", try ownedString(allocator, parsed.raw));
    if (parsed.path) |path| try obj.put(allocator, "path", try ownedString(allocator, path)) else try obj.put(allocator, "path", .null);
    if (parsed.line) |line_no| try obj.put(allocator, "line", .{ .integer = line_no }) else try obj.put(allocator, "line", .null);
    if (parsed.column) |column| try obj.put(allocator, "column", .{ .integer = column }) else try obj.put(allocator, "column", .null);
    return .{ .object = obj };
}

/// Allocates a command failure summary from compiler insights.
pub fn failureSummaryValue(allocator: std.mem.Allocator, insights: std.json.Value, ok: bool, argv: []const []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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
        try suggested.append(try ownedString(allocator, "zigars_failure_fusion"));
        try suggested.append(try ownedString(allocator, "zigars_impact"));
    }
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", try likelyFailureScopeValue(allocator, insights_obj.get("primary") orelse .null));
    return .{ .object = obj };
}

/// Allocates a command failure summary when no command result exists.
pub fn commandErrorSummaryValue(allocator: std.mem.Allocator, err: anyerror, argv: []const []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "primary", .null);
    try obj.put(allocator, "error_class", .{ .string = kindForError(err) });
    try obj.put(allocator, "rerun_command", .{ .string = try commandString(allocator, argv) });
    var suggested = std.json.Array.init(allocator);
    try suggested.append(try ownedString(allocator, "zigars_doctor"));
    try suggested.append(try ownedString(allocator, "zigars_context_pack"));
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", .{ .string = if (command.isTimeoutError(err)) "command_timeout" else "tool_or_backend_configuration" });
    return .{ .object = obj };
}

/// Classifies the likely source area for a primary compiler finding.
pub fn likelyFailureScopeValue(allocator: std.mem.Allocator, primary: std.json.Value) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns owned changed paths from explicit input or git status.
pub fn changedPathList(allocator: std.mem.Allocator, app: anytype, explicit_files: ?[]const u8, timeout_ms: i64) !std.ArrayList([]const u8) {
    // Normalize and constrain path handling here before any downstream filesystem action.
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

/// Extracts the path portion from a git porcelain status line.
pub fn statusLinePath(line: []const u8) []const u8 {
    // Porcelain prefixes each path with a 2-char status code plus a space; rename
    // entries read "old -> new", so keep only the post-arrow destination path.
    const trimmed = std.mem.trim(u8, if (line.len > 3) line[3..] else "", " \t");
    if (std.mem.indexOf(u8, trimmed, " -> ")) |arrow| return trimmed[arrow + " -> ".len ..];
    return trimmed;
}

/// Appends unique paths found in unified diff headers.
pub fn appendPatchPaths(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), patch_text: ?[]const u8) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
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

/// Returns true when a string list contains an exact value.
pub fn stringListContains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

/// Appends path tokens data into caller-provided storage, propagating allocation failures.
fn appendPathTokens(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), text_value: ?[]const u8) !void {
    const text_input = text_value orelse return;
    var tokens = std.mem.tokenizeAny(u8, text_input, ", \t\r\n");
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        try appendUniqueString(allocator, list, token);
    }
}

/// Appends unique string data into caller-provided storage, propagating allocation failures.
fn appendUniqueString(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |item| if (std.mem.eql(u8, item, value)) return;
    try list.append(allocator, try allocator.dupe(u8, value));
}

/// Converts a byte index to a one-based line number.
pub fn lineNumberLocal(text_value: []const u8, index: usize) usize {
    var line: usize = 1;
    for (text_value[0..@min(index, text_value.len)]) |ch| {
        if (ch == '\n') line += 1;
    }
    return line;
}

/// Serializes a JSON value into an owned byte buffer.
pub fn serializeAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return try out.toOwnedSlice();
}

/// Appends JSON serialization to an existing byte list.
pub fn serializeValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
    // Keep serialization centralized so output formatting stays consistent across call sites.
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

/// Appends a JSON-escaped string to an existing byte list.
pub fn serializeString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    // Keep serialization centralized so output formatting stays consistent across call sites.
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

/// Deep-clones a JSON value into allocator-owned storage.
pub fn cloneValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Recursively frees a JSON value produced by cloneValue or owned builders.
pub fn deinitOwnedValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    // Only release owned state here to avoid invalidating borrowed data.
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

/// Artifact registry JSON helpers shared by evidence-producing use cases.
pub const artifacts = struct {
    /// Default workspace-relative registry path for artifact records.
    pub const default_registry_path = ".zigars-cache/artifacts/registry.jsonl";

    /// Toolchain path metadata stored with artifact provenance.
    pub const Toolchain = struct {
        zig_path: []const u8,
        zls_path: []const u8 = "",
        zflame_path: []const u8 = "",
        diff_folded_path: []const u8 = "",
    };

    /// Borrowed artifact provenance fields serialized into registry entries.
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

    /// File identity recorded for workspace artifacts.
    pub const FileIdentity = struct {
        path: []const u8,
        abs_path: []const u8,
        bytes: usize,
        sha256: []const u8,
    };

    /// Complete artifact registry entry before JSON serialization.
    pub const RegistryEntry = struct {
        identity: FileIdentity,
        provenance: Provenance,
        indexed_at_unix_ms: i64,
        parser_confidence: []const u8 = "high",
        raw_reference: []const u8 = "workspace_file",
    };

    /// Allocates a lowercase SHA-256 hex digest for bytes.
    pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        return allocator.dupe(u8, &hex);
    }

    /// Builds file identity from borrowed paths and owned digest bytes.
    pub fn identityFromBytes(allocator: std.mem.Allocator, path: []const u8, abs_path: []const u8, bytes: []const u8) !FileIdentity {
        return .{
            .path = path,
            .abs_path = abs_path,
            .bytes = bytes.len,
            .sha256 = try sha256Hex(allocator, bytes),
        };
    }

    /// Allocates the JSON representation of a registry entry.
    pub fn entryValue(allocator: std.mem.Allocator, entry: RegistryEntry) !std.json.Value {
        // Keep this logic centralized so callers observe one consistent behavior path.
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

    /// Serializes provenance fields into an allocator-owned JSON value; allocation failures propagate.
    fn provenanceValue(allocator: std.mem.Allocator, provenance: Provenance) !std.json.Value {
        // Keep this logic centralized so callers observe one consistent behavior path.
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

    /// Serializes toolchain fields into an allocator-owned JSON value; allocation failures propagate.
    fn toolchainValue(allocator: std.mem.Allocator, toolchain: Toolchain) !std.json.Value {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "zig_path", .{ .string = toolchain.zig_path });
        try obj.put(allocator, "zls_path", .{ .string = toolchain.zls_path });
        try obj.put(allocator, "zflame_path", .{ .string = toolchain.zflame_path });
        try obj.put(allocator, "diff_folded_path", .{ .string = toolchain.diff_folded_path });
        return .{ .object = obj };
    }
};

/// Records an existing workspace artifact through the optional artifact port.
pub fn recordArtifact(app: anytype, allocator: std.mem.Allocator, entry: artifacts.RegistryEntry) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Records an artifact and its bytes through the optional artifact port.
pub fn recordWrittenArtifact(app: anytype, allocator: std.mem.Allocator, entry: artifacts.RegistryEntry, bytes: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Returns current unix milliseconds from the clock port, or 0 when unavailable.
pub fn unixMs(app: anytype) i64 {
    if (app.context.clock_and_ids) |clock| {
        const instant = clock.now() catch return 0;
        return instant.unix_ms;
    }
    return 0;
}

/// Returns abs_path expressed relative to root ("." when equal), or null when
/// abs_path is not strictly under root. The separator check rejects sibling
/// prefixes (e.g. "/repo-other" under root "/repo"), so callers can treat null
/// as a workspace-boundary violation.
fn relativeFromAbs(root: []const u8, abs_path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, root, abs_path)) return ".";
    if (!std.mem.startsWith(u8, abs_path, root)) return null;
    if (abs_path.len <= root.len or abs_path[root.len] != std.fs.path.sep) return null;
    return abs_path[root.len + 1 ..];
}

const fakes = @import("../../testing/fakes/root.zig");

test "workflow support workspace facade delegates through workspace store port" {
    const Stub = struct {
        /// Resolves resolve from caller-provided inputs; borrowed data remains caller-owned and failures are propagated.
        fn resolve(_: *anyopaque, _: std.mem.Allocator, request: ports.WorkspaceResolveRequest) ports.PortError!ports.WorkspaceResolveResult {
            if (request.for_output) return .{ .path = "/workspace/out/report.json" };
            return .{ .path = "/workspace/src/main.zig" };
        }

        /// Reads read data from the provided context without taking ownership of inputs.
        fn read(_: *anyopaque, _: std.mem.Allocator, request: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            if (!std.mem.eql(u8, "src/main.zig", request.path)) return error.StaleArguments;
            return .{ .bytes = "pub fn main() void {}" };
        }

        /// Writes write fields to the provided JSON stream and propagates writer failures.
        fn write(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            if (!request.create_parent_dirs or !request.replace_existing) return error.StaleArguments;
            return .{ .bytes_written = request.bytes.len };
        }

        /// Implements ensure dir workflow logic using caller-owned inputs.
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
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
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
        /// Executes this workflow with caller-owned inputs; command and allocation failures propagate.
        fn run(_: *anyopaque, allocator: std.mem.Allocator, request: ports.CommandRequest) ports.PortError!ports.CommandResult {
            // Keep this logic centralized so callers observe one consistent behavior path.
            if (!std.mem.eql(u8, "/workspace", request.cwd orelse "")) return error.StaleArguments;
            if (!std.mem.eql(u8, "arch110-workflow-command", request.provenance)) return error.StaleArguments;
            const stdout = try allocator.dupe(u8, " M src/main.zig\nR  src/old.zig -> src/new.zig\n?? .zigars-cache/tmp\n");
            errdefer allocator.free(stdout);
            const stderr = try allocator.dupe(u8, "stderr");
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

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, runCommand(failing.allocator(), app, &.{ "git", "status", "--porcelain" }, 5000));

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
    const parse_failed = try splitToolArgsErrorResult(allocator, "zig_tool", "extra", "value", error.FileNotFound);
    try std.testing.expect(parse_failed.is_error);
    try std.testing.expectEqualStrings("argument_parse_failed", parse_failed.value.object.get("code").?.string);
    try std.testing.expectEqual(@as(i64, 42), argInt(.{ .object = obj }, "count", 0));
    try std.testing.expectEqual(@as(i64, 12), argInt(.{ .object = obj }, "missing", 12));
    try obj.put(allocator, "float", .{ .float = 7.9 });
    try std.testing.expectEqual(@as(i64, 7), argInt(.{ .object = obj }, "float", 0));
    try obj.put(allocator, "huge_float", .{ .float = 1e308 });
    try obj.put(allocator, "nan_float", .{ .float = std.math.nan(f64) });
    try std.testing.expectEqual(@as(i64, 99), argInt(.{ .object = obj }, "huge_float", 99));
    try std.testing.expectEqual(@as(i64, 99), argInt(.{ .object = obj }, "nan_float", 99));
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

test "workflow support backend probe helper covers missing failing and unavailable probes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const no_probe_app = .{
        .context = .{ .backend_probe = @as(?ports.BackendProbe, null) },
        .workspace = .{ .root = "/workspace" },
    };
    const missing = checkBackend(no_probe_app, allocator, "zls", &.{"zls"}, 1000);
    try std.testing.expect(!missing.ok);
    try std.testing.expectEqualStrings("unavailable", missing.status);

    var probe = fakes.FakeBackendProbe.init(std.testing.allocator);
    defer probe.deinit();
    const app = .{
        .context = .{ .backend_probe = @as(?ports.BackendProbe, probe.port()) },
        .workspace = .{ .root = "/workspace" },
    };
    const unexpected = checkBackend(app, allocator, "zls", &.{ "zls", "--version" }, 1000);
    try std.testing.expect(!unexpected.ok);
    try std.testing.expectEqualStrings("UnexpectedCall", unexpected.status);

    try probe.expectCheck(.{
        .backend = "zls",
        .argv = &.{ "zls", "--version" },
        .cwd = "/workspace",
        .timeout_ms = 1000,
        .provenance = "arch110-workflow-backend-check",
    }, .{
        .backend = "zls",
        .available = false,
        .unavailable_reason = "not executable",
        .basis = "chmod +x zls",
    });
    const unavailable = checkBackend(app, allocator, "zls", &.{ "zls", "--version" }, 1000);
    try std.testing.expect(!unavailable.ok);
    try std.testing.expectEqualStrings("not executable", unavailable.status);
    try std.testing.expectEqualStrings("chmod +x zls", unavailable.resolution);
    try probe.verify();
}

test "workflow support command argument splitting covers quotes escaping and cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try splitToolArgs(allocator, "zig\\ build \"src/main.zig\" 'single quoted'");
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("zig build", args[0]);
    try std.testing.expectEqualStrings("src/main.zig", args[1]);
    try std.testing.expectEqualStrings("single quoted", args[2]);
    try std.testing.expectError(error.InvalidArguments, splitToolArgs(allocator, "unterminated\\"));
    try std.testing.expectError(error.InvalidArguments, splitToolArgs(allocator, "\"unterminated"));

    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer backing.deinit();
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        const failing_allocator = failing.allocator();
        if (splitToolArgs(failing_allocator, "one two three")) |owned| {
            freeStringList(failing_allocator, owned);
            failing_allocator.free(owned);
        } else |err| try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);

        var join_failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        if (command.joinArgv(join_failing.allocator(), &.{"zig"}, &.{ "build", "test" })) |joined| {
            join_failing.allocator().free(joined);
        } else |err| try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);

        var command_failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        if (commandString(command_failing.allocator(), &.{ "zig", "build", "test" })) |text| {
            command_failing.allocator().free(text);
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

test "workflow support compiler insights and changed paths cover edge classifications" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const insights = try compilerInsightsValue(
        allocator,
        "src/lib.zig:2:3: warning: unused local variable\nnote: referenced here\n",
        "",
        &.{ "zig", "test" },
    );
    const obj = insights.object;
    try std.testing.expectEqual(@as(i64, 1), obj.get("warning_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("note_count").?.integer);

    const summary = try failureSummaryValue(allocator, .{ .bool = true }, false, &.{ "zig", "test" });
    try std.testing.expectEqual(.null, summary.object.get("primary").?);

    var primary = std.json.ObjectMap.empty;
    try primary.put(allocator, "path", .{ .string = "README.md" });
    const likely = try likelyFailureScopeValue(allocator, .{ .object = primary });
    try std.testing.expectEqualStrings("path:README.md", likely.string);

    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    const dummy_app = .{
        .context = .{ .command_runner = commands.port() },
        .workspace = .{ .root = "/workspace" },
    };
    const explicit = try changedPathList(allocator, dummy_app, "src/a.zig, src/b.zig\nsrc/a.zig", 1000);
    try std.testing.expectEqual(@as(usize, 2), explicit.items.len);
    try std.testing.expect(stringListContains(explicit.items, "src/a.zig"));
    try std.testing.expect(!stringListContains(explicit.items, "src/missing.zig"));

    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer backing.deinit();
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        if (changedPathList(failing.allocator(), dummy_app, "src/a.zig src/b.zig", 1000)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }

    const command_error = try commandRunErrorResult(allocator, .{
        .operation = "build",
        .argv = &.{ "zig", "build" },
        .cwd = "/workspace",
        .timeout_ms = 1000,
        .err = error.StreamTooLong,
    });
    try std.testing.expectEqualStrings("command_error", command_error.value.object.get("kind").?.string);
    try std.testing.expect(command_error.value.object.get("output_limit_exceeded").?.bool);
}

test "workflow support serialization and owned JSON teardown cover scalar variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var out: std.ArrayList(u8) = .empty;
    try serializeValue(allocator, &out, .{ .float = 3.5 });
    try out.append(allocator, ',');
    try serializeValue(allocator, &out, .{ .number_string = "42" });
    try out.append(allocator, ',');
    try serializeString(allocator, &out, "\"\\\n\r\t\x08\x0c\x01");
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\\\"\\\\\\n\\r\\t\\b\\f\\u0001") != null);

    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer backing.deinit();
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        if (serializeAlloc(failing.allocator(), .{ .string = "value" })) |bytes| {
            failing.allocator().free(bytes);
        } else |err| try std.testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
    }

    const owned_number = try std.testing.allocator.dupe(u8, "99");
    deinitOwnedValue(std.testing.allocator, .{ .number_string = owned_number });

    var array = std.json.Array.init(std.testing.allocator);
    try array.append(.{ .string = try std.testing.allocator.dupe(u8, "item") });
    var owned_obj = std.json.ObjectMap.empty;
    const owned_key = try std.testing.allocator.dupe(u8, "items");
    try owned_obj.put(std.testing.allocator, owned_key, .{ .array = array });
    deinitOwnedValue(std.testing.allocator, .{ .object = owned_obj });
}
