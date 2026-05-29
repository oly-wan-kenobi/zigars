//! Architecture-neutral agent ergonomics over parser-backed and heuristic
//! workspace evidence.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const zig_analysis = @import("../../../domain/zig/analysis.zig");
const project_values = @import("project_values.zig");
const workspace_scans = @import("workspace_scans.zig");

/// Default workspace scan limit used by Phase 3 tools.
pub const default_limit: usize = 200;
const max_source_read = workspace_scans.default_source_read_limit;

/// Import-cycle request fields.
pub const ImportCyclesRequest = struct {
    limit: usize = default_limit,
};

/// Test-name resolution request fields.
pub const TestNameResolveRequest = struct {
    filters: ?[]const u8 = null,
    limit: usize = 500,
};

/// Workspace catalog request fields.
pub const CatalogRequest = struct {
    path: ?[]const u8 = null,
    limit: usize = default_limit,
};

/// Symbol-scoped request fields.
pub const SymbolRequest = struct {
    symbol: []const u8,
    limit: usize = default_limit,
};

/// Change-risk request fields.
pub const ChangeRiskRequest = struct {
    files: ?[]const u8 = null,
    symbols: ?[]const u8 = null,
    diff: ?[]const u8 = null,
    limit: usize = default_limit,
};

/// Insertion-site request fields.
pub const InsertionSitesRequest = struct {
    topic: []const u8,
    path: ?[]const u8 = null,
    limit: usize = 20,
};

const SourceRecord = struct {
    file: []const u8,
    bytes: []const u8,

    fn deinit(self: SourceRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.bytes);
    }
};

const TestRecord = struct {
    file: []const u8,
    line: usize,
    name: ?[]const u8,
    declaration: []const u8,
    command: []const u8,

    fn deinit(self: TestRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        if (self.name) |value| allocator.free(value);
        allocator.free(self.declaration);
        allocator.free(self.command);
    }
};

const PublicDeclRecord = struct {
    file: []const u8,
    line: usize,
    kind: []const u8,
    name: []const u8,
    signature: []const u8,

    fn deinit(self: PublicDeclRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.kind);
        allocator.free(self.name);
        allocator.free(self.signature);
    }
};

const HelperRecord = struct {
    file: []const u8,
    line: usize,
    name: []const u8,
    kind: []const u8,
    signature: []const u8,

    fn deinit(self: HelperRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.name);
        allocator.free(self.kind);
        allocator.free(self.signature);
    }
};

const WorkspaceSnapshot = struct {
    sources: []SourceRecord,
    tests: []TestRecord,
    public_decls: []PublicDeclRecord,
    helpers: []HelperRecord,
    skipped_files: usize,
    partial_files: usize,

    fn deinit(self: WorkspaceSnapshot, allocator: std.mem.Allocator) void {
        for (self.sources) |item| item.deinit(allocator);
        allocator.free(self.sources);
        for (self.tests) |item| item.deinit(allocator);
        allocator.free(self.tests);
        for (self.public_decls) |item| item.deinit(allocator);
        allocator.free(self.public_decls);
        for (self.helpers) |item| item.deinit(allocator);
        allocator.free(self.helpers);
    }
};

const GraphEdge = struct {
    from: usize,
    to: usize,
    import_name: []const u8,
};

/// Finds import SCCs and cycle-oriented graph metadata without applying any
/// project-specific architecture policy.
pub fn importCyclesValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: ImportCyclesRequest) ports.PortError!std.json.Value {
    var graph = try workspace_scans.importGraph(allocator, context, .{ .limit = request.limit });
    defer graph.deinit(allocator);

    var edges: std.ArrayList(GraphEdge) = .empty;
    defer edges.deinit(allocator);
    for (graph.files, 0..) |file, from| {
        for (file.imports) |import_edge| {
            if (try workspaceImportIndex(allocator, graph.files, file.file, import_edge.import)) |to| {
                try edges.append(allocator, .{ .from = from, .to = to, .import_name = import_edge.import });
            }
        }
    }

    const count = graph.files.len;
    var assigned = try allocator.alloc(bool, count);
    defer allocator.free(assigned);
    @memset(assigned, false);

    var cycles = std.json.Array.init(allocator);
    var cycle_paths = std.json.Array.init(allocator);
    var importer_counts = try allocator.alloc(usize, count);
    defer allocator.free(importer_counts);
    @memset(importer_counts, 0);
    for (edges.items) |edge| importer_counts[edge.to] += 1;

    var cycle_node_count: usize = 0;
    var largest_scc: usize = 0;
    for (0..count) |i| {
        if (assigned[i]) continue;
        var members: std.ArrayList(usize) = .empty;
        defer members.deinit(allocator);
        for (i..count) |j| {
            if (assigned[j]) continue;
            if (try mutuallyReachable(allocator, count, edges.items, i, j)) try members.append(allocator, j);
        }
        for (members.items) |member| assigned[member] = true;
        if (!isCycleComponent(members.items, edges.items)) continue;
        cycle_node_count += members.items.len;
        largest_scc = @max(largest_scc, members.items.len);
        const component = try cycleComponentValue(allocator, graph.files, edges.items, importer_counts, members.items);
        try cycles.append(component);
        const path = try cyclePathValue(allocator, graph.files, members.items);
        try cycle_paths.append(path);
    }

    var depths = std.json.Array.init(allocator);
    for (graph.files, 0..) |file, index| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try ownedString(allocator, file.file));
        try item.put(allocator, "depth", .{ .integer = @intCast(try importDepth(allocator, count, edges.items, index)) });
        try item.put(allocator, "importer_count", .{ .integer = @intCast(importer_counts[index]) });
        try depths.append(.{ .object = item });
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_import_cycles" });
    try obj.put(allocator, "cycles", .{ .array = cycles });
    try obj.put(allocator, "cycle_paths", .{ .array = cycle_paths });
    try obj.put(allocator, "cycle_count", .{ .integer = @intCast(cycles.items.len) });
    try obj.put(allocator, "cycle_node_count", .{ .integer = @intCast(cycle_node_count) });
    try obj.put(allocator, "largest_scc_size", .{ .integer = @intCast(largest_scc) });
    try obj.put(allocator, "topological_depths", .{ .array = depths });
    try obj.put(allocator, "severity", .{ .string = cycleSeverity(largest_scc, cycle_node_count) });
    try obj.put(allocator, "confidence", .{ .string = if (graph.skipped_files.len == 0) "medium" else "low" });
    try obj.put(allocator, "policy", .{ .string = "architecture-neutral import-cycle analysis; no zigars layer policy is applied" });
    try obj.put(allocator, "skipped_file_count", .{ .integer = @intCast(graph.skipped_files.len) });
    try obj.put(allocator, "omitted_sections", try stringArrayValue(allocator, &.{}));
    return .{ .object = obj };
}

/// Resolves requested test filters to actual parser-backed or heuristic test names.
pub fn testNameResolveValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: TestNameResolveRequest) ports.PortError!std.json.Value {
    var snapshot = try loadWorkspaceSnapshot(allocator, context, request.limit, "static_analysis.test_name_resolve");
    defer snapshot.deinit(allocator);

    var filters = std.ArrayList([]const u8).empty;
    defer filters.deinit(allocator);
    defer freeStringList(allocator, filters.items);
    try appendTokens(allocator, &filters, request.filters);

    var requested = std.json.Array.init(allocator);
    for (filters.items) |filter| try requested.append(try ownedString(allocator, filter));

    var matches = std.json.Array.init(allocator);
    for (snapshot.tests) |test_record| {
        if (matches.items.len >= request.limit) break;
        const name = test_record.name orelse test_record.declaration;
        const match_kind = testFilterMatch(filters.items, name);
        if (filters.items.len > 0 and match_kind == null) continue;
        var item = try testRecordObject(allocator, test_record);
        try item.put(allocator, "match_kind", .{ .string = match_kind orelse "all" });
        try item.put(allocator, "duplicate_name", .{ .bool = testNameCount(snapshot.tests, name) > 1 });
        try matches.append(.{ .object = item });
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_test_name_resolve" });
    try obj.put(allocator, "requested_filters", .{ .array = requested });
    try obj.put(allocator, "matches", .{ .array = matches });
    try obj.put(allocator, "match_count", .{ .integer = @intCast(matches.items.len) });
    try obj.put(allocator, "test_count", .{ .integer = @intCast(snapshot.tests.len) });
    try obj.put(allocator, "confidence", .{ .string = if (snapshot.partial_files == 0) "high" else "medium" });
    try obj.put(allocator, "evidence_basis", .{ .string = "std.zig.Ast test declarations with heuristic fallback for partial files" });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{
        "Filters match declared test names and declarations only; custom build test routing can add or omit test binaries.",
        "Parameterized naming conventions are surfaced as declared names, not expanded runtime cases.",
    }));
    return .{ .object = obj };
}

/// Inventories likely test helpers, fixtures, fakes, and harness utilities.
pub fn testFixtureInventoryValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: CatalogRequest) ports.PortError!std.json.Value {
    var snapshot = try loadWorkspaceSnapshot(allocator, context, request.limit, "static_analysis.test_fixture_inventory");
    defer snapshot.deinit(allocator);

    var helpers = std.json.Array.init(allocator);
    for (snapshot.helpers) |helper| {
        if (helpers.items.len >= request.limit) break;
        if (request.path) |prefix| if (!std.mem.startsWith(u8, helper.file, prefix)) continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "name", try ownedString(allocator, helper.name));
        try item.put(allocator, "kind", try ownedString(allocator, helper.kind));
        try item.put(allocator, "file", try ownedString(allocator, helper.file));
        try item.put(allocator, "line", .{ .integer = @intCast(helper.line) });
        try item.put(allocator, "signature", try ownedString(allocator, helper.signature));
        try item.put(allocator, "usage_count", .{ .integer = @intCast(symbolUseCount(snapshot.sources, helper.name, helper.file, helper.line)) });
        try item.put(allocator, "usage_sites", try usageSitesValue(allocator, snapshot.sources, helper.name, helper.file, 5));
        try helpers.append(.{ .object = item });
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_test_fixture_inventory" });
    if (request.path) |path| try obj.put(allocator, "path", try ownedString(allocator, path)) else try obj.put(allocator, "path", .null);
    try obj.put(allocator, "helpers", .{ .array = helpers });
    try obj.put(allocator, "helper_count", .{ .integer = @intCast(helpers.items.len) });
    try obj.put(allocator, "skipped_file_count", .{ .integer = @intCast(snapshot.skipped_files) });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{
        "Fixture classification is name- and path-based and should be reviewed before deletion or broad refactors.",
        "Usage counts are source-text occurrences and do not resolve aliases or comptime-selected tests.",
    }));
    return .{ .object = obj };
}

/// Catalogs safety-relevant source sites while ignoring obvious comments and
/// string literal spans on each line.
pub fn safetySiteCatalogValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: CatalogRequest) ports.PortError!std.json.Value {
    var snapshot = try loadWorkspaceSnapshot(allocator, context, request.limit, "static_analysis.safety_site_catalog");
    defer snapshot.deinit(allocator);

    var sites = std.json.Array.init(allocator);
    for (snapshot.sources) |source| {
        if (request.path) |prefix| if (!std.mem.startsWith(u8, source.file, prefix)) continue;
        var lines = std.mem.splitScalar(u8, source.bytes, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            if (sites.items.len >= request.limit) break;
            const sanitized = try sanitizeCodeLine(allocator, line);
            defer allocator.free(sanitized);
            if (safetyKind(sanitized)) |kind| {
                var item = std.json.ObjectMap.empty;
                try item.put(allocator, "kind", .{ .string = kind });
                try item.put(allocator, "file", try ownedString(allocator, source.file));
                try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
                try item.put(allocator, "text", try ownedString(allocator, std.mem.trim(u8, line, " \t")));
                try item.put(allocator, "confidence", .{ .string = "medium" });
                try sites.append(.{ .object = item });
            }
        }
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_safety_site_catalog" });
    try obj.put(allocator, "sites", .{ .array = sites });
    try obj.put(allocator, "site_count", .{ .integer = @intCast(sites.items.len) });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{
        "Line-level scan masks obvious comments and string spans but does not perform full semantic safety proof.",
        "Unchecked cast categories are review prompts; some are intentional and safe after local invariants are checked.",
    }));
    return .{ .object = obj };
}

/// Maps a symbol to likely tests using test names, source occurrences, and test-file proximity.
pub fn testForSymbolValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: SymbolRequest) ports.PortError!std.json.Value {
    var snapshot = try loadWorkspaceSnapshot(allocator, context, request.limit, "static_analysis.test_for_symbol");
    defer snapshot.deinit(allocator);

    var tests = std.json.Array.init(allocator);
    var commands = std.json.Array.init(allocator);
    for (snapshot.tests) |test_record| {
        if (tests.items.len >= request.limit) break;
        const score = testSymbolScore(snapshot.sources, test_record, request.symbol);
        if (score == 0) continue;
        var item = try testRecordObject(allocator, test_record);
        try item.put(allocator, "score", .{ .integer = @intCast(score) });
        try item.put(allocator, "reason", .{ .string = testSymbolReason(score) });
        try tests.append(.{ .object = item });
        try appendUniqueStringValue(allocator, &commands, test_record.command);
    }
    try appendUniqueStringValue(allocator, &commands, "zig build test");

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_test_for_symbol" });
    try obj.put(allocator, "symbol", try ownedString(allocator, request.symbol));
    try obj.put(allocator, "candidate_tests", .{ .array = tests });
    try obj.put(allocator, "commands", .{ .array = commands });
    try obj.put(allocator, "coverage_status", .{ .string = if (tests.items.len == 0) "no_direct_matches" else "candidate_matches" });
    try obj.put(allocator, "confidence", .{ .string = if (tests.items.len == 0) "low" else "medium" });
    try obj.put(allocator, "omitted_sections", try stringArrayValue(allocator, &.{"compiler coverage data"}));
    return .{ .object = obj };
}

/// Builds a directory-level public surface aggregate.
pub fn moduleSurfaceValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: CatalogRequest) ports.PortError!std.json.Value {
    var snapshot = try loadWorkspaceSnapshot(allocator, context, request.limit, "static_analysis.module_surface");
    defer snapshot.deinit(allocator);
    const prefix = request.path orelse "";

    var exports = std.json.Array.init(allocator);
    var reexports = std.json.Array.init(allocator);
    var unused = std.json.Array.init(allocator);
    for (snapshot.public_decls) |decl| {
        if (prefix.len > 0 and !std.mem.startsWith(u8, decl.file, prefix)) continue;
        var item = try publicDeclObject(allocator, decl);
        const uses = symbolUseCount(snapshot.sources, decl.name, decl.file, decl.line);
        try item.put(allocator, "consumer_reference_count", .{ .integer = @intCast(uses) });
        try exports.append(.{ .object = item });
        if (std.mem.indexOf(u8, decl.signature, "@import(") != null) try reexports.append(try publicDeclObjectValue(allocator, decl));
        if (uses == 0) try unused.append(try publicDeclObjectValue(allocator, decl));
    }

    var consumers = std.json.Array.init(allocator);
    for (snapshot.sources) |source| {
        if (prefix.len > 0 and std.mem.startsWith(u8, source.file, prefix)) continue;
        if (sourceImportsPrefix(source.bytes, prefix)) try consumers.append(try ownedString(allocator, source.file));
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_module_surface" });
    try obj.put(allocator, "path", try ownedString(allocator, if (prefix.len == 0) "." else prefix));
    try obj.put(allocator, "public_exports", .{ .array = exports });
    try obj.put(allocator, "re_exports", .{ .array = reexports });
    try obj.put(allocator, "consumers", .{ .array = consumers });
    try obj.put(allocator, "unused_exports", .{ .array = unused });
    try obj.put(allocator, "module_role_hints", try moduleRoleHintsValue(allocator, prefix));
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{
        "Directory surface is parser-backed for declarations but source-scan based for consumers.",
        "Unused export candidates require ZLS/compiler/reference verification before removal.",
    }));
    return .{ .object = obj };
}

/// Returns a symbol-scoped dossier for review and planning.
pub fn symbolDossierValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: SymbolRequest) ports.PortError!std.json.Value {
    var snapshot = try loadWorkspaceSnapshot(allocator, context, request.limit, "static_analysis.symbol_dossier");
    defer snapshot.deinit(allocator);

    var declarations = std.json.Array.init(allocator);
    var public_api = false;
    for (snapshot.public_decls) |decl| {
        if (!std.mem.eql(u8, decl.name, request.symbol)) continue;
        public_api = true;
        try declarations.append(try publicDeclObjectValue(allocator, decl));
    }

    var callers = std.json.Array.init(allocator);
    try appendSymbolLineMatches(allocator, &callers, snapshot.sources, request.symbol, request.limit);

    var tests = std.json.Array.init(allocator);
    for (snapshot.tests) |test_record| {
        const score = testSymbolScore(snapshot.sources, test_record, request.symbol);
        if (score == 0) continue;
        try tests.append(.{ .object = try testRecordObject(allocator, test_record) });
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_symbol_dossier" });
    try obj.put(allocator, "symbol", try ownedString(allocator, request.symbol));
    try obj.put(allocator, "declarations", .{ .array = declarations });
    try obj.put(allocator, "public_api_member", .{ .bool = public_api });
    try obj.put(allocator, "callers", .{ .array = callers });
    try obj.put(allocator, "tests", .{ .array = tests });
    try obj.put(allocator, "module_role_hints", try moduleRoleHintsForSymbolValue(allocator, snapshot.public_decls, request.symbol));
    try obj.put(allocator, "confidence", .{ .string = if (declarations.items.len > 0) "medium" else "low" });
    try obj.put(allocator, "omitted_sections", try stringArrayValue(allocator, &.{ "diagnostics", "lint findings", "git history" }));
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{"Symbol dossier is parser/source-scan evidence and does not resolve aliases or comptime-generated declarations."}));
    return .{ .object = obj };
}

/// Risk-ranks a proposed or current change set with architecture-neutral weights.
pub fn changeRiskAuditValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: ChangeRiskRequest) ports.PortError!std.json.Value {
    var snapshot = try loadWorkspaceSnapshot(allocator, context, request.limit, "static_analysis.change_risk_audit");
    defer snapshot.deinit(allocator);

    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(allocator);
    defer freeStringList(allocator, files.items);
    try appendTokens(allocator, &files, request.files);
    try appendFilesFromDiff(allocator, &files, request.diff);

    var symbols = std.ArrayList([]const u8).empty;
    defer symbols.deinit(allocator);
    defer freeStringList(allocator, symbols.items);
    try appendTokens(allocator, &symbols, request.symbols);

    var findings = std.json.Array.init(allocator);
    var total_score: usize = 0;
    for (files.items) |file| {
        const score = fileRiskScore(snapshot, file);
        total_score += score;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "kind", .{ .string = "file" });
        try item.put(allocator, "file", try ownedString(allocator, file));
        try item.put(allocator, "score", .{ .integer = @intCast(score) });
        try item.put(allocator, "risk", .{ .string = riskLabel(score) });
        try item.put(allocator, "reasons", try fileRiskReasonsValue(allocator, snapshot, file));
        try findings.append(.{ .object = item });
    }
    for (symbols.items) |symbol| {
        const score = symbolRiskScore(snapshot, symbol);
        total_score += score;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "kind", .{ .string = "symbol" });
        try item.put(allocator, "symbol", try ownedString(allocator, symbol));
        try item.put(allocator, "score", .{ .integer = @intCast(score) });
        try item.put(allocator, "risk", .{ .string = riskLabel(score) });
        try findings.append(.{ .object = item });
    }
    if (request.diff) |diff| if (std.mem.indexOf(u8, diff, "pub ") != null) {
        total_score += 3;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "kind", .{ .string = "diff_signal" });
        try item.put(allocator, "signal", .{ .string = "public_api_delta" });
        try item.put(allocator, "score", .{ .integer = 3 });
        try item.put(allocator, "risk", .{ .string = "medium" });
        try findings.append(.{ .object = item });
    };

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_change_risk_audit" });
    try obj.put(allocator, "overall_risk", .{ .string = riskLabel(total_score) });
    try obj.put(allocator, "score", .{ .integer = @intCast(total_score) });
    try obj.put(allocator, "weights", try riskWeightsValue(allocator));
    try obj.put(allocator, "findings", .{ .array = findings });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "omitted_sections", try stringArrayValue(allocator, &.{"runtime coverage delta"}));
    return .{ .object = obj };
}

/// Ranks insertion sites for a topic using local names, declarations, imports,
/// and sibling path evidence.
pub fn insertionSitesValue(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: InsertionSitesRequest) ports.PortError!std.json.Value {
    var snapshot = try loadWorkspaceSnapshot(allocator, context, @max(request.limit * 10, default_limit), "static_analysis.insertion_sites");
    defer snapshot.deinit(allocator);

    var recommendations = std.json.Array.init(allocator);
    for (snapshot.sources) |source| {
        if (recommendations.items.len >= request.limit) break;
        if (request.path) |prefix| if (!std.mem.startsWith(u8, source.file, prefix)) continue;
        const score = topicScore(allocator, request.topic, source.file, source.bytes) catch 0;
        if (score == 0) continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try ownedString(allocator, source.file));
        try item.put(allocator, "score", .{ .integer = @intCast(score) });
        try item.put(allocator, "reason", try insertionReasonValue(allocator, request.topic, source.file, source.bytes));
        try item.put(allocator, "recommendation", .{ .string = "inspect this existing module before adding a new file" });
        try recommendations.append(.{ .object = item });
    }

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_insertion_sites" });
    try obj.put(allocator, "topic", try ownedString(allocator, request.topic));
    try obj.put(allocator, "recommendations", .{ .array = recommendations });
    try obj.put(allocator, "recommendation_count", .{ .integer = @intCast(recommendations.items.len) });
    try obj.put(allocator, "confidence", .{ .string = if (recommendations.items.len == 0) "low" else "medium" });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{
        "Recommendation-oriented ranking only; it does not prove ownership or design intent.",
        "Scores are based on project-local text and path evidence, not architecture policy.",
    }));
    return .{ .object = obj };
}

fn loadWorkspaceSnapshot(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, limit: usize, provenance: []const u8) ports.PortError!WorkspaceSnapshot {
    var scan = try context.workspace_scanner.scanZigFiles(allocator, .{
        .max_files = @max(limit, 1),
        .provenance = provenance,
    });
    defer scan.deinit(allocator);

    var sources: std.ArrayList(SourceRecord) = .empty;
    var tests: std.ArrayList(TestRecord) = .empty;
    var public_decls: std.ArrayList(PublicDeclRecord) = .empty;
    var helpers: std.ArrayList(HelperRecord) = .empty;
    var skipped: usize = 0;
    var partial: usize = 0;
    errdefer {
        for (sources.items) |item| item.deinit(allocator);
        sources.deinit(allocator);
        for (tests.items) |item| item.deinit(allocator);
        tests.deinit(allocator);
        for (public_decls.items) |item| item.deinit(allocator);
        public_decls.deinit(allocator);
        for (helpers.items) |item| item.deinit(allocator);
        helpers.deinit(allocator);
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
        const owned_file = try allocator.dupe(u8, file.path);
        errdefer allocator.free(owned_file);
        const owned_bytes = try allocator.dupe(u8, read.bytes);
        errdefer allocator.free(owned_bytes);
        try sources.append(allocator, .{ .file = owned_file, .bytes = owned_bytes });

        const summary = zig_analysis.parseSourceSummary(allocator, file.path, read.bytes) catch null;
        if (summary) |parsed| {
            defer parsed.deinit(allocator);
            if (parsed.parse.partial_result) partial += 1;
            for (parsed.tests) |test_item| try tests.append(allocator, try copyTestRecord(allocator, test_item.file, test_item.line, test_item.name, test_item.declaration, test_item.command));
            for (parsed.declarations) |decl| {
                if (decl.public and decl.name != null) try public_decls.append(allocator, try copyPublicDecl(allocator, file.path, decl));
                if (isHelperDecl(file.path, decl.name, decl.signature)) try helpers.append(allocator, try copyHelper(allocator, file.path, decl));
            }
        } else {
            partial += 1;
            try appendHeuristicTests(allocator, &tests, file.path, read.bytes);
            try appendHeuristicDecls(allocator, &public_decls, &helpers, file.path, read.bytes);
        }
    }

    return .{
        .sources = try sources.toOwnedSlice(allocator),
        .tests = try tests.toOwnedSlice(allocator),
        .public_decls = try public_decls.toOwnedSlice(allocator),
        .helpers = try helpers.toOwnedSlice(allocator),
        .skipped_files = skipped,
        .partial_files = partial,
    };
}

fn copyTestRecord(allocator: std.mem.Allocator, file: []const u8, line: usize, name: ?[]const u8, declaration: []const u8, command: []const u8) !TestRecord {
    return .{
        .file = try allocator.dupe(u8, file),
        .line = line,
        .name = if (name) |value| try allocator.dupe(u8, value) else null,
        .declaration = try allocator.dupe(u8, declaration),
        .command = try allocator.dupe(u8, command),
    };
}

fn copyPublicDecl(allocator: std.mem.Allocator, file: []const u8, decl: zig_analysis.Declaration) !PublicDeclRecord {
    return .{
        .file = try allocator.dupe(u8, file),
        .line = decl.line,
        .kind = try allocator.dupe(u8, decl.kind),
        .name = try allocator.dupe(u8, decl.name orelse ""),
        .signature = try allocator.dupe(u8, decl.signature),
    };
}

fn copyHelper(allocator: std.mem.Allocator, file: []const u8, decl: zig_analysis.Declaration) !HelperRecord {
    return .{
        .file = try allocator.dupe(u8, file),
        .line = decl.line,
        .name = try allocator.dupe(u8, decl.name orelse ""),
        .kind = try allocator.dupe(u8, decl.kind),
        .signature = try allocator.dupe(u8, decl.signature),
    };
}

fn appendHeuristicTests(allocator: std.mem.Allocator, tests: *std.ArrayList(TestRecord), file: []const u8, bytes: []const u8) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "test ")) continue;
        try tests.append(allocator, .{
            .file = try allocator.dupe(u8, file),
            .line = line_no,
            .name = if (project_values.testNameFromLine(trimmed)) |name| try allocator.dupe(u8, name) else null,
            .declaration = try allocator.dupe(u8, trimmed),
            .command = try std.fmt.allocPrint(allocator, "zig test {s}", .{file}),
        });
    }
}

fn appendHeuristicDecls(allocator: std.mem.Allocator, public_decls: *std.ArrayList(PublicDeclRecord), helpers: *std.ArrayList(HelperRecord), file: []const u8, bytes: []const u8) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        const kind = zig_analysis.declKind(trimmed) orelse continue;
        const name = project_values.declName(trimmed, kind) orelse continue;
        if (std.mem.startsWith(u8, trimmed, "pub ")) try public_decls.append(allocator, .{
            .file = try allocator.dupe(u8, file),
            .line = line_no,
            .kind = try allocator.dupe(u8, kind),
            .name = try allocator.dupe(u8, name),
            .signature = try allocator.dupe(u8, trimmed),
        });
        if (isHelperName(file, name)) try helpers.append(allocator, .{
            .file = try allocator.dupe(u8, file),
            .line = line_no,
            .name = try allocator.dupe(u8, name),
            .kind = try allocator.dupe(u8, kind),
            .signature = try allocator.dupe(u8, trimmed),
        });
    }
}

fn workspaceImportIndex(allocator: std.mem.Allocator, files: []const workspace_scans.ImportFile, from_file: []const u8, import_name: []const u8) !?usize {
    if (!std.mem.endsWith(u8, import_name, ".zig")) return null;
    const dir = std.fs.path.dirname(from_file) orelse "";
    const candidate = if (dir.len == 0)
        try allocator.dupe(u8, import_name)
    else
        try std.fs.path.join(allocator, &.{ dir, import_name });
    defer allocator.free(candidate);
    for (files, 0..) |file, index| {
        if (std.mem.eql(u8, file.file, candidate)) return index;
    }
    return null;
}

fn reachable(allocator: std.mem.Allocator, count: usize, edges: []const GraphEdge, start: usize, target: usize) !bool {
    if (start == target) return true;
    var seen = try allocator.alloc(bool, count);
    defer allocator.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, start);
    while (stack.pop()) |node| {
        if (node == target) return true;
        if (seen[node]) continue;
        seen[node] = true;
        for (edges) |edge| if (edge.from == node and !seen[edge.to]) try stack.append(allocator, edge.to);
    }
    return false;
}

fn mutuallyReachable(allocator: std.mem.Allocator, count: usize, edges: []const GraphEdge, a: usize, b: usize) !bool {
    return (try reachable(allocator, count, edges, a, b)) and (try reachable(allocator, count, edges, b, a));
}

fn isCycleComponent(members: []const usize, edges: []const GraphEdge) bool {
    if (members.len > 1) return true;
    if (members.len == 0) return false;
    for (edges) |edge| if (edge.from == members[0] and edge.to == members[0]) return true;
    return false;
}

fn cycleComponentValue(allocator: std.mem.Allocator, files: []const workspace_scans.ImportFile, edges: []const GraphEdge, importer_counts: []const usize, members: []const usize) !std.json.Value {
    var file_values = std.json.Array.init(allocator);
    var edge_values = std.json.Array.init(allocator);
    var importer_total: usize = 0;
    for (members) |member| {
        importer_total += importer_counts[member];
        try file_values.append(try ownedString(allocator, files[member].file));
    }
    for (edges) |edge| {
        if (!containsIndex(members, edge.from) or !containsIndex(members, edge.to)) continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "from", try ownedString(allocator, files[edge.from].file));
        try item.put(allocator, "to", try ownedString(allocator, files[edge.to].file));
        try item.put(allocator, "import", try ownedString(allocator, edge.import_name));
        try edge_values.append(.{ .object = item });
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "files", .{ .array = file_values });
    try obj.put(allocator, "size", .{ .integer = @intCast(members.len) });
    try obj.put(allocator, "edges", .{ .array = edge_values });
    try obj.put(allocator, "severity", .{ .string = cycleSeverity(members.len, importer_total) });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    return .{ .object = obj };
}

fn cyclePathValue(allocator: std.mem.Allocator, files: []const workspace_scans.ImportFile, members: []const usize) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (members) |member| try array.append(try ownedString(allocator, files[member].file));
    if (members.len > 0) try array.append(try ownedString(allocator, files[members[0]].file));
    return .{ .array = array };
}

fn importDepth(allocator: std.mem.Allocator, count: usize, edges: []const GraphEdge, target: usize) !usize {
    var max_depth: usize = 0;
    for (0..count) |start| {
        if (start == target) continue;
        if (try reachable(allocator, count, edges, start, target)) max_depth += 1;
    }
    return max_depth;
}

fn containsIndex(values: []const usize, needle: usize) bool {
    for (values) |value| if (value == needle) return true;
    return false;
}

fn cycleSeverity(largest_scc: usize, affected: usize) []const u8 {
    if (largest_scc >= 5 or affected >= 10) return "high";
    if (largest_scc >= 2 or affected > 0) return "medium";
    return "none";
}

fn testFilterMatch(filters: []const []const u8, name: []const u8) ?[]const u8 {
    for (filters) |filter| {
        if (std.mem.eql(u8, name, filter)) return "exact";
        if (std.mem.indexOf(u8, name, filter) != null) return "substring";
        if (asciiContainsIgnoreCase(name, filter)) return "case_insensitive";
    }
    return null;
}

fn testNameCount(tests: []const TestRecord, name: []const u8) usize {
    var count: usize = 0;
    for (tests) |test_record| {
        const candidate = test_record.name orelse test_record.declaration;
        if (std.mem.eql(u8, candidate, name)) count += 1;
    }
    return count;
}

fn testRecordObject(allocator: std.mem.Allocator, test_record: TestRecord) !std.json.ObjectMap {
    var item = std.json.ObjectMap.empty;
    try item.put(allocator, "file", try ownedString(allocator, test_record.file));
    try item.put(allocator, "line", .{ .integer = @intCast(test_record.line) });
    if (test_record.name) |name| try item.put(allocator, "name", try ownedString(allocator, name)) else try item.put(allocator, "name", .null);
    try item.put(allocator, "declaration", try ownedString(allocator, test_record.declaration));
    try item.put(allocator, "command", try ownedString(allocator, test_record.command));
    return item;
}

fn isHelperDecl(file: []const u8, name: ?[]const u8, signature: []const u8) bool {
    if (name) |value| if (isHelperName(file, value)) return true;
    return std.mem.indexOf(u8, signature, "std.testing") != null and std.mem.indexOf(u8, file, "test") != null;
}

fn isHelperName(file: []const u8, name: []const u8) bool {
    return containsWordIgnoreCase(file, "test") or
        containsWordIgnoreCase(file, "fixture") or
        containsWordIgnoreCase(file, "fake") or
        containsWordIgnoreCase(file, "harness") or
        containsWordIgnoreCase(name, "fixture") or
        containsWordIgnoreCase(name, "fake") or
        containsWordIgnoreCase(name, "helper") or
        containsWordIgnoreCase(name, "harness") or
        containsWordIgnoreCase(name, "expect");
}

fn symbolUseCount(sources: []const SourceRecord, symbol: []const u8, decl_file: []const u8, decl_line: usize) usize {
    var count: usize = 0;
    for (sources) |source| {
        var lines = std.mem.splitScalar(u8, source.bytes, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            if (std.mem.eql(u8, source.file, decl_file) and line_no == decl_line) continue;
            if (std.mem.indexOf(u8, line, symbol) != null) count += 1;
        }
    }
    return count;
}

fn usageSitesValue(allocator: std.mem.Allocator, sources: []const SourceRecord, symbol: []const u8, decl_file: []const u8, limit: usize) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (sources) |source| {
        var lines = std.mem.splitScalar(u8, source.bytes, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            if (array.items.len >= limit) return .{ .array = array };
            if (std.mem.eql(u8, source.file, decl_file) and std.mem.indexOf(u8, line, symbol) != null) continue;
            if (std.mem.indexOf(u8, line, symbol) == null) continue;
            var item = std.json.ObjectMap.empty;
            try item.put(allocator, "file", try ownedString(allocator, source.file));
            try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
            try item.put(allocator, "text", try ownedString(allocator, std.mem.trim(u8, line, " \t")));
            try array.append(.{ .object = item });
        }
    }
    return .{ .array = array };
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

fn safetyKind(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "catch unreachable") != null) return "catch_unreachable";
    if (std.mem.indexOf(u8, line, "@panic(") != null) return "panic";
    if (std.mem.indexOf(u8, line, "unreachable") != null) return "unreachable";
    if (std.mem.indexOf(u8, line, "@ptrCast(") != null) return "unchecked_cast_ptr";
    if (std.mem.indexOf(u8, line, "@alignCast(") != null) return "unchecked_cast_align";
    if (std.mem.indexOf(u8, line, "@bitCast(") != null) return "unchecked_cast_bit";
    if (std.mem.indexOf(u8, line, "@intFromPtr(") != null or std.mem.indexOf(u8, line, "@ptrFromInt(") != null) return "pointer_integer_cast";
    if (std.mem.indexOf(u8, line, "@enumFromInt(") != null or std.mem.indexOf(u8, line, "@truncate(") != null) return "unchecked_integer_cast";
    return null;
}

fn testSymbolScore(sources: []const SourceRecord, test_record: TestRecord, symbol: []const u8) usize {
    var score: usize = 0;
    if (test_record.name) |name| {
        if (std.mem.indexOf(u8, name, symbol) != null) score += 5;
    }
    if (std.mem.indexOf(u8, test_record.declaration, symbol) != null) score += 3;
    for (sources) |source| {
        if (!std.mem.eql(u8, source.file, test_record.file)) continue;
        if (std.mem.indexOf(u8, source.bytes, symbol) != null) score += 2;
    }
    return score;
}

fn testSymbolReason(score: usize) []const u8 {
    if (score >= 5) return "test name/declaration mentions the symbol";
    if (score >= 2) return "test file source mentions the symbol";
    return "weak source proximity";
}

fn publicDeclObject(allocator: std.mem.Allocator, decl: PublicDeclRecord) !std.json.ObjectMap {
    var item = std.json.ObjectMap.empty;
    try item.put(allocator, "file", try ownedString(allocator, decl.file));
    try item.put(allocator, "line", .{ .integer = @intCast(decl.line) });
    try item.put(allocator, "kind", try ownedString(allocator, decl.kind));
    try item.put(allocator, "name", try ownedString(allocator, decl.name));
    try item.put(allocator, "signature", try ownedString(allocator, decl.signature));
    return item;
}

fn publicDeclObjectValue(allocator: std.mem.Allocator, decl: PublicDeclRecord) !std.json.Value {
    return .{ .object = try publicDeclObject(allocator, decl) };
}

fn sourceImportsPrefix(bytes: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    return std.mem.indexOf(u8, bytes, prefix) != null;
}

fn moduleRoleHintsValue(allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    if (containsWordIgnoreCase(path, "test")) try array.append(.{ .string = "test_support" });
    if (containsWordIgnoreCase(path, "domain")) try array.append(.{ .string = "domain_logic" });
    if (containsWordIgnoreCase(path, "adapter")) try array.append(.{ .string = "adapter_boundary" });
    if (containsWordIgnoreCase(path, "tool")) try array.append(.{ .string = "tool_projection" });
    if (array.items.len == 0) try array.append(.{ .string = "project_local_module" });
    return .{ .array = array };
}

fn moduleRoleHintsForSymbolValue(allocator: std.mem.Allocator, decls: []const PublicDeclRecord, symbol: []const u8) !std.json.Value {
    for (decls) |decl| if (std.mem.eql(u8, decl.name, symbol)) return moduleRoleHintsValue(allocator, decl.file);
    return moduleRoleHintsValue(allocator, "");
}

fn appendSymbolLineMatches(allocator: std.mem.Allocator, out: *std.json.Array, sources: []const SourceRecord, symbol: []const u8, limit: usize) !void {
    for (sources) |source| {
        var lines = std.mem.splitScalar(u8, source.bytes, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            if (out.items.len >= limit) return;
            if (std.mem.indexOf(u8, line, symbol) == null) continue;
            var item = std.json.ObjectMap.empty;
            try item.put(allocator, "file", try ownedString(allocator, source.file));
            try item.put(allocator, "line", .{ .integer = @intCast(line_no) });
            try item.put(allocator, "text", try ownedString(allocator, std.mem.trim(u8, line, " \t")));
            try out.append(.{ .object = item });
        }
    }
}

fn appendFilesFromDiff(allocator: std.mem.Allocator, files: *std.ArrayList([]const u8), diff: ?[]const u8) !void {
    const text = diff orelse return;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const prefix = "+++ b/";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const path = line[prefix.len..];
        if (path.len == 0 or std.mem.eql(u8, path, "/dev/null")) continue;
        try appendUniqueToken(allocator, files, path);
    }
}

fn fileRiskScore(snapshot: WorkspaceSnapshot, file: []const u8) usize {
    var score: usize = 0;
    if (std.mem.eql(u8, file, "build.zig") or std.mem.eql(u8, file, "build.zig.zon")) score += 3;
    for (snapshot.public_decls) |decl| {
        if (std.mem.eql(u8, decl.file, file)) score += 2;
    }
    for (snapshot.sources) |source| {
        if (!std.mem.eql(u8, source.file, file) and std.mem.indexOf(u8, source.bytes, file) != null) score += 1;
    }
    for (snapshot.tests) |test_record| {
        if (std.mem.eql(u8, test_record.file, file)) score = if (score > 0) score - 1 else 0;
    }
    return score;
}

fn symbolRiskScore(snapshot: WorkspaceSnapshot, symbol: []const u8) usize {
    var score: usize = 0;
    for (snapshot.public_decls) |decl| {
        if (std.mem.eql(u8, decl.name, symbol)) score += 3;
    }
    score += @min(symbolUseCount(snapshot.sources, symbol, "", 0), 5);
    return score;
}

fn fileRiskReasonsValue(allocator: std.mem.Allocator, snapshot: WorkspaceSnapshot, file: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    if (std.mem.eql(u8, file, "build.zig") or std.mem.eql(u8, file, "build.zig.zon")) try array.append(.{ .string = "build or dependency metadata" });
    for (snapshot.public_decls) |decl| if (std.mem.eql(u8, decl.file, file)) {
        try array.append(.{ .string = "public API declaration in file" });
        break;
    };
    if (array.items.len == 0) try array.append(.{ .string = "localized source change" });
    return .{ .array = array };
}

fn riskWeightsValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "public_api_delta", .{ .integer = 3 });
    try obj.put(allocator, "build_metadata", .{ .integer = 3 });
    try obj.put(allocator, "importer_reference", .{ .integer = 1 });
    try obj.put(allocator, "test_coverage_presence", .{ .integer = -1 });
    return .{ .object = obj };
}

fn riskLabel(score: usize) []const u8 {
    if (score >= 8) return "high";
    if (score >= 3) return "medium";
    return "low";
}

fn topicScore(allocator: std.mem.Allocator, topic: []const u8, file: []const u8, bytes: []const u8) !usize {
    var score: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, topic, " .,_-/\t\r\n");
    while (tokens.next()) |token| {
        if (token.len < 3) continue;
        if (containsWordIgnoreCase(file, token)) score += 3;
        if (try containsTextIgnoreCase(allocator, bytes, token)) score += 1;
    }
    return score;
}

fn insertionReasonValue(allocator: std.mem.Allocator, topic: []const u8, file: []const u8, bytes: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var tokens = std.mem.tokenizeAny(u8, topic, " .,_-/\t\r\n");
    while (tokens.next()) |token| {
        if (token.len < 3) continue;
        if (containsWordIgnoreCase(file, token)) try array.append(.{ .string = try std.fmt.allocPrint(allocator, "path matches `{s}`", .{token}) });
        if (try containsTextIgnoreCase(allocator, bytes, token)) try array.append(.{ .string = try std.fmt.allocPrint(allocator, "source mentions `{s}`", .{token}) });
        if (array.items.len >= 3) break;
    }
    if (array.items.len == 0) try array.append(.{ .string = "weak project-local similarity" });
    return .{ .array = array };
}

fn appendTokens(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), text: ?[]const u8) !void {
    const raw = text orelse return;
    var tokens = std.mem.tokenizeAny(u8, raw, ",\n\r\t ");
    while (tokens.next()) |token| try appendUniqueToken(allocator, list, token);
}

fn appendUniqueToken(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), token: []const u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, token)) return;
    try list.append(allocator, try allocator.dupe(u8, token));
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
}

fn appendUniqueStringValue(allocator: std.mem.Allocator, array: *std.json.Array, value: []const u8) !void {
    for (array.items) |item| switch (item) {
        .string => |existing| if (std.mem.eql(u8, existing, value)) return,
        else => {},
    };
    try array.append(try ownedString(allocator, value));
}

fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

fn containsWordIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    // Compare case-insensitively without a fixed-size buffer so needles longer
    // than 128 bytes (e.g. a long caller-supplied topic) are not silently dropped.
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn containsTextIgnoreCase(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8) !bool {
    const lower_haystack = try std.ascii.allocLowerString(allocator, haystack);
    defer allocator.free(lower_haystack);
    const lower_needle = try std.ascii.allocLowerString(allocator, needle);
    defer allocator.free(lower_needle);
    return std.mem.indexOf(u8, lower_haystack, lower_needle) != null;
}

const fakes = @import("../../../testing/fakes/root.zig");

test "import cycles reports workspace SCCs without architecture policy labels" {
    var fake_scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer fake_scanner.deinit();
    var fake_workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer fake_workspace.deinit();

    try fake_scanner.expectScan(.{
        .path_prefix = "",
        .max_files = 4,
        .provenance = "static_analysis.import_graph",
    }, &.{ "src/a.zig", "src/b.zig", "src/c.zig" });
    try fake_workspace.expectRead(.{
        .path = "src/a.zig",
        .max_bytes = max_source_read,
        .provenance = "static_analysis.import_graph",
    }, "const b = @import(\"b.zig\");\n");
    try fake_workspace.expectRead(.{
        .path = "src/b.zig",
        .max_bytes = max_source_read,
        .provenance = "static_analysis.import_graph",
    }, "const a = @import(\"a.zig\");\n");
    try fake_workspace.expectRead(.{
        .path = "src/c.zig",
        .max_bytes = max_source_read,
        .provenance = "static_analysis.import_graph",
    }, "const std = @import(\"std\");\n");

    const ctx = app_context.StaticAnalysisContext{
        .workspace = .{ .root = "/workspace" },
        .workspace_store = fake_workspace.port(),
        .workspace_scanner = fake_scanner.port(),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try importCyclesValue(arena.allocator(), ctx, .{ .limit = 4 });
    const obj = value.object;
    try std.testing.expectEqual(@as(i64, 1), obj.get("cycle_count").?.integer);
    try std.testing.expectEqualStrings("medium", obj.get("severity").?.string);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("policy").?.string, "hexagonal") == null);
    try fake_scanner.verify();
    try fake_workspace.verify();
}

test "safety catalog ignores obvious comments and strings" {
    var fake_scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer fake_scanner.deinit();
    var fake_workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer fake_workspace.deinit();

    try fake_scanner.expectScan(.{
        .path_prefix = "",
        .max_files = 10,
        .provenance = "static_analysis.safety_site_catalog",
    }, &.{"src/main.zig"});
    try fake_workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = max_source_read,
        .provenance = "static_analysis.safety_site_catalog",
    },
        \\// @panic("comment")
        \\const text = "unreachable";
        \\fn f() void { _ = foo() catch unreachable; }
    );

    const ctx = app_context.StaticAnalysisContext{
        .workspace = .{ .root = "/workspace" },
        .workspace_store = fake_workspace.port(),
        .workspace_scanner = fake_scanner.port(),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try safetySiteCatalogValue(arena.allocator(), ctx, .{ .limit = 10 });
    const sites = value.object.get("sites").?.array;
    try std.testing.expectEqual(@as(usize, 1), sites.items.len);
    try std.testing.expectEqualStrings("catch_unreachable", sites.items[0].object.get("kind").?.string);
}

test "containsWordIgnoreCase matches needles longer than 128 bytes" {
    // A topic token longer than the former 128-byte buffer ceiling must still
    // match case-insensitively rather than silently returning false.
    const needle = "Aa" ** 80; // 160 bytes, > 128
    try std.testing.expect(needle.len > 128);

    var haystack: [256]u8 = undefined;
    const lowered = std.ascii.lowerString(haystack[0..needle.len], needle);
    try std.testing.expect(containsWordIgnoreCase(lowered, needle));
    try std.testing.expect(containsWordIgnoreCase("prefix/" ++ ("aA" ** 80), needle));
    try std.testing.expect(!containsWordIgnoreCase("short", needle));
}
