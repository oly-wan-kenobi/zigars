//! Semantic index use-case around symbol/reference extraction with cache and tool boundaries.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const zig_analysis = @import("../../../domain/zig/analysis.zig");

pub const semantic_format_version = 1;
pub const default_limit: usize = 500;
pub const default_source_read_limit: usize = 512 * 1024;

pub const SemanticError = ports.PortError || error{
    MissingCachePort,
    MissingCommandRunner,
    InvalidCache,
};

pub const IndexRequest = struct {
    limit: usize = default_limit,
    refresh: bool = false,
    tool_name: []const u8 = "zig_semantic_index_build",
};

pub const QueryRequest = struct {
    query: []const u8,
    kind: ?[]const u8 = null,
    index_limit: usize = default_limit,
    match_limit: usize = 50,
    refresh: bool = false,
};

pub const DeclRequest = struct {
    symbol: []const u8,
    index_limit: usize = default_limit,
    match_limit: usize = 20,
    refresh: bool = false,
};

pub const SourceRefsRequest = struct {
    symbol: []const u8,
    calls_only: bool = false,
    limit: usize = 100,
    timeout_ms: ?u64 = null,
};

pub const FusionRequest = struct {
    query: []const u8,
    index_limit: usize = default_limit,
    match_limit: usize = 20,
    zlint_findings: ?[]const u8 = null,
    zwanzig_findings: ?[]const u8 = null,
};

pub const ExportRequest = struct {
    tool_name: []const u8,
    format: []const u8,
    output: []const u8,
    limit: usize = default_limit,
    apply: bool = false,
    refresh: bool = false,
};

pub const IndexResult = struct {
    value: std.json.Value,
    cache: ports.StaticCacheStatus,
};

const ParseStats = struct {
    partial_result: bool,
    parse_error_count: i64,
};

pub fn status(context: app_context.StaticAnalysisContext) SemanticError!ports.StaticCacheStatus {
    const cache = context.semantic_index_cache orelse return error.MissingCachePort;
    return cache.status();
}

pub fn buildIndex(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: IndexRequest) SemanticError!IndexResult {
    const cache = context.semantic_index_cache orelse return error.MissingCachePort;
    const normalized_limit = @max(request.limit, 1);
    const signature = try semanticSignature(allocator, context, normalized_limit);
    const current = try cache.status();
    if (!request.refresh and current.cached and current.signature == signature) {
        const loaded = try cache.load(allocator);
        if (loaded.bytes) |bytes| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidCache;
            const hit = try cache.recordHit();
            return .{ .value = parsed.value, .cache = hit };
        }
    }

    const value = try semanticIndexValue(allocator, context, normalized_limit, request.tool_name);
    const bytes = try serializeAlloc(allocator, value);
    defer allocator.free(bytes);
    const stored = try cache.store(allocator, .{
        .signature = signature,
        .bytes = bytes,
        .provenance = "static_analysis.semantic_index",
    });
    return .{ .value = value, .cache = stored };
}

pub fn query(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: QueryRequest) SemanticError!std.json.Value {
    const index = try buildIndex(allocator, context, .{ .limit = request.index_limit, .refresh = request.refresh, .tool_name = "zig_semantic_query" });
    const matches = try semanticMatchesValue(allocator, index.value, request.query, request.kind, @max(request.match_limit, 1));
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_semantic_query" });
    try obj.put(allocator, "query", try ownedString(allocator, request.query));
    try obj.put(allocator, "matches", matches);
    return .{ .object = obj };
}

pub fn decl(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: DeclRequest) SemanticError!std.json.Value {
    const index = try buildIndex(allocator, context, .{ .limit = request.index_limit, .refresh = request.refresh, .tool_name = "zig_semantic_decl" });
    const matches = try semanticMatchesValue(allocator, index.value, request.symbol, "declaration", @max(request.match_limit, 1));
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_semantic_decl" });
    try obj.put(allocator, "symbol", try ownedString(allocator, request.symbol));
    try obj.put(allocator, "declarations", matches);
    return .{ .object = obj };
}

pub fn sourceRefs(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: SourceRefsRequest) SemanticError!std.json.Value {
    var matches = std.json.Array.init(allocator);
    var scan = try context.workspace_scanner.scanZigFiles(allocator, .{
        .max_files = null,
        .provenance = "static_analysis.semantic_refs",
    });
    defer scan.deinit(allocator);

    var zlint_ast_files: usize = 0;
    var zlint_ast_failures: usize = 0;
    var zlint_disabled = false;

    for (scan.files) |file| {
        if (matches.items.len >= request.limit) break;
        const read = context.workspace_store.read(allocator, .{
            .path = file.path,
            .max_bytes = default_source_read_limit,
            .provenance = "static_analysis.semantic_refs",
        }) catch continue;
        defer read.deinit(allocator);

        var zlint_confirmed = false;
        if (!zlint_disabled and std.mem.indexOf(u8, read.bytes, request.symbol) != null) {
            zlint_confirmed = zlintAstSymbolHasReferenceForFile(allocator, context, request, file.path) catch blk: {
                zlint_ast_failures += 1;
                zlint_disabled = true;
                break :blk false;
            };
            if (!zlint_disabled) zlint_ast_files += 1;
        }

        var lines = std.mem.splitScalar(u8, read.bytes, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            if (matches.items.len >= request.limit) break;
            if (std.mem.indexOf(u8, line, request.symbol) == null) continue;
            if (request.calls_only and std.mem.indexOf(u8, line, "(") == null) continue;
            if (request.calls_only and zig_analysis.declKind(std.mem.trim(u8, line, " \t")) != null) continue;
            var item = std.json.ObjectMap.empty;
            try item.put(allocator, "file", try ownedString(allocator, file.path));
            try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
            try item.put(allocator, "text", try ownedString(allocator, std.mem.trim(u8, line, " \t")));
            try item.put(allocator, "location", try locationValue(allocator, file.path, line_no, 1));
            try item.put(allocator, "source", .{ .string = if (zlint_confirmed) "zlint" else "heuristic" });
            try item.put(allocator, "confidence", .{ .string = if (zlint_confirmed) "high" else "medium" });
            try item.put(allocator, "semantic_confirmed", .{ .bool = zlint_confirmed });
            if (zlint_confirmed) try item.put(allocator, "semantic_backend", .{ .string = "zlint --print-ast" });
            try matches.append(.{ .object = item });
        }
    }

    const tool_name = if (request.calls_only) "zig_semantic_callers" else "zig_semantic_refs";
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "symbol", try ownedString(allocator, request.symbol));
    try obj.put(allocator, if (request.calls_only) "callers" else "references", .{ .array = matches });
    try obj.put(allocator, "count", .{ .integer = @intCast(matches.items.len) });
    try obj.put(allocator, "zlint_ast_files", .{ .integer = @intCast(zlint_ast_files) });
    try obj.put(allocator, "zlint_ast_failures", .{ .integer = @intCast(zlint_ast_failures) });
    try obj.put(allocator, "evidence_sources", try stringArrayValue(allocator, if (zlint_ast_files > 0) &.{ "zlint", "heuristic" } else &.{"heuristic"}));
    return .{ .object = obj };
}

pub fn staticFusion(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: FusionRequest) SemanticError!std.json.Value {
    const index = try buildIndex(allocator, context, .{ .limit = request.index_limit, .tool_name = "zig_static_fusion" });
    const matches = try semanticMatchesValue(allocator, index.value, request.query, null, @max(request.match_limit, 1));
    const zlint_findings = if (request.zlint_findings) |text| normalizeFindingsText(allocator, text, "zlint") catch return error.InvalidCache else std.json.Value{ .array = std.json.Array.init(allocator) };
    const zwanzig_findings = if (request.zwanzig_findings) |text| normalizeFindingsText(allocator, text, "zwanzig") catch return error.InvalidCache else std.json.Value{ .array = std.json.Array.init(allocator) };
    const zlint_related = try findingsMatchingQuery(allocator, zlint_findings.array, request.query);
    const zwanzig_related = try findingsMatchingQuery(allocator, zwanzig_findings.array, request.query);
    var sources = std.json.Array.init(allocator);
    if (matches.array.items.len > 0) try sources.append(.{ .string = "parser" });
    if (zlint_related.array.items.len > 0) try sources.append(.{ .string = "zlint" });
    if (zwanzig_related.array.items.len > 0) try sources.append(.{ .string = "zwanzig" });
    const consensus = sources.items.len >= 2;

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_static_fusion" });
    try obj.put(allocator, "query", try ownedString(allocator, request.query));
    try obj.put(allocator, "matches", matches);
    try obj.put(allocator, "lint_evidence", try lintEvidenceValue(allocator, zlint_findings.array, zlint_related.array, zwanzig_findings.array, zwanzig_related.array));
    try obj.put(allocator, "evidence_sources", .{ .array = sources });
    try obj.put(allocator, "consensus", .{ .bool = consensus });
    try obj.put(allocator, "fusion_source", .{ .string = if (consensus) "consensus" else "disagreement_or_single_source" });
    try obj.put(allocator, "confidence", .{ .string = if (consensus) "high" else if (matches.array.items.len > 0) "medium" else "low" });
    try obj.put(allocator, "recommended_cross_check", try stringArrayValue(allocator, &.{ "zig build test", "ZLS references", "zig_lint_compare" }));
    return .{ .object = obj };
}

pub fn exportIndex(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: ExportRequest) SemanticError!std.json.Value {
    const index = try buildIndex(allocator, context, .{ .limit = request.limit, .refresh = request.refresh, .tool_name = request.tool_name });
    var export_obj = std.json.ObjectMap.empty;
    try export_obj.put(allocator, "kind", .{ .string = request.tool_name });
    try export_obj.put(allocator, "format", try ownedString(allocator, request.format));
    try export_obj.put(allocator, "format_version", .{ .integer = semantic_format_version });
    try export_obj.put(allocator, "index", index.value);
    const export_value: std.json.Value = .{ .object = export_obj };
    const bytes = try serializeAlloc(allocator, export_value);
    defer allocator.free(bytes);
    if (request.apply) {
        _ = try context.workspace_store.write(.{
            .path = request.output,
            .bytes = bytes,
            .provenance = "static_analysis.semantic_export",
        });
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = request.tool_name });
    try obj.put(allocator, "apply", .{ .bool = request.apply });
    try obj.put(allocator, "output", try ownedString(allocator, request.output));
    try obj.put(allocator, "wrote", .{ .bool = request.apply });
    try obj.put(allocator, "preview_bytes", .{ .integer = @intCast(bytes.len) });
    if (!request.apply) try obj.put(allocator, "artifact_preview", export_value);
    return .{ .object = obj };
}

pub fn semanticSignature(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, limit: usize) SemanticError!u64 {
    var hasher = std.hash.Wyhash.init(semantic_format_version);
    var scan = try context.workspace_scanner.scanZigFiles(allocator, .{
        .max_files = @max(limit, 1),
        .provenance = "static_analysis.semantic_signature",
    });
    defer scan.deinit(allocator);
    for (scan.files) |file| {
        hasher.update(file.path);
        const read = context.workspace_store.read(allocator, .{
            .path = file.path,
            .max_bytes = default_source_read_limit,
            .provenance = "static_analysis.semantic_signature",
        }) catch continue;
        defer read.deinit(allocator);
        hasher.update(read.bytes);
    }
    return hasher.final();
}

pub fn semanticIndexValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, limit: usize, tool_name: []const u8) SemanticError!std.json.Value {
    var files = std.json.Array.init(allocator);
    var declarations = std.json.Array.init(allocator);
    var imports = std.json.Array.init(allocator);
    var tests = std.json.Array.init(allocator);
    var skipped = std.json.Array.init(allocator);
    var scan = try context.workspace_scanner.scanZigFiles(allocator, .{
        .max_files = @max(limit, 1),
        .provenance = "static_analysis.semantic_index",
    });
    defer scan.deinit(allocator);

    var partial_result = false;
    var parse_error_count: i64 = 0;
    var seen: usize = 0;
    for (scan.files) |file| {
        const read = context.workspace_store.read(allocator, .{
            .path = file.path,
            .max_bytes = default_source_read_limit,
            .provenance = "static_analysis.semantic_index",
        }) catch |err| {
            try skipped.append(try skippedFileValue(allocator, file.path, err));
            continue;
        };
        defer read.deinit(allocator);
        seen += 1;
        const stats = try appendFileIndex(allocator, file.path, read.bytes, &files, &declarations, &imports, &tests);
        partial_result = partial_result or stats.partial_result;
        parse_error_count += stats.parse_error_count;
    }
    partial_result = partial_result or skipped.items.len > 0;

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "format", .{ .string = "zigar.semantic_index" });
    try obj.put(allocator, "format_version", .{ .integer = semantic_format_version });
    try obj.put(allocator, "parse_status", .{ .string = if (parse_error_count > 0) "syntax_errors" else if (partial_result) "partial" else "ok" });
    try obj.put(allocator, "partial_result", .{ .bool = partial_result });
    try obj.put(allocator, "result_complete", .{ .bool = !partial_result });
    try obj.put(allocator, "parse_error_count", .{ .integer = parse_error_count });
    try obj.put(allocator, "evidence_sources", try stringArrayValue(allocator, &.{ "parser", "heuristic", "profile" }));
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "declarations", .{ .array = declarations });
    try obj.put(allocator, "imports", .{ .array = imports });
    try obj.put(allocator, "tests", .{ .array = tests });
    try obj.put(allocator, "build_targets", try stringArrayValue(allocator, &.{ "zig build", "zig build test" }));
    try obj.put(allocator, "file_count", .{ .integer = @intCast(seen) });
    try obj.put(allocator, "declaration_count", .{ .integer = @intCast(declarations.items.len) });
    try obj.put(allocator, "import_count", .{ .integer = @intCast(imports.items.len) });
    try obj.put(allocator, "test_count", .{ .integer = @intCast(tests.items.len) });
    try obj.put(allocator, "skipped_files", .{ .array = skipped });
    try obj.put(allocator, "skipped_file_count", .{ .integer = @intCast(skipped.items.len) });
    try obj.put(allocator, "walk_errors", .{ .integer = 0 });
    return .{ .object = obj };
}

fn appendFileIndex(allocator: std.mem.Allocator, file: []const u8, contents: []const u8, files: *std.json.Array, declarations: *std.json.Array, imports: *std.json.Array, tests: *std.json.Array) !ParseStats {
    const summary = zig_analysis.parseSourceSummary(allocator, file, contents) catch null;
    const stats: ParseStats = if (summary) |s| .{ .partial_result = s.parse.partial_result, .parse_error_count = s.parse.parse_error_count } else .{ .partial_result = true, .parse_error_count = 0 };
    var file_decls = std.json.Array.init(allocator);
    var file_imports = std.json.Array.init(allocator);
    var file_tests = std.json.Array.init(allocator);
    if (summary) |s| {
        defer s.deinit(allocator);
        for (s.declarations) |decl_item| {
            const item = try semanticDeclValue(allocator, file, decl_item.line, decl_item.kind, decl_item.name, decl_item.public, decl_item.signature, "parser");
            try file_decls.append(item);
            try declarations.append(item);
        }
        for (s.imports) |import_item| {
            const item = try semanticImportValue(allocator, file, import_item.line, import_item.import, import_item.alias, "parser");
            try file_imports.append(item);
            try imports.append(item);
        }
        for (s.tests) |test_item| {
            const item = try semanticTestValue(allocator, file, test_item.line, test_item.name, test_item.command, "parser");
            try file_tests.append(item);
            try tests.append(item);
        }
    }
    if (summary == null or (stats.partial_result and file_decls.items.len == 0)) {
        var decl_list = try zig_analysis.heuristicDeclarations(allocator, contents);
        defer decl_list.deinit(allocator);
        for (decl_list.items) |decl_item| {
            const item = try semanticDeclValue(allocator, file, decl_item.line, decl_item.kind, decl_item.name, decl_item.public, decl_item.signature, "heuristic");
            try file_decls.append(item);
            try declarations.append(item);
        }
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "parse_status", .{ .string = if (summary != null) zig_analysis.parseStatusName(summary.?.parse.status) else "heuristic_fallback" });
    try obj.put(allocator, "partial_result", .{ .bool = stats.partial_result });
    try obj.put(allocator, "result_complete", .{ .bool = !stats.partial_result });
    try obj.put(allocator, "parse_error_count", .{ .integer = stats.parse_error_count });
    try obj.put(allocator, "source_evidence", try stringArrayValue(allocator, if (summary != null) &.{ "parser", "heuristic" } else &.{"heuristic"}));
    try obj.put(allocator, "declarations", .{ .array = file_decls });
    try obj.put(allocator, "imports", .{ .array = file_imports });
    try obj.put(allocator, "tests", .{ .array = file_tests });
    try files.append(.{ .object = obj });
    return stats;
}

fn semanticDeclValue(allocator: std.mem.Allocator, file: []const u8, line: usize, kind: []const u8, name: ?[]const u8, public: bool, signature: []const u8, source: []const u8) !std.json.Value {
    var out = std.json.ObjectMap.empty;
    try out.put(allocator, "file", try ownedString(allocator, file));
    try out.put(allocator, "line", .{ .integer = @intCast(line) });
    try out.put(allocator, "kind", try ownedString(allocator, kind));
    try out.put(allocator, "name", if (name) |value| try ownedString(allocator, value) else .null);
    try out.put(allocator, "public", .{ .bool = public });
    try out.put(allocator, "signature", try ownedString(allocator, signature));
    try out.put(allocator, "location", try locationValue(allocator, file, line, 1));
    try out.put(allocator, "source", try ownedString(allocator, source));
    try out.put(allocator, "confidence", .{ .string = if (std.mem.eql(u8, source, "parser")) "high" else "medium" });
    try out.put(allocator, "evidence", try evidenceValue(allocator, source, if (std.mem.eql(u8, source, "parser")) "high" else "medium", "Declaration recovered from workspace source.", &.{ "ZLS definition", "zig ast-check" }));
    return .{ .object = out };
}

fn semanticImportValue(allocator: std.mem.Allocator, file: []const u8, line: usize, import_name: []const u8, alias: ?[]const u8, source: []const u8) !std.json.Value {
    var out = std.json.ObjectMap.empty;
    try out.put(allocator, "file", try ownedString(allocator, file));
    try out.put(allocator, "line", .{ .integer = @intCast(line) });
    try out.put(allocator, "import", try ownedString(allocator, import_name));
    try out.put(allocator, "alias", if (alias) |value| try ownedString(allocator, value) else .null);
    try out.put(allocator, "source", try ownedString(allocator, source));
    try out.put(allocator, "confidence", .{ .string = "high" });
    try out.put(allocator, "evidence", try evidenceValue(allocator, source, "high", "Import recovered from workspace source.", &.{ "zig_ast_imports", "zig build test" }));
    return .{ .object = out };
}

fn semanticTestValue(allocator: std.mem.Allocator, file: []const u8, line: usize, name: ?[]const u8, command: []const u8, source: []const u8) !std.json.Value {
    var out = std.json.ObjectMap.empty;
    try out.put(allocator, "file", try ownedString(allocator, file));
    try out.put(allocator, "line", .{ .integer = @intCast(line) });
    try out.put(allocator, "name", if (name) |value| try ownedString(allocator, value) else .null);
    try out.put(allocator, "command", try ownedString(allocator, command));
    try out.put(allocator, "source", try ownedString(allocator, source));
    try out.put(allocator, "confidence", .{ .string = "high" });
    try out.put(allocator, "evidence", try evidenceValue(allocator, source, "high", "Test declaration recovered from workspace source.", &.{ "zig_ast_tests", "zig test <file>" }));
    return .{ .object = out };
}

fn zlintAstSymbolHasReferenceForFile(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: SourceRefsRequest, file: []const u8) SemanticError!bool {
    const command_runner = context.command_runner orelse return error.MissingCommandRunner;
    const resolved = try context.workspace_store.resolve(allocator, .{ .path = file, .provenance = "static_analysis.zlint_ast" });
    defer resolved.deinit(allocator);
    const argv = [_][]const u8{ context.tool_paths.zlint, "--print-ast", resolved.path };
    const result = try command_runner.run(allocator, .{
        .argv = argv[0..],
        .cwd = context.workspace.root,
        .timeout_ms = request.timeout_ms,
        .provenance = "static_analysis.zlint_ast",
    });
    defer result.deinit(allocator);
    if (result.effectiveTerm().failed()) return false;
    return zlintAstSymbolHasReference(allocator, result.stdout, request.symbol, request.calls_only) catch false;
}

pub fn zlintAstSymbolHasReference(allocator: std.mem.Allocator, text: []const u8, symbol: []const u8, calls_only: bool) !bool {
    const start = std.mem.indexOfScalar(u8, text, '{') orelse return false;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text[start..], .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };
    const symbols = switch (root.get("symbols") orelse .null) {
        .array => |array| array,
        else => return false,
    };
    for (symbols.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (!std.mem.eql(u8, stringField(obj, "name") orelse "", symbol)) continue;
        const refs = switch (obj.get("references") orelse .null) {
            .array => |array| array,
            else => return false,
        };
        if (!calls_only) return refs.items.len > 0;
        for (refs.items) |ref| if (zlintReferenceHasFlag(ref, "call")) return true;
        return false;
    }
    return false;
}

fn zlintReferenceHasFlag(value: std.json.Value, flag: []const u8) bool {
    const obj = switch (value) {
        .object => |o| o,
        else => return false,
    };
    const flags = switch (obj.get("flags") orelse .null) {
        .array => |array| array,
        else => return false,
    };
    for (flags.items) |item| switch (item) {
        .string => |s| if (std.mem.eql(u8, s, flag)) return true,
        else => {},
    };
    return false;
}

fn semanticMatchesValue(allocator: std.mem.Allocator, index: std.json.Value, query_text: []const u8, kind_filter: ?[]const u8, limit: usize) !std.json.Value {
    const lower_query = try std.ascii.allocLowerString(allocator, query_text);
    var matches = std.json.Array.init(allocator);
    const root = switch (index) {
        .object => |o| o,
        else => return .{ .array = matches },
    };
    try appendMatchesFromArray(allocator, &matches, root.get("declarations") orelse .null, lower_query, "declaration", kind_filter, limit);
    try appendMatchesFromArray(allocator, &matches, root.get("imports") orelse .null, lower_query, "import", kind_filter, limit);
    try appendMatchesFromArray(allocator, &matches, root.get("tests") orelse .null, lower_query, "test", kind_filter, limit);
    return .{ .array = matches };
}

fn appendMatchesFromArray(allocator: std.mem.Allocator, matches: *std.json.Array, value: std.json.Value, lower_query: []const u8, match_kind: []const u8, kind_filter: ?[]const u8, limit: usize) !void {
    if (matches.items.len >= limit) return;
    if (kind_filter) |filter| if (!std.mem.eql(u8, filter, match_kind) and !std.mem.eql(u8, filter, "any")) return;
    const array = switch (value) {
        .array => |a| a,
        else => return,
    };
    for (array.items) |item| {
        if (matches.items.len >= limit) break;
        const text = try searchableText(allocator, item);
        const lower_text = try std.ascii.allocLowerString(allocator, text);
        if (std.mem.indexOf(u8, lower_text, lower_query) == null) continue;
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "match_kind", try ownedString(allocator, match_kind));
        try obj.put(allocator, "item", item);
        try matches.append(.{ .object = obj });
    }
}

fn normalizeFindingsText(allocator: std.mem.Allocator, text: []const u8, source: []const u8) !std.json.Value {
    var findings = std.json.Array.init(allocator);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return .{ .array = findings };
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    const raw = findingsArray(parsed.value);
    for (raw.items) |item| try findings.append(try normalizeFindingValue(allocator, item, source));
    return .{ .array = findings };
}

fn findingsArray(value: std.json.Value) std.json.Array {
    switch (value) {
        .array => |array| return array,
        .object => |obj| {
            if (obj.get("findings")) |field_value| if (field_value == .array) return field_value.array;
            if (obj.get("diagnostics")) |field_value| if (field_value == .array) return field_value.array;
            if (obj.get("results")) |field_value| if (field_value == .array) return field_value.array;
        },
        else => {},
    }
    return std.json.Array.init(std.heap.page_allocator);
}

fn normalizeFindingValue(allocator: std.mem.Allocator, value: std.json.Value, source: []const u8) !std.json.Value {
    const obj = switch (value) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const location = switch (obj.get("location") orelse .null) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const file = stringField(obj, "path") orelse stringField(obj, "file") orelse stringField(location, "file") orelse stringField(location, "path") orelse "unknown";
    const line: usize = @intCast(@max(integerField(obj, "line") orelse integerField(location, "line") orelse 1, 1));
    const column: usize = @intCast(@max(integerField(obj, "column") orelse integerField(location, "column") orelse 1, 1));
    const rule = stringField(obj, "rule") orelse stringField(obj, "rule_id") orelse stringField(obj, "code") orelse "unknown";
    const severity = stringField(obj, "severity") orelse stringField(obj, "level") orelse "info";
    const message = stringField(obj, "message") orelse stringField(obj, "title") orelse stringField(obj, "detail") orelse "";
    var out = std.json.ObjectMap.empty;
    try out.put(allocator, "source", try ownedString(allocator, source));
    try out.put(allocator, "rule", try ownedString(allocator, rule));
    try out.put(allocator, "severity", try ownedString(allocator, severity));
    try out.put(allocator, "location", try locationValue(allocator, file, line, column));
    try out.put(allocator, "message", try ownedString(allocator, message));
    try out.put(allocator, "confidence", .{ .string = "high" });
    try out.put(allocator, "recommended_cross_check", try stringArrayValue(allocator, &.{ "zig_lint_compare", "zig build test" }));
    try out.put(allocator, "comparison_key", .{ .string = try std.fmt.allocPrint(allocator, "{s}:{s}:{d}", .{ rule, file, line }) });
    try out.put(allocator, "fingerprint", try fingerprintValue(allocator, .{ .object = out }));
    return .{ .object = out };
}

fn findingsMatchingQuery(allocator: std.mem.Allocator, findings: std.json.Array, query_text: []const u8) !std.json.Value {
    var matches = std.json.Array.init(allocator);
    const lower_query = try std.ascii.allocLowerString(allocator, query_text);
    for (findings.items) |finding| {
        const text = try lintSearchableText(allocator, finding);
        const lower_text = try std.ascii.allocLowerString(allocator, text);
        if (std.mem.indexOf(u8, lower_text, lower_query) != null) try matches.append(finding);
    }
    return .{ .array = matches };
}

fn lintSearchableText(allocator: std.mem.Allocator, finding: std.json.Value) ![]const u8 {
    const obj = switch (finding) {
        .object => |o| o,
        else => return "",
    };
    const loc = switch (obj.get("location") orelse .null) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    return std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{
        stringField(obj, "rule") orelse "",
        stringField(obj, "message") orelse "",
        stringField(obj, "severity") orelse "",
        stringField(loc, "file") orelse "",
    });
}

fn lintEvidenceValue(allocator: std.mem.Allocator, zlint_all: std.json.Array, zlint_related: std.json.Array, zwanzig_all: std.json.Array, zwanzig_related: std.json.Array) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "zlint_total_count", .{ .integer = @intCast(zlint_all.items.len) });
    try obj.put(allocator, "zlint_related_count", .{ .integer = @intCast(zlint_related.items.len) });
    try obj.put(allocator, "zlint_related", .{ .array = zlint_related });
    try obj.put(allocator, "zwanzig_total_count", .{ .integer = @intCast(zwanzig_all.items.len) });
    try obj.put(allocator, "zwanzig_related_count", .{ .integer = @intCast(zwanzig_related.items.len) });
    try obj.put(allocator, "zwanzig_related", .{ .array = zwanzig_related });
    return .{ .object = obj };
}

fn searchableText(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return "",
    };
    return std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{
        stringField(obj, "file") orelse "",
        stringField(obj, "name") orelse "",
        stringField(obj, "import") orelse "",
        stringField(obj, "signature") orelse "",
    });
}

fn skippedFileValue(allocator: std.mem.Allocator, path: []const u8, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", try ownedString(allocator, path));
    try obj.put(allocator, "error", try ownedString(allocator, @errorName(err)));
    return .{ .object = obj };
}

fn locationValue(allocator: std.mem.Allocator, file: []const u8, line: usize, column: usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "line", .{ .integer = @intCast(@max(line, 1)) });
    try obj.put(allocator, "column", .{ .integer = @intCast(@max(column, 1)) });
    return .{ .object = obj };
}

fn evidenceValue(allocator: std.mem.Allocator, source: []const u8, confidence: []const u8, detail: []const u8, verify_with: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "source", try ownedString(allocator, source));
    try obj.put(allocator, "confidence", try ownedString(allocator, confidence));
    try obj.put(allocator, "detail", try ownedString(allocator, detail));
    try obj.put(allocator, "verify_with", try stringArrayValue(allocator, verify_with));
    return .{ .object = obj };
}

fn fingerprintValue(allocator: std.mem.Allocator, finding: std.json.Value) !std.json.Value {
    const obj = switch (finding) {
        .object => |o| o,
        else => return ownedString(allocator, "unknown"),
    };
    const source = stringField(obj, "source") orelse "unknown";
    const rule = stringField(obj, "rule") orelse "unknown";
    const message = stringField(obj, "message") orelse "";
    const location = switch (obj.get("location") orelse .null) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const file = stringField(location, "file") orelse "unknown";
    const line = integerField(location, "line") orelse 0;
    return .{ .string = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}:{d}:{s}", .{ source, rule, file, line, message }) };
}

fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return switch (obj.get(field) orelse .null) {
        .string => |s| s,
        else => null,
    };
}

fn integerField(obj: std.json.ObjectMap, field: []const u8) ?i64 {
    return switch (obj.get(field) orelse .null) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(try ownedString(allocator, value));
    return .{ .array = array };
}

fn serializeAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try serializeValue(allocator, &bytes, value);
    return bytes.toOwnedSlice(allocator);
}

fn serializeValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| try out.print(allocator, "{d}", .{i}),
        .float => |f| try out.print(allocator, "{d}", .{f}),
        .number_string => |s| try out.appendSlice(allocator, s),
        .string => |s| try serializeString(allocator, out, s),
        .array => |array| {
            try out.append(allocator, '[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try out.append(allocator, ',');
                try serializeValue(allocator, out, item);
            }
            try out.append(allocator, ']');
        },
        .object => |object| {
            try out.append(allocator, '{');
            var it = object.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.append(allocator, ',');
                first = false;
                try serializeString(allocator, out, entry.key_ptr.*);
                try out.append(allocator, ':');
                try serializeValue(allocator, out, entry.value_ptr.*);
            }
            try out.append(allocator, '}');
        },
    }
}

fn serializeString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789abcdef";
    try out.append(allocator, '"');
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        0...8, 11...12, 14...0x1f => {
            try out.appendSlice(allocator, "\\u00");
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0f]);
        },
        else => try out.append(allocator, c),
    };
    try out.append(allocator, '"');
}

test "semantic helper fallbacks normalize lint evidence and serialize primitives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const empty = try normalizeFindingsText(allocator, "  \n", "zlint");
    try std.testing.expectEqual(@as(usize, 0), empty.array.items.len);
    const raw_array = try normalizeFindingsText(allocator, "[42]", "zlint");
    try std.testing.expectEqualStrings("unknown", raw_array.array.items[0].object.get("location").?.object.get("file").?.string);
    const findings = try normalizeFindingsText(allocator,
        \\{"findings":[{"rule":"r1","severity":"warning","path":"src/a.zig","line":"2","column":"3","message":"Widget warning"}]}
    , "zlint");
    const diagnostics = try normalizeFindingsText(allocator,
        \\{"diagnostics":[{"rule_id":"r2","level":"error","location":{"path":"src/b.zig","line":4,"column":5},"title":"Widget error"}]}
    , "zlint");
    const results = try normalizeFindingsText(allocator,
        \\{"results":[{"code":"r3","file":"src/c.zig","detail":"Widget info"}]}
    , "zwanzig");
    const fallback = try normalizeFindingsText(allocator, "42", "zlint");
    try std.testing.expectEqual(@as(usize, 0), fallback.array.items.len);
    try std.testing.expectEqualStrings("src/a.zig", findings.array.items[0].object.get("location").?.object.get("file").?.string);
    try std.testing.expectEqualStrings("src/b.zig", diagnostics.array.items[0].object.get("location").?.object.get("file").?.string);
    try std.testing.expectEqualStrings("src/c.zig", results.array.items[0].object.get("location").?.object.get("file").?.string);

    const related = try findingsMatchingQuery(allocator, findings.array, "widget");
    try std.testing.expectEqual(@as(usize, 1), related.array.items.len);
    const empty_search = try lintSearchableText(allocator, .null);
    try std.testing.expectEqualStrings("", empty_search);
    const searchable = try searchableText(allocator, .null);
    try std.testing.expectEqualStrings("", searchable);
    const unknown_fp = try fingerprintValue(allocator, .null);
    try std.testing.expectEqualStrings("unknown", unknown_fp.string);
    var fp_obj = std.json.ObjectMap.empty;
    try fp_obj.put(allocator, "source", .{ .string = "zlint" });
    try fp_obj.put(allocator, "rule", .{ .string = "rule" });
    try fp_obj.put(allocator, "message", .{ .string = "message" });
    try fp_obj.put(allocator, "location", .null);
    const no_location_search = try lintSearchableText(allocator, .{ .object = fp_obj });
    try std.testing.expectEqualStrings("rule message  ", no_location_search);
    const fp = try fingerprintValue(allocator, .{ .object = fp_obj });
    try std.testing.expectEqualStrings("zlint:rule:unknown:0:message", fp.string);
    var numbered = std.json.ObjectMap.empty;
    try numbered.put(allocator, "line", .{ .number_string = "12" });
    try std.testing.expectEqual(@as(i64, 12), integerField(numbered, "line").?);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try serializeValue(allocator, &out, .{ .float = 2.5 });
    try out.append(allocator, ' ');
    try serializeValue(allocator, &out, .{ .number_string = "17" });
    try std.testing.expectEqualStrings("2.5 17", out.items);

    const escaped = try serializeAlloc(allocator, .{ .string = "\"\\\r\t\x01" });
    try std.testing.expectEqualStrings("\"\\\"\\\\\\r\\t\\u0001\"", escaped);

    var fail_buf: [1]u8 = undefined;
    var fail_fba = std.heap.FixedBufferAllocator.init(&fail_buf);
    try std.testing.expectError(error.OutOfMemory, serializeAlloc(fail_fba.allocator(), .{ .string = "too long" }));
}
