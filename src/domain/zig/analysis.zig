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
    errdefer {
        deinitDeclarations(allocator, declarations.items);
        declarations.deinit(allocator);
        deinitImports(allocator, imports.items);
        imports.deinit(allocator);
        deinitTests(allocator, tests.items);
        tests.deinit(allocator);
    }

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
    errdefer {
        deinitDeclarations(allocator, declarations.items);
        declarations.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        const kind = declKind(trimmed) orelse continue;
        try appendOwnedDeclaration(allocator, &declarations, try declarationFromLine(allocator, line_no, trimmed, kind, 0, false));
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
            try appendOwnedDeclaration(allocator, declarations, try astVarDecl(allocator, tree.*, node, decl, depth));
            if (decl.ast.init_node.unwrap()) |init_node| try appendAstContainerOrBlockDecls(allocator, tree, init_node, declarations, depth + 1);
        },
        .fn_decl, .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, node).?;
            try appendOwnedDeclaration(allocator, declarations, try astFnDecl(allocator, tree.*, node, proto, depth));
        },
        .test_decl => try appendOwnedDeclaration(allocator, declarations, try astTestDecl(allocator, tree.*, node, depth)),
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
    const kind = try allocator.dupe(u8, tree.tokenSlice(decl.ast.mut_token));
    errdefer allocator.free(kind);
    const name = try astOptionalIdentifier(allocator, tree, decl.ast.mut_token + 1);
    errdefer if (name) |owned| allocator.free(owned);
    const signature = try allocator.dupe(u8, compactNodeSource(tree.getNodeSource(node)));
    return .{
        .line = lineForNode(tree, node),
        .kind = kind,
        .name = name,
        .public = decl.visib_token != null,
        .is_comptime = decl.comptime_token != null,
        .depth = depth,
        .signature = signature,
    };
}

fn astFnDecl(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index, proto: std.zig.Ast.full.FnProto, depth: usize) !Declaration {
    const kind = try allocator.dupe(u8, "fn");
    errdefer allocator.free(kind);
    const name = if (proto.name_token) |token| try allocator.dupe(u8, tree.tokenSlice(token)) else null;
    errdefer if (name) |owned| allocator.free(owned);
    const signature = try allocator.dupe(u8, compactNodeSource(tree.getNodeSource(node)));
    return .{
        .line = lineForNode(tree, node),
        .kind = kind,
        .name = name,
        .public = proto.visib_token != null,
        .is_comptime = false,
        .depth = depth,
        .signature = signature,
    };
}

fn astTestDecl(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index, depth: usize) !Declaration {
    const kind = try allocator.dupe(u8, "test");
    errdefer allocator.free(kind);
    const name = try astTestName(allocator, tree, node);
    errdefer if (name) |owned| allocator.free(owned);
    const signature = try allocator.dupe(u8, compactNodeSource(tree.getNodeSource(node)));
    return .{
        .line = lineForNode(tree, node),
        .kind = kind,
        .name = name,
        .public = false,
        .is_comptime = false,
        .depth = depth,
        .signature = signature,
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
        try appendOwnedImport(allocator, imports, try astImportDecl(allocator, file, tree.*, node, params[0]));
    }
}

fn appendAstTests(allocator: std.mem.Allocator, file: []const u8, tree: *const std.zig.Ast, tests: *std.ArrayList(TestDecl)) !void {
    for (0..tree.nodes.len) |node_i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(@as(u32, @intCast(node_i)));
        if (tree.nodeTag(node) != .test_decl) continue;
        try appendOwnedTestDecl(allocator, tests, try astTestRun(allocator, file, tree.*, node));
    }
}

fn appendOwnedDeclaration(allocator: std.mem.Allocator, declarations: *std.ArrayList(Declaration), declaration: Declaration) !void {
    var owned = declaration;
    errdefer owned.deinit(allocator);
    try declarations.append(allocator, owned);
}

fn appendOwnedImport(allocator: std.mem.Allocator, imports: *std.ArrayList(Import), import: Import) !void {
    var owned = import;
    errdefer owned.deinit(allocator);
    try imports.append(allocator, owned);
}

fn appendOwnedTestDecl(allocator: std.mem.Allocator, tests: *std.ArrayList(TestDecl), test_decl: TestDecl) !void {
    var owned = test_decl;
    errdefer owned.deinit(allocator);
    try tests.append(allocator, owned);
}

fn astImportDecl(allocator: std.mem.Allocator, file: []const u8, tree: std.zig.Ast, node: std.zig.Ast.Node.Index, import_node: std.zig.Ast.Node.Index) !Import {
    const file_owned = try allocator.dupe(u8, file);
    errdefer allocator.free(file_owned);
    const import_owned = try astStringLiteral(allocator, tree, import_node);
    errdefer allocator.free(import_owned);
    const alias = try astImportAlias(allocator, tree, node);
    errdefer if (alias) |owned| allocator.free(owned);
    const declaration = try allocator.dupe(u8, tree.getNodeSource(node));
    return .{
        .file = file_owned,
        .line = lineForNode(tree, node),
        .import = import_owned,
        .alias = alias,
        .declaration = declaration,
    };
}

fn astTestRun(allocator: std.mem.Allocator, file: []const u8, tree: std.zig.Ast, node: std.zig.Ast.Node.Index) !TestDecl {
    const file_owned = try allocator.dupe(u8, file);
    errdefer allocator.free(file_owned);
    const name = try astTestName(allocator, tree, node);
    errdefer if (name) |owned| allocator.free(owned);
    const declaration = try allocator.dupe(u8, compactNodeSource(tree.getNodeSource(node)));
    errdefer allocator.free(declaration);
    const command = try std.fmt.allocPrint(allocator, "zig test {s}", .{file});
    return .{
        .file = file_owned,
        .line = lineForNode(tree, node),
        .name = name,
        .declaration = declaration,
        .command = command,
    };
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
    const kind_owned = try allocator.dupe(u8, kind);
    errdefer allocator.free(kind_owned);
    const name = if (declName(trimmed, kind)) |name_value| try allocator.dupe(u8, name_value) else null;
    errdefer if (name) |owned| allocator.free(owned);
    const signature = try allocator.dupe(u8, trimmed);
    return .{
        .line = line_no,
        .kind = kind_owned,
        .name = name,
        .public = std.mem.startsWith(u8, trimmed, "pub "),
        .is_comptime = comptime_decl,
        .depth = depth,
        .signature = signature,
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

test "parser-backed source summary covers comptime and negative helper paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\comptime {
        \\    const Inside = struct {};
        \\    _ = @import("builtin");
        \\}
        \\test "inline" {}
    ;
    const summary = try parseSourceSummary(allocator, "comptime.zig", source);
    try std.testing.expect(hasDeclaration(summary.declarations, "Inside"));
    try std.testing.expect(hasImportValue(summary.imports, "builtin"));
    try std.testing.expect(hasTest(summary.tests, "inline"));
    try std.testing.expect(!hasDeclaration(summary.declarations, "Missing"));
    try std.testing.expect(!hasImport(summary.imports, "std", "std"));
    try std.testing.expect(!hasImportValue(summary.imports, "std"));
    try std.testing.expect(!hasTest(summary.tests, "missing"));

    var tree = try parseAst(allocator, source);
    defer {
        const parsed_source = tree.source;
        tree.deinit(allocator);
        allocator.free(parsed_source);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), try astOptionalIdentifier(allocator, tree, 0));
}

test "heuristic analysis builders clean up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, heuristicAnalysisAllocationCase, .{});
}

fn heuristicAnalysisAllocationCase(allocator: std.mem.Allocator) !void {
    var decls = try heuristicDeclarations(allocator,
        \\pub fn main() void {}
        \\pub const Api = struct {};
    );
    defer decls.deinit(allocator);

    const summary = try declarationSummaryText(allocator, "x.zig", "pub fn main() void {}\n");
    defer allocator.free(summary);
    const dead = try deadDeclCandidatesText(allocator, "x.zig", "const Hidden = struct {};\n");
    defer allocator.free(dead);
    const allocations = try allocationSummaryText(allocator, "x.zig", "var list: std.ArrayList(u8) = .empty;\n");
    defer allocator.free(allocations);
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
