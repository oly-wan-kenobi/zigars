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

// Central release hygiene policy. Budgets intentionally include required
// headroom so growth triggers splitting before files become hard to audit.
// Oversized legacy modules are re-baselined with narrow headroom and reasons
// that name the next split target instead of disabling future growth checks.

pub const line_budgets = [_]LineBudget{
    .{
        .path = "src/main.zig",
        .max_lines = 150,
        .reason = "main must stay a small startup/lifecycle entrypoint",
    },
    .{
        .path = "src/testing/mcp/adapter_tests.zig",
        .max_lines = 640,
        .reason = "server integration fixtures should stay readable and move shared setup helpers if they grow further",
    },
    .{
        .path = "src/adapters/mcp/server.zig",
        .max_lines = 1680,
        .reason = "first-party MCP adapter is over the preferred audit size and should split remaining routing or lifecycle helpers next",
    },
    .{
        .path = "src/testing/mcp/server_tests.zig",
        .max_lines = 805,
        .reason = "MCP adapter fixtures are over the preferred audit size and should split routing and error-contract scenarios next",
    },
    .{
        .path = "src/adapters/mcp/server/http_transport.zig",
        .max_lines = 120,
        .reason = "HTTP request transport adapter should stay compact and protocol-focused",
    },
    .{
        .path = "src/infra/backends/catalog.zig",
        .max_lines = 120,
        .reason = "backend setup catalog rendering should remain separate from packaged backend definitions",
    },
    .{
        .path = "src/infra/backends/definitions.zig",
        .max_lines = 140,
        .reason = "backend setup metadata should remain compact and auditable",
    },
    .{
        .path = "src/infra/artifacts/registry.zig",
        .max_lines = 676,
        .reason = "artifact registry provenance helpers must stay auditable and separate from tool handlers",
    },
    .{
        .path = "src/infra/observability/state.zig",
        .max_lines = 640,
        .reason = "observability state is over the preferred audit size and should split JSON value builders from state mutation next",
    },
    .{
        .path = "src/app/result_shape.zig",
        .max_lines = 310,
        .reason = "result-shape contract policy should stay compact and reusable",
    },
    .{
        .path = "src/adapters/mcp/tools/artifacts.zig",
        .max_lines = 820,
        .reason = "artifact registry MCP projection is over the preferred audit size and should split helper-value tests or JSON builders next",
    },
    .{
        .path = "src/adapters/mcp/tools/runtime_metrics.zig",
        .max_lines = 544,
        .reason = "runtime metrics MCP projection should stay bounded around argument/result/error mapping",
    },
    .{
        .path = "src/manifest/definitions/diagnostics.zig",
        .max_lines = 210,
        .reason = "runtime diagnostic definitions are over the preferred audit size and should split schema groups next",
    },
    .{
        .path = "src/manifest/definitions/adoption.zig",
        .max_lines = 100,
        .reason = "adoption tool definitions should remain compact and centralized",
    },
    .{
        .path = "src/adapters/mcp/tools/discovery.zig",
        .max_lines = 245,
        .reason = "discovery MCP adapter must stay projection-only over app discovery use cases",
    },
    .{
        .path = "src/infra/workspace/workspace.zig",
        .max_lines = 616,
        .reason = "workspace path and IO boundaries are trust-critical and must stay compact enough to audit",
    },
    .{
        .path = "src/infra/zls/documents.zig",
        .max_lines = 543,
        .reason = "document state is over the preferred audit size and should split lifecycle helpers from retained-content accounting next",
    },
    .{
        .path = "src/infra/zls/documents_tests.zig",
        .max_lines = 671,
        .reason = "document-state lifecycle fixtures are near the preferred audit size and should split reopen scenarios next",
    },
    .{
        .path = "src/infra/zls/client.zig",
        .max_lines = 692,
        .reason = "LSP client is over the preferred audit size and should split unit tests or shutdown helpers next",
    },
    .{
        .path = "src/infra/zls/client_test_support.zig",
        .max_lines = 100,
        .reason = "LSP test support should stay compact and separate from client runtime logic",
    },
    .{
        .path = "src/infra/zls/client_tests.zig",
        .max_lines = 312,
        .reason = "black-box LSP client tests should stay separate from runtime transport logic",
    },
    .{
        .path = "src/infra/zls/diagnostics_cache.zig",
        .max_lines = 392,
        .reason = "diagnostics retention policy should stay small enough to audit independently",
    },
    .{
        .path = "src/manifest/types.zig",
        .max_lines = 160,
        .reason = "manifest type definitions should remain a compact schema vocabulary",
    },
    .{
        .path = "src/manifest/definitions.zig",
        .max_lines = 140,
        .reason = "tool definition facade should preserve public order and delegate group bodies",
    },
    .{
        .path = "src/manifest/all_definitions.zig",
        .max_lines = 270,
        .reason = "combined tool definition aliases should stay a compact ordered table over group bodies",
    },
    .{
        .path = "src/manifest/definitions/discovery.zig",
        .max_lines = 140,
        .reason = "discovery and planning tool definitions should remain independently reviewable",
    },
    .{
        .path = "src/manifest/definitions/agent.zig",
        .max_lines = 120,
        .reason = "agent workflow tool definitions should remain independently reviewable",
    },
    .{
        .path = "src/manifest/definitions/core.zig",
        .max_lines = 130,
        .reason = "core Zig command tool definitions should remain independently reviewable",
    },
    .{
        .path = "src/manifest/definitions/formatting.zig",
        .max_lines = 100,
        .reason = "formatting and edit tool definitions should remain independently reviewable",
    },
    .{
        .path = "src/manifest/definitions/zls.zig",
        .max_lines = 170,
        .reason = "ZLS tool definitions should remain independently reviewable",
    },
    .{
        .path = "src/manifest/definitions/docs.zig",
        .max_lines = 80,
        .reason = "docs tool definitions should remain compact and explicitly scoped",
    },
    .{
        .path = "src/manifest/definitions/foundation.zig",
        .max_lines = 180,
        .reason = "foundation contract tool definitions should remain compact and additive",
    },
    .{
        .path = "src/manifest/definitions/environment_profiles.zig",
        .max_lines = 280,
        .reason = "environment/profile tool definitions should remain independently reviewable",
    },
    .{
        .path = "src/manifest/definitions/static_analysis.zig",
        .max_lines = 440,
        .reason = "static analysis tool definitions should remain independently reviewable",
    },
    .{
        .path = "src/manifest/definitions/ci.zig",
        .max_lines = 80,
        .reason = "CI artifact tool definitions should remain compact",
    },
    .{
        .path = "src/manifest/definitions/zwanzig.zig",
        .max_lines = 90,
        .reason = "optional zwanzig backend definitions should remain compact",
    },
    .{
        .path = "src/manifest/definitions/profiling.zig",
        .max_lines = 100,
        .reason = "profiling backend definitions should remain compact",
    },
    .{
        .path = "src/manifest/definitions/performance.zig",
        .max_lines = 220,
        .reason = "performance workflow definitions are over the preferred audit size and should split schema groups next",
    },
    .{
        .path = "src/manifest/groups.zig",
        .max_lines = 80,
        .reason = "tool group keyword metadata should remain a compact manifest adjunct",
    },
    .{
        .path = "tools/zigars_tools.zig",
        .max_lines = 220,
        .reason = "tool dispatcher must remain a small command router over focused helpers",
    },
    .{
        .path = "tools/common/cli_io.zig",
        .max_lines = 120,
        .reason = "tooling CLI IO and argument diagnostics should remain a compact shared utility",
    },
    .{
        .path = "tools/release/dist.zig",
        .max_lines = 550,
        .reason = "release packaging should stay a focused helper, not a second build system",
    },
    .{
        .path = "tools/coverage/coverage.zig",
        .max_lines = 580,
        .reason = "coverage command orchestration should stay separate from Cobertura parsing and summary rendering",
    },
    .{
        .path = "tools/coverage/coverage_summary.zig",
        .max_lines = 440,
        .reason = "coverage release-evidence JSON rendering should stay focused and schema-shaped",
    },
    .{
        .path = "tools/integration/http/http_smoke.zig",
        .max_lines = 340,
        .reason = "HTTP smoke tests should stay focused on transport-level release assertions",
    },
    .{
        .path = "tools/integration/http/http_tool_contract_smoke.zig",
        .max_lines = 160,
        .reason = "HTTP tool contract smoke assertions should stay grouped by tool family",
    },
    .{
        .path = "tools/integration/http/http_performance_smoke.zig",
        .max_lines = 120,
        .reason = "performance HTTP smoke coverage should stay a focused fixture module",
    },
    .{
        .path = "tools/integration/http/http_adoption_smoke.zig",
        .max_lines = 80,
        .reason = "adoption HTTP smoke coverage should stay a focused fixture module",
    },
    .{
        .path = "tools/integration/stdio/stdio_fixtures.zig",
        .max_lines = 595,
        .reason = "stdio smoke fixtures should stay focused on end-to-end protocol assertions",
    },
    .{
        .path = "tools/integration/stdio/stdio_core_fixtures.zig",
        .max_lines = 190,
        .reason = "stdio core tool-family assertions should remain separate from protocol lifecycle setup",
    },
    .{
        .path = "tools/integration/stdio/stdio_adoption_fixtures.zig",
        .max_lines = 60,
        .reason = "adoption stdio fixture coverage should stay compact",
    },
    .{
        .path = "tools/integration/smoke_support.zig",
        .max_lines = 184,
        .reason = "shared smoke-test utilities should remain a small helper module",
    },
    .{
        .path = "tools/release/release_targets.zig",
        .max_lines = 120,
        .reason = "release target metadata should remain a compact shared table",
    },
    .{
        .path = "tools/release/release_docs.zig",
        .max_lines = 260,
        .reason = "release documentation checks include public adoption contract needles and should stay separate from the release-check dispatcher",
    },
    .{
        .path = "tools/release/backend_docs.zig",
        .max_lines = 120,
        .reason = "optional backend documentation checks should stay focused on backend evidence contracts",
    },
    .{
        .path = "tools/release/public_claims.zig",
        .max_lines = 180,
        .reason = "public claim wording checks should stay focused and separate from docs-specific release checks",
    },
    .{
        .path = "tools/release/mcp_contracts.zig",
        .max_lines = 120,
        .reason = "MCP release-contract checks should stay focused on adapter and advertised-capability invariants",
    },
    .{
        .path = "tools/release/mcp_tool_contracts.zig",
        .max_lines = 90,
        .reason = "per-tool MCP schema probes should stay separate from release surface token checks",
    },
    .{
        .path = "tools/release/release_checks.zig",
        .max_lines = 520,
        .reason = "release checks are critical trust infrastructure; policy tables and fake backends belong in focused modules",
    },
    .{
        .path = "tools/release/fake_backends.zig",
        .max_lines = 165,
        .reason = "fake backend fixtures should stay small and focused on conformance smoke behavior",
    },
    .{
        .path = "tools/release/release_rules.zig",
        .max_lines = 850,
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
        .path = "src/infra/zls/client.zig",
        .token = "std.debug.print",
        .reason = "LSP lifecycle logs must go through the project logger",
    },
    .{
        .path = "src/infra/zls/documents.zig",
        .token = "std.debug.print",
        .reason = "document-session logs must go through the project logger",
    },
};

pub const code_hygiene_tokens = [_]HygieneToken{
    .{
        .path = "src/infra/zls/session.zig",
        .token = "const std = @import(\"std\");",
        .reason = "known stale import from task 018",
    },
};

pub const ignored_error_hygiene_tokens = [_]HygieneToken{
    .{
        .path = "src/infra/zls/client.zig",
        .token = "catch {};",
        .reason = "LSP client errors must be propagated or recorded with logger/last_error",
    },
    .{
        .path = "src/infra/zls/client.zig",
        .token = "catch return;",
        .reason = "LSP client best-effort shutdown/read paths must record why they are ignored",
    },
    .{
        .path = "src/infra/zls/transport.zig",
        .token = "catch continue",
        .reason = "LSP transport parse/read errors must be explicit protocol failures",
    },
    .{
        .path = "src/infra/zls/transport.zig",
        .token = "catch return",
        .reason = "LSP transport test helpers must only swallow EOF-like read errors explicitly",
    },
    .{
        .path = "tools/integration/stdio/stdio_fixtures.zig",
        .token = "deleteTree(io, rel) catch {};",
        .reason = "fixture cleanup failures must be reported without masking test status",
    },
    .{
        .path = "tools/integration/http/http_smoke.zig",
        .token = "sleep(.{ .duration = .{ .raw = Io.Duration.fromMilliseconds(100), .clock = .awake } }, io) catch {};",
        .reason = "HTTP smoke retry sleep failures must be visible",
    },
    .{
        .path = "tools/release/fake_backends.zig",
        .token = "writeStreamingAll(io, message) catch " ++ "{};",
        .reason = "release-check fake backend diagnostics must not be silently dropped",
    },
    .{
        .path = "tools/release/release_checks.zig",
        .token = "catch return " ++ "false",
        .reason = "release-check git/filesystem probes must report unexpected failures",
    },
    .{
        .path = "tools/common/cli_io.zig",
        .token = "catch {};",
        .reason = "CLI usage diagnostics must either be printed or return the print failure",
    },
};

pub const tool_error_contract_paths = [_][]const u8{
    "src/adapters/mcp/registry.zig",
    "src/adapters/mcp/tools/artifacts.zig",
    "src/adapters/mcp/tools/discovery.zig",
    "src/adapters/mcp/tools/runtime_metrics.zig",
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
    "src/adapters/mcp/server.zig",
    "src/adapters/mcp/resources.zig",
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
    "tools/zigars_tools.zig",
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

test "release rules declare gates for source and tool checks" {
    try @import("std").testing.expect(line_budgets.len > 0);
    try @import("std").testing.expect(forbidden_tokens.len > 0);
    try @import("std").testing.expect(pure_zig_roots.len >= 2);
}
