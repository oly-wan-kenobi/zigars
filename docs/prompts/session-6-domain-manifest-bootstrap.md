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
- Fixed: destructiveHintFor derives from risk metadata; zig_diagnostics_workspace summarizes cached ZLS diagnostics; foreground request cancellation is intentionally non-cancellable because transports are serial; the dead PATH-based findZls was removed; domain JSON builders in evidence.zig/trust.zig are OOM-hardened; writes_source apply-gating is comptime-enforced (src/manifest/aggregate.zig:74-94).
- Known-open (don't rediscover; flag only if your area directly touches them): argInt `.float` -> @intFromFloat panic (src/app/usecases/usecase_support.zig:326); reentrant dispatch (src/adapters/mcp/server/protocol_client.zig:166); npm cache poisoning (packages/@zigars/mcp/src/install.ts:94); zig_code_action_batch stub vs manifest; discovery tools text-only; negative @intCast (patch_sessions.zig:848, artifacts/registry.zig:383); zon injection (src/domain/zig/zon_dependencies.zig:193 - IN YOUR AREA, verify); zig_diagnostics plan says publishDiagnostics but handler sends textDocument/diagnostic.
- Verified-safe (don't re-litigate without new evidence): the workspace sandbox (src/infra/workspace/workspace.zig resolveInsideRoot), the subprocess command runner (src/infra/process/command.zig), the ZLS client concurrency, and structured() deep-copy (src/adapters/mcp/result.zig:103).

---
THIS SESSION: Domain logic + manifest invariants + bootstrap (small layers, folded).

Subagents: spawn 4 in parallel, one cluster each:
1. src/domain/zig/{compiler_output,zon_dependencies}.zig + src/domain/editing/* (parsers and edit model)
2. src/domain/{diagnostics,profiling,evidence,trust}.zig + domain/release/*
3. src/manifest/{aggregate,mod,types,groups,tooling,all_definitions}.zig + tool_catalog.json (comptime invariants, hint derivation, catalog<->definition consistency)
4. src/bootstrap/{runtime,config,app_context,runtime_ports,runtime_state}.zig + src/main.zig

Hunt for: parser bounds/overflow/underflow on malformed input that should be tolerated rather than panic; comptime manifest guards that are INCOMPLETE (which risk-capability/read_only/plan combinations can still slip past validateDefinition?); the hint functions readOnlyHintFor / destructiveHintFor / idempotentHintFor vs the underlying risk metadata (any remaining inconsistency or contradictory hint pair); catalog references that don't resolve; bootstrap allocator ownership, errdefer chains, partial-init teardown, and whether dependency wiring can leave a null/invalid port that a handler later dereferences; whether main.zig stays a thin lifecycle entrypoint.
