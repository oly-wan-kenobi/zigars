const std = @import("std");

const json_result = @import("json_result.zig");
const tool_metadata = @import("tool_metadata.zig");
const tooling = @import("tooling.zig");
const version = @import("version.zig");

pub fn parsed(allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    var catalog = try std.json.parseFromSlice(std.json.Value, allocator, tooling.catalog_json, .{});
    errdefer catalog.deinit();

    switch (catalog.value) {
        .object => |*obj| {
            try obj.put(allocator, "version", .{ .string = version.string });
            try obj.put(allocator, "registry_tool_arguments", try toolArgumentsValue(allocator));
            try obj.put(allocator, "registered_tool_count", .{ .integer = @intCast(tool_metadata.specs.len) });
            try obj.put(allocator, "registry_tool_schema_source", .{ .string = "generated from zigar tool registry" });
        },
        else => return error.InvalidCatalog,
    }
    return catalog;
}

pub fn text(allocator: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const catalog = try parsed(arena.allocator());
    return json_result.serializeAlloc(allocator, catalog.value);
}

pub fn toolArgumentsValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    for (tool_metadata.specs) |spec| {
        if (spec.input_schema.fields.len == 0) continue;
        try obj.put(allocator, spec.name, try toolArgumentValue(allocator, spec));
    }
    return .{ .object = obj };
}

fn toolArgumentValue(allocator: std.mem.Allocator, spec: tool_metadata.ToolMeta) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "risk", try toolRiskValue(allocator, spec));
    var required = try schemaFieldsValue(allocator, spec.input_schema, true);
    var optional = try schemaFieldsValue(allocator, spec.input_schema, false);
    if (required.object.count() > 0) {
        try obj.put(allocator, "required", required);
    } else {
        required.object.deinit(allocator);
    }
    if (optional.object.count() > 0) {
        try obj.put(allocator, "optional", optional);
    } else {
        optional.object.deinit(allocator);
    }
    try obj.put(allocator, "fields", try richSchemaFieldsValue(allocator, spec.input_schema));
    return .{ .object = obj };
}

fn toolRiskValue(allocator: std.mem.Allocator, spec: tool_metadata.ToolMeta) !std.json.Value {
    const risk = tool_metadata.riskFor(spec.id);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "level", .{ .string = tool_metadata.riskLevel(risk) });
    try obj.put(allocator, "mcp_read_only_hint", .{ .bool = spec.read_only });
    try obj.put(allocator, "writes_source", .{ .bool = risk.writes_source });
    try obj.put(allocator, "writes_artifacts", .{ .bool = risk.writes_artifacts });
    try obj.put(allocator, "writes_require_apply", .{ .bool = risk.writes_require_apply });
    try obj.put(allocator, "preview_by_default", .{ .bool = risk.preview_by_default });
    try obj.put(allocator, "mutates_lsp_state", .{ .bool = risk.mutates_lsp_state });
    try obj.put(allocator, "executes_project_code", .{ .bool = risk.executes_project_code });
    try obj.put(allocator, "executes_user_command", .{ .bool = risk.executes_user_command });
    try obj.put(allocator, "executes_backend", .{ .bool = risk.executes_backend });
    return .{ .object = obj };
}

fn schemaFieldsValue(allocator: std.mem.Allocator, input_schema: tooling.SchemaSpec, required: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    for (input_schema.fields) |field| {
        if (field[2] == required) {
            try obj.put(allocator, field[0], .{ .string = field[1] });
        }
    }
    return .{ .object = obj };
}

fn richSchemaFieldsValue(allocator: std.mem.Allocator, input_schema: tooling.SchemaSpec) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    for (input_schema.fields) |field| {
        try obj.put(allocator, field[0], try richSchemaFieldValue(allocator, field));
    }
    return .{ .object = obj };
}

fn richSchemaFieldValue(allocator: std.mem.Allocator, field: tooling.SchemaField) !std.json.Value {
    const hint = tooling.hintFor(field);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "type", .{ .string = field[1] });
    try obj.put(allocator, "required", .{ .bool = field[2] });
    try obj.put(allocator, "description", .{ .string = hint.description });
    if (hint.default_bool) |value| try obj.put(allocator, "default", .{ .bool = value });
    if (hint.default_int) |value| try obj.put(allocator, "default", .{ .integer = value });
    if (hint.default_string) |value| try obj.put(allocator, "default", .{ .string = value });
    if (hint.path_kind) |value| try obj.put(allocator, "path_kind", .{ .string = value });
    if (hint.minimum) |value| try obj.put(allocator, "minimum", .{ .integer = value });
    if (hint.maximum) |value| try obj.put(allocator, "maximum", .{ .integer = value });
    if (hint.enum_values.len > 0) {
        var values = std.json.Array.init(allocator);
        errdefer values.deinit();
        for (hint.enum_values) |value| try values.append(.{ .string = value });
        try obj.put(allocator, "enum", .{ .array = values });
    }
    return .{ .object = obj };
}

test "registry arguments include risk metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const catalog = try parsed(arena.allocator());
    const args = catalog.value.object.get("registry_tool_arguments").?.object;
    const validate_patch = args.get("zigar_validate_patch").?.object;
    try std.testing.expect(validate_patch.get("risk").?.object.get("executes_project_code").?.bool);
    const format = args.get("zig_format").?.object;
    try std.testing.expect(format.get("risk").?.object.get("writes_require_apply").?.bool);
    try std.testing.expectEqualStrings("input_file", format.get("fields").?.object.get("file").?.object.get("path_kind").?.string);
    try std.testing.expectEqualStrings("boolean", format.get("fields").?.object.get("apply").?.object.get("type").?.string);
    try std.testing.expect(!format.get("fields").?.object.get("apply").?.object.get("default").?.bool);
    try std.testing.expect(format.get("risk").?.object.get("writes_artifacts").?.bool);
    const matrix = args.get("zig_matrix_check").?.object;
    try std.testing.expect(matrix.get("risk").?.object.get("executes_user_command").?.bool);
}

test "static catalog group membership covers registry exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed_catalog = try std.json.parseFromSlice(std.json.Value, allocator, tooling.catalog_json, .{});
    const groups = parsed_catalog.value.object.get("groups").?.array;
    var seen = std.StringHashMap(void).init(allocator);

    for (groups.items) |group_value| {
        const tools = group_value.object.get("tools").?.array;
        for (tools.items) |tool_value| {
            const tool_name = tool_value.string;
            try std.testing.expect(tool_metadata.find(tool_name) != null);
            try std.testing.expect(!seen.contains(tool_name));
            try seen.put(tool_name, {});
        }
    }

    for (tool_metadata.specs) |spec| {
        try std.testing.expect(seen.contains(spec.name));
    }
    try std.testing.expectEqual(tool_metadata.specs.len, seen.count());
}

test "static catalog groups match typed registry groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed_catalog = try std.json.parseFromSlice(std.json.Value, allocator, tooling.catalog_json, .{});
    const groups = parsed_catalog.value.object.get("groups").?.array;

    for (tool_metadata.specs) |spec| {
        const expected = tool_metadata.groupName(tool_metadata.groupFor(spec.id));
        const actual = catalogGroupForTool(groups, spec.name) orelse return error.MissingCatalogGroup;
        try std.testing.expectEqualStrings(expected, actual);
    }
}

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
