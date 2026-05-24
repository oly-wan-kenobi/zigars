const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const result_contracts = @import("../../../app/result_contracts.zig");
const artifact_registry = @import("../../../app/usecases/artifacts/registry.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

pub fn zigarArtifactIndex(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode = parseModeArg(args) catch return modeError(allocator, "zigar_artifact_index", args, "Choose compact, standard, or deep.");
    const limit: usize = @intCast(@max(1, @min(argInt(args, "limit", 50), 500)));
    const include_hashes = argBool(args, "include_hashes", true);
    const root_arg = argString(args, "path");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const registry = artifact_registry.readRegistrySnapshot(scratch, context) catch |err| switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => return workspacePathError(allocator, context, "zigar_artifact_index", artifact_registry.default_registry_path, err),
        else => return artifactError(allocator, "zigar_artifact_index", "load_registry", artifact_registry.default_registry_path, err, "Confirm zigar can read .zigar-cache artifact registry metadata, then retry."),
    };
    const scan = artifact_registry.scanArtifacts(scratch, context, root_arg, limit, include_hashes) catch |err| switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => return workspacePathError(allocator, context, "zigar_artifact_index", root_arg orelse artifact_registry.default_registry_path, err),
        else => return artifactError(allocator, "zigar_artifact_index", "scan_artifacts", root_arg orelse artifact_registry.default_registry_path, err, "Confirm zigar can scan workspace artifact directories, then retry."),
    };

    var omitted = std.json.Array.init(scratch);
    if (mode == .compact and scan.limit_reached) {
        try omitted.append(try omissionValue(scratch, "additional_artifacts", "limit reached in compact artifact index", "increase limit or use mode=deep"));
    }
    if (!include_hashes) {
        try omitted.append(try omissionValue(scratch, "artifact_hashes", "include_hashes=false", "set include_hashes=true"));
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zigar_artifact_index" });
    try obj.put(scratch, "ok", .{ .bool = true });
    try attachMetadata(scratch, &obj, mode, omitted);
    try obj.put(scratch, "workspace", .{ .string = context.workspace.root });
    try obj.put(scratch, "registry_path", .{ .string = artifact_registry.default_registry_path });
    try obj.put(scratch, "registered_count", .{ .integer = @intCast(registry.entries.len) });
    try obj.put(scratch, "scanned_count", .{ .integer = @intCast(scan.artifacts.len) });
    try obj.put(scratch, "scan_roots", try scanRootsValue(scratch, root_arg));
    try obj.put(scratch, "registered_artifacts", try registryValue(scratch, registry));
    try obj.put(scratch, "scanned_artifacts", try scannedArtifactsValue(scratch, scan.artifacts));
    try obj.put(scratch, "evidence_source", .{ .string = "registry_jsonl_and_workspace_artifact_scan" });
    try obj.put(scratch, "confidence", .{ .string = "medium" });
    try obj.put(scratch, "limitations", .{ .string = "The registry only contains artifacts explicitly registered by zigar workflows; scan results are bounded by limit and hash-size constraints." });
    try obj.put(scratch, "resolution", .{ .string = "Use zigar_artifact_read for a specific artifact or zigar_artifact_prune to remove stale registry entries after previewing the preimage identity." });
    return mcp_result.structured(allocator, .{ .object = obj });
}

pub fn zigarArtifactRead(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode = parseModeArg(args) catch return modeError(allocator, "zigar_artifact_read", args, "Choose compact, standard, or deep.");
    const path = argString(args, "path") orelse return mcp_errors.missingArgument(allocator, "zigar_artifact_read", "path", "workspace-relative artifact path");
    const max_bytes: usize = @intCast(@max(1, @min(argInt(args, "max_bytes", artifact_registry.default_read_limit), 4 * 1024 * 1024)));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const artifact = artifact_registry.readArtifact(scratch, context, path, max_bytes) catch |err| switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => return workspacePathError(allocator, context, "zigar_artifact_read", path, err),
        else => return artifactError(allocator, "zigar_artifact_read", "read_artifact", path, err, "Confirm the artifact exists inside the workspace, or raise max_bytes for bounded text reads."),
    };
    var omitted = std.json.Array.init(scratch);
    if (mode == .compact) {
        try omitted.append(try omissionValue(scratch, "full_content_context", "compact mode returns the bounded text and identity only", "use mode=deep with a suitable max_bytes value"));
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zigar_artifact_read" });
    try obj.put(scratch, "ok", .{ .bool = true });
    try attachMetadata(scratch, &obj, mode, omitted);
    try obj.put(scratch, "path", .{ .string = artifact.path });
    try obj.put(scratch, "abs_path", .{ .string = artifact.abs_path });
    try obj.put(scratch, "bytes", .{ .integer = @intCast(artifact.bytes) });
    try obj.put(scratch, "max_bytes", .{ .integer = @intCast(artifact.max_bytes) });
    try obj.put(scratch, "sha256", .{ .string = artifact.sha256 });
    try obj.put(scratch, "content", .{ .string = artifact.content });
    try obj.put(scratch, "evidence_source", .{ .string = "workspace_file_read" });
    try obj.put(scratch, "confidence", .{ .string = "high" });
    try obj.put(scratch, "limitations", .{ .string = "Content is returned as bounded text; binary artifacts may not be human-readable." });
    try obj.put(scratch, "resolution", .{ .string = "Use the sha256 and path fields when citing this artifact as evidence." });
    return mcp_result.structured(allocator, .{ .object = obj });
}

pub fn zigarArtifactPrune(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode = parseModeArg(args) catch return modeError(allocator, "zigar_artifact_prune", args, "Choose compact, standard, or deep.");
    const apply = argBool(args, "apply", false);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const preimage = artifact_registry.preimageIdentity(scratch, context) catch |err| switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => return workspacePathError(allocator, context, "zigar_artifact_prune", artifact_registry.default_registry_path, err),
        else => return artifactError(allocator, "zigar_artifact_prune", "read_preimage", artifact_registry.default_registry_path, err, "Confirm zigar can inspect the artifact registry preimage before pruning."),
    };
    const registry = artifact_registry.readRegistrySnapshot(scratch, context) catch |err| switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => return workspacePathError(allocator, context, "zigar_artifact_prune", artifact_registry.default_registry_path, err),
        else => return artifactError(allocator, "zigar_artifact_prune", "load_registry", artifact_registry.default_registry_path, err, "Confirm zigar can read the artifact registry before pruning."),
    };
    const before_count = registry.entries.len;
    const pruned = artifact_registry.pruneStale(scratch, context, registry) catch |err| {
        return artifactError(allocator, "zigar_artifact_prune", "prune_registry", artifact_registry.default_registry_path, err, "Inspect registry entries and rerun after removing unreadable artifact paths.");
    };
    if (apply) {
        artifact_registry.persistRegistrySnapshot(scratch, context, pruned.entries) catch |err| switch (err) {
            error.PathOutsideWorkspace, error.EmptyPath => return workspacePathError(allocator, context, "zigar_artifact_prune", artifact_registry.default_registry_path, err),
            else => return artifactError(allocator, "zigar_artifact_prune", "write_registry", artifact_registry.default_registry_path, err, "Confirm zigar can write .zigar-cache/artifacts before applying prune."),
        };
    }

    var omitted = std.json.Array.init(scratch);
    if (!apply) {
        try omitted.append(try omissionValue(scratch, "registry_write", "apply=false preview only", "rerun with apply=true after confirming preimage_identity"));
    }
    if (mode == .compact) {
        try omitted.append(try omissionValue(scratch, "remaining_registry_entries", "compact mode returns counts only", "use mode=deep after pruning if entry details are needed"));
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(scratch, "kind", .{ .string = "zigar_artifact_prune" });
    try obj.put(scratch, "ok", .{ .bool = true });
    try attachMetadata(scratch, &obj, mode, omitted);
    try obj.put(scratch, "applied", .{ .bool = apply });
    try obj.put(scratch, "registry_path", .{ .string = artifact_registry.default_registry_path });
    try obj.put(scratch, "preimage_identity", try preimageValue(scratch, preimage));
    try obj.put(scratch, "before_count", .{ .integer = @intCast(before_count) });
    try obj.put(scratch, "after_count", .{ .integer = @intCast(pruned.entries.len) });
    try obj.put(scratch, "summary", try pruneSummaryValue(scratch, pruned.summary));
    try obj.put(scratch, "evidence_source", .{ .string = "artifact_registry_preimage_and_workspace_file_hashes" });
    try obj.put(scratch, "confidence", .{ .string = "high" });
    try obj.put(scratch, "limitations", .{ .string = "Prune removes stale registry records only; it does not delete artifact files." });
    try obj.put(scratch, "resolution", .{ .string = if (apply) "stale registry entries were removed" else "preview complete; rerun with apply=true to update the registry" });
    return mcp_result.structured(allocator, .{ .object = obj });
}

fn parseModeArg(args: ?std.json.Value) error{InvalidMode}!result_contracts.OutputMode {
    const raw = argString(args, "mode") orelse result_contracts.OutputMode.standard.name();
    return switch (result_contracts.parseOutputMode(raw)) {
        .ok => |mode| mode,
        .err => error.InvalidMode,
    };
}

fn modeError(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args: ?std.json.Value,
    resolution: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.invalidArgument(
        allocator,
        tool_name,
        "mode",
        result_contracts.supportedModesText(),
        argString(args, "mode") orelse "",
        resolution,
    );
}

fn workspacePathError(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    tool_name: []const u8,
    path: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.workspacePath(allocator, tool_name, path, context.workspace.root, err);
}

fn artifactError(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    operation: []const u8,
    path: []const u8,
    err: anyerror,
    resolution: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "artifact_registry",
        .code = "artifact_operation_failed",
        .category = "artifact",
        .resolution = resolution,
        .details = &.{.{ .key = "path", .value = .{ .string = path } }},
    }, err);
}

fn attachMetadata(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    mode: result_contracts.OutputMode,
    omitted: std.json.Array,
) !void {
    try obj.put(allocator, "mode", .{ .string = mode.name() });
    try obj.put(allocator, "result_shape", try modeMetadataValue(allocator, result_contracts.modeMetadata(mode)));
    try obj.put(allocator, "omitted_sections", .{ .array = omitted });
}

fn modeMetadataValue(allocator: std.mem.Allocator, metadata: result_contracts.ModeMetadata) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = metadata.schema_version });
    try obj.put(allocator, "mode", .{ .string = metadata.mode.name() });
    try obj.put(allocator, "description", .{ .string = metadata.description });
    try obj.put(allocator, "default_token_budget", .{ .integer = metadata.default_token_budget });
    try obj.put(allocator, "stable_machine_fields", try stringArrayValue(allocator, metadata.stable_machine_fields));
    try obj.put(allocator, "included_sections", try stringArrayValue(allocator, metadata.included_sections));
    try obj.put(allocator, "omitted_by_default", try stringArrayValue(allocator, metadata.omitted_by_default));
    try obj.put(allocator, "omission_contract", .{ .string = metadata.omission_contract });
    return .{ .object = obj };
}

fn omissionValue(allocator: std.mem.Allocator, section: []const u8, reason: []const u8, recovery: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "section", .{ .string = section });
    try obj.put(allocator, "reason", .{ .string = reason });
    try obj.put(allocator, "recovery", .{ .string = recovery });
    return .{ .object = obj };
}

fn scanRootsValue(allocator: std.mem.Allocator, root_arg: ?[]const u8) !std.json.Value {
    if (root_arg) |root| return stringArrayValue(allocator, &.{root});
    return stringArrayValue(allocator, artifact_registry.default_scan_roots[0..]);
}

fn registryValue(allocator: std.mem.Allocator, registry: artifact_registry.Registry) !std.json.Value {
    var entries = std.json.Array.init(allocator);
    for (registry.entries) |entry| try entries.append(try registryEntryValue(allocator, entry));
    return .{ .array = entries };
}

fn registryEntryValue(allocator: std.mem.Allocator, entry: artifact_registry.RegistryEntry) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "path", .{ .string = entry.path });
    try obj.put(allocator, "abs_path", .{ .string = entry.abs_path });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(entry.bytes) });
    try obj.put(allocator, "sha256", .{ .string = entry.sha256 });
    try obj.put(allocator, "indexed_at_unix_ms", .{ .integer = entry.indexed_at_unix_ms });
    try obj.put(allocator, "parser_confidence", .{ .string = entry.parser_confidence });
    try obj.put(allocator, "raw_reference", .{ .string = entry.raw_reference });
    try obj.put(allocator, "provenance", try provenanceValue(allocator, entry.provenance));
    return .{ .object = obj };
}

fn provenanceValue(allocator: std.mem.Allocator, provenance: artifact_registry.Provenance) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "producer", .{ .string = provenance.producer });
    try obj.put(allocator, "artifact_kind", .{ .string = provenance.artifact_kind });
    try obj.put(allocator, "backend_name", .{ .string = provenance.backend_name });
    try obj.put(allocator, "backend_version", .{ .string = provenance.backend_version });
    try obj.put(allocator, "target", .{ .string = provenance.target });
    try obj.put(allocator, "baseline_identity", .{ .string = provenance.baseline_identity });
    try obj.put(allocator, "notes", .{ .string = provenance.notes });
    try obj.put(allocator, "command_argv", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "toolchain", try toolchainValue(allocator, provenance.toolchain));
    return .{ .object = obj };
}

fn toolchainValue(allocator: std.mem.Allocator, toolchain: artifact_registry.Toolchain) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig_path", .{ .string = toolchain.zig_path });
    try obj.put(allocator, "zls_path", .{ .string = toolchain.zls_path });
    try obj.put(allocator, "zflame_path", .{ .string = toolchain.zflame_path });
    try obj.put(allocator, "diff_folded_path", .{ .string = toolchain.diff_folded_path });
    return .{ .object = obj };
}

fn scannedArtifactsValue(allocator: std.mem.Allocator, artifacts: []const artifact_registry.ScannedArtifact) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (artifacts) |artifact| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "path", .{ .string = artifact.path });
        try obj.put(allocator, "artifact_kind", .{ .string = artifact.artifact_kind });
        if (artifact.bytes) |bytes| try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes) });
        try obj.put(allocator, "sha256", if (artifact.sha256) |hash| .{ .string = hash } else .null);
        try obj.put(allocator, "hash_status", .{ .string = artifact.hash_status });
        if (artifact.max_hash_bytes) |max| try obj.put(allocator, "max_hash_bytes", .{ .integer = @intCast(max) });
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn preimageValue(allocator: std.mem.Allocator, preimage: artifact_registry.PreimageIdentity) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "exists", .{ .bool = preimage.exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(preimage.bytes) });
    try obj.put(allocator, "sha256", if (preimage.sha256) |hash| .{ .string = hash } else .null);
    return .{ .object = obj };
}

fn pruneSummaryValue(allocator: std.mem.Allocator, summary: artifact_registry.PruneSummary) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kept", .{ .integer = @intCast(summary.kept) });
    try obj.put(allocator, "missing", .{ .integer = @intCast(summary.missing) });
    try obj.put(allocator, "changed", .{ .integer = @intCast(summary.changed) });
    try obj.put(allocator, "pruned", .{ .integer = @intCast(summary.pruned) });
    return .{ .object = obj };
}

fn stringArrayValue(allocator: std.mem.Allocator, items: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (items) |item| try array.append(.{ .string = item });
    return .{ .array = array };
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

fn argBool(args: ?std.json.Value, key: []const u8, default: bool) bool {
    const value = args orelse return default;
    if (value != .object) return default;
    const field = value.object.get(key) orelse return default;
    return switch (field) {
        .bool => |actual| actual,
        else => default,
    };
}

fn argInt(args: ?std.json.Value, key: []const u8, default: i64) i64 {
    const value = args orelse return default;
    if (value != .object) return default;
    const field = value.object.get(key) orelse return default;
    return switch (field) {
        .integer => |actual| actual,
        else => default,
    };
}
