const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const catalog = zigar.catalog;
const command = zigar.command;
const doctor = zigar.doctor;
const tool_metadata = zigar.tool_metadata;
const common = @import("common.zig");
const static_analysis = @import("static_analysis.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const argBool = common.argBool;
const argInt = common.argInt;
const workspacePathErrorResult = common.workspacePathErrorResult;
const toolTimeout = common.toolTimeout;
const argvValue = common.argvValue;
const backendErrorResult = common.backendErrorResult;
const splitToolArgs = common.splitToolArgs;
const jsonTextOnly = common.jsonTextOnly;
const probeBackend = common.probeBackend;
const backendProbeCacheValue = common.backendProbeCacheValue;
const ownedString = common.ownedString;
const metricsValue = common.metricsValue;
const zlsStatusValue = common.zlsStatusValue;
const freeArgList = common.freeArgList;
const quotedString = static_analysis.quotedString;

pub fn zigarCapabilities(_: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return catalogToolResult(allocator);
}

pub fn zigarSchema(_: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return catalogToolResult(allocator);
}

pub fn catalogToolResult(allocator: std.mem.Allocator) mcp.tools.ToolError!mcp.tools.ToolResult {
    return jsonTextOnly(allocator, catalog.text(allocator) catch return error.OutOfMemory);
}

pub fn zigarDoctor(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const probe_backends = argBool(args, "probe_backends", false);
    const probe_timeout_ms = @max(1, @min(argInt(args, "timeout_ms", 1_000), 10_000));
    const value = doctor.report(allocator, .{
        .workspace = a.workspace.root,
        .cache = a.workspace.cache_root,
        .strict_workspace = a.config.strict_workspace,
        .transport = switch (a.config.transport) {
            .stdio => "stdio",
            .http => "http",
        },
        .zig_path = a.config.zig_path,
        .zls_path = a.config.zls_path,
        .zwanzig_path = a.config.zwanzig_path,
        .zflame_path = a.config.zflame_path,
        .diff_folded_path = a.config.diff_folded_path,
        .zls_status = a.zls_status,
        .zls_last_failure = a.zls_last_failure,
        .timeout_ms = a.config.timeout_ms,
        .zls_timeout_ms = a.config.zls_timeout_ms,
        .mcp_dependency = "mcp.zig 0.0.4",
        .http_available = true,
        .zig_probe = if (probe_backends) probeBackend(a, allocator, "zig", &.{ a.config.zig_path, "version" }, probe_timeout_ms) else null,
        .zls_probe = if (probe_backends) probeBackend(a, allocator, "zls", &.{ a.config.zls_path, "--version" }, probe_timeout_ms) else null,
        .zwanzig_probe = if (probe_backends) probeBackend(a, allocator, "zwanzig", &.{ a.config.zwanzig_path, "--help" }, probe_timeout_ms) else null,
        .zflame_probe = if (probe_backends) probeBackend(a, allocator, "zflame", &.{ a.config.zflame_path, "--help" }, probe_timeout_ms) else null,
        .diff_folded_probe = if (probe_backends) probeBackend(a, allocator, "diff-folded", &.{ a.config.diff_folded_path, "--help" }, probe_timeout_ms) else null,
    }) catch return error.OutOfMemory;
    return structured(allocator, value);
}

pub fn zigarMetrics(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, metricsValue(a, allocator) catch return error.OutOfMemory);
}

pub fn zigarHttpStatus(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "configured_transport", .{ .string = switch (a.config.transport) {
        .stdio => "stdio",
        .http => "http",
    } }) catch return error.OutOfMemory;
    obj.put(allocator, "host", .{ .string = a.config.host }) catch return error.OutOfMemory;
    obj.put(allocator, "port", .{ .integer = a.config.port }) catch return error.OutOfMemory;
    obj.put(allocator, "http_available", .{ .bool = true }) catch return error.OutOfMemory;
    obj.put(allocator, "reason", .{ .string = "HTTP transport is enabled through mcp.zig 0.0.4; stdio remains the safest default for Codex" }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn workspaceInfo(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "workspace", .{ .string = a.workspace.root }) catch return error.OutOfMemory;
    obj.put(allocator, "cache", .{ .string = a.workspace.cache_root }) catch return error.OutOfMemory;
    obj.put(allocator, "zig", .{ .string = a.config.zig_path }) catch return error.OutOfMemory;
    obj.put(allocator, "zls", .{ .string = a.config.zls_path }) catch return error.OutOfMemory;
    obj.put(allocator, "zls_status", .{ .string = a.zls_status }) catch return error.OutOfMemory;
    obj.put(allocator, "zls_session", zlsStatusValue(allocator, a) catch return error.OutOfMemory) catch return error.OutOfMemory;
    if (a.zls_last_failure) |failure| {
        obj.put(allocator, "zls_last_failure", .{ .string = failure }) catch return error.OutOfMemory;
    } else {
        obj.put(allocator, "zls_last_failure", .null) catch return error.OutOfMemory;
    }
    obj.put(allocator, "zwanzig", .{ .string = a.config.zwanzig_path }) catch return error.OutOfMemory;
    obj.put(allocator, "zflame", .{ .string = a.config.zflame_path }) catch return error.OutOfMemory;
    obj.put(allocator, "timeout_ms", .{ .integer = a.config.timeout_ms }) catch return error.OutOfMemory;
    obj.put(allocator, "zls_timeout_ms", .{ .integer = a.config.zls_timeout_ms }) catch return error.OutOfMemory;
    obj.put(allocator, "strict_workspace", .{ .bool = a.config.strict_workspace }) catch return error.OutOfMemory;
    obj.put(allocator, "backend_probe_cache", backendProbeCacheValue(allocator, a.backend_probe_cache) catch return error.OutOfMemory) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigVersion(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const zig = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zig_path, "version" }, a.config.timeout_ms) catch |err| {
        return backendErrorResult(allocator, "zig", "version", err, "confirm --zig-path points to an executable Zig 0.16.0 binary");
    };
    defer zig.deinit(allocator);
    const zls = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zls_path, "--version" }, a.config.timeout_ms) catch null;
    defer if (zls) |r| r.deinit(allocator);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "zig", .{ .string = std.mem.trim(u8, zig.stdout, " \t\r\n") }) catch return error.OutOfMemory;
    obj.put(allocator, "zig_ok", .{ .bool = zig.succeeded() }) catch return error.OutOfMemory;
    if (zls) |r| {
        obj.put(allocator, "zls", .{ .string = std.mem.trim(u8, r.stdout, " \t\r\n") }) catch return error.OutOfMemory;
        obj.put(allocator, "zls_ok", .{ .bool = r.succeeded() }) catch return error.OutOfMemory;
    } else {
        obj.put(allocator, "zls", .{ .string = "unavailable" }) catch return error.OutOfMemory;
        obj.put(allocator, "zls_ok", .{ .bool = false }) catch return error.OutOfMemory;
    }
    obj.put(allocator, "zls_status", .{ .string = a.zls_status }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigToolchainResolve(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const timeout_ms = toolTimeout(a, args);
    const zig = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zig_path, "version" }, timeout_ms) catch null;
    defer if (zig) |r| r.deinit(allocator);
    const zls = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zls_path, "--version" }, timeout_ms) catch null;
    defer if (zls) |r| r.deinit(allocator);

    var expected = std.json.Array.init(allocator);
    tryAppendVersionHint(allocator, &expected, a, ".zigversion", "first non-empty line", ".zigversion");
    tryAppendToolVersionsHint(allocator, &expected, a);
    tryAppendMiseHint(allocator, &expected, a);
    tryAppendBuildZonMinimumHint(allocator, &expected, a);

    const active_zig = if (zig) |r| std.mem.trim(u8, r.stdout, " \t\r\n") else "";
    var issues = std.json.Array.init(allocator);
    var zig_hint_count: usize = 0;
    var exact_match_found = false;
    var minimum_satisfied = false;
    var unknown_version_hint = false;
    for (expected.items) |hint| {
        const hint_obj = switch (hint) {
            .object => |o| o,
            else => continue,
        };
        switch (zigVersionHintStatus(active_zig, hint_obj)) {
            .ignored => {},
            .exact_match => {
                zig_hint_count += 1;
                exact_match_found = true;
            },
            .minimum_satisfied => {
                zig_hint_count += 1;
                minimum_satisfied = true;
            },
            .mismatch => zig_hint_count += 1,
            .unknown => {
                zig_hint_count += 1;
                unknown_version_hint = true;
            },
        }
    }
    const version_match = zig_hint_count == 0 or exact_match_found or minimum_satisfied;
    const version_status = if (zig_hint_count == 0)
        "no_zig_hints"
    else if (exact_match_found)
        "exact_match"
    else if (minimum_satisfied)
        "minimum_satisfied"
    else if (active_zig.len == 0 or unknown_version_hint)
        "unknown"
    else
        "mismatch";
    if (zig_hint_count > 0 and active_zig.len > 0 and !version_match) {
        try issues.append(.{ .string = try std.fmt.allocPrint(allocator, "active zig version `{s}` does not satisfy any project Zig version hint", .{active_zig}) });
    }
    if (zig == null or !zig.?.succeeded()) {
        try issues.append(try ownedString(allocator, "configured --zig-path is not executable or did not return a version"));
    }
    if (zls == null or !zls.?.succeeded()) {
        try issues.append(try ownedString(allocator, "configured --zls-path is unavailable; ZLS-backed tools will be limited"));
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_toolchain_resolve" });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "zig_path", .{ .string = a.config.zig_path });
    try obj.put(allocator, "zig_version", if (zig) |r| .{ .string = std.mem.trim(u8, r.stdout, " \t\r\n") } else .null);
    try obj.put(allocator, "zig_ok", .{ .bool = if (zig) |r| r.succeeded() else false });
    try obj.put(allocator, "zls_path", .{ .string = a.config.zls_path });
    try obj.put(allocator, "zls_version", if (zls) |r| .{ .string = std.mem.trim(u8, if (r.stdout.len > 0) r.stdout else r.stderr, " \t\r\n") } else .null);
    try obj.put(allocator, "zls_ok", .{ .bool = if (zls) |r| r.succeeded() else false });
    try obj.put(allocator, "project_version_hints", .{ .array = expected });
    try obj.put(allocator, "version_match", .{ .bool = version_match });
    try obj.put(allocator, "zig_hint_count", .{ .integer = @intCast(zig_hint_count) });
    try obj.put(allocator, "version_status", .{ .string = version_status });
    try obj.put(allocator, "managers", try versionManagersValue(allocator, a, argBool(args, "probe_managers", true), timeout_ms));
    try obj.put(allocator, "issues", .{ .array = issues });
    try obj.put(allocator, "resolution", .{ .string = "Use an existing manager such as mise, asdf, zvm, or zigup to install/select the expected Zig version, then restart zigar with matching --zig-path and --zls-path." });
    return structured(allocator, .{ .object = obj });
}

pub const ZigVersionHintStatus = enum {
    ignored,
    exact_match,
    minimum_satisfied,
    mismatch,
    unknown,
};

pub fn zigVersionHintStatus(active_zig: []const u8, hint_obj: std.json.ObjectMap) ZigVersionHintStatus {
    const key = switch (hint_obj.get("key") orelse .null) {
        .string => |s| s,
        else => return .ignored,
    };
    if (!zigVersionHintAppliesToZig(key)) return .ignored;
    const version_hint = switch (hint_obj.get("version") orelse .null) {
        .string => |s| s,
        else => return .unknown,
    };
    if (active_zig.len == 0) return .unknown;
    if (std.mem.eql(u8, key, "minimum_zig_version")) {
        if (versionMeetsMinimum(active_zig, version_hint)) return .minimum_satisfied;
        if (parseVersionPrefix(active_zig) == null or parseVersionPrefix(version_hint) == null) return .unknown;
        return .mismatch;
    }
    if (std.mem.eql(u8, active_zig, version_hint)) return .exact_match;
    return .mismatch;
}

pub fn zigVersionHintAppliesToZig(key: []const u8) bool {
    return !std.mem.eql(u8, key, "zls");
}

pub fn versionMeetsMinimum(active_zig: []const u8, minimum_zig: []const u8) bool {
    const active = parseVersionPrefix(active_zig) orelse return false;
    const minimum = parseVersionPrefix(minimum_zig) orelse return false;
    for (active, minimum) |active_part, minimum_part| {
        if (active_part > minimum_part) return true;
        if (active_part < minimum_part) return false;
    }
    return true;
}

pub fn parseVersionPrefix(raw: []const u8) ?[3]u64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (trimmed.len == 0) return null;
    var pos: usize = if (trimmed[0] == 'v') 1 else 0;
    var parts: [3]u64 = .{ 0, 0, 0 };
    var index: usize = 0;
    while (index < parts.len) : (index += 1) {
        if (pos >= trimmed.len or !std.ascii.isDigit(trimmed[pos])) break;
        var value: u64 = 0;
        while (pos < trimmed.len and std.ascii.isDigit(trimmed[pos])) : (pos += 1) {
            value = value * 10 + (trimmed[pos] - '0');
        }
        parts[index] = value;
        if (pos >= trimmed.len or trimmed[pos] != '.') {
            index += 1;
            break;
        }
        pos += 1;
    }
    if (index < 2) return null;
    return parts;
}

pub fn appendVersionHint(allocator: std.mem.Allocator, hints: *std.json.Array, source: []const u8, key: []const u8, version_value: []const u8) !void {
    const trimmed = std.mem.trim(u8, version_value, " \t\r\n\"'");
    if (trimmed.len == 0) return;
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "source", try ownedString(allocator, source));
    try obj.put(allocator, "key", try ownedString(allocator, key));
    try obj.put(allocator, "version", try ownedString(allocator, trimmed));
    try hints.append(.{ .object = obj });
}

pub fn tryAppendVersionHint(allocator: std.mem.Allocator, hints: *std.json.Array, a: *App, path: []const u8, key: []const u8, source: []const u8) void {
    const bytes = a.workspace.readFileAlloc(a.io, path, 64 * 1024) catch return;
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;
        appendVersionHint(allocator, hints, source, key, trimmed) catch return;
        return;
    }
}

pub fn tryAppendToolVersionsHint(allocator: std.mem.Allocator, hints: *std.json.Array, a: *App) void {
    const bytes = a.workspace.readFileAlloc(a.io, ".tool-versions", 64 * 1024) catch return;
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeAny(u8, line, " \t\r\n");
        const tool = parts.next() orelse continue;
        if (!std.mem.eql(u8, tool, "zig") and !std.mem.eql(u8, tool, "zls")) continue;
        const version_hint = parts.next() orelse continue;
        appendVersionHint(allocator, hints, ".tool-versions", tool, version_hint) catch return;
    }
}

pub fn tryAppendMiseHint(allocator: std.mem.Allocator, hints: *std.json.Array, a: *App) void {
    const bytes = a.workspace.readFileAlloc(a.io, "mise.toml", 128 * 1024) catch return;
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "zig =")) {
            if (quotedString(trimmed)) |version_hint| appendVersionHint(allocator, hints, "mise.toml", "zig", version_hint) catch return;
        }
    }
}

pub fn tryAppendBuildZonMinimumHint(allocator: std.mem.Allocator, hints: *std.json.Array, a: *App) void {
    const bytes = a.workspace.readFileAlloc(a.io, "build.zig.zon", 256 * 1024) catch return;
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.indexOf(u8, trimmed, "minimum_zig_version") != null) {
            if (quotedString(trimmed)) |version_hint| appendVersionHint(allocator, hints, "build.zig.zon", "minimum_zig_version", version_hint) catch return;
        }
    }
}

pub fn versionManagersValue(allocator: std.mem.Allocator, a: *App, probe: bool, timeout_ms: i64) !std.json.Value {
    var managers = std.json.Array.init(allocator);
    const names = [_][]const u8{ "mise", "asdf", "zvm", "zigup" };
    const args = [_][]const u8{ "--version", "--version", "version", "--version" };
    for (names, args) |name, version_arg| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "name", .{ .string = name });
        if (probe) {
            const result = command.run(allocator, a.io, a.workspace.root, &.{ name, version_arg }, @min(timeout_ms, 3000)) catch null;
            if (result) |r| {
                defer r.deinit(allocator);
                try obj.put(allocator, "available", .{ .bool = r.succeeded() });
                try obj.put(allocator, "version_output", try ownedString(allocator, std.mem.trim(u8, if (r.stdout.len > 0) r.stdout else r.stderr, " \t\r\n")));
            } else {
                try obj.put(allocator, "available", .{ .bool = false });
                try obj.put(allocator, "version_output", .null);
            }
        } else {
            try obj.put(allocator, "available", .null);
            try obj.put(allocator, "version_output", .null);
        }
        try managers.append(.{ .object = obj });
    }
    return .{ .array = managers };
}

pub fn zigCommandPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const tool_name = argString(args, "tool") orelse return error.InvalidArguments;
    const entry = tool_metadata.findEntry(tool_name) orelse return error.InvalidArguments;
    const plan = tool_metadata.commandPlanFor(entry.id) orelse {
        return commandPlanUnsupportedResult(allocator, entry);
    };
    return exactCommandPlanResult(a, allocator, args, entry, plan, "zig_command_plan");
}

pub fn zigToolPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const tool_name = argString(args, "tool") orelse return error.InvalidArguments;
    const entry = tool_metadata.findEntry(tool_name) orelse return error.InvalidArguments;
    return switch (entry.plan) {
        .exact_command => |plan| exactCommandPlanResult(a, allocator, args, entry, plan, "zig_tool_plan"),
        else => toolPlanPolicyResult(allocator, entry),
    };
}

fn exactCommandPlanResult(
    a: *App,
    allocator: std.mem.Allocator,
    args: ?std.json.Value,
    entry: tool_metadata.ToolEntry,
    plan: tool_metadata.CommandPlan,
    planner_name: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var resolved_path: ?[]const u8 = null;
    defer if (resolved_path) |path| allocator.free(path);
    list.append(allocator, a.config.zig_path) catch return error.OutOfMemory;

    switch (plan) {
        .argv => |argv| list.appendSlice(allocator, argv) catch return error.OutOfMemory,
        .optional_file => |file_plan| {
            if (argString(args, "file")) |file| {
                resolved_path = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, planner_name, file, err);
                list.appendSlice(allocator, file_plan.file_args) catch return error.OutOfMemory;
                list.append(allocator, resolved_path.?) catch return error.OutOfMemory;
            } else {
                list.appendSlice(allocator, file_plan.fallback_args) catch return error.OutOfMemory;
            }
        },
        .required_file => |argv| {
            const file = argString(args, "file") orelse {
                return missingPlanningArgumentResult(allocator, planner_name, entry, "file");
            };
            resolved_path = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, planner_name, file, err);
            list.appendSlice(allocator, argv) catch return error.OutOfMemory;
            list.append(allocator, resolved_path.?) catch return error.OutOfMemory;
        },
        .required_path => |argv| {
            const path = argString(args, "path") orelse {
                return missingPlanningArgumentResult(allocator, planner_name, entry, "path");
            };
            resolved_path = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, planner_name, path, err);
            list.appendSlice(allocator, argv) catch return error.OutOfMemory;
            list.append(allocator, resolved_path.?) catch return error.OutOfMemory;
        },
    }
    const extra = try splitToolArgs(allocator, argString(args, "args"));
    defer freeArgList(allocator, extra);
    list.appendSlice(allocator, extra) catch return error.OutOfMemory;

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    putPlanningBase(allocator, &obj, planner_name, entry, true) catch return error.OutOfMemory;
    obj.put(allocator, "command_backed", .{ .bool = true }) catch return error.OutOfMemory;
    obj.put(allocator, "argv_exact", .{ .bool = true }) catch return error.OutOfMemory;
    obj.put(allocator, "cwd", .{ .string = a.workspace.root }) catch return error.OutOfMemory;
    obj.put(allocator, "argv", argvValue(allocator, list.items) catch return error.OutOfMemory) catch return error.OutOfMemory;
    obj.put(allocator, "timeout_ms", .{ .integer = toolTimeout(a, args) }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn commandPlanUnsupportedResult(allocator: std.mem.Allocator, entry: tool_metadata.ToolEntry) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    putPlanningBase(allocator, &obj, "zig_command_plan", entry, false) catch return error.OutOfMemory;
    obj.put(allocator, "command_backed", .{ .bool = false }) catch return error.OutOfMemory;
    obj.put(allocator, "argv_exact", .{ .bool = false }) catch return error.OutOfMemory;
    obj.put(allocator, "reason", .{ .string = "zig_command_plan only returns exact argv/cwd/timeout plans for command-backed tools." }) catch return error.OutOfMemory;
    obj.put(allocator, "use", .{ .string = "zig_tool_plan" }) catch return error.OutOfMemory;
    obj.put(allocator, "supported_tools", supportedCommandToolsValue(allocator) catch return error.OutOfMemory) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn toolPlanPolicyResult(allocator: std.mem.Allocator, entry: tool_metadata.ToolEntry) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    const supported = switch (entry.plan) {
        .not_plannable => false,
        else => true,
    };
    putPlanningBase(allocator, &obj, "zig_tool_plan", entry, supported) catch return error.OutOfMemory;
    putPlanPolicyDetails(allocator, &obj, entry) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn missingPlanningArgumentResult(
    allocator: std.mem.Allocator,
    planner_name: []const u8,
    entry: tool_metadata.ToolEntry,
    field: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    putPlanningBase(allocator, &obj, planner_name, entry, false) catch return error.OutOfMemory;
    obj.put(allocator, "error_kind", .{ .string = "argument_error" }) catch return error.OutOfMemory;
    obj.put(allocator, "code", .{ .string = "missing_required_argument" }) catch return error.OutOfMemory;
    obj.put(allocator, "field", .{ .string = field }) catch return error.OutOfMemory;
    obj.put(allocator, "expected", .{ .string = "non-empty workspace-relative path" }) catch return error.OutOfMemory;
    obj.put(allocator, "resolution", .{ .string = "Provide the required argument or use zig_tool_plan on non-command tools to inspect planning support without producing argv." }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

fn putPlanningBase(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    planner_name: []const u8,
    entry: tool_metadata.ToolEntry,
    supported: bool,
) !void {
    const risk = tool_metadata.riskFor(entry.id);
    try obj.put(allocator, "kind", .{ .string = planner_name });
    try obj.put(allocator, "tool", .{ .string = entry.name });
    try obj.put(allocator, "registered", .{ .bool = true });
    try obj.put(allocator, "supported", .{ .bool = supported });
    try obj.put(allocator, "plan_kind", .{ .string = tool_metadata.planKind(entry.plan) });
    try obj.put(allocator, "group", .{ .string = tool_metadata.groupName(entry.group) });
    try obj.put(allocator, "description", .{ .string = entry.meta.description });
    try obj.put(allocator, "read_only", .{ .bool = entry.meta.read_only });
    try obj.put(allocator, "risk", try tool_metadata.riskValue(allocator, entry.meta));
    try obj.put(allocator, "risk_level", .{ .string = tool_metadata.riskLevel(risk) });
    try obj.put(allocator, "writes_source", .{ .bool = risk.writes_source });
}

fn putPlanPolicyDetails(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, entry: tool_metadata.ToolEntry) !void {
    switch (entry.plan) {
        .exact_command => unreachable,
        .dynamic_command => |reason| {
            try obj.put(allocator, "command_backed", .{ .bool = true });
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .zls_request => |plan| {
            try obj.put(allocator, "command_backed", .{ .bool = false });
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "backend", .{ .string = "zls" });
            try obj.put(allocator, "method", .{ .string = plan.method });
            try obj.put(allocator, "requires_document_sync", .{ .bool = plan.requires_document_sync });
            try obj.put(allocator, "mutates_document_state", .{ .bool = plan.mutates_document_state });
            if (plan.required_capability) |capability| {
                try obj.put(allocator, "required_capability", .{ .string = capability });
            } else {
                try obj.put(allocator, "required_capability", .null);
            }
        },
        .apply_gated_mutation => |reason| {
            try obj.put(allocator, "command_backed", .{ .bool = entry.risk.executes_backend });
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "apply_gated", .{ .bool = true });
            try obj.put(allocator, "preview_by_default", .{ .bool = entry.risk.preview_by_default });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .workspace_artifact => |reason| {
            try obj.put(allocator, "command_backed", .{ .bool = entry.risk.executes_backend });
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "writes_artifact", .{ .bool = true });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .pure_analysis => |reason| {
            try obj.put(allocator, "command_backed", .{ .bool = false });
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .not_plannable => |reason| {
            try obj.put(allocator, "command_backed", .{ .bool = false });
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
    }
}

fn supportedCommandToolsValue(allocator: std.mem.Allocator) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (tool_metadata.entries) |entry| {
        if (tool_metadata.commandPlanFor(entry.id) != null) {
            try array.append(.{ .string = entry.name });
        }
    }
    return .{ .array = array };
}
