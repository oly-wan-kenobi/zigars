pub const LineBudget = struct {
    path: []const u8,
    max_lines: usize,
    reason: []const u8,
};

pub const ForbiddenToken = struct {
    path: []const u8,
    token: []const u8,
    reason: []const u8,
};

pub const HygieneToken = struct {
    path: []const u8,
    token: []const u8,
    reason: []const u8,
};

pub const ToolErrorContractToken = struct {
    token: []const u8,
    reason: []const u8,
};

pub const line_budgets = [_]LineBudget{
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
        .max_lines = 120,
        .reason = "documentation lookup facade should stay thin over focused source-family modules",
    },
    .{
        .path = "src/docs/builtins.zig",
        .max_lines = 280,
        .reason = "curated builtin docs should stay a compact offline lookup table and renderer",
    },
    .{
        .path = "src/docs/std.zig",
        .max_lines = 650,
        .reason = "stdlib source lookup should stay below a single-review module size",
    },
    .{
        .path = "src/analysis.zig",
        .max_lines = 700,
        .reason = "heuristic source scanners should stay bounded; semantic analysis belongs in stronger backends",
    },
    .{
        .path = "src/state/documents.zig",
        .max_lines = 520,
        .reason = "document state is concurrency-sensitive and runtime logic must stay separate from fixtures",
    },
    .{
        .path = "src/state/documents_tests.zig",
        .max_lines = 520,
        .reason = "document-state lifecycle fixtures should stay separate from runtime logic",
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
        .path = "tools/backend_docs.zig",
        .max_lines = 120,
        .reason = "optional backend documentation checks should stay focused on backend evidence contracts",
    },
    .{
        .path = "tools/public_claims.zig",
        .max_lines = 180,
        .reason = "public claim wording checks should stay focused and separate from docs-specific release checks",
    },
    .{
        .path = "tools/mcp_contracts.zig",
        .max_lines = 150,
        .reason = "MCP release-contract checks should stay focused on adapter and advertised-capability invariants",
    },
    .{
        .path = "tools/release_checks.zig",
        .max_lines = 650,
        .reason = "release checks are critical trust infrastructure; policy tables belong in release_rules.zig",
    },
    .{
        .path = "tools/release_rules.zig",
        .max_lines = 620,
        .reason = "release policy tables should stay auditable and split by domain if they grow further",
    },
};

pub const forbidden_tokens = [_]ForbiddenToken{
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

pub const code_hygiene_tokens = [_]HygieneToken{
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

pub const ignored_error_hygiene_tokens = [_]HygieneToken{
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

pub const tool_error_contract_paths = [_][]const u8{
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

pub const tool_error_contract_tokens = [_]ToolErrorContractToken{
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

pub const resource_error_contract_paths = [_][]const u8{
    "src/server.zig",
    "src/tools/resources.zig",
};

pub const resource_error_contract_tokens = [_]ToolErrorContractToken{
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

pub const cli_error_contract_paths = [_][]const u8{
    "tools/zigar_tools.zig",
};

pub const cli_error_contract_tokens = [_]ToolErrorContractToken{
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

pub const WorkflowPermissionRule = struct {
    path: []const u8,
    required: []const []const u8,
};

pub const workflow_permission_rules = [_]WorkflowPermissionRule{
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
        .path = ".github/workflows/zls-conformance.yml",
        .required = &.{
            "permissions:",
            "contents: read",
        },
    },
    .{
        .path = ".github/workflows/release-readiness.yml",
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

pub const pure_zig_roots = [_][]const u8{
    ".github",
    "docs",
    "examples",
    "scripts",
    "src",
    "tests",
    "tools",
};
