//! Artifact registry workflows: scan workspace outputs, hash them, persist a
//! JSONL provenance registry, and prune entries that no longer match on disk.
//! All filesystem access goes through the workspace store port, so every path
//! resolves under the sandbox. Returned slices and the parsed `Registry` are
//! owned by the caller-supplied allocator; most callers pass an arena and free
//! the whole batch at once rather than freeing fields individually.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");

/// Default registry path used when the caller omits an explicit value.
pub const default_registry_path = ".zigars-cache/artifacts/registry.jsonl";
/// Default read limit used when the caller omits an explicit value.
pub const default_read_limit: usize = 64 * 1024;
/// Maximum registry bytes accepted by this workflow module.
pub const max_registry_bytes: usize = 16 * 1024 * 1024;
/// Maximum hash bytes accepted by this workflow module.
pub const max_hash_bytes: usize = 32 * 1024 * 1024;
/// Default scan roots used when the caller omits an explicit value.
pub const default_scan_roots = [_][]const u8{ ".zigars-cache", "zig-out", "coverage", "dist" };

/// Error set returned by artifact workflow failures.
pub const ArtifactError = ports.PortError || error{
    InvalidArtifactRegistryEntry,
};

/// Carries toolchain data across use case and port boundaries.
/// All path fields default to empty string when the backend was not configured.
pub const Toolchain = struct {
    zig_path: []const u8,
    zls_path: []const u8 = "",
    zflame_path: []const u8 = "",
    diff_folded_path: []const u8 = "",
};

/// Carries provenance data across use case and port boundaries.
/// `producer` and `artifact_kind` are required; all other fields default to "".
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

/// Carries registry entry data across use case and port boundaries.
/// `path` is workspace-relative; `abs_path` is the resolved canonical path.
/// `bytes` and `sha256` record the file identity at index time.
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

/// Carries registry data across use case and port boundaries.
pub const Registry = struct {
    entries: []RegistryEntry = &.{},
};

/// Carries scanned artifact data across use case and port boundaries.
/// `bytes` and `sha256` are null when hashing was not requested or failed.
/// `hash_status` is always set: "not_requested", "ok", "skipped_size_limit",
/// or the @errorName of the first read failure.
pub const ScannedArtifact = struct {
    path: []const u8,
    artifact_kind: []const u8,
    bytes: ?usize = null,
    sha256: ?[]const u8 = null,
    hash_status: []const u8,
    max_hash_bytes: ?usize = null,
};

/// Carries scan result data across use case and port boundaries.
pub const ScanResult = struct {
    artifacts: []ScannedArtifact,
    limit_reached: bool,
};

/// Carries read artifact result data across use case and port boundaries.
pub const ReadArtifactResult = struct {
    path: []const u8,
    abs_path: []const u8,
    bytes: usize,
    max_bytes: usize,
    sha256: []const u8,
    content: []const u8,
};

/// Carries preimage identity data across use case and port boundaries.
pub const PreimageIdentity = struct {
    exists: bool,
    bytes: usize,
    sha256: ?[]const u8 = null,
};

/// Carries prune summary data across use case and port boundaries.
/// `pruned` is always `missing + changed` — a derived total, not a separate
/// counter. Callers that only need the net removal count may use `pruned` alone.
pub const PruneSummary = struct {
    kept: usize = 0,
    missing: usize = 0,
    changed: usize = 0,
    pruned: usize = 0,
};

/// Carries prune result data across use case and port boundaries.
/// `entries` is the kept subset and is owned by the caller's allocator;
/// strings within each kept entry borrow from the input registry.
pub const PruneResult = struct {
    entries: []RegistryEntry,
    summary: PruneSummary,
};

/// Loads and parses the persisted JSONL registry from the workspace cache.
/// Returns an empty registry (not an error) when the file does not exist yet.
/// Entries are duplicated into `allocator`; malformed lines fail the whole load.
pub fn readRegistrySnapshot(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
) ArtifactError!Registry {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Walks workspace artifact roots and returns up to `limit` scanned entries,
/// sorted by path for deterministic output. With `root_arg` null the default
/// roots are scanned best-effort: a root that fails to resolve or walk is
/// skipped rather than aborting the scan. With an explicit `root_arg` a resolve
/// failure propagates. `include_hashes` opts into reading and SHA-256 hashing
/// each file; per-file read failures are recorded in `hash_status`, not raised.
/// The returned slice and its strings are owned by `allocator`.
pub fn scanArtifacts(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    root_arg: ?[]const u8,
    limit: usize,
    include_hashes: bool,
) ports.PortError!ScanResult {
    // Always scan at least one entry so a caller-supplied limit of 0 still
    // makes progress and limit_reached stays meaningful.
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

/// Reads one workspace artifact and reports its byte length and SHA-256 hex.
/// `path` resolves under the sandbox; `max_bytes` caps the read (StreamTooLong
/// propagates past it). The returned `content` aliases the read buffer and
/// `abs_path` aliases the resolved path; both, plus `sha256`, are owned by
/// `allocator` and intentionally outlive this call (no internal deinit).
pub fn readArtifact(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    path: []const u8,
    max_bytes: usize,
) ports.PortError!ReadArtifactResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Captures the on-disk identity (existence, size, SHA-256) of the registry
/// file before a prune rewrite, so the change can be reported deterministically.
/// A missing file yields `.exists = false` rather than an error. The `sha256`
/// field, when present, is owned by `allocator`.
pub fn preimageIdentity(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
) ports.PortError!PreimageIdentity {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Re-verifies each registry entry against the workspace and keeps only those
/// whose file still exists with the recorded byte length and SHA-256. Missing
/// files count as `missing`; size or hash drift counts as `changed`; `pruned`
/// is their sum. The returned entries are shallow copies that borrow strings
/// from the input `registry`, so the caller must keep `registry` alive for the
/// lifetime of the result; the kept slice itself is owned by `allocator`.
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
            // Read one byte past the recorded size: a file that has grown
            // trips StreamTooLong and is classified as changed without hashing.
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

/// Rewrites the registry file as one JSON object per line (JSONL), replacing
/// the existing file and creating parent directories as needed. Each entry is
/// serialized through a per-entry arena so transient JSON buffers are freed
/// immediately. This is the only writer in this module; callers gate it behind
/// the surrounding tool's apply policy.
pub fn persistRegistrySnapshot(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    entries: []const RegistryEntry,
) ArtifactError!void {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Computes a lowercase SHA-256 hex digest in allocator-owned storage.
pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ports.PortError![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex) catch return error.OutOfMemory;
}

/// Classifies an artifact by filename suffix into a coarse kind label. Returns
/// a static string; the fallback for unrecognized suffixes is
/// "workspace_artifact".
pub fn artifactKind(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".svg")) return "svg";
    if (std.mem.endsWith(u8, path, ".json") or std.mem.endsWith(u8, path, ".jsonl")) return "json";
    if (std.mem.endsWith(u8, path, ".xml")) return "xml";
    if (std.mem.endsWith(u8, path, ".txt") or std.mem.endsWith(u8, path, ".log")) return "text";
    if (std.mem.endsWith(u8, path, ".tar.gz") or std.mem.endsWith(u8, path, ".zip")) return "release_archive";
    return "workspace_artifact";
}

/// Walks `root` under the workspace sandbox and appends up to `limit` paths to
/// `paths`. Stops early once `paths.items.len >= limit` without error. Each
/// appended string is workspace-relative and owned by `allocator`.
fn collectArtifactPaths(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    paths: *std.ArrayList([]const u8),
    root: []const u8,
    limit: usize,
) ports.PortError!void {
    // Normalize and constrain path handling here before any downstream filesystem action.
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

/// Builds one scanned-artifact record for `path`. When `include_hashes` is set,
/// reads and hashes the file; a size-limit hit records "skipped_size_limit" and
/// any other read error records its `@errorName` in `hash_status`, so a single
/// unreadable file never fails the surrounding scan.
fn scannedArtifact(
    allocator: std.mem.Allocator,
    context: app_context.ArtifactContext,
    path: []const u8,
    include_hashes: bool,
) ports.PortError!ScannedArtifact {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Parses JSONL registry bytes into an owned slice of RegistryEntry values.
/// Blank and whitespace-only lines are skipped; the first malformed JSON line
/// fails the entire parse (InvalidArtifactRegistryEntry). All strings are
/// duplicated into `allocator`.
fn parseRegistryJsonl(allocator: std.mem.Allocator, bytes: []const u8) ArtifactError!Registry {
    // Normalize input here so downstream paths can rely on validated shape.
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

/// Builds a RegistryEntry from one parsed JSONL object, duplicating every
/// string field into `allocator`. Missing/typed-wrong required fields or a
/// negative byte count fail as InvalidArtifactRegistryEntry; optional fields
/// fall back to their documented defaults.
fn entryFromValue(allocator: std.mem.Allocator, value: std.json.Value) ArtifactError!RegistryEntry {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (value != .object) return error.InvalidArtifactRegistryEntry;
    const obj = value.object;
    const provenance = objectValue(obj.get("provenance")) orelse return error.InvalidArtifactRegistryEntry;
    const toolchain = objectValue(provenance.get("toolchain")) orelse return error.InvalidArtifactRegistryEntry;
    const bytes = integerField(obj, "bytes") orelse return error.InvalidArtifactRegistryEntry;
    if (bytes < 0) return error.InvalidArtifactRegistryEntry;
    return .{
        .path = try dupStringField(allocator, obj, "path"),
        .abs_path = try dupStringField(allocator, obj, "abs_path"),
        .bytes = @intCast(bytes),
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

/// Serializes registry entry fields into an allocator-owned JSON value; allocation failures propagate.
fn registryEntryValue(allocator: std.mem.Allocator, entry: RegistryEntry) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "path", .{ .string = entry.path });
    try obj.put(allocator, "abs_path", .{ .string = entry.abs_path });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(entry.bytes) });
    try obj.put(allocator, "sha256", .{ .string = entry.sha256 });
    try obj.put(allocator, "indexed_at_unix_ms", .{ .integer = entry.indexed_at_unix_ms });
    try obj.put(allocator, "parser_confidence", .{ .string = entry.parser_confidence });
    try obj.put(allocator, "raw_reference", .{ .string = entry.raw_reference });
    try obj.put(allocator, "provenance", try provenanceValue(allocator, entry.provenance));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes provenance fields into an allocator-owned JSON value; allocation failures propagate.
fn provenanceValue(allocator: std.mem.Allocator, provenance: Provenance) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "producer", .{ .string = provenance.producer });
    try obj.put(allocator, "artifact_kind", .{ .string = provenance.artifact_kind });
    try obj.put(allocator, "backend_name", .{ .string = provenance.backend_name });
    try obj.put(allocator, "backend_version", .{ .string = provenance.backend_version });
    try obj.put(allocator, "target", .{ .string = provenance.target });
    try obj.put(allocator, "baseline_identity", .{ .string = provenance.baseline_identity });
    try obj.put(allocator, "notes", .{ .string = provenance.notes });
    // Persist an empty command_argv so the on-disk schema stays stable; this
    // module never records argv, but readers expect the field to be present.
    try obj.put(allocator, "command_argv", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "toolchain", try toolchainValue(allocator, provenance.toolchain));
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes toolchain fields into an allocator-owned JSON value; allocation failures propagate.
fn toolchainValue(allocator: std.mem.Allocator, toolchain: Toolchain) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "zig_path", .{ .string = toolchain.zig_path });
    try obj.put(allocator, "zls_path", .{ .string = toolchain.zls_path });
    try obj.put(allocator, "zflame_path", .{ .string = toolchain.zflame_path });
    try obj.put(allocator, "diff_folded_path", .{ .string = toolchain.diff_folded_path });
    obj_owned = false;
    return .{ .object = obj };
}

/// Unwraps an optional JSON value to its object map, or null if absent or not
/// an object. Used to validate required nested objects during parsing.
fn objectValue(value: ?std.json.Value) ?std.json.ObjectMap {
    const actual = value orelse return null;
    if (actual != .object) return null;
    return actual.object;
}

/// Duplicates a required string field into `allocator`; a missing or non-string
/// value is a malformed entry.
fn dupStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ArtifactError![]u8 {
    const value = obj.get(key) orelse return error.InvalidArtifactRegistryEntry;
    if (value != .string) return error.InvalidArtifactRegistryEntry;
    return allocator.dupe(u8, value.string) catch return error.OutOfMemory;
}

/// Duplicates an optional string field, defaulting to "" when absent or null.
fn dupOptionalStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ArtifactError![]u8 {
    return dupOptionalStringFieldDefault(allocator, obj, key, "");
}

/// Duplicates an optional string field into `allocator`, substituting `default`
/// when the key is absent or JSON null. A present non-string value is malformed.
fn dupOptionalStringFieldDefault(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) ArtifactError![]u8 {
    const value = obj.get(key) orelse return allocator.dupe(u8, default) catch return error.OutOfMemory;
    if (value == .null) return allocator.dupe(u8, default) catch return error.OutOfMemory;
    if (value != .string) return error.InvalidArtifactRegistryEntry;
    return allocator.dupe(u8, value.string) catch return error.OutOfMemory;
}

/// Reads an integer field, or null when absent or not a JSON integer.
fn integerField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

/// Rejoins a scan root with a directory-walk entry path so scanned paths stay
/// workspace-relative. An empty or "." root returns the entry path unchanged.
/// The result is owned by `allocator`.
fn relativeEntryPath(allocator: std.mem.Allocator, root: []const u8, entry_path: []const u8) ports.PortError![]const u8 {
    if (root.len == 0 or std.mem.eql(u8, root, ".")) {
        return allocator.dupe(u8, entry_path) catch return error.OutOfMemory;
    }
    // Workspace-relative logical paths stay `/`-separated on every platform;
    // std.fs.path.join would insert `\` on Windows.
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry_path }) catch return error.OutOfMemory;
}

/// Byte-order comparator used to sort scanned paths for deterministic output.
fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

/// Narrows a JSON-stringify/write error into the module's error set: OutOfMemory
/// is preserved; every other write failure collapses to Unavailable.
fn mapWriteError(err: anyerror) ArtifactError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unavailable,
    };
}

const fakes = @import("../../../testing/fakes/root.zig");

test "artifact kind classifies common generated outputs" {
    try std.testing.expectEqualStrings("svg", artifactKind("zig-out/profile.svg"));
    try std.testing.expectEqualStrings("json", artifactKind(".zigars-cache/report.json"));
    try std.testing.expectEqualStrings("release_archive", artifactKind("dist/assets/zigars.tar.gz"));
}

test "artifact registry handles missing preimages and stream-too-long prune checks" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    const context = testArtifactContext(workspace.port());

    try workspace.expectReadError(.{
        .path = default_registry_path,
        .max_bytes = max_registry_bytes,
        .for_output = true,
        .provenance = "artifacts.prune.preimage",
    }, error.FileNotFound);
    const preimage = try preimageIdentity(std.testing.allocator, context);
    try std.testing.expect(!preimage.exists);
    try std.testing.expectEqual(@as(usize, 0), preimage.bytes);
    try std.testing.expect(preimage.sha256 == null);

    const entry = RegistryEntry{
        .path = "zig-out/report.json",
        .abs_path = "/repo/zig-out/report.json",
        .bytes = 2,
        .sha256 = "old",
        .provenance = .{
            .producer = "test",
            .artifact_kind = "json",
            .toolchain = .{ .zig_path = "zig" },
        },
    };
    try workspace.expectReadError(.{
        .path = entry.path,
        .max_bytes = entry.bytes + 1,
        .for_output = false,
        .provenance = "artifacts.prune.verify",
    }, error.StreamTooLong);
    var entries = [_]RegistryEntry{entry};
    const pruned = try pruneStale(std.testing.allocator, context, .{ .entries = entries[0..] });
    defer std.testing.allocator.free(pruned.entries);
    try std.testing.expectEqual(@as(usize, 0), pruned.summary.kept);
    try std.testing.expectEqual(@as(usize, 1), pruned.summary.changed);
    try std.testing.expectEqual(@as(usize, 1), pruned.summary.pruned);

    try workspace.verify();
}

test "artifact scan reports hash read failures for current root entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    const context = testArtifactContext(workspace.port());

    try workspace.expectResolve(.{
        .path = ".",
        .for_output = false,
        .provenance = "artifacts.scan.resolve",
    }, "/repo");
    try workspace.expectScanDirectory(.{
        .path = ".",
        .max_files = 4,
        .for_output = false,
        .provenance = "artifacts.scan.walk",
    }, &.{"report.log"});
    try workspace.expectReadError(.{
        .path = "report.log",
        .max_bytes = max_hash_bytes,
        .for_output = false,
        .provenance = "artifacts.scan.hash",
    }, error.AccessDenied);

    const scanned = try scanArtifacts(allocator, context, ".", 4, true);
    try std.testing.expectEqual(@as(usize, 1), scanned.artifacts.len);
    try std.testing.expectEqualStrings("report.log", scanned.artifacts[0].path);
    try std.testing.expectEqualStrings("AccessDenied", scanned.artifacts[0].hash_status);
    try std.testing.expect(!scanned.limit_reached);

    try workspace.verify();
}

test "artifact registry JSON helpers and write error mapping cover rollback edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try registryEntryValue(allocator, .{
        .path = "zig-out/report.json",
        .abs_path = "/repo/zig-out/report.json",
        .bytes = 2,
        .sha256 = "abcd",
        .provenance = .{
            .producer = "test",
            .artifact_kind = "json",
            .backend_name = "zls",
            .toolchain = .{ .zig_path = "zig" },
        },
    });
    try std.testing.expectEqualStrings("zig-out/report.json", value.object.get("path").?.string);
    try std.testing.expectEqualStrings("zig", value.object.get("provenance").?.object.get("toolchain").?.object.get("zig_path").?.string);

    try std.testing.expectEqual(error.OutOfMemory, mapWriteError(error.OutOfMemory));
    try std.testing.expectEqual(error.Unavailable, mapWriteError(error.WriteFailed));
}

test "artifact registry rejects negative persisted byte counts" {
    try std.testing.expectError(error.InvalidArtifactRegistryEntry, parseRegistryJsonl(
        std.testing.allocator,
        "{\"path\":\"zig-out/report.json\",\"abs_path\":\"/repo/zig-out/report.json\",\"bytes\":-1,\"sha256\":\"abcd\",\"provenance\":{\"producer\":\"test\",\"artifact_kind\":\"json\",\"toolchain\":{\"zig_path\":\"zig\"}}}\n",
    ));
}

/// Builds a fixed test ArtifactContext backed by the given fake workspace store.
fn testArtifactContext(workspace_store: ports.WorkspaceStore) app_context.ArtifactContext {
    return .{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigars-cache", .transport = "test" },
        .workspace_store = workspace_store,
    };
}
