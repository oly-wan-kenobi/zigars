//! Serializes the pure-domain backend catalog (Zig plus optional ZLS/ZLint/
//! zwanzig/zflame/diff-folded) into an allocator-owned JSON value for setup and
//! adoption surfaces. Reporting only: zigars ships metadata and probe argv but
//! never installs optional backends.
const std = @import("std");
const domain_catalog = @import("../../../domain/zig/backend_catalog.zig");

/// Shared supported zig version result type used by this workflow module.
pub const supported_zig_version = domain_catalog.supported_zig_version;
/// Shared backend result type used by this workflow module.
pub const Backend = domain_catalog.Backend;
/// Shared paths result type used by this workflow module.
pub const Paths = domain_catalog.Paths;
/// Shared backends result type used by this workflow module.
pub const backends = domain_catalog.backends;

/// Serializes value data into an allocator-owned JSON value; allocation failures propagate.
pub fn value(allocator: std.mem.Allocator, paths: Paths, include_configured_paths: bool) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "backend_setup_catalog" });
    try obj.put(allocator, "supported_zig_version", .{ .string = supported_zig_version });
    try obj.put(allocator, "packaging_model", .{ .string = "zigars ships backend metadata and probes; optional backends remain external executables pinned by each project or CI image" });
    var array = std.json.Array.init(allocator);
    for (backends) |backend| try array.append(try backendValue(allocator, backend, paths, include_configured_paths));
    try obj.put(allocator, "backends", .{ .array = array });
    return .{ .object = obj };
}

/// Serializes backend fields into an allocator-owned JSON value; allocation failures propagate.
fn backendValue(allocator: std.mem.Allocator, backend: Backend, paths: Paths, include_configured_paths: bool) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Maps a backend name to its configured executable path. Falls through to the
/// diff-folded path for any unmatched name, which is safe because callers only
/// pass names drawn from the fixed `backends` table.
fn pathFor(name: []const u8, paths: Paths) []const u8 {
    if (std.mem.eql(u8, name, "zig")) return paths.zig_path;
    if (std.mem.eql(u8, name, "zls")) return paths.zls_path;
    if (std.mem.eql(u8, name, "zlint")) return paths.zlint_path;
    if (std.mem.eql(u8, name, "zwanzig")) return paths.zwanzig_path;
    if (std.mem.eql(u8, name, "zflame")) return paths.zflame_path;
    return paths.diff_folded_path;
}

/// Serializes string array fields into an allocator-owned JSON value; allocation failures propagate.
fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |item| try array.append(.{ .string = item });
    return .{ .array = array };
}

/// Serializes the probe argv, substituting the configured executable path for
/// the catalog's placeholder argv[0] so the reported command matches what would
/// actually run. Allocation failures propagate.
fn probeArgvValue(allocator: std.mem.Allocator, probe_argv: []const []const u8, configured_path: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (probe_argv, 0..) |item, index| {
        try array.append(.{ .string = if (index == 0) configured_path else item });
    }
    return .{ .array = array };
}
