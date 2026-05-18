const std = @import("std");
const definitions = @import("backend_catalog/definitions.zig");

pub const supported_zig_version = definitions.supported_zig_version;
pub const Backend = definitions.Backend;
pub const Paths = struct {
    zig_path: []const u8 = "zig",
    zls_path: []const u8 = "zls",
    zwanzig_path: []const u8 = "zwanzig",
    zflame_path: []const u8 = "zflame",
    diff_folded_path: []const u8 = "diff-folded",
};
pub const backends = definitions.backends;

pub fn value(allocator: std.mem.Allocator, paths: Paths, include_configured_paths: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_setup_catalog" });
    try obj.put(allocator, "supported_zig_version", .{ .string = supported_zig_version });
    try obj.put(allocator, "packaging_model", .{ .string = "zigar ships backend metadata and probes; optional backends remain external executables pinned by each project or CI image" });
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (backends) |backend| try array.append(try backendValue(allocator, backend, paths, include_configured_paths));
    try obj.put(allocator, "backends", .{ .array = array });
    return .{ .object = obj };
}

fn backendValue(allocator: std.mem.Allocator, backend: Backend, paths: Paths, include_configured_paths: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    const configured_path = pathFor(backend.name, paths);
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
    return .{ .object = obj };
}

fn pathFor(name: []const u8, paths: Paths) []const u8 {
    if (std.mem.eql(u8, name, "zig")) return paths.zig_path;
    if (std.mem.eql(u8, name, "zls")) return paths.zls_path;
    if (std.mem.eql(u8, name, "zwanzig")) return paths.zwanzig_path;
    if (std.mem.eql(u8, name, "zflame")) return paths.zflame_path;
    if (std.mem.eql(u8, name, "diff-folded")) return paths.diff_folded_path;
    unreachable;
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (values) |item| try array.append(.{ .string = item });
    return .{ .array = array };
}

fn probeArgvValue(allocator: std.mem.Allocator, probe_argv: []const []const u8, configured_path: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (probe_argv, 0..) |item, index| {
        try array.append(.{ .string = if (index == 0) configured_path else item });
    }
    return .{ .array = array };
}

test "backend catalog keeps every backend executable configurable and probeable" {
    try std.testing.expectEqual(@as(usize, 5), backends.len);
    for (backends) |backend| {
        try std.testing.expect(std.mem.startsWith(u8, backend.path_flag, "--"));
        try std.testing.expect(backend.default_path.len > 0);
        try std.testing.expect(backend.probe_argv.len > 0);
        try std.testing.expect(backend.verify.len > 0);
    }
}

test "backend catalog applies configured paths to probe argv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const catalog = try value(arena.allocator(), .{ .zls_path = "/tools/zls" }, true);
    const zls = catalog.object.get("backends").?.array.items[1].object;
    try std.testing.expectEqualStrings("/tools/zls", zls.get("configured_path").?.string);
    try std.testing.expectEqualStrings("/tools/zls", zls.get("probe_argv").?.array.items[0].string);
}
