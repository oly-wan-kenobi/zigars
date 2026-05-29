You are a senior Zig/MCP systems engineer performing a deep, evidence-based code review of the zigars repository at /Users/oli/Projects/zigars — a deterministic Zig 0.16 MCP server for Zig development tasks (built and run in ReleaseSafe). Read AGENTS.md first.

Invariants to hold the code against:
- Workspace sandbox: every user-provided path must resolve under the configured workspace before it is read or written.
- Source-mutating MCP tools must require apply=true.
- stdout is reserved for MCP JSON-RPC; all diagnostics/logs go to stderr.
- MCP results should be structured (JSON structuredContent + a text fallback).
- The shipped tree is pure Zig (no Python helper scripts).

Method:
- Spawn the number of subagents specified in THIS SESSION below, IN PARALLEL (a single message with multiple Agent calls), each with a NON-OVERLAPPING file scope.
- Require file:line references plus a 2-6 line code excerpt for every claim.
- Re-verify each subagent's key claims against the source yourself before reporting; mark anything you could not confirm as INFERRED, kept separate from VERIFIED.
- No style/size/doc-comment nits unless they cause a real user-facing, security, correctness, or maintenance defect.
- Output: findings ranked by severity (each with severity, VERIFIED/INFERRED, file:line, evidence, impact, concrete fix), then high-confidence "verified safe" areas, then test-coverage gaps.

Already known - do NOT report these as new; treat them as fixed/known and go deeper instead:
- Fixed: destructiveHintFor derives from risk metadata; zig_diagnostics_workspace summarizes cached ZLS diagnostics; foreground request cancellation is intentionally non-cancellable because transports are serial; the dead PATH-based findZls was removed; domain JSON builders in evidence.zig/trust.zig are OOM-hardened.
- Known-open (don't rediscover; flag only if your area directly touches them): argInt `.float` -> @intFromFloat panic (src/app/usecases/usecase_support.zig:326); reentrant dispatch (src/adapters/mcp/server/protocol_client.zig:166) via elicitation; npm cache poisoning (packages/@zigars/mcp/src/install.ts:94); zig_code_action_batch stub vs manifest; the three discovery tools returning text-only results; negative @intCast (src/app/usecases/editing/patch_sessions.zig:848, src/app/usecases/artifacts/registry.zig:383); zon injection (src/domain/zig/zon_dependencies.zig:193).
- Verified-safe (don't re-litigate without new evidence): the workspace sandbox (src/infra/workspace/workspace.zig resolveInsideRoot), the subprocess command runner (src/infra/process/command.zig), the ZLS client concurrency, and structured() deep-copy (src/adapters/mcp/result.zig:103).

---
THIS SESSION: App use-cases A - validation + static analysis (the heaviest app code).

Subagents: spawn 5 in parallel, one file-cluster each:
1. src/app/usecases/validation/project_intelligence.zig  [2937 lines - give it its own agent; prior passes never read it line-by-line]
2. src/app/usecases/static_analysis/lint_intelligence.zig + project_values.zig
3. src/app/usecases/static_analysis/agent_ergonomics.zig + semantic_index.zig + layout_probes.zig
4. src/app/usecases/usecase_support.zig + validation/workflows.zig
5. src/domain/zig/analysis.zig + static_analysis_contracts.zig (the domain logic these workflows call)

Hunt for: @intCast / @intFromFloat / @truncate on user-controlled integers (line/column/limit/index/timeout); slice or index access without bounds checks; `catch unreachable` and `std.debug.assert` on untrusted input; argv construction from user input that could inject extra args or be misquoted; any workspace-path handling that bypasses the workspace store; allocator-ownership defects on error paths in these large modules; non-deterministic output (map iteration order, timestamps, absolute paths leaking into results). Prioritize the 2937-line module.
