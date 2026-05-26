//! JSON-building helpers for response shape metadata and token budget plans.
//! Returned values are allocator-owned unless a function documents borrowing.
const std = @import("std");

/// Version for JSON result-shape metadata emitted by these helpers.
pub const schema_version = 1;
/// Lower bound applied to requested token budgets.
pub const min_token_budget: i64 = 500;
/// Upper bound applied to requested token budgets.
pub const max_token_budget: i64 = 50_000;

/// JSON-oriented response shape profile.
pub const ResultShapeMode = enum {
    compact,
    standard,
    deep,

    /// Stable mode name used in JSON payloads.
    pub fn name(self: ResultShapeMode) []const u8 {
        return @tagName(self);
    }

    /// Human-facing description for JSON metadata.
    pub fn description(self: ResultShapeMode) []const u8 {
        return switch (self) {
            .compact => "Small response with stable machine fields, a short summary, and explicit omissions.",
            .standard => "Balanced response with machine fields, evidence, limitations, and compact human-readable context.",
            .deep => "Expanded response with fuller evidence and diagnostics while preserving explicit omission metadata.",
        };
    }

    /// Default planning budget for this mode.
    pub fn defaultBudget(self: ResultShapeMode) i64 {
        return switch (self) {
            .compact => 1_200,
            .standard => 4_000,
            .deep => 12_000,
        };
    }
};

/// Parses a mode name, returning null for caller-specific error handling.
pub fn parseMode(raw: []const u8) ?ResultShapeMode {
    inline for (std.meta.fields(ResultShapeMode)) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @field(ResultShapeMode, field.name);
    }
    return null;
}

/// Returns a static human-readable list of supported modes.
pub fn supportedModesText() []const u8 {
    return "compact, standard, or deep";
}

/// Allocates a JSON array containing supported mode names.
pub fn supportedModeNamesValue(allocator: std.mem.Allocator) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    inline for (std.meta.fields(ResultShapeMode)) |field| {
        try array.append(.{ .string = field.name });
    }
    return .{ .array = array };
}

/// Allocates JSON metadata for one result shape mode.
pub fn modeMetadataValue(allocator: std.mem.Allocator, mode: ResultShapeMode) !std.json.Value {
    // Ownership of child values is transferred into `obj` via put().
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "mode", .{ .string = mode.name() });
    try obj.put(allocator, "description", .{ .string = mode.description() });
    try obj.put(allocator, "default_token_budget", .{ .integer = mode.defaultBudget() });
    try obj.put(allocator, "stable_machine_fields", try stringArrayValue(allocator, stableMachineFields(mode)));
    try obj.put(allocator, "included_sections", try stringArrayValue(allocator, includedSections(mode)));
    try obj.put(allocator, "omitted_by_default", try stringArrayValue(allocator, omittedByDefault(mode)));
    try obj.put(allocator, "omission_contract", .{ .string = "Every omitted or truncated section must be named in omitted_sections with a reason and recovery path." });
    obj_owned = false;
    return .{ .object = obj };
}

/// Allocates the full JSON result-shape contract for transport output.
pub fn contractValue(allocator: std.mem.Allocator, mode: ResultShapeMode) !std.json.Value {
    // Contract payload is fully materialized JSON for transport serialization.
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_result_shape" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "mode", .{ .string = mode.name() });
    try obj.put(allocator, "default_mode", .{ .string = ResultShapeMode.standard.name() });
    try obj.put(allocator, "selected_mode", .{ .string = mode.name() });
    try obj.put(allocator, "supported_modes", try supportedModesValue(allocator));
    try obj.put(allocator, "selected_mode_metadata", try modeMetadataValue(allocator, mode));
    try obj.put(allocator, "result_shape", try modeMetadataValue(allocator, mode));
    try obj.put(allocator, "omitted_sections", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "evidence_source", .{ .string = "static zigar result-shape contract" });
    try obj.put(allocator, "confidence", .{ .string = "high" });
    try obj.put(allocator, "required_top_level_fields", try stringArrayValue(allocator, &.{
        "kind",
        "ok",
        "mode",
        "result_shape",
        "omitted_sections",
        "evidence_source",
        "confidence",
        "limitations",
        "resolution",
    }));
    try obj.put(allocator, "limitations", .{ .string = "This contract standardizes response shape and omissions; it does not prove tool-specific correctness." });
    try obj.put(allocator, "resolution", .{ .string = "Validate public tool schemas and inspect each handler result for result_shape and omitted_sections." });
    obj_owned = false;
    return .{ .object = obj };
}

/// Input for JSON token budget planning.
pub const BudgetPlanInput = struct {
    mode: ResultShapeMode,
    requested_token_budget: ?i64 = null,
    tool_name: ?[]const u8 = null,
};

/// Allocates a JSON token budget plan.
pub fn budgetPlanValue(allocator: std.mem.Allocator, input: BudgetPlanInput) !std.json.Value {
    const default_budget = input.mode.defaultBudget();
    const requested = input.requested_token_budget orelse default_budget;
    const effective = clampTokenBudget(requested);
    const clamp_applied = requested != effective;

    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_output_budget_plan" });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "tool", if (input.tool_name) |tool_name| .{ .string = tool_name } else .null);
    try obj.put(allocator, "mode", .{ .string = input.mode.name() });
    try obj.put(allocator, "requested_token_budget", if (input.requested_token_budget) |_| .{ .integer = requested } else .null);
    try obj.put(allocator, "default_token_budget", .{ .integer = default_budget });
    try obj.put(allocator, "effective_token_budget", .{ .integer = effective });
    try obj.put(allocator, "min_token_budget", .{ .integer = min_token_budget });
    try obj.put(allocator, "max_token_budget", .{ .integer = max_token_budget });
    try obj.put(allocator, "clamp_applied", .{ .bool = clamp_applied });
    try obj.put(allocator, "allocation", try allocationValue(allocator, input.mode, effective));
    try obj.put(allocator, "omission_policy", .{ .string = "Prefer stable machine fields first, then evidence, then human detail; record every dropped section in omitted_sections." });
    try obj.put(allocator, "evidence_source", .{ .string = "static zigar result-shape budget policy" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "limitations", .{ .string = "Token counts are planning budgets, not tokenizer-exact guarantees for every MCP client." });
    try obj.put(allocator, "resolution", .{ .string = "Use mode=compact for routing, mode=standard for normal agent use, and mode=deep when a human or verifier needs fuller evidence." });
    try obj.put(allocator, "result_shape", try modeMetadataValue(allocator, input.mode));
    obj_owned = false;
    return .{ .object = obj };
}

/// Clamps a requested budget to the supported range.
pub fn clampTokenBudget(value: i64) i64 {
    return @max(min_token_budget, @min(value, max_token_budget));
}

/// Allocates one omitted-section JSON object.
pub fn omissionValue(allocator: std.mem.Allocator, section: []const u8, reason: []const u8, recovery: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "section", .{ .string = section });
    try obj.put(allocator, "reason", .{ .string = reason });
    try obj.put(allocator, "recovery", .{ .string = recovery });
    return .{ .object = obj };
}

/// Attaches mode metadata and caller-owned omission array to an existing object.
pub fn attachMetadata(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, mode: ResultShapeMode, omitted_sections: std.json.Array) !void {
    try obj.put(allocator, "mode", .{ .string = mode.name() });
    try obj.put(allocator, "result_shape", try modeMetadataValue(allocator, mode));
    try obj.put(allocator, "omitted_sections", .{ .array = omitted_sections });
}

fn supportedModesValue(allocator: std.mem.Allocator) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    inline for (std.meta.fields(ResultShapeMode)) |field| {
        const mode = @field(ResultShapeMode, field.name);
        try array.append(try modeMetadataValue(allocator, mode));
    }
    array_owned = false;
    return .{ .array = array };
}

fn allocationValue(allocator: std.mem.Allocator, mode: ResultShapeMode, effective_budget: i64) !std.json.Value {
    const machine_pct: i64 = switch (mode) {
        .compact => 55,
        .standard => 35,
        .deep => 25,
    };
    const evidence_pct: i64 = switch (mode) {
        .compact => 20,
        .standard => 35,
        .deep => 45,
    };
    const human_pct = 100 - machine_pct - evidence_pct;

    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "machine_fields_tokens", .{ .integer = @divTrunc(effective_budget * machine_pct, 100) });
    try obj.put(allocator, "evidence_tokens", .{ .integer = @divTrunc(effective_budget * evidence_pct, 100) });
    try obj.put(allocator, "human_summary_tokens", .{ .integer = @divTrunc(effective_budget * human_pct, 100) });
    try obj.put(allocator, "priority_order", try stringArrayValue(allocator, switch (mode) {
        .compact => &.{ "machine_fields", "omitted_sections", "short_summary", "evidence_pointer" },
        .standard => &.{ "machine_fields", "evidence", "limitations", "summary", "omitted_sections" },
        .deep => &.{ "machine_fields", "expanded_evidence", "diagnostics", "limitations", "omitted_sections" },
    }));
    obj_owned = false;
    return .{ .object = obj };
}

fn stableMachineFields(mode: ResultShapeMode) []const []const u8 {
    return switch (mode) {
        .compact => &.{ "kind", "ok", "mode", "result_shape", "omitted_sections", "resolution" },
        .standard => &.{ "kind", "ok", "mode", "result_shape", "evidence_source", "confidence", "limitations", "omitted_sections", "resolution" },
        .deep => &.{ "kind", "ok", "mode", "result_shape", "evidence_source", "confidence", "limitations", "omitted_sections", "resolution", "diagnostics" },
    };
}

fn includedSections(mode: ResultShapeMode) []const []const u8 {
    return switch (mode) {
        .compact => &.{ "machine_fields", "short_summary", "omission_metadata" },
        .standard => &.{ "machine_fields", "summary", "evidence", "limitations", "omission_metadata" },
        .deep => &.{ "machine_fields", "summary", "expanded_evidence", "diagnostics", "limitations", "omission_metadata" },
    };
}

fn omittedByDefault(mode: ResultShapeMode) []const []const u8 {
    return switch (mode) {
        .compact => &.{ "raw_backend_output", "large_collections", "source_snippets", "debug_trace" },
        .standard => &.{ "raw_backend_output", "debug_trace", "unbounded_collections" },
        .deep => &.{ "unbounded_raw_output", "client_tokenizer_exact_accounting" },
    };
}

fn stringArrayValue(allocator: std.mem.Allocator, items: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (items) |item| try array.append(.{ .string = item });
    array_owned = false;
    return .{ .array = array };
}
