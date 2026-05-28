const std = @import("std");
const subject = @import("tool_catalog_render.zig");
const parsed = subject.parsed;
const text = subject.text;
const toolArgumentsValue = subject.toolArgumentsValue;
const toolPlanningValue = subject.toolPlanningValue;
const staticAnalysisContractsValue = subject.staticAnalysisContractsValue;
const backendSetupValue = subject.backendSetupValue;

test "registry arguments include risk metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const catalog = try parsed(arena.allocator());
    const args = catalog.value.object.get("registry_tool_arguments").?.object;
    const validate_patch = args.get("zigars_validate_patch").?.object;
    try std.testing.expect(validate_patch.get("risk").?.object.get("executes_project_code").?.bool);
    const format = args.get("zig_format").?.object;
    try std.testing.expect(format.get("risk").?.object.get("writes_require_apply").?.bool);
    try std.testing.expectEqualStrings("input_file", format.get("fields").?.object.get("file").?.object.get("path_kind").?.string);
    try std.testing.expectEqualStrings("boolean", format.get("fields").?.object.get("apply").?.object.get("type").?.string);
    try std.testing.expect(!format.get("fields").?.object.get("apply").?.object.get("default").?.bool);
    try std.testing.expect(format.get("risk").?.object.get("writes_artifacts").?.bool);
    const matrix = args.get("zig_matrix_check").?.object;
    try std.testing.expect(matrix.get("risk").?.object.get("executes_user_command").?.bool);

    const planning = catalog.value.object.get("registry_tool_planning").?.object;
    const hover = planning.get("zig_hover").?.object;
    try std.testing.expectEqualStrings("zls_request", hover.get("kind").?.string);
    try std.testing.expectEqualStrings("textDocument/hover", hover.get("method").?.string);
    const build = planning.get("zig_build").?.object;
    try std.testing.expectEqualStrings("exact_command", build.get("kind").?.string);
    try std.testing.expect(build.get("exact_command").?.bool);

    const static_contracts = catalog.value.object.get("registry_static_analysis_contracts").?.object;
    const ast_decls = static_contracts.get("zig_ast_decl_summary").?.object;
    try std.testing.expectEqualStrings("parser_backed", ast_decls.get("capability_tier").?.string);
    try std.testing.expectEqualStrings("high", ast_decls.get("confidence").?.string);
    const lint = static_contracts.get("zig_lint").?.object;
    try std.testing.expectEqualStrings("zwanzig_backed", lint.get("capability_tier").?.string);
}
test "manifest-generated catalog group membership covers registry exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed_catalog = try parsed(allocator);
    const groups = parsed_catalog.value.object.get("groups").?.array;
    var seen = std.StringHashMap(void).init(allocator);

    for (groups.items) |group_value| {
        const tools = group_value.object.get("tools").?.array;
        for (tools.items) |tool_value| {
            const tool_name = tool_value.string;
            try std.testing.expect(find(tool_name) != null);
            try std.testing.expect(!seen.contains(tool_name));
            try seen.put(tool_name, {});
        }
    }

    for (aggregate.specs) |spec| {
        try std.testing.expect(seen.contains(spec.name));
    }
    try std.testing.expectEqual(aggregate.specs.len, seen.count());
}
test "manifest-generated catalog groups match typed registry groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed_catalog = try parsed(allocator);
    const groups = parsed_catalog.value.object.get("groups").?.array;

    for (aggregate.specs) |spec| {
        const expected = groupName(groupFor(spec.id));
        const actual = catalogGroupForTool(groups, spec.name) orelse return error.MissingCatalogGroup;
        try std.testing.expectEqualStrings(expected, actual);
    }
}
test "catalog common-intent preferred tools resolve to registered ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed_catalog = try parsed(arena.allocator());
    const intents = parsed_catalog.value.object.get("common_intents").?.array;
    for (intents.items) |intent_value| {
        const prefer = intent_value.object.get("prefer").?.string;
        var parts = std.mem.splitScalar(u8, prefer, ',');
        while (parts.next()) |raw_name| {
            const name = std.mem.trim(u8, raw_name, " \t\r\n");
            try std.testing.expect(name.len > 0);
            try std.testing.expect(find(name) != null);
        }
    }
}
test "catalog lookup helpers return null for unknown tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed_catalog = try parsed(arena.allocator());
    const groups = parsed_catalog.value.object.get("groups").?.array;
    try std.testing.expect(find("__zigars_unknown_tool__") == null);
    try std.testing.expect(catalogGroupForTool(groups, "__zigars_unknown_tool__") == null);
}

const aggregate = @import("aggregate.zig");

/// Finds a tool by name and returns null when no registry entry matches.
fn find(name: []const u8) ?aggregate.ToolMeta {
    for (aggregate.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.meta;
    }
    return null;
}

/// Returns the manifest group assigned to a tool id.
fn groupFor(id: aggregate.ToolId) @import("types.zig").ToolGroup {
    return aggregate.entries[@intFromEnum(id)].group;
}

/// Returns the serialized manifest group name.
fn groupName(group: @import("types.zig").ToolGroup) []const u8 {
    return @tagName(group);
}

/// Returns the manifest catalog group name containing a tool.
fn catalogGroupForTool(groups: std.json.Array, tool_name: []const u8) ?[]const u8 {
    for (groups.items) |group_value| {
        const group = group_value.object;
        const group_name = group.get("name").?.string;
        const tools = group.get("tools").?.array;
        for (tools.items) |tool_value| {
            if (std.mem.eql(u8, tool_value.string, tool_name)) return group_name;
        }
    }
    return null;
}
