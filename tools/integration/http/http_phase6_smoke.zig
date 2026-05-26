const std = @import("std");
const cli_io = @import("../../common/cli_io.zig");
const smoke = @import("../smoke_support.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const valueAt = smoke.valueAt;

const FieldValue = union(enum) {
    string: []const u8,
    bool: bool,
    integer: i64,
};

const Field = struct {
    key: []const u8,
    value: FieldValue,
};

const ci_log = "src/main.zig:1:2: error: fixture failure\n";
const api_baseline =
    \\{"kind":"zig_api_baseline","declarations":[{"file":"src/lib.zig","line":1,"kind":"fn","name":"old","signature":"pub fn old() void {}"}],"declaration_count":1}
;
const dependency_manifest =
    \\.{
    \\    .dependencies = .{
    \\        .dep_a = .{
    \\            .url = "https://example.com/dep-a.tar.gz",
    \\            .hash = "1220fixturehash",
    \\        },
    \\        .local_dep = .{
    \\            .path = "deps/local",
    \\        },
    \\    },
    \\}
;
const docs_example =
    \\# Example
    \\```zig
    \\pub fn ok() void {}
    \\```
;
const readme_commands =
    \\```sh
    \\zig build test
    \\```
;
const autodoc_json = "{\"name\":\"FixtureSymbol\",\"docs\":\"FixtureSymbol docs\"}";
const osv_report = "{\"vulns\":[{\"id\":\"CVE-2024-0001\"}]}";

pub fn run(allocator: std.mem.Allocator, io: Io, port: u16, expected: JsonValue, scenario_count: *usize) !void {
    try assertToolFields(allocator, io, port, 140, "zig_ci_ingest", &.{ str("content", ci_log), str("format", "log") }, expected, "phase6_ci_ingest_paths", scenario_count);
    try assertToolFields(allocator, io, port, 141, "zig_ci_repro_plan", &.{ str("content", ci_log), str("format", "log"), str("changed_files", "src/main.zig") }, expected, "phase6_ci_repro_plan_paths", scenario_count);
    try assertToolFields(allocator, io, port, 142, "zig_ci_failure_map", &.{ str("content", ci_log), str("format", "log") }, expected, "phase6_ci_failure_map_paths", scenario_count);
    try assertToolFields(allocator, io, port, 143, "zig_release_plan", &.{ str("goal", "fixture release"), str("validation", "tests passed"), str("ci", "ci passed"), str("api", "api checked"), str("docs", "docs checked"), str("dependencies", "deps checked"), str("security", "security reviewed"), str("changelog", "notes drafted") }, expected, "phase6_release_plan_paths", scenario_count);
    try assertToolFields(allocator, io, port, 144, "zig_semver_suggest", &.{ str("api_diff", "breaking change"), str("current_version", "1.2.3") }, expected, "phase6_semver_suggest_paths", scenario_count);
    try assertToolFields(allocator, io, port, 145, "zig_release_notes_draft", &.{ str("version", "1.2.4"), str("changes", "Added fixture capability."), str("validation", "tests passed") }, expected, "phase6_release_notes_draft_paths", scenario_count);
    try assertToolFields(allocator, io, port, 146, "zig_release_evidence_pack", &.{ str("validation", "tests passed"), str("ci", "ci passed"), str("api", "api checked") }, expected, "phase6_release_evidence_pack_paths", scenario_count);

    try assertToolFields(allocator, io, port, 147, "zig_api_baseline_init", &.{ str("content", "pub fn alpha() void {}\n"), str("file", "src/lib.zig"), boolv("apply", false) }, expected, "phase6_api_baseline_init_paths", scenario_count);
    try assertToolFields(allocator, io, port, 148, "zig_api_check", &.{ str("content", "pub fn new() void {}\n"), str("file", "src/lib.zig"), str("baseline", api_baseline) }, expected, "phase6_api_check_paths", scenario_count);
    try assertToolFields(allocator, io, port, 149, "zig_api_diff_baseline", &.{ str("content", "pub fn new() void {}\n"), str("file", "src/lib.zig"), str("baseline", api_baseline) }, expected, "phase6_api_diff_baseline_paths", scenario_count);
    try assertToolFields(allocator, io, port, 150, "zig_api_docs_diff", &.{ str("content", "pub fn visible() void {}\n"), str("file", "src/lib.zig"), str("docs_content", "No public API docs here.") }, expected, "phase6_api_docs_diff_paths", scenario_count);

    try assertToolFields(allocator, io, port, 151, "zig_docs_index_build", &.{ str("scope", "docs"), intv("limit", 1) }, expected, "phase6_docs_index_build_paths", scenario_count);
    try assertToolFields(allocator, io, port, 152, "zig_docs_query", &.{ str("query", "zigar"), str("scope", "all"), intv("limit", 1) }, expected, "phase6_docs_query_paths", scenario_count);
    try assertToolFields(allocator, io, port, 153, "zig_std_signature", &.{ str("name", "std.mem.eql"), intv("limit", 1) }, expected, "phase6_std_signature_paths", scenario_count);
    try assertToolFields(allocator, io, port, 154, "zig_langref_item", &.{ str("query", "defer"), intv("limit", 1) }, expected, "phase6_langref_item_paths", scenario_count);
    try assertToolFields(allocator, io, port, 155, "zig_autodoc_ingest", &.{ str("content", autodoc_json), intv("limit", 5) }, expected, "phase6_autodoc_ingest_paths", scenario_count);
    try assertToolFields(allocator, io, port, 156, "zig_project_docs_query", &.{ str("query", "FixtureSymbol"), str("scope", "docs"), str("autodoc", "FixtureSymbol docs"), intv("limit", 5) }, expected, "phase6_project_docs_query_paths", scenario_count);
    try assertToolFields(allocator, io, port, 157, "zig_doc_example_check", &.{str("content", docs_example)}, expected, "phase6_doc_example_check_paths", scenario_count);
    try assertToolFields(allocator, io, port, 158, "zig_snippet_check", &.{str("content", "pub fn bad() void { const x = ; _ = x; }")}, expected, "phase6_snippet_check_paths", scenario_count);
    try assertToolFields(allocator, io, port, 159, "zig_readme_command_check", &.{str("content", readme_commands)}, expected, "phase6_readme_command_check_paths", scenario_count);

    try assertToolFields(allocator, io, port, 160, "zig_dependency_update_plan", &.{ str("manifest", dependency_manifest), str("dependency", "dep_a"), str("target_version", "1.0.0") }, expected, "phase6_dependency_update_plan_paths", scenario_count);
    try assertToolFields(allocator, io, port, 161, "zig_dependency_fetch_check", &.{str("manifest", dependency_manifest)}, expected, "phase6_dependency_fetch_check_paths", scenario_count);
    try assertToolFields(allocator, io, port, 162, "zig_dependency_lock_audit", &.{str("manifest", dependency_manifest)}, expected, "phase6_dependency_lock_audit_paths", scenario_count);
    try assertToolFields(allocator, io, port, 163, "zig_dependency_impact", &.{ str("dependency", "dep_a"), str("changed_files", "build.zig.zon") }, expected, "phase6_dependency_impact_paths", scenario_count);
    try assertToolFields(allocator, io, port, 164, "zig_sbom", &.{ str("manifest", dependency_manifest), boolv("apply", false) }, expected, "phase6_sbom_paths", scenario_count);
    try assertToolFields(allocator, io, port, 165, "zig_zat_scan", &.{}, expected, "phase6_zat_scan_paths", scenario_count);
    try assertToolFields(allocator, io, port, 166, "zig_osv_scan", &.{str("content", osv_report)}, expected, "phase6_osv_scan_paths", scenario_count);
    try assertToolFields(allocator, io, port, 167, "zig_dependency_security_report", &.{ str("manifest", dependency_manifest), str("osv", osv_report) }, expected, "phase6_dependency_security_report_paths", scenario_count);
    try assertToolFields(allocator, io, port, 168, "zig_dependency_provenance", &.{str("manifest", dependency_manifest)}, expected, "phase6_dependency_provenance_paths", scenario_count);
    try assertToolFields(allocator, io, port, 169, "zig_dependency_license_summary", &.{ str("manifest", dependency_manifest), str("license_text", "MIT License\n") }, expected, "phase6_dependency_license_summary_paths", scenario_count);
    try assertToolFields(allocator, io, port, 170, "zig_github_dependency_submit_plan", &.{ str("manifest", dependency_manifest), str("job", "fixture"), str("sha", "abc123") }, expected, "phase6_github_dependency_submit_plan_paths", scenario_count);
}

fn str(key: []const u8, value: []const u8) Field {
    return .{ .key = key, .value = .{ .string = value } };
}

fn boolv(key: []const u8, value: bool) Field {
    return .{ .key = key, .value = .{ .bool = value } };
}

fn intv(key: []const u8, value: i64) Field {
    return .{ .key = key, .value = .{ .integer = value } };
}

fn assertToolFields(allocator: std.mem.Allocator, io: Io, port: u16, id: i64, tool_name: []const u8, fields: []const Field, expected_root: JsonValue, expected_key: []const u8, scenario_count: *usize) !void {
    const args_json = try argsJson(allocator, fields);
    defer allocator.free(args_json);
    try assertToolPaths(allocator, io, port, id, tool_name, args_json, expected_root, expected_key, scenario_count);
}

fn argsJson(allocator: std.mem.Allocator, fields: []const Field) ![]u8 {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    for (fields) |field| {
        const value: JsonValue = switch (field.value) {
            .string => |value| .{ .string = value },
            .bool => |value| .{ .bool = value },
            .integer => |value| .{ .integer = value },
        };
        try obj.put(allocator, field.key, value);
    }
    return cli_io.jsonStringifyAlloc(allocator, .{ .object = obj }, .{ .whitespace = .minified });
}

fn assertToolPaths(
    allocator: std.mem.Allocator,
    io: Io,
    port: u16,
    id: i64,
    tool_name: []const u8,
    args_json: []const u8,
    expected_root: JsonValue,
    expected_key: []const u8,
    scenario_count: *usize,
) !void {
    const tool_json = try smoke.callHttpToolJson(allocator, io, port, id, tool_name, args_json);
    defer allocator.free(tool_json);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, tool_json, .{});
    defer parsed.deinit();
    var it = expected_root.object.get(expected_key).?.object.iterator();
    while (it.next()) |entry| {
        const actual = valueAt(parsed.value, entry.key_ptr.*) orelse return error.AssertionFailed;
        try smoke.expectJsonEq(io, actual, entry.value_ptr.*, entry.key_ptr.*);
    }
    scenario_count.* += 1;
}

test "http phase6 smoke exposes run entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
