//! Standalone compiler probes for Zig layout evidence.
//!
//! Probes are generated under the workspace cache and invoke direct `zig`
//! commands. They do not import project modules or execute build.zig.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");

pub const default_memory_targets = "x86_64-linux";
pub const default_abi_targets = "x86_64-linux x86-linux";

const max_targets = 5;
const max_measured_declarations = 16;
const max_command_output = 24 * 1024;
const target_metadata_output = 4096;
const probe_provenance = "static_analysis.layout_probe";

/// Extracted layout-sensitive declaration that can be copied into a standalone
/// probe without importing project modules.
pub const LayoutDeclaration = struct {
    file: []const u8,
    line: usize,
    name: []const u8,
    kind: []const u8,
    source: []const u8,
    fields: []const []const u8,

    pub fn deinit(self: LayoutDeclaration, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.name);
        allocator.free(self.source);
        for (self.fields) |field| allocator.free(field);
        allocator.free(self.fields);
    }
};

/// Owned declaration list.
pub const DeclarationSet = struct {
    declarations: []LayoutDeclaration,

    pub fn deinit(self: DeclarationSet, allocator: std.mem.Allocator) void {
        for (self.declarations) |declaration| declaration.deinit(allocator);
        allocator.free(self.declarations);
    }
};

/// Compiler probe options supplied by an MCP tool.
pub const ProbeOptions = struct {
    tool_name: []const u8,
    targets: ?[]const u8 = null,
    timeout_ms: u64,
    allow_project_comptime: bool = false,
    compare_targets: bool = false,
};

const TargetList = struct {
    values: []const []const u8,

    fn deinit(self: TargetList, allocator: std.mem.Allocator) void {
        for (self.values) |value| allocator.free(value);
        allocator.free(self.values);
    }
};

const ProbeStatus = struct {
    label: []const u8,
    measured: usize,
    unsupported: usize,
    failed: usize,
};

/// Adds layout declarations found in `bytes` to `out`.
pub fn appendDeclarations(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(LayoutDeclaration),
    file: []const u8,
    bytes: []const u8,
    limit: usize,
    abi_only: bool,
) !void {
    var offset: usize = 0;
    var line_no: usize = 1;
    while (offset < bytes.len and out.items.len < limit) {
        const line_end = std.mem.indexOfScalarPos(u8, bytes, offset, '\n') orelse bytes.len;
        const line = bytes[offset..line_end];
        defer {
            offset = if (line_end < bytes.len) line_end + 1 else bytes.len;
            line_no += 1;
        }

        const sanitized = try sanitizeCodeLine(allocator, line);
        defer allocator.free(sanitized);
        const kind = layoutKind(sanitized) orelse continue;
        if (abi_only and !abiLayoutKind(kind)) continue;
        const name = declarationName(sanitized) orelse continue;
        const declaration_source = extractDeclarationSource(bytes, offset) orelse continue;
        const fields = try collectFieldNames(allocator, declaration_source, std.mem.endsWith(u8, kind, "struct"));
        errdefer {
            for (fields) |field| allocator.free(field);
            allocator.free(fields);
        }
        try out.append(allocator, .{
            .file = try allocator.dupe(u8, file),
            .line = line_no,
            .name = try allocator.dupe(u8, name),
            .kind = kind,
            .source = try allocator.dupe(u8, declaration_source),
            .fields = fields,
        });
    }
}

/// Runs standalone compiler probes and returns structured evidence.
pub fn compilerEvidenceValue(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    declarations: []const LayoutDeclaration,
    options: ProbeOptions,
) ports.PortError!std.json.Value {
    const requested_targets = options.targets orelse if (options.compare_targets) default_abi_targets else default_memory_targets;
    const targets = try parseTargets(allocator, requested_targets);
    defer targets.deinit(allocator);

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "measurement_mode", .{ .string = "compiler_backed_standalone" });
    try obj.put(allocator, "targets", try dynamicStringArrayValue(allocator, targets.values));
    try obj.put(allocator, "target_count", .{ .integer = @intCast(targets.values.len) });
    const layout_cache_dir = try cacheDir(allocator, context);
    defer allocator.free(layout_cache_dir);
    try obj.put(allocator, "cache_dir", try ownedString(allocator, layout_cache_dir));
    try obj.put(allocator, "output_limit_bytes", .{ .integer = max_command_output });
    try obj.put(allocator, "execution_risk", try executionRiskValue(allocator, options.allow_project_comptime));

    const command_runner = context.command_runner orelse {
        try obj.put(allocator, "backend_status", .{ .string = "unavailable" });
        try obj.put(allocator, "resolution", .{ .string = "Bind a command runner and configured Zig executable before requesting compiler-backed layout measurements." });
        try obj.put(allocator, "measurements", .{ .array = std.json.Array.init(allocator) });
        try obj.put(allocator, "unsupported_measurements", .{ .array = std.json.Array.init(allocator) });
        try obj.put(allocator, "layout_differences", .{ .array = std.json.Array.init(allocator) });
        try obj.put(allocator, "unchanged_layouts", .{ .array = std.json.Array.init(allocator) });
        return .{ .object = obj };
    };

    const zig_version = try runZigVersionValue(allocator, context, command_runner, options.timeout_ms);
    try obj.put(allocator, "zig_version", zig_version);
    const version_text = versionStringFromValue(obj.get("zig_version").?);
    if (version_text == null or !std.mem.eql(u8, version_text.?, "0.16.0")) {
        try obj.put(allocator, "backend_status", .{ .string = "unsupported_zig_version" });
        try obj.put(allocator, "resolution", .{ .string = "Install or select Zig 0.16.0 before trusting versioned ABI/layout fixture expectations." });
        try obj.put(allocator, "measurements", .{ .array = std.json.Array.init(allocator) });
        try obj.put(allocator, "unsupported_measurements", .{ .array = std.json.Array.init(allocator) });
        try obj.put(allocator, "layout_differences", .{ .array = std.json.Array.init(allocator) });
        try obj.put(allocator, "unchanged_layouts", .{ .array = std.json.Array.init(allocator) });
        return .{ .object = obj };
    }

    try obj.put(allocator, "target_metadata", try targetMetadataValues(allocator, context, command_runner, targets.values, options.timeout_ms));

    var measurements = std.json.Array.init(allocator);
    var unsupported = std.json.Array.init(allocator);
    var command_count: usize = 1 + targets.values.len;
    var measured_count: usize = 0;
    var failed_count: usize = 0;
    const declaration_limit = @min(declarations.len, max_measured_declarations);
    for (declarations[0..declaration_limit]) |declaration| {
        if (unsupportedReason(declaration, options.allow_project_comptime)) |reason| {
            try unsupported.append(try unsupportedValue(allocator, declaration, reason, options.allow_project_comptime));
            continue;
        }
        for (targets.values) |target| {
            const measurement = runDeclarationProbe(allocator, context, command_runner, declaration, target, options.timeout_ms) catch |err| {
                failed_count += 1;
                try unsupported.append(try commandFailureValue(allocator, declaration, target, err));
                continue;
            };
            command_count += 1;
            if (measurement.object.get("status")) |status| {
                if (status == .string and std.mem.eql(u8, status.string, "measured")) {
                    measured_count += 1;
                } else {
                    failed_count += 1;
                }
            }
            try measurements.append(measurement);
        }
    }

    const status = probeStatus(.{
        .label = "compiler_probe_executed",
        .measured = measured_count,
        .unsupported = unsupported.items.len,
        .failed = failed_count,
    });
    try obj.put(allocator, "backend_status", .{ .string = status });
    try obj.put(allocator, "command_count", .{ .integer = @intCast(command_count) });
    try obj.put(allocator, "measured_declaration_limit", .{ .integer = @intCast(max_measured_declarations) });
    try obj.put(allocator, "measurement_count", .{ .integer = @intCast(measurements.items.len) });
    try obj.put(allocator, "unsupported_count", .{ .integer = @intCast(unsupported.items.len) });
    try obj.put(allocator, "measurements", .{ .array = measurements });
    try obj.put(allocator, "unsupported_measurements", .{ .array = unsupported });
    try obj.put(allocator, "layout_differences", try layoutDifferencesValue(allocator, measurements.items, true));
    try obj.put(allocator, "unchanged_layouts", try layoutDifferencesValue(allocator, measurements.items, false));
    try obj.put(allocator, "resolution", .{ .string = "Use measurements only for declarations reported as measured; unsupported declarations need stronger project-aware evidence before ABI claims." });
    return .{ .object = obj };
}

fn probeStatus(status: ProbeStatus) []const u8 {
    if (status.measured == 0 and status.failed == 0 and status.unsupported == 0) return "no_layout_declarations";
    if (status.measured == 0) return "unsupported";
    if (status.failed > 0 or status.unsupported > 0) return "partial";
    return status.label;
}

fn runZigVersionValue(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    command_runner: ports.CommandRunner,
    timeout_ms: u64,
) ports.PortError!std.json.Value {
    var result = try command_runner.run(allocator, .{
        .argv = &.{ context.tool_paths.zig, "version" },
        .cwd = context.workspace.root,
        .timeout_ms = timeout_ms,
        .max_stdout_bytes = 128,
        .max_stderr_bytes = 2048,
        .provenance = probe_provenance,
    });
    defer result.deinit(allocator);

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "version", try ownedString(allocator, std.mem.trim(u8, result.stdout, " \t\r\n")));
    try obj.put(allocator, "command", try commandResultValue(allocator, &.{ context.tool_paths.zig, "version" }, context.workspace.root, timeout_ms, 128, 2048, result));
    return .{ .object = obj };
}

fn targetMetadataValues(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    command_runner: ports.CommandRunner,
    targets: []const []const u8,
    timeout_ms: u64,
) ports.PortError!std.json.Value {
    var array = std.json.Array.init(allocator);
    for (targets) |target| {
        const argv = &.{ context.tool_paths.zig, "build-exe", "--show-builtin", "-target", target };
        var result = command_runner.run(allocator, .{
            .argv = argv,
            .cwd = context.workspace.root,
            .timeout_ms = timeout_ms,
            .max_stdout_bytes = target_metadata_output,
            .max_stderr_bytes = 2048,
            .provenance = probe_provenance,
        }) catch |err| {
            var item = std.json.ObjectMap.empty;
            try item.put(allocator, "target", try ownedString(allocator, target));
            try item.put(allocator, "status", .{ .string = "metadata_unavailable" });
            try item.put(allocator, "error", .{ .string = @errorName(err) });
            try item.put(allocator, "command_argv", try dynamicStringArrayValue(allocator, argv));
            try array.append(.{ .object = item });
            continue;
        };
        defer result.deinit(allocator);
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "target", try ownedString(allocator, target));
        try item.put(allocator, "status", .{ .string = if (result.effectiveTerm().failed()) "command_failed" else "available" });
        try item.put(allocator, "basis", .{ .string = "zig build-exe --show-builtin -target" });
        try item.put(allocator, "stdout_excerpt", try ownedString(allocator, bounded(result.stdout, 1024)));
        try item.put(allocator, "command", try commandResultValue(allocator, argv, context.workspace.root, timeout_ms, target_metadata_output, 2048, result));
        try array.append(.{ .object = item });
    }
    return .{ .array = array };
}

fn runDeclarationProbe(
    allocator: std.mem.Allocator,
    context: app_context.StaticAnalysisContext,
    command_runner: ports.CommandRunner,
    declaration: LayoutDeclaration,
    target: []const u8,
    timeout_ms: u64,
) ports.PortError!std.json.Value {
    const probe_source = try buildProbeSource(allocator, declaration);
    defer allocator.free(probe_source);
    const path = try probePath(allocator, declaration, target, probe_source);
    defer allocator.free(path);

    _ = try context.workspace_store.write(.{
        .path = path,
        .bytes = probe_source,
        .create_parent_dirs = true,
        .replace_existing = true,
        .provenance = probe_provenance,
    });

    const cache_path = try cacheDir(allocator, context);
    defer allocator.free(cache_path);
    const argv = &.{ context.tool_paths.zig, "build-obj", path, "-target", target, "-fno-emit-bin", "--cache-dir", cache_path };
    var result = try command_runner.run(allocator, .{
        .argv = argv,
        .cwd = context.workspace.root,
        .timeout_ms = timeout_ms,
        .max_stdout_bytes = max_command_output,
        .max_stderr_bytes = max_command_output,
        .provenance = probe_provenance,
    });
    defer result.deinit(allocator);

    var measurement = try measurementFromCompileLog(allocator, declaration, target, result.stderr);
    try measurement.object.put(allocator, "probe_path", try ownedString(allocator, path));
    try measurement.object.put(allocator, "command", try commandResultValue(allocator, argv, context.workspace.root, timeout_ms, max_command_output, max_command_output, result));
    if (measurement.object.get("status")) |status| {
        if (status == .string and std.mem.eql(u8, status.string, "measured")) {
            try measurement.object.put(allocator, "evidence_basis", .{ .string = "zig build-obj -fno-emit-bin compile-log @sizeOf/@alignOf/@offsetOf/@bitOffsetOf evidence" });
        }
    }
    return measurement;
}

pub fn buildProbeSource(allocator: std.mem.Allocator, declaration: LayoutDeclaration) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "//! Generated by zigars ABI/layout probe. Standalone: no project imports and no build.zig execution.\n");
    try out.appendSlice(allocator, declaration.source);
    if (!std.mem.endsWith(u8, std.mem.trim(u8, declaration.source, " \t\r\n"), ";")) try out.append(allocator, ';');
    try out.appendSlice(allocator, "\ncomptime {\n");
    try appendCompileLog(allocator, &out, declaration.name, "size", "@sizeOf");
    try appendCompileLog(allocator, &out, declaration.name, "align", "@alignOf");
    if (std.mem.endsWith(u8, declaration.kind, "struct")) {
        for (declaration.fields) |field| {
            try appendFieldCompileLog(allocator, &out, declaration.name, field, "offset", "@offsetOf");
            try appendFieldCompileLog(allocator, &out, declaration.name, field, "bit_offset", "@bitOffsetOf");
        }
    }
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

fn appendCompileLog(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, metric: []const u8, builtin: []const u8) !void {
    const line = try std.fmt.allocPrint(allocator, "    @compileLog(\"zigars:decl:{s}:{s}\", {s}({s}));\n", .{ name, metric, builtin, name });
    defer allocator.free(line);
    try out.appendSlice(allocator, line);
}

fn appendFieldCompileLog(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, field: []const u8, metric: []const u8, builtin: []const u8) !void {
    const line = try std.fmt.allocPrint(allocator, "    @compileLog(\"zigars:decl:{s}:field:{s}:{s}\", {s}({s}, \"{s}\"));\n", .{ name, field, metric, builtin, name, field });
    defer allocator.free(line);
    try out.appendSlice(allocator, line);
}

fn measurementFromCompileLog(
    allocator: std.mem.Allocator,
    declaration: LayoutDeclaration,
    target: []const u8,
    stderr: []const u8,
) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "declaration", try declarationValue(allocator, declaration));
    try obj.put(allocator, "target", try ownedString(allocator, target));
    try obj.put(allocator, "imports_project_modules", .{ .bool = false });
    try obj.put(allocator, "executes_build_zig", .{ .bool = false });
    try obj.put(allocator, "executes_target_binary", .{ .bool = false });
    try obj.put(allocator, "stdout_basis", .{ .string = "none" });

    const size = parseMetric(stderr, declaration.name, "size");
    const alignment = parseMetric(stderr, declaration.name, "align");
    if (size == null or alignment == null) {
        try obj.put(allocator, "status", .{ .string = "unsupported" });
        try obj.put(allocator, "reason", .{ .string = "compiler output did not contain parseable zigars layout compile logs" });
        try obj.put(allocator, "stderr_excerpt", try ownedString(allocator, bounded(stderr, 2048)));
        return .{ .object = obj };
    }

    try obj.put(allocator, "status", .{ .string = "measured" });
    try obj.put(allocator, "size", .{ .integer = @intCast(size.?) });
    try obj.put(allocator, "alignment", .{ .integer = @intCast(alignment.?) });
    try obj.put(allocator, "fields", try fieldsMeasurementValue(allocator, stderr, declaration));
    try obj.put(allocator, "confidence", .{ .string = "high" });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{
        "Measurements come from generated standalone probes and do not prove declarations that require project imports.",
        "Compile-log probes intentionally make the compiler return a non-zero exit status after emitting measurement evidence.",
    }));
    return .{ .object = obj };
}

fn fieldsMeasurementValue(
    allocator: std.mem.Allocator,
    stderr: []const u8,
    declaration: LayoutDeclaration,
) !std.json.Value {
    var fields = std.json.Array.init(allocator);
    if (!std.mem.endsWith(u8, declaration.kind, "struct")) return .{ .array = fields };
    for (declaration.fields) |field| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "name", try ownedString(allocator, field));
        if (parseFieldMetric(stderr, declaration.name, field, "offset")) |value| {
            try item.put(allocator, "offset", .{ .integer = @intCast(value) });
        } else {
            try item.put(allocator, "offset", .null);
        }
        if (parseFieldMetric(stderr, declaration.name, field, "bit_offset")) |value| {
            try item.put(allocator, "bit_offset", .{ .integer = @intCast(value) });
        } else {
            try item.put(allocator, "bit_offset", .null);
        }
        try fields.append(.{ .object = item });
    }
    return .{ .array = fields };
}

fn layoutDifferencesValue(allocator: std.mem.Allocator, measurements: []const std.json.Value, want_changed: bool) !std.json.Value {
    var out = std.json.Array.init(allocator);
    for (measurements, 0..) |measurement, index| {
        if (measurement != .object) continue;
        const declaration = measurement.object.get("declaration") orelse continue;
        if (declaration != .object) continue;
        const name_value = declaration.object.get("name") orelse continue;
        if (name_value != .string) continue;
        const target_value = measurement.object.get("target") orelse continue;
        if (target_value != .string) continue;
        const size_value = measurement.object.get("size") orelse continue;
        const align_value = measurement.object.get("alignment") orelse continue;
        if (size_value != .integer or align_value != .integer) continue;
        for (measurements[index + 1 ..]) |other| {
            if (other != .object) continue;
            const other_declaration = other.object.get("declaration") orelse continue;
            if (other_declaration != .object) continue;
            const other_name = other_declaration.object.get("name") orelse continue;
            if (other_name != .string or !std.mem.eql(u8, other_name.string, name_value.string)) continue;
            const other_target = other.object.get("target") orelse continue;
            if (other_target != .string or std.mem.eql(u8, other_target.string, target_value.string)) continue;
            const other_size = other.object.get("size") orelse continue;
            const other_align = other.object.get("alignment") orelse continue;
            if (other_size != .integer or other_align != .integer) continue;
            const changed = size_value.integer != other_size.integer or align_value.integer != other_align.integer;
            if (changed != want_changed) continue;
            var item = std.json.ObjectMap.empty;
            try item.put(allocator, "declaration", try ownedString(allocator, name_value.string));
            try item.put(allocator, "left_target", try ownedString(allocator, target_value.string));
            try item.put(allocator, "right_target", try ownedString(allocator, other_target.string));
            try item.put(allocator, "left_size", size_value);
            try item.put(allocator, "right_size", other_size);
            try item.put(allocator, "left_alignment", align_value);
            try item.put(allocator, "right_alignment", other_align);
            try item.put(allocator, "basis", .{ .string = "compiler-backed standalone target measurements" });
            try out.append(.{ .object = item });
        }
    }
    return .{ .array = out };
}

fn parseMetric(stderr: []const u8, name: []const u8, metric: []const u8) ?u64 {
    var label_buf: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "zigars:decl:{s}:{s}", .{ name, metric }) catch return null;
    return parseCompileLogValue(stderr, label);
}

fn parseFieldMetric(stderr: []const u8, name: []const u8, field: []const u8, metric: []const u8) ?u64 {
    var label_buf: [220]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "zigars:decl:{s}:field:{s}:{s}", .{ name, field, metric }) catch return null;
    return parseCompileLogValue(stderr, label);
}

pub fn parseCompileLogValue(stderr: []const u8, label: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, label) == null) continue;
        const marker = "@as(comptime_int, ";
        const start = std.mem.indexOf(u8, line, marker) orelse continue;
        const rest = line[start + marker.len ..];
        const end = std.mem.indexOfScalar(u8, rest, ')') orelse continue;
        return std.fmt.parseUnsigned(u64, std.mem.trim(u8, rest[0..end], " \t\r"), 10) catch null;
    }
    return null;
}

fn unsupportedReason(declaration: LayoutDeclaration, allow_project_comptime: bool) ?[]const u8 {
    if (std.mem.indexOf(u8, declaration.source, "@import(") != null) return "standalone probe refused because declaration source contains @import";
    if (std.mem.indexOf(u8, declaration.source, "usingnamespace") != null) return "standalone probe refused because declaration source contains usingnamespace";
    if (std.mem.indexOf(u8, declaration.source, "@embedFile(") != null) return "standalone probe refused because declaration source contains @embedFile workspace-boundary risk";
    if (!allow_project_comptime and std.mem.indexOf(u8, declaration.source, "comptime") != null) return "standalone probe refused because declaration source contains comptime logic; set allow_project_comptime=true only after reviewing arbitrary comptime risk";
    return null;
}

fn unsupportedValue(allocator: std.mem.Allocator, declaration: LayoutDeclaration, reason: []const u8, allow_project_comptime: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "declaration", try declarationValue(allocator, declaration));
    try obj.put(allocator, "status", .{ .string = "unsupported" });
    try obj.put(allocator, "reason", .{ .string = reason });
    try obj.put(allocator, "imports_project_modules", .{ .bool = false });
    try obj.put(allocator, "executes_build_zig", .{ .bool = false });
    try obj.put(allocator, "executes_target_binary", .{ .bool = false });
    try obj.put(allocator, "allow_project_comptime", .{ .bool = allow_project_comptime });
    return .{ .object = obj };
}

fn commandFailureValue(allocator: std.mem.Allocator, declaration: LayoutDeclaration, target: []const u8, err: ports.PortError) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "declaration", try declarationValue(allocator, declaration));
    try obj.put(allocator, "target", try ownedString(allocator, target));
    try obj.put(allocator, "status", .{ .string = "command_error" });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "resolution", .{ .string = "Verify the configured Zig executable and workspace cache path, then retry with a smaller target/declaration set if needed." });
    return .{ .object = obj };
}

fn declarationValue(allocator: std.mem.Allocator, declaration: LayoutDeclaration) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, declaration.file));
    try obj.put(allocator, "line", .{ .integer = @intCast(declaration.line) });
    try obj.put(allocator, "name", try ownedString(allocator, declaration.name));
    try obj.put(allocator, "kind", .{ .string = declaration.kind });
    return .{ .object = obj };
}

fn commandResultValue(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    timeout_ms: u64,
    max_stdout_bytes: usize,
    max_stderr_bytes: usize,
    result: ports.CommandResult,
) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "argv", try dynamicStringArrayValue(allocator, argv));
    try obj.put(allocator, "cwd", try ownedString(allocator, cwd));
    try obj.put(allocator, "timeout_ms", .{ .integer = @intCast(timeout_ms) });
    try obj.put(allocator, "max_stdout_bytes", .{ .integer = @intCast(max_stdout_bytes) });
    try obj.put(allocator, "max_stderr_bytes", .{ .integer = @intCast(max_stderr_bytes) });
    try obj.put(allocator, "term", .{ .string = result.effectiveTerm().name() });
    if (result.effectiveTerm().exitCode()) |exit_code| try obj.put(allocator, "exit_code", .{ .integer = exit_code });
    try obj.put(allocator, "duration_ms", .{ .integer = @intCast(result.duration_ms) });
    try obj.put(allocator, "timed_out", .{ .bool = result.timed_out });
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    return .{ .object = obj };
}

fn executionRiskValue(allocator: std.mem.Allocator, allow_project_comptime: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "executes_backend", .{ .bool = true });
    try obj.put(allocator, "imports_project_modules", .{ .bool = false });
    try obj.put(allocator, "executes_build_zig", .{ .bool = false });
    try obj.put(allocator, "executes_target_binary", .{ .bool = false });
    try obj.put(allocator, "allow_project_comptime", .{ .bool = allow_project_comptime });
    try obj.put(allocator, "project_comptime_risk", .{ .string = if (allow_project_comptime) "opt-in: compiler may evaluate comptime code copied into the standalone declaration probe" else "default: declarations containing explicit comptime logic are skipped" });
    return .{ .object = obj };
}

fn parseTargets(allocator: std.mem.Allocator, raw: []const u8) !TargetList {
    var values: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }
    var parts = std.mem.tokenizeAny(u8, raw, ", \t\r\n");
    while (parts.next()) |part| {
        if (values.items.len >= max_targets) break;
        if (!validTargetToken(part)) continue;
        try values.append(allocator, try allocator.dupe(u8, part));
    }
    if (values.items.len == 0) try values.append(allocator, try allocator.dupe(u8, default_memory_targets));
    return .{ .values = try values.toOwnedSlice(allocator) };
}

fn validTargetToken(target: []const u8) bool {
    if (target.len == 0 or target.len > 96) return false;
    for (target) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.') continue;
        return false;
    }
    return true;
}

fn probePath(allocator: std.mem.Allocator, declaration: LayoutDeclaration, target: []const u8, probe_source: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(declaration.file);
    hasher.update(declaration.name);
    hasher.update(target);
    hasher.update(probe_source);
    const digest = hasher.final();
    const safe_name = try sanitizePathToken(allocator, declaration.name);
    defer allocator.free(safe_name);
    const safe_target = try sanitizePathToken(allocator, target);
    defer allocator.free(safe_target);
    return std.fmt.allocPrint(allocator, ".zigars-cache/abi-layout/{x}-{s}-{s}.zig", .{ digest, safe_name, safe_target });
}

fn sanitizePathToken(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, value.len);
    for (value, 0..) |ch, index| {
        out[index] = if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') ch else '_';
    }
    return out;
}

fn cacheDir(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext) ![]u8 {
    if (context.workspace.cache_root.len == 0) return allocator.dupe(u8, ".zigars-cache/abi-layout/cache");
    if (context.workspace.root.len > 0 and std.mem.startsWith(u8, context.workspace.cache_root, context.workspace.root)) {
        var relative = context.workspace.cache_root[context.workspace.root.len..];
        relative = std.mem.trimStart(u8, relative, "/\\");
        if (relative.len > 0) return std.fs.path.join(allocator, &.{ relative, "abi-layout", "cache" });
    }
    return allocator.dupe(u8, ".zigars-cache/abi-layout/cache");
}

fn versionStringFromValue(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const version = value.object.get("version") orelse return null;
    if (version != .string) return null;
    return version.string;
}

fn extractDeclarationSource(bytes: []const u8, start: usize) ?[]const u8 {
    const first_brace = std.mem.indexOfScalarPos(u8, bytes, start, '{') orelse return null;
    var depth: usize = 0;
    var index = first_brace;
    while (index < bytes.len) : (index += 1) {
        switch (bytes[index]) {
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) {
                    const semi = std.mem.indexOfScalarPos(u8, bytes, index, ';') orelse return null;
                    return bytes[start .. semi + 1];
                }
            },
            else => {},
        }
    }
    return null;
}

fn collectFieldNames(allocator: std.mem.Allocator, declaration: []const u8, include_fields: bool) ![]const []const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fields.items) |field| allocator.free(field);
        fields.deinit(allocator);
    }
    if (!include_fields) return fields.toOwnedSlice(allocator);
    const body_start = std.mem.indexOfScalar(u8, declaration, '{') orelse return fields.toOwnedSlice(allocator);
    const body_end = std.mem.lastIndexOfScalar(u8, declaration, '}') orelse return fields.toOwnedSlice(allocator);
    if (body_end <= body_start) return fields.toOwnedSlice(allocator);
    var lines = std.mem.splitScalar(u8, declaration[body_start + 1 .. body_end], '\n');
    while (lines.next()) |line| {
        const sanitized = try sanitizeCodeLine(allocator, line);
        defer allocator.free(sanitized);
        const trimmed = std.mem.trim(u8, sanitized, " \t\r,");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "pub ") or
            std.mem.startsWith(u8, trimmed, "const ") or
            std.mem.startsWith(u8, trimmed, "var ") or
            std.mem.startsWith(u8, trimmed, "fn ") or
            std.mem.startsWith(u8, trimmed, "comptime") or
            std.mem.startsWith(u8, trimmed, "usingnamespace")) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..colon], " \t\r");
        if (!validIdentifier(name)) continue;
        try fields.append(allocator, try allocator.dupe(u8, name));
    }
    return fields.toOwnedSlice(allocator);
}

fn declarationName(line: []const u8) ?[]const u8 {
    const const_pos = std.mem.indexOf(u8, line, "const ") orelse return null;
    const after_const = line[const_pos + "const ".len ..];
    const equals = std.mem.indexOfScalar(u8, after_const, '=') orelse return null;
    const name = std.mem.trim(u8, after_const[0..equals], " \t\r");
    if (!validIdentifier(name)) return null;
    return name;
}

fn validIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    if (!(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) return false;
    for (value[1..]) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') continue;
        return false;
    }
    return true;
}

fn sanitizeCodeLine(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, line.len);
    var in_string = false;
    var escaped = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (!in_string and i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
            @memset(out[i..], ' ');
            break;
        }
        if (line[i] == '"' and !escaped) {
            in_string = !in_string;
            out[i] = ' ';
            continue;
        }
        escaped = in_string and line[i] == '\\' and !escaped;
        out[i] = if (in_string) ' ' else line[i];
        if (line[i] != '\\') escaped = false;
    }
    return out;
}

fn layoutKind(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "extern struct") != null) return "extern_struct";
    if (std.mem.indexOf(u8, line, "packed struct") != null) return "packed_struct";
    if (std.mem.indexOf(u8, line, "extern union") != null) return "extern_union";
    if (std.mem.indexOf(u8, line, "packed union") != null) return "packed_union";
    if (std.mem.indexOf(u8, line, "extern enum") != null) return "extern_enum";
    if (std.mem.indexOf(u8, line, "packed enum") != null) return "packed_enum";
    if (std.mem.indexOf(u8, line, "struct") != null) return "struct";
    if (std.mem.indexOf(u8, line, "union") != null) return "union";
    if (std.mem.indexOf(u8, line, "enum") != null) return "enum";
    if (std.mem.indexOf(u8, line, "opaque") != null) return "opaque";
    return null;
}

fn abiLayoutKind(kind: []const u8) bool {
    return std.mem.startsWith(u8, kind, "extern") or std.mem.startsWith(u8, kind, "packed");
}

fn dynamicStringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(try ownedString(allocator, value));
    return .{ .array = array };
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

fn bounded(value: []const u8, limit: usize) []const u8 {
    return value[0..@min(value.len, limit)];
}

test "compile-log parser extracts layout numbers" {
    const stderr =
        \\Compile Log Output:
        \\@as(*const [20:0]u8, "zigars:decl:Foo:size"), @as(comptime_int, 16)
        \\@as(*const [21:0]u8, "zigars:decl:Foo:align"), @as(comptime_int, 8)
    ;
    try std.testing.expectEqual(@as(?u64, 16), parseCompileLogValue(stderr, "zigars:decl:Foo:size"));
    try std.testing.expectEqual(@as(?u64, 8), parseCompileLogValue(stderr, "zigars:decl:Foo:align"));
}

test "declaration extraction captures fields and skips imports" {
    var declarations: std.ArrayList(LayoutDeclaration) = .empty;
    defer {
        for (declarations.items) |declaration| declaration.deinit(std.testing.allocator);
        declarations.deinit(std.testing.allocator);
    }
    try appendDeclarations(std.testing.allocator, &declarations, "src/layout.zig",
        \\pub const Header = extern struct {
        \\    tag: u8,
        \\    payload: u64,
        \\};
        \\pub const Imported = extern struct { dep: @import("dep.zig").T };
    , 10, true);
    try std.testing.expectEqual(@as(usize, 2), declarations.items.len);
    try std.testing.expectEqualStrings("Header", declarations.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), declarations.items[0].fields.len);
    try std.testing.expect(unsupportedReason(declarations.items[1], false) != null);
}

test "probe source is standalone and records offset measurements" {
    const fields = try std.testing.allocator.alloc([]const u8, 2);
    fields[0] = try std.testing.allocator.dupe(u8, "tag");
    fields[1] = try std.testing.allocator.dupe(u8, "payload");
    const declaration = LayoutDeclaration{
        .file = try std.testing.allocator.dupe(u8, "src/layout.zig"),
        .line = 1,
        .name = try std.testing.allocator.dupe(u8, "Header"),
        .kind = "extern_struct",
        .source = try std.testing.allocator.dupe(u8,
            \\pub const Header = extern struct {
            \\    tag: u8,
            \\    payload: u64,
            \\};
        ),
        .fields = fields,
    };
    defer declaration.deinit(std.testing.allocator);
    const probe = try buildProbeSource(std.testing.allocator, declaration);
    defer std.testing.allocator.free(probe);
    try std.testing.expect(std.mem.indexOf(u8, probe, "@import(") == null);
    try std.testing.expect(std.mem.indexOf(u8, probe, "pub fn build") == null);
    try std.testing.expect(std.mem.indexOf(u8, probe, "@offsetOf(Header, \"payload\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, probe, "@bitOffsetOf(Header, \"payload\")") != null);
}
