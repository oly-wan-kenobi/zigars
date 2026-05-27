const std = @import("std");

/// Carries input data across use case and port boundaries.
pub const Input = struct {
    workspace: []const u8,
    cache: []const u8,
    transport: []const u8,
    zig_path: []const u8,
    zls_path: []const u8,
    zlint_path: []const u8,
    zwanzig_path: []const u8,
    zflame_path: []const u8,
    diff_folded_path: []const u8,
    zls_status: []const u8,
    zls_last_failure: ?[]const u8,
    timeout_ms: i64,
    zls_timeout_ms: i64,
    mcp_dependency: []const u8,
    tools_list_schema_rich: bool = false,
    http_available: bool,
    zig_probe: ?Probe = null,
    zls_probe: ?Probe = null,
    zlint_probe: ?Probe = null,
    zwanzig_probe: ?Probe = null,
    zflame_probe: ?Probe = null,
    diff_folded_probe: ?Probe = null,
};

/// Carries probe data across use case and port boundaries.
pub const Probe = struct {
    ok: bool,
    status: []const u8,
    resolution: []const u8,
};

/// Implements report workflow logic using caller-owned inputs.
pub fn report(allocator: std.mem.Allocator, input: Input) !std.json.Value {
    var checks = std.json.Array.init(allocator);
    // Each check records both observed state and operator-facing resolution text
    // so the doctor output can be rendered without extra policy lookups.
    try checks.append(try checkValue(allocator, "workspace", true, "configured", input.workspace));
    try checks.append(try checkValue(allocator, "cache", true, "configured", input.cache));
    try checks.append(try checkValue(
        allocator,
        "workspace_boundary",
        true,
        "realpath",
        "workspace root, existing input paths, existing output files, and output parents are canonicalized; symlink escapes are rejected",
    ));
    try checks.append(try checkValue(allocator, "mcp_dependency", std.mem.indexOf(u8, input.mcp_dependency, "0.0.4") != null, input.mcp_dependency, "use mcp.zig 0.0.4 or newer"));
    try checks.append(try checkValue(
        allocator,
        "mcp_tools_list_schema",
        input.tools_list_schema_rich,
        if (input.tools_list_schema_rich) "rich" else "generic",
        if (input.tools_list_schema_rich)
            "tools/list publishes registered inputSchema properties and required fields"
        else
            "pin mcp.zig to a revision that serializes registered InputSchema values",
    ));
    try checks.append(try checkValue(
        allocator,
        "http_transport",
        input.http_available,
        if (input.http_available) "available" else "disabled",
        if (input.http_available)
            "HTTP is available; stdio remains the safest default for Codex sessions"
        else
            "upgrade to an mcp.zig release with HTTP transport support",
    ));
    try checks.append(try checkValue(
        allocator,
        "zls_session",
        std.mem.eql(u8, input.zls_status, "connected"),
        input.zls_status,
        if (std.mem.eql(u8, input.zls_status, "connected"))
            "ZLS-backed tools are available"
        else
            input.zls_last_failure orelse "ZLS-backed tools require a working zls binary",
    ));
    try checks.append(try checkValue(allocator, "zlint_backend_path", true, "configured", input.zlint_path));
    try checks.append(try checkValue(allocator, "zwanzig_backend_path", true, "configured", input.zwanzig_path));
    try checks.append(try checkValue(allocator, "zflame_backend_path", true, "configured", input.zflame_path));
    try checks.append(try checkValue(allocator, "diff_folded_backend_path", true, "configured", input.diff_folded_path));
    if (input.zig_probe) |probe| try checks.append(try probeValue(allocator, "zig_probe", probe));
    if (input.zls_probe) |probe| try checks.append(try probeValue(allocator, "zls_probe", probe));
    if (input.zlint_probe) |probe| try checks.append(try probeValue(allocator, "zlint_probe", probe));
    if (input.zwanzig_probe) |probe| try checks.append(try probeValue(allocator, "zwanzig_probe", probe));
    if (input.zflame_probe) |probe| try checks.append(try probeValue(allocator, "zflame_probe", probe));
    if (input.diff_folded_probe) |probe| try checks.append(try probeValue(allocator, "diff_folded_probe", probe));

    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_doctor" });
    try obj.put(allocator, "workspace", .{ .string = input.workspace });
    try obj.put(allocator, "transport", .{ .string = input.transport });
    try obj.put(allocator, "zig_path", .{ .string = input.zig_path });
    try obj.put(allocator, "zls_path", .{ .string = input.zls_path });
    try obj.put(allocator, "zlint_path", .{ .string = input.zlint_path });
    try obj.put(allocator, "zwanzig_path", .{ .string = input.zwanzig_path });
    try obj.put(allocator, "zflame_path", .{ .string = input.zflame_path });
    try obj.put(allocator, "diff_folded_path", .{ .string = input.diff_folded_path });
    try obj.put(allocator, "timeout_ms", .{ .integer = input.timeout_ms });
    try obj.put(allocator, "zls_timeout_ms", .{ .integer = input.zls_timeout_ms });
    try obj.put(allocator, "checks", .{ .array = checks });
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes check fields into an allocator-owned JSON value; allocation failures propagate.
fn checkValue(allocator: std.mem.Allocator, name: []const u8, ok: bool, status: []const u8, resolution: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "status", .{ .string = status });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return .{ .object = obj };
}

/// Serializes probe fields into an allocator-owned JSON value; allocation failures propagate.
fn probeValue(allocator: std.mem.Allocator, name: []const u8, probe: Probe) !std.json.Value {
    return checkValue(allocator, name, probe.ok, probe.status, probe.resolution);
}
