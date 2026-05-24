const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");

pub const default_registry_path = ".zigar-cache/artifacts/registry.jsonl";
pub const default_read_limit: usize = 64 * 1024;
pub const max_registry_bytes: usize = 16 * 1024 * 1024;
pub const max_hash_bytes: usize = 32 * 1024 * 1024;
pub const default_scan_roots = [_][]const u8{ ".zigar-cache", "zig-out", "coverage", "dist" };

pub const ArtifactError = ports.PortError || error{
    InvalidArtifactRegistryEntry,
};

pub const Toolchain = struct {
    zig_path: []const u8,
    zls_path: []const u8 = "",
    zflame_path: []const u8 = "",
    diff_folded_path: []const u8 = "",
};

pub const Provenance = struct {
    producer: []const u8,
    artifact_kind: []const u8,
    backend_name: []const u8 = "",
    backend_version: []const u8 = "",
    target: []const u8 = "",
    baseline_identity: []const u8 = "",
    notes: []const u8 = "",
    toolchain: Toolchain,
};

pub const RegistryEntry = struct {
    path: []const u8,
    abs_path: []const u8,
    bytes: usize,
    sha256: []const u8,
    indexed_at_unix_ms: i64 = 0,
    parser_confidence: []const u8 = "medium",
    raw_reference: []const u8 = "registry_jsonl",
    provenance: Provenance,
};

pub const Registry = struct {
    entries: []RegistryEntry = &.{},
};

pub const ScannedArtifact = struct {
    path: []const u8,
    artifact_kind: []const u8,
    bytes: ?usize = null,
    sha256: ?[]const u8 = null,
    hash_status: []const u8,
    max_hash_bytes: ?usize = null,
};

pub const ScanResult = struct {
    artifacts: []ScannedArtifact,
    limit_reached: bool,
};

pub const ReadArtifactResult = struct {
    path: []const u8,
    abs_path: []const u8,
    bytes: usize,
    max_bytes: usize,
    sha256: []const u8,
    content: []const u8,
};

pub const PreimageIdentity = struct {
    exists: bool,
    bytes: usize,
    sha256: ?[]const u8 = null,
};

pub const PruneSummary = struct {
    kept: usize = 0,
    missing: usize = 0,
    changed: usize = 0,
    pruned: usize = 0,
};

pub const PruneResult = struct {
    entries: []RegistryEntry,
    summary: PruneSummary,
};

pub fn readRegistrySnapshot(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
) ArtifactError!Registry {
    const read = context.workspace_store.read(allocator, .{
        .path = default_registry_path,
        .max_bytes = max_registry_bytes,
        .for_output = true,
        .provenance = "artifacts.registry.load",
    }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer read.deinit(allocator);
    return parseRegistryJsonl(allocator, read.bytes);
}

pub fn scanArtifacts(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    root_arg: ?[]const u8,
    limit: usize,
    include_hashes: bool,
) ports.PortError!ScanResult {
    const normalized_limit = @max(limit, 1);
    var paths: std.ArrayList([]const u8) = .empty;
    if (root_arg) |root| {
        const resolved = try context.workspace_store.resolve(allocator, .{
            .path = root,
            .for_output = false,
            .provenance = "artifacts.scan.resolve",
        });
        resolved.deinit(allocator);
        try collectArtifactPaths(allocator, context, &paths, root, normalized_limit);
    } else {
        for (default_scan_roots) |root| {
            if (paths.items.len >= normalized_limit) break;
            const resolved = context.workspace_store.resolve(allocator, .{
                .path = root,
                .for_output = false,
                .provenance = "artifacts.scan.resolve",
            }) catch continue;
            resolved.deinit(allocator);
            collectArtifactPaths(allocator, context, &paths, root, normalized_limit) catch continue;
        }
    }
    std.mem.sort([]const u8, paths.items, {}, stringLessThan);

    var scanned: std.ArrayList(ScannedArtifact) = .empty;
    for (paths.items) |path| {
        try scanned.append(allocator, try scannedArtifact(allocator, context, path, include_hashes));
    }
    return .{
        .artifacts = try scanned.toOwnedSlice(allocator),
        .limit_reached = paths.items.len >= normalized_limit,
    };
}

pub fn readArtifact(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    path: []const u8,
    max_bytes: usize,
) ports.PortError!ReadArtifactResult {
    const resolved = try context.workspace_store.resolve(allocator, .{
        .path = path,
        .for_output = false,
        .provenance = "artifacts.read.resolve",
    });
    const read = try context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = max_bytes,
        .for_output = false,
        .provenance = "artifacts.read.content",
    });
    const hash = try sha256Hex(allocator, read.bytes);
    return .{
        .path = path,
        .abs_path = resolved.path,
        .bytes = read.bytes.len,
        .max_bytes = max_bytes,
        .sha256 = hash,
        .content = read.bytes,
    };
}

pub fn preimageIdentity(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
) ports.PortError!PreimageIdentity {
    const read = context.workspace_store.read(allocator, .{
        .path = default_registry_path,
        .max_bytes = max_registry_bytes,
        .for_output = true,
        .provenance = "artifacts.prune.preimage",
    }) catch |err| switch (err) {
        error.FileNotFound => return .{ .exists = false, .bytes = 0, .sha256 = null },
        else => return err,
    };
    defer read.deinit(allocator);
    return .{
        .exists = true,
        .bytes = read.bytes.len,
        .sha256 = try sha256Hex(allocator, read.bytes),
    };
}

pub fn pruneStale(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    registry: Registry,
) ports.PortError!PruneResult {
    var kept: std.ArrayList(RegistryEntry) = .empty;
    var summary: PruneSummary = .{};
    for (registry.entries) |entry| {
        const read = context.workspace_store.read(allocator, .{
            .path = entry.path,
            .max_bytes = entry.bytes + 1,
            .for_output = false,
            .provenance = "artifacts.prune.verify",
        }) catch |err| switch (err) {
            error.FileNotFound => {
                summary.missing += 1;
                continue;
            },
            error.StreamTooLong => {
                summary.changed += 1;
                continue;
            },
            else => return err,
        };
        defer read.deinit(allocator);
        const hash = try sha256Hex(allocator, read.bytes);
        if (read.bytes.len != entry.bytes or !std.mem.eql(u8, hash, entry.sha256)) {
            summary.changed += 1;
            continue;
        }
        try kept.append(allocator, entry);
        summary.kept += 1;
    }
    summary.pruned = summary.missing + summary.changed;
    return .{
        .entries = try kept.toOwnedSlice(allocator),
        .summary = summary,
    };
}

pub fn persistRegistrySnapshot(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    entries: []const RegistryEntry,
) ArtifactError!void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (entries) |entry| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const value = try registryEntryValue(arena.allocator(), entry);
        std.json.Stringify.value(value, .{}, &out.writer) catch |err| return mapWriteError(err);
        out.writer.writeByte('\n') catch |err| return mapWriteError(err);
    }
    _ = try context.workspace_store.write(.{
        .path = default_registry_path,
        .bytes = out.written(),
        .create_parent_dirs = true,
        .replace_existing = true,
        .provenance = "artifacts.prune.write_registry",
    });
}

pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ports.PortError![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex) catch return error.OutOfMemory;
}

pub fn artifactKind(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".svg")) return "svg";
    if (std.mem.endsWith(u8, path, ".json") or std.mem.endsWith(u8, path, ".jsonl")) return "json";
    if (std.mem.endsWith(u8, path, ".xml")) return "xml";
    if (std.mem.endsWith(u8, path, ".txt") or std.mem.endsWith(u8, path, ".log")) return "text";
    if (std.mem.endsWith(u8, path, ".tar.gz") or std.mem.endsWith(u8, path, ".zip")) return "release_archive";
    return "workspace_artifact";
}

fn collectArtifactPaths(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    paths: *std.ArrayList([]const u8),
    root: []const u8,
    limit: usize,
) ports.PortError!void {
    if (paths.items.len >= limit) return;
    var scan = try context.workspace_store.scanDirectory(allocator, .{
        .path = root,
        .max_files = limit - paths.items.len,
        .for_output = false,
        .provenance = "artifacts.scan.walk",
    });
    defer scan.deinit(allocator);
    for (scan.entries) |entry| {
        if (paths.items.len >= limit) break;
        const path = try relativeEntryPath(allocator, root, entry.path);
        try paths.append(allocator, path);
    }
}

fn scannedArtifact(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    path: []const u8,
    include_hashes: bool,
) ports.PortError!ScannedArtifact {
    var result = ScannedArtifact{
        .path = path,
        .artifact_kind = artifactKind(path),
        .hash_status = "not_requested",
    };
    if (!include_hashes) return result;

    const read = context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = max_hash_bytes,
        .for_output = false,
        .provenance = "artifacts.scan.hash",
    }) catch |err| switch (err) {
        error.StreamTooLong => {
            result.hash_status = "skipped_size_limit";
            result.max_hash_bytes = max_hash_bytes;
            return result;
        },
        else => {
            result.hash_status = @errorName(err);
            return result;
        },
    };
    defer read.deinit(allocator);
    result.bytes = read.bytes.len;
    result.sha256 = try sha256Hex(allocator, read.bytes);
    result.hash_status = "ok";
    return result;
}

fn parseRegistryJsonl(allocator: std.mem.Allocator, bytes: []const u8) ArtifactError!Registry {
    var entries: std.ArrayList(RegistryEntry) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return error.InvalidArtifactRegistryEntry;
        defer parsed.deinit();
        try entries.append(allocator, try entryFromValue(allocator, parsed.value));
    }
    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

fn entryFromValue(allocator: std.mem.Allocator, value: std.json.Value) ArtifactError!RegistryEntry {
    if (value != .object) return error.InvalidArtifactRegistryEntry;
    const obj = value.object;
    const provenance = objectValue(obj.get("provenance")) orelse return error.InvalidArtifactRegistryEntry;
    const toolchain = objectValue(provenance.get("toolchain")) orelse return error.InvalidArtifactRegistryEntry;
    return .{
        .path = try dupStringField(allocator, obj, "path"),
        .abs_path = try dupStringField(allocator, obj, "abs_path"),
        .bytes = @intCast(integerField(obj, "bytes") orelse return error.InvalidArtifactRegistryEntry),
        .sha256 = try dupStringField(allocator, obj, "sha256"),
        .indexed_at_unix_ms = integerField(obj, "indexed_at_unix_ms") orelse 0,
        .parser_confidence = try dupOptionalStringFieldDefault(allocator, obj, "parser_confidence", "medium"),
        .raw_reference = try dupOptionalStringFieldDefault(allocator, obj, "raw_reference", "registry_jsonl"),
        .provenance = .{
            .producer = try dupStringField(allocator, provenance, "producer"),
            .artifact_kind = try dupStringField(allocator, provenance, "artifact_kind"),
            .backend_name = try dupOptionalStringField(allocator, provenance, "backend_name"),
            .backend_version = try dupOptionalStringField(allocator, provenance, "backend_version"),
            .target = try dupOptionalStringField(allocator, provenance, "target"),
            .baseline_identity = try dupOptionalStringField(allocator, provenance, "baseline_identity"),
            .notes = try dupOptionalStringField(allocator, provenance, "notes"),
            .toolchain = .{
                .zig_path = try dupOptionalStringField(allocator, toolchain, "zig_path"),
                .zls_path = try dupOptionalStringField(allocator, toolchain, "zls_path"),
                .zflame_path = try dupOptionalStringField(allocator, toolchain, "zflame_path"),
                .diff_folded_path = try dupOptionalStringField(allocator, toolchain, "diff_folded_path"),
            },
        },
    };
}

fn registryEntryValue(allocator: std.mem.Allocator, entry: RegistryEntry) !std.json.Value {
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

fn provenanceValue(allocator: std.mem.Allocator, provenance: Provenance) !std.json.Value {
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

fn toolchainValue(allocator: std.mem.Allocator, toolchain: Toolchain) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig_path", .{ .string = toolchain.zig_path });
    try obj.put(allocator, "zls_path", .{ .string = toolchain.zls_path });
    try obj.put(allocator, "zflame_path", .{ .string = toolchain.zflame_path });
    try obj.put(allocator, "diff_folded_path", .{ .string = toolchain.diff_folded_path });
    return .{ .object = obj };
}

fn objectValue(value: ?std.json.Value) ?std.json.ObjectMap {
    const actual = value orelse return null;
    if (actual != .object) return null;
    return actual.object;
}

fn dupStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ArtifactError![]u8 {
    const value = obj.get(key) orelse return error.InvalidArtifactRegistryEntry;
    if (value != .string) return error.InvalidArtifactRegistryEntry;
    return allocator.dupe(u8, value.string) catch return error.OutOfMemory;
}

fn dupOptionalStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ArtifactError![]u8 {
    return dupOptionalStringFieldDefault(allocator, obj, key, "");
}

fn dupOptionalStringFieldDefault(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) ArtifactError![]u8 {
    const value = obj.get(key) orelse return allocator.dupe(u8, default) catch return error.OutOfMemory;
    if (value == .null) return allocator.dupe(u8, default) catch return error.OutOfMemory;
    if (value != .string) return error.InvalidArtifactRegistryEntry;
    return allocator.dupe(u8, value.string) catch return error.OutOfMemory;
}

fn integerField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn relativeEntryPath(allocator: std.mem.Allocator, root: []const u8, entry_path: []const u8) ports.PortError![]const u8 {
    if (root.len == 0 or std.mem.eql(u8, root, ".")) {
        return allocator.dupe(u8, entry_path) catch return error.OutOfMemory;
    }
    return std.fs.path.join(allocator, &.{ root, entry_path }) catch return error.OutOfMemory;
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn mapWriteError(err: anyerror) ArtifactError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unavailable,
    };
}

test "artifact kind classifies common generated outputs" {
    try std.testing.expectEqualStrings("svg", artifactKind("zig-out/profile.svg"));
    try std.testing.expectEqualStrings("json", artifactKind(".zigar-cache/report.json"));
    try std.testing.expectEqualStrings("release_archive", artifactKind("dist/assets/zigar.tar.gz"));
}
