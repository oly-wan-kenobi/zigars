# Zigars Deep Review (5-agent pass) — Verified Findings

**Date:** 2026-05-29
**Method:** five parallel subagents (server core / tool-handlers+manifest / app+domain / infra / npm-shim+build), each briefed to skip already-fixed areas. Every finding below was re-verified against source by the lead reviewer. Severities are the lead's calibration. The full suite passes (948/948) at the reviewed commit.

---

## HIGH

### H1 — Crafted float arg panics the whole server (DoS)
**VERIFIED** · `src/app/usecases/usecase_support.zig:326`

```zig
.float => |f| @intFromFloat(f),   // unguarded
```

`argInt` is called with raw client args across many live tools — `limit` (`zig_bench_discover`, `zig_samply_summary`, `zig_tracy_plan`, diagnostics, release CI), `port`/`seconds` (`zig_tracy_capture`), `threshold_pct`/`min_line_rate_bp` (coverage), `timeout_ms` (via `toolTimeout`, usecase_support.zig:341). A JSON number that parses as `.float` with magnitude > i64 (e.g. `{"limit": 1e308}`) hits `@intFromFloat` → **out-of-bounds panic in ReleaseSafe**, crashing the process. The `@max(@min(...))` clamps run *after* the cast. Adapter-local `argInt`s are `.integer`-only (safe); this is specifically the app-layer path. Same idiom at `src/domain/performance/coverage_model.zig:188`, `src/app/usecases/performance/workflows.zig:1097`. Reproduced at runtime.

**Fix:** guard before cast — `if (!std.math.isFinite(f) or f > maxInt(i64) or f < minInt(i64)) return default;` (or `std.math.lossyCast`). Sweep the three sites. Add an out-of-range-float test (the current test only covers an in-range `7.x`).

---

## MEDIUM

### M1 — Reentrant dispatch → unbounded recursion + serial-invariant break — FIXED
**VERIFIED · FIXED** · `src/adapters/mcp/server/protocol_client.zig:166`, reachable via `src/adapters/mcp/tools/transactional_editing.zig:193`

> **Fixed:** inbound requests received while awaiting a protocol-helper reply are
> now rejected rather than dispatched — `protocol_client.zig:188` calls
> `rejectNestedRequest` (defined at `:194`) on a `.request`, so no nested tool
> execution occurs and the serial-execution invariant holds.

`zigars_patch_session_apply` (apply=true) calls `requestApplyElicitation`, which blocks in the protocol-client receive loop. That loop dispatches any inbound request recursively: `.request => try server.handleRequest(...)`. There is no depth guard. A client that sends another `tools/call` instead of the elicitation reply gets nested tool execution — repeatable to native-stack overflow (crash), and it violates the serial-execution invariant that the (just-made-honest) cancellation design relies on.

**Fix:** while awaiting a protocol-helper reply, queue/reject inbound requests instead of dispatching them; or add a hard nesting-depth cap.

### M2 — npm shim cache poisoning: cached binary run without checksum re-verification — FIXED
**VERIFIED · FIXED** · `packages/@zigars/mcp/src/install.ts:94-100` (stored-but-unused hash at `:225`)

> **Fixed:** `verifiedCachedExecutable` now re-hashes the cached binary and
> compares it against the marker — `sha256Equals(sha256(executableBytes),
> marker.sha256)` (`install.ts:107`) — and fails closed on mismatch/missing, so
> the cache short-circuit no longer bypasses checksum verification.

`verifiedCachedExecutable` returns the cached binary after checking only marker *metadata* (version/archiveName/executableName) and `isFile()`. It writes `sha256` into the marker (`:225`) but **never re-hashes the cached binary against it**, and `installZigars` returns the cached path (`:188`) before any download/verify. The download path *does* verify and fail closed (`:196`), so the cache short-circuit is the bypass. A writer of the cache dir (e.g. `ZIGARS_MCP_CACHE_DIR` on a shared path, or another same-user process) drops a malicious binary + marker → code execution on next launch. Half-implemented control: the hash is stored but the check is missing.

**Fix:** in `verifiedCachedExecutable`, read the binary and compare `sha256(bytes) === marker.sha256`; fail closed on mismatch/missing.

### M3 — `zig_code_action_batch`: inert stub advertised as a destructive ZLS mutator
**VERIFIED** · handler `src/adapters/mcp/tools/transactional_editing.zig:169` vs manifest `src/manifest/definitions/transactional_editing.zig:135-142`

Handler signature is `(allocator, context, _: ?std.json.Value)` — args discarded; it only checks `zls_state.running` and returns a hardcoded "unavailable" value. The manifest declares 6 **required** fields + `risk{writes_source, writes_require_apply, preview_by_default, mutates_lsp_state, executes_backend}` + `apply_gated_mutation`. With the just-fixed `destructiveHintFor`, this now advertises a **destructive, source-writing, apply-gated** tool that does nothing.

**Fix:** strip the required fields + source/LSP risk to match the stub (or implement it). This is the same drift class fixed for `zig_rename`/`zig_code_action_apply` but missed here.

### M4 — Three discovery tools return text-only results (no `structuredContent`)
**VERIFIED** · `src/adapters/mcp/tools/discovery.zig:12-19,73-81`

`zigars_capabilities`, `zigars_tool_index` (→ `zigarsCapabilities`), and `zigars_schema` call `jsonTextOnly`, which returns `.{ .content = content }` with no `structuredContent` — violating the repo-wide "structured + text fallback" rule that every other handler follows via `mcp_result.structured`. (`zigars_schema` also emits the *identical* catalog as `zigars_capabilities`, contradicting its "schema-discovery hints" description.)

**Fix:** route these through `mcp_result.structured`.

### M5 — `@intCast` of negative on-disk int → panic
**VERIFIED** · `src/app/usecases/editing/patch_sessions.zig:848`, `src/app/usecases/artifacts/registry.zig:383`

`@intCast(integerField(obj,"bytes") ...)` to `usize` panics on a negative value read from `.zigars-cache` JSON (patch-session history / artifact registry). Not directly protocol-reachable (the server writes these files), but a corrupted/tampered cache file crashes `revert`/registry reads. A safe sibling pattern `@intCast(@max(x,0))` exists elsewhere.

**Fix:** `@intCast(@max(integerField(...) orelse 0, 0))` or reject negatives as malformed.

### M6 — zon manifest injection via unescaped fields — FIXED
**VERIFIED · FIXED** · `src/domain/zig/zon_dependencies.zig:193`

> **Fixed:** `addDependency` now validates inputs before interpolation —
> `requireSafeDependencyName(name)` (`zon_dependencies.zig:190`) plus
> `requireSafeStringLiteralField` on `url`/`hash`/`path` (`:193`–`:195`) reject
> quotes, backslashes, and newlines, closing the breakout into the zon literal.

`url`/`name`/`hash`/`path` from tool args are interpolated raw into a zon string literal; a `"`, `\`, or newline breaks out and injects arbitrary zon into `build.zig.zon`. Apply-gated + diff-previewed, so bounded — but an auto-applying agent corrupts the manifest or injects an unintended dependency.

**Fix:** reject `"`/`\`/newline (and validate `name` as an identifier), or emit via a proper zon string escaper.

---

## LOW (verified)

- **L1 — FIXED** Unguarded re-`initialize` resets `state` to `.initializing` and overwrites client info/capabilities mid-session (`src/adapters/mcp/server.zig:495`); the spec says once-only. Bounded impact. Fix: reject when `state != .uninitialized`. **Fixed:** `initialize` now rejects when `self.state != .uninitialized` and replies "Server already initialized" (`src/adapters/mcp/server.zig:447`).
- **L2** `zig_diagnostics`/`zig_diagnostics_all` plan says `textDocument/publishDiagnostics` but the handler issues `textDocument/diagnostic` (`src/adapters/mcp/tools/zls.zig:172` vs `src/manifest/definitions/zls.zig:49,58`). **Note:** the earlier metadata-alignment change made the two strings match each other, but both still mismatch the actual request method — the correct value is `textDocument/diagnostic`.
- **L3** `zig_document_change` advertises `didChange` but the handler performs/labels `didOpen` (`src/adapters/mcp/handler_refs.zig:341`, hardcoded literals in `zls.zig`).
- **L4** Pagination cursors are plain decimal offsets; a malformed/negative cursor silently serves page 0 instead of `INVALID_PARAMS`, and offsets are unstable under list mutation (`src/adapters/mcp/server/pagination.zig:18`).
- **L5** `completion/complete` reports `total` = returned count (capped at 100), understating matches when `hasMore` (`src/adapters/mcp/server/completion.zig:88`).
- **L6 — FIXED** Checksum comparison is not constant-time (`packages/@zigars/mcp/src/checksums.ts:61`); low practical impact (hash of attacker-supplied data). **Fixed:** comparisons now go through `sha256Equals` (used by the install/cache path, `packages/@zigars/mcp/src/install.ts:107`).
- **L7** `src/infra/observability/audit.zig:101` does `length()`+`writePositionalAll` non-atomically — latent torn-write only if request dispatch ever becomes multi-threaded.

**Notes (not defects):** download integrity rests on GitHub release integrity (no client-side attestation verification — common, acceptable); zip-slip is mitigated by `tar` defaults but has no negative test (INFERRED); CI shell scripts use `python3` heredocs — the "pure Zig, no Python" rule only holds for the shipped tree (**done in S14:** AGENTS.md and `docs/release.md` now scope the ban to the `.py`-extension gate and acknowledge the vetted CI heredocs); `next_request_id`/transport trailing-`%X` are theoretical only.

---

## Verified safe (notable)

- **ZLS concurrency is sound** — `disconnect()` joins both threads before pending teardown; request waits use a 50 ms `waitTimeout` loop on a monotonic deadline (no lost wakeup/hang); lock ordering consistent (no deadlock); ids atomic-monotonic; subprocess killed/reaped once. The prior pass's thread-cleanup/timeout claims hold.
- Command runner hardened (argv arrays/no shell, monotonic timeout, kill+reap, concurrent pipe drain, bounded output); workspace sandbox sound; `resources/read` URI traversal enforced downstream; download-path checksum fails closed; `shell:false` everywhere; unknown target fails closed; HTTPS host-pinned; CI Actions SHA-pinned; pagination boundary math safe; JSON-RPC error codes correct; diagnostics-cache byte accounting saturates; `structured()` deep-copies (arena-safe).

## Coverage gaps

Out-of-range float in `argInt`; negative ints in patch-session/registry parsing; timeout-then-late-response ZLS race; cache-checksum-mismatch and zip-slip negative tests in the npm shim.

## Suggested fix order

1. **H1** (one-line guard, sweep 3 sites) — stops a trivial client-triggered crash.
2. **M2** (cache checksum re-verify) — closes the code-exec bypass.
3. **M1** (reentrancy guard) — prevents the recursion crash.
4. **M3/M4** (manifest/result-shape fidelity) — small, mechanical.
5. **M5/M6** (defensive casts + zon escaping).
6. LOWs as convenient; L2 corrects the lingering plan-metadata inaccuracy.
