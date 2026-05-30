//! Artifact registry: types, JSONL persistence, and provenance helpers.
//! The registry lives at `.zigars-cache/artifacts/registry.jsonl`; each line
//! is one JSON object.  Corrupt or negative-size lines are silently skipped
//! so a single bad entry cannot block all subsequent artifact writes.
//! `OwnedEntry` owns all strings; `RegistryEntry` / `Provenance` are borrowed
//! views used for writing.  Callers are responsible for deinitializing owned
//! values via the appropriate `deinit` methods.
const std = @import("std");

/// Default workspace-relative JSONL registry location.
pub const default_registry_path = ".zigars-cache/artifacts/registry.jsonl";
/// Upper bound for reading a single artifact payload through the registry API.
pub const default_read_limit: usize = 64 * 1024;

/// Tool paths recorded with artifact provenance.
/// All fields are borrowed slices; lifetime must exceed the `RegistryEntry` or
/// `Provenance` that holds this struct.  Optional fields default to "" (absent).
pub const Toolchain = struct {
    zig_path: []const u8,
    zls_path: []const u8 = "",
    zflame_path: []const u8 = "",
    diff_folded_path: []const u8 = "",
};

/// Borrowed provenance metadata attached to an artifact registry entry.
/// All slice fields are borrowed; they must remain valid until the entry is
/// serialized or cloned into an `OwnedEntry`.
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

/// Borrowed identity for a concrete artifact file.
/// `path` is workspace-relative; `abs_path` is the fully resolved path used
/// during prune verification.  `sha256` must be a 64-character lowercase hex
/// string allocated by the caller (e.g. from `sha256Hex`).
pub const FileIdentity = struct {
    path: []const u8,
    abs_path: []const u8,
    bytes: usize,
    sha256: []const u8,
};

/// Borrowed registry row ready for JSONL serialization.
/// Use for writing; convert to `OwnedEntry` via `upsert` or `cloneEntry` when
/// the entry must outlive the caller's borrows.
pub const RegistryEntry = struct {
    identity: FileIdentity,
    provenance: Provenance,
    indexed_at_unix_ms: i64,
    parser_confidence: []const u8 = "high",
    raw_reference: []const u8 = "workspace_file",
};

/// Heap-owned registry row loaded from disk.
/// Every string field is individually allocated; call `deinit` to free them
/// all.  Do not mix allocators between `cloneEntry` and `deinit`.
pub const OwnedEntry = struct {
    path: []const u8,
    abs_path: []const u8,
    bytes: usize,
    sha256: []const u8,
    producer: []const u8,
    artifact_kind: []const u8,
    backend_name: []const u8,
    backend_version: []const u8,
    target: []const u8,
    baseline_identity: []const u8,
    notes: []const u8,
    zig_path: []const u8,
    zls_path: []const u8,
    zflame_path: []const u8,
    diff_folded_path: []const u8,
    indexed_at_unix_ms: i64,
    parser_confidence: []const u8,
    raw_reference: []const u8,

    /// Frees every owned string in the loaded registry entry.
    pub fn deinit(self: *OwnedEntry, allocator: std.mem.Allocator) void {
        // Only release owned state here to avoid invalidating borrowed data.
        allocator.free(self.path);
        allocator.free(self.abs_path);
        allocator.free(self.sha256);
        allocator.free(self.producer);
        allocator.free(self.artifact_kind);
        allocator.free(self.backend_name);
        allocator.free(self.backend_version);
        allocator.free(self.target);
        allocator.free(self.baseline_identity);
        allocator.free(self.notes);
        allocator.free(self.zig_path);
        allocator.free(self.zls_path);
        allocator.free(self.zflame_path);
        allocator.free(self.diff_folded_path);
        allocator.free(self.parser_confidence);
        allocator.free(self.raw_reference);
    }
};

/// In-memory artifact registry loaded from JSONL.
/// Holds an ordered list of `OwnedEntry` values; insertion order matches the
/// JSONL file.  Upsert replaces in-place by path, preserving order.
pub const Registry = struct {
    entries: std.ArrayList(OwnedEntry) = .empty,

    /// Frees all loaded entries and the backing list.
    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
    }

    /// Finds the first entry with a matching registry path.
    /// Returns a copy of the struct (all slices still point into the Registry's
    /// owned storage); do NOT call deinit on the returned value.
    pub fn findByPath(self: Registry, path: []const u8) ?OwnedEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }

    /// Finds the first entry with a matching SHA-256 hex digest.
    /// Same ownership note as `findByPath`: do NOT call deinit on the result.
    pub fn findBySha256(self: Registry, sha256: []const u8) ?OwnedEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.sha256, sha256)) return entry;
        }
        return null;
    }
};

/// Returns an allocator-owned lowercase SHA-256 hex digest of `data`.
/// Caller must free the returned slice.
pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

/// Builds a borrowed file identity and allocates only the checksum string.
/// `path` and `abs_path` are borrowed; only `sha256` is heap-allocated and
/// must be freed by the caller when no longer needed.
pub fn identityFromBytes(allocator: std.mem.Allocator, path: []const u8, abs_path: []const u8, bytes: []const u8) !FileIdentity {
    return .{
        .path = path,
        .abs_path = abs_path,
        .bytes = bytes.len,
        .sha256 = try sha256Hex(allocator, bytes),
    };
}

/// Converts a borrowed entry into a JSON object; nested JSON allocations use `allocator`.
pub fn entryValue(allocator: std.mem.Allocator, entry: RegistryEntry) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "path", .{ .string = entry.identity.path });
    try obj.put(allocator, "abs_path", .{ .string = entry.identity.abs_path });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(entry.identity.bytes) });
    try obj.put(allocator, "sha256", .{ .string = entry.identity.sha256 });
    try obj.put(allocator, "indexed_at_unix_ms", .{ .integer = entry.indexed_at_unix_ms });
    try obj.put(allocator, "parser_confidence", .{ .string = entry.parser_confidence });
    try obj.put(allocator, "raw_reference", .{ .string = entry.raw_reference });
    try obj.put(allocator, "provenance", try provenanceValue(allocator, entry.provenance));
    obj_owned = false;
    return .{ .object = obj };
}

/// Converts an owned entry into the public registry JSON shape.
/// Delegates to `entryValue` by constructing a borrowed view on the fly.
pub fn ownedEntryValue(allocator: std.mem.Allocator, entry: OwnedEntry) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return entryValue(allocator, .{
        .identity = .{
            .path = entry.path,
            .abs_path = entry.abs_path,
            .bytes = entry.bytes,
            .sha256 = entry.sha256,
        },
        .provenance = .{
            .producer = entry.producer,
            .artifact_kind = entry.artifact_kind,
            .backend_name = entry.backend_name,
            .backend_version = entry.backend_version,
            .target = entry.target,
            .baseline_identity = entry.baseline_identity,
            .notes = entry.notes,
            .toolchain = .{
                .zig_path = entry.zig_path,
                .zls_path = entry.zls_path,
                .zflame_path = entry.zflame_path,
                .diff_folded_path = entry.diff_folded_path,
            },
        },
        .indexed_at_unix_ms = entry.indexed_at_unix_ms,
        .parser_confidence = entry.parser_confidence,
        .raw_reference = entry.raw_reference,
    });
}

/// Converts borrowed provenance metadata into a JSON object.
pub fn provenanceValue(allocator: std.mem.Allocator, provenance: Provenance) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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
    try obj.put(allocator, "command_argv", try argvValue(allocator, provenance.command_argv));
    try obj.put(allocator, "toolchain", try toolchainValue(allocator, provenance.toolchain));
    obj_owned = false;
    return .{ .object = obj };
}

/// Converts all registry entries into an array-valued JSON object.
pub fn registryValue(allocator: std.mem.Allocator, registry: Registry) !std.json.Value {
    var entries = std.json.Array.init(allocator);
    var entries_owned = true;
    defer if (entries_owned) entries.deinit();
    for (registry.entries.items) |entry| try entries.append(try ownedEntryValue(allocator, entry));
    entries_owned = false;
    return .{ .array = entries };
}

/// Loads newline-delimited registry entries; a missing file produces an empty registry.
/// Up to 16 MiB is read at once.  Malformed JSON or negative `bytes` fields
/// are silently skipped so a single corrupt entry cannot block writes.
/// Caller must deinit the returned Registry.
pub fn loadRegistry(allocator: std.mem.Allocator, io: std.Io, registry_abs_path: []const u8) !Registry {
    var registry: Registry = .{};
    var registry_owned = true;
    defer if (registry_owned) registry.deinit(allocator);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, registry_abs_path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            registry_owned = false;
            return registry;
        },
        else => return err,
    };
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        // Skip malformed lines so one corrupt entry cannot disable all artifact writes.
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        var entry = ownedEntryFromValue(allocator, parsed.value) catch continue;
        errdefer entry.deinit(allocator);
        try registry.entries.append(allocator, entry);
    }
    registry_owned = false;
    return registry;
}

/// Inserts or replaces by path, taking an owned clone of the borrowed entry.
/// If an existing entry with the same `path` is found its memory is freed and
/// the slot is replaced in-place, preserving list order.
pub fn upsert(registry: *Registry, allocator: std.mem.Allocator, entry: RegistryEntry) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var owned = try cloneEntry(allocator, entry);
    var owned_entry = true;
    defer if (owned_entry) owned.deinit(allocator);
    for (registry.entries.items, 0..) |*existing, index| {
        if (std.mem.eql(u8, existing.path, owned.path)) {
            existing.deinit(allocator);
            registry.entries.items[index] = owned;
            owned_entry = false;
            return;
        }
    }
    try registry.entries.append(allocator, owned);
    owned_entry = false;
}

/// Writes the registry atomically as JSONL, creating parent directories first.
/// Builds the full JSONL payload in a heap buffer, then commits it via an
/// atomic file replace so a partial write cannot corrupt the registry.
pub fn writeRegistry(allocator: std.mem.Allocator, io: std.Io, registry_abs_path: []const u8, registry: Registry) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const parent = std.fs.path.dirname(registry_abs_path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(io, parent);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (registry.entries.items) |entry| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const value = try ownedEntryValue(arena.allocator(), entry);
        try std.json.Stringify.value(value, .{}, &out.writer);
        try out.writer.writeByte('\n');
    }
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, registry_abs_path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    var buffer: [1024]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(out.written());
    try writer.flush();
    try atomic.replace(io);
}

/// Returns a JSON identity for the registry file before an update.
/// Used to record the pre-mutation state for audit trails.  If the file does
/// not exist, `exists` is false and `sha256` is null.  Caller must deinit the
/// returned value.
pub fn preimageIdentity(allocator: std.mem.Allocator, io: std.Io, registry_abs_path: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, registry_abs_path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return preimageValue(allocator, false, 0, ""),
        else => return err,
    };
    defer allocator.free(bytes);
    const hash = try sha256Hex(allocator, bytes);
    defer allocator.free(hash);
    return preimageValue(allocator, true, bytes.len, hash);
}

/// Drops registry rows whose files are missing or whose size/hash changed.
/// Surviving entries replace the registry's list in-place.  Both size and SHA-256
/// must match; a file that changed size without a hash change is still pruned.
/// Unexpected read errors (not FileNotFound / StreamTooLong) are propagated.
pub fn pruneStale(allocator: std.mem.Allocator, io: std.Io, registry: *Registry) !PruneSummary {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var kept: std.ArrayList(OwnedEntry) = .empty;
    var kept_owned = true;
    defer if (kept_owned) {
        for (kept.items) |*entry| entry.deinit(allocator);
        kept.deinit(allocator);
    };
    var summary: PruneSummary = .{};
    for (registry.entries.items) |*entry| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, entry.abs_path, allocator, .limited(entry.bytes + 1)) catch |err| switch (err) {
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
        defer allocator.free(bytes);
        const hash = try sha256Hex(allocator, bytes);
        defer allocator.free(hash);
        if (bytes.len != entry.bytes or !std.mem.eql(u8, hash, entry.sha256)) {
            summary.changed += 1;
            continue;
        }
        try kept.append(allocator, entry.*);
        entry.* = emptyOwnedEntry();
        summary.kept += 1;
    }
    for (registry.entries.items) |*entry| entry.deinit(allocator);
    registry.entries.deinit(allocator);
    registry.entries = kept;
    kept_owned = false;
    summary.pruned = summary.missing + summary.changed;
    return summary;
}

/// Counts registry rows retained and removed by a prune pass.
pub const PruneSummary = struct {
    kept: usize = 0,
    missing: usize = 0,
    changed: usize = 0,
    pruned: usize = 0,
};

/// Converts a prune summary into the public JSON shape.
pub fn pruneSummaryValue(allocator: std.mem.Allocator, summary: PruneSummary) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kept", .{ .integer = @intCast(summary.kept) });
    try obj.put(allocator, "missing", .{ .integer = @intCast(summary.missing) });
    try obj.put(allocator, "changed", .{ .integer = @intCast(summary.changed) });
    try obj.put(allocator, "pruned", .{ .integer = @intCast(summary.pruned) });
    obj_owned = false;
    return .{ .object = obj };
}

/// Deinitializes top-level JSON containers produced by this module.
/// Only frees the outermost object or array; nested values share the same
/// allocator and are reclaimed transitively.
pub fn deinitValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    var mutable = value;
    switch (mutable) {
        .object => |*obj| obj.deinit(allocator),
        .array => |*array| array.deinit(),
        else => {},
    }
}

/// Builds an owned registry entry from serialized artifact metadata.
/// On partial failure the owned_guard defers deinit of all already-allocated
/// strings, preventing leaks mid-construction.
fn ownedEntryFromValue(allocator: std.mem.Allocator, value: std.json.Value) !OwnedEntry {
    if (value != .object) return error.InvalidArtifactRegistryEntry;
    const obj = value.object;
    const provenance = objectValue(obj.get("provenance")) orelse return error.InvalidArtifactRegistryEntry;
    const toolchain = objectValue(provenance.get("toolchain")) orelse return error.InvalidArtifactRegistryEntry;
    var owned = emptyOwnedEntry();
    var owned_guard = true;
    defer if (owned_guard) owned.deinit(allocator);
    const bytes_field = integerField(obj, "bytes") orelse return error.InvalidArtifactRegistryEntry;
    // Reject negative or out-of-range sizes so a tampered registry cannot trap the @intCast in ReleaseSafe.
    owned.bytes = std.math.cast(usize, bytes_field) orelse return error.InvalidArtifactRegistryEntry;
    owned.indexed_at_unix_ms = integerField(obj, "indexed_at_unix_ms") orelse 0;
    owned.path = try dupStringField(allocator, obj, "path");
    owned.abs_path = try dupStringField(allocator, obj, "abs_path");
    owned.sha256 = try dupStringField(allocator, obj, "sha256");
    owned.producer = try dupStringField(allocator, provenance, "producer");
    owned.artifact_kind = try dupStringField(allocator, provenance, "artifact_kind");
    owned.backend_name = try dupOptionalStringField(allocator, provenance, "backend_name");
    owned.backend_version = try dupOptionalStringField(allocator, provenance, "backend_version");
    owned.target = try dupOptionalStringField(allocator, provenance, "target");
    owned.baseline_identity = try dupOptionalStringField(allocator, provenance, "baseline_identity");
    owned.notes = try dupOptionalStringField(allocator, provenance, "notes");
    owned.zig_path = try dupOptionalStringField(allocator, toolchain, "zig_path");
    owned.zls_path = try dupOptionalStringField(allocator, toolchain, "zls_path");
    owned.zflame_path = try dupOptionalStringField(allocator, toolchain, "zflame_path");
    owned.diff_folded_path = try dupOptionalStringField(allocator, toolchain, "diff_folded_path");
    owned.parser_confidence = try dupOptionalStringFieldDefault(allocator, obj, "parser_confidence", "medium");
    owned.raw_reference = try dupOptionalStringFieldDefault(allocator, obj, "raw_reference", "registry_jsonl");
    owned_guard = false;
    return owned;
}

/// Clones entry into allocator-owned storage.
fn cloneEntry(allocator: std.mem.Allocator, entry: RegistryEntry) !OwnedEntry {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var owned = emptyOwnedEntry();
    errdefer owned.deinit(allocator);
    owned.bytes = entry.identity.bytes;
    owned.indexed_at_unix_ms = entry.indexed_at_unix_ms;
    owned.path = try allocator.dupe(u8, entry.identity.path);
    owned.abs_path = try allocator.dupe(u8, entry.identity.abs_path);
    owned.sha256 = try allocator.dupe(u8, entry.identity.sha256);
    owned.producer = try allocator.dupe(u8, entry.provenance.producer);
    owned.artifact_kind = try allocator.dupe(u8, entry.provenance.artifact_kind);
    owned.backend_name = try allocator.dupe(u8, entry.provenance.backend_name);
    owned.backend_version = try allocator.dupe(u8, entry.provenance.backend_version);
    owned.target = try allocator.dupe(u8, entry.provenance.target);
    owned.baseline_identity = try allocator.dupe(u8, entry.provenance.baseline_identity);
    owned.notes = try allocator.dupe(u8, entry.provenance.notes);
    owned.zig_path = try allocator.dupe(u8, entry.provenance.toolchain.zig_path);
    owned.zls_path = try allocator.dupe(u8, entry.provenance.toolchain.zls_path);
    owned.zflame_path = try allocator.dupe(u8, entry.provenance.toolchain.zflame_path);
    owned.diff_folded_path = try allocator.dupe(u8, entry.provenance.toolchain.diff_folded_path);
    owned.parser_confidence = try allocator.dupe(u8, entry.parser_confidence);
    owned.raw_reference = try allocator.dupe(u8, entry.raw_reference);
    return owned;
}

/// Creates an empty owned registry entry for rollback paths.
/// All string fields are set to "" (static literals) so deinit is safe to call
/// even before individual fields have been allocated.
fn emptyOwnedEntry() OwnedEntry {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return .{
        .path = "",
        .abs_path = "",
        .bytes = 0,
        .sha256 = "",
        .producer = "",
        .artifact_kind = "",
        .backend_name = "",
        .backend_version = "",
        .target = "",
        .baseline_identity = "",
        .notes = "",
        .zig_path = "",
        .zls_path = "",
        .zflame_path = "",
        .diff_folded_path = "",
        .indexed_at_unix_ms = 0,
        .parser_confidence = "",
        .raw_reference = "",
    };
}

/// Serializes a Toolchain struct into a JSON object.
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

/// Serializes a string slice as a JSON array for the `command_argv` field.
fn argvValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (argv) |arg| try array.append(.{ .string = arg });
    array_owned = false;
    return .{ .array = array };
}

/// Builds the preimage JSON object; `sha256` is serialized as null when the file did not exist.
fn preimageValue(allocator: std.mem.Allocator, exists: bool, bytes: usize, sha256: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "exists", .{ .bool = exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes) });
    if (exists) {
        try obj.put(allocator, "sha256", .{ .string = sha256 });
    } else {
        try obj.put(allocator, "sha256", .null);
    }
    obj_owned = false;
    return .{ .object = obj };
}

/// Returns the inner ObjectMap if the value is an object, otherwise null.
fn objectValue(value: ?std.json.Value) ?std.json.ObjectMap {
    const actual = value orelse return null;
    if (actual != .object) return null;
    return actual.object;
}

/// Duplicates a required string field from artifact JSON.
/// Returns `error.InvalidArtifactRegistryEntry` if the key is absent or not a string.
fn dupStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = obj.get(key) orelse return error.InvalidArtifactRegistryEntry;
    if (value != .string) return error.InvalidArtifactRegistryEntry;
    return allocator.dupe(u8, value.string);
}

/// Duplicates an optional string field from artifact JSON, defaulting to "".
fn dupOptionalStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]u8 {
    return dupOptionalStringFieldDefault(allocator, obj, key, "");
}

/// Duplicates an optional string field or returns an owned copy of `default`.
/// A JSON null is treated the same as a missing key.
fn dupOptionalStringFieldDefault(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) ![]u8 {
    const value = obj.get(key) orelse return allocator.dupe(u8, default);
    if (value == .null) return allocator.dupe(u8, default);
    if (value != .string) return error.InvalidArtifactRegistryEntry;
    return allocator.dupe(u8, value.string);
}

/// Reads a bounded integer field from artifact JSON.
fn integerField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}
