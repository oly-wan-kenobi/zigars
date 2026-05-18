const std = @import("std");
const mcp = @import("mcp");

pub const catalog_json = @embedFile("tool_catalog.json");

pub const SchemaField = struct { []const u8, []const u8, bool };
pub const SchemaSpec = struct { fields: []const SchemaField };

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

pub fn schema(comptime fields: []const SchemaField) SchemaSpec {
    return .{ .fields = fields };
}

pub fn buildInputSchema(allocator: std.mem.Allocator, spec: SchemaSpec) !mcp.types.InputSchema {
    var properties = std.json.ObjectMap.empty;
    var required = std.ArrayList([]const u8).empty;
    errdefer {
        properties.deinit(allocator);
        required.deinit(allocator);
    }

    for (spec.fields) |field| {
        var property = std.json.ObjectMap.empty;
        errdefer property.deinit(allocator);
        try property.put(allocator, "type", .{ .string = field[1] });
        try applyFieldHint(allocator, &property, field);
        try properties.put(allocator, field[0], .{ .object = property });
        if (field[2]) try required.append(allocator, field[0]);
    }

    const required_slice = if (required.items.len > 0)
        try required.toOwnedSlice(allocator)
    else
        null;

    return .{
        .properties = .{ .object = properties },
        .required = required_slice,
    };
}

pub fn hintFor(field: SchemaField) FieldHint {
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
    if (std.mem.eql(u8, name, "wait_ms")) return .{ .description = "How long to wait for asynchronous ZLS diagnostics.", .default_int = 500, .minimum = 0 };
    if (std.mem.eql(u8, name, "limit")) return .{ .description = "Maximum number of records to return.", .minimum = 1 };
    if (std.mem.eql(u8, name, "line") or std.mem.eql(u8, name, "start_line") or std.mem.eql(u8, name, "end_line")) return .{ .description = "Zero-based line number.", .minimum = 0 };
    if (std.mem.eql(u8, name, "character") or std.mem.eql(u8, name, "start_char") or std.mem.eql(u8, name, "end_char")) return .{ .description = "Zero-based UTF-16 character offset.", .minimum = 0 };
    if (std.mem.eql(u8, name, "args")) return .{ .description = "Extra whitespace-split argv fragments. zigar does not invoke a shell." };
    if (std.mem.eql(u8, name, "command")) return .{ .description = "Command name or argv text accepted by the specific tool." };
    if (std.mem.eql(u8, name, "query")) return .{ .description = "Search query." };
    if (std.mem.eql(u8, name, "mode")) return .{ .description = "Tool-specific mode selector.", .enum_values = &.{ "tiny", "standard", "deep", "quick", "full", "check", "test", "fmt-check" } };
    if (std.mem.eql(u8, name, "client")) return .{ .description = "Agent/client profile.", .enum_values = &.{ "codex", "claude", "generic" } };
    if (std.mem.eql(u8, name, "format")) return .{ .description = "Profiler input format passed to zflame.", .default_string = "guess", .enum_values = &.{ "perf", "dtrace", "sample", "vtune", "xctrace", "recursive", "guess" } };
    if (std.mem.eql(u8, name, "probe_backends") or std.mem.eql(u8, name, "probe_managers")) return .{ .description = "Run extra backend probes instead of using cheap static checks.", .default_bool = false };
    if (std.mem.eql(u8, name, "refresh")) return .{ .description = "Rebuild the cached workspace index.", .default_bool = false };
    if (std.mem.eql(u8, name, "stop_on_failure")) return .{ .description = "Stop validation after the first failed phase.", .default_bool = false };
    if (std.mem.eql(u8, name, "include_declaration")) return .{ .description = "Include the declaration location in reference results.", .default_bool = true };
    if (std.mem.eql(u8, name, "hash")) return .{ .description = "Enable zflame hash coloring when supported.", .default_bool = false };
    return .{ .description = "Tool argument." };
}

pub fn boolDefault(name: []const u8, fallback: bool) bool {
    const hint = hintFor(.{ name, "boolean", false });
    return hint.default_bool orelse fallback;
}

pub fn intDefault(name: []const u8, fallback: i64) i64 {
    const hint = hintFor(.{ name, "integer", false });
    return hint.default_int orelse fallback;
}

fn applyFieldHint(allocator: std.mem.Allocator, property: *std.json.ObjectMap, field: SchemaField) !void {
    const hint = hintFor(field);
    try property.put(allocator, "description", .{ .string = hint.description });
    if (hint.default_bool) |value| try property.put(allocator, "default", .{ .bool = value });
    if (hint.default_int) |value| try property.put(allocator, "default", .{ .integer = value });
    if (hint.default_string) |value| try property.put(allocator, "default", .{ .string = value });
    if (hint.path_kind) |value| try property.put(allocator, "x-zigar-path-kind", .{ .string = value });
    if (hint.minimum) |value| try property.put(allocator, "minimum", .{ .integer = value });
    if (hint.maximum) |value| try property.put(allocator, "maximum", .{ .integer = value });
    if (hint.enum_values.len > 0) {
        var values = std.json.Array.init(allocator);
        errdefer values.deinit();
        for (hint.enum_values) |value| try values.append(.{ .string = value });
        try property.put(allocator, "enum", .{ .array = values });
    }
}

test "static catalog declares generated manifest sections" {
    try std.testing.expect(std.mem.indexOf(u8, catalog_json, "\"tool_argument_scope\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_json, "\"tools_list_schema_note\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_json, "\"source_write_gate\"") != null);
}

test "input schema includes discovery hints" {
    var s = try buildInputSchema(std.testing.allocator, schema(&.{
        .{ "file", "string", true },
        .{ "apply", "boolean", false },
    }));
    defer if (s.required) |required| std.testing.allocator.free(required);
    defer if (s.properties) |*properties| {
        var it = properties.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.object.get("enum")) |*value| value.array.deinit();
            entry.value_ptr.object.deinit(std.testing.allocator);
        }
        properties.object.deinit(std.testing.allocator);
    };
    const file = s.properties.?.object.get("file").?.object;
    try std.testing.expectEqualStrings("Workspace-relative source file path.", file.get("description").?.string);
    try std.testing.expectEqualStrings("input_file", file.get("x-zigar-path-kind").?.string);
    const apply = s.properties.?.object.get("apply").?.object;
    try std.testing.expect(!apply.get("default").?.bool);
}

test "field hints expose reusable runtime defaults" {
    try std.testing.expect(!boolDefault("probe_managers", true));
    try std.testing.expect(!boolDefault("stop_on_failure", true));
    try std.testing.expect(boolDefault("unknown", true));
    try std.testing.expectEqual(@as(i64, 500), intDefault("wait_ms", 0));
    try std.testing.expectEqual(@as(i64, 42), intDefault("unknown", 42));
}
