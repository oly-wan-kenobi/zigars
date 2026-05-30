//! Thin, read-only CLI adapter over existing app use cases, selected by
//! `zigars cli ...`. Only non-mutating reporting commands are exposed and every
//! command requires `--json`; successful output is minified JSON on stdout while
//! diagnostics and help go to stderr. It reuses the same structuredContent
//! builders as the MCP adapter so both surfaces report identical shapes.
const std = @import("std");

const app_context = @import("../../app/context.zig");
const discovery = @import("../../app/usecases/discovery/workflows.zig");

/// Stable public process exit codes for explicit `zigars cli` mode.
pub const ExitCode = enum(u8) {
    success = 0,
    invalid_args = 2,
    workspace_error = 3,
    fatal_internal = 70,
};

/// Supported first-slice CLI commands.
pub const Command = enum {
    workspace_info,
    doctor,

    fn parse(value: []const u8) ?Command {
        if (std.mem.eql(u8, value, "workspace-info")) return .workspace_info;
        if (std.mem.eql(u8, value, "doctor")) return .doctor;
        return null;
    }

    pub fn label(self: Command) []const u8 {
        return switch (self) {
            .workspace_info => "workspace-info",
            .doctor => "doctor",
        };
    }
};

/// Shared read-only process configuration accepted by CLI commands.
pub const SharedOptions = struct {
    workspace: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    zig_path: ?[]const u8 = null,
    zls_path: ?[]const u8 = null,
    zlint_path: ?[]const u8 = null,
    zwanzig_path: ?[]const u8 = null,
    zflame_path: ?[]const u8 = null,
    diff_folded_path: ?[]const u8 = null,
    timeout_ms: ?i64 = null,
    timeout_ms_raw: ?[]const u8 = null,
    zls_timeout_ms: ?i64 = null,
    zls_timeout_ms_raw: ?[]const u8 = null,
};

/// Parsed explicit CLI invocation. Slices borrow from the argv arena.
pub const Invocation = struct {
    command: Command,
    json: bool = false,
    probe_backends: bool = false,
    shared: SharedOptions = .{},

    /// Doctor backend-probe timeout in ms, clamped to 1..10000 (default 1000) to
    /// match the MCP adapter so both surfaces bound probes identically.
    pub fn doctorProbeTimeoutMs(self: Invocation) i64 {
        return @max(1, @min(self.shared.timeout_ms orelse 1_000, 10_000));
    }
};

pub const ParseError = error{
    HelpRequested,
    MissingCommand,
    UnknownCommand,
    MissingJsonFlag,
    MissingValue,
    UnknownArgument,
    InvalidBoolean,
    InvalidTimeout,
};

/// True when argv selects explicit CLI mode. The MCP server remains the default.
pub fn isInvocation(raw_args: []const []const u8) bool {
    return raw_args.len > 1 and std.mem.eql(u8, raw_args[1], "cli");
}

/// Parses `zigars cli <command> ...` into an Invocation, borrowing argv slices.
///
/// `--json` is mandatory and checked last, so a syntactically valid but
/// non-JSON invocation still fails with `MissingJsonFlag`. `--probe-backends`
/// is only accepted for `doctor`; any other unrecognized flag is rejected. `-h`
/// / `--help` short-circuits to `HelpRequested`.
pub fn parse(raw_args: []const []const u8) ParseError!Invocation {
    if (!isInvocation(raw_args)) return ParseError.UnknownArgument;
    if (raw_args.len <= 2) return ParseError.MissingCommand;
    if (std.mem.eql(u8, raw_args[2], "--help") or std.mem.eql(u8, raw_args[2], "-h")) return ParseError.HelpRequested;

    var invocation = Invocation{
        .command = Command.parse(raw_args[2]) orelse return ParseError.UnknownCommand,
    };

    var i: usize = 3;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return ParseError.HelpRequested;
        if (std.mem.eql(u8, arg, "--json")) {
            invocation.json = true;
        } else if (try parseStringFlag(raw_args, &i, arg, "--workspace")) |value| {
            invocation.shared.workspace = value;
        } else if (try parseStringFlag(raw_args, &i, arg, "--cache-dir")) |value| {
            invocation.shared.cache_dir = value;
        } else if (try parseStringFlag(raw_args, &i, arg, "--zig-path")) |value| {
            invocation.shared.zig_path = value;
        } else if (try parseStringFlag(raw_args, &i, arg, "--zls-path")) |value| {
            invocation.shared.zls_path = value;
        } else if (try parseStringFlag(raw_args, &i, arg, "--zlint-path")) |value| {
            invocation.shared.zlint_path = value;
        } else if (try parseStringFlag(raw_args, &i, arg, "--zwanzig-path")) |value| {
            invocation.shared.zwanzig_path = value;
        } else if (try parseStringFlag(raw_args, &i, arg, "--zflame-path")) |value| {
            invocation.shared.zflame_path = value;
        } else if (try parseStringFlag(raw_args, &i, arg, "--diff-folded-path")) |value| {
            invocation.shared.diff_folded_path = value;
        } else if (try parseStringFlag(raw_args, &i, arg, "--timeout-ms")) |value| {
            invocation.shared.timeout_ms = parsePositiveInt(value) catch return ParseError.InvalidTimeout;
            invocation.shared.timeout_ms_raw = value;
        } else if (try parseStringFlag(raw_args, &i, arg, "--zls-timeout-ms")) |value| {
            invocation.shared.zls_timeout_ms = parsePositiveInt(value) catch return ParseError.InvalidTimeout;
            invocation.shared.zls_timeout_ms_raw = value;
        } else if (invocation.command == .doctor) {
            if (try parseStringFlag(raw_args, &i, arg, "--probe-backends")) |value| {
                invocation.probe_backends = parseBool(value) orelse return ParseError.InvalidBoolean;
            } else {
                return ParseError.UnknownArgument;
            }
        } else {
            return ParseError.UnknownArgument;
        }
    }

    if (!invocation.json) return ParseError.MissingJsonFlag;
    return invocation;
}

/// Re-emits the parsed shared options as a synthetic argv (leading "zigars"
/// program slot included) so the shared bootstrap Config parser can consume CLI
/// flags through the same path as the MCP server, avoiding a second config
/// surface. Only options the client actually supplied are appended.
pub fn appendConfigArgs(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), invocation: Invocation) !void {
    try out.append(allocator, "zigars");
    try appendOptional(out, allocator, "--workspace", invocation.shared.workspace);
    try appendOptional(out, allocator, "--cache-dir", invocation.shared.cache_dir);
    try appendOptional(out, allocator, "--zig-path", invocation.shared.zig_path);
    try appendOptional(out, allocator, "--zls-path", invocation.shared.zls_path);
    try appendOptional(out, allocator, "--zlint-path", invocation.shared.zlint_path);
    try appendOptional(out, allocator, "--zwanzig-path", invocation.shared.zwanzig_path);
    try appendOptional(out, allocator, "--zflame-path", invocation.shared.zflame_path);
    try appendOptional(out, allocator, "--diff-folded-path", invocation.shared.diff_folded_path);
    try appendOptional(out, allocator, "--timeout-ms", invocation.shared.timeout_ms_raw);
    try appendOptional(out, allocator, "--zls-timeout-ms", invocation.shared.zls_timeout_ms_raw);
}

/// Renders a successful CLI command result using the existing MCP structuredContent use cases.
pub fn renderValue(allocator: std.mem.Allocator, context: app_context.Context, invocation: Invocation) !std.json.Value {
    return switch (invocation.command) {
        .workspace_info => discovery.workspaceInfoValue(allocator, context),
        .doctor => discovery.doctorValue(allocator, context, invocation.probe_backends, invocation.doctorProbeTimeoutMs()),
    };
}

/// Serializes a JSON value to stable machine output with a trailing newline.
pub fn stringifyAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .minified }, &aw.writer);
    try aw.writer.writeAll("\n");
    const bytes = try aw.toOwnedSlice();
    aw_owned = false;
    return bytes;
}

/// Writes command JSON to stdout; diagnostics are intentionally handled elsewhere.
pub fn stdoutWrite(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

/// Writes CLI diagnostics to stderr.
pub fn stderrPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

/// Emits CLI usage to stderr.
pub fn writeUsage(io: std.Io) !void {
    try stderrPrint(io, "{s}", .{usage()});
}

/// Emits a stable invalid-argument diagnostic to stderr.
pub fn writeParseDiagnostic(io: std.Io, err: ParseError) !void {
    if (err == ParseError.HelpRequested) return writeUsage(io);
    try stderrPrint(io, "zigars cli: {s}\n\n{s}", .{ parseErrorMessage(err), usage() });
}

/// Maps a parse error to its process exit code: an explicit help request exits
/// success; every other parse failure is an invalid-arguments exit.
pub fn parseErrorExitCode(err: ParseError) ExitCode {
    return switch (err) {
        ParseError.HelpRequested => .success,
        else => .invalid_args,
    };
}

/// User-facing CLI help. Successful command output still requires `--json`.
pub fn usage() []const u8 {
    return
    \\zigars cli - thin JSON reporting surface over selected zigars use cases
    \\
    \\Usage:
    \\  zigars cli workspace-info --workspace <path> --json
    \\  zigars cli doctor --workspace <path> --probe-backends=false --json
    \\
    \\Common read-only flags:
    \\  --workspace <path>          Workspace root; defaults to the current directory.
    \\  --cache-dir <path>          Workspace-relative cache directory.
    \\  --zig-path <path>           Zig executable path used in reported configuration.
    \\  --zls-path <path>           ZLS executable path used in reported configuration.
    \\  --zlint-path <path>         ZLint executable path used in reported configuration.
    \\  --zwanzig-path <path>       zwanzig executable path used in reported configuration.
    \\  --zflame-path <path>        zflame executable path used in reported configuration.
    \\  --diff-folded-path <path>   diff-folded executable path used in reported configuration.
    \\  --timeout-ms <n>            Command/probe timeout in milliseconds.
    \\  --zls-timeout-ms <n>        ZLS timeout in milliseconds.
    \\
    \\Doctor flags:
    \\  --probe-backends=true|false Run bounded backend probes; defaults to false.
    \\
    \\Output:
    \\  Successful command output is minified JSON on stdout.
    \\  Diagnostics and help go to stderr.
    \\
    \\Exit codes:
    \\  0  success
    \\  2  invalid CLI arguments
    \\  3  workspace or path resolution error
    \\  70 fatal internal error
    \\
    ;
}

fn parseErrorMessage(err: ParseError) []const u8 {
    return switch (err) {
        ParseError.HelpRequested => "help requested",
        ParseError.MissingCommand => "missing command",
        ParseError.UnknownCommand => "unknown command",
        ParseError.MissingJsonFlag => "missing required --json flag",
        ParseError.MissingValue => "missing flag value",
        ParseError.UnknownArgument => "unknown argument",
        ParseError.InvalidBoolean => "invalid boolean; use true or false",
        ParseError.InvalidTimeout => "invalid timeout; use a positive integer",
    };
}

fn parseStringFlag(raw_args: []const []const u8, index: *usize, arg: []const u8, flag: []const u8) ParseError!?[]const u8 {
    if (std.mem.eql(u8, arg, flag)) {
        index.* += 1;
        if (index.* >= raw_args.len) return ParseError.MissingValue;
        return raw_args[index.*];
    }
    if (assignedValue(arg, flag)) |value| return value;
    return null;
}

fn assignedValue(arg: []const u8, flag: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, flag)) return null;
    if (arg.len <= flag.len or arg[flag.len] != '=') return null;
    return arg[flag.len + 1 ..];
}

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

fn parsePositiveInt(value: []const u8) !i64 {
    const parsed = std.fmt.parseInt(i64, value, 10) catch return error.InvalidTimeout;
    if (parsed <= 0) return error.InvalidTimeout;
    return parsed;
}

fn appendOptional(out: *std.ArrayList([]const u8), allocator: std.mem.Allocator, flag: []const u8, maybe_value: ?[]const u8) !void {
    const value = maybe_value orelse return;
    try out.append(allocator, flag);
    try out.append(allocator, value);
}

test "cli parser accepts workspace-info and doctor JSON commands" {
    const workspace = try parse(&.{ "zigars", "cli", "workspace-info", "--workspace", "/tmp/project", "--json" });
    try std.testing.expectEqual(Command.workspace_info, workspace.command);
    try std.testing.expect(workspace.json);
    try std.testing.expectEqualStrings("/tmp/project", workspace.shared.workspace.?);

    const doctor = try parse(&.{ "zigars", "cli", "doctor", "--workspace=/tmp/project", "--probe-backends=false", "--json", "--timeout-ms", "2500" });
    try std.testing.expectEqual(Command.doctor, doctor.command);
    try std.testing.expect(!doctor.probe_backends);
    try std.testing.expectEqual(@as(i64, 2500), doctor.shared.timeout_ms.?);
    try std.testing.expectEqual(@as(i64, 2500), doctor.doctorProbeTimeoutMs());
}

test "cli parser rejects non-json and mutating-looking commands" {
    try std.testing.expectError(ParseError.MissingJsonFlag, parse(&.{ "zigars", "cli", "workspace-info", "--workspace", "/tmp/project" }));
    try std.testing.expectError(ParseError.UnknownCommand, parse(&.{ "zigars", "cli", "format", "--json" }));
    try std.testing.expectError(ParseError.InvalidBoolean, parse(&.{ "zigars", "cli", "doctor", "--probe-backends", "maybe", "--json" }));
    try std.testing.expectError(ParseError.InvalidTimeout, parse(&.{ "zigars", "cli", "doctor", "--timeout-ms", "0", "--json" }));
}

test "cli exit codes are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ExitCode.success));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(ExitCode.invalid_args));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(ExitCode.workspace_error));
    try std.testing.expectEqual(@as(u8, 70), @intFromEnum(ExitCode.fatal_internal));
    try std.testing.expectEqual(ExitCode.invalid_args, parseErrorExitCode(ParseError.MissingJsonFlag));
}

test "cli renders existing structuredContent JSON shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const context = app_context.Context{
        .workspace = .{
            .root = "/repo",
            .cache_root = "/repo/.zigars-cache",
            .transport = "stdio",
        },
        .tool_paths = .{
            .zig = "zig",
            .zls = "zls",
            .zlint = "zlint",
            .zwanzig = "zwanzig",
            .zflame = "zflame",
            .diff_folded = "diff-folded",
        },
        .timeouts = .{
            .command_ms = 30_000,
            .zls_ms = 30_000,
        },
        .zls_state = .{
            .status = "not started",
        },
    };

    const workspace_value = try renderValue(allocator, context, .{ .command = .workspace_info, .json = true });
    const workspace_json = try stringifyAlloc(allocator, workspace_value);
    try std.testing.expect(std.mem.endsWith(u8, workspace_json, "\n"));
    var parsed_workspace = try std.json.parseFromSlice(std.json.Value, allocator, workspace_json, .{});
    defer parsed_workspace.deinit();
    try std.testing.expectEqualStrings("/repo", parsed_workspace.value.object.get("workspace").?.string);
    try std.testing.expectEqualStrings("not started", parsed_workspace.value.object.get("zls_status").?.string);

    const doctor_value = try renderValue(allocator, context, .{ .command = .doctor, .json = true, .probe_backends = false });
    const doctor_json = try stringifyAlloc(allocator, doctor_value);
    var parsed_doctor = try std.json.parseFromSlice(std.json.Value, allocator, doctor_json, .{});
    defer parsed_doctor.deinit();
    try std.testing.expectEqualStrings("zigars_doctor", parsed_doctor.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("stdio", parsed_doctor.value.object.get("transport").?.string);
}
