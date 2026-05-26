//! Artifact-registry MCP adapters for listing, reading, and preview-pruning
//! workspace artifacts with result-shape metadata.
const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const result_contracts = @import("../../../app/result_contracts.zig");
const artifact_registry = @import("../../../app/usecases/artifacts/registry.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

/// Lists registered and scanned artifacts; reads registry metadata and workspace files.
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

/// Reads bounded artifact text and identity fields from a workspace-local path.
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

/// Previews or applies stale artifact-registry pruning; never deletes artifact files.
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

/// Parses compact/standard/deep mode, defaulting to the standard result shape.
fn parseModeArg(args: ?std.json.Value) error{InvalidMode}!result_contracts.OutputMode {
    const raw = argString(args, "mode") orelse result_contracts.OutputMode.standard.name();
    return switch (result_contracts.parseOutputMode(raw)) {
        .ok => |mode| mode,
        .err => error.InvalidMode,
    };
}

/// Maps mode error failures to structured MCP errors.
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

/// Maps workspace path error failures to structured MCP errors.
fn workspacePathError(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    tool_name: []const u8,
    path: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.workspacePath(allocator, tool_name, path, context.workspace.root, err);
}

/// Maps artifact error failures to structured MCP errors.
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

/// Attaches artifact metadata to a structured tool result object.
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

/// Returns an allocator-owned JSON value for mode metadata.
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

/// Returns an allocator-owned JSON value for omission.
fn omissionValue(allocator: std.mem.Allocator, section: []const u8, reason: []const u8, recovery: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "section", .{ .string = section });
    try obj.put(allocator, "reason", .{ .string = reason });
    try obj.put(allocator, "recovery", .{ .string = recovery });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for scan roots.
fn scanRootsValue(allocator: std.mem.Allocator, root_arg: ?[]const u8) !std.json.Value {
    if (root_arg) |root| return stringArrayValue(allocator, &.{root});
    return stringArrayValue(allocator, artifact_registry.default_scan_roots[0..]);
}

/// Returns an allocator-owned JSON value for registry.
fn registryValue(allocator: std.mem.Allocator, registry: artifact_registry.Registry) !std.json.Value {
    var entries = std.json.Array.init(allocator);
    for (registry.entries) |entry| try entries.append(try registryEntryValue(allocator, entry));
    return .{ .array = entries };
}

/// Returns an allocator-owned JSON value for registry entry.
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

/// Returns an allocator-owned JSON value for provenance.
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

/// Returns an allocator-owned JSON value for toolchain.
fn toolchainValue(allocator: std.mem.Allocator, toolchain: artifact_registry.Toolchain) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig_path", .{ .string = toolchain.zig_path });
    try obj.put(allocator, "zls_path", .{ .string = toolchain.zls_path });
    try obj.put(allocator, "zflame_path", .{ .string = toolchain.zflame_path });
    try obj.put(allocator, "diff_folded_path", .{ .string = toolchain.diff_folded_path });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for scanned artifacts.
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

/// Returns an allocator-owned JSON value for preimage.
fn preimageValue(allocator: std.mem.Allocator, preimage: artifact_registry.PreimageIdentity) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "exists", .{ .bool = preimage.exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(preimage.bytes) });
    try obj.put(allocator, "sha256", if (preimage.sha256) |hash| .{ .string = hash } else .null);
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for prune summary.
fn pruneSummaryValue(allocator: std.mem.Allocator, summary: artifact_registry.PruneSummary) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kept", .{ .integer = @intCast(summary.kept) });
    try obj.put(allocator, "missing", .{ .integer = @intCast(summary.missing) });
    try obj.put(allocator, "changed", .{ .integer = @intCast(summary.changed) });
    try obj.put(allocator, "pruned", .{ .integer = @intCast(summary.pruned) });
    return .{ .object = obj };
}

/// Copies a string slice into an allocator-owned JSON array.
fn stringArrayValue(allocator: std.mem.Allocator, items: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (items) |item| try array.append(.{ .string = item });
    return .{ .array = array };
}

/// Reads a string argument when it is present with the expected type.
fn argString(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    const value = args orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

/// Reads a bool argument when it is present with the expected type.
fn argBool(args: ?std.json.Value, key: []const u8, default: bool) bool {
    const value = args orelse return default;
    if (value != .object) return default;
    const field = value.object.get(key) orelse return default;
    return switch (field) {
        .bool => |actual| actual,
        else => default,
    };
}

/// Reads an int argument when it is present with the expected type.
fn argInt(args: ?std.json.Value, key: []const u8, default: i64) i64 {
    const value = args orelse return default;
    if (value != .object) return default;
    const field = value.object.get(key) orelse return default;
    return switch (field) {
        .integer => |actual| actual,
        else => default,
    };
}

const fakes = @import("../../../testing/fakes/root.zig");

/// Creates artifact adapter context from the ports required by the adapter.
fn artifactAdapterContext(workspace: *fakes.FakeWorkspaceStore) app_context.ArtifactContext {
    return .{
        .workspace = .{ .root = "/workspace" },
        .workspace_store = workspace.port(),
    };
}

/// Parses artifact args from MCP JSON arguments.
fn artifactArgs(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, text, .{});
}

/// Formats one registry fixture line with path and byte metadata.
fn registryLine(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) ![]const u8 {
    const hash = try artifact_registry.sha256Hex(allocator, bytes);
    return std.fmt.allocPrint(allocator,
        \\{{"path":"{s}","abs_path":"/workspace/{s}","bytes":{d},"sha256":"{s}","indexed_at_unix_ms":1,"provenance":{{"producer":"fixture","artifact_kind":"{s}","toolchain":{{"zig_path":"zig"}}}}}}
        \\
    , .{ path, path, bytes.len, hash, artifact_registry.artifactKind(path) });
}

/// Creates a registry entry fixture for artifact adapter tests.
fn registryEntryFixture(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !artifact_registry.RegistryEntry {
    return .{
        .path = path,
        .abs_path = try std.fmt.allocPrint(allocator, "/workspace/{s}", .{path}),
        .bytes = bytes.len,
        .sha256 = try artifact_registry.sha256Hex(allocator, bytes),
        .indexed_at_unix_ms = 1,
        .parser_confidence = "medium",
        .raw_reference = "registry_jsonl",
        .provenance = .{
            .producer = "fixture",
            .artifact_kind = artifact_registry.artifactKind(path),
            .toolchain = .{ .zig_path = "zig" },
        },
    };
}

/// Serializes a registry entry fixture to JSON text.
fn serializedRegistryEntry(allocator: std.mem.Allocator, entry: artifact_registry.RegistryEntry) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const value = try registryEntryValue(allocator, entry);
    try std.json.Stringify.value(value, .{}, &out.writer);
    try out.writer.writeByte('\n');
    return try out.toOwnedSlice();
}

test "artifact MCP adapters index read and prune artifact registry data" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    const context = artifactAdapterContext(&workspace);

    const kept_line = try registryLine(allocator, "zig-out/kept.txt", "kept");
    const missing_line = try registryLine(allocator, "zig-out/missing.txt", "missing");
    const changed_line = try registryLine(allocator, "zig-out/changed.txt", "changed");
    const registry_bytes = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ kept_line, missing_line, changed_line });

    var index_args = try artifactArgs(allocator,
        \\{"mode":"deep","path":"artifacts","limit":3,"include_hashes":true}
    );
    defer index_args.deinit();
    try workspace.expectRead(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.registry.load" }, registry_bytes);
    try workspace.expectResolve(.{ .path = "artifacts", .for_output = false, .provenance = "artifacts.scan.resolve" }, "/workspace/artifacts");
    try workspace.expectScanDirectory(.{ .path = "artifacts", .max_files = 3, .for_output = false, .provenance = "artifacts.scan.walk" }, &.{ "report.json", "big.log" });
    try workspace.expectReadError(.{ .path = "artifacts/big.log", .max_bytes = artifact_registry.max_hash_bytes, .for_output = false, .provenance = "artifacts.scan.hash" }, error.StreamTooLong);
    try workspace.expectRead(.{ .path = "artifacts/report.json", .max_bytes = artifact_registry.max_hash_bytes, .for_output = false, .provenance = "artifacts.scan.hash" }, "{\"ok\":true}");
    const index = try zigarArtifactIndex(allocator, context, index_args.value);
    try std.testing.expect(!index.is_error);
    try std.testing.expectEqual(@as(i64, 3), index.structuredContent.?.object.get("registered_count").?.integer);
    try std.testing.expectEqual(@as(i64, 2), index.structuredContent.?.object.get("scanned_count").?.integer);

    var compact_index_args = try artifactArgs(allocator,
        \\{"mode":"compact","path":"artifacts","limit":2,"include_hashes":false}
    );
    defer compact_index_args.deinit();
    try workspace.expectReadError(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.registry.load" }, error.FileNotFound);
    try workspace.expectResolve(.{ .path = "artifacts", .for_output = false, .provenance = "artifacts.scan.resolve" }, "/workspace/artifacts");
    try workspace.expectScanDirectory(.{ .path = "artifacts", .max_files = 2, .for_output = false, .provenance = "artifacts.scan.walk" }, &.{ "one.txt", "two.svg" });
    const compact_index = try zigarArtifactIndex(allocator, context, compact_index_args.value);
    try std.testing.expectEqual(@as(usize, 2), compact_index.structuredContent.?.object.get("omitted_sections").?.array.items.len);

    var read_args = try artifactArgs(allocator,
        \\{"mode":"compact","path":"zig-out/kept.txt","max_bytes":1024}
    );
    defer read_args.deinit();
    try workspace.expectResolve(.{ .path = "zig-out/kept.txt", .for_output = false, .provenance = "artifacts.read.resolve" }, "/workspace/zig-out/kept.txt");
    try workspace.expectRead(.{ .path = "zig-out/kept.txt", .max_bytes = 1024, .for_output = false, .provenance = "artifacts.read.content" }, "kept");
    const read = try zigarArtifactRead(allocator, context, read_args.value);
    try std.testing.expectEqualStrings("zig-out/kept.txt", read.structuredContent.?.object.get("path").?.string);
    try std.testing.expectEqual(@as(usize, 1), read.structuredContent.?.object.get("omitted_sections").?.array.items.len);

    var prune_preview_args = try artifactArgs(allocator,
        \\{"mode":"compact","apply":false}
    );
    defer prune_preview_args.deinit();
    try workspace.expectRead(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.prune.preimage" }, registry_bytes);
    try workspace.expectRead(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.registry.load" }, registry_bytes);
    try workspace.expectRead(.{ .path = "zig-out/kept.txt", .max_bytes = 5, .for_output = false, .provenance = "artifacts.prune.verify" }, "kept");
    try workspace.expectReadError(.{ .path = "zig-out/missing.txt", .max_bytes = 8, .for_output = false, .provenance = "artifacts.prune.verify" }, error.FileNotFound);
    try workspace.expectRead(.{ .path = "zig-out/changed.txt", .max_bytes = 8, .for_output = false, .provenance = "artifacts.prune.verify" }, "new");
    const preview = try zigarArtifactPrune(allocator, context, prune_preview_args.value);
    try std.testing.expect(!preview.structuredContent.?.object.get("applied").?.bool);
    try std.testing.expectEqual(@as(i64, 2), preview.structuredContent.?.object.get("summary").?.object.get("pruned").?.integer);

    var prune_apply_args = try artifactArgs(allocator,
        \\{"mode":"standard","apply":true}
    );
    defer prune_apply_args.deinit();
    const kept_only = try registryLine(allocator, "zig-out/kept.txt", "kept");
    const kept_entry = try registryEntryFixture(allocator, "zig-out/kept.txt", "kept");
    const expected_registry_write = try serializedRegistryEntry(allocator, kept_entry);
    try workspace.expectRead(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.prune.preimage" }, kept_only);
    try workspace.expectRead(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.registry.load" }, kept_only);
    try workspace.expectRead(.{ .path = "zig-out/kept.txt", .max_bytes = 5, .for_output = false, .provenance = "artifacts.prune.verify" }, "kept");
    try workspace.expectWrite(.{
        .path = artifact_registry.default_registry_path,
        .bytes = expected_registry_write,
        .create_parent_dirs = true,
        .replace_existing = true,
        .provenance = "artifacts.prune.write_registry",
    }, .{ .bytes_written = expected_registry_write.len, .replaced_existing = true });
    const applied = try zigarArtifactPrune(allocator, context, prune_apply_args.value);
    try std.testing.expect(applied.structuredContent.?.object.get("applied").?.bool);

    try workspace.verify();
}

test "artifact MCP adapters surface argument workspace and artifact errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    const context = artifactAdapterContext(&workspace);

    var invalid_mode_args = try artifactArgs(allocator,
        \\{"mode":"wide"}
    );
    defer invalid_mode_args.deinit();
    const invalid_mode = try zigarArtifactIndex(allocator, context, invalid_mode_args.value);
    try std.testing.expect(invalid_mode.is_error);
    try std.testing.expectEqualStrings("invalid_argument", invalid_mode.structuredContent.?.object.get("code").?.string);

    const missing_path = try zigarArtifactRead(allocator, context, null);
    try std.testing.expect(missing_path.is_error);
    try std.testing.expectEqualStrings("missing_required_argument", missing_path.structuredContent.?.object.get("code").?.string);

    var outside_read_args = try artifactArgs(allocator,
        \\{"path":"../secret.txt"}
    );
    defer outside_read_args.deinit();
    try workspace.expectResolveError(.{ .path = "../secret.txt", .for_output = false, .provenance = "artifacts.read.resolve" }, error.PathOutsideWorkspace);
    const outside_read = try zigarArtifactRead(allocator, context, outside_read_args.value);
    try std.testing.expect(outside_read.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", outside_read.structuredContent.?.object.get("kind").?.string);

    var missing_artifact_args = try artifactArgs(allocator,
        \\{"path":"zig-out/missing.txt"}
    );
    defer missing_artifact_args.deinit();
    try workspace.expectResolve(.{ .path = "zig-out/missing.txt", .for_output = false, .provenance = "artifacts.read.resolve" }, "/workspace/zig-out/missing.txt");
    try workspace.expectReadError(.{ .path = "zig-out/missing.txt", .max_bytes = artifact_registry.default_read_limit, .for_output = false, .provenance = "artifacts.read.content" }, error.FileNotFound);
    const missing_artifact = try zigarArtifactRead(allocator, context, missing_artifact_args.value);
    try std.testing.expect(missing_artifact.is_error);
    try std.testing.expectEqualStrings("artifact_operation_failed", missing_artifact.structuredContent.?.object.get("code").?.string);

    try workspace.expectReadError(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.registry.load" }, error.AccessDenied);
    const denied_index = try zigarArtifactIndex(allocator, context, null);
    try std.testing.expect(denied_index.is_error);
    try std.testing.expectEqualStrings("artifact_operation_failed", denied_index.structuredContent.?.object.get("code").?.string);

    try workspace.expectReadError(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.registry.load" }, error.PathOutsideWorkspace);
    const outside_index_registry = try zigarArtifactIndex(allocator, context, null);
    try std.testing.expect(outside_index_registry.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", outside_index_registry.structuredContent.?.object.get("kind").?.string);

    var outside_scan_args = try artifactArgs(allocator,
        \\{"path":"../artifacts"}
    );
    defer outside_scan_args.deinit();
    try workspace.expectReadError(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.registry.load" }, error.FileNotFound);
    try workspace.expectResolveError(.{ .path = "../artifacts", .for_output = false, .provenance = "artifacts.scan.resolve" }, error.PathOutsideWorkspace);
    const outside_index_scan = try zigarArtifactIndex(allocator, context, outside_scan_args.value);
    try std.testing.expect(outside_index_scan.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", outside_index_scan.structuredContent.?.object.get("kind").?.string);

    try workspace.expectReadError(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.prune.preimage" }, error.EmptyPath);
    const bad_prune = try zigarArtifactPrune(allocator, context, null);
    try std.testing.expect(bad_prune.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", bad_prune.structuredContent.?.object.get("kind").?.string);

    try workspace.expectReadError(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.prune.preimage" }, error.AccessDenied);
    const denied_prune_preimage = try zigarArtifactPrune(allocator, context, null);
    try std.testing.expect(denied_prune_preimage.is_error);
    try std.testing.expectEqualStrings("artifact_operation_failed", denied_prune_preimage.structuredContent.?.object.get("code").?.string);

    try workspace.expectRead(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.prune.preimage" }, "");
    try workspace.expectReadError(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.registry.load" }, error.EmptyPath);
    const bad_prune_registry = try zigarArtifactPrune(allocator, context, null);
    try std.testing.expect(bad_prune_registry.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", bad_prune_registry.structuredContent.?.object.get("kind").?.string);

    var apply_args = try artifactArgs(allocator,
        \\{"apply":true}
    );
    defer apply_args.deinit();
    try workspace.expectRead(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.prune.preimage" }, "");
    try workspace.expectRead(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.registry.load" }, "");
    try workspace.expectWriteError(.{
        .path = artifact_registry.default_registry_path,
        .bytes = "",
        .create_parent_dirs = true,
        .replace_existing = true,
        .provenance = "artifacts.prune.write_registry",
    }, error.PathOutsideWorkspace);
    const bad_prune_write = try zigarArtifactPrune(allocator, context, apply_args.value);
    try std.testing.expect(bad_prune_write.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", bad_prune_write.structuredContent.?.object.get("kind").?.string);

    try workspace.verify();
}

/// Exercises artifact adapter helper values coverage with test fixture storage.
fn exerciseArtifactAdapterHelperValues(allocator: std.mem.Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var omitted = std.json.Array.init(arena);
    try omitted.append(try omissionValue(arena, "section", "reason", "recovery"));
    var obj = std.json.ObjectMap.empty;
    try attachMetadata(arena, &obj, .deep, omitted);
    _ = try modeMetadataValue(arena, result_contracts.modeMetadata(.compact));

    const entry = try registryEntryFixture(arena, "zig-out/helper.json", "{}");
    _ = try registryEntryValue(arena, entry);
    _ = try provenanceValue(arena, entry.provenance);
    _ = try toolchainValue(arena, entry.provenance.toolchain);

    const scanned = [_]artifact_registry.ScannedArtifact{.{
        .path = "zig-out/helper.json",
        .artifact_kind = "json",
        .bytes = 2,
        .sha256 = "hash",
        .hash_status = "ok",
        .max_hash_bytes = artifact_registry.max_hash_bytes,
    }};
    _ = try scannedArtifactsValue(arena, scanned[0..]);
    _ = try preimageValue(arena, .{ .exists = true, .bytes = 2, .sha256 = "hash" });
    _ = try pruneSummaryValue(arena, .{ .kept = 1, .missing = 1, .changed = 1, .pruned = 2 });
    _ = try stringArrayValue(arena, &.{ "one", "two" });
}

test "artifact MCP adapter helper values clean up during allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseArtifactAdapterHelperValues, .{});
    try exerciseArtifactAdapterFixedBufferFailures();
}

/// Exercises artifact adapter fixed buffer failures coverage with test fixture storage.
fn exerciseArtifactAdapterFixedBufferFailures() !void {
    const entry = artifact_registry.RegistryEntry{
        .path = "zig-out/helper.json",
        .abs_path = "/workspace/zig-out/helper.json",
        .bytes = 2,
        .sha256 = "hash",
        .indexed_at_unix_ms = 1,
        .parser_confidence = "medium",
        .raw_reference = "registry_jsonl",
        .provenance = .{
            .producer = "fixture",
            .artifact_kind = "json",
            .toolchain = .{ .zig_path = "zig" },
        },
    };
    var storage: [2048]u8 = undefined;
    for (0..storage.len) |cap| {
        var fba = std.heap.FixedBufferAllocator.init(storage[0..cap]);
        _ = registryEntryValue(fba.allocator(), entry) catch |err| switch (err) {
            error.OutOfMemory => continue,
        };
    }
    for (0..storage.len) |cap| {
        var fba = std.heap.FixedBufferAllocator.init(storage[0..cap]);
        _ = provenanceValue(fba.allocator(), entry.provenance) catch |err| switch (err) {
            error.OutOfMemory => continue,
        };
    }
    for (0..storage.len) |cap| {
        var fba = std.heap.FixedBufferAllocator.init(storage[0..cap]);
        _ = toolchainValue(fba.allocator(), entry.provenance.toolchain) catch |err| switch (err) {
            error.OutOfMemory => continue,
        };
    }
    for (0..storage.len) |cap| {
        var fba = std.heap.FixedBufferAllocator.init(storage[0..cap]);
        _ = preimageValue(fba.allocator(), .{ .exists = true, .bytes = 2, .sha256 = "hash" }) catch |err| switch (err) {
            error.OutOfMemory => continue,
        };
    }
    for (0..storage.len) |cap| {
        var fba = std.heap.FixedBufferAllocator.init(storage[0..cap]);
        _ = pruneSummaryValue(fba.allocator(), .{ .kept = 1, .missing = 1, .changed = 1, .pruned = 2 }) catch |err| switch (err) {
            error.OutOfMemory => continue,
        };
    }
}
