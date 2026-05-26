const std = @import("std");
const definitions = @import("definitions.zig");

/// Zig compiler version this backend catalog is validated against.
pub const supported_zig_version = definitions.supported_zig_version;
/// Backend metadata row type re-exported for callers.
pub const Backend = definitions.Backend;
/// Optional configured executable paths for catalog rendering.
pub const Paths = definitions.Paths;
/// Static backend catalog used by setup and doctor workflows.
pub const backends = definitions.backends;

/// Builds the public backend setup catalog JSON.
pub fn value(allocator: std.mem.Allocator, paths: Paths, include_configured_paths: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_setup_catalog" });
    try obj.put(allocator, "supported_zig_version", .{ .string = supported_zig_version });
    try obj.put(allocator, "packaging_model", .{ .string = "zigar ships backend metadata and probes; optional backends remain external executables pinned by each project or CI image" });
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (backends) |backend| try array.append(try backendValue(allocator, backend, paths, include_configured_paths));
    try obj.put(allocator, "backends", .{ .array = array });
    array_owned = false;
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes one backend definition for the catalog response.
fn backendValue(allocator: std.mem.Allocator, backend: Backend, paths: Paths, include_configured_paths: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    const configured_path = pathFor(backend.name, paths) orelse backend.default_path;
    try obj.put(allocator, "name", .{ .string = backend.name });
    try obj.put(allocator, "optional", .{ .bool = backend.optional });
    try obj.put(allocator, "path_flag", .{ .string = backend.path_flag });
    try obj.put(allocator, "default_path", .{ .string = backend.default_path });
    if (include_configured_paths) try obj.put(allocator, "configured_path", .{ .string = configured_path });
    try obj.put(allocator, "purpose", .{ .string = backend.purpose });
    try obj.put(allocator, "compatibility", .{ .string = backend.compatibility });
    try obj.put(allocator, "install_strategy", .{ .string = backend.install_strategy });
    try obj.put(allocator, "tools", try stringArrayValue(allocator, backend.tools));
    try obj.put(allocator, "probe_argv", try probeArgvValue(allocator, backend.probe_argv, configured_path));
    try obj.put(allocator, "verify", try stringArrayValue(allocator, backend.verify));
    obj_owned = false;
    return .{ .object = obj };
}

/// Returns the configured executable path for a backend.
fn pathFor(name: []const u8, paths: Paths) ?[]const u8 {
    if (std.mem.eql(u8, name, "zig")) return paths.zig_path;
    if (std.mem.eql(u8, name, "zls")) return paths.zls_path;
    if (std.mem.eql(u8, name, "zlint")) return paths.zlint_path;
    if (std.mem.eql(u8, name, "zwanzig")) return paths.zwanzig_path;
    if (std.mem.eql(u8, name, "zflame")) return paths.zflame_path;
    if (std.mem.eql(u8, name, "diff-folded")) return paths.diff_folded_path;
    return null;
}

/// Serializes a string slice as a JSON array.
fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (values) |item| try array.append(.{ .string = item });
    array_owned = false;
    return .{ .array = array };
}

/// Builds the argv JSON value used by a backend probe.
fn probeArgvValue(allocator: std.mem.Allocator, probe_argv: []const []const u8, configured_path: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (probe_argv, 0..) |item, index| {
        try array.append(.{ .string = if (index == 0) configured_path else item });
    }
    array_owned = false;
    return .{ .array = array };
}

test "backend catalog can omit configured paths and handles unknown path names defensively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const catalog = try value(arena.allocator(), .{}, false);
    const zig = catalog.object.get("backends").?.array.items[0].object;
    try std.testing.expect(zig.get("configured_path") == null);
    try std.testing.expect(pathFor("not-a-backend", .{}) == null);
}
