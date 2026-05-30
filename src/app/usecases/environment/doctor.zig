//! Environment doctor: renders configured workspace/toolchain state plus
//! optional backend probes as a flat list of `{name, ok, status, resolution}`
//! checks, and classifies the configured Zig against build.zig.zon's
//! minimum_zig_version.
//!
//! Probes are caller-supplied here (the use case does not run commands); every
//! check carries an operator-facing resolution so doctor output is actionable
//! without a second policy lookup. Version comparison is prefix-only
//! (major.minor.patch) and treats unparseable versions as not-meeting-minimum.
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
    zig_version_preflight: ?ZigVersionPreflightReport = null,
};

/// Carries probe data across use case and port boundaries.
pub const Probe = struct {
    ok: bool,
    status: []const u8,
    resolution: []const u8,
};

/// Input data used to classify the configured Zig binary against build.zig.zon.
pub const ZigVersionPreflightInput = struct {
    probe_enabled: bool = true,
    zig_path: []const u8 = "zig",
    observed_version: ?[]const u8 = null,
    required_minimum: ?[]const u8 = null,
    minimum_unavailable_reason: ?[]const u8 = null,
    unavailable_reason: ?[]const u8 = null,
};

/// Carries Zig version preflight data across use case and port boundaries.
pub const ZigVersionPreflightReport = struct {
    ok: ?bool,
    status: []const u8,
    observed_version: ?[]const u8 = null,
    required_minimum: ?[]const u8 = null,
    resolution: []const u8,
    owns_resolution: bool = false,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: ZigVersionPreflightReport, allocator: std.mem.Allocator) void {
        if (self.owns_resolution) allocator.free(self.resolution);
    }
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
    try checks.append(try checkValue(allocator, "mcp_dependency", std.mem.indexOf(u8, input.mcp_dependency, "0.0.5") != null, input.mcp_dependency, "use mcp.zig 0.0.5 or newer"));
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
    if (input.zig_version_preflight) |preflight| try checks.append(try zigVersionPreflightCheckValue(allocator, preflight));

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

/// Classifies observed Zig version compatibility with build.zig.zon minimum_zig_version.
pub fn zigVersionPreflight(allocator: std.mem.Allocator, input: ZigVersionPreflightInput) !ZigVersionPreflightReport {
    if (!input.probe_enabled) return .{
        .ok = null,
        .status = "unprobed",
        .observed_version = null,
        .required_minimum = input.required_minimum,
        .resolution = "Run zigars_doctor with probe_backends=true to compare `zig version` with build.zig.zon minimum_zig_version.",
    };

    const minimum = input.required_minimum orelse {
        if (input.minimum_unavailable_reason) |reason| return .{
            .ok = null,
            .status = "unavailable",
            .observed_version = input.observed_version,
            .required_minimum = null,
            .resolution = try std.fmt.allocPrint(
                allocator,
                "Could not read build.zig.zon minimum_zig_version ({s}); restore workspace access so Zig compatibility preflight can run.",
                .{reason},
            ),
            .owns_resolution = true,
        };
        return .{
            .ok = null,
            .status = "unavailable",
            .observed_version = input.observed_version,
            .required_minimum = null,
            .resolution = "build.zig.zon minimum_zig_version was not found; add it to enable Zig compatibility preflight.",
        };
    };
    if (std.mem.trim(u8, minimum, " \t\r\n\"'").len == 0) return .{
        .ok = null,
        .status = "unavailable",
        .observed_version = input.observed_version,
        .required_minimum = null,
        .resolution = "build.zig.zon minimum_zig_version was empty; set it to the required Zig release.",
    };

    if (input.unavailable_reason) |reason| return .{
        .ok = false,
        .status = "unavailable",
        .observed_version = input.observed_version,
        .required_minimum = minimum,
        .resolution = try std.fmt.allocPrint(
            allocator,
            "Configured Zig at `{s}` was unavailable ({s}); install or select Zig {s} or newer, then restart zigars with --zig-path pointing at that toolchain.",
            .{ input.zig_path, reason, minimum },
        ),
        .owns_resolution = true,
    };

    const observed = input.observed_version orelse return .{
        .ok = false,
        .status = "unavailable",
        .observed_version = null,
        .required_minimum = minimum,
        .resolution = try std.fmt.allocPrint(
            allocator,
            "Configured Zig at `{s}` did not return a version; install or select Zig {s} or newer, then restart zigars with --zig-path pointing at that toolchain.",
            .{ input.zig_path, minimum },
        ),
        .owns_resolution = true,
    };
    const active = std.mem.trim(u8, observed, " \t\r\n");
    if (parseVersionPrefix(active) == null or parseVersionPrefix(minimum) == null) return .{
        .ok = false,
        .status = "unavailable",
        .observed_version = active,
        .required_minimum = minimum,
        .resolution = try std.fmt.allocPrint(
            allocator,
            "Could not compare configured Zig version `{s}` with build.zig.zon minimum_zig_version `{s}`; verify --zig-path and the minimum_zig_version field.",
            .{ active, minimum },
        ),
        .owns_resolution = true,
    };
    if (!versionMeetsMinimum(active, minimum)) return .{
        .ok = false,
        .status = "incompatible",
        .observed_version = active,
        .required_minimum = minimum,
        .resolution = try std.fmt.allocPrint(
            allocator,
            "Configured Zig at `{s}` reports {s}, but build.zig.zon requires {s} or newer; install or select Zig {s} or newer, then restart zigars with --zig-path pointing at that toolchain.",
            .{ input.zig_path, active, minimum, minimum },
        ),
        .owns_resolution = true,
    };
    return .{
        .ok = true,
        .status = "compatible",
        .observed_version = active,
        .required_minimum = minimum,
        .resolution = "Configured Zig satisfies build.zig.zon minimum_zig_version.",
    };
}

/// Serializes Zig version preflight into the standard doctor check shape.
pub fn zigVersionPreflightValue(allocator: std.mem.Allocator, input: ZigVersionPreflightInput) !std.json.Value {
    const preflight = try zigVersionPreflight(allocator, input);
    defer preflight.deinit(allocator);
    return zigVersionPreflightCheckValue(allocator, preflight);
}

/// Extracts build.zig.zon minimum_zig_version from caller-owned bytes.
pub fn minimumZigVersionFromBuildZon(bytes: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.indexOf(u8, trimmed, "minimum_zig_version") == null) continue;
        return quotedString(trimmed);
    }
    return null;
}

/// True when `active_zig` is at least `minimum_zig`, comparing only the leading
/// major.minor.patch tuple. Unparseable versions fail closed (return false).
/// Note: prerelease/dev suffixes are ignored, so `0.16.0-dev.N` satisfies a
/// `0.16.0` minimum once the numeric prefix matches.
pub fn versionMeetsMinimum(active_zig: []const u8, minimum_zig: []const u8) bool {
    const active = parseVersionPrefix(active_zig) orelse return false;
    const minimum = parseVersionPrefix(minimum_zig) orelse return false;
    for (active, minimum) |active_part, minimum_part| {
        if (active_part > minimum_part) return true;
        if (active_part < minimum_part) return false;
    }
    return true;
}

/// Parses the leading major.minor.patch version from Zig version strings.
pub fn parseVersionPrefix(raw: []const u8) ?[3]u64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (trimmed.len == 0) return null;
    var pos: usize = if (trimmed[0] == 'v') 1 else 0;
    var parts: [3]u64 = .{ 0, 0, 0 };
    var index: usize = 0;
    while (index < parts.len) : (index += 1) {
        if (pos >= trimmed.len or !std.ascii.isDigit(trimmed[pos])) break;
        var value: u64 = 0;
        while (pos < trimmed.len and std.ascii.isDigit(trimmed[pos])) : (pos += 1) {
            value = value * 10 + (trimmed[pos] - '0');
        }
        parts[index] = value;
        if (pos >= trimmed.len or trimmed[pos] != '.') {
            index += 1;
            break;
        }
        pos += 1;
    }
    if (index < 2) return null;
    return parts;
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

/// Serializes Zig version preflight fields into an allocator-owned JSON value.
fn zigVersionPreflightCheckValue(allocator: std.mem.Allocator, preflight: ZigVersionPreflightReport) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "name", .{ .string = "zig_version_preflight" });
    try obj.put(allocator, "ok", if (preflight.ok) |ok| .{ .bool = ok } else .null);
    try obj.put(allocator, "status", try ownedString(allocator, preflight.status));
    try obj.put(allocator, "resolution", try ownedString(allocator, preflight.resolution));
    try obj.put(allocator, "observed_version", if (preflight.observed_version) |version| try ownedString(allocator, version) else .null);
    try obj.put(allocator, "required_minimum", if (preflight.required_minimum) |version| try ownedString(allocator, version) else .null);
    try obj.put(allocator, "source_path", .{ .string = "build.zig.zon" });
    obj_owned = false;
    return .{ .object = obj };
}

/// Returns the first quoted string found in caller-owned input.
fn quotedString(line: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const rest = line[start + 1 ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

/// Copies the provided string into allocator-owned storage.
fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}
