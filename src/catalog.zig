const std = @import("std");

const analysis_contract = @import("analysis_contract.zig");
const backend_catalog = @import("backend_catalog.zig");
const json_result = @import("json_result.zig");
const tool_metadata = @import("tool_metadata.zig");
const tooling = @import("tooling.zig");
const version = @import("version.zig");

pub fn parsed(allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    var catalog = try std.json.parseFromSlice(std.json.Value, allocator, tooling.catalog_json, .{});
    errdefer catalog.deinit();

    if (catalog.value != .object) return error.InvalidCatalog;
    const catalog_allocator = catalog.arena.allocator();
    var obj = &catalog.value.object;
    try obj.put(catalog_allocator, "version", .{ .string = version.string });
    try obj.put(catalog_allocator, "groups", try groupsValue(catalog_allocator));
    try obj.put(catalog_allocator, "registry_tool_arguments", try toolArgumentsValue(catalog_allocator));
    try obj.put(catalog_allocator, "registry_tool_planning", try toolPlanningValue(catalog_allocator));
    try obj.put(catalog_allocator, "registry_static_analysis_contracts", try staticAnalysisContractsValue(catalog_allocator));
    try obj.put(catalog_allocator, "backend_setup", try backend_catalog.value(catalog_allocator, .{}, false));
    try obj.put(catalog_allocator, "registered_tool_count", .{ .integer = @intCast(tool_metadata.specs.len) });
    try obj.put(catalog_allocator, "registry_tool_schema_source", .{ .string = "generated from src/tool_manifest.zig" });
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

pub fn toolPlanningValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    for (tool_metadata.entries) |entry| {
        try obj.put(allocator, entry.name, try planningValue(allocator, entry));
    }
    return .{ .object = obj };
}

pub fn staticAnalysisContractsValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    for (analysis_contract.contracts) |contract| {
        var item = std.json.ObjectMap.empty;
        errdefer item.deinit(allocator);
        try item.put(allocator, "analysis_kind", .{ .string = contract.analysis_kind });
        try item.put(allocator, "capability_tier", .{ .string = analysis_contract.capabilityTierName(contract.tier) });
        try item.put(allocator, "confidence", .{ .string = analysis_contract.confidenceName(contract.confidence) });
        try item.put(allocator, "confidence_class", .{ .string = analysis_contract.classificationName(contract.classification) });
        try item.put(allocator, "source_coverage", .{ .string = contract.source_coverage });
        try item.put(allocator, "limitations", try stringArrayValue(allocator, contract.limitations));
        try item.put(allocator, "verify_with", try stringArrayValue(allocator, contract.verify_with));
        if (contract.verify_with.len > 0) try item.put(allocator, "recommended_cross_check", .{ .string = contract.verify_with[0] });
        try obj.put(allocator, contract.tool, .{ .object = item });
    }
    return .{ .object = obj };
}

fn groupsValue(allocator: std.mem.Allocator) !std.json.Value {
    var groups = std.json.Array.init(allocator);
    errdefer groups.deinit();
    for (tool_metadata.group_specs) |group_spec| {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "name", .{ .string = tool_metadata.groupName(group_spec.group) });
        try obj.put(allocator, "tools", try groupToolsValue(allocator, group_spec.group));
        try obj.put(allocator, "keywords", try stringArrayValue(allocator, group_spec.keywords));
        try groups.append(.{ .object = obj });
    }
    return .{ .array = groups };
}

fn groupToolsValue(allocator: std.mem.Allocator, group: tool_metadata.ToolGroup) !std.json.Value {
    var tools = std.json.Array.init(allocator);
    errdefer tools.deinit();
    for (tool_metadata.entries) |entry| {
        if (entry.group == group) try tools.append(.{ .string = entry.name });
    }
    return .{ .array = tools };
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
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
    return tool_metadata.riskValue(allocator, spec);
}

fn planningValue(allocator: std.mem.Allocator, entry: tool_metadata.ToolEntry) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_metadata.planKind(entry.plan) });
    try obj.put(allocator, "group", .{ .string = tool_metadata.groupName(entry.group) });
    try obj.put(allocator, "exact_command", .{ .bool = tool_metadata.commandPlanFor(entry.id) != null });
    try obj.put(allocator, "supported", .{ .bool = switch (entry.plan) {
        .not_plannable => false,
        else => true,
    } });
    try obj.put(allocator, "risk_level", .{ .string = tool_metadata.riskLevel(entry.risk) });
    switch (entry.plan) {
        .exact_command => {
            try obj.put(allocator, "argv_exact", .{ .bool = true });
            try obj.put(allocator, "command_backed", .{ .bool = true });
        },
        .dynamic_command => |reason| {
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "command_backed", .{ .bool = true });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .zls_request => |plan| {
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "backend", .{ .string = "zls" });
            try obj.put(allocator, "method", .{ .string = plan.method });
            try obj.put(allocator, "requires_document_sync", .{ .bool = plan.requires_document_sync });
            try obj.put(allocator, "mutates_document_state", .{ .bool = plan.mutates_document_state });
        },
        .apply_gated_mutation => |reason| {
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "apply_gated", .{ .bool = true });
            try obj.put(allocator, "preview_by_default", .{ .bool = entry.risk.preview_by_default });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .workspace_artifact => |reason| {
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "writes_artifact", .{ .bool = true });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .pure_analysis => |reason| {
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
        .not_plannable => |reason| {
            try obj.put(allocator, "argv_exact", .{ .bool = false });
            try obj.put(allocator, "reason", .{ .string = reason });
        },
    }
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
        try obj.put(allocator, field[0], try richSchemaFieldValue(allocator, input_schema, field));
    }
    return .{ .object = obj };
}

fn richSchemaFieldValue(allocator: std.mem.Allocator, input_schema: tooling.SchemaSpec, field: tooling.SchemaField) !std.json.Value {
    const hint = tooling.hintFor(input_schema, field);
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

test "manifest-generated catalog groups match typed registry groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed_catalog = try parsed(allocator);
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
