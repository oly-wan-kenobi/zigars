const std = @import("std");

pub const ParseStatus = enum {
    ok,
    syntax_errors,
    heuristic_fallback,
};

pub const ParseMetadata = struct {
    status: ParseStatus = .ok,
    partial_result: bool = false,
    result_complete: bool = true,
    parse_error_count: i64 = 0,
};

pub const Declaration = struct {
    line: usize,
    kind: []const u8,
    name: ?[]const u8 = null,
    public: bool = false,
    is_comptime: bool = false,
    depth: usize = 0,
    signature: []const u8,

    pub fn deinit(self: Declaration, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        if (self.name) |name| allocator.free(name);
        allocator.free(self.signature);
    }
};

pub const Import = struct {
    file: []const u8,
    line: usize,
    import: []const u8,
    alias: ?[]const u8 = null,
    declaration: []const u8,

    pub fn deinit(self: Import, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.import);
        if (self.alias) |alias| allocator.free(alias);
        allocator.free(self.declaration);
    }
};

pub const TestDecl = struct {
    file: []const u8,
    line: usize,
    name: ?[]const u8 = null,
    declaration: []const u8,
    command: []const u8,

    pub fn deinit(self: TestDecl, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        if (self.name) |name| allocator.free(name);
        allocator.free(self.declaration);
        allocator.free(self.command);
    }
};

pub const DeclarationList = struct {
    items: []Declaration,

    pub fn deinit(self: DeclarationList, allocator: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const SourceSummary = struct {
    parse: ParseMetadata,
    declarations: []Declaration,
    imports: []Import,
    tests: []TestDecl,

    pub fn deinit(self: SourceSummary, allocator: std.mem.Allocator) void {
        for (self.declarations) |item| item.deinit(allocator);
        allocator.free(self.declarations);
        for (self.imports) |item| item.deinit(allocator);
        allocator.free(self.imports);
        for (self.tests) |item| item.deinit(allocator);
        allocator.free(self.tests);
    }
};

pub fn parseStatusName(status: ParseStatus) []const u8 {
    return @tagName(status);
}

pub fn parseSourceSummary(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) !SourceSummary {
    var tree = try parseAst(allocator, contents);
    const parsed_source = tree.source;
    defer tree.deinit(allocator);
    defer allocator.free(parsed_source);

    var declarations: std.ArrayList(Declaration) = .empty;
    var imports: std.ArrayList(Import) = .empty;
    var tests: std.ArrayList(TestDecl) = .empty;
    errdefer deinitDeclarations(allocator, declarations.items);
    errdefer declarations.deinit(allocator);
    errdefer deinitImports(allocator, imports.items);
    errdefer imports.deinit(allocator);
    errdefer deinitTests(allocator, tests.items);
    errdefer tests.deinit(allocator);

    try appendAstDecls(allocator, &tree, tree.rootDecls(), &declarations, 0);
    try appendAstImports(allocator, file, &tree, &imports);
    try appendAstTests(allocator, file, &tree, &tests);

    return .{
        .parse = parseMetadata(tree),
        .declarations = try declarations.toOwnedSlice(allocator),
        .imports = try imports.toOwnedSlice(allocator),
        .tests = try tests.toOwnedSlice(allocator),
    };
}

pub fn heuristicDeclarations(allocator: std.mem.Allocator, contents: []const u8) !DeclarationList {
    var declarations: std.ArrayList(Declaration) = .empty;
    errdefer deinitDeclarations(allocator, declarations.items);
    errdefer declarations.deinit(allocator);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        const kind = declKind(trimmed) orelse continue;
        try declarations.append(allocator, try declarationFromLine(allocator, line_no, trimmed, kind, 0, false));
    }
    return .{ .items = try declarations.toOwnedSlice(allocator) };
}

pub fn declarationSummaryText(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "# Declaration summary for {s}\n\n", .{file});
    try out.appendSlice(allocator, "Capability tier: advisory_orientation. Confidence: medium heuristic text scan (orientation_only). Verify with `zig_ast_decl_summary`, ZLS, or `zig ast-check` before making destructive edits.\n\n");

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    var count: usize = 0;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (isDeclarationSummaryLine(trimmed)) {
            count += 1;
            try out.print(allocator, "- {d}: `{s}`\n", .{ line_no, trimmed });
        }
    }
    if (count == 0) try out.appendSlice(allocator, "No top-level-looking declarations found.\n");
    return out.toOwnedSlice(allocator);
}

pub fn allocationSummaryText(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    return keywordSummaryText(allocator, file, contents, "allocation-related sites", &.{
        ".alloc(",
        ".create(",
        ".dupe(",
        "ArrayList",
        "ArenaAllocator",
        "GeneralPurposeAllocator",
    }, "Capability tier: advisory_orientation. Confidence: low heuristic keyword scan (orientation_only). Review matches before acting.\n\n");
}

pub fn errorSetSummaryText(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    return keywordSummaryText(allocator, file, contents, "error-related sites", &.{
        "error{",
        "anyerror",
        "catch",
        "try ",
        "!",
    }, "Capability tier: advisory_orientation. Confidence: low heuristic keyword scan (orientation_only). Review matches before acting.\n\n");
}

pub fn publicApiSummaryText(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    return keywordSummaryText(allocator, file, contents, "public API declarations", &.{
        "pub const ",
        "pub var ",
        "pub fn ",
        "pub extern ",
        "pub export ",
    }, "Capability tier: advisory_orientation. Confidence: medium heuristic keyword scan (advisory). Comparison basis is public-looking source lines; verify API changes with `zig_ast_decl_summary`, ZLS, compiler checks, and release review.\n\n");
}

pub fn deadDeclCandidatesText(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "# Dead declaration candidates for {s}\n\n", .{file});
    try out.appendSlice(allocator, "Capability tier: advisory_orientation. Confidence: low heuristic (orientation_only). Private declarations listed here still need ZLS references, workspace search, and tests before deletion.\n\n");

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    var count: usize = 0;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "const ") or std.mem.startsWith(u8, trimmed, "fn ")) {
            count += 1;
            try out.print(allocator, "- {d}: `{s}`\n", .{ line_no, trimmed });
        }
    }
    if (count == 0) try out.appendSlice(allocator, "No obvious private top-level declarations found.\n");
    return out.toOwnedSlice(allocator);
}

fn keywordSummaryText(
    allocator: std.mem.Allocator,
    file: []const u8,
    contents: []const u8,
    title: []const u8,
    keywords: []const []const u8,
    confidence_line: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "# {s} for {s}\n\n", .{ title, file });
    try out.appendSlice(allocator, confidence_line);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    var count: usize = 0;
    while (lines.next()) |line| : (line_no += 1) {
        for (keywords) |keyword| {
            if (std.mem.indexOf(u8, line, keyword) != null) {
                count += 1;
                try out.print(allocator, "- {d}: `{s}`\n", .{ line_no, std.mem.trim(u8, line, " \t") });
                break;
            }
        }
    }
    if (count == 0) try out.appendSlice(allocator, "No matches found.\n");
    return out.toOwnedSlice(allocator);
}

fn parseAst(allocator: std.mem.Allocator, contents: []const u8) !std.zig.Ast {
    const source = try allocator.dupeZ(u8, contents);
    return std.zig.Ast.parse(allocator, source, .zig);
}

fn parseMetadata(tree: std.zig.Ast) ParseMetadata {
    const has_errors = tree.errors.len != 0;
    return .{
        .status = if (has_errors) .syntax_errors else .ok,
        .partial_result = has_errors,
        .result_complete = !has_errors,
        .parse_error_count = @intCast(tree.errors.len),
    };
}

fn appendAstDecls(allocator: std.mem.Allocator, tree: *const std.zig.Ast, nodes: []const std.zig.Ast.Node.Index, declarations: *std.ArrayList(Declaration), depth: usize) anyerror!void {
    for (nodes) |node| try appendAstDecl(allocator, tree, node, declarations, depth);
}

fn appendAstDecl(allocator: std.mem.Allocator, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index, declarations: *std.ArrayList(Declaration), depth: usize) anyerror!void {
    switch (tree.nodeTag(node)) {
        .global_var_decl, .simple_var_decl, .aligned_var_decl => {
            const decl = tree.fullVarDecl(node).?;
            try declarations.append(allocator, try astVarDecl(allocator, tree.*, node, decl, depth));
            if (decl.ast.init_node.unwrap()) |init_node| try appendAstContainerOrBlockDecls(allocator, tree, init_node, declarations, depth + 1);
        },
        .fn_decl, .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, node).?;
            try declarations.append(allocator, try astFnDecl(allocator, tree.*, node, proto, depth));
        },
        .test_decl => try declarations.append(allocator, try astTestDecl(allocator, tree.*, node, depth)),
        .@"comptime" => try appendAstContainerOrBlockDecls(allocator, tree, tree.nodeData(node).node, declarations, depth + 1),
        else => try appendAstContainerOrBlockDecls(allocator, tree, node, declarations, depth),
    }
}

fn appendAstContainerOrBlockDecls(allocator: std.mem.Allocator, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index, declarations: *std.ArrayList(Declaration), depth: usize) anyerror!void {
    var container_buffer: [2]std.zig.Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_buffer, node)) |container| {
        try appendAstDecls(allocator, tree, container.ast.members, declarations, depth);
        return;
    }
    var block_buffer: [2]std.zig.Ast.Node.Index = undefined;
    if (tree.blockStatements(&block_buffer, node)) |statements| {
        try appendAstDecls(allocator, tree, statements, declarations, depth);
    }
}

fn astVarDecl(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index, decl: std.zig.Ast.full.VarDecl, depth: usize) !Declaration {
    return .{
        .line = lineForNode(tree, node),
        .kind = try allocator.dupe(u8, tree.tokenSlice(decl.ast.mut_token)),
        .name = try astOptionalIdentifier(allocator, tree, decl.ast.mut_token + 1),
        .public = decl.visib_token != null,
        .is_comptime = decl.comptime_token != null,
        .depth = depth,
        .signature = try allocator.dupe(u8, compactNodeSource(tree.getNodeSource(node))),
    };
}

fn astFnDecl(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index, proto: std.zig.Ast.full.FnProto, depth: usize) !Declaration {
    return .{
        .line = lineForNode(tree, node),
        .kind = try allocator.dupe(u8, "fn"),
        .name = if (proto.name_token) |token| try allocator.dupe(u8, tree.tokenSlice(token)) else null,
        .public = proto.visib_token != null,
        .is_comptime = false,
        .depth = depth,
        .signature = try allocator.dupe(u8, compactNodeSource(tree.getNodeSource(node))),
    };
}

fn astTestDecl(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index, depth: usize) !Declaration {
    return .{
        .line = lineForNode(tree, node),
        .kind = try allocator.dupe(u8, "test"),
        .name = try astTestName(allocator, tree, node),
        .public = false,
        .is_comptime = false,
        .depth = depth,
        .signature = try allocator.dupe(u8, compactNodeSource(tree.getNodeSource(node))),
    };
}

fn appendAstImports(allocator: std.mem.Allocator, file: []const u8, tree: *const std.zig.Ast, imports: *std.ArrayList(Import)) !void {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    for (0..tree.nodes.len) |node_i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(@as(u32, @intCast(node_i)));
        const tag = tree.nodeTag(node);
        if (tag != .builtin_call and tag != .builtin_call_comma and tag != .builtin_call_two and tag != .builtin_call_two_comma) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) continue;
        const params = tree.builtinCallParams(&buffer, node) orelse continue;
        if (params.len == 0 or tree.nodeTag(params[0]) != .string_literal) continue;
        try imports.append(allocator, .{
            .file = try allocator.dupe(u8, file),
            .line = lineForNode(tree.*, node),
            .import = try astStringLiteral(allocator, tree.*, params[0]),
            .alias = try astImportAlias(allocator, tree.*, node),
            .declaration = try allocator.dupe(u8, tree.getNodeSource(node)),
        });
    }
}

fn appendAstTests(allocator: std.mem.Allocator, file: []const u8, tree: *const std.zig.Ast, tests: *std.ArrayList(TestDecl)) !void {
    for (0..tree.nodes.len) |node_i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(@as(u32, @intCast(node_i)));
        if (tree.nodeTag(node) != .test_decl) continue;
        try tests.append(allocator, .{
            .file = try allocator.dupe(u8, file),
            .line = lineForNode(tree.*, node),
            .name = try astTestName(allocator, tree.*, node),
            .declaration = try allocator.dupe(u8, compactNodeSource(tree.getNodeSource(node))),
            .command = try std.fmt.allocPrint(allocator, "zig test {s}", .{file}),
        });
    }
}

fn astTestName(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index) !?[]const u8 {
    const name_token = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse return null;
    if (tree.tokenTag(name_token) == .string_literal) return try astStringLiteralToken(allocator, tree, name_token);
    return try allocator.dupe(u8, tree.tokenSlice(name_token));
}

fn astStringLiteral(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index) ![]const u8 {
    return astStringLiteralToken(allocator, tree, tree.nodeMainToken(node));
}

fn astImportAlias(allocator: std.mem.Allocator, tree: std.zig.Ast, import_node: std.zig.Ast.Node.Index) !?[]const u8 {
    for (0..tree.nodes.len) |node_i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(@as(u32, @intCast(node_i)));
        switch (tree.nodeTag(node)) {
            .global_var_decl, .simple_var_decl, .aligned_var_decl => {
                const decl = tree.fullVarDecl(node).?;
                const init_node = decl.ast.init_node.unwrap() orelse continue;
                if (init_node == import_node) return astOptionalIdentifier(allocator, tree, decl.ast.mut_token + 1);
            },
            else => {},
        }
    }
    return null;
}

fn astStringLiteralToken(allocator: std.mem.Allocator, tree: std.zig.Ast, token: std.zig.Ast.TokenIndex) ![]const u8 {
    const raw = tree.tokenSlice(token);
    return std.zig.string_literal.parseAlloc(allocator, raw) catch allocator.dupe(u8, stripQuotes(raw));
}

fn astOptionalIdentifier(allocator: std.mem.Allocator, tree: std.zig.Ast, token: std.zig.Ast.TokenIndex) !?[]const u8 {
    if (token < tree.tokens.len and tree.tokenTag(token) == .identifier) return try allocator.dupe(u8, tree.tokenSlice(token));
    return null;
}

fn declarationFromLine(allocator: std.mem.Allocator, line_no: usize, trimmed: []const u8, kind: []const u8, depth: usize, comptime_decl: bool) !Declaration {
    return .{
        .line = line_no,
        .kind = try allocator.dupe(u8, kind),
        .name = if (declName(trimmed, kind)) |name| try allocator.dupe(u8, name) else null,
        .public = std.mem.startsWith(u8, trimmed, "pub "),
        .is_comptime = comptime_decl,
        .depth = depth,
        .signature = try allocator.dupe(u8, trimmed),
    };
}

fn lineForNode(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) usize {
    return tree.tokenLocation(0, tree.firstToken(node)).line + 1;
}

fn compactNodeSource(source: []const u8) []const u8 {
    return std.mem.trim(u8, source, " \t\r\n");
}

fn stripQuotes(raw: []const u8) []const u8 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') return raw[1 .. raw.len - 1];
    return raw;
}

fn deinitDeclarations(allocator: std.mem.Allocator, declarations: []Declaration) void {
    for (declarations) |item| item.deinit(allocator);
}

fn deinitImports(allocator: std.mem.Allocator, imports: []Import) void {
    for (imports) |item| item.deinit(allocator);
}

fn deinitTests(allocator: std.mem.Allocator, tests: []TestDecl) void {
    for (tests) |item| item.deinit(allocator);
}

pub fn declKind(line: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, line, "pub ")) line["pub ".len..] else line;
    if (std.mem.startsWith(u8, rest, "const ")) return "const";
    if (std.mem.startsWith(u8, rest, "var ")) return "var";
    if (std.mem.startsWith(u8, rest, "fn ")) return "fn";
    if (std.mem.startsWith(u8, rest, "extern ")) return "extern";
    if (std.mem.startsWith(u8, rest, "export ")) return "export";
    return null;
}

pub fn declName(line: []const u8, kind: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, line, "pub ")) line["pub ".len..] else line;
    const prefix_len = kind.len + 1;
    if (rest.len <= prefix_len) return null;
    var name = std.mem.trim(u8, rest[prefix_len..], " \t");
    const end = std.mem.indexOfAny(u8, name, " (:=,{") orelse name.len;
    name = name[0..end];
    return if (name.len == 0) null else name;
}

pub fn skipWorkspacePath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, ".zig-cache") or
        std.mem.startsWith(u8, path, ".zigar-cache") or
        std.mem.startsWith(u8, path, "zig-out") or
        std.mem.startsWith(u8, path, "zig-pkg") or
        std.mem.indexOf(u8, path, "/.zig-cache/") != null or
        std.mem.indexOf(u8, path, "/.zigar-cache/") != null or
        std.mem.indexOf(u8, path, "/zig-out/") != null or
        std.mem.indexOf(u8, path, "/zig-pkg/") != null;
}

fn isDeclarationSummaryLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "pub const ") or
        std.mem.startsWith(u8, line, "pub var ") or
        std.mem.startsWith(u8, line, "pub fn ") or
        std.mem.startsWith(u8, line, "const ") or
        std.mem.startsWith(u8, line, "var ") or
        std.mem.startsWith(u8, line, "fn ");
}

test "parser-backed source summary covers static-analysis fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const summary = try parseSourceSummary(arena.allocator(), "fixture.zig", @embedFile("fixtures/static_analysis_tricky.fixture"));
    try std.testing.expectEqual(ParseStatus.ok, summary.parse.status);
    try std.testing.expect(!summary.parse.partial_result);
    try std.testing.expect(hasDeclaration(summary.declarations, "Outer"));
    try std.testing.expect(hasDeclaration(summary.declarations, "nested"));
    try std.testing.expect(hasDeclaration(summary.declarations, "LocalErrors"));
    try std.testing.expect(hasImport(summary.imports, "std", "std"));
    try std.testing.expect(hasImport(summary.imports, "math.zig", "math_alias"));
    try std.testing.expect(hasTest(summary.tests, "outer works"));
    try std.testing.expect(hasTest(summary.tests, "escaped \"quote\" text"));
}

test "parser-backed source summary marks malformed fixtures partial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const malformed = try parseSourceSummary(arena.allocator(), "malformed.zig", @embedFile("fixtures/static_analysis_malformed.fixture"));
    try std.testing.expectEqual(ParseStatus.syntax_errors, malformed.parse.status);
    try std.testing.expect(malformed.parse.partial_result);
    try std.testing.expect(!malformed.parse.result_complete);
    try std.testing.expect(malformed.parse.parse_error_count > 0);
    try std.testing.expect(hasImportValue(malformed.imports, "std"));

    const sample = try parseSourceSummary(arena.allocator(), "usingnamespace.zig", @embedFile("fixtures/static_analysis_usingnamespace.fixture"));
    try std.testing.expectEqual(ParseStatus.syntax_errors, sample.parse.status);
    try std.testing.expect(hasImport(sample.imports, "std", "std"));
}

test "heuristic summaries preserve advisory source policy" {
    const text =
        \\pub fn main() void {}
        \\const Hidden = struct {};
        \\const std = @import("std");
    ;
    const summary = try declarationSummaryText(std.testing.allocator, "x.zig", text);
    defer std.testing.allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Capability tier: advisory_orientation") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "pub fn main") != null);

    const allocations = try allocationSummaryText(std.testing.allocator, "x.zig", "var list: std.ArrayList(u8) = .empty;\n");
    defer std.testing.allocator.free(allocations);
    try std.testing.expect(std.mem.indexOf(u8, allocations, "ArrayList") != null);
}

test "workspace skip policy remains cache and artifact oriented" {
    try std.testing.expect(skipWorkspacePath(".zig-cache/o/file.zig"));
    try std.testing.expect(skipWorkspacePath(".zigar-cache/profile/out.zig"));
    try std.testing.expect(skipWorkspacePath("zig-out/bin/main.zig"));
    try std.testing.expect(skipWorkspacePath("zig-pkg/mcp/src/server.zig"));
    try std.testing.expect(!skipWorkspacePath("src/main.zig"));
}

fn hasDeclaration(items: []const Declaration, name: []const u8) bool {
    for (items) |item| {
        if (item.name) |actual| if (std.mem.eql(u8, actual, name)) return true;
    }
    return false;
}

fn hasImport(items: []const Import, import_name: []const u8, alias: []const u8) bool {
    for (items) |item| {
        if (!std.mem.eql(u8, item.import, import_name)) continue;
        if (item.alias) |actual| if (std.mem.eql(u8, actual, alias)) return true;
    }
    return false;
}

fn hasImportValue(items: []const Import, import_name: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.import, import_name)) return true;
    }
    return false;
}

fn hasTest(items: []const TestDecl, name: []const u8) bool {
    for (items) |item| {
        if (item.name) |actual| if (std.mem.eql(u8, actual, name)) return true;
    }
    return false;
}
