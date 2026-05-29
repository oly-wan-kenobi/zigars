You are a senior Zig/MCP systems engineer performing a deep, evidence-based code review of the zigars repository at /Users/oli/Projects/zigars — a deterministic Zig 0.16 MCP server for Zig development tasks (built and run in ReleaseSafe). Read AGENTS.md first.

Invariants to hold the code against:
- Workspace sandbox: every user-provided path must resolve under the configured workspace before it is read or written.
- Source-mutating MCP tools must require apply=true.
- stdout is reserved for MCP JSON-RPC; all diagnostics/logs go to stderr.
- MCP results should be structured (JSON structuredContent + a text fallback).
- The shipped tree is pure Zig (no Python helper scripts). NOTE: this rule is enforced for the shipped source tree (tools/release/release_checks.zig has a no-.py-in-tree check), but .github/scripts use python3 heredocs - assess whether that is the intended scope and flag any drift.

Method:
- Spawn the number of subagents specified in THIS SESSION below, IN PARALLEL (a single message with multiple Agent calls), each with a NON-OVERLAPPING file scope.
- Require file:line references plus a 2-6 line code excerpt for every claim.
- Re-verify each subagent's key claims against the source yourself before reporting; mark anything you could not confirm as INFERRED, kept separate from VERIFIED.
- No style/size/doc-comment nits unless they cause a real user-facing, security, correctness, or maintenance defect.
- Output: findings ranked by severity (each with severity, VERIFIED/INFERRED, file:line, evidence, impact, concrete fix), then high-confidence "verified safe" areas, then test-coverage gaps.

Already known - do NOT report these as new; treat them as fixed/known and go deeper instead:
- Fixed: destructiveHintFor derives from risk metadata; zig_diagnostics_workspace summarizes cached ZLS diagnostics; foreground request cancellation is intentionally non-cancellable; the dead PATH-based findZls was removed; domain JSON builders OOM-hardened; zig_diagnostics_all plan metadata aligned and tool index regenerated.
- Known-open elsewhere (don't rediscover): argInt `.float` panic (usecase_support.zig:326); reentrancy (protocol_client.zig:166); npm cache poisoning (install.ts:94); zig_code_action_batch stub; discovery tools text-only; negative @intCast (patch_sessions.zig:848, artifacts/registry.zig:383); zon injection (zon_dependencies.zig:193).
- Verified-safe (don't re-litigate without new evidence): workspace sandbox; subprocess command runner; ZLS concurrency; structured() deep-copy. Note the prior pass observed "backend contract scenario missing ..." and "dist expected 8 release packages, got 7" lines in `zig build test` output - these were captured output from PASSING negative-path tests (the suite is 948/948 green); confirm that interpretation rather than treating them as failures.

---
THIS SESSION: tools/ + build & CI supply-chain.

Subagents: spawn 4 in parallel, one cluster each:
1. tools/release/* (release_checks.zig, dist.zig, artifact-hygiene) - do the gates actually fail when their invariant is violated, or can they pass while the invariant is broken (false-negative gates)?
2. tools/quality/architecture_guard.zig - is the forbidden-import / layering / cycle detection SOUND, or can a real violation slip past its patterns? Try to construct a bypass.
3. tools/zigars_tools.zig (dispatcher) + tools/fuzz_test_runner.zig + tools/common/* + tools/integration/* fixtures
4. build.zig + build.zig.zon + .github/workflows/* + .github/scripts/*

Hunt for: release-gate checks that can pass while the property they guard is violated; architecture_guard soundness and bypassability; CI supply-chain risks (unpinned actions, pull_request_target with checkout of untrusted code, untrusted github.event.* interpolation into shell, curl|sh patterns); generated-artifact hygiene (committed build outputs / zig-out / caches); determinism of generated docs and the tool index; the python3-in-CI vs pure-Zig scope question; and whether integration smoke fixtures actually assert tools/call contracts rather than just running.
