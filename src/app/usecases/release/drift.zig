const std = @import("std");
const app_context = @import("../../context.zig");
const support = @import("../usecase_support.zig");

pub const App = support.UsecaseApp(app_context.ReleaseWorkflowContext);
pub const Result = support.Result;
const argString = support.argString;
const invalidArgumentResult = support.invalidArgumentResult;
const structured = support.structured;
const toolErrorFromError = support.toolErrorFromError;

const Mode = enum {
    compact,
    standard,
    deep,

    fn name(self: Mode) []const u8 {
        return @tagName(self);
    }
};

const doc_paths = [_][]const u8{
    "README.md",
    "docs/tools.md",
    "docs/tool-index.generated.md",
    "docs/trust.md",
    "docs/release.md",
};

const overclaim_tokens = [_][]const u8{
    "top notch",
    "production-grade",
    "fully supports",
    "complete Zig docs",
    "semantic proof",
};

pub fn zigarDocsDriftCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const mode = parseModeArg(allocator, "zigar_docs_drift_check", args) catch |err| return modeError(allocator, "zigar_docs_drift_check", args, err);
    var checks = std.json.Array.init(allocator);
    errdefer checks.deinit();
    var ok = true;
    for (doc_paths) |path| {
        const bytes = readWorkspaceFile(a, allocator, path) catch |err| {
            ok = false;
            try checks.append(try fileCheckErrorValue(allocator, path, err));
            continue;
        };
        defer allocator.free(bytes);
        try checks.append(try docNeedleCheckValue(a, allocator, path, bytes));
    }
    ok = ok and allChecksOk(checks);
    return structured(allocator, driftResultValue(allocator, .{
        .kind = "zigar_docs_drift_check",
        .mode = mode,
        .ok = ok,
        .checks = checks,
        .evidence_source = "bounded_workspace_doc_reads",
        .limitations = "This tool checks public contract markers and generated-index presence; it does not replace the full release-check target.",
        .resolution = if (ok) "documentation drift markers are present" else "update docs or run zig build tool-index, then verify with zig build docs-check and release-check",
    }) catch return error.OutOfMemory);
}

pub fn zigarReleaseClaimCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const mode = parseModeArg(allocator, "zigar_release_claim_check", args) catch |err| return modeError(allocator, "zigar_release_claim_check", args, err);
    var checks = std.json.Array.init(allocator);
    errdefer checks.deinit();
    var ok = true;
    for ([_][]const u8{ "README.md", "docs/tools.md", "docs/maturity.md", "docs/backends.md" }) |path| {
        const bytes = readWorkspaceFile(a, allocator, path) catch |err| {
            ok = false;
            try checks.append(try fileCheckErrorValue(allocator, path, err));
            continue;
        };
        defer allocator.free(bytes);
        const value = try claimCheckValue(allocator, path, bytes);
        if (!value.object.get("ok").?.bool) ok = false;
        try checks.append(value);
    }
    return structured(allocator, driftResultValue(allocator, .{
        .kind = "zigar_release_claim_check",
        .mode = mode,
        .ok = ok,
        .checks = checks,
        .evidence_source = "public_docs_claim_token_scan",
        .limitations = "Claim checks are conservative token scans; release evidence still comes from release-check, release-readiness, and real-backend conformance artifacts.",
        .resolution = if (ok) "public claim guard tokens passed" else "replace overclaims with evidence-labeled wording and cite verification paths",
    }) catch return error.OutOfMemory);
}

pub fn zigarToolIndexCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const mode = parseModeArg(allocator, "zigar_tool_index_check", args) catch |err| return modeError(allocator, "zigar_tool_index_check", args, err);
    const path = "docs/tool-index.generated.md";
    const bytes = readWorkspaceFile(a, allocator, path) catch |err| return toolErrorFromError(allocator, .{
        .tool = "zigar_tool_index_check",
        .operation = "read_tool_index",
        .phase = "docs_drift",
        .code = "read_failed",
        .category = "filesystem",
        .resolution = "Run zig build tool-index to generate docs/tool-index.generated.md, then retry.",
    }, err);
    defer allocator.free(bytes);

    var missing = std.json.Array.init(allocator);
    errdefer missing.deinit();
    var index: usize = 0;
    while (index < a.context.tool_manifest.count()) : (index += 1) {
        const entry = a.context.tool_manifest.entryAt(index) orelse continue;
        const needle = std.fmt.allocPrint(allocator, "`{s}`", .{entry.name}) catch return error.OutOfMemory;
        defer allocator.free(needle);
        if (std.mem.indexOf(u8, bytes, needle) == null) try missing.append(.{ .string = entry.name });
    }
    const ok = missing.items.len == 0 and std.mem.indexOf(u8, bytes, "Generated by zigar-tools generate-tool-index") != null;
    var checks = std.json.Array.init(allocator);
    errdefer checks.deinit();
    var item = std.json.ObjectMap.empty;
    errdefer item.deinit(allocator);
    try item.put(allocator, "path", .{ .string = path });
    try item.put(allocator, "ok", .{ .bool = ok });
    try item.put(allocator, "registered_tool_count", .{ .integer = @intCast(a.context.tool_manifest.count()) });
    try item.put(allocator, "missing_tool_count", .{ .integer = @intCast(missing.items.len) });
    try item.put(allocator, "missing_tools", .{ .array = missing });
    try checks.append(.{ .object = item });

    return structured(allocator, driftResultValue(allocator, .{
        .kind = "zigar_tool_index_check",
        .mode = mode,
        .ok = ok,
        .checks = checks,
        .evidence_source = "manifest_registered_tools_vs_generated_tool_index",
        .limitations = "This check validates tool mentions in the generated index; run zig build docs-check for byte-for-byte regeneration drift.",
        .resolution = if (ok) "generated tool index mentions every registered tool" else "run zig build tool-index and commit the regenerated docs/tool-index.generated.md",
    }) catch return error.OutOfMemory);
}

const DriftResult = struct {
    kind: []const u8,
    mode: Mode,
    ok: bool,
    checks: std.json.Array,
    evidence_source: []const u8,
    limitations: []const u8,
    resolution: []const u8,
};

fn driftResultValue(allocator: std.mem.Allocator, input: DriftResult) !std.json.Value {
    var omitted = std.json.Array.init(allocator);
    errdefer omitted.deinit();
    if (input.mode == .compact) {
        try omitted.append(try omissionValue(allocator, "full_release_check_output", "compact drift result reports structured markers only", "run zig build release-check --summary all"));
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = input.kind });
    try obj.put(allocator, "ok", .{ .bool = input.ok });
    try attachMetadata(allocator, &obj, input.mode, omitted);
    try obj.put(allocator, "checks", .{ .array = input.checks });
    try obj.put(allocator, "evidence_source", .{ .string = input.evidence_source });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "limitations", .{ .string = input.limitations });
    try obj.put(allocator, "resolution", .{ .string = input.resolution });
    return .{ .object = obj };
}

fn docNeedleCheckValue(a: *App, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !std.json.Value {
    var missing = std.json.Array.init(allocator);
    errdefer missing.deinit();
    if (std.mem.eql(u8, path, "docs/tool-index.generated.md")) {
        var index: usize = 0;
        while (index < a.context.tool_manifest.count()) : (index += 1) {
            const entry = a.context.tool_manifest.entryAt(index) orelse continue;
            const needle = try std.fmt.allocPrint(allocator, "`{s}`", .{entry.name});
            defer allocator.free(needle);
            if (std.mem.indexOf(u8, bytes, needle) == null) try missing.append(.{ .string = entry.name });
        }
    } else {
        for (docNeedles(path)) |needle| {
            if (std.mem.indexOf(u8, bytes, needle) == null) try missing.append(.{ .string = needle });
        }
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "ok", .{ .bool = missing.items.len == 0 });
    try obj.put(allocator, "missing_count", .{ .integer = @intCast(missing.items.len) });
    try obj.put(allocator, "missing", .{ .array = missing });
    return .{ .object = obj };
}

fn docNeedles(path: []const u8) []const []const u8 {
    if (std.mem.eql(u8, path, "README.md")) return &.{
        "Public feature claims use evidence labels",
        "command-backed tools",
    };
    if (std.mem.eql(u8, path, "docs/tools.md")) return &.{
        "## Evidence Labels",
        "Real conformance artifact",
    };
    if (std.mem.eql(u8, path, "docs/trust.md")) return &.{
        "release-check",
        "validation evidence block",
    };
    if (std.mem.eql(u8, path, "docs/release.md")) return &.{
        "source_tree_clean: true",
        "Release Readiness",
    };
    return &.{};
}

fn claimCheckValue(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !std.json.Value {
    var found = std.json.Array.init(allocator);
    errdefer found.deinit();
    for (overclaim_tokens) |needle| {
        if (std.mem.indexOf(u8, bytes, needle) != null) try found.append(.{ .string = needle });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "ok", .{ .bool = found.items.len == 0 });
    try obj.put(allocator, "overclaim_count", .{ .integer = @intCast(found.items.len) });
    try obj.put(allocator, "overclaims", .{ .array = found });
    return .{ .object = obj };
}

fn fileCheckErrorValue(allocator: std.mem.Allocator, path: []const u8, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = support.command.errorKind(err) });
    return .{ .object = obj };
}

fn allChecksOk(checks: std.json.Array) bool {
    for (checks.items) |item| {
        if (!item.object.get("ok").?.bool) return false;
    }
    return true;
}

fn readWorkspaceFile(a: *App, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    _ = allocator;
    return a.workspace.readFileAlloc(a.io, path, 8 * 1024 * 1024);
}

fn parseModeArg(allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value) !Mode {
    _ = allocator;
    _ = tool_name;
    const raw = argString(args, "mode") orelse Mode.standard.name();
    inline for (std.meta.fields(Mode)) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return error.InvalidMode;
}

fn modeError(allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value, err: anyerror) !Result {
    return switch (err) {
        error.InvalidMode => invalidArgumentResult(allocator, tool_name, "mode", supportedModesText(), argString(args, "mode") orelse "", "Choose compact, standard, or deep."),
        else => error.OutOfMemory,
    };
}

fn attachMetadata(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, mode: Mode, omitted: std.json.Array) !void {
    try obj.put(allocator, "mode", .{ .string = mode.name() });
    try obj.put(allocator, "result_shape", try resultShapeValue(allocator, mode));
    try obj.put(allocator, "omitted_sections", .{ .array = omitted });
}

fn resultShapeValue(allocator: std.mem.Allocator, mode: Mode) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "mode", .{ .string = mode.name() });
    try obj.put(allocator, "schema_version", .{ .integer = 1 });
    return .{ .object = obj };
}

fn omissionValue(allocator: std.mem.Allocator, section: []const u8, reason: []const u8, restore_with: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "section", .{ .string = section });
    try obj.put(allocator, "reason", .{ .string = reason });
    try obj.put(allocator, "restore_with", .{ .string = restore_with });
    return .{ .object = obj };
}

fn supportedModesText() []const u8 {
    return "compact, standard, or deep";
}

test "claim check flags public overclaim tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try claimCheckValue(arena.allocator(), "README.md", "production-grade semantic proof");
    try std.testing.expect(!value.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 2), value.object.get("overclaim_count").?.integer);
}
