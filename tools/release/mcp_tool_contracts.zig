//! Per-tool MCP schema and error contract probes.
//! Checks that every manifest entry has a correct JSON schema, required-field
//! count, structured invalid-input response, and apply gate for source writes.
//! The manifest is the source of truth; the runtime validator is exercised
//! directly so both the declaration and the runtime path are tested together.
const std = @import("std");
const zigars = @import("zigars");

const Io = std.Io;
const Allocator = std.mem.Allocator;

// Each probe injects a deliberately unknown argument so the validator must
// produce a structured argument_error; a missing response or wrong field values
// indicate the tool's error contract is not wired up correctly.

/// Checks one manifest entry against MCP schema and structured-error contracts.
pub fn checkToolContract(allocator: Allocator, io: Io, comptime entry: zigars.manifest.ToolEntry) !bool {
    // Fail fast on the first mismatch to keep diagnostics deterministic.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ok = true;
    const schema = try zigars.adapters.mcp.schema.buildInputSchema(a, entry.meta.input_schema);
    if (schema.properties == null) ok = (try missingTool(io, entry.name, "schema properties object")) and ok;
    var required_count: usize = 0;
    for (entry.meta.input_schema.fields) |field| {
        if (schema.properties == null or schema.properties.?.object.get(field[0]) == null) ok = (try missingTool(io, entry.name, field[0])) and ok;
        if (field[2]) required_count += 1;
    }
    const actual_required = if (schema.required) |required| required.len else 0;
    if (actual_required != required_count) ok = (try missingTool(io, entry.name, "required-field schema count")) and ok;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "__zigars_contract_probe", .{ .bool = true });
    const invalid = (try zigars.adapters.mcp.registry.validateToolArgs(a, entry.meta, .{ .object = obj })) orelse {
        return missingTool(io, entry.name, "structured invalid-input result");
    };
    if (!toolErrorHas(invalid, entry.name, "unknown_argument")) ok = (try missingTool(io, entry.name, "structured invalid-input fields")) and ok;
    if (entry.risk.writes_source and !hasField(entry, "apply")) ok = (try missingTool(io, entry.name, "apply gate for source writes")) and ok;
    if ((entry.risk.writes_artifacts or entry.risk.executes_backend) and std.mem.eql(u8, zigars.manifest.planKind(entry.plan), "not_plannable")) ok = (try missingTool(io, entry.name, "success/unavailable or artifact plan")) and ok;
    return ok;
}

/// Returns `true` when `result` is a structured error with `kind`,
/// `tool`, and `code` fields matching the expected values.
fn toolErrorHas(result: anytype, tool: []const u8, code: []const u8) bool {
    const sc = result.structuredContent orelse return false;
    if (!result.is_error or sc != .object) return false;
    const obj = sc.object;
    return stringField(obj, "kind", "argument_error") and stringField(obj, "tool", tool) and stringField(obj, "code", code);
}

/// Checks that an object field is the expected string value.
fn stringField(obj: std.json.ObjectMap, name: []const u8, expected: []const u8) bool {
    const value = obj.get(name) orelse return false;
    return value == .string and std.mem.eql(u8, value.string, expected);
}

/// Returns `true` when the input schema for `entry` contains a field named `name`.
fn hasField(comptime entry: zigars.manifest.ToolEntry, name: []const u8) bool {
    for (entry.meta.input_schema.fields) |field| {
        if (std.mem.eql(u8, field[0], name)) return true;
    }
    return false;
}

/// Reports one missing per-tool contract field and returns `false`.
fn missingTool(io: Io, tool: []const u8, missing: []const u8) !bool {
    try stderrPrint(io, "MCP tool contract missing for {s}: {s}\n", .{ tool, missing });
    return false;
}

/// Writes a formatted diagnostic to stderr.
fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "MCP per-tool contract checker exposes manifest entry probe" {
    try std.testing.expect(@hasDecl(@This(), "checkToolContract"));
}
