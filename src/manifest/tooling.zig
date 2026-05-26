const std = @import("std");

/// Static catalog JSON that is enriched with generated manifest metadata.
pub const catalog_json = @embedFile("tool_catalog.json");

/// Minimal schema field tuple: name, JSON type, and required flag.
pub const SchemaField = struct { []const u8, []const u8, bool };
/// Optional metadata override for one schema field.
pub const SchemaFieldHint = struct {
    field_name: []const u8,
    hint: FieldHint,
};
/// Schema fields plus optional field-level UI and validation hints.
pub const SchemaSpec = struct {
    fields: []const SchemaField,
    field_hints: []const SchemaFieldHint = &.{},
};

/// Human-facing field metadata used when rendering rich catalog schemas.
pub const FieldHint = struct {
    description: []const u8,
    default_bool: ?bool = null,
    default_int: ?i64 = null,
    default_string: ?[]const u8 = null,
    enum_values: []const []const u8 = &.{},
    path_kind: ?[]const u8 = null,
    minimum: ?i64 = null,
    maximum: ?i64 = null,
};

/// Creates a schema with no custom field hints.
pub fn schema(comptime fields: []const SchemaField) SchemaSpec {
    return .{ .fields = fields };
}

/// Creates a schema with explicit hints for selected fields.
pub fn schemaWithHints(comptime fields: []const SchemaField, comptime field_hints: []const SchemaFieldHint) SchemaSpec {
    return .{ .fields = fields, .field_hints = field_hints };
}

/// Resolves a field hint, falling back to conventional defaults by field name.
pub fn hintFor(spec: SchemaSpec, field: SchemaField) FieldHint {
    for (spec.field_hints) |override| {
        if (std.mem.eql(u8, override.field_name, field[0])) return override.hint;
    }
    return defaultHintFor(field);
}

/// Supplies common defaults for shared argument names.
fn defaultHintFor(field: SchemaField) FieldHint {
    const name = field[0];
    if (std.mem.eql(u8, name, "file")) return .{ .description = "Workspace-relative source file path.", .path_kind = "input_file" };
    if (std.mem.eql(u8, name, "path")) return .{ .description = "Workspace-relative path.", .path_kind = "input_path" };
    if (std.mem.eql(u8, name, "output")) return .{ .description = "Workspace-relative output path.", .path_kind = "output_path" };
    if (std.mem.eql(u8, name, "input")) return .{ .description = "Workspace-relative input artifact path.", .path_kind = "input_file" };
    if (std.mem.eql(u8, name, "before")) return .{ .description = "Workspace-relative baseline input path.", .path_kind = "input_file" };
    if (std.mem.eql(u8, name, "after")) return .{ .description = "Workspace-relative comparison input path.", .path_kind = "input_file" };
    if (std.mem.eql(u8, name, "from")) return .{ .description = "Workspace-relative source file used to resolve a relative import.", .path_kind = "input_file" };
    if (std.mem.eql(u8, name, "content")) return .{ .description = "Complete source text to preview, analyze, or sync in memory." };
    if (std.mem.eql(u8, name, "apply")) return .{ .description = "Must be true before a tool writes source or workspace artifacts.", .default_bool = false };
    if (std.mem.eql(u8, name, "timeout_ms")) return .{ .description = "Per-call timeout in milliseconds; values must be positive and may be clamped by zigar.", .minimum = 1 };
    if (std.mem.eql(u8, name, "max_bytes")) return .{ .description = "Maximum bytes to read from a bounded artifact or document.", .default_int = 65536, .minimum = 1 };
    if (std.mem.eql(u8, name, "token_budget")) return .{ .description = "Approximate output token budget for result-shape planning.", .minimum = 1 };
    if (std.mem.eql(u8, name, "wait_ms")) return .{ .description = "How long to wait for asynchronous ZLS diagnostics.", .default_int = 500, .minimum = 0 };
    if (std.mem.eql(u8, name, "limit")) return .{ .description = "Maximum number of records to return.", .minimum = 1 };
    if (std.mem.eql(u8, name, "line") or std.mem.eql(u8, name, "start_line") or std.mem.eql(u8, name, "end_line")) return .{ .description = "Zero-based line number.", .minimum = 0 };
    if (std.mem.eql(u8, name, "character") or std.mem.eql(u8, name, "start_char") or std.mem.eql(u8, name, "end_char")) return .{ .description = "Zero-based UTF-16 character offset.", .minimum = 0 };
    if (std.mem.eql(u8, name, "args")) return .{ .description = "Extra whitespace-split argv fragments. zigar does not invoke a shell." };
    if (std.mem.eql(u8, name, "command")) return .{ .description = "Command name or argv text accepted by the specific tool." };
    if (std.mem.eql(u8, name, "query")) return .{ .description = "Search query." };
    if (std.mem.eql(u8, name, "mode")) return .{ .description = "Tool-specific mode selector." };
    if (std.mem.eql(u8, name, "client")) return .{ .description = "Agent/client profile." };
    if (std.mem.eql(u8, name, "format")) return .{ .description = "Tool-specific format selector." };
    if (std.mem.eql(u8, name, "probe_backends") or std.mem.eql(u8, name, "probe_managers")) return .{ .description = "Run extra backend probes instead of using cheap static checks.", .default_bool = false };
    if (std.mem.eql(u8, name, "include_hashes")) return .{ .description = "Include bounded artifact hashes where practical.", .default_bool = true };
    if (std.mem.eql(u8, name, "include_clean_tree")) return .{ .description = "Run a bounded git clean-tree check as part of the report.", .default_bool = false };
    if (std.mem.eql(u8, name, "include_none")) return .{ .description = "Include tools whose risk level is none.", .default_bool = false };
    if (std.mem.eql(u8, name, "include_configured_paths")) return .{ .description = "Include the server's currently configured backend paths in setup catalog output.", .default_bool = true };
    if (std.mem.eql(u8, name, "refresh")) return .{ .description = "Rebuild the cached workspace index.", .default_bool = false };
    if (std.mem.eql(u8, name, "stop_on_failure")) return .{ .description = "Stop validation after the first failed phase.", .default_bool = false };
    if (std.mem.eql(u8, name, "include_declaration")) return .{ .description = "Include the declaration location in reference results.", .default_bool = true };
    if (std.mem.eql(u8, name, "hash")) return .{ .description = "Enable zflame hash coloring when supported.", .default_bool = false };
    return .{ .description = "Tool argument." };
}

/// Returns the declared boolean default for a field, or the caller fallback.
pub fn boolDefault(spec: SchemaSpec, name: []const u8, fallback: bool) bool {
    const field = findField(spec, name) orelse return fallback;
    const hint = hintFor(spec, field);
    return hint.default_bool orelse fallback;
}

/// Returns the declared integer default for a field, or the caller fallback.
pub fn intDefault(spec: SchemaSpec, name: []const u8, fallback: i64) i64 {
    const field = findField(spec, name) orelse return fallback;
    const hint = hintFor(spec, field);
    return hint.default_int orelse fallback;
}

/// Finds a schema field by name without allocating.
fn findField(spec: SchemaSpec, name: []const u8) ?SchemaField {
    for (spec.fields) |field| {
        if (std.mem.eql(u8, field[0], name)) return field;
    }
    return null;
}
