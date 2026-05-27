//! Schema projection from manifest hints into MCP-compatible JSON schema values.
const std = @import("std");
const mcp = @import("mcp");

const tooling = @import("../../manifest/tooling.zig");

/// Converts manifest schema fields into MCP inputSchema properties/required arrays.
pub fn buildInputSchema(allocator: std.mem.Allocator, spec: tooling.SchemaSpec) !mcp.types.InputSchema {
    var properties = std.json.ObjectMap.empty;
    var required = std.ArrayList([]const u8).empty;
    var schema_owned = true;
    defer if (schema_owned) required.deinit(allocator);
    defer if (schema_owned) properties.deinit(allocator);

    for (spec.fields) |field| {
        var property = std.json.ObjectMap.empty;
        var property_owned = true;
        defer if (property_owned) property.deinit(allocator);
        try property.put(allocator, "type", .{ .string = field[1] });
        try applyFieldHint(allocator, &property, spec, field);
        try properties.put(allocator, field[0], .{ .object = property });
        property_owned = false;
        if (field[2]) try required.append(allocator, field[0]);
    }

    const required_slice = if (required.items.len > 0)
        try required.toOwnedSlice(allocator)
    else
        null;

    schema_owned = false;
    return .{
        .properties = .{ .object = properties },
        .required = required_slice,
    };
}

/// Converts a shared manifest output envelope into an MCP outputSchema.
pub fn buildOutputSchema(allocator: std.mem.Allocator, spec: tooling.OutputSchemaSpec) !mcp.types.OutputSchema {
    const fields = outputFields(spec.shape);
    var properties = std.json.ObjectMap.empty;
    var required = std.ArrayList([]const u8).empty;
    var schema_owned = true;
    defer if (schema_owned) required.deinit(allocator);
    defer if (schema_owned) properties.deinit(allocator);

    for (fields) |field| {
        var property = std.json.ObjectMap.empty;
        var property_owned = true;
        defer if (property_owned) property.deinit(allocator);
        try property.put(allocator, "type", .{ .string = field.type });
        try property.put(allocator, "description", .{ .string = field.description });
        try properties.put(allocator, field.name, .{ .object = property });
        property_owned = false;
        if (field.required) try required.append(allocator, field.name);
    }

    const required_slice = if (required.items.len > 0)
        try required.toOwnedSlice(allocator)
    else
        null;

    schema_owned = false;
    return .{
        .@"$schema" = "https://json-schema.org/draft/2020-12/schema",
        .properties = .{ .object = properties },
        .required = required_slice,
    };
}

/// Adds zigars-specific JSON schema hints such as defaults, enums, and path kind.
fn applyFieldHint(
    allocator: std.mem.Allocator,
    property: *std.json.ObjectMap,
    spec: tooling.SchemaSpec,
    field: tooling.SchemaField,
) !void {
    const hint = tooling.hintFor(spec, field);
    try property.put(allocator, "description", .{ .string = hint.description });
    if (hint.default_bool) |value| try property.put(allocator, "default", .{ .bool = value });
    if (hint.default_int) |value| try property.put(allocator, "default", .{ .integer = value });
    if (hint.default_string) |value| try property.put(allocator, "default", .{ .string = value });
    if (hint.path_kind) |value| try property.put(allocator, "x-zigars-path-kind", .{ .string = value });
    if (hint.minimum) |value| try property.put(allocator, "minimum", .{ .integer = value });
    if (hint.maximum) |value| try property.put(allocator, "maximum", .{ .integer = value });
    if (hint.enum_values.len > 0) {
        var values = std.json.Array.init(allocator);
        var values_owned = true;
        defer if (values_owned) values.deinit();
        for (hint.enum_values) |value| try values.append(.{ .string = value });
        try property.put(allocator, "enum", .{ .array = values });
        values_owned = false;
    }
}

const OutputField = struct {
    name: []const u8,
    type: []const u8,
    required: bool,
    description: []const u8,
};

/// Returns the compact shared output fields for an envelope shape.
fn outputFields(shape: tooling.OutputSchemaShape) []const OutputField {
    return switch (shape) {
        .error_envelope => &.{
            .{ .name = "kind", .type = "string", .required = true, .description = "Stable zigars result kind or error envelope kind." },
            .{ .name = "tool", .type = "string", .required = false, .description = "Tool that produced the error." },
            .{ .name = "code", .type = "string", .required = true, .description = "Stable error code." },
            .{ .name = "error", .type = "string", .required = false, .description = "Underlying Zig or backend error name." },
            .{ .name = "resolution", .type = "string", .required = true, .description = "Deterministic recovery guidance." },
        },
        .command_result => &.{
            .{ .name = "kind", .type = "string", .required = true, .description = "Stable zigars result kind." },
            .{ .name = "ok", .type = "boolean", .required = true, .description = "Whether the command-backed workflow succeeded." },
            .{ .name = "command", .type = "string", .required = false, .description = "Command or workflow label." },
            .{ .name = "argv", .type = "array", .required = false, .description = "Exact argv when available." },
            .{ .name = "stdout", .type = "string", .required = false, .description = "Bounded stdout text or tail." },
            .{ .name = "stderr", .type = "string", .required = false, .description = "Bounded stderr text or tail." },
            .{ .name = "elicitation_used", .type = "boolean", .required = false, .description = "Whether MCP elicitation/create contributed to the result." },
            .{ .name = "elicitation_status", .type = "string", .required = false, .description = "Normalized elicitation/create status when a workflow attempted or reported elicitation." },
            .{ .name = "elicitation_unavailable_reason", .type = "string", .required = false, .description = "Why elicitation was not used when the workflow could otherwise ask for confirmation." },
            .{ .name = "sampling_used", .type = "boolean", .required = false, .description = "Whether MCP sampling contributed to the result summary." },
            .{ .name = "sampling_status", .type = "string", .required = false, .description = "Normalized sampling/createMessage status when a workflow attempted or reported sampling." },
            .{ .name = "sampled_summary", .type = "string", .required = false, .description = "Client-sampled summary text when sampling/createMessage succeeds." },
            .{ .name = "summary_unavailable_reason", .type = "string", .required = false, .description = "Why protocol sampling did not provide a summary." },
        },
        .analysis_result => &.{
            .{ .name = "kind", .type = "string", .required = true, .description = "Stable analysis result kind." },
            .{ .name = "ok", .type = "boolean", .required = false, .description = "Whether the analysis completed without a tool error." },
            .{ .name = "evidence_source", .type = "string", .required = false, .description = "Primary evidence basis for the analysis." },
            .{ .name = "confidence", .type = "string", .required = false, .description = "Declared confidence tier." },
            .{ .name = "limitations", .type = "string", .required = false, .description = "Bounded analysis limitations." },
            .{ .name = "resolution", .type = "string", .required = false, .description = "Suggested deterministic follow-up." },
            .{ .name = "elicitation_used", .type = "boolean", .required = false, .description = "Whether MCP elicitation/create contributed to the result." },
            .{ .name = "elicitation_status", .type = "string", .required = false, .description = "Normalized elicitation/create status when a workflow attempted or reported elicitation." },
            .{ .name = "elicitation_unavailable_reason", .type = "string", .required = false, .description = "Why elicitation was not used when the workflow could otherwise ask for confirmation." },
            .{ .name = "sampling_used", .type = "boolean", .required = false, .description = "Whether MCP sampling contributed to the result summary." },
            .{ .name = "sampling_status", .type = "string", .required = false, .description = "Normalized sampling/createMessage status when a workflow attempted or reported sampling." },
            .{ .name = "sampled_summary", .type = "string", .required = false, .description = "Client-sampled summary text when sampling/createMessage succeeds." },
            .{ .name = "summary_unavailable_reason", .type = "string", .required = false, .description = "Why protocol sampling did not provide a summary." },
        },
        .patch_session => &.{
            .{ .name = "kind", .type = "string", .required = true, .description = "Stable patch/session result kind." },
            .{ .name = "session_id", .type = "string", .required = false, .description = "Process or workspace-local session identity." },
            .{ .name = "applied", .type = "boolean", .required = false, .description = "Whether a mutation was applied." },
            .{ .name = "preimages", .type = "array", .required = false, .description = "Preimage identities used to gate mutation." },
            .{ .name = "artifacts", .type = "array", .required = false, .description = "Artifact identities emitted by the workflow." },
            .{ .name = "resolution", .type = "string", .required = false, .description = "Next action guidance." },
            .{ .name = "elicitation_used", .type = "boolean", .required = false, .description = "Whether MCP elicitation/create contributed to the result." },
            .{ .name = "elicitation_status", .type = "string", .required = false, .description = "Normalized elicitation/create status when a patch-session apply attempted or reported elicitation." },
            .{ .name = "elicitation_unavailable_reason", .type = "string", .required = false, .description = "Why elicitation was not used when apply confirmation falls back to apply=true and preimage checks." },
        },
        .artifact => &.{
            .{ .name = "kind", .type = "string", .required = true, .description = "Stable artifact result kind." },
            .{ .name = "ok", .type = "boolean", .required = true, .description = "Whether the artifact operation succeeded." },
            .{ .name = "path", .type = "string", .required = false, .description = "Workspace-relative artifact path." },
            .{ .name = "sha256", .type = "string", .required = false, .description = "Artifact sha256 identity." },
            .{ .name = "resource_uri", .type = "string", .required = false, .description = "MCP resource URI for reading the artifact by sha." },
            .{ .name = "omitted_sections", .type = "array", .required = false, .description = "Explicit result-shape omissions." },
            .{ .name = "resolution", .type = "string", .required = false, .description = "Next action guidance." },
        },
    };
}
