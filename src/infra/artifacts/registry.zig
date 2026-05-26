const std = @import("std");

pub const default_registry_path = ".zigar-cache/artifacts/registry.jsonl";
pub const default_read_limit: usize = 64 * 1024;

pub const Toolchain = struct {
    zig_path: []const u8,
    zls_path: []const u8 = "",
    zflame_path: []const u8 = "",
    diff_folded_path: []const u8 = "",
};

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

pub const FileIdentity = struct {
    path: []const u8,
    abs_path: []const u8,
    bytes: usize,
    sha256: []const u8,
};

pub const RegistryEntry = struct {
    identity: FileIdentity,
    provenance: Provenance,
    indexed_at_unix_ms: i64,
    parser_confidence: []const u8 = "high",
    raw_reference: []const u8 = "workspace_file",
};

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

    pub fn deinit(self: *OwnedEntry, allocator: std.mem.Allocator) void {
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

pub const Registry = struct {
    entries: std.ArrayList(OwnedEntry) = .empty,

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
    }

    pub fn findByPath(self: Registry, path: []const u8) ?OwnedEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }

    pub fn findBySha256(self: Registry, sha256: []const u8) ?OwnedEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.sha256, sha256)) return entry;
        }
        return null;
    }
};

pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

pub fn identityFromBytes(allocator: std.mem.Allocator, path: []const u8, abs_path: []const u8, bytes: []const u8) !FileIdentity {
    return .{
        .path = path,
        .abs_path = abs_path,
        .bytes = bytes.len,
        .sha256 = try sha256Hex(allocator, bytes),
    };
}

pub fn entryValue(allocator: std.mem.Allocator, entry: RegistryEntry) !std.json.Value {
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

pub fn ownedEntryValue(allocator: std.mem.Allocator, entry: OwnedEntry) !std.json.Value {
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

pub fn provenanceValue(allocator: std.mem.Allocator, provenance: Provenance) !std.json.Value {
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

pub fn registryValue(allocator: std.mem.Allocator, registry: Registry) !std.json.Value {
    var entries = std.json.Array.init(allocator);
    var entries_owned = true;
    defer if (entries_owned) entries.deinit();
    for (registry.entries.items) |entry| try entries.append(try ownedEntryValue(allocator, entry));
    entries_owned = false;
    return .{ .array = entries };
}

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
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try registry.entries.append(allocator, try ownedEntryFromValue(allocator, parsed.value));
    }
    registry_owned = false;
    return registry;
}

pub fn upsert(registry: *Registry, allocator: std.mem.Allocator, entry: RegistryEntry) !void {
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

pub fn writeRegistry(allocator: std.mem.Allocator, io: std.Io, registry_abs_path: []const u8, registry: Registry) !void {
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

pub fn preimageIdentity(allocator: std.mem.Allocator, io: std.Io, registry_abs_path: []const u8) !std.json.Value {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, registry_abs_path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return preimageValue(allocator, false, 0, ""),
        else => return err,
    };
    defer allocator.free(bytes);
    const hash = try sha256Hex(allocator, bytes);
    defer allocator.free(hash);
    return preimageValue(allocator, true, bytes.len, hash);
}

pub fn pruneStale(allocator: std.mem.Allocator, io: std.Io, registry: *Registry) !PruneSummary {
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

pub const PruneSummary = struct {
    kept: usize = 0,
    missing: usize = 0,
    changed: usize = 0,
    pruned: usize = 0,
};

pub fn pruneSummaryValue(allocator: std.mem.Allocator, summary: PruneSummary) !std.json.Value {
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

pub fn deinitValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    var mutable = value;
    switch (mutable) {
        .object => |*obj| obj.deinit(allocator),
        .array => |*array| array.deinit(),
        else => {},
    }
}

fn ownedEntryFromValue(allocator: std.mem.Allocator, value: std.json.Value) !OwnedEntry {
    if (value != .object) return error.InvalidArtifactRegistryEntry;
    const obj = value.object;
    const provenance = objectValue(obj.get("provenance")) orelse return error.InvalidArtifactRegistryEntry;
    const toolchain = objectValue(provenance.get("toolchain")) orelse return error.InvalidArtifactRegistryEntry;
    var owned = emptyOwnedEntry();
    var owned_guard = true;
    defer if (owned_guard) owned.deinit(allocator);
    owned.bytes = @intCast(integerField(obj, "bytes") orelse return error.InvalidArtifactRegistryEntry);
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

fn cloneEntry(allocator: std.mem.Allocator, entry: RegistryEntry) !OwnedEntry {
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

fn emptyOwnedEntry() OwnedEntry {
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

fn toolchainValue(allocator: std.mem.Allocator, toolchain: Toolchain) !std.json.Value {
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

fn argvValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (argv) |arg| try array.append(.{ .string = arg });
    array_owned = false;
    return .{ .array = array };
}

fn preimageValue(allocator: std.mem.Allocator, exists: bool, bytes: usize, sha256: []const u8) !std.json.Value {
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

fn objectValue(value: ?std.json.Value) ?std.json.ObjectMap {
    const actual = value orelse return null;
    if (actual != .object) return null;
    return actual.object;
}

fn dupStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = obj.get(key) orelse return error.InvalidArtifactRegistryEntry;
    if (value != .string) return error.InvalidArtifactRegistryEntry;
    return allocator.dupe(u8, value.string);
}

fn dupOptionalStringField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]u8 {
    return dupOptionalStringFieldDefault(allocator, obj, key, "");
}

fn dupOptionalStringFieldDefault(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) ![]u8 {
    const value = obj.get(key) orelse return allocator.dupe(u8, default);
    if (value == .null) return allocator.dupe(u8, default);
    if (value != .string) return error.InvalidArtifactRegistryEntry;
    return allocator.dupe(u8, value.string);
}

fn integerField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

test "artifact registry upserts and loads jsonl entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const registry_path = try std.fs.path.join(allocator, &.{ base_z[0..], "registry.jsonl" });
    defer allocator.free(registry_path);

    var registry: Registry = .{};
    defer registry.deinit(allocator);
    const data = "profile data\n";
    const identity = try identityFromBytes(allocator, "zig-out/profile.svg", "/workspace/zig-out/profile.svg", data);
    defer allocator.free(identity.sha256);
    try upsert(&registry, allocator, .{
        .identity = identity,
        .provenance = .{
            .producer = "zig_flamegraph",
            .artifact_kind = "profile_svg",
            .command_argv = &.{ "zflame", "recursive", "profile.folded" },
            .backend_name = "zflame",
            .backend_version = "unknown",
            .target = "native",
            .toolchain = .{ .zig_path = "zig" },
        },
        .indexed_at_unix_ms = 1234,
    });
    try upsert(&registry, allocator, .{
        .identity = identity,
        .provenance = .{
            .producer = "zig_flamegraph",
            .artifact_kind = "profile_svg",
            .command_argv = &.{ "zflame", "recursive", "profile.folded" },
            .backend_name = "zflame",
            .backend_version = "unknown",
            .target = "native",
            .notes = "updated",
            .toolchain = .{ .zig_path = "zig" },
        },
        .indexed_at_unix_ms = 5678,
    });
    try std.testing.expectEqual(@as(usize, 1), registry.entries.items.len);
    try std.testing.expectEqualStrings("updated", registry.entries.items[0].notes);
    const registry_json = try registryValue(allocator, registry);
    try std.testing.expectEqual(@as(usize, 1), registry_json.array.items.len);
    try writeRegistry(allocator, io, registry_path, registry);

    var loaded = try loadRegistry(allocator, io, registry_path);
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), loaded.entries.items.len);
    try std.testing.expectEqualStrings("zig-out/profile.svg", loaded.entries.items[0].path);
    try std.testing.expectEqualStrings(identity.sha256, loaded.entries.items[0].sha256);
    try std.testing.expectEqualStrings("zflame", loaded.entries.items[0].backend_name);
}

test "artifact registry prunes missing and changed entries without deleting files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "kept" });
    try tmp.dir.writeFile(io, .{ .sub_path = "changed.txt", .data = "changed" });
    try tmp.dir.writeFile(io, .{ .sub_path = "same-size-changed.txt", .data = "new" });
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const kept_abs = try std.fs.path.join(allocator, &.{ base_z[0..], "kept.txt" });
    defer allocator.free(kept_abs);
    const changed_abs = try std.fs.path.join(allocator, &.{ base_z[0..], "changed.txt" });
    defer allocator.free(changed_abs);
    const same_size_changed_abs = try std.fs.path.join(allocator, &.{ base_z[0..], "same-size-changed.txt" });
    defer allocator.free(same_size_changed_abs);
    const missing_abs = try std.fs.path.join(allocator, &.{ base_z[0..], "missing.txt" });
    defer allocator.free(missing_abs);

    var registry: Registry = .{};
    defer registry.deinit(allocator);
    const kept_identity = try identityFromBytes(allocator, "kept.txt", kept_abs, "kept");
    defer allocator.free(kept_identity.sha256);
    const changed_identity = try identityFromBytes(allocator, "changed.txt", changed_abs, "old");
    defer allocator.free(changed_identity.sha256);
    const same_size_changed_identity = try identityFromBytes(allocator, "same-size-changed.txt", same_size_changed_abs, "old");
    defer allocator.free(same_size_changed_identity.sha256);
    const missing_identity = try identityFromBytes(allocator, "missing.txt", missing_abs, "missing");
    defer allocator.free(missing_identity.sha256);
    const provenance: Provenance = .{
        .producer = "fixture",
        .artifact_kind = "text",
        .toolchain = .{ .zig_path = "zig" },
    };
    try upsert(&registry, allocator, .{ .identity = kept_identity, .provenance = provenance, .indexed_at_unix_ms = 1 });
    try upsert(&registry, allocator, .{ .identity = changed_identity, .provenance = provenance, .indexed_at_unix_ms = 1 });
    try upsert(&registry, allocator, .{ .identity = same_size_changed_identity, .provenance = provenance, .indexed_at_unix_ms = 1 });
    try upsert(&registry, allocator, .{ .identity = missing_identity, .provenance = provenance, .indexed_at_unix_ms = 1 });

    const summary = try pruneStale(allocator, io, &registry);
    try std.testing.expectEqual(@as(usize, 1), summary.kept);
    try std.testing.expectEqual(@as(usize, 2), summary.changed);
    try std.testing.expectEqual(@as(usize, 1), summary.missing);
    try std.testing.expectEqual(@as(usize, 3), summary.pruned);
    try std.testing.expectEqual(@as(usize, 1), registry.entries.items.len);
    try std.testing.expectEqualStrings("kept.txt", registry.entries.items[0].path);
    const summary_value = try pruneSummaryValue(allocator, summary);
    try std.testing.expectEqual(@as(i64, 2), summary_value.object.get("changed").?.integer);
}

test "artifact registry cleans kept entries when prune aborts on read error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "kept" });
    try tmp.dir.createDirPath(io, "bad-dir");
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const kept_abs = try std.fs.path.join(allocator, &.{ base_z[0..], "kept.txt" });
    defer allocator.free(kept_abs);
    const bad_abs = try std.fs.path.join(allocator, &.{ base_z[0..], "bad-dir" });
    defer allocator.free(bad_abs);

    var registry: Registry = .{};
    defer registry.deinit(allocator);
    const provenance: Provenance = .{
        .producer = "fixture",
        .artifact_kind = "text",
        .toolchain = .{ .zig_path = "zig" },
    };
    const kept_identity = try identityFromBytes(allocator, "kept.txt", kept_abs, "kept");
    defer allocator.free(kept_identity.sha256);
    const bad_identity = try identityFromBytes(allocator, "bad-dir", bad_abs, "");
    defer allocator.free(bad_identity.sha256);
    try upsert(&registry, allocator, .{ .identity = kept_identity, .provenance = provenance, .indexed_at_unix_ms = 1 });
    try upsert(&registry, allocator, .{ .identity = bad_identity, .provenance = provenance, .indexed_at_unix_ms = 1 });

    if (pruneStale(allocator, io, &registry)) |_| {
        return error.TestExpectedError;
    } else |_| {}
}
