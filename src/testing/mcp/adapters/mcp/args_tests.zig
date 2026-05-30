//! Pins the argument validation contract for the MCP adapter layer:
//! required/optional presence, type checking, enum values, integer bounds,
//! and the M1/M2 reachability invariant (advertised fields must be accepted;
//! removed or inapplicable fields must be rejected as unknown_argument).

const std = @import("std");

const args = @import("../../../../adapters/mcp/args.zig");
const manifest = @import("../../../../manifest/mod.zig");
const tooling = @import("../../../../manifest/tooling.zig");

test "finds schema fields" {
    const spec = manifest.find("zig_check").?;
    const field = args.findSchemaField(spec.input_schema, "file").?;
    try std.testing.expect(field[2]);
    try std.testing.expectEqualStrings("string", field[1]);
}

test "accepts empty argument object for no-argument tool" {
    const spec = manifest.find("zig_version").?;
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(std.testing.allocator);
    const result = try args.validateToolArgs(std.testing.allocator, spec, .{ .object = obj });
    try std.testing.expect(result == null);
}

test "accepts absent params for tools without required arguments" {
    const spec = manifest.find("zig_version").?;
    try std.testing.expect((try args.validateToolArgs(std.testing.allocator, spec, null)) == null);
}

test "rejects missing required argument when params are absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const spec = manifest.find("zig_check").?;

    const result = (try args.validateToolArgs(arena.allocator(), spec, null)).?;
    const err = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("missing_required_argument", err.get("code").?.string);
    try std.testing.expectEqualStrings("file", err.get("field").?.string);
}

test "rejects enum arguments outside schema hints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const spec = manifest.find("zigars_context_pack").?;

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "mode", .{ .string = "sideways" });
    const result = (try args.validateToolArgs(allocator, spec, .{ .object = obj })).?;
    const err = result.structuredContent.?.object;

    try std.testing.expectEqualStrings("argument_error", err.get("kind").?.string);
    try std.testing.expectEqualStrings("invalid_enum_value", err.get("code").?.string);
    try std.testing.expectEqualStrings("mode", err.get("field").?.string);
    try std.testing.expect(std.mem.indexOf(u8, err.get("expected").?.string, "standard") != null);
    try std.testing.expectEqualStrings("sideways", err.get("actual").?.string);
}

test "validates enum hints in tool context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const context_spec = manifest.find("zigars_context_pack").?;
    const validate_spec = manifest.find("zigars_validate_patch").?;

    var context_obj = std.json.ObjectMap.empty;
    try context_obj.put(allocator, "mode", .{ .string = "quick" });
    const context_result = (try args.validateToolArgs(allocator, context_spec, .{ .object = context_obj })).?;
    const context_err = context_result.structuredContent.?.object;
    try std.testing.expectEqualStrings("invalid_enum_value", context_err.get("code").?.string);
    try std.testing.expect(std.mem.indexOf(u8, context_err.get("expected").?.string, "deep") != null);
    try std.testing.expect(std.mem.indexOf(u8, context_err.get("expected").?.string, "quick") == null);

    var validate_obj = std.json.ObjectMap.empty;
    try validate_obj.put(allocator, "mode", .{ .string = "quick" });
    try std.testing.expect((try args.validateToolArgs(allocator, validate_spec, .{ .object = validate_obj })) == null);

    var invalid_validate_obj = std.json.ObjectMap.empty;
    try invalid_validate_obj.put(allocator, "mode", .{ .string = "deep" });
    const validate_result = (try args.validateToolArgs(allocator, validate_spec, .{ .object = invalid_validate_obj })).?;
    const validate_err = validate_result.structuredContent.?.object;
    try std.testing.expectEqualStrings("invalid_enum_value", validate_err.get("code").?.string);
    try std.testing.expect(std.mem.indexOf(u8, validate_err.get("expected").?.string, "quick") != null);
    try std.testing.expect(std.mem.indexOf(u8, validate_err.get("expected").?.string, "deep") == null);
}

test "rejects integer arguments below schema minimum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const spec = manifest.find("zig_std_search").?;

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "query", .{ .string = "ArrayList" });
    try obj.put(allocator, "limit", .{ .integer = 0 });
    const result = (try args.validateToolArgs(allocator, spec, .{ .object = obj })).?;
    const err = result.structuredContent.?.object;

    try std.testing.expectEqualStrings("argument_error", err.get("kind").?.string);
    try std.testing.expectEqualStrings("below_minimum", err.get("code").?.string);
    try std.testing.expectEqualStrings("limit", err.get("field").?.string);
    try std.testing.expectEqualStrings("integer >= 1", err.get("expected").?.string);
    try std.testing.expectEqualStrings("0", err.get("actual").?.string);
}

/// Returns true when `tool` advertises `field` and a typed value for it is
/// accepted by central validation (i.e. the handler can actually receive it).
///
/// Some tools have other required fields; submitting only `field` can therefore
/// surface a `missing_required_argument` for a *different* field. That is fine —
/// it still proves `field` itself is not rejected as `unknown_argument`, which is
/// the exact reachability contract M1/M2 are about. The check fails only if the
/// field is missing from the schema or is rejected as unknown/invalid for itself.
fn advertisedArgAccepted(tool_name: []const u8, field: []const u8, value: std.json.Value) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const spec = manifest.find(tool_name).?;
    // The field must be registered in the schema, otherwise it is advertised
    // nowhere and a handler that reads it can never receive it.
    if (args.findSchemaField(spec.input_schema, field) == null) return false;
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, field, value);
    const result = (try args.validateToolArgs(allocator, spec, .{ .object = obj })) orelse return true;
    const err = result.structuredContent.?.object;
    const code = err.get("code").?.string;
    // A missing-required error for another field still proves `field` was accepted.
    if (std.mem.eql(u8, code, "missing_required_argument")) {
        const offending = err.get("field").?.string;
        return !std.mem.eql(u8, offending, field);
    }
    return false;
}

/// Returns true when passing `field` to `tool` is rejected as an unknown argument.
fn unknownArgRejected(tool_name: []const u8, field: []const u8, value: std.json.Value) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const spec = manifest.find(tool_name).?;
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, field, value);
    const result = (try args.validateToolArgs(allocator, spec, .{ .object = obj })) orelse return false;
    const err = result.structuredContent.?.object;
    return std.mem.eql(u8, err.get("code").?.string, "unknown_argument");
}

test "advertised timeout_ms is honored on backend-spawning static tools" {
    // M1: these handlers read timeout_ms; it must be reachable through the schema.
    const tools = [_][]const u8{
        "zig_lint",
        "zig_lint_sarif",
        "zig_lint_rules",
        "zig_analysis_graphs",
        "zig_semantic_refs",
        "zig_semantic_callers",
        "zig_format",
    };
    for (tools) |tool_name| {
        try std.testing.expect(try advertisedArgAccepted(tool_name, "timeout_ms", .{ .integer = 1000 }));
    }
}

test "removed diagnostics wait_ms and timeout_ms are rejected as unknown" {
    // M2f: the diagnostics handler (zigDiagnostics/zigDiagnosticsAll -> fileOnlyTool)
    // reads only file + content, so these advertised-but-unread fields were removed
    // from the schemas and must now be rejected as unknown arguments.
    try std.testing.expect(try unknownArgRejected("zig_diagnostics", "wait_ms", .{ .integer = 500 }));
    try std.testing.expect(try unknownArgRejected("zig_diagnostics_all", "wait_ms", .{ .integer = 500 }));
    try std.testing.expect(try unknownArgRejected("zig_diagnostics_all", "timeout_ms", .{ .integer = 1000 }));
}

test "advertised autodoc is honored on both docs query tools" {
    // The shared docsQueryTool reads autodoc; both query tools must advertise it.
    try std.testing.expect(try advertisedArgAccepted("zig_docs_query", "autodoc", .{ .string = "[]" }));
    try std.testing.expect(try advertisedArgAccepted("zig_project_docs_query", "autodoc", .{ .string = "[]" }));
}

test "advertised filter is honored on test-event tools and failure fusion" {
    // zigars_failure_fusion and zig_test_events read filter; both must advertise it.
    try std.testing.expect(try advertisedArgAccepted("zigars_failure_fusion", "filter", .{ .string = "MyTest" }));
    try std.testing.expect(try advertisedArgAccepted("zig_test_events", "filter", .{ .string = "MyTest" }));
}

test "advertised coverage cross-fields match the handler reads" {
    // zig_coverage_diff reads current/baseline only.
    try std.testing.expect(try advertisedArgAccepted("zig_coverage_diff", "current", .{ .string = "{}" }));
    try std.testing.expect(try advertisedArgAccepted("zig_coverage_diff", "baseline", .{ .string = "{}" }));
    // zig_coverage_budget_check reads coverage + thresholds + changed_files only.
    try std.testing.expect(try advertisedArgAccepted("zig_coverage_budget_check", "coverage", .{ .string = "{}" }));
    try std.testing.expect(try advertisedArgAccepted("zig_coverage_budget_check", "min_line_rate_bp", .{ .integer = 8000 }));
    try std.testing.expect(try advertisedArgAccepted("zig_coverage_budget_check", "changed_files", .{ .string = "src/main.zig" }));
}

test "advertised bench compare fields match the handler reads" {
    try std.testing.expect(try advertisedArgAccepted("zig_bench_compare", "current", .{ .string = "{}" }));
    try std.testing.expect(try advertisedArgAccepted("zig_bench_compare", "baseline", .{ .string = "{}" }));
    try std.testing.expect(try advertisedArgAccepted("zig_bench_compare", "threshold_pct", .{ .integer = 5 }));
}

test "advertised corpus is honored on the AFL fuzz tool" {
    // zig_afl_run reads corpus and target; both must be reachable.
    try std.testing.expect(try advertisedArgAccepted("zig_afl_run", "corpus", .{ .string = "corpus" }));
    try std.testing.expect(try advertisedArgAccepted("zig_afl_run", "target", .{ .string = "native" }));
}

test "removed and inapplicable arguments are rejected as unknown" {
    // M2: these arguments were advertised but never read; they must now be rejected.
    try std.testing.expect(try unknownArgRejected("zigars_context_pack", "include", .{ .string = "build" }));
    try std.testing.expect(try unknownArgRejected("zig_coverage_diff", "coverage", .{ .string = "{}" }));
    try std.testing.expect(try unknownArgRejected("zig_coverage_diff", "min_line_rate_bp", .{ .integer = 8000 }));
    try std.testing.expect(try unknownArgRejected("zig_coverage_budget_check", "current", .{ .string = "{}" }));
    try std.testing.expect(try unknownArgRejected("zig_coverage_budget_check", "baseline", .{ .string = "{}" }));
    try std.testing.expect(try unknownArgRejected("zig_bench_compare", "results", .{ .string = "{}" }));
    try std.testing.expect(try unknownArgRejected("zig_bench_compare", "limit", .{ .integer = 10 }));
    // libFuzzer takes its corpus inside the command; AFL-specific args are not advertised.
    try std.testing.expect(try unknownArgRejected("zig_libfuzzer_run", "corpus", .{ .string = "corpus" }));
    try std.testing.expect(try unknownArgRejected("zig_libfuzzer_run", "afl_path", .{ .string = "afl-fuzz" }));
    // zig_build_events has no test filter (a build is not test-filtered).
    try std.testing.expect(try unknownArgRejected("zig_build_events", "filter", .{ .string = "MyTest" }));
    // zig_rename / zig_code_action_apply are preview-only and never advertised apply.
    try std.testing.expect(try unknownArgRejected("zig_rename", "apply", .{ .bool = true }));
    try std.testing.expect(try unknownArgRejected("zig_code_action_apply", "apply", .{ .bool = true }));
}

test "rejects integer arguments above schema maximum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const base = manifest.find("zig_check").?;
    const spec = manifest.ToolMeta{
        .id = base.id,
        .name = "bounded_tool",
        .description = "bounded fixture",
        .input_schema = tooling.schemaWithHints(&.{.{ "count", "integer", true }}, &.{
            .{ .field_name = "count", .hint = .{ .description = "Bounded count.", .minimum = 1, .maximum = 3 } },
        }),
        .output_schema = null,
        .read_only = true,
    };

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "count", .{ .integer = 4 });
    const result = (try args.validateToolArgs(allocator, spec, .{ .object = obj })).?;
    const err = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("above_maximum", err.get("code").?.string);
    try std.testing.expectEqualStrings("integer <= 3", err.get("expected").?.string);
    try std.testing.expectEqualStrings("4", err.get("actual").?.string);
}
