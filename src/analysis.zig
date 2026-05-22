const std = @import("std");
const analysis_contract = @import("analysis_contract.zig");
const zig_analysis = @import("domain/zig/analysis.zig");

pub fn declSummary(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    return zig_analysis.declarationSummaryText(allocator, file, contents);
}

pub fn allocationSummary(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    return zig_analysis.allocationSummaryText(allocator, file, contents);
}

pub fn errorSetSummary(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    return zig_analysis.errorSetSummaryText(allocator, file, contents);
}

pub fn publicApiSummary(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    return zig_analysis.publicApiSummaryText(allocator, file, contents);
}

pub fn deadDeclCandidates(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) ![]u8 {
    return zig_analysis.deadDeclCandidatesText(allocator, file, contents);
}

pub fn importGraph(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    limit: usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# Import graph\n\n");
    try out.appendSlice(allocator, "Capability tier: advisory_orientation. Confidence: medium heuristic string-literal @import scan (orientation_only). Use `zig_ast_imports` or compiler/ZLS checks when precision matters.\n\n");

    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var files: usize = 0;
    var skipped: usize = 0;
    while (try walker.next(io)) |entry| {
        if (files >= limit) break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (skipWorkspacePath(entry.path)) continue;

        const abs = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(abs);
        const contents = std.Io.Dir.cwd().readFileAlloc(io, abs, allocator, .limited(512 * 1024)) catch |err| {
            skipped += 1;
            try out.print(allocator, "## {s}\n- skipped: {s}\n\n", .{ entry.path, @errorName(err) });
            continue;
        };
        defer allocator.free(contents);

        files += 1;
        try out.print(allocator, "## {s}\n", .{entry.path});
        var pos: usize = 0;
        var found = false;
        while (std.mem.indexOfPos(u8, contents, pos, "@import(\"")) |hit| {
            const start = hit + "@import(\"".len;
            const end = std.mem.indexOfScalarPos(u8, contents, start, '"') orelse break;
            try out.print(allocator, "- {s}\n", .{contents[start..end]});
            pos = end + 1;
            found = true;
        }
        if (!found) try out.appendSlice(allocator, "- no string-literal imports found\n");
        try out.append(allocator, '\n');
    }
    if (skipped > 0) try out.print(allocator, "\nSkipped unreadable files: {d}\n", .{skipped});
    return out.toOwnedSlice(allocator);
}

pub fn importGraphJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    limit: usize,
) !std.json.Value {
    var files = std.json.Array.init(allocator);
    var skipped_files = std.json.Array.init(allocator);
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var seen: usize = 0;
    while (try walker.next(io)) |entry| {
        if (seen >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (skipWorkspacePath(entry.path)) continue;
        const abs = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(abs);
        const contents = std.Io.Dir.cwd().readFileAlloc(io, abs, allocator, .limited(512 * 1024)) catch |err| {
            try skipped_files.append(try skippedFileValue(allocator, entry.path, err));
            continue;
        };
        defer allocator.free(contents);
        seen += 1;
        var imports = std.json.Array.init(allocator);
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, contents, pos, "@import(\"")) |hit| {
            const start = hit + "@import(\"".len;
            const end = std.mem.indexOfScalarPos(u8, contents, start, '"') orelse break;
            try imports.append(try ownedString(allocator, contents[start..end]));
            pos = end + 1;
        }
        var file_obj = std.json.ObjectMap.empty;
        try file_obj.put(allocator, "file", try ownedString(allocator, entry.path));
        try file_obj.put(allocator, "imports", .{ .array = imports });
        try files.append(.{ .object = file_obj });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try analysis_contract.putMetadata(allocator, &obj, "zig_import_graph_json");
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "file_count", .{ .integer = @intCast(seen) });
    try obj.put(allocator, "skipped_files", .{ .array = skipped_files });
    try obj.put(allocator, "skipped_file_count", .{ .integer = @intCast(skipped_files.items.len) });
    return .{ .object = obj };
}

pub fn declSummaryJson(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) !std.json.Value {
    const declarations = try zig_analysis.heuristicDeclarations(allocator, contents);
    defer declarations.deinit(allocator);
    return declSummaryJsonFromDomain(allocator, file, declarations);
}

pub fn astDeclSummaryJson(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) !std.json.Value {
    var summary = try zig_analysis.parseSourceSummary(allocator, file, contents);
    defer summary.deinit(allocator);
    return astDeclSummaryJsonFromDomain(allocator, file, summary);
}

pub fn astImportsJson(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) !std.json.Value {
    var summary = try zig_analysis.parseSourceSummary(allocator, file, contents);
    defer summary.deinit(allocator);
    return astImportsJsonFromDomain(allocator, file, summary);
}

pub fn astTestsJson(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) !std.json.Value {
    var summary = try zig_analysis.parseSourceSummary(allocator, file, contents);
    defer summary.deinit(allocator);
    return astTestsJsonFromDomain(allocator, file, summary);
}

pub fn declSummaryJsonFromDomain(allocator: std.mem.Allocator, file: []const u8, declarations: zig_analysis.DeclarationList) !std.json.Value {
    var decls = std.json.Array.init(allocator);
    for (declarations.items) |decl| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "line", .{ .integer = @intCast(decl.line) });
        try item.put(allocator, "kind", try ownedString(allocator, decl.kind));
        try item.put(allocator, "public", .{ .bool = decl.public });
        try item.put(allocator, "text", try ownedString(allocator, decl.signature));
        try decls.append(.{ .object = item });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try analysis_contract.putMetadata(allocator, &obj, "zig_decl_summary_json");
    try obj.put(allocator, "declarations", .{ .array = decls });
    return .{ .object = obj };
}

pub fn astDeclSummaryJsonFromDomain(allocator: std.mem.Allocator, file: []const u8, summary: zig_analysis.SourceSummary) !std.json.Value {
    var declarations = std.json.Array.init(allocator);
    for (summary.declarations) |decl| try declarations.append(try astDeclValueFromDomain(allocator, decl));

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_ast_decl_summary" });
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try analysis_contract.putMetadata(allocator, &obj, "zig_ast_decl_summary");
    try putParseMetadataFromDomain(allocator, &obj, summary.parse);
    try obj.put(allocator, "declarations", .{ .array = declarations });
    try obj.put(allocator, "skipped_files", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "skipped_file_count", .{ .integer = 0 });
    return .{ .object = obj };
}

pub fn astImportsJsonFromDomain(allocator: std.mem.Allocator, file: []const u8, summary: zig_analysis.SourceSummary) !std.json.Value {
    var imports = std.json.Array.init(allocator);
    for (summary.imports) |import_item| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try ownedString(allocator, import_item.file));
        try item.put(allocator, "line", .{ .integer = @intCast(import_item.line) });
        try item.put(allocator, "import", try ownedString(allocator, import_item.import));
        try item.put(allocator, "alias", if (import_item.alias) |alias| try ownedString(allocator, alias) else .null);
        try item.put(allocator, "declaration", try ownedString(allocator, import_item.declaration));
        try imports.append(.{ .object = item });
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_ast_imports" });
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try analysis_contract.putMetadata(allocator, &obj, "zig_ast_imports");
    try putParseMetadataFromDomain(allocator, &obj, summary.parse);
    try obj.put(allocator, "imports", .{ .array = imports });
    try obj.put(allocator, "skipped_files", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "skipped_file_count", .{ .integer = 0 });
    return .{ .object = obj };
}

pub fn astTestsJsonFromDomain(allocator: std.mem.Allocator, file: []const u8, summary: zig_analysis.SourceSummary) !std.json.Value {
    var tests = std.json.Array.init(allocator);
    for (summary.tests) |test_item| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try ownedString(allocator, test_item.file));
        try item.put(allocator, "line", .{ .integer = @intCast(test_item.line) });
        try item.put(allocator, "name", if (test_item.name) |name| try ownedString(allocator, name) else .null);
        try item.put(allocator, "declaration", try ownedString(allocator, test_item.declaration));
        try item.put(allocator, "command", try ownedString(allocator, test_item.command));
        try tests.append(.{ .object = item });
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_ast_tests" });
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try analysis_contract.putMetadata(allocator, &obj, "zig_ast_tests");
    try putParseMetadataFromDomain(allocator, &obj, summary.parse);
    try obj.put(allocator, "tests", .{ .array = tests });
    try obj.put(allocator, "skipped_files", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "skipped_file_count", .{ .integer = 0 });
    return .{ .object = obj };
}

fn astDeclValueFromDomain(allocator: std.mem.Allocator, decl: zig_analysis.Declaration) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "line", .{ .integer = @intCast(decl.line) });
    try obj.put(allocator, "kind", try ownedString(allocator, decl.kind));
    try obj.put(allocator, "name", if (decl.name) |name| try ownedString(allocator, name) else .null);
    try obj.put(allocator, "public", .{ .bool = decl.public });
    try obj.put(allocator, "comptime", .{ .bool = decl.is_comptime });
    try obj.put(allocator, "depth", .{ .integer = @intCast(decl.depth) });
    try obj.put(allocator, "signature", try ownedString(allocator, decl.signature));
    return .{ .object = obj };
}

fn putParseMetadataFromDomain(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, parse: zig_analysis.ParseMetadata) !void {
    try obj.put(allocator, "parse_status", .{ .string = zig_analysis.parseStatusName(parse.status) });
    try obj.put(allocator, "partial_result", .{ .bool = parse.partial_result });
    try obj.put(allocator, "result_complete", .{ .bool = parse.result_complete });
    try obj.put(allocator, "parse_error_count", .{ .integer = parse.parse_error_count });
}

pub fn testDiscoverJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    limit: usize,
) !std.json.Value {
    var tests = std.json.Array.init(allocator);
    var skipped_files = std.json.Array.init(allocator);
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (count >= limit) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or skipWorkspacePath(entry.path)) continue;
        const abs = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(abs);
        const contents = std.Io.Dir.cwd().readFileAlloc(io, abs, allocator, .limited(512 * 1024)) catch |err| {
            try skipped_files.append(try skippedFileValue(allocator, entry.path, err));
            continue;
        };
        defer allocator.free(contents);
        var lines = std.mem.splitScalar(u8, contents, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            if (count >= limit) break;
            const trimmed = std.mem.trim(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, "test ")) continue;
            count += 1;
            var obj = std.json.ObjectMap.empty;
            try obj.put(allocator, "file", try ownedString(allocator, entry.path));
            try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
            try obj.put(allocator, "declaration", try ownedString(allocator, trimmed));
            try obj.put(allocator, "command", .{ .string = try std.fmt.allocPrint(allocator, "zig test {s}", .{entry.path}) });
            try tests.append(.{ .object = obj });
        }
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try analysis_contract.putMetadata(allocator, &obj, "zig_test_discover");
    try obj.put(allocator, "tests", .{ .array = tests });
    try obj.put(allocator, "count", .{ .integer = @intCast(count) });
    try obj.put(allocator, "skipped_files", .{ .array = skipped_files });
    try obj.put(allocator, "skipped_file_count", .{ .integer = @intCast(skipped_files.items.len) });
    return .{ .object = obj };
}

fn skippedFileValue(allocator: std.mem.Allocator, path: []const u8, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "path", try ownedString(allocator, path));
    try obj.put(allocator, "error", try ownedString(allocator, @errorName(err)));
    return .{ .object = obj };
}

fn parseAst(allocator: std.mem.Allocator, contents: []const u8) !std.zig.Ast {
    const source = try allocator.dupeZ(u8, contents);
    return std.zig.Ast.parse(allocator, source, .zig);
}

fn putParseMetadata(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, tree: std.zig.Ast) !void {
    const has_errors = tree.errors.len != 0;
    try obj.put(allocator, "parse_status", .{ .string = if (has_errors) "syntax_errors" else "ok" });
    try obj.put(allocator, "partial_result", .{ .bool = has_errors });
    try obj.put(allocator, "result_complete", .{ .bool = !has_errors });
    try obj.put(allocator, "parse_error_count", .{ .integer = @intCast(tree.errors.len) });
}

fn appendAstDecls(allocator: std.mem.Allocator, tree: *const std.zig.Ast, nodes: []const std.zig.Ast.Node.Index, declarations: *std.json.Array, depth: usize) anyerror!void {
    for (nodes) |node| try appendAstDecl(allocator, tree, node, declarations, depth);
}

fn appendAstDecl(allocator: std.mem.Allocator, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index, declarations: *std.json.Array, depth: usize) anyerror!void {
    switch (tree.nodeTag(node)) {
        .global_var_decl, .simple_var_decl, .aligned_var_decl => {
            const decl = tree.fullVarDecl(node).?;
            try declarations.append(try astVarDeclValue(allocator, tree.*, node, decl, depth));
            if (decl.ast.init_node.unwrap()) |init_node| try appendAstContainerOrBlockDecls(allocator, tree, init_node, declarations, depth + 1);
        },
        .fn_decl, .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, node).?;
            try declarations.append(try astFnDeclValue(allocator, tree.*, node, proto, depth));
        },
        .test_decl => try declarations.append(try astTestDeclValue(allocator, tree.*, node, depth)),
        .@"comptime" => try appendAstContainerOrBlockDecls(allocator, tree, tree.nodeData(node).node, declarations, depth + 1),
        else => try appendAstContainerOrBlockDecls(allocator, tree, node, declarations, depth),
    }
}

fn appendAstContainerOrBlockDecls(allocator: std.mem.Allocator, tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index, declarations: *std.json.Array, depth: usize) anyerror!void {
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

fn astVarDeclValue(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index, decl: std.zig.Ast.full.VarDecl, depth: usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "line", .{ .integer = @intCast(lineForNode(tree, node)) });
    try obj.put(allocator, "kind", .{ .string = tree.tokenSlice(decl.ast.mut_token) });
    try obj.put(allocator, "name", try astOptionalTokenValue(allocator, tree, decl.ast.mut_token + 1));
    try obj.put(allocator, "public", .{ .bool = decl.visib_token != null });
    try obj.put(allocator, "comptime", .{ .bool = decl.comptime_token != null });
    try obj.put(allocator, "depth", .{ .integer = @intCast(depth) });
    try obj.put(allocator, "signature", try ownedString(allocator, compactNodeSource(tree.getNodeSource(node))));
    return .{ .object = obj };
}

fn astFnDeclValue(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index, proto: std.zig.Ast.full.FnProto, depth: usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "line", .{ .integer = @intCast(lineForNode(tree, node)) });
    try obj.put(allocator, "kind", .{ .string = "fn" });
    try obj.put(allocator, "name", if (proto.name_token) |token| try ownedString(allocator, tree.tokenSlice(token)) else .null);
    try obj.put(allocator, "public", .{ .bool = proto.visib_token != null });
    try obj.put(allocator, "comptime", .{ .bool = false });
    try obj.put(allocator, "depth", .{ .integer = @intCast(depth) });
    try obj.put(allocator, "signature", try ownedString(allocator, compactNodeSource(tree.getNodeSource(node))));
    return .{ .object = obj };
}

fn astTestDeclValue(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index, depth: usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "line", .{ .integer = @intCast(lineForNode(tree, node)) });
    try obj.put(allocator, "kind", .{ .string = "test" });
    try obj.put(allocator, "name", try astTestNameValue(allocator, tree, node));
    try obj.put(allocator, "public", .{ .bool = false });
    try obj.put(allocator, "comptime", .{ .bool = false });
    try obj.put(allocator, "depth", .{ .integer = @intCast(depth) });
    try obj.put(allocator, "signature", try ownedString(allocator, compactNodeSource(tree.getNodeSource(node))));
    return .{ .object = obj };
}

fn astTestNameValue(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index) !std.json.Value {
    const name_token = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse return .null;
    if (tree.tokenTag(name_token) == .string_literal) {
        return astStringLiteralTokenValue(allocator, tree, name_token);
    }
    return ownedString(allocator, tree.tokenSlice(name_token));
}

fn astStringLiteralValue(allocator: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index) !std.json.Value {
    return astStringLiteralTokenValue(allocator, tree, tree.nodeMainToken(node));
}

fn astImportAliasValue(allocator: std.mem.Allocator, tree: std.zig.Ast, import_node: std.zig.Ast.Node.Index) !std.json.Value {
    for (0..tree.nodes.len) |node_i| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(@as(u32, @intCast(node_i)));
        switch (tree.nodeTag(node)) {
            .global_var_decl, .simple_var_decl, .aligned_var_decl => {
                const decl = tree.fullVarDecl(node).?;
                const init_node = decl.ast.init_node.unwrap() orelse continue;
                if (init_node == import_node) return astOptionalTokenValue(allocator, tree, decl.ast.mut_token + 1);
            },
            else => {},
        }
    }
    return .null;
}

fn astStringLiteralTokenValue(allocator: std.mem.Allocator, tree: std.zig.Ast, token: std.zig.Ast.TokenIndex) !std.json.Value {
    const raw = tree.tokenSlice(token);
    const parsed = std.zig.string_literal.parseAlloc(allocator, raw) catch return ownedString(allocator, stripQuotes(raw));
    return .{ .string = parsed };
}

fn astOptionalTokenValue(allocator: std.mem.Allocator, tree: std.zig.Ast, token: std.zig.Ast.TokenIndex) !std.json.Value {
    if (token < tree.tokens.len and tree.tokenTag(token) == .identifier) return ownedString(allocator, tree.tokenSlice(token));
    return .null;
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

fn keywordSummary(
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

fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

fn isDeclarationLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "pub const ") or
        std.mem.startsWith(u8, line, "pub var ") or
        std.mem.startsWith(u8, line, "pub fn ") or
        std.mem.startsWith(u8, line, "const ") or
        std.mem.startsWith(u8, line, "var ") or
        std.mem.startsWith(u8, line, "fn ");
}

pub fn declKind(line: []const u8) ?[]const u8 {
    return zig_analysis.declKind(line);
}

pub fn skipWorkspacePath(path: []const u8) bool {
    return zig_analysis.skipWorkspacePath(path);
}

test "declaration summary finds pub fn" {
    const text = try declSummary(std.testing.allocator, "x.zig", "pub fn main() void {}\nconst A = u8;\n");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "pub fn main") != null);
}

test "declaration summary json classifies declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try declSummaryJson(arena.allocator(), "x.zig", "pub fn main() void {}\nconst A = u8;\n");
    const decls = value.object.get("declarations").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expectEqualStrings("fn", decls[0].object.get("kind").?.string);
    try std.testing.expect(decls[0].object.get("public").?.bool);
}

test "import graph skips cache and vendored package paths" {
    try std.testing.expect(skipWorkspacePath(".zig-cache/o/file.zig"));
    try std.testing.expect(skipWorkspacePath(".zigar-cache/profile/out.zig"));
    try std.testing.expect(skipWorkspacePath("zig-out/bin/main.zig"));
    try std.testing.expect(skipWorkspacePath("zig-pkg/mcp/src/server.zig"));
    try std.testing.expect(!skipWorkspacePath("src/main.zig"));
}

test "heuristic JSON scans report skipped file count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "ok.zig", .data = "const std = @import(\"std\");\ntest \"ok\" {}\n" });
    const too_large = try allocator.alloc(u8, 512 * 1024 + 1);
    @memset(too_large, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "too-large.zig", .data = too_large });

    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    const root_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    const root = root_z[0..];

    const imports = try importGraphJson(allocator, io, root, 10);
    try std.testing.expectEqualStrings("heuristic_import_scan", imports.object.get("analysis_kind").?.string);
    try std.testing.expectEqualStrings("advisory_orientation", imports.object.get("capability_tier").?.string);
    try std.testing.expectEqualStrings("orientation_only", imports.object.get("confidence_class").?.string);
    try std.testing.expect(imports.object.get("source_coverage").?.string.len > 0);
    try std.testing.expect(imports.object.get("limitations").?.array.items.len > 0);
    try std.testing.expectEqual(@as(i64, 1), imports.object.get("skipped_file_count").?.integer);
    try std.testing.expect(imports.object.get("skipped_files").?.array.items.len == 1);

    const tests = try testDiscoverJson(allocator, io, root, 10);
    try std.testing.expectEqualStrings("heuristic_test_scan", tests.object.get("analysis_kind").?.string);
    try std.testing.expectEqualStrings("advisory_orientation", tests.object.get("capability_tier").?.string);
    try std.testing.expectEqualStrings("orientation_only", tests.object.get("confidence_class").?.string);
    try std.testing.expect(tests.object.get("verify_with").?.array.items.len > 0);
    try std.testing.expectEqual(@as(i64, 1), tests.object.get("skipped_file_count").?.integer);
}
