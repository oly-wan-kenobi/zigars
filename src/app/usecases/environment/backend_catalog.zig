const std = @import("std");
const domain_catalog = @import("../../../domain/zig/backend_catalog.zig");

pub const supported_zig_version = domain_catalog.supported_zig_version;
pub const Backend = domain_catalog.Backend;
pub const Paths = domain_catalog.Paths;
pub const backends = domain_catalog.backends;

pub fn value(allocator: std.mem.Allocator, paths: Paths, include_configured_paths: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "backend_setup_catalog" });
    try obj.put(allocator, "supported_zig_version", .{ .string = supported_zig_version });
    try obj.put(allocator, "packaging_model", .{ .string = "zigar ships backend metadata and probes; optional backends remain external executables pinned by each project or CI image" });
    var array = std.json.Array.init(allocator);
    for (backends) |backend| try array.append(try backendValue(allocator, backend, paths, include_configured_paths));
    try obj.put(allocator, "backends", .{ .array = array });
    return .{ .object = obj };
}

fn backendValue(allocator: std.mem.Allocator, backend: Backend, paths: Paths, include_configured_paths: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
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
    if (std.mem.eql(u8, name, "zlint")) return paths.zlint_path;
    if (std.mem.eql(u8, name, "zwanzig")) return paths.zwanzig_path;
    if (std.mem.eql(u8, name, "zflame")) return paths.zflame_path;
    return paths.diff_folded_path;
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |item| try array.append(.{ .string = item });
    return .{ .array = array };
}

fn probeArgvValue(allocator: std.mem.Allocator, probe_argv: []const []const u8, configured_path: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (probe_argv, 0..) |item, index| {
        try array.append(.{ .string = if (index == 0) configured_path else item });
    }
    return .{ .array = array };
}
