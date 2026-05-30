//! Cross-cutting manifest invariant tests.
//!
//! Pins risk-flag consistency, apply-gate wire reachability, planning-policy
//! alignment, and group keyword coverage across every registered tool entry.
//! Each test documents a named finding from the review campaign so regressions
//! are traceable.

const std = @import("std");

test "manifest schema hints target declared fields and matching types" {
    for (manifest.entries) |entry| {
        for (entry.meta.input_schema.field_hints) |override| {
            const field = fieldByName(entry.meta.input_schema, override.field_name) orelse return error.ManifestHintForUnknownField;
            const hint = override.hint;
            if (hint.default_bool != null) try expectFieldType(entry.name, field, "boolean");
            if (hint.default_int != null or hint.minimum != null or hint.maximum != null) try expectFieldType(entry.name, field, "integer");
            if (hint.default_string != null or hint.enum_values.len > 0 or hint.path_kind != null) try expectFieldType(entry.name, field, "string");
        }
    }
}
test "manifest side-effect metadata stays aligned with planning policy" {
    for (manifest.entries) |entry| {
        const risk = entry.risk;
        switch (entry.plan) {
            .apply_gated_mutation => {
                try std.testing.expect(risk.writes_require_apply);
                try std.testing.expect(risk.preview_by_default);
            },
            .workspace_artifact => try std.testing.expect(risk.writes_artifacts),
            .zls_request => |plan| if (plan.mutates_document_state) try std.testing.expect(risk.mutates_lsp_state),
            else => {},
        }
        if (risk.writes_source) {
            try std.testing.expect(risk.writes_require_apply);
            try std.testing.expect(risk.preview_by_default);
            try std.testing.expect(!manifest.readOnlyHintFor(entry.meta));
            try std.testing.expect(!manifest.idempotentHintFor(entry.meta));
        }
        if (risk.writes_artifacts or risk.executes_project_code or risk.executes_user_command or risk.mutates_lsp_state) {
            try std.testing.expect(!manifest.readOnlyHintFor(entry.meta));
        }
        if (!risk.writes_require_apply or !risk.preview_by_default) {
            if (risk.writes_source or risk.writes_artifacts or risk.executes_project_code or risk.executes_user_command or risk.mutates_lsp_state) {
                try std.testing.expect(manifest.destructiveHintFor(entry.meta));
            }
        }
    }
}
test "command and source execution unconditionally advertises destructiveHint" {
    // Capability dominates the apply-gate: any tool that executes a caller command,
    // executes project code, or writes source MUST advertise destructiveHint=true,
    // even when it is apply-gated and previews by default. The previous guard
    // suppressed this for the 15 gated execution tools, so this assertion fails on
    // pre-fix code (e.g. zig_libfuzzer_run / zig_format reported false).
    for (manifest.entries) |entry| {
        const risk = entry.risk;
        if (risk.executes_user_command or risk.executes_project_code or risk.writes_source) {
            try std.testing.expect(manifest.destructiveHintFor(entry.meta));
        }
    }
}
test "raw read_only never coexists with source writes or user-command execution" {
    // The raw read_only field is internal source-of-truth; keep it consistent with
    // the two capabilities that unambiguously contradict it. validateDefinition
    // enforces this at comptime; this test pins the runtime view across every
    // registered entry. On pre-fix code zig_matrix_check / zig_profile_run declared
    // read_only=true with executes_user_command=true, so this assertion fails there.
    //
    // writes_artifacts / mutates_lsp_state / executes_project_code are intentionally
    // not asserted here: the manifest sets raw read_only=true on tools carrying
    // those flags and the MCP hint is derived correctly by readOnlyHintFor.
    for (manifest.entries) |entry| {
        if (entry.meta.read_only) {
            try std.testing.expect(!entry.risk.writes_source);
            try std.testing.expect(!entry.risk.executes_user_command);
        }
    }
}
test "the 15 reviewed command-execution tools advertise destructiveHint" {
    // Acceptance pin for Finding 1: the exact arbitrary-command-execution tools
    // that previously reported destructiveHint=false (because they are apply-gated
    // and preview by default) must now report true. Named explicitly so a renamed
    // or recategorized tool cannot silently drop out of coverage.
    const reviewed = [_][]const u8{
        "zig_libfuzzer_run",   "zig_afl_run",           "zig_qemu_test",
        "zig_heaptrack_run",   "zig_valgrind_memcheck", "zig_callgrind_report",
        "zig_lldb_backtrace",  "zig_core_inspect",      "zig_objdump_summary",
        "zig_dwarfdump_check", "zig_symbolize",         "zig_coverage_run",
        "zig_bench_run",       "zig_samply_record",     "zig_tracy_capture",
    };
    for (reviewed) |name| {
        const meta = manifest.find(name) orelse return error.MissingReviewedTool;
        try std.testing.expect(manifest.destructiveHintFor(meta));
    }
}
test "apply-gated tools expose an apply boolean in their input schema" {
    // Acceptance pin for Finding 4: validateDefinition enforces this at comptime;
    // assert it at runtime so the wire-reachable apply gate stays observable.
    for (manifest.entries) |entry| {
        if (!entry.risk.writes_require_apply) continue;
        var has_apply_boolean = false;
        for (entry.meta.input_schema.fields) |field| {
            if (std.mem.eql(u8, field[0], "apply") and std.mem.eql(u8, field[1], "boolean")) has_apply_boolean = true;
        }
        try std.testing.expect(has_apply_boolean);
    }
}
test "manifest free-form args and output fields disclose runtime risk" {
    for (manifest.entries) |entry| {
        if (fieldByName(entry.meta.input_schema, "args") != null and runsFromRuntimeArguments(entry)) {
            try std.testing.expect(entry.risk.executes_backend or entry.risk.executes_project_code or entry.risk.executes_user_command);
        }
        if (fieldByName(entry.meta.input_schema, "output") != null and entry.group != .discovery) {
            try std.testing.expect(entry.risk.writes_artifacts);
        }
    }
}
test "public api diff text snapshots are not advertised as input paths" {
    const entry = manifest.findEntry("zig_public_api_diff") orelse return error.MissingTool;
    const before = fieldByName(entry.meta.input_schema, "before") orelse return error.MissingField;
    const after = fieldByName(entry.meta.input_schema, "after") orelse return error.MissingField;
    try std.testing.expect(tooling.hintFor(entry.meta.input_schema, before).path_kind == null);
    try std.testing.expect(tooling.hintFor(entry.meta.input_schema, after).path_kind == null);
}
test "tool group keyword metadata covers each group once" {
    const fields = @typeInfo(manifest.ToolGroup).@"enum".fields;
    try std.testing.expectEqual(fields.len, manifest.group_specs.len);
    inline for (fields) |field| {
        var count: usize = 0;
        for (manifest.group_specs) |spec| {
            if (std.mem.eql(u8, manifest.groupName(spec.group), field.name)) {
                count += 1;
                try std.testing.expect(spec.keywords.len > 0);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
}

const manifest = @import("mod.zig");
const tooling = @import("tooling.zig");

/// Returns the first schema field with the given name, or null when absent.
/// Used to probe optional schema slots (e.g. `apply`, `args`, `output`)
/// without asserting their presence upfront.
fn fieldByName(spec: tooling.SchemaSpec, name: []const u8) ?tooling.SchemaField {
    for (spec.fields) |field| {
        if (std.mem.eql(u8, field[0], name)) return field;
    }
    return null;
}

/// Returns true when the tool's plan executes a command that may be shaped by
/// runtime arguments, which implies the `args` field should be accompanied by
/// an execution risk flag in the tool definition.
fn runsFromRuntimeArguments(entry: manifest.ToolEntry) bool {
    return switch (entry.plan) {
        .exact_command, .dynamic_command, .workspace_artifact => true,
        else => false,
    };
}

/// Asserts that a schema field's JSON type string matches `expected`.
/// `tool_name` is accepted but unused; it remains in the signature so future
/// diagnostics can include the tool name without a signature change.
fn expectFieldType(tool_name: []const u8, field: tooling.SchemaField, expected: []const u8) !void {
    _ = tool_name;
    try std.testing.expectEqualStrings(expected, field[1]);
}
