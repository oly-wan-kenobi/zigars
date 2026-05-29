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
- Known-open (don't rediscover; flag only if your area directly touches them): argInt `.float` -> @intFromFloat panic (src/app/usecases/usecase_support.zig:326); reentrant dispatch (src/adapters/mcp/server/protocol_client.zig:166) via elicitation; npm cache poisoning (packages/@zigars/mcp/src/install.ts:94); zig_code_action_batch stub vs manifest (src/adapters/mcp/tools/transactional_editing.zig:169 vs src/manifest/definitions/transactional_editing.zig:135); the three discovery tools returning text-only results (src/adapters/mcp/tools/discovery.zig); negative @intCast (patch_sessions.zig:848, artifacts/registry.zig:383); zon injection (src/domain/zig/zon_dependencies.zig:193).
- Verified-safe (don't re-litigate without new evidence): the workspace sandbox (src/infra/workspace/workspace.zig resolveInsideRoot), the subprocess command runner (src/infra/process/command.zig), the ZLS client concurrency, and structured() deep-copy (src/adapters/mcp/result.zig:103).

---
THIS SESSION: MCP adapters & tool-handler <-> manifest fidelity. Keep each handler paired with its manifest definition - this boundary produces the highest-value findings.

Subagents: spawn 5 in parallel, each owning a handler+definition pairing:
1. tools/core.zig + tools/diagnostics.zig + tools/dependencies.zig  vs  manifest/definitions/{core,diagnostics,*}.zig
2. tools/static_analysis.zig + static_source_summary.zig + static_evidence (defs)  vs  manifest/definitions/{static_analysis,static_evidence}.zig
3. tools/release.zig + tools/performance.zig + tools/profiling.zig  vs  manifest/definitions/{ci,docs,performance,profiling}.zig
4. tools/transactional_editing.zig + tools/zls.zig + tools/runtime_ux.zig + tools/runtime_metrics.zig  vs  manifest/definitions/{transactional_editing,zls,formatting,runtime_ux}.zig
5. tools/project_intelligence.zig + tools/environment.zig + tools/discovery.zig + tools/artifacts.zig + tools/result_shape.zig, plus the projection glue: handlers.zig, handler_refs.zig, registration.zig, args.zig, schema.zig, result.zig, errors.zig

Hunt for (contract fidelity is the #1 priority): does each handler read every REQUIRED schema field and reject when missing? does it read args NOT in the schema, or ignore args that ARE? does it advertise a plan method/command it does not actually run? risk metadata that under- or over-states real side effects? read_only=true on a handler that mutates (or vice versa)? result-shape consistency (structuredContent + text fallback everywhere)? enum/fieldHint values that don't match handler validation? Cross-check tool_catalog.json common_intents[].prefer ids and group membership against the actual definitions.
