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
- Known-open (don't rediscover; flag only if your area directly touches them): argInt `.float` -> @intFromFloat panic (src/app/usecases/usecase_support.zig:326); reentrant dispatch (src/adapters/mcp/server/protocol_client.zig:166) via elicitation - THIS IS IN YOUR AREA, verify the fix or confirm it persists; npm cache poisoning (packages/@zigars/mcp/src/install.ts:94); zig_code_action_batch stub vs manifest; the three discovery tools returning text-only results; negative @intCast (patch_sessions.zig:848, artifacts/registry.zig:383); zon injection (src/domain/zig/zon_dependencies.zig:193); unguarded re-initialize resets state (server.zig:495).
- Verified-safe (don't re-litigate without new evidence): the workspace sandbox (src/infra/workspace/workspace.zig resolveInsideRoot), the subprocess command runner (src/infra/process/command.zig), the ZLS client concurrency, and structured() deep-copy (src/adapters/mcp/result.zig:103). Note: the JSON-RPC wire framing lives in a vendored `mcp` package (NOT in src/) - out of scope; review only how this code uses it.

---
THIS SESSION: MCP server core, protocol lifecycle & transports.

Subagents: spawn 4 in parallel, one cluster each:
1. src/adapters/mcp/server.zig  (dispatch, ServerState machine, handleRequest/handleNotification/handleResponse, cancellation handling, audit hooks)
2. src/adapters/mcp/server/{http_runner,http_transport,protocol_client}.zig + correlation.zig
3. src/adapters/mcp/server/{completion,pagination,tasks,resource_subscriptions,json_helpers}.zig
4. src/adapters/mcp/resources.zig + prompts.zig + resource_errors.zig + src/domain/cancellation.zig

Hunt for: lifecycle/state-machine bugs (re-initialize, requests after shutdown, double-init); pagination cursor validity and stability under list mutation; completion `total`/`hasMore` honesty; tasks submit/poll/cancel/result correctness, retained-job ring eviction, and stdout/stderr tail-truncation honesty; resources read/subscribe/unsubscribe URI sandboxing, subscription leaks, notification storms; JSON-RPC error-code correctness with no internal-detail or stdout leakage; unbounded growth in correlation / completed-request / pending-request structures; request-id int-vs-string handling; and the reentrancy concern - confirm whether a handler blocked on an elicitation/sampling reply can recursively dispatch inbound requests and whether any depth guard exists.
