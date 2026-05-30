//! Zig-specific developer-pain analyzers for migration, memory, safety, and
//! comptime review workflows.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const layout_probes = @import("layout_probes.zig");
const workspace_scans = @import("workspace_scans.zig");

/// Default scan limit for Phase 4 parser-backed analyzers.
pub const default_limit: usize = 200;
const max_source_read = workspace_scans.default_source_read_limit;

/// Workspace source scan request.
pub const SourceScanRequest = struct {
    path: ?[]const u8 = null,
    limit: usize = default_limit,
    measure: bool = false,
    targets: ?[]const u8 = null,
    allow_project_comptime: bool = false,
    timeout_ms: ?u64 = null,
};

/// Text or file-backed log analysis request.
pub const TextEvidenceRequest = struct {
    text: ?[]const u8 = null,
    path: ?[]const u8 = null,
    limit: usize = default_limit,
};

/// Comptime diagnostic request.
pub const ComptimeDiagnoseRequest = struct {
    text: ?[]const u8 = null,
    path: ?[]const u8 = null,
    diagnostic: ?[]const u8 = null,
    limit: usize = default_limit,
};

const SourceRecord = struct {
    file: []const u8,
    bytes: []const u8,

    fn deinit(self: SourceRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.bytes);
    }
};

const SourceSet = struct {
    sources: []SourceRecord,
    skipped_files: usize,
    partial_files: usize,

    fn deinit(self: SourceSet, allocator: std.mem.Allocator) void {
        for (self.sources) |source| source.deinit(allocator);
        allocator.free(self.sources);
    }
};

const IoMapping = struct {
    pattern: []const u8,
    replacement: []const u8,
    confidence: []const u8,
    note: []const u8,
};

/// Curated Zig 0.15 -> 0.16 std.io/std.Io migration table. Confidence is `exact`
/// for pure renames, `likely` where the shape usually changes, and `manual_review`
/// where buffer ownership or read/write strategy must be decided at the call site.
const io_mappings = [_]IoMapping{
    .{ .pattern = "std.io.getStdOut().writer()", .replacement = "std.fs.File.stdout().writer(&buffer)", .confidence = "likely", .note = "Zig 0.16 writer construction generally requires caller-owned buffers; verify the exact buffer lifetime." },
    .{ .pattern = "std.io.getStdErr().writer()", .replacement = "std.fs.File.stderr().writer(&buffer)", .confidence = "likely", .note = "stderr writer APIs moved toward std.Io/file-backed writers with explicit buffers." },
    .{ .pattern = "std.io.getStdIn().reader()", .replacement = "std.fs.File.stdin().reader(&buffer)", .confidence = "likely", .note = "stdin reader APIs moved toward std.Io/file-backed readers with explicit buffers." },
    .{ .pattern = "std.io.bufferedWriter", .replacement = "std.Io.Writer buffered/file writer APIs", .confidence = "manual_review", .note = "Buffered IO changed shape; migrate with the compiler and tests because buffer ownership is call-site specific." },
    .{ .pattern = "std.io.bufferedReader", .replacement = "std.Io.Reader buffered/file reader APIs", .confidence = "manual_review", .note = "Buffered reader migration depends on source lifetime and read strategy." },
    .{ .pattern = "std.io.fixedBufferStream", .replacement = "std.Io.Reader/Writer fixed-buffer helpers", .confidence = "manual_review", .note = "Fixed-buffer stream replacements depend on whether the call site reads, writes, or seeks." },
    .{ .pattern = "std.io.AnyWriter", .replacement = "std.Io.Writer", .confidence = "exact", .note = "The public type moved into the std.Io namespace." },
    .{ .pattern = "std.io.AnyReader", .replacement = "std.Io.Reader", .confidence = "exact", .note = "The public type moved into the std.Io namespace." },
    .{ .pattern = "std.io.Writer", .replacement = "std.Io.Writer", .confidence = "likely", .note = "Generic writer APIs changed; verify concrete aliases and buffer requirements." },
    .{ .pattern = "std.io.Reader", .replacement = "std.Io.Reader", .confidence = "likely", .note = "Generic reader APIs changed; verify concrete aliases and buffer requirements." },
};

/// Finds likely Zig 0.15 -> 0.16 IO migration sites without editing source.
pub fn ioMigrationScanValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: SourceScanRequest) ports.PortError!std.json.Value {
    var sources = try loadSources(allocator, context, request, "static_analysis.io_migration_scan");
    defer sources.deinit(allocator);

    var findings = std.json.Array.init(allocator);
    var exact_count: usize = 0;
    var likely_count: usize = 0;
    var manual_count: usize = 0;
    for (sources.sources) |source| {
        try appendIoFindings(allocator, &findings, source, request.limit, &exact_count, &likely_count, &manual_count);
        if (findings.items.len >= request.limit) break;
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_io_migration_scan" });
    try obj.put(allocator, "from_version", .{ .string = "0.15" });
    try obj.put(allocator, "to_version", .{ .string = "0.16" });
    try obj.put(allocator, "findings", .{ .array = findings });
    try obj.put(allocator, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try obj.put(allocator, "confidence_counts", try confidenceCountsValue(allocator, exact_count, likely_count, manual_count));
    try obj.put(allocator, "evidence_basis", .{ .string = "curated std.io/std.Io mapping table plus comment/string-masked source scan" });
    try obj.put(allocator, "suggested_verification_commands", try stringArrayValue(allocator, &.{ "zig fmt --check .", "zig build test", "zig build -Doptimize=ReleaseSafe" }));
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{
        "This is a migration-site catalog, not an automatic rewrite.",
        "Buffer ownership and concrete reader/writer types must be verified with compiler diagnostics.",
    }));
    try obj.put(allocator, "skipped_file_count", .{ .integer = @intCast(sources.skipped_files) });
    try obj.put(allocator, "partial_file_count", .{ .integer = @intCast(sources.partial_files) });
    return .{ .object = obj };
}

/// Parses GPA leak stderr and groups repeated allocation traces.
pub fn leakTriageValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: TextEvidenceRequest) ports.PortError!std.json.Value {
    const evidence = try loadTextEvidence(allocator, context, request, "static_analysis.leak_triage");
    defer allocator.free(evidence.text);

    var groups = std.json.Array.init(allocator);
    var leak_count: usize = 0;
    var malformed_count: usize = 0;
    try appendLeakGroups(allocator, &groups, evidence.text, request.limit, &leak_count, &malformed_count);

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_leak_triage" });
    try obj.put(allocator, "source", try ownedString(allocator, evidence.source));
    try obj.put(allocator, "leak_count", .{ .integer = @intCast(leak_count) });
    try obj.put(allocator, "group_count", .{ .integer = @intCast(groups.items.len) });
    try obj.put(allocator, "malformed_trace_count", .{ .integer = @intCast(malformed_count) });
    try obj.put(allocator, "groups", .{ .array = groups });
    try obj.put(allocator, "symbolizer_status", .{ .string = "unavailable" });
    try obj.put(allocator, "evidence_basis", .{ .string = "GPA leak stderr text; groups use repeated first Zig stack frame when present" });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{
        "No external symbolizer is executed by this parser-only tool.",
        "Optimized builds and stripped binaries can omit useful allocation frames.",
    }));
    return .{ .object = obj };
}

/// Diagnoses likely comptime failures from source snippets and compiler text.
pub fn comptimeDiagnoseValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: ComptimeDiagnoseRequest) ports.PortError!std.json.Value {
    const source_text: TextEvidence = if (request.text != null or request.path != null)
        try loadTextEvidence(allocator, context, .{ .text = request.text, .path = request.path, .limit = request.limit }, "static_analysis.comptime_diagnose")
    else
        TextEvidence{ .text = try allocator.dupe(u8, ""), .source = "none" };
    defer allocator.free(source_text.text);

    var findings = std.json.Array.init(allocator);
    if (request.diagnostic) |diagnostic| try appendComptimeDiagnosticFindings(allocator, &findings, diagnostic, request.limit);
    try appendComptimeSourceFindings(allocator, &findings, source_text.text, source_text.source, request.limit);

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_comptime_diagnose" });
    try obj.put(allocator, "analysis_mode", .{ .string = "parser_only" });
    try obj.put(allocator, "source", try ownedString(allocator, source_text.source));
    try obj.put(allocator, "findings", .{ .array = findings });
    try obj.put(allocator, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try obj.put(allocator, "runtime_tainted_operands", try runtimeTaintedOperandsValue(allocator, source_text.text, request.diagnostic));
    try obj.put(allocator, "likely_fixes", try stringArrayValue(allocator, &.{
        "Move runtime-only values out of comptime contexts or make the dependency an explicit comptime parameter.",
        "Prefer inline loops or comptime-known tables only when all operands are compile-time known.",
        "Use the compiler diagnostic location as the source of truth before applying a fix.",
    }));
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{
        "This tool does not execute compiler probes or evaluate comptime code.",
        "Parser-only evidence can identify likely causes but cannot prove Zig semantic requirements.",
    }));
    return .{ .object = obj };
}

/// Catalogs layout-sensitive declarations for review and optional ABI probing.
pub fn memoryLayoutValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: SourceScanRequest) ports.PortError!std.json.Value {
    var sources = try loadSources(allocator, context, request, "static_analysis.memory_layout");
    defer sources.deinit(allocator);

    var candidates = std.json.Array.init(allocator);
    for (sources.sources) |source| {
        try appendMemoryLayoutCandidates(allocator, &candidates, source, request.limit);
        if (candidates.items.len >= request.limit) break;
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_memory_layout" });
    try obj.put(allocator, "analysis_mode", .{ .string = "parser_backed_line_catalog" });
    try obj.put(allocator, "candidates", .{ .array = candidates });
    try obj.put(allocator, "candidate_count", .{ .integer = @intCast(candidates.items.len) });
    try obj.put(allocator, "probe_status", .{ .string = "not_executed" });
    try obj.put(allocator, "measurement_mode", .{ .string = if (request.measure) "requested" else "parser_only" });
    try obj.put(allocator, "evidence_basis", .{ .string = "comment/string-masked source scan for struct, union, enum, opaque, packed, and extern layout declarations" });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{
        "Layout candidates are source declarations; actual size, alignment, and offsets require compiler probes for a concrete target.",
        "Nested anonymous container declarations may need manual review.",
    }));
    try obj.put(allocator, "skipped_file_count", .{ .integer = @intCast(sources.skipped_files) });
    if (request.measure) {
        const declarations = try collectLayoutProbeDeclarations(allocator, sources, request.limit, false);
        defer declarations.deinit(allocator);
        const evidence = try layout_probes.compilerEvidenceValue(allocator, context, declarations.declarations, .{
            .tool_name = "zig_memory_layout",
            .targets = request.targets,
            .timeout_ms = request.timeout_ms orelse normalizedTimeout(context.timeouts.command_ms),
            .allow_project_comptime = request.allow_project_comptime,
            .compare_targets = false,
        });
        try attachCompilerEvidence(allocator, &obj, evidence, false);
    }
    return .{ .object = obj };
}

/// Catalogs unsafe or boundary-sensitive Zig operations for review.
pub fn unsafeOperationsAuditValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: SourceScanRequest) ports.PortError!std.json.Value {
    var sources = try loadSources(allocator, context, request, "static_analysis.unsafe_operations_audit");
    defer sources.deinit(allocator);

    var operations = std.json.Array.init(allocator);
    var high: usize = 0;
    var medium: usize = 0;
    for (sources.sources) |source| {
        try appendUnsafeOperations(allocator, &operations, source, request.limit, &high, &medium);
        if (operations.items.len >= request.limit) break;
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_unsafe_operations_audit" });
    try obj.put(allocator, "operations", .{ .array = operations });
    try obj.put(allocator, "operation_count", .{ .integer = @intCast(operations.items.len) });
    try obj.put(allocator, "high_severity_count", .{ .integer = @intCast(high) });
    try obj.put(allocator, "medium_severity_count", .{ .integer = @intCast(medium) });
    try obj.put(allocator, "evidence_basis", .{ .string = "comment/string-masked line scan for unsafe builtins, unreachable paths, runtime-safety toggles, packed/extern boundaries, volatile, and anyopaque" });
    try obj.put(allocator, "recommended_cross_checks", try stringArrayValue(allocator, &.{ "zig_safety_site_catalog", "zig build test", "code review at FFI and pointer boundaries" }));
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{
        "The audit is a review catalog and does not prove an operation is incorrect.",
        "Semantic safety depends on invariants that may live outside the matched line.",
    }));
    return .{ .object = obj };
}

/// Produces a bounded ABI layout probe plan without executing compiler probes.
pub fn abiLayoutDiffValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: SourceScanRequest) ports.PortError!std.json.Value {
    var sources = try loadSources(allocator, context, request, "static_analysis.abi_layout_diff");
    defer sources.deinit(allocator);

    var probes = std.json.Array.init(allocator);
    for (sources.sources) |source| {
        try appendAbiProbePlans(allocator, &probes, source, request.limit);
        if (probes.items.len >= request.limit) break;
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_abi_layout_diff" });
    try obj.put(allocator, "analysis_mode", .{ .string = "probe_plan_only" });
    try obj.put(allocator, "backend_status", .{ .string = "compiler_probe_not_executed" });
    try obj.put(allocator, "measurement_mode", .{ .string = if (request.measure) "requested" else "parser_only" });
    try obj.put(allocator, "probes", .{ .array = probes });
    try obj.put(allocator, "probe_count", .{ .integer = @intCast(probes.items.len) });
    try obj.put(allocator, "cache_layout", .{ .string = ".zigars-cache/abi-layout/<probe-id>.zig plus .zigars-cache/abi-layout/cache when compiler probing is enabled" });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{
        "Parser-only mode does not execute compiler probes.",
        "Actual ABI differences require concrete target pairs and generated @sizeOf/@alignOf/@offsetOf/@bitOffsetOf code.",
    }));
    if (request.measure) {
        const declarations = try collectLayoutProbeDeclarations(allocator, sources, request.limit, true);
        defer declarations.deinit(allocator);
        const evidence = try layout_probes.compilerEvidenceValue(allocator, context, declarations.declarations, .{
            .tool_name = "zig_abi_layout_diff",
            .targets = request.targets,
            .timeout_ms = request.timeout_ms orelse normalizedTimeout(context.timeouts.command_ms),
            .allow_project_comptime = request.allow_project_comptime,
            .compare_targets = true,
        });
        try attachCompilerEvidence(allocator, &obj, evidence, true);
    }
    return .{ .object = obj };
}

const TextEvidence = struct {
    text: []u8,
    source: []const u8,
};

fn loadTextEvidence(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: TextEvidenceRequest, provenance: []const u8) ports.PortError!TextEvidence {
    if (request.text) |text| return .{ .text = try allocator.dupe(u8, text), .source = "inline_text" };
    const path = request.path orelse return .{ .text = try allocator.dupe(u8, ""), .source = "empty" };
    const read = try context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = max_source_read,
        .provenance = provenance,
    });
    defer read.deinit(allocator);
    return .{ .text = try allocator.dupe(u8, read.bytes), .source = path };
}

fn loadSources(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: SourceScanRequest, provenance: []const u8) ports.PortError!SourceSet {
    if (request.path) |path| {
        if (std.mem.endsWith(u8, path, ".zig")) {
            const read = try context.workspace_store.read(allocator, .{
                .path = path,
                .max_bytes = max_source_read,
                .provenance = provenance,
            });
            defer read.deinit(allocator);
            const source = SourceRecord{
                .file = try allocator.dupe(u8, path),
                .bytes = try allocator.dupe(u8, read.bytes),
            };
            const slice = try allocator.alloc(SourceRecord, 1);
            slice[0] = source;
            return .{ .sources = slice, .skipped_files = 0, .partial_files = 0 };
        }
    }

    var scan = try context.workspace_scanner.scanZigFiles(allocator, .{
        .path_prefix = request.path orelse "",
        .max_files = @max(request.limit, 1),
        .provenance = provenance,
    });
    defer scan.deinit(allocator);

    var sources: std.ArrayList(SourceRecord) = .empty;
    var skipped: usize = 0;
    errdefer {
        for (sources.items) |source| source.deinit(allocator);
        sources.deinit(allocator);
    }

    for (scan.files) |file| {
        const read = context.workspace_store.read(allocator, .{
            .path = file.path,
            .max_bytes = max_source_read,
            .provenance = provenance,
        }) catch {
            skipped += 1;
            continue;
        };
        defer read.deinit(allocator);
        try sources.append(allocator, .{
            .file = try allocator.dupe(u8, file.path),
            .bytes = try allocator.dupe(u8, read.bytes),
        });
    }

    return .{
        .sources = try sources.toOwnedSlice(allocator),
        .skipped_files = skipped,
        .partial_files = 0,
    };
}

fn appendIoFindings(allocator: std.mem.Allocator, findings: *std.json.Array, source: SourceRecord, limit: usize, exact_count: *usize, likely_count: *usize, manual_count: *usize) !void {
    var lines = std.mem.splitScalar(u8, source.bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (findings.items.len >= limit) return;
        const sanitized = try sanitizeCodeLine(allocator, line);
        defer allocator.free(sanitized);
        for (io_mappings) |mapping| {
            if (std.mem.indexOf(u8, sanitized, mapping.pattern) == null) continue;
            if (std.mem.eql(u8, mapping.confidence, "exact")) exact_count.* += 1 else if (std.mem.eql(u8, mapping.confidence, "likely")) likely_count.* += 1 else manual_count.* += 1;
            var item = std.json.ObjectMap.empty;
            try item.put(allocator, "file", try ownedString(allocator, source.file));
            try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
            try item.put(allocator, "pattern", try ownedString(allocator, mapping.pattern));
            try item.put(allocator, "suggested_replacement", try ownedString(allocator, mapping.replacement));
            try item.put(allocator, "confidence", .{ .string = mapping.confidence });
            try item.put(allocator, "note", .{ .string = mapping.note });
            try item.put(allocator, "text", try ownedString(allocator, std.mem.trim(u8, line, " \t")));
            try findings.append(.{ .object = item });
            break;
        }
    }
}

fn appendLeakGroups(allocator: std.mem.Allocator, groups: *std.json.Array, text: []const u8, limit: usize, leak_count: *usize, malformed_count: *usize) !void {
    var current_key: ?[]const u8 = null;
    var current_count: usize = 0;
    var current_frames = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (isLeakStart(trimmed)) {
            if (current_key != null) try flushLeakGroup(allocator, groups, current_key.?, current_count, current_frames);
            leak_count.* += 1;
            current_key = "unresolved allocation site";
            current_count = 1;
            current_frames = std.json.Array.init(allocator);
            continue;
        }
        if (current_key == null) continue;
        if (std.mem.indexOf(u8, trimmed, ".zig:") != null) {
            if (std.mem.eql(u8, current_key.?, "unresolved allocation site")) current_key = try allocator.dupe(u8, trimmed);
            if (current_frames.items.len < 8) try current_frames.append(try ownedString(allocator, trimmed));
        }
    }
    if (current_key != null) try flushLeakGroup(allocator, groups, current_key.?, current_count, current_frames);
    if (leak_count.* == 0 and std.mem.indexOf(u8, text, ".zig:") != null) malformed_count.* += 1;
    if (groups.items.len > limit) groups.items.len = limit;
}

fn flushLeakGroup(allocator: std.mem.Allocator, groups: *std.json.Array, key: []const u8, count: usize, frames: std.json.Array) !void {
    for (groups.items) |*existing| {
        if (existing.* != .object) continue;
        const existing_key = existing.object.get("allocation_site") orelse continue;
        if (existing_key != .string or !std.mem.eql(u8, existing_key.string, key)) continue;
        const old = existing.object.get("count").?.integer;
        try existing.object.put(allocator, "count", .{ .integer = old + @as(i64, @intCast(count)) });
        return;
    }
    var item = std.json.ObjectMap.empty;
    try item.put(allocator, "allocation_site", try ownedString(allocator, key));
    try item.put(allocator, "count", .{ .integer = @intCast(count) });
    try item.put(allocator, "frames", .{ .array = frames });
    try item.put(allocator, "confidence", .{ .string = if (std.mem.eql(u8, key, "unresolved allocation site")) "low" else "medium" });
    try groups.append(.{ .object = item });
}

fn appendComptimeDiagnosticFindings(allocator: std.mem.Allocator, findings: *std.json.Array, diagnostic: []const u8, limit: usize) !void {
    var lines = std.mem.splitScalar(u8, diagnostic, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (findings.items.len >= limit) return;
        const cause = comptimeDiagnosticCause(line) orelse continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "source", .{ .string = "compiler_diagnostic_text" });
        try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
        try item.put(allocator, "likely_cause", .{ .string = cause });
        try item.put(allocator, "confidence", .{ .string = "medium" });
        try item.put(allocator, "text", try ownedString(allocator, std.mem.trim(u8, line, " \t\r")));
        try findings.append(.{ .object = item });
    }
}

fn appendComptimeSourceFindings(allocator: std.mem.Allocator, findings: *std.json.Array, text: []const u8, source: []const u8, limit: usize) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (findings.items.len >= limit) return;
        const sanitized = try sanitizeCodeLine(allocator, line);
        defer allocator.free(sanitized);
        const cause = comptimeSourceCause(sanitized) orelse continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "source", try ownedString(allocator, source));
        try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
        try item.put(allocator, "likely_cause", .{ .string = cause });
        try item.put(allocator, "confidence", .{ .string = "low" });
        try item.put(allocator, "text", try ownedString(allocator, std.mem.trim(u8, line, " \t")));
        try findings.append(.{ .object = item });
    }
}

fn appendMemoryLayoutCandidates(allocator: std.mem.Allocator, candidates: *std.json.Array, source: SourceRecord, limit: usize) !void {
    var lines = std.mem.splitScalar(u8, source.bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (candidates.items.len >= limit) return;
        const sanitized = try sanitizeCodeLine(allocator, line);
        defer allocator.free(sanitized);
        const kind = layoutKind(sanitized) orelse continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try ownedString(allocator, source.file));
        try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
        try item.put(allocator, "kind", .{ .string = kind });
        try item.put(allocator, "layout_sensitivity", .{ .string = layoutSensitivity(kind) });
        try item.put(allocator, "probe_recommendation", .{ .string = "probe @sizeOf, @alignOf, and field @offsetOf for concrete target triples before ABI claims" });
        try item.put(allocator, "text", try ownedString(allocator, std.mem.trim(u8, line, " \t")));
        try candidates.append(.{ .object = item });
    }
}

fn appendUnsafeOperations(allocator: std.mem.Allocator, operations: *std.json.Array, source: SourceRecord, limit: usize, high: *usize, medium: *usize) !void {
    var lines = std.mem.splitScalar(u8, source.bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (operations.items.len >= limit) return;
        const sanitized = try sanitizeCodeLine(allocator, line);
        defer allocator.free(sanitized);
        const kind = unsafeKind(sanitized) orelse continue;
        const severity = unsafeSeverity(kind);
        if (std.mem.eql(u8, severity, "high")) high.* += 1 else medium.* += 1;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try ownedString(allocator, source.file));
        try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
        try item.put(allocator, "kind", .{ .string = kind });
        try item.put(allocator, "severity", .{ .string = severity });
        try item.put(allocator, "review_prompt", .{ .string = unsafeReviewPrompt(kind) });
        try item.put(allocator, "text", try ownedString(allocator, std.mem.trim(u8, line, " \t")));
        try operations.append(.{ .object = item });
    }
}

fn appendAbiProbePlans(allocator: std.mem.Allocator, probes: *std.json.Array, source: SourceRecord, limit: usize) !void {
    var lines = std.mem.splitScalar(u8, source.bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (probes.items.len >= limit) return;
        const sanitized = try sanitizeCodeLine(allocator, line);
        defer allocator.free(sanitized);
        const kind = layoutKind(sanitized) orelse continue;
        if (!std.mem.eql(u8, kind, "extern_struct") and !std.mem.eql(u8, kind, "packed_struct") and !std.mem.eql(u8, kind, "extern_union") and !std.mem.eql(u8, kind, "packed_union")) continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try ownedString(allocator, source.file));
        try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
        try item.put(allocator, "kind", .{ .string = kind });
        try item.put(allocator, "planned_measurements", try stringArrayValue(allocator, &.{ "@sizeOf", "@alignOf", "@offsetOf for named fields", "@bitOffsetOf for packed/bit-sensitive fields" }));
        try item.put(allocator, "argv_shape", try stringArrayValue(allocator, &.{ "zig", "build-obj", ".zigars-cache/abi-layout/<probe>.zig", "-target", "<target>", "-fno-emit-bin", "--cache-dir", ".zigars-cache/abi-layout/cache" }));
        try item.put(allocator, "text", try ownedString(allocator, std.mem.trim(u8, line, " \t")));
        try probes.append(.{ .object = item });
    }
}

fn collectLayoutProbeDeclarations(allocator: std.mem.Allocator, sources: SourceSet, limit: usize, abi_only: bool) !layout_probes.DeclarationSet {
    var declarations: std.ArrayList(layout_probes.LayoutDeclaration) = .empty;
    errdefer {
        for (declarations.items) |declaration| declaration.deinit(allocator);
        declarations.deinit(allocator);
    }
    for (sources.sources) |source| {
        try layout_probes.appendDeclarations(allocator, &declarations, source.file, source.bytes, limit, abi_only);
        if (declarations.items.len >= limit) break;
    }
    return .{ .declarations = try declarations.toOwnedSlice(allocator) };
}

fn attachCompilerEvidence(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, evidence: std.json.Value, abi_diff: bool) !void {
    if (evidence == .object) {
        if (evidence.object.get("backend_status")) |status| if (status == .string) {
            try obj.put(allocator, if (abi_diff) "backend_status" else "probe_status", .{ .string = status.string });
        };
        if (evidence.object.get("measurement_mode")) |mode| if (mode == .string) {
            try obj.put(allocator, "measurement_mode", .{ .string = mode.string });
        };
        if (evidence.object.get("measurement_count")) |count| try obj.put(allocator, "measurement_count", count);
        if (evidence.object.get("unsupported_count")) |count| try obj.put(allocator, "unsupported_count", count);
        if (abi_diff) {
            if (evidence.object.get("layout_differences")) |differences| try obj.put(allocator, "layout_differences", differences);
            if (evidence.object.get("unchanged_layouts")) |unchanged| try obj.put(allocator, "unchanged_layouts", unchanged);
        }
    }
    try obj.put(allocator, "compiler_evidence", evidence);
}

fn normalizedTimeout(timeout_ms: i64) u64 {
    return @intCast(@max(1, @min(timeout_ms, 60 * 60 * 1000)));
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

fn isLeakStart(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "leaked") != null and
        (std.mem.indexOf(u8, line, "memory address") != null or std.mem.indexOf(u8, line, "error(gpa)") != null);
}

fn comptimeDiagnosticCause(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "unable to resolve comptime value") != null) return "runtime-known value required in comptime-known position";
    if (std.mem.indexOf(u8, line, "must be comptime-known") != null) return "operand or type parameter is not comptime-known";
    if (std.mem.indexOf(u8, line, "depends on runtime control flow") != null) return "comptime expression depends on runtime control flow";
    if (std.mem.indexOf(u8, line, "comptime call") != null) return "called function cannot be evaluated at comptime";
    return null;
}

fn comptimeSourceCause(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "comptime ") != null and std.mem.indexOf(u8, line, "var ") != null) return "mutable comptime state may depend on runtime-fed values";
    if (std.mem.indexOf(u8, line, "inline for") != null or std.mem.indexOf(u8, line, "inline while") != null) return "inline loop requires comptime-known iteration shape";
    if (std.mem.indexOf(u8, line, "@field(") != null or std.mem.indexOf(u8, line, "@hasDecl(") != null) return "reflection builtin requires comptime-known type/name operands";
    if (std.mem.indexOf(u8, line, "@TypeOf(") != null or std.mem.indexOf(u8, line, "@typeInfo(") != null) return "type reflection result may force comptime-known operands";
    return null;
}

fn runtimeTaintedOperandsValue(allocator: std.mem.Allocator, source: []const u8, diagnostic: ?[]const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    if (diagnostic) |text| {
        if (std.mem.indexOf(u8, text, "runtime") != null) try array.append(.{ .string = "compiler diagnostic mentions runtime dependency" });
    }
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "var ") != null and std.mem.indexOf(u8, line, "comptime") == null) {
            try array.append(.{ .string = "runtime var near comptime-sensitive source snippet" });
            break;
        }
    }
    return .{ .array = array };
}

fn layoutKind(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "extern struct") != null) return "extern_struct";
    if (std.mem.indexOf(u8, line, "packed struct") != null) return "packed_struct";
    if (std.mem.indexOf(u8, line, "extern union") != null) return "extern_union";
    if (std.mem.indexOf(u8, line, "packed union") != null) return "packed_union";
    if (std.mem.indexOf(u8, line, "struct") != null) return "struct";
    if (std.mem.indexOf(u8, line, "union") != null) return "union";
    if (std.mem.indexOf(u8, line, "enum") != null) return "enum";
    if (std.mem.indexOf(u8, line, "opaque") != null) return "opaque";
    return null;
}

fn layoutSensitivity(kind: []const u8) []const u8 {
    if (std.mem.startsWith(u8, kind, "extern") or std.mem.startsWith(u8, kind, "packed")) return "high";
    if (std.mem.eql(u8, kind, "opaque")) return "ffi_boundary";
    return "target_dependent";
}

fn unsafeKind(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "@setRuntimeSafety(false)") != null) return "runtime_safety_disabled";
    if (std.mem.indexOf(u8, line, "catch unreachable") != null) return "catch_unreachable";
    if (std.mem.indexOf(u8, line, "unreachable") != null) return "unreachable";
    if (std.mem.indexOf(u8, line, "@ptrCast(") != null) return "ptr_cast";
    if (std.mem.indexOf(u8, line, "@alignCast(") != null) return "align_cast";
    if (std.mem.indexOf(u8, line, "@bitCast(") != null) return "bit_cast";
    if (std.mem.indexOf(u8, line, "@intFromPtr(") != null or std.mem.indexOf(u8, line, "@ptrFromInt(") != null) return "pointer_integer_cast";
    if (std.mem.indexOf(u8, line, "@enumFromInt(") != null or std.mem.indexOf(u8, line, "@truncate(") != null) return "unchecked_integer_cast";
    if (std.mem.indexOf(u8, line, "allowzero") != null) return "allowzero_pointer";
    if (std.mem.indexOf(u8, line, "volatile") != null) return "volatile_boundary";
    if (std.mem.indexOf(u8, line, "anyopaque") != null) return "opaque_pointer_boundary";
    if (std.mem.indexOf(u8, line, "extern ") != null) return "extern_boundary";
    if (std.mem.indexOf(u8, line, "packed struct") != null or std.mem.indexOf(u8, line, "packed union") != null) return "packed_layout_boundary";
    return null;
}

fn unsafeSeverity(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "runtime_safety_disabled") or
        std.mem.eql(u8, kind, "pointer_integer_cast") or
        std.mem.eql(u8, kind, "ptr_cast") or
        std.mem.eql(u8, kind, "catch_unreachable")) return "high";
    return "medium";
}

fn unsafeReviewPrompt(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "runtime_safety_disabled")) return "Confirm why runtime safety is disabled and whether tests cover the unsafe region.";
    if (std.mem.eql(u8, kind, "ptr_cast") or std.mem.eql(u8, kind, "align_cast")) return "Verify pointer provenance, alignment, lifetime, and aliasing invariants.";
    if (std.mem.eql(u8, kind, "extern_boundary")) return "Verify ABI, ownership, and error contracts at the foreign boundary.";
    return "Review the local invariant that makes this operation safe.";
}

fn confidenceCountsValue(allocator: std.mem.Allocator, exact: usize, likely: usize, manual: usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exact", .{ .integer = @intCast(exact) });
    try obj.put(allocator, "likely", .{ .integer = @intCast(likely) });
    try obj.put(allocator, "manual_review", .{ .integer = @intCast(manual) });
    return .{ .object = obj };
}

fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

const fakes = @import("../../../testing/fakes/root.zig");

test "io migration scan masks comments and strings" {
    var fake_scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer fake_scanner.deinit();
    var fake_workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer fake_workspace.deinit();

    try fake_scanner.expectScan(.{ .path_prefix = "", .max_files = 10, .provenance = "static_analysis.io_migration_scan" }, &.{"src/main.zig"});
    try fake_workspace.expectRead(.{ .path = "src/main.zig", .max_bytes = max_source_read, .provenance = "static_analysis.io_migration_scan" },
        \\// std.io.AnyWriter
        \\const msg = "std.io.AnyReader";
        \\const Writer = std.io.AnyWriter;
    );

    const ctx = app_context.StaticAnalysisContext{
        .workspace = .{ .root = "/workspace" },
        .workspace_store = fake_workspace.port(),
        .workspace_scanner = fake_scanner.port(),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try ioMigrationScanValue(arena.allocator(), ctx, .{ .limit = 10 });
    try std.testing.expectEqual(@as(i64, 1), value.object.get("finding_count").?.integer);
    try std.testing.expectEqualStrings("exact", value.object.get("findings").?.array.items[0].object.get("confidence").?.string);
}

test "leak triage groups GPA traces by first Zig frame" {
    var fake_workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer fake_workspace.deinit();
    var fake_scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer fake_scanner.deinit();
    const ctx = app_context.StaticAnalysisContext{
        .workspace = .{ .root = "/workspace" },
        .workspace_store = fake_workspace.port(),
        .workspace_scanner = fake_scanner.port(),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try leakTriageValue(arena.allocator(), ctx, .{
        .text =
        \\error(gpa): memory address 0x1 leaked:
        \\    /workspace/src/a.zig:10:5: 0xabc in make (test)
        \\error(gpa): memory address 0x2 leaked:
        \\    /workspace/src/a.zig:10:5: 0xabc in make (test)
        ,
        .limit = 10,
    });
    try std.testing.expectEqual(@as(i64, 2), value.object.get("leak_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), value.object.get("group_count").?.integer);
}

test "unsafe audit ignores comments and reports ptr casts" {
    var fake_scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer fake_scanner.deinit();
    var fake_workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer fake_workspace.deinit();

    try fake_scanner.expectScan(.{ .path_prefix = "", .max_files = 10, .provenance = "static_analysis.unsafe_operations_audit" }, &.{"src/main.zig"});
    try fake_workspace.expectRead(.{ .path = "src/main.zig", .max_bytes = max_source_read, .provenance = "static_analysis.unsafe_operations_audit" },
        \\// @ptrCast(foo)
        \\const text = "@alignCast(foo)";
        \\const p: *T = @ptrCast(raw);
    );

    const ctx = app_context.StaticAnalysisContext{
        .workspace = .{ .root = "/workspace" },
        .workspace_store = fake_workspace.port(),
        .workspace_scanner = fake_scanner.port(),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try unsafeOperationsAuditValue(arena.allocator(), ctx, .{ .limit = 10 });
    try std.testing.expectEqual(@as(i64, 1), value.object.get("operation_count").?.integer);
    try std.testing.expectEqualStrings("ptr_cast", value.object.get("operations").?.array.items[0].object.get("kind").?.string);
}
