//! Tool definitions for the `docs` group: offline Zig builtin, stdlib, and
//! language-reference lookups. All tools are read-only, pure-analysis, and
//! require no network or optional backend — results carry explicit
//! source/completeness metadata so callers know the data's fidelity.
const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const fieldHint = types.fieldHint;

/// Shared plan string for every tool in this module: signals to the planner
/// that no network, ZLS session, or optional backend is involved.
const docs_plan = "Offline docs lookup; no network, ZLS, or optional backend.";

/// Shared enum hint: every docs lookup returns a text summary by default, or the
/// full structured JSON payload (source/completeness/ranking metadata) when
/// `output_format=json`. This replaces the former `*_json` twin tools.
const output_format_hint = fieldHint("output_format", .{ .description = "Result format: \"text\" summary (default) or structured \"json\" payload with source, completeness, and ranking metadata.", .default_string = "text", .enum_values = &.{ "text", "json" } });

/// List bundled curated Zig builtin docs; source is partial curated zigars data.
pub const zig_builtin_list = tool(.{ .description = "List bundled curated Zig builtin docs; source is partial curated zigars data. Set output_format=json for source, completeness, count, and ranking metadata.", .input_schema = schemaWithHints(&.{.{ "output_format", "string", false }}, &.{output_format_hint}), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
/// Search bundled curated Zig builtin docs; text output includes partial-curated source metadata.
pub const zig_builtin_doc = tool(.{ .description = "Search bundled curated Zig builtin docs; text includes partial-curated source metadata. Set output_format=json for source, completeness, query, limit, result-count, no-result, and ranking metadata.", .input_schema = schemaWithHints(&.{ .{ "query", "string", true }, .{ "limit", "integer", false }, .{ "output_format", "string", false } }, &.{output_format_hint}), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
/// Search local Zig stdlib .zig source files; results note that this is source scanning, not rendered stdlib docs.
pub const zig_std_search = tool(.{ .description = "Search local Zig stdlib .zig source files; this is source scanning, not rendered stdlib documentation. Set output_format=json for source-scan provenance, query, limit, result-count, no-result, and ranking metadata.", .input_schema = schemaWithHints(&.{ .{ "query", "string", true }, .{ "limit", "integer", false }, .{ "output_format", "string", false } }, &.{output_format_hint}), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
/// Look up exact Zig stdlib declaration-name matches in local .zig source; not rendered stdlib documentation.
pub const zig_std_item = tool(.{ .description = "Look up exact Zig stdlib declaration-name matches in local .zig source; not rendered stdlib documentation. Set output_format=json for source-scan provenance, query, limit, result-count, no-result, and ranking metadata.", .input_schema = schemaWithHints(&.{ .{ "name", "string", true }, .{ "limit", "integer", false }, .{ "output_format", "string", false } }, &.{output_format_hint}), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
/// Search installed langref HTML or bundled partial langref fallback; text includes source/completeness metadata.
pub const zig_lang_ref_search = tool(.{ .description = "Search installed langref HTML or bundled partial langref fallback; text includes source/completeness metadata. Set output_format=json for source, completeness, query, limit, result-count, no-result, and ranking metadata.", .input_schema = schemaWithHints(&.{ .{ "query", "string", true }, .{ "limit", "integer", false }, .{ "output_format", "string", false } }, &.{output_format_hint}), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
