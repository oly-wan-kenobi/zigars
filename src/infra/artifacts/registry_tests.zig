//! Tests the artifact registry: upsert-replaces by path, JSONL round-trip,
//! corrupt/negative-size line skipping, and prune-stale semantics (missing,
//! size-changed, hash-changed, and error-during-prune scenarios).
const std = @import("std");
const artifacts = @import("registry.zig");

const Registry = artifacts.Registry;
const Provenance = artifacts.Provenance;
const identityFromBytes = artifacts.identityFromBytes;
const upsert = artifacts.upsert;
const registryValue = artifacts.registryValue;
const writeRegistry = artifacts.writeRegistry;
const loadRegistry = artifacts.loadRegistry;
const pruneStale = artifacts.pruneStale;
const pruneSummaryValue = artifacts.pruneSummaryValue;

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

test "artifact registry load skips malformed and negative-size lines but keeps good entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Produce one canonical good JSONL line via the public writer so the fixture cannot drift.
    var good_registry: Registry = .{};
    defer good_registry.deinit(allocator);
    const data = "profile data\n";
    const identity = try identityFromBytes(allocator, "zig-out/profile.svg", "/workspace/zig-out/profile.svg", data);
    defer allocator.free(identity.sha256);
    try upsert(&good_registry, allocator, .{
        .identity = identity,
        .provenance = .{
            .producer = "zig_flamegraph",
            .artifact_kind = "profile_svg",
            .toolchain = .{ .zig_path = "zig" },
        },
        .indexed_at_unix_ms = 1234,
    });
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    const good_path = try std.fs.path.join(allocator, &.{ base_z[0..], "good.jsonl" });
    defer allocator.free(good_path);
    try writeRegistry(allocator, io, good_path, good_registry);
    const good_line_raw = try std.Io.Dir.cwd().readFileAlloc(io, good_path, allocator, .limited(64 * 1024));
    defer allocator.free(good_line_raw);
    const good_line = std.mem.trim(u8, good_line_raw, " \t\r\n");

    // A negative byte count is corrupt/tampered; the @intCast must not trap and the line is dropped.
    const negative_bytes_line = try std.mem.replaceOwned(u8, allocator, good_line, "\"bytes\":13", "\"bytes\":-1");
    defer allocator.free(negative_bytes_line);
    try std.testing.expect(!std.mem.eql(u8, negative_bytes_line, good_line));

    // Compose a registry: one good line, one syntactically broken line, one negative-size line.
    const composed = try std.fmt.allocPrint(allocator, "{s}\n{{ this is not json\n{s}\n", .{ good_line, negative_bytes_line });
    defer allocator.free(composed);
    const composed_path = try std.fs.path.join(allocator, &.{ base_z[0..], "registry.jsonl" });
    defer allocator.free(composed_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = composed_path, .data = composed });

    var loaded = try loadRegistry(allocator, io, composed_path);
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), loaded.entries.items.len);
    try std.testing.expectEqualStrings("zig-out/profile.svg", loaded.entries.items[0].path);
    try std.testing.expectEqual(@as(usize, data.len), loaded.entries.items[0].bytes);
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
