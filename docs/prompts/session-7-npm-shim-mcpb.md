You are a senior Zig/MCP systems engineer performing a deep, evidence-based, SECURITY-FOCUSED code review of the zigars repository at /Users/oli/Projects/zigars — a deterministic Zig 0.16 MCP server distributed via an npm shim that downloads a prebuilt binary from GitHub releases. Read AGENTS.md first.

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
- No style nits unless they cause a real security, correctness, or maintenance defect.
- Output: findings ranked by severity (each with severity, VERIFIED/INFERRED, file:line, evidence, impact, concrete fix), then high-confidence "verified safe" areas, then test-coverage gaps.

Already known - do NOT report these as new; treat them as known and verify/deepen:
- Known-open IN YOUR AREA - confirm whether fixed or still present: npm cache poisoning - verifiedCachedExecutable (packages/@zigars/mcp/src/install.ts:94-100) returns the cached binary after checking only marker metadata and never re-hashes it against the stored marker.sha256 (written at install.ts:225), bypassing the download-time checksum. Also: checksum comparison is not constant-time (src/checksums.ts:61); zip-slip relies on tar's safe-by-default behavior with no negative test.
- Verified-safe from a prior pass (re-verify, report only NEW defects): download-path checksum is enforced and fails closed (install.ts:193-196); binary + tar spawned with shell:false (cli.ts, install.ts); unknown target fails closed (targets.ts); HTTPS host-pinned URLs (releases.ts); atomic install via mkdtemp->stage->rename; CI Actions are SHA-pinned.
- The shipped artifact is pure Zig, but CI scripts under .github/scripts use python3 - that is a separate session's concern; do not dwell on it here.

---
THIS SESSION: npm shim + MCPB distribution (the highest-value security surface).

Subagents: spawn 4 in parallel, one cluster each:
1. packages/@zigars/mcp/src/releases.ts + checksums.ts + bin/zigars-mcp.js  (download + verify path: URL construction, HTTPS pinning, redirect handling, checksum parsing/comparison)
2. packages/@zigars/mcp/src/install.ts  (cache validation, extraction, staging, file perms, atomic install, the cache-poisoning gap)
3. packages/@zigars/mcp/src/targets.ts + args.ts + cli.ts  (target/platform resolution, arg validation, process spawn, env passthrough)
4. packages/@zigars/mcpb/src/build.ts + packages/@zigars/skills/* + dist/ vs src/ parity + package.json/lockfiles

Hunt for: checksum verification correctness and fail-closed behavior on missing/mismatch (download AND cache paths); HTTPS/URL pinning with no http fallback and no attacker-controlled host/tag/version injection; redirect following to off-host locations; zip-slip / absolute-path / symlink escape during extraction; unsafe file permissions (chmod beyond the single binary); command/arg injection on spawn (argv array vs shell string, env passthrough); cache poisoning and verify-then-exec TOCTOU; unknown-target / unsupported-platform fail-safe. For each security-critical path, note whether a NEGATIVE test exists (checksum mismatch, malicious archive entry, unknown target).
