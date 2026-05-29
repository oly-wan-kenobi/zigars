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
- Known-open (don't rediscover; flag only if your area directly touches them): argInt `.float` -> @intFromFloat panic (src/app/usecases/usecase_support.zig:326); reentrant dispatch (src/adapters/mcp/server/protocol_client.zig:166); npm cache poisoning (packages/@zigars/mcp/src/install.ts:94); zig_code_action_batch stub vs manifest; discovery tools text-only; negative @intCast (patch_sessions.zig:848, artifacts/registry.zig:383); zon injection (src/domain/zig/zon_dependencies.zig:193); audit.zig:101 non-atomic length+writePositional (latent only if dispatch becomes multi-threaded).
- Verified-safe FROM A PRIOR PASS - re-verify rather than trust, but only report a real NEW defect: workspace sandbox (src/infra/workspace/workspace.zig resolveInsideRoot two-stage lexical+realpath containment); command runner (src/infra/process/command.zig monotonic deadline, child kill+reap, MultiReader concurrent drain, bounded output); ZLS client thread cleanup (disconnect joins both threads) and request waitTimeout; diagnostics_cache byte accounting; structured() deep-copy (src/adapters/mcp/result.zig:103).

---
THIS SESSION: Infra - ZLS client, process, workspace, artifacts, observability.

Subagents: spawn 5 in parallel, one cluster each:
1. src/infra/zls/client.zig + transport.zig  [read FULLY - the only genuinely concurrent component]
2. src/infra/zls/{gateway,session,process,diagnostics_cache,edits,uri}.zig
3. src/infra/process/{command,command_runner,sync}.zig
4. src/infra/workspace/{workspace,filesystem,scanner}.zig + src/infra/artifacts/{registry,registry_store}.zig
5. src/infra/observability/{state,metrics,logging,audit}.zig + src/infra/toolchain/env.zig + src/infra/runtime_ux/*

Hunt for: data races or missing-/wrong-lock access to shared ZLS state (pending requests, last_error, diagnostics cache, document versions); lock-ordering deadlock across the client mutexes; request/response correlation bugs (id reuse, lost wakeups, stale pending on timeout); thread and subprocess teardown on deinit/disconnect and on partial init (joins, zombies, double-close); LSP framing parse bugs in transport.zig (Content-Length, partial reads, oversized headers); diagnostics-cache eviction and byte-accounting correctness under the lock; observability byte/ring accounting edge cases; audit-writer failure handling (must never touch stdout or fail a request); workspace edge cases (symlink/TOCTOU, output-parent canonicalization, prefix-sibling escapes).
