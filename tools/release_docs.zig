const std = @import("std");
const zigar = @import("zigar");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn checkStaticAnalysisDocs(allocator: Allocator, io: Io) !bool {
    var ok = true;
    ok = (try checkDocNeedles(allocator, io, "docs/tools.md", &.{
        "capability_tier",
        "advisory_orientation",
        "parser_backed",
        "zwanzig_backed",
        "optional zwanzig-backed",
        "zig_dead_decl_candidates",
        "reference checks before deletion",
        "zig_public_api_diff",
        "comparison basis",
        "zig_test_select",
        "recommendations",
    })) and ok;
    ok = (try checkDocNeedles(allocator, io, "docs/tool-index.generated.md", &.{
        "## Static Analysis Capability Tiers",
        "zig_ast_decl_summary",
        "parser_backed",
        "zig_lint",
        "zwanzig_backed",
    })) and ok;
    return ok;
}

pub fn checkOptionalBackendContracts(allocator: Allocator, io: Io) !bool {
    const path = "docs/backends.md";
    const bytes = readFileAlloc(allocator, io, path, 1024 * 1024) catch |err| {
        try stderrPrint(io, "backend-contract check could not read {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    var ok = true;
    const required = [_][]const u8{
        "--dump-cfg",
        "--dump-exploded-graph",
        "--dump-annotated-cfg",
        "--dump-path-trace",
        "zflame recursive",
        "--title=<title>",
        "--colors=<palette>",
        "diff-folded --output=",
        "zig_profile_plan",
        "capture semantics",
        "artifact metadata",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, bytes, needle) == null) {
            try stderrPrint(io, "backend-contract check missing `{s}` in {s}\n", .{ needle, path });
            ok = false;
        }
    }
    const stale = [_][]const u8{
        "zflame guess",
        "--palette",
        "diff-folded before.folded after.folded >",
    };
    for (stale) |needle| {
        if (std.mem.indexOf(u8, bytes, needle) != null) {
            try stderrPrint(io, "backend-contract check found stale `{s}` in {s}\n", .{ needle, path });
            ok = false;
        }
    }
    return ok;
}

pub fn checkCommandRunningToolDocs(allocator: Allocator, io: Io) !bool {
    const path = "README.md";
    const bytes = readFileAlloc(allocator, io, path, 1024 * 1024) catch |err| {
        try stderrPrint(io, "command-running tool docs check could not read {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    var ok = std.mem.indexOf(u8, bytes, "without a shell") != null and
        std.mem.indexOf(u8, bytes, "MCP `readOnlyHint`") != null;
    for (zigar.tool_metadata.entries) |entry| {
        if (entry.risk.executes_user_command and std.mem.indexOf(u8, bytes, entry.name) == null) {
            try stderrPrint(io, "command-running tool docs check missing `{s}` in {s}\n", .{ entry.name, path });
            ok = false;
        }
    }
    return ok;
}

pub fn checkAgentWorkflowDocs(allocator: Allocator, io: Io) !bool {
    return checkDocNeedles(allocator, io, "docs/agent-workflows.md", &.{
        "workflow_contract",
        "omitted_sections",
        "skipped_phases",
        "heuristic text/import scan",
        "zigar_context_pack -> zigar_next_action",
    });
}

pub fn checkCiArtifactDocs(allocator: Allocator, io: Io) !bool {
    return checkDocNeedles(allocator, io, "docs/ci-artifacts.md", &.{
        "parser_confidence",
        "parsing_basis",
        "command_level_junit",
        "raw_output_available",
        "failure_summary",
        "GitHub Actions",
    });
}

pub fn checkMaturityDocs(allocator: Allocator, io: Io) !bool {
    return checkDocNeedles(allocator, io, "docs/maturity.md", &.{
        "Minimum public-release rating: A-",
        "No below-A- feature area remains",
        "ZLS/LSP tools",
        "Docs lookup",
        "Static analysis",
        "zwanzig optional backend",
        "Profiling/zflame",
        "Agent workflows",
        "CI artifact tools",
        "HTTP/MCP substrate",
        "command-level JUnit",
    });
}

pub fn checkTrustDocs(allocator: Allocator, io: Io) !bool {
    return checkDocNeedles(allocator, io, "docs/trust.md", &.{
        "tools/call`, `resources/read`, and",
        "prompts/get",
        "total wall-clock deadlines",
        "Public-release blocker tasks",
        "advisory_orientation",
        "release-check",
        "release-asset-smoke",
    });
}

fn checkDocNeedles(allocator: Allocator, io: Io, path: []const u8, needles: []const []const u8) !bool {
    const bytes = readFileAlloc(allocator, io, path, 8 * 1024 * 1024) catch |err| {
        try stderrPrint(io, "docs check could not read {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    var ok = true;
    for (needles) |needle| {
        if (std.mem.indexOf(u8, bytes, needle) == null) {
            try stderrPrint(io, "docs check missing `{s}` in {s}\n", .{ needle, path });
            ok = false;
        }
    }
    return ok;
}

fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, max_bytes: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}
