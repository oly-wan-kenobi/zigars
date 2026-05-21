const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const common = @import("common.zig");

const App = common.App;
const argBool = common.argBool;
const argInt = common.argInt;
const argString = common.argString;
const invalidArgumentResult = common.invalidArgumentResult;
const structured = common.structured;
const toolErrorFromError = common.toolErrorFromError;
const workspacePathErrorResult = common.workspacePathErrorResult;

const artifacts = zigar.artifacts;
const result_shape = zigar.result_shape;

const default_scan_roots = [_][]const u8{ ".zigar-cache", "zig-out", "coverage", "dist" };
const max_hash_bytes: usize = 32 * 1024 * 1024;

pub fn zigarArtifactIndex(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode = parseModeArg(allocator, "zigar_artifact_index", args) catch |err| return modeError(allocator, "zigar_artifact_index", args, err);
    const limit: usize = @intCast(@max(1, @min(argInt(args, "limit", 50), 500)));
    const include_hashes = argBool(args, "include_hashes", true);
    const root_arg = argString(args, "path");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const registry_abs = a.workspace.resolveOutput(artifacts.default_registry_path) catch |err| return workspacePathErrorResult(a, allocator, "zigar_artifact_index", artifacts.default_registry_path, err);
    defer a.workspace.allocator.free(registry_abs);
    var registry = artifacts.loadRegistry(scratch, a.io, registry_abs) catch |err| return artifactError(allocator, "zigar_artifact_index", "load_registry", artifacts.default_registry_path, err, "Confirm zigar can read .zigar-cache artifact registry metadata, then retry.");
    defer registry.deinit(scratch);

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| scratch.free(path);
        paths.deinit(scratch);
    }
    if (root_arg) |root| {
        const resolved = a.workspace.resolve(root) catch |err| return workspacePathErrorResult(a, allocator, "zigar_artifact_index", root, err);
        defer a.workspace.allocator.free(resolved);
        try collectArtifactPaths(scratch, a, &paths, resolved, limit);
    } else {
        for (default_scan_roots) |root| {
            if (paths.items.len >= limit) break;
            const resolved = a.workspace.resolve(root) catch continue;
            defer a.workspace.allocator.free(resolved);
            try collectArtifactPaths(scratch, a, &paths, resolved, limit);
        }
    }
    std.mem.sort([]const u8, paths.items, {}, stringLessThan);

    var scanned = std.json.Array.init(allocator);
    errdefer scanned.deinit();
    for (paths.items) |path| {
        try scanned.append(try scannedArtifactValue(allocator, a, path, include_hashes));
    }

    var omitted = std.json.Array.init(allocator);
    errdefer omitted.deinit();
    if (mode == .compact and paths.items.len >= limit) {
        try omitted.append(try result_shape.omissionValue(allocator, "additional_artifacts", "limit reached in compact artifact index", "increase limit or use mode=deep"));
    }
    if (!include_hashes) {
        try omitted.append(try result_shape.omissionValue(allocator, "artifact_hashes", "include_hashes=false", "set include_hashes=true"));
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_artifact_index" });
    try obj.put(allocator, "ok", .{ .bool = true });
    try result_shape.attachMetadata(allocator, &obj, mode, omitted);
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "registry_path", .{ .string = artifacts.default_registry_path });
    try obj.put(allocator, "registered_count", .{ .integer = @intCast(registry.entries.items.len) });
    try obj.put(allocator, "scanned_count", .{ .integer = @intCast(paths.items.len) });
    try obj.put(allocator, "scan_roots", try stringArrayValue(allocator, if (root_arg) |root| &.{root} else &default_scan_roots));
    try obj.put(allocator, "registered_artifacts", try artifacts.registryValue(allocator, registry));
    try obj.put(allocator, "scanned_artifacts", .{ .array = scanned });
    try obj.put(allocator, "evidence_source", .{ .string = "registry_jsonl_and_workspace_artifact_scan" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "limitations", .{ .string = "The registry only contains artifacts explicitly registered by zigar workflows; scan results are bounded by limit and hash-size constraints." });
    try obj.put(allocator, "resolution", .{ .string = "Use zigar_artifact_read for a specific artifact or zigar_artifact_prune to remove stale registry entries after previewing the preimage identity." });
    return structured(allocator, .{ .object = obj });
}

pub fn zigarArtifactRead(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode = parseModeArg(allocator, "zigar_artifact_read", args) catch |err| return modeError(allocator, "zigar_artifact_read", args, err);
    const path = argString(args, "path") orelse return common.missingArgumentResult(allocator, "zigar_artifact_read", "path", "workspace-relative artifact path");
    const max_bytes: usize = @intCast(@max(1, @min(argInt(args, "max_bytes", artifacts.default_read_limit), 4 * 1024 * 1024)));
    const resolved = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zigar_artifact_read", path, err);
    defer a.workspace.allocator.free(resolved);
    const bytes = std.Io.Dir.cwd().readFileAlloc(a.io, resolved, allocator, .limited(max_bytes)) catch |err| return artifactError(allocator, "zigar_artifact_read", "read_artifact", path, err, "Confirm the artifact exists inside the workspace, or raise max_bytes for bounded text reads.");
    defer allocator.free(bytes);
    const hash = artifacts.sha256Hex(allocator, bytes) catch return error.OutOfMemory;
    defer allocator.free(hash);

    var omitted = std.json.Array.init(allocator);
    errdefer omitted.deinit();
    if (mode == .compact) {
        try omitted.append(try result_shape.omissionValue(allocator, "full_content_context", "compact mode returns the bounded text and identity only", "use mode=deep with a suitable max_bytes value"));
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_artifact_read" });
    try obj.put(allocator, "ok", .{ .bool = true });
    try result_shape.attachMetadata(allocator, &obj, mode, omitted);
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "abs_path", .{ .string = resolved });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes.len) });
    try obj.put(allocator, "max_bytes", .{ .integer = @intCast(max_bytes) });
    try obj.put(allocator, "sha256", .{ .string = hash });
    try obj.put(allocator, "content", .{ .string = bytes });
    try obj.put(allocator, "evidence_source", .{ .string = "workspace_file_read" });
    try obj.put(allocator, "confidence", .{ .string = "high" });
    try obj.put(allocator, "limitations", .{ .string = "Content is returned as bounded text; binary artifacts may not be human-readable." });
    try obj.put(allocator, "resolution", .{ .string = "Use the sha256 and path fields when citing this artifact as evidence." });
    return structured(allocator, .{ .object = obj });
}

pub fn zigarArtifactPrune(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode = parseModeArg(allocator, "zigar_artifact_prune", args) catch |err| return modeError(allocator, "zigar_artifact_prune", args, err);
    const apply = argBool(args, "apply", false);
    const registry_abs = a.workspace.resolveOutput(artifacts.default_registry_path) catch |err| return workspacePathErrorResult(a, allocator, "zigar_artifact_prune", artifacts.default_registry_path, err);
    defer a.workspace.allocator.free(registry_abs);
    const preimage = artifacts.preimageIdentity(allocator, a.io, registry_abs) catch |err| return artifactError(allocator, "zigar_artifact_prune", "read_preimage", artifacts.default_registry_path, err, "Confirm zigar can inspect the artifact registry preimage before pruning.");

    var registry = artifacts.loadRegistry(allocator, a.io, registry_abs) catch |err| return artifactError(allocator, "zigar_artifact_prune", "load_registry", artifacts.default_registry_path, err, "Confirm zigar can read the artifact registry before pruning.");
    defer registry.deinit(allocator);
    const before_count = registry.entries.items.len;
    const summary = artifacts.pruneStale(allocator, a.io, &registry) catch |err| return artifactError(allocator, "zigar_artifact_prune", "prune_registry", artifacts.default_registry_path, err, "Inspect registry entries and rerun after removing unreadable artifact paths.");
    if (apply) {
        artifacts.writeRegistry(allocator, a.io, registry_abs, registry) catch |err| return artifactError(allocator, "zigar_artifact_prune", "write_registry", artifacts.default_registry_path, err, "Confirm zigar can write .zigar-cache/artifacts before applying prune.");
    }

    var omitted = std.json.Array.init(allocator);
    errdefer omitted.deinit();
    if (!apply) {
        try omitted.append(try result_shape.omissionValue(allocator, "registry_write", "apply=false preview only", "rerun with apply=true after confirming preimage_identity"));
    }
    if (mode == .compact) {
        try omitted.append(try result_shape.omissionValue(allocator, "remaining_registry_entries", "compact mode returns counts only", "use mode=deep after pruning if entry details are needed"));
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_artifact_prune" });
    try obj.put(allocator, "ok", .{ .bool = true });
    try result_shape.attachMetadata(allocator, &obj, mode, omitted);
    try obj.put(allocator, "applied", .{ .bool = apply });
    try obj.put(allocator, "registry_path", .{ .string = artifacts.default_registry_path });
    try obj.put(allocator, "preimage_identity", preimage);
    try obj.put(allocator, "before_count", .{ .integer = @intCast(before_count) });
    try obj.put(allocator, "after_count", .{ .integer = @intCast(registry.entries.items.len) });
    try obj.put(allocator, "summary", try artifacts.pruneSummaryValue(allocator, summary));
    try obj.put(allocator, "evidence_source", .{ .string = "artifact_registry_preimage_and_workspace_file_hashes" });
    try obj.put(allocator, "confidence", .{ .string = "high" });
    try obj.put(allocator, "limitations", .{ .string = "Prune removes stale registry records only; it does not delete artifact files." });
    try obj.put(allocator, "resolution", .{ .string = if (apply) "stale registry entries were removed" else "preview complete; rerun with apply=true to update the registry" });
    return structured(allocator, .{ .object = obj });
}

fn collectArtifactPaths(allocator: std.mem.Allocator, a: *App, paths: *std.ArrayList([]const u8), abs_root: []const u8, limit: usize) !void {
    var dir = std.Io.Dir.openDirAbsolute(a.io, abs_root, .{ .iterate = true }) catch return;
    defer dir.close(a.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (paths.items.len < limit) {
        const entry = walker.next(a.io) catch break;
        const actual = entry orelse break;
        if (actual.kind != .file) continue;
        const abs = try std.fs.path.join(allocator, &.{ abs_root, actual.path });
        errdefer allocator.free(abs);
        try paths.append(allocator, abs);
    }
}

fn scannedArtifactValue(allocator: std.mem.Allocator, a: *App, abs_path: []const u8, include_hashes: bool) !std.json.Value {
    const rel = a.workspace.relative(abs_path);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "path", .{ .string = rel });
    try obj.put(allocator, "artifact_kind", .{ .string = artifactKind(rel) });
    if (include_hashes) {
        const bytes = std.Io.Dir.cwd().readFileAlloc(a.io, abs_path, allocator, .limited(max_hash_bytes)) catch |err| switch (err) {
            error.StreamTooLong => {
                try obj.put(allocator, "sha256", .null);
                try obj.put(allocator, "hash_status", .{ .string = "skipped_size_limit" });
                try obj.put(allocator, "max_hash_bytes", .{ .integer = @intCast(max_hash_bytes) });
                return .{ .object = obj };
            },
            else => {
                try obj.put(allocator, "sha256", .null);
                try obj.put(allocator, "hash_status", .{ .string = @errorName(err) });
                return .{ .object = obj };
            },
        };
        defer allocator.free(bytes);
        const hash = try artifacts.sha256Hex(allocator, bytes);
        defer allocator.free(hash);
        try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes.len) });
        try obj.put(allocator, "sha256", .{ .string = hash });
        try obj.put(allocator, "hash_status", .{ .string = "ok" });
    } else {
        try obj.put(allocator, "sha256", .null);
        try obj.put(allocator, "hash_status", .{ .string = "not_requested" });
    }
    return .{ .object = obj };
}

fn artifactKind(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".svg")) return "svg";
    if (std.mem.endsWith(u8, path, ".json") or std.mem.endsWith(u8, path, ".jsonl")) return "json";
    if (std.mem.endsWith(u8, path, ".xml")) return "xml";
    if (std.mem.endsWith(u8, path, ".txt") or std.mem.endsWith(u8, path, ".log")) return "text";
    if (std.mem.endsWith(u8, path, ".tar.gz") or std.mem.endsWith(u8, path, ".zip")) return "release_archive";
    return "workspace_artifact";
}

fn parseModeArg(allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value) !result_shape.ResultShapeMode {
    _ = allocator;
    _ = tool_name;
    const raw = argString(args, "mode") orelse result_shape.ResultShapeMode.standard.name();
    return result_shape.parseMode(raw) orelse error.InvalidMode;
}

fn modeError(allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.InvalidMode => invalidArgumentResult(allocator, tool_name, "mode", result_shape.supportedModesText(), argString(args, "mode") orelse "", "Choose compact, standard, or deep."),
        else => error.OutOfMemory,
    };
}

fn artifactError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, path: []const u8, err: anyerror, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "artifact_registry",
        .code = "artifact_operation_failed",
        .category = "artifact",
        .resolution = resolution,
        .details = &.{.{ .key = "path", .value = .{ .string = path } }},
    }, err);
}

fn stringArrayValue(allocator: std.mem.Allocator, items: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (items) |item| try array.append(.{ .string = item });
    return .{ .array = array };
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

test "artifact kind classifies common generated outputs" {
    try std.testing.expectEqualStrings("svg", artifactKind("zig-out/profile.svg"));
    try std.testing.expectEqualStrings("json", artifactKind(".zigar-cache/report.json"));
    try std.testing.expectEqualStrings("release_archive", artifactKind("dist/assets/zigar.tar.gz"));
}
