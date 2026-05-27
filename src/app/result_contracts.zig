//! Typed, non-JSON result contracts used internally before transport encoding.
const std = @import("std");

const errors = @import("errors.zig");

/// Version for the typed result-shape contract.
pub const schema_version: u32 = 1;
/// Lower bound applied to requested token budgets.
pub const min_token_budget: i64 = 500;
/// Upper bound applied to requested token budgets.
pub const max_token_budget: i64 = 50_000;

/// Response shape profile selected before transport encoding.
pub const OutputMode = enum {
    compact,
    standard,
    deep,

    /// Stable mode name used in result payloads.
    pub fn name(self: OutputMode) []const u8 {
        return @tagName(self);
    }

    /// Human-facing description for mode metadata.
    pub fn description(self: OutputMode) []const u8 {
        return switch (self) {
            .compact => "Small response with stable machine fields, a short summary, and explicit omissions.",
            .standard => "Balanced response with machine fields, evidence, limitations, and compact human-readable context.",
            .deep => "Expanded response with fuller evidence and diagnostics while preserving explicit omission metadata.",
        };
    }

    /// Default planning budget for this mode.
    pub fn defaultBudget(self: OutputMode) i64 {
        return switch (self) {
            .compact => 1_200,
            .standard => 4_000,
            .deep => 12_000,
        };
    }
};

/// Coarse confidence marker for generated contract metadata.
pub const Confidence = enum {
    low,
    medium,
    high,

    /// Stable confidence name used in result payloads.
    pub fn name(self: Confidence) []const u8 {
        return @tagName(self);
    }
};

/// Description of an intentionally omitted response section.
pub const OmittedSection = struct {
    section: []const u8,
    reason: []const u8,
    recovery: []const u8,
};

/// Static metadata describing one output mode.
pub const ModeMetadata = struct {
    schema_version: u32,
    mode: OutputMode,
    description: []const u8,
    default_token_budget: i64,
    stable_machine_fields: []const []const u8,
    included_sections: []const []const u8,
    omitted_by_default: []const []const u8,
    omission_contract: []const u8,
};

/// Request for the result shape contract.
pub const ResultShapeRequest = struct {
    mode: OutputMode = .standard,
};

/// Borrowed typed result-shape contract; no allocator-owned fields.
pub const ResultShapeContract = struct {
    kind: []const u8 = "zigars_result_shape",
    schema_version: u32,
    ok: bool = true,
    mode: OutputMode,
    default_mode: OutputMode = .standard,
    selected_mode: OutputMode,
    supported_modes: []const OutputMode,
    selected_mode_metadata: ModeMetadata,
    result_shape: ModeMetadata,
    omitted_sections: []const OmittedSection,
    evidence_source: []const u8,
    confidence: Confidence,
    required_top_level_fields: []const []const u8,
    limitations: []const u8,
    resolution: []const u8,

    /// This initial contract is backed by static slices and borrowed request
    /// fields only; there is no allocator-owned payload to release.
    pub fn ownsMemory(_: ResultShapeContract) bool {
        return false;
    }
};

/// Request for token budget planning.
pub const OutputBudgetPlanRequest = struct {
    mode: OutputMode = .standard,
    requested_token_budget: ?i64 = null,
    tool_name: ?[]const u8 = null,
};

/// Token budget allocation across response sections.
pub const BudgetAllocation = struct {
    machine_fields_tokens: i64,
    evidence_tokens: i64,
    human_summary_tokens: i64,
    priority_order: []const []const u8,
};

/// Borrowed token budget plan; no allocator-owned fields.
pub const OutputBudgetPlan = struct {
    kind: []const u8 = "zigars_output_budget_plan",
    schema_version: u32,
    tool_name: ?[]const u8,
    mode: OutputMode,
    requested_token_budget: ?i64,
    default_token_budget: i64,
    effective_token_budget: i64,
    min_token_budget: i64,
    max_token_budget: i64,
    clamp_applied: bool,
    allocation: BudgetAllocation,
    omission_policy: []const u8,
    evidence_source: []const u8,
    confidence: Confidence,
    limitations: []const u8,
    resolution: []const u8,
    result_shape: ModeMetadata,

    /// `tool_name` is borrowed from the request. All other slices point to
    /// static contract data. Callers do not deinit this value.
    pub fn ownsMemory(_: OutputBudgetPlan) bool {
        return false;
    }
};

const supported_modes = [_]OutputMode{ .compact, .standard, .deep };
const empty_omitted_sections = [_]OmittedSection{};
const required_top_level_fields = [_][]const u8{
    "kind",
    "ok",
    "mode",
    "result_shape",
    "omitted_sections",
    "evidence_source",
    "confidence",
    "limitations",
    "resolution",
};
const compact_machine_fields = [_][]const u8{ "kind", "ok", "mode", "result_shape", "omitted_sections", "resolution" };
const standard_machine_fields = [_][]const u8{ "kind", "ok", "mode", "result_shape", "evidence_source", "confidence", "limitations", "omitted_sections", "resolution" };
const deep_machine_fields = [_][]const u8{ "kind", "ok", "mode", "result_shape", "evidence_source", "confidence", "limitations", "omitted_sections", "resolution", "diagnostics" };
const compact_included_sections = [_][]const u8{ "machine_fields", "short_summary", "omission_metadata" };
const standard_included_sections = [_][]const u8{ "machine_fields", "summary", "evidence", "limitations", "omission_metadata" };
const deep_included_sections = [_][]const u8{ "machine_fields", "summary", "expanded_evidence", "diagnostics", "limitations", "omission_metadata" };
const compact_omitted_by_default = [_][]const u8{ "raw_backend_output", "large_collections", "source_snippets", "debug_trace" };
const standard_omitted_by_default = [_][]const u8{ "raw_backend_output", "debug_trace", "unbounded_collections" };
const deep_omitted_by_default = [_][]const u8{ "unbounded_raw_output", "client_tokenizer_exact_accounting" };
const compact_priority = [_][]const u8{ "machine_fields", "omitted_sections", "short_summary", "evidence_pointer" };
const standard_priority = [_][]const u8{ "machine_fields", "evidence", "limitations", "summary", "omitted_sections" };
const deep_priority = [_][]const u8{ "machine_fields", "expanded_evidence", "diagnostics", "limitations", "omitted_sections" };

/// Parses an output mode or returns a typed invalid-argument error.
pub fn parseOutputMode(raw: []const u8) errors.Result(OutputMode) {
    inline for (std.meta.fields(OutputMode)) |field| {
        if (std.mem.eql(u8, raw, field.name)) return .{ .ok = @field(OutputMode, field.name) };
    }
    return .{ .err = errors.invalidArgument(
        "mode",
        supportedModesText(),
        raw,
        "Choose compact for routing, standard for normal use, or deep for expanded evidence.",
    ) };
}

/// Returns a static human-readable list of supported modes.
pub fn supportedModesText() []const u8 {
    return "compact, standard, or deep";
}

/// Returns borrowed static metadata for one output mode.
pub fn modeMetadata(mode: OutputMode) ModeMetadata {
    return .{
        .schema_version = schema_version,
        .mode = mode,
        .description = mode.description(),
        .default_token_budget = mode.defaultBudget(),
        .stable_machine_fields = stableMachineFields(mode),
        .included_sections = includedSections(mode),
        .omitted_by_default = omittedByDefault(mode),
        .omission_contract = "Every omitted or truncated section must be named in omitted_sections with a reason and recovery path.",
    };
}

/// Builds the typed result-shape contract without allocating.
pub fn describeResultShape(request: ResultShapeRequest) ResultShapeContract {
    const metadata = modeMetadata(request.mode);
    return .{
        .schema_version = schema_version,
        .mode = request.mode,
        .selected_mode = request.mode,
        .supported_modes = supported_modes[0..],
        .selected_mode_metadata = metadata,
        .result_shape = metadata,
        .omitted_sections = empty_omitted_sections[0..],
        .evidence_source = "static zigars result-shape contract",
        .confidence = .high,
        .required_top_level_fields = required_top_level_fields[0..],
        .limitations = "This contract standardizes response shape and omissions; it does not prove tool-specific correctness.",
        .resolution = "Validate public tool schemas and inspect each handler result for result_shape and omitted_sections.",
    };
}

/// Builds a typed token budget plan without allocating.
pub fn planOutputBudget(request: OutputBudgetPlanRequest) OutputBudgetPlan {
    const default_budget = request.mode.defaultBudget();
    const requested = request.requested_token_budget orelse default_budget;
    const effective = clampTokenBudget(requested);

    return .{
        .schema_version = schema_version,
        .tool_name = request.tool_name,
        .mode = request.mode,
        .requested_token_budget = request.requested_token_budget,
        .default_token_budget = default_budget,
        .effective_token_budget = effective,
        .min_token_budget = min_token_budget,
        .max_token_budget = max_token_budget,
        .clamp_applied = requested != effective,
        .allocation = allocation(request.mode, effective),
        .omission_policy = "Prefer stable machine fields first, then evidence, then human detail; record every dropped section in omitted_sections.",
        .evidence_source = "static zigars result-shape budget policy",
        .confidence = .medium,
        .limitations = "Token counts are planning budgets, not tokenizer-exact guarantees for every MCP client.",
        .resolution = "Use mode=compact for routing, mode=standard for normal agent use, and mode=deep when a human or verifier needs fuller evidence.",
        .result_shape = modeMetadata(request.mode),
    };
}

/// Clamps a requested budget to the supported range.
pub fn clampTokenBudget(value: i64) i64 {
    return @max(min_token_budget, @min(value, max_token_budget));
}

/// Implements allocation workflow logic using caller-owned inputs.
fn allocation(mode: OutputMode, effective_budget: i64) BudgetAllocation {
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

    return .{
        .machine_fields_tokens = @divTrunc(effective_budget * machine_pct, 100),
        .evidence_tokens = @divTrunc(effective_budget * evidence_pct, 100),
        .human_summary_tokens = @divTrunc(effective_budget * human_pct, 100),
        .priority_order = switch (mode) {
            .compact => compact_priority[0..],
            .standard => standard_priority[0..],
            .deep => deep_priority[0..],
        },
    };
}

/// Implements stable machine fields workflow logic using caller-owned inputs.
fn stableMachineFields(mode: OutputMode) []const []const u8 {
    return switch (mode) {
        .compact => compact_machine_fields[0..],
        .standard => standard_machine_fields[0..],
        .deep => deep_machine_fields[0..],
    };
}

/// Implements included sections workflow logic using caller-owned inputs.
fn includedSections(mode: OutputMode) []const []const u8 {
    return switch (mode) {
        .compact => compact_included_sections[0..],
        .standard => standard_included_sections[0..],
        .deep => deep_included_sections[0..],
    };
}

/// Implements omitted by default workflow logic using caller-owned inputs.
fn omittedByDefault(mode: OutputMode) []const []const u8 {
    return switch (mode) {
        .compact => compact_omitted_by_default[0..],
        .standard => standard_omitted_by_default[0..],
        .deep => deep_omitted_by_default[0..],
    };
}
