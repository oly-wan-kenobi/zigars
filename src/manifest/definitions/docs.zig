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

/// List bundled curated Zig builtin docs; source is partial curated zigars data.
pub const zig_builtin_list = tool(.{ .description = "List bundled curated Zig builtin docs; source is partial curated zigars data.", .input_schema = schema(&.{}), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
/// Return bundled curated Zig builtin docs with source, completeness, count, and ranking metadata.
pub const zig_builtin_list_json = tool(.{ .description = "Return bundled curated Zig builtin docs with source, completeness, count, and ranking metadata.", .input_schema = schema(&.{}), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
/// Search bundled curated Zig builtin docs; text output includes partial-curated source metadata.
pub const zig_builtin_doc = tool(.{ .description = "Search bundled curated Zig builtin docs; text output includes partial-curated source metadata.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
/// Search bundled curated Zig builtin docs with source, completeness, query, limit, result-count, no-result, and ranking metadata.
pub const zig_builtin_doc_json = tool(.{ .description = "Search bundled curated Zig builtin docs with source, completeness, query, limit, result-count, no-result, and ranking metadata.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
/// Search local Zig stdlib .zig source files; results note that this is source scanning, not rendered stdlib docs.
pub const zig_std_search = tool(.{ .description = "Search local Zig stdlib .zig source files; this is source scanning, not rendered stdlib documentation.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
/// JSON variant: same search with source-scan provenance, result-count, no-result, and ranking metadata.
pub const zig_std_search_json = tool(.{ .description = "Search local Zig stdlib .zig source files with source-scan provenance, query, limit, result-count, no-result, and ranking metadata.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
/// Look up exact Zig stdlib declaration-name matches in local .zig source; not rendered stdlib documentation.
pub const zig_std_item = tool(.{ .description = "Look up exact Zig stdlib declaration-name matches in local .zig source; not rendered stdlib documentation.", .input_schema = schema(&.{ .{ "name", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
/// Look up exact Zig stdlib declaration-name matches with source-scan provenance, query, limit, result-count, no-result, and ranking metadata.
pub const zig_std_item_json = tool(.{ .description = "Look up exact Zig stdlib declaration-name matches with source-scan provenance, query, limit, result-count, no-result, and ranking metadata.", .input_schema = schema(&.{ .{ "name", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
/// Search installed langref HTML or bundled partial langref fallback; text includes source/completeness metadata.
pub const zig_lang_ref_search = tool(.{ .description = "Search installed langref HTML or bundled partial langref fallback; text includes source/completeness metadata.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
/// Search installed langref HTML or bundled partial langref fallback with source, completeness, query, limit, result-count, no-result, and ranking metadata.
pub const zig_lang_ref_search_json = tool(.{ .description = "Search installed langref HTML or bundled partial langref fallback with source, completeness, query, limit, result-count, no-result, and ranking metadata.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .plan = .{ .pure_analysis = docs_plan } });
