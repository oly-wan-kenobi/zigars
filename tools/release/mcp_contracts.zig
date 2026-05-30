//! Release gate: MCP adapter and public-surface contracts.
//! Three groups of checks are provided: no-patch (first-party adapter only),
//! advertised-capability (tasks, completions, pagination, resource subscriptions),
//! and public-surface (tool schemas, resource URIs, prompt names, report shapes).
const std = @import("std");
const zigars = @import("zigars");
const backend_contract_scenarios = @import("backend_contract_scenarios.zig");
const mcp_tool_contracts = @import("mcp_tool_contracts.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

// Token-presence checks used here are intentionally coarse: they cannot catch
// all regressions, but they do prevent silent removal of load-bearing adapter
// surface that would break published MCP clients.

/// Verifies that zigars uses its first-party MCP adapter without patch shims.
pub fn checkNoPatchContract(allocator: Allocator, io: Io) !bool {
    var ok = true;
    for ([_][]const u8{ "build.zig", "build.zig.zon" }) |path| {
        ok = (try checkAbsent(allocator, io, "MCP no-patch contract", path, &.{ "third_party/mcp_zigars_patch", "mcp_upstream", "addMcpModule" })) and ok;
    }
    ok = (try checkPresent(allocator, io, "MCP no-patch contract", "src/adapters/mcp/server.zig", &.{ "First-party MCP server adapter", "pinned upstream MCP dependency", "ToolResultDeinit", "ResourceContentDeinit", "PromptMessagesDeinit", "deinit_result", "addResourceWithDeinit", "addPromptWithDeinit" })) and ok;
    return ok;
}

/// Verifies protocol capabilities that are advertised to MCP clients.
pub fn checkAdvertisedCapabilityContract(allocator: Allocator, io: Io) !bool {
    var ok = true;
    ok = (try checkPresent(allocator, io, "MCP advertised-capability contract", "src/bootstrap/runtime.zig", &.{ "enableCompletions()", "enableResourceSubscriptions()", "enableTasks(&runtime.runtime_ux)" })) and ok;
    ok = (try checkPresent(allocator, io, "MCP advertised-capability contract", "src/adapters/mcp/server.zig", &.{ "capabilities.tasks", "completion/complete", "tasks/list", "resource_subscriptions.handleSubscribe", "pagination.fromParams" })) and ok;
    ok = (try checkPresent(allocator, io, "MCP tasks extension contract", "src/adapters/mcp/server/tasks.zig", &.{ "handleGet", "handleResult", "handleList", "handleCancel", "taskValue" })) and ok;
    ok = (try checkPresent(allocator, io, "MCP completion extension contract", "src/adapters/mcp/server/completion.zig", &.{ "completion", "ref/prompt", "ref/resource", "appendManifestArgumentCompletions", "completion_source" })) and ok;
    ok = (try checkPresent(allocator, io, "MCP pagination extension contract", "src/adapters/mcp/server/pagination.zig", &.{ "fromParams", "shouldIncludeIndex", "maybePutNextCursor" })) and ok;
    return ok;
}

/// Verifies MCP tool/resource/prompt surface contracts exposed by releases.
pub fn checkPublicSurfaceContract(allocator: Allocator, io: Io) !bool {
    var ok = true;
    inline for (zigars.manifest.entries) |entry| {
        ok = (try mcp_tool_contracts.checkToolContract(allocator, io, entry)) and ok;
    }
    ok = (try checkPresent(allocator, io, "MCP tool discovery contract", "src/adapters/mcp/registration.zig", &.{ "inline for (manifest.specs)", "registry.addTool", "handlers.handlerFor" })) and ok;
    ok = (try checkPresent(allocator, io, "MCP tool discovery contract", "src/adapters/mcp/registration.zig", &.{ "pub fn registerTools", "registry.addTool", "handlers.handlerFor" })) and ok;
    ok = (try checkPresent(allocator, io, "MCP resource/prompt contract fixture", "tests/fixtures/mcp-contracts.expect.json", &.{ "\"resources\"", "\"resource_templates\"", "\"prompts\"", "\"report_kinds\"" })) and ok;
    ok = (try checkPresent(allocator, io, "MCP resource contract", "src/adapters/mcp/resources.zig", &.{ "zigars://trust/manifest", "zigars://workspace", "zigars://zls/status", "zigars://tools/capabilities", "zigars://tools/schema", "zigars://workspace/import-graph", "zigars://metrics", "zigars://jobs", "zigars://run/events", "zigars://workspace/roots", "zigars://artifacts/{sha}", "zigars://file/{path}/symbols", "zigars://file/{path}/diagnostics", "zigars://file/{path}/imports" })) and ok;
    ok = (try checkPresent(allocator, io, "MCP prompt contract", "src/adapters/mcp/prompts.zig", &.{ "zigars_profile_workflow", "zigars_compile_error_workflow", "zigars_release_workflow" })) and ok;
    ok = (try checkPresent(allocator, io, "MCP resource/prompt routing contract", "src/adapters/mcp/server.zig", &.{ "resources/list", "resources/read", "resources/templates/list", "resources/subscribe", "Resource not found", "prompts/list", "prompts/get", "completion/complete", "tasks/list", "Prompt not found", "createInvalidParams", "deinit_content", "deinit_messages" })) and ok;
    ok = (try checkPresent(allocator, io, "backend conformance report contract", ".github/scripts/backend-conformance.sh", &.{ "\"kind\": \"zigars_backend_conformance_report\"", "\"schema_version\": 2", "\"source_commit\"", "\"claimed_backends\"", "\"compatibility_matrix\"", "\"tool_evidence\"", "\"artifacts\"", "profile.svg", "diff.svg", "validate_svg_artifact", "ET.parse(path).getroot()" })) and ok;
    ok = (try backend_contract_scenarios.check(allocator, io)) and ok;
    ok = (try checkPresent(allocator, io, "release-readiness report contract", ".github/scripts/release-readiness.sh", &.{ "\"kind\": \"zigars_release_readiness_report\"", "\"schema_version\": 2", "\"source_tree_clean\"", "\"backend_conformance\"", "\"zls_conformance\"", "\"subreport_commits\"", "\"compatibility_matrix\"" })) and ok;
    ok = (try checkPresent(allocator, io, "real-ZLS report contract", ".github/scripts/real-zls-conformance.sh", &.{ "\"kind\": \"zigars_real_zls_conformance_report\"", "\"schema_version\": 2", "\"source_commit\"", "\"backends\"", "\"scenarios\"", "\"response_count\"" })) and ok;
    return ok;
}

/// Returns `true` iff every token in `tokens` is a substring of the file at
/// `path`.  Missing tokens and file-read errors are reported to stderr with
/// `label` as context; `false` is returned rather than propagating an error
/// so the caller can accumulate multiple failures.
fn checkPresent(allocator: Allocator, io: Io, label: []const u8, path: []const u8, tokens: []const []const u8) !bool {
    const bytes = readFileAlloc(allocator, io, path, 4 * 1024 * 1024) catch |err| {
        try stderrPrint(io, "{s} could not read {s}: {s}\n", .{ label, path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    var ok = true;
    for (tokens) |token| {
        if (std.mem.indexOf(u8, bytes, token) == null) {
            try stderrPrint(io, "{s} missing `{s}` in {s}\n", .{ label, token, path });
            ok = false;
        }
    }
    return ok;
}

/// Returns `true` iff none of `tokens` appear in the file at `path`.
/// Forbidden tokens and file-read errors are reported to stderr with `label`.
fn checkAbsent(allocator: Allocator, io: Io, label: []const u8, path: []const u8, tokens: []const []const u8) !bool {
    const bytes = readFileAlloc(allocator, io, path, 4 * 1024 * 1024) catch |err| {
        try stderrPrint(io, "{s} could not read {s}: {s}\n", .{ label, path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    var ok = true;
    for (tokens) |token| {
        if (std.mem.indexOf(u8, bytes, token) != null) {
            try stderrPrint(io, "{s} found forbidden `{s}` in {s}\n", .{ label, token, path });
            ok = false;
        }
    }
    return ok;
}

fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, limit: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "MCP contract checker exposes public surface checks" {
    try std.testing.expect(@hasDecl(@This(), "checkPublicSurfaceContract"));
}
