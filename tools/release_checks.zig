const std = @import("std");
const zigar = @import("zigar");
const release_docs = @import("release_docs.zig");
const task_status = @import("task_status.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn artifactHygiene(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 0) return error.InvalidArguments;
    const generated = [_][]const u8{ "zig-out", ".zig-cache", "zig-pkg", ".zigar-cache", "coverage", "dist" };
    var ok = true;
    for (generated) |path| {
        const tracked = isGitTracked(io, path) catch |err| blk: {
            try stderrPrint(io, "generated artifact check could not query git tracking for {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            break :blk false;
        };
        if (tracked) {
            try stderrPrint(io, "generated artifact path is tracked: {s}\n", .{path});
            ok = false;
        }
        const exists = pathExists(io, path) catch |err| blk: {
            try stderrPrint(io, "generated artifact check could not inspect {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            break :blk false;
        };
        const ignored = isGitIgnored(io, path) catch |err| blk: {
            try stderrPrint(io, "generated artifact check could not query git ignore status for {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            break :blk false;
        };
        if (exists and !ignored) {
            try stderrPrint(io, "generated artifact path exists but is not ignored: {s}\n", .{path});
            ok = false;
        }
    }
    ok = (try checkLineBudgets(allocator, io)) and ok;
    ok = (try checkForbiddenTokens(allocator, io)) and ok;
    ok = (try checkToolErrorContract(allocator, io)) and ok;
    ok = (try checkResourceErrorContract(allocator, io)) and ok;
    ok = (try checkCliErrorContract(allocator, io)) and ok;
    ok = (try checkPureZigTrees(allocator, io)) and ok;
    ok = (try checkStaticAnalysisContracts(io)) and ok;
    ok = (try checkWorkflowPermissions(allocator, io)) and ok;
    ok = (try release_docs.checkStaticAnalysisDocs(allocator, io)) and ok;
    ok = (try release_docs.checkOptionalBackendContracts(allocator, io)) and ok;
    ok = (try release_docs.checkCommandRunningToolDocs(allocator, io)) and ok;
    ok = (try release_docs.checkAgentWorkflowDocs(allocator, io)) and ok;
    ok = (try release_docs.checkCiArtifactDocs(allocator, io)) and ok;
    ok = (try release_docs.checkMaturityDocs(allocator, io)) and ok;
    ok = (try release_docs.checkTrustDocs(allocator, io)) and ok;
    ok = (try checkSecurityPolicy(allocator, io)) and ok;
    ok = (try checkMcpNoPatchContract(allocator, io)) and ok;
    ok = (try checkMcpAdvertisedCapabilityContract(allocator, io)) and ok;
    ok = (try task_status.checkPublicReleaseBlockers(allocator, io)) and ok;
    ok = (try task_status.checkReadyTaskScope(allocator, io)) and ok;
    ok = (try checkCodeHygiene(allocator, io)) and ok;
    if (!ok) return error.ArtifactHygieneFailed;
}

pub fn fakeZwanzig(io: Io, args: []const []const u8) !void {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        try stdoutWrite(io, "fake zwanzig help\n--format json|sarif\n--dump-cfg <dir> <file>\n--dump-exploded-graph <dir> <file>\n--dump-annotated-cfg <dir> <file>\n--dump-path-trace <dir> <file>\n");
        return;
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "--dot")) return fakeBackendUsageError(io, "fake zwanzig rejected stale --dot graph flag\n");
    if (args.len > 0 and zwanzigGraphModeName(args[0]) != null) {
        if (args.len < 3) return fakeBackendUsageError(io, "fake zwanzig graph requires <flag> <output-dir> <source>\n");
        try writeFakeDot(io, args[1], zwanzigGraphModeName(args[0]).?);
        return;
    }

    if (args.len < 3 or !std.mem.eql(u8, args[0], "--format")) {
        return fakeBackendUsageError(io, "fake zwanzig lint requires --format <json|sarif> <path>\n");
    }
    const format = args[1];
    if (!std.mem.eql(u8, format, "json") and !std.mem.eql(u8, format, "sarif")) {
        return fakeBackendUsageError(io, "fake zwanzig rejected unsupported --format value\n");
    }
    var i: usize = 2;
    var saw_path = false;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "--do") or std.mem.eql(u8, arg, "--skip")) {
            if (i + 1 >= args.len) return fakeBackendUsageError(io, "fake zwanzig option requires a value\n");
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--dump-") or std.mem.eql(u8, arg, "--dot")) {
            return fakeBackendUsageError(io, "fake zwanzig graph flags must use zig_analysis_graphs typed mode\n");
        }
        saw_path = true;
        break;
    }
    if (!saw_path) return fakeBackendUsageError(io, "fake zwanzig lint requires a workspace path\n");
    if (std.mem.eql(u8, format, "sarif")) {
        try stdoutWrite(io, "{\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"fake-zwanzig\"}}}]}\n");
    } else {
        try stdoutWrite(io, "{\"diagnostics\":[]}\n");
    }
}

pub fn fakeZflame(io: Io, args: []const []const u8) !void {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        try stdoutWrite(io, "fake zflame help\nusage: zflame <format> [--title=<text>] [--colors=<palette>] <input>\n");
        return;
    }
    if (args.len < 2) return fakeBackendUsageError(io, "fake zflame requires <format> <input>\n");
    if (zigar.backend_contracts.parseZflameFormat(args[0]) == null) {
        return fakeBackendUsageError(io, "fake zflame rejected unsupported format\n");
    }
    var input_count: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--hash")) continue;
        if (std.mem.startsWith(u8, arg, "--title=") or
            std.mem.startsWith(u8, arg, "--subtitle=") or
            std.mem.startsWith(u8, arg, "--colors=") or
            std.mem.startsWith(u8, arg, "--width=") or
            std.mem.startsWith(u8, arg, "--min-width="))
        {
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return fakeBackendUsageError(io, "fake zflame rejected stale or unsupported option syntax\n");
        }
        input_count += 1;
        if (i + 1 != args.len) return fakeBackendUsageError(io, "fake zflame input must be the final argument\n");
    }
    if (input_count != 1) return fakeBackendUsageError(io, "fake zflame requires exactly one input\n");
    try stdoutWrite(io, "<svg xmlns=\"http://www.w3.org/2000/svg\"><title>fake flamegraph</title></svg>\n");
}

pub fn fakeDiffFolded(io: Io, args: []const []const u8) !void {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        try stdoutWrite(io, "fake diff-folded help\nusage: diff-folded --output=<path> before.folded after.folded\n");
        return;
    }
    if (args.len != 3 or !std.mem.startsWith(u8, args[0], "--output=")) {
        return fakeBackendUsageError(io, "fake diff-folded requires --output=<path> before after\n");
    }
    const output = args[0]["--output=".len..];
    if (output.len == 0) return fakeBackendUsageError(io, "fake diff-folded output must be non-empty\n");
    if (std.fs.path.dirname(output)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = "main;delta 2\n" });
    try stdoutWrite(io, "wrote folded diff\n");
}

fn zwanzigGraphModeName(flag: []const u8) ?[]const u8 {
    inline for (std.meta.tags(zigar.backend_contracts.ZwanzigGraphMode)) |mode| {
        if (std.mem.eql(u8, flag, mode.flag())) return mode.name();
    }
    return null;
}

fn writeFakeDot(io: Io, output_dir: []const u8, mode: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, output_dir);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/fake-{s}.dot", .{ output_dir, mode });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "digraph fake { start -> end }\n" });
    try stdoutWrite(io, "wrote fake graph\n");
}

fn fakeBackendUsageError(io: Io, message: []const u8) !void {
    try Io.File.stderr().writeStreamingAll(io, message);
    return error.InvalidArguments;
}

fn isGitTracked(io: Io, path: []const u8) !bool {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "git", "ls-files", "--error-unmatch", path },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn isGitIgnored(io: Io, path: []const u8) !bool {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "git", "check-ignore", "-q", "--", path },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn pathExists(io: Io, path: []const u8) !bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    dir.close(io);
    return true;
}

const LineBudget = struct {
    path: []const u8,
    max_lines: usize,
    reason: []const u8,
};

const ForbiddenToken = struct {
    path: []const u8,
    token: []const u8,
    reason: []const u8,
};

const HygieneToken = struct {
    path: []const u8,
    token: []const u8,
    reason: []const u8,
};

const ToolErrorContractToken = struct {
    token: []const u8,
    reason: []const u8,
};

const line_budgets = [_]LineBudget{
    .{
        .path = "src/main.zig",
        .max_lines = 150,
        .reason = "main must stay a small startup/lifecycle entrypoint",
    },
    .{
        .path = "src/server.zig",
        .max_lines = 450,
        .reason = "MCP server wiring must stay a dispatcher; tool behavior belongs in src/tools modules",
    },
    .{
        .path = "src/mcp_server.zig",
        .max_lines = 1300,
        .reason = "first-party MCP adapter owns routing and tool/resource/prompt result lifetime but must not grow into a general MCP framework",
    },
    .{
        .path = "src/backend_catalog.zig",
        .max_lines = 120,
        .reason = "backend setup catalog rendering should remain separate from packaged backend definitions",
    },
    .{
        .path = "src/backend_catalog/definitions.zig",
        .max_lines = 140,
        .reason = "backend setup metadata should remain compact and auditable",
    },
    .{
        .path = "src/tools/common.zig",
        .max_lines = 160,
        .reason = "shared tool helpers must stay a small facade over focused helper modules",
    },
    .{
        .path = "src/tools/ci.zig",
        .max_lines = 430,
        .reason = "CI artifact handlers should keep parsing, XML, and matrix shaping reviewable",
    },
    .{
        .path = "src/tools/agent.zig",
        .max_lines = 340,
        .reason = "agent workflow handlers should remain focused and delegate value-building helpers",
    },
    .{
        .path = "src/tools/agent_values.zig",
        .max_lines = 540,
        .reason = "agent workflow value builders should remain separate from public tool handlers",
    },
    .{
        .path = "src/tools/edit_zls.zig",
        .max_lines = 620,
        .reason = "edit and ZLS mutation/navigation handlers must keep diagnostics in the dedicated module",
    },
    .{
        .path = "src/tools/edit_zls_diagnostics.zig",
        .max_lines = 300,
        .reason = "ZLS diagnostics handlers and cache shaping should stay independently reviewable",
    },
    .{
        .path = "src/tools/edit_zls_edits.zig",
        .max_lines = 240,
        .reason = "ZLS text/workspace edit application should remain independently reviewable",
    },
    .{
        .path = "src/tools/shared_core.zig",
        .max_lines = 500,
        .reason = "shared command/compiler/path helpers must stay a facade over focused helper modules",
    },
    .{
        .path = "src/tools/command_result.zig",
        .max_lines = 380,
        .reason = "command result and compiler diagnostic shaping should stay focused and testable",
    },
    .{
        .path = "src/tools/tool_result_errors.zig",
        .max_lines = 160,
        .reason = "structured tool-result error helpers should stay focused on command failure mapping",
    },
    .{
        .path = "src/tools/static_core.zig",
        .max_lines = 520,
        .reason = "static-analysis tool handlers should delegate scanner implementation details",
    },
    .{
        .path = "src/tools/static_build.zig",
        .max_lines = 450,
        .reason = "build graph scanning should stay independently reviewable",
    },
    .{
        .path = "src/tools/static_dependencies.zig",
        .max_lines = 180,
        .reason = "dependency inspection should stay independently reviewable",
    },
    .{
        .path = "src/tools/static_tests.zig",
        .max_lines = 700,
        .reason = "test/cache/public-API analysis helpers should stay below a reviewable module size",
    },
    .{
        .path = "src/tools/profiling.zig",
        .max_lines = 820,
        .reason = "profiling workflow handlers should stay separate from backend-heavy unit fixtures",
    },
    .{
        .path = "src/tools/profiling_tests.zig",
        .max_lines = 430,
        .reason = "profiling backend contract fixtures should stay reviewable and move shared helpers if they grow further",
    },
    .{
        .path = "src/docs.zig",
        .max_lines = 840,
        .reason = "documentation lookup indexes should remain reviewable and split if another source family is added",
    },
    .{
        .path = "src/analysis.zig",
        .max_lines = 700,
        .reason = "heuristic source scanners should stay bounded; semantic analysis belongs in stronger backends",
    },
    .{
        .path = "src/state/documents.zig",
        .max_lines = 860,
        .reason = "document state is concurrency-sensitive and must keep line-count pressure visible",
    },
    .{
        .path = "src/tools/zls_common.zig",
        .max_lines = 600,
        .reason = "shared ZLS/LSP helpers should keep capability contract tests in focused test modules",
    },
    .{
        .path = "src/tools/zls_common_tests.zig",
        .max_lines = 380,
        .reason = "ZLS common helper tests should remain focused on capability, command, and LSP shaping contracts",
    },
    .{
        .path = "src/lsp/client.zig",
        .max_lines = 520,
        .reason = "LSP client must stay focused on transport lifecycle; caches, tests, and parsing helpers belong in focused modules",
    },
    .{
        .path = "src/lsp/client_test_support.zig",
        .max_lines = 100,
        .reason = "LSP test support should stay compact and separate from client runtime logic",
    },
    .{
        .path = "src/lsp/client_tests.zig",
        .max_lines = 260,
        .reason = "black-box LSP client tests should stay separate from runtime transport logic",
    },
    .{
        .path = "src/lsp/diagnostics_cache.zig",
        .max_lines = 340,
        .reason = "diagnostics retention policy should stay small enough to audit independently",
    },
    .{
        .path = "src/tool_manifest.zig",
        .max_lines = 320,
        .reason = "tool manifest facade must stay focused on derived tables and public lookup helpers",
    },
    .{
        .path = "src/tool_manifest/types.zig",
        .max_lines = 150,
        .reason = "manifest type definitions should remain a compact schema vocabulary",
    },
    .{
        .path = "src/tool_manifest/definitions.zig",
        .max_lines = 850,
        .reason = "the generated-style tool definition list should remain reviewable and avoid helper logic",
    },
    .{
        .path = "src/tool_manifest/groups.zig",
        .max_lines = 80,
        .reason = "tool group keyword metadata should remain a compact manifest adjunct",
    },
    .{
        .path = "tools/zigar_tools.zig",
        .max_lines = 220,
        .reason = "tool dispatcher must remain a small command router over focused helpers",
    },
    .{
        .path = "tools/cli_io.zig",
        .max_lines = 120,
        .reason = "tooling CLI IO and argument diagnostics should remain a compact shared utility",
    },
    .{
        .path = "tools/dist.zig",
        .max_lines = 550,
        .reason = "release packaging should stay a focused helper, not a second build system",
    },
    .{
        .path = "tools/http_smoke.zig",
        .max_lines = 260,
        .reason = "HTTP smoke tests should stay focused on transport-level release assertions",
    },
    .{
        .path = "tools/stdio_fixtures.zig",
        .max_lines = 450,
        .reason = "stdio smoke fixtures should stay focused on end-to-end protocol assertions",
    },
    .{
        .path = "tools/smoke_support.zig",
        .max_lines = 180,
        .reason = "shared smoke-test utilities should remain a small helper module",
    },
    .{
        .path = "tools/release_targets.zig",
        .max_lines = 120,
        .reason = "release target metadata should remain a compact shared table",
    },
    .{
        .path = "tools/release_docs.zig",
        .max_lines = 190,
        .reason = "release documentation checks should stay separate from the release-check dispatcher",
    },
    .{
        .path = "tools/task_status.zig",
        .max_lines = 140,
        .reason = "task frontmatter release-blocker checks should stay separate from the main release-check dispatcher",
    },
    .{
        .path = "tools/release_checks.zig",
        .max_lines = 1150,
        .reason = "release checks are critical trust infrastructure and should split before becoming hard to audit",
    },
};

const forbidden_tokens = [_]ForbiddenToken{
    .{
        .path = "src/main.zig",
        .token = "active_app",
        .reason = "MCP handlers must receive runtime through user_data, not globals",
    },
    .{
        .path = "src/main.zig",
        .token = "fn app(",
        .reason = "MCP handlers must receive runtime through user_data, not globals",
    },
    .{
        .path = "src/main.zig",
        .token = "std.debug.print",
        .reason = "runtime logs and CLI messages must use the project logging/stderr helpers",
    },
    .{
        .path = "src/server.zig",
        .token = "active_app",
        .reason = "server handlers must not reintroduce global runtime state",
    },
    .{
        .path = "src/lsp/client.zig",
        .token = "std.debug.print",
        .reason = "LSP lifecycle logs must go through the project logger",
    },
    .{
        .path = "src/state/documents.zig",
        .token = "std.debug.print",
        .reason = "document-session logs must go through the project logger",
    },
};

const code_hygiene_tokens = [_]HygieneToken{
    .{
        .path = "src/zls/session.zig",
        .token = "const std = @import(\"std\");",
        .reason = "known stale import from task 018",
    },
    .{
        .path = "src/tools/static_core.zig",
        .token = "const docs = zigar.docs;",
        .reason = "known stale alias from task 018",
    },
    .{
        .path = "src/tools/static_tests.zig",
        .token = "const countTopLevelEntries = static_core.countTopLevelEntries;",
        .reason = "known stale alias from task 018",
    },
    .{
        .path = "src/tools/agent_values.zig",
        .token = "const testMapValue = static_analysis.testMapValue;",
        .reason = "known stale alias from task 018",
    },
    .{
        .path = "src/tools/edit_zls.zig",
        .token = "const LspClient = common.LspClient;",
        .reason = "known stale alias from task 018",
    },
};

const ignored_error_hygiene_tokens = [_]HygieneToken{
    .{
        .path = "src/lsp/client.zig",
        .token = "catch {};",
        .reason = "LSP client errors must be propagated or recorded with logger/last_error",
    },
    .{
        .path = "src/lsp/client.zig",
        .token = "catch return;",
        .reason = "LSP client best-effort shutdown/read paths must record why they are ignored",
    },
    .{
        .path = "src/lsp/transport.zig",
        .token = "catch continue",
        .reason = "LSP transport parse/read errors must be explicit protocol failures",
    },
    .{
        .path = "src/lsp/transport.zig",
        .token = "catch return",
        .reason = "LSP transport test helpers must only swallow EOF-like read errors explicitly",
    },
    .{
        .path = "src/tools/edit_zls.zig",
        .token = "catch {};",
        .reason = "ZLS edit cleanup/close errors must be logged or surfaced",
    },
    .{
        .path = "src/tools/edit_zls_diagnostics.zig",
        .token = "catch null",
        .reason = "ZLS diagnostics fallbacks must log the backend/cache failure before falling back",
    },
    .{
        .path = "src/tools/edit_zls_diagnostics.zig",
        .token = "catch continue",
        .reason = "ZLS diagnostics workspace must count or report malformed cached notifications",
    },
    .{
        .path = "src/tools/edit_zls_edits.zig",
        .token = "catch {};",
        .reason = "ZLS edit close failures after apply must be logged",
    },
    .{
        .path = "tools/stdio_fixtures.zig",
        .token = "deleteTree(io, rel) catch {};",
        .reason = "fixture cleanup failures must be reported without masking test status",
    },
    .{
        .path = "tools/http_smoke.zig",
        .token = "sleep(.{ .duration = .{ .raw = Io.Duration.fromMilliseconds(100), .clock = .awake } }, io) catch {};",
        .reason = "HTTP smoke retry sleep failures must be visible",
    },
    .{
        .path = "tools/release_checks.zig",
        .token = "writeStreamingAll(io, message) catch " ++ "{};",
        .reason = "release-check fake backend diagnostics must not be silently dropped",
    },
    .{
        .path = "tools/release_checks.zig",
        .token = "catch return " ++ "false",
        .reason = "release-check git/filesystem probes must report unexpected failures",
    },
    .{
        .path = "tools/cli_io.zig",
        .token = "catch {};",
        .reason = "CLI usage diagnostics must either be printed or return the print failure",
    },
};

const tool_error_contract_paths = [_][]const u8{
    "src/tool_registry.zig",
    "src/tools/common.zig",
    "src/tools/agent.zig",
    "src/tools/ci.zig",
    "src/tools/core.zig",
    "src/tools/discovery.zig",
    "src/tools/docs.zig",
    "src/tools/edit_zls.zig",
    "src/tools/edit_zls_diagnostics.zig",
    "src/tools/profiling.zig",
    "src/tools/static_core.zig",
    "src/tools/static_tests.zig",
    "src/tools/shared_core.zig",
    "src/tools/tool_result_errors.zig",
    "src/tools/zls_common.zig",
    "src/tools/zwanzig.zig",
};

const tool_error_contract_tokens = [_]ToolErrorContractToken{
    .{
        .token = "mcp.tools.errorResult",
        .reason = "tool handlers must use structured tool_errors/json_result helpers instead of raw text MCP errors",
    },
    .{
        .token = "errorText",
        .reason = "raw text error helpers must not bypass the structured tool error contract",
    },
    .{
        .token = "return error.InvalidArguments",
        .reason = "tool handlers must return structured argument_error payloads for expected user-facing argument failures",
    },
    .{
        .token = "catch return error.InvalidArguments",
        .reason = "tool handlers must preserve argument parse context instead of collapsing catches",
    },
    .{
        .token = "return error.ExecutionFailed",
        .reason = "tool handlers must explain operation, phase, cause, and resolution instead of collapsing expected failures",
    },
    .{
        .token = "catch return error.ExecutionFailed",
        .reason = "tool handlers must preserve the underlying error in a structured tool_error",
    },
    .{
        .token = "return error.ResourceNotFound",
        .reason = "tool handlers must include the tool, phase, resource, and not_found classification for misses",
    },
    .{
        .token = "catch return error.ResourceNotFound",
        .reason = "tool handlers must preserve not_found context instead of collapsing catches",
    },
    .{
        .token = "try splitToolArgs(",
        .reason = "extra-argument parsing must map InvalidArguments to structured argument_error results at the handler boundary",
    },
};

const resource_error_contract_paths = [_][]const u8{
    "src/server.zig",
    "src/tools/resources.zig",
};

const resource_error_contract_tokens = [_]ToolErrorContractToken{
    .{
        .token = "return error.Unknown",
        .reason = "public resource/prompt handlers must preserve actionable context instead of generic Unknown",
    },
    .{
        .token = "catch return error.Unknown",
        .reason = "public resource/prompt handlers must map expected failures to structured resource_error payloads",
    },
    .{
        .token = "return error.ReadFailed",
        .reason = "public resources must return structured resource_error payloads for expected read failures",
    },
    .{
        .token = "catch return error.ReadFailed",
        .reason = "public resources must preserve read failure context instead of collapsing catches",
    },
};

const cli_error_contract_paths = [_][]const u8{
    "tools/zigar_tools.zig",
};

const cli_error_contract_tokens = [_]ToolErrorContractToken{
    .{
        .token = "std.debug.print",
        .reason = "developer helper diagnostics must use CLI stderr helpers so output stays consistent and testable",
    },
    .{
        .token = "return error.InvalidArguments",
        .reason = "developer helper commands must print an actionable argument diagnostic before returning InvalidArguments",
    },
    .{
        .token = "catch return error.InvalidArguments",
        .reason = "developer helper commands must preserve argument context instead of collapsing catches",
    },
};

const WorkflowPermissionRule = struct {
    path: []const u8,
    required: []const []const u8,
};

const workflow_permission_rules = [_]WorkflowPermissionRule{
    .{
        .path = ".github/workflows/ci.yml",
        .required = &.{
            "permissions:",
            "contents: read",
        },
    },
    .{
        .path = ".github/workflows/backend-conformance.yml",
        .required = &.{
            "permissions:",
            "contents: read",
        },
    },
    .{
        .path = ".github/workflows/release.yml",
        .required = &.{
            "permissions:",
            "contents: write",
            "id-token: write",
            "attestations: write",
        },
    },
};

const pure_zig_roots = [_][]const u8{
    ".github",
    "docs",
    "examples",
    "scripts",
    "src",
    "tests",
    "tools",
};

fn checkWorkflowPermissions(allocator: Allocator, io: Io) !bool {
    var ok = true;
    for (workflow_permission_rules) |rule| {
        const bytes = readFileAlloc(allocator, io, rule.path, 1024 * 1024) catch |err| {
            try stderrPrint(io, "workflow-permissions check could not read {s}: {s}\n", .{ rule.path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        for (rule.required) |needle| {
            if (std.mem.indexOf(u8, bytes, needle) == null) {
                try stderrPrint(io, "workflow-permissions check missing `{s}` in {s}\n", .{ needle, rule.path });
                ok = false;
            }
        }
    }
    return ok;
}

fn checkLineBudgets(allocator: Allocator, io: Io) !bool {
    var ok = true;
    for (line_budgets) |budget| {
        const bytes = readFileAlloc(allocator, io, budget.path, 4 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "line-budget check could not read {s}: {s}\n", .{ budget.path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        const lines = lineCount(bytes);
        if (lines > budget.max_lines) {
            try stderrPrint(io, "line budget exceeded: {s} has {d} lines, max {d} ({s})\n", .{ budget.path, lines, budget.max_lines, budget.reason });
            ok = false;
            continue;
        }
        const headroom = budget.max_lines - lines;
        const required_headroom = minLineBudgetHeadroom(budget.max_lines);
        if (headroom < required_headroom) {
            try stderrPrint(io, "line budget headroom too small: {s} has {d} lines, max {d}, headroom {d}, required {d} ({s})\n", .{ budget.path, lines, budget.max_lines, headroom, required_headroom, budget.reason });
            ok = false;
        }
    }
    return ok;
}

fn minLineBudgetHeadroom(max_lines: usize) usize {
    return @min(@as(usize, 50), @max(@as(usize, 10), max_lines / 10));
}

fn checkForbiddenTokens(allocator: Allocator, io: Io) !bool {
    var ok = true;
    for (forbidden_tokens) |rule| {
        const bytes = readFileAlloc(allocator, io, rule.path, 8 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "forbidden-token check could not read {s}: {s}\n", .{ rule.path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, rule.token) != null) {
            try stderrPrint(io, "forbidden token in {s}: `{s}` ({s})\n", .{ rule.path, rule.token, rule.reason });
            ok = false;
        }
    }
    return ok;
}

fn checkCodeHygiene(allocator: Allocator, io: Io) !bool {
    var ok = true;
    ok = (try checkHygieneTokensAbsent(allocator, io, "stale-code", &code_hygiene_tokens)) and ok;
    ok = (try checkHygieneTokensAbsent(allocator, io, "ignored-error", &ignored_error_hygiene_tokens)) and ok;
    return ok;
}

fn checkHygieneTokensAbsent(allocator: Allocator, io: Io, check_name: []const u8, rules: []const HygieneToken) !bool {
    var ok = true;
    for (rules) |rule| {
        const bytes = readFileAlloc(allocator, io, rule.path, 8 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "{s} hygiene check could not read {s}: {s}\n", .{ check_name, rule.path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, rule.token) != null) {
            try stderrPrint(io, "{s} hygiene violation in {s}: `{s}` ({s})\n", .{ check_name, rule.path, rule.token, rule.reason });
            ok = false;
        }
    }
    return ok;
}

fn checkToolErrorContract(allocator: Allocator, io: Io) !bool {
    var ok = true;
    for (tool_error_contract_paths) |path| {
        const bytes = readFileAlloc(allocator, io, path, 8 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "tool-error-contract check could not read {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        for (tool_error_contract_tokens) |rule| {
            if (std.mem.indexOf(u8, bytes, rule.token) != null) {
                try stderrPrint(io, "tool-error-contract violation in {s}: `{s}` ({s})\n", .{ path, rule.token, rule.reason });
                ok = false;
            }
        }
    }
    return ok;
}

fn checkResourceErrorContract(allocator: Allocator, io: Io) !bool {
    var ok = true;
    for (resource_error_contract_paths) |path| {
        const bytes = readFileAlloc(allocator, io, path, 8 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "resource-error-contract check could not read {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        for (resource_error_contract_tokens) |rule| {
            if (std.mem.indexOf(u8, bytes, rule.token) != null) {
                try stderrPrint(io, "resource-error-contract violation in {s}: `{s}` ({s})\n", .{ path, rule.token, rule.reason });
                ok = false;
            }
        }
    }
    return ok;
}

fn checkCliErrorContract(allocator: Allocator, io: Io) !bool {
    var ok = true;
    for (cli_error_contract_paths) |path| {
        const bytes = readFileAlloc(allocator, io, path, 8 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "cli-error-contract check could not read {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        for (cli_error_contract_tokens) |rule| {
            if (std.mem.indexOf(u8, bytes, rule.token) != null) {
                try stderrPrint(io, "cli-error-contract violation in {s}: `{s}` ({s})\n", .{ path, rule.token, rule.reason });
                ok = false;
            }
        }
    }
    return ok;
}

fn checkPureZigTrees(allocator: Allocator, io: Io) !bool {
    var ok = true;
    for (pure_zig_roots) |root| {
        ok = (try checkNoExtensionInTree(allocator, io, root, ".py")) and ok;
    }
    return ok;
}

fn checkStaticAnalysisContracts(io: Io) !bool {
    var ok = true;
    for (zigar.tool_metadata.entries) |entry| {
        if (entry.group != .static_analysis and entry.group != .zwanzig) continue;
        const tier = entry.static_analysis_tier orelse {
            try stderrPrint(io, "static-analysis capability tier missing for tool: {s}\n", .{entry.name});
            ok = false;
            continue;
        };
        const contract = zigar.analysis_contract.forTool(entry.name) orelse {
            try stderrPrint(io, "static-analysis contract missing for tool: {s}\n", .{entry.name});
            ok = false;
            continue;
        };
        if (tier != contract.tier) {
            try stderrPrint(io, "static-analysis manifest tier disagrees with contract for tool: {s}\n", .{entry.name});
            ok = false;
        }
        if (contract.analysis_kind.len == 0 or contract.source_coverage.len == 0 or contract.limitations.len == 0 or contract.verify_with.len == 0) {
            try stderrPrint(io, "static-analysis contract incomplete for tool: {s}\n", .{entry.name});
            ok = false;
        }
        if (entry.group == .zwanzig and tier != .zwanzig_backed) {
            try stderrPrint(io, "zwanzig tool must use zwanzig_backed capability tier: {s}\n", .{entry.name});
            ok = false;
        }
        if (entry.group == .static_analysis and (!entry.meta.read_only or entry.risk.writes_source)) {
            try stderrPrint(io, "static-analysis tool must stay source-read-only: {s}\n", .{entry.name});
            ok = false;
        }
    }
    return ok;
}

fn checkSecurityPolicy(allocator: Allocator, io: Io) !bool {
    const path = "SECURITY.md";
    const bytes = readFileAlloc(allocator, io, path, 1024 * 1024) catch |err| {
        try stderrPrint(io, "security-policy check could not read {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    var ok = true;
    const required = [_][]const u8{
        "https://github.com/oly-wan-kenobi/zigar/security/advisories/new",
        "oliver.guenthardt@digitecgalaxus.ch",
        "acknowledge a private vulnerability report within 7 days",
        "initial triage assessment within 14 days",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, bytes, needle) == null) {
            try stderrPrint(io, "security-policy check missing `{s}` in {s}\n", .{ needle, path });
            ok = false;
        }
    }
    return ok;
}

fn checkMcpNoPatchContract(allocator: Allocator, io: Io) !bool {
    var ok = true;
    const build_files = [_][]const u8{ "build.zig", "build.zig.zon" };
    const forbidden = [_][]const u8{
        "third_party/mcp_zigar_patch",
        "mcp_upstream",
        "addMcpModule",
    };
    for (build_files) |path| {
        const bytes = readFileAlloc(allocator, io, path, 1024 * 1024) catch |err| {
            try stderrPrint(io, "MCP no-patch check could not read {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        for (forbidden) |needle| {
            if (std.mem.indexOf(u8, bytes, needle) != null) {
                try stderrPrint(io, "MCP no-patch check found `{s}` in {s}; build must use the pinned upstream mcp module directly\n", .{ needle, path });
                ok = false;
            }
        }
    }

    const adapter = readFileAlloc(allocator, io, "src/mcp_server.zig", 2 * 1024 * 1024) catch |err| {
        try stderrPrint(io, "MCP no-patch check could not read src/mcp_server.zig: {s}\n", .{@errorName(err)});
        return false;
    };
    defer allocator.free(adapter);
    const required = [_][]const u8{
        "First-party MCP server adapter",
        "pinned upstream MCP dependency",
        "ToolResultDeinit",
        "ResourceContentDeinit",
        "PromptMessagesDeinit",
        "deinit_result",
        "addResourceWithDeinit",
        "addPromptWithDeinit",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, adapter, needle) == null) {
            try stderrPrint(io, "MCP no-patch check missing `{s}` in src/mcp_server.zig\n", .{needle});
            ok = false;
        }
    }
    return ok;
}

fn checkMcpAdvertisedCapabilityContract(allocator: Allocator, io: Io) !bool {
    const rules = [_]struct {
        path: []const u8,
        token: []const u8,
        reason: []const u8,
    }{
        .{
            .path = "src/main.zig",
            .token = "enableTasks(",
            .reason = "public server startup must not advertise MCP task support until zigar implements the task lifecycle",
        },
        .{
            .path = "src/mcp_server.zig",
            .token = "capabilities.tasks",
            .reason = "MCP task capabilities must not be emitted without implemented task methods",
        },
        .{
            .path = "src/mcp_server.zig",
            .token = "handleTasks",
            .reason = "stub task handlers must not remain in the public protocol surface",
        },
        .{
            .path = "docs/architecture.md",
            .token = "empty task-list",
            .reason = "architecture docs must not advertise MCP task support until zigar implements the task lifecycle",
        },
    };

    var ok = true;
    for (rules) |rule| {
        const bytes = readFileAlloc(allocator, io, rule.path, 2 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "MCP capability-contract check could not read {s}: {s}\n", .{ rule.path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, rule.token) != null) {
            try stderrPrint(io, "MCP capability-contract violation in {s}: `{s}` ({s})\n", .{ rule.path, rule.token, rule.reason });
            ok = false;
        }
    }
    return ok;
}

fn checkNoExtensionInTree(allocator: Allocator, io: Io, root: []const u8, extension: []const u8) !bool {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var ok = true;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, extension)) continue;
        try stderrPrint(io, "pure Zig hygiene rejected {s}/{s}: Python files do not belong in project-owned source, tools, tests, scripts, examples, docs, or CI\n", .{ root, entry.path });
        ok = false;
    }
    return ok;
}

fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, limit: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

fn lineCount(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var count: usize = 0;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    if (bytes[bytes.len - 1] != '\n') count += 1;
    return count;
}

fn stdoutWrite(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "lineCount handles empty trailing and unterminated text" {
    try std.testing.expectEqual(@as(usize, 0), lineCount(""));
    try std.testing.expectEqual(@as(usize, 1), lineCount("one"));
    try std.testing.expectEqual(@as(usize, 1), lineCount("one\n"));
    try std.testing.expectEqual(@as(usize, 2), lineCount("one\ntwo"));
    try std.testing.expectEqual(@as(usize, 2), lineCount("one\ntwo\n"));
}

test "line budget headroom scales for small and large files" {
    try std.testing.expectEqual(@as(usize, 10), minLineBudgetHeadroom(80));
    try std.testing.expectEqual(@as(usize, 18), minLineBudgetHeadroom(180));
    try std.testing.expectEqual(@as(usize, 50), minLineBudgetHeadroom(800));
}
