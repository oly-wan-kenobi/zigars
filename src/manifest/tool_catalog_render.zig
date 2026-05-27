const std = @import("std");

const analysis_contract = @import("../domain/zig/static_analysis_contracts.zig");
const aggregate = @import("aggregate.zig");
const backend_catalog = @import("../domain/zig/backend_catalog.zig");
const groups_mod = @import("groups.zig");
const types = @import("types.zig");
const tooling = @import("tooling.zig");
const version = @import("version.zig");

const ToolGroup = types.ToolGroup;
const ToolRisk = types.ToolRisk;
const PlanPolicy = types.PlanPolicy;
const CommandPlan = types.CommandPlan;
const ToolMeta = aggregate.ToolMeta;
const ToolEntry = aggregate.ToolEntry;

/// Parses the embedded catalog and enriches it with generated registry metadata.
pub fn parsed(allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    var catalog = try std.json.parseFromSlice(std.json.Value, allocator, tooling.catalog_json, .{});
    var catalog_owned = true;
    defer if (catalog_owned) catalog.deinit();

    if (catalog.value != .object) return error.InvalidCatalog;
    const catalog_allocator = catalog.arena.allocator();
    var obj = &catalog.value.object;
    try obj.put(catalog_allocator, "version", .{ .string = version.string });
    try obj.put(catalog_allocator, "groups", try groupsValue(catalog_allocator));
    try obj.put(catalog_allocator, "registry_tool_arguments", try toolArgumentsValue(catalog_allocator));
    try obj.put(catalog_allocator, "registry_tool_planning", try toolPlanningValue(catalog_allocator));
    try obj.put(catalog_allocator, "registry_static_analysis_contracts", try staticAnalysisContractsValue(catalog_allocator));
    try obj.put(catalog_allocator, "backend_setup", try backendSetupValue(catalog_allocator, .{}, false));
    try obj.put(catalog_allocator, "registered_tool_count", .{ .integer = @intCast(aggregate.specs.len) });
    try obj.put(catalog_allocator, "registry_tool_schema_source", .{ .string = "generated from src/manifest/mod.zig" });
    catalog_owned = false;
    return catalog;
}

/// Returns the enriched tool catalog as allocator-owned JSON text.
pub fn text(allocator: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const catalog = try parsed(arena.allocator());
    return serializeAlloc(allocator, catalog.value);
}

/// Builds the catalog map of tool argument schemas and risk metadata.
pub fn toolArgumentsValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    for (aggregate.specs) |spec| {
        if (spec.input_schema.fields.len == 0) continue;
        try obj.put(allocator, spec.name, try toolArgumentValue(allocator, spec));
    }
    obj_owned = false;
    return .{ .object = obj };
}

/// Builds the catalog map of tool planning contracts.
pub fn toolPlanningValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    for (aggregate.entries) |entry| {
        try obj.put(allocator, entry.name, try planningValue(allocator, entry));
    }
    obj_owned = false;
    return .{ .object = obj };
}

/// Builds the catalog map of static-analysis evidence contracts.
pub fn staticAnalysisContractsValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    for (analysis_contract.contracts) |contract| {
        var item = std.json.ObjectMap.empty;
        var item_owned = true;
        defer if (item_owned) item.deinit(allocator);
        try item.put(allocator, "analysis_kind", .{ .string = contract.analysis_kind });
        try item.put(allocator, "capability_tier", .{ .string = analysis_contract.capabilityTierName(contract.tier) });
        try item.put(allocator, "confidence", .{ .string = analysis_contract.confidenceName(contract.confidence) });
        try item.put(allocator, "confidence_class", .{ .string = analysis_contract.classificationName(contract.classification) });
        try item.put(allocator, "source_coverage", .{ .string = contract.source_coverage });
        try item.put(allocator, "limitations", try stringArrayValue(allocator, contract.limitations));
        try item.put(allocator, "verify_with", try stringArrayValue(allocator, contract.verify_with));
        if (contract.verify_with.len > 0) try item.put(allocator, "recommended_cross_check", .{ .string = contract.verify_with[0] });
        try obj.put(allocator, contract.tool, .{ .object = item });
        item_owned = false;
    }
    obj_owned = false;
    return .{ .object = obj };
}

/// Builds backend setup metadata, optionally including configured paths.
pub fn backendSetupValue(allocator: std.mem.Allocator, paths: backend_catalog.Paths, include_configured_paths: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_setup_catalog" });
    try obj.put(allocator, "supported_zig_version", .{ .string = backend_catalog.supported_zig_version });
    try obj.put(allocator, "packaging_model", .{ .string = "zigars ships backend metadata and probes; optional backends remain external executables pinned by each project or CI image" });
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (backend_catalog.backends) |backend| try array.append(try backendValue(allocator, backend, paths, include_configured_paths));
    try obj.put(allocator, "backends", .{ .array = array });
    obj_owned = false;
    array_owned = false;
    return .{ .object = obj };
}

/// Builds JSON metadata for one backend, including optional configured paths.
fn backendValue(allocator: std.mem.Allocator, backend: backend_catalog.Backend, paths: backend_catalog.Paths, include_configured_paths: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    const configured_path = backendPathFor(backend.name, paths);
    try obj.put(allocator, "name", .{ .string = backend.name });
    try obj.put(allocator, "optional", .{ .bool = backend.optional });
    try obj.put(allocator, "path_flag", .{ .string = backend.path_flag });
    try obj.put(allocator, "default_path", .{ .string = backend.default_path });
    if (include_configured_paths) try obj.put(allocator, "configured_path", .{ .string = configured_path });
    try obj.put(allocator, "purpose", .{ .string = backend.purpose });
    try obj.put(allocator, "compatibility", .{ .string = backend.compatibility });
    try obj.put(allocator, "install_strategy", .{ .string = backend.install_strategy });
    try obj.put(allocator, "tools", try stringArrayValue(allocator, backend.tools));
    try obj.put(allocator, "probe_argv", try probeArgvValue(allocator, backend.probe_argv, configured_path));
    try obj.put(allocator, "verify", try stringArrayValue(allocator, backend.verify));
    obj_owned = false;
    return .{ .object = obj };
}

/// Selects the configured executable path for a backend name.
fn backendPathFor(name: []const u8, paths: backend_catalog.Paths) []const u8 {
    if (std.mem.eql(u8, name, "zig")) return paths.zig_path;
    if (std.mem.eql(u8, name, "zls")) return paths.zls_path;
    if (std.mem.eql(u8, name, "zlint")) return paths.zlint_path;
    if (std.mem.eql(u8, name, "zwanzig")) return paths.zwanzig_path;
    if (std.mem.eql(u8, name, "zflame")) return paths.zflame_path;
    std.debug.assert(std.mem.eql(u8, name, "diff-folded"));
    return paths.diff_folded_path;
}

/// Builds backend probe argv JSON, replacing argv[0] with the configured path.
fn probeArgvValue(allocator: std.mem.Allocator, probe_argv: []const []const u8, configured_path: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (probe_argv, 0..) |item, index| {
        try array.append(.{ .string = if (index == 0) configured_path else item });
    }
    array_owned = false;
    return .{ .array = array };
}

/// Builds JSON group metadata with tool names and search keywords.
fn groupsValue(allocator: std.mem.Allocator) !std.json.Value {
    var groups = std.json.Array.init(allocator);
    var groups_owned = true;
    defer if (groups_owned) groups.deinit();
    for (groups_mod.group_specs) |group_spec| {
        var obj = std.json.ObjectMap.empty;
        var obj_owned = true;
        defer if (obj_owned) obj.deinit(allocator);
        try obj.put(allocator, "name", .{ .string = groupName(group_spec.group) });
        try obj.put(allocator, "tools", try groupToolsValue(allocator, group_spec.group));
        try obj.put(allocator, "keywords", try stringArrayValue(allocator, group_spec.keywords));
        try groups.append(.{ .object = obj });
        obj_owned = false;
    }
    groups_owned = false;
    return .{ .array = groups };
}

/// Builds the JSON list of tool names assigned to one group.
fn groupToolsValue(allocator: std.mem.Allocator, group: ToolGroup) !std.json.Value {
    var tools = std.json.Array.init(allocator);
    var tools_owned = true;
    defer if (tools_owned) tools.deinit();
    for (aggregate.entries) |entry| {
        if (entry.group == group) try tools.append(.{ .string = entry.name });
    }
    tools_owned = false;
    return .{ .array = tools };
}

/// Builds a JSON string array from borrowed string slices.
fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (values) |value| try array.append(.{ .string = value });
    array_owned = false;
    return .{ .array = array };
}

/// Builds JSON argument schema metadata for one registered tool.
fn toolArgumentValue(allocator: std.mem.Allocator, spec: ToolMeta) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
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
    if (spec.output_schema) |output_schema| {
        try obj.put(allocator, "output_shape", .{ .string = @tagName(output_schema.shape) });
    }
    obj_owned = false;
    return .{ .object = obj };
}

/// Builds JSON risk metadata for one registered tool.
fn toolRiskValue(allocator: std.mem.Allocator, spec: ToolMeta) !std.json.Value {
    return riskValue(allocator, spec);
}

/// Builds JSON planning metadata for one registered tool.
fn planningValue(allocator: std.mem.Allocator, entry: ToolEntry) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = planKind(entry.plan) });
    try obj.put(allocator, "group", .{ .string = groupName(entry.group) });
    try obj.put(allocator, "exact_command", .{ .bool = commandPlanFor(entry.id) != null });
    try obj.put(allocator, "supported", .{ .bool = switch (entry.plan) {
        .not_plannable => false,
        else => true,
    } });
    try obj.put(allocator, "risk_level", .{ .string = riskLevel(entry.risk) });
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
    obj_owned = false;
    return .{ .object = obj };
}

/// Finds a tool by name and returns null when no registry entry matches.
fn find(name: []const u8) ?ToolMeta {
    for (aggregate.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.meta;
    }
    return null;
}

/// Returns the registry entry for a tool id.
fn entryFor(id: aggregate.ToolId) ToolEntry {
    return aggregate.entries[@intFromEnum(id)];
}

/// Returns the manifest group assigned to a tool id.
fn groupFor(id: aggregate.ToolId) ToolGroup {
    return entryFor(id).group;
}

/// Returns the serialized manifest group name.
fn groupName(group: ToolGroup) []const u8 {
    return @tagName(group);
}

/// Returns the risk policy assigned to a tool id.
fn riskFor(id: aggregate.ToolId) ToolRisk {
    return entryFor(id).risk;
}

/// Returns the planning policy assigned to a tool id.
fn planFor(id: aggregate.ToolId) PlanPolicy {
    return entryFor(id).plan;
}

/// Returns an exact command plan when the tool is command-backed.
fn commandPlanFor(id: aggregate.ToolId) ?CommandPlan {
    return switch (planFor(id)) {
        .exact_command => |plan| plan,
        else => null,
    };
}

/// Returns the serialized planning policy kind.
fn planKind(plan: PlanPolicy) []const u8 {
    return switch (plan) {
        .exact_command => "exact_command",
        .dynamic_command => "dynamic_command",
        .zls_request => "zls_request",
        .apply_gated_mutation => "apply_gated_mutation",
        .workspace_artifact => "workspace_artifact",
        .pure_analysis => "pure_analysis",
        .not_plannable => "not_plannable",
    };
}

/// Returns the serialized risk level implied by risk flags.
fn riskLevel(risk: ToolRisk) []const u8 {
    if (risk.writes_source or risk.executes_user_command) return "high";
    if (risk.executes_project_code or risk.writes_artifacts) return "medium";
    if (risk.mutates_lsp_state or risk.executes_backend) return "low";
    return "none";
}

/// Builds JSON risk flags and planner hints for one registered tool.
fn riskValue(allocator: std.mem.Allocator, spec: ToolMeta) !std.json.Value {
    const risk_value = riskFor(spec.id);
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "level", .{ .string = riskLevel(risk_value) });
    try obj.put(allocator, "mcp_read_only_hint", .{ .bool = readOnlyHintFor(spec) });
    try obj.put(allocator, "writes_source", .{ .bool = risk_value.writes_source });
    try obj.put(allocator, "writes_artifacts", .{ .bool = risk_value.writes_artifacts });
    try obj.put(allocator, "writes_require_apply", .{ .bool = risk_value.writes_require_apply });
    try obj.put(allocator, "preview_by_default", .{ .bool = risk_value.preview_by_default });
    try obj.put(allocator, "mutates_lsp_state", .{ .bool = risk_value.mutates_lsp_state });
    try obj.put(allocator, "executes_project_code", .{ .bool = risk_value.executes_project_code });
    try obj.put(allocator, "executes_user_command", .{ .bool = risk_value.executes_user_command });
    try obj.put(allocator, "executes_backend", .{ .bool = risk_value.executes_backend });
    obj_owned = false;
    return .{ .object = obj };
}

/// Returns whether manifest risk metadata allows a read-only hint.
fn readOnlyHintFor(spec: ToolMeta) bool {
    const risk_value = riskFor(spec.id);
    return spec.read_only and
        !risk_value.writes_source and
        !risk_value.writes_artifacts and
        !risk_value.mutates_lsp_state and
        !risk_value.executes_project_code and
        !risk_value.executes_user_command;
}

/// Builds JSON schema fields filtered by required or optional status.
fn schemaFieldsValue(allocator: std.mem.Allocator, input_schema: tooling.SchemaSpec, required: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    for (input_schema.fields) |field| {
        if (field[2] == required) {
            try obj.put(allocator, field[0], .{ .string = field[1] });
        }
    }
    obj_owned = false;
    return .{ .object = obj };
}

/// Builds JSON schema fields with field-level hint metadata.
fn richSchemaFieldsValue(allocator: std.mem.Allocator, input_schema: tooling.SchemaSpec) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    for (input_schema.fields) |field| {
        try obj.put(allocator, field[0], try richSchemaFieldValue(allocator, input_schema, field));
    }
    obj_owned = false;
    return .{ .object = obj };
}

/// Builds JSON metadata for one schema field and its optional hints.
fn richSchemaFieldValue(allocator: std.mem.Allocator, input_schema: tooling.SchemaSpec, field: tooling.SchemaField) !std.json.Value {
    const hint = tooling.hintFor(input_schema, field);
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "type", .{ .string = field[1] });
    try obj.put(allocator, "required", .{ .bool = field[2] });
    try obj.put(allocator, "description", .{ .string = hint.description });
    if (hint.default_bool) |value| try obj.put(allocator, "default", .{ .bool = value });
    if (hint.default_int) |value| try obj.put(allocator, "default", .{ .integer = value });
    if (hint.default_string) |value| try obj.put(allocator, "default", .{ .string = value });
    if (hint.path_kind) |value| try obj.put(allocator, "path_kind", .{ .string = value });
    if (hint.completion_source) |value| try obj.put(allocator, "completion_source", .{ .string = @tagName(value) });
    if (hint.minimum) |value| try obj.put(allocator, "minimum", .{ .integer = value });
    if (hint.maximum) |value| try obj.put(allocator, "maximum", .{ .integer = value });
    if (hint.enum_values.len > 0) {
        var values = std.json.Array.init(allocator);
        var values_owned = true;
        defer if (values_owned) values.deinit();
        for (hint.enum_values) |value| try values.append(.{ .string = value });
        try obj.put(allocator, "enum", .{ .array = values });
        values_owned = false;
    }
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes a JSON value into allocator-owned bytes; allocation failures are returned.
fn serializeAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var writer_owned = true;
    defer if (writer_owned) aw.deinit();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    const bytes = try aw.toOwnedSlice();
    writer_owned = false;
    return bytes;
}
