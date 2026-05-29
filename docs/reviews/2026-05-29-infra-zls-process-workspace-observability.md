# Infra Code Review — ZLS, Process, Workspace, Artifacts, Observability

- **Date:** 2026-05-29
- **Reviewer:** senior Zig/MCP systems engineer (Claude Code), 5 parallel subagents + manual re-verification
- **Build target:** Zig 0.16, ReleaseSafe
- **Scope:** `src/infra/zls/**`, `src/infra/process/**`, `src/infra/workspace/**`, `src/infra/artifacts/**`, `src/infra/observability/**`, `src/infra/toolchain/env.zig`, `src/infra/runtime_ux/**`

## Method

Five subagents reviewed non-overlapping file clusters. Every claim that affects ranking was then **personally re-read against source**: `workspace.zig`, `client.zig` (full), `transport.zig` (full), `command.zig`, `diagnostics_cache.zig`, `runtime_ux/state.zig`, `registry.zig`, plus grep-level checks for the dead-code and stdout-leak invariants.

- **VERIFIED** = I traced the exact code path myself.
- **INFERRED** = relayed from a subagent without a personal deep read (lower confidence).

## Invariants checked

- Workspace sandbox: every user-provided path resolves under the configured workspace before read/write.
- Source-mutating MCP tools require `apply=true`.
- stdout reserved for MCP JSON-RPC; all diagnostics/logs to stderr.
- MCP results structured (JSON `structuredContent` + text fallback).
- Shipped tree is pure Zig.

## Headline

The genuinely concurrent component (ZLS client) and the two hang/zombie-risk subsystems (command runner, diagnostics cache) are **correct** — the prior-pass "safe" verdicts hold under independent trace. **No Critical or High defect survived re-verification.** The subagents' one HIGH (workspace TOCTOU) was **downgraded to Medium** because it is not exploitable under this server's serial single-threaded dispatch. The clearest *actual* bug is a ring buffer that never rotates (M2).

---

## Findings (ranked)

### M1 — Workspace sandbox uses check-then-open on a path *string*; realpath-failure falls back to a lexical-only check

- **Severity:** Medium
- **Confidence:** VERIFIED (code pattern) · INFERRED-not-exploitable-today (threat model)
- **Location:** [`src/infra/workspace/workspace.zig:50-80`](../../src/infra/workspace/workspace.zig#L50), [`src/infra/workspace/workspace.zig:105-110`](../../src/infra/workspace/workspace.zig#L105)

`resolve()` returns a canonical path *string*; every consumer re-opens that string in a separate syscall:

```zig
pub fn readFileAlloc(self: Workspace, io, path, max_bytes) ![]u8 {
    const resolved = try self.resolve(path);        // realpath + isInside check
    defer self.allocator.free(resolved);
    return std.Io.Dir.cwd().readFileAlloc(io, resolved, ...);  // re-walks the string
}
```

On any realpath failure other than OOM, containment degrades to the lexical `isInside` at line 102:

```zig
const real = realPathFileAbsoluteOwned(allocator, io, resolved) catch |err| switch (err) {
    error.OutOfMemory => return error.OutOfMemory,
    else => { resolved_owned = false; return resolved; },   // lexical-only path returned
};
```

**Impact:** classic TOCTOU — between the realpath check and the open, a path component could be swapped for a symlink pointing outside the root, defeating *both* read and write containment (writes use `createFileAtomic` with default `follow_symlinks`).

**Why Medium, not High:** I could not construct an exploit under the current architecture. MCP dispatch is serial and single-threaded, so the MCP client cannot run code inside the resolve→open window to win the race. Pre-existing outside-pointing symlinks *are* caught (realpath resolves them, line 112). The lexical fallback only returns paths that already passed the lexical check, and an unresolved-symlink path that made realpath fail hits the same error on open. So this is a **defense-in-depth gap**, elevated in importance only because the sandbox is invariant #1. It becomes live if (a) dispatch ever becomes concurrent, or (b) an external process races the tree (such a process already has the user's privileges).

**Fix:** operate on a file descriptor, not a re-walked string — open the canonical parent dir then `openat`/create the final component with `O_NOFOLLOW`, or use the std `resolve_beneath: true` open option so the kernel enforces containment atomically. Treat realpath failure as fatal for inputs rather than returning a lexically-checked path.

---

### M2 — Job and subscription "rings" only ever churn slot 0 after capacity

- **Severity:** Medium
- **Confidence:** VERIFIED
- **Location:** [`src/infra/runtime_ux/state.zig:279-286`](../../src/infra/runtime_ux/state.zig#L279), [`src/infra/runtime_ux/state.zig:193-200`](../../src/infra/runtime_ux/state.zig#L193)

```zig
fn reserveJobSlot(self: *State) *JobRecord {
    if (self.job_count < self.jobs.len) { ... return slot; }
    return &self.jobs[0];          // every overflow returns slot 0
}
```

The docstring promises "overwriting the oldest slot after capacity," but slot 0 is the *newest* after the first wrap. `appendEvent` (line 266) correctly uses `ringIndex(sequence, max_events)` — these two do not.

**Impact:** after 32 jobs, slots 1-31 permanently pin jobs 2-32, while jobs 33, 34, 35… all overwrite slot 0. A long-lived server reports ancient jobs and loses nearly all recent ones via `zigars_job_status` / `job_result`. Subscriptions have the identical defect. No crash (fixed buffers; `jobById` still matches what is present), hence Medium.

**Fix:** use the same monotonic ring index as `appendEvent` so eviction actually picks the oldest slot.

---

### L1 — A single corrupt registry line disables the artifact subsystem; the known negative-`@intCast` is at line 367 (not 383)

- **Severity:** Low
- **Confidence:** VERIFIED
- **Location:** [`src/infra/artifacts/registry.zig:222-228`](../../src/infra/artifacts/registry.zig#L222), [`src/infra/artifacts/registry.zig:367`](../../src/infra/artifacts/registry.zig#L367); called from [`registry_store.zig:59,138`](../../src/infra/artifacts/registry_store.zig#L59)

`loadRegistry` runs at the top of every `put` / `recordWorkspace`, and any malformed line aborts the entire load:

```zig
var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});  // any bad line -> error
try registry.entries.append(allocator, try ownedEntryFromValue(allocator, parsed.value));
```

**Impact:** one bad line → `error.Unavailable` for all artifact writes (fail-closed, no corruption — the registry is written atomically so corruption is unlikely in normal operation), hence Low.

**Tracking correction:** the known-open negative-`@intCast` panic has **drifted to line 367** (`owned.bytes = @intCast(integerField(obj, "bytes")...)`); line 383 is now a string field. Same known issue, relocated — not re-reported as new.

**Fix:** skip-and-continue on a bad line; use `std.math.cast` for `bytes`.

---

### L2 — `edits.zig` is entirely dead code; its apply-gate / atomic-write invariant is unenforced

- **Severity:** Low (maintenance / false sense of safety)
- **Confidence:** VERIFIED
- **Location:** [`src/infra/zls/edits.zig`](../../src/infra/zls/edits.zig) (whole file)

`applyTextEdits` / `lspPositionToByteOffset` are referenced *only* by `edits_tests.zig` (grep-confirmed). The live edit path is `domain/editing/patch_session.zig`.

**Impact:** the carefully UTF-16-correct edit applier has zero production callers, and it writes nothing to disk — so the `apply=true` gate and atomic write are *not* enforced here. A future contributor wiring ZLS code-action apply to it would inherit an ungated writer assuming it is battle-tested. (For the record: its UTF-16 offset math, overlap rejection, and bounds checks are correct — it is simply unreachable.)

**Fix:** delete it, or if ZLS-driven edits are planned, route them through it and add the gate + atomic write at that call site.

---

### L3 — `documents.zig` retained-byte subtraction is unclamped (asymmetric with the cache)

- **Severity:** Low
- **Confidence:** VERIFIED
- **Location:** [`src/infra/zls/documents.zig:321`](../../src/infra/zls/documents.zig#L321), `:442`, `:452`

Raw `self.retained_content_bytes -= contentLen(...)`, whereas `diagnostics_cache.zig` deliberately clamps via `subtractBytesLocked`. No underflow on traced paths today, but a future accounting desync wraps to ~`usize.MAX` and spuriously trips `RetainedContentLimitExceeded` for all subsequent syncs.

**Fix:** mirror the cache's saturating subtraction.

---

### L4 — Latent / robustness (verified safe today)

| Item | Location | Status / Fix |
| --- | --- | --- |
| client.zig unguarded `zls_stdin/stdout` fields | [`client.zig:118,123,185`](../../src/infra/zls/client.zig#L118) vs `:415-419` | VERIFIED safe today: threads read their handle once at startup (happens-before the spawn); all other access is on the serial dispatch thread. Latent if a second thread calls `isRunning()`/a sender. Document the confinement invariant or guard with `write_mutex`. |
| transport.zig over-strict `Content-Length` | [`transport.zig:90-92`](../../src/infra/zls/transport.zig#L90) | Requires exactly `"Content-Length: "` and does not trim the value. Benign vs ZLS (canonical form); recoverable reader error, not a crash. Case-insensitive prefix + trim. |
| command_runner.zig duration metric uses wall-clock `.real` | [`command_runner.zig:74,152`](../../src/infra/process/command_runner.zig#L74) | Timeout *enforcement* uses monotonic `.awake` (verified); only the reported `duration_ms` on the error path is wall-clock, clamped to 0 at line 153 — cosmetic. Reuse the monotonic elapsed from `command.zig`. |
| audit.zig has no rotation | `src/infra/observability/audit.zig` | INFERRED (relayed). Append-only, no size cap; opt-in feature grows unbounded; once disk-full, appends fail and are correctly swallowed. Add size check + rollover. |
| uri.zig no `..`/sandbox validation | `src/infra/zls/uri.zig` | INFERRED (relayed). `uriToPath`/`resolvePath` do no validation but are fed only server-generated, already-resolved URIs today. Latent. |
| gateway request_counter non-atomic | [`gateway.zig:116`](../../src/infra/zls/gateway.zig#L116) | INFERRED (relayed). `counter.* += 1` is non-atomic but single-threaded today. Latent. |

---

## Verified-safe areas (re-verified against source)

- **ZLS client request/response correlation — correct.** `pending` map and `last_error` are consistently locked; the `pending_mutex → last_error_mutex` order is never inverted (line 391 takes last_error while holding pending; no reverse path), so no deadlock. The level-triggered `std.Io.Event` (registered at 194 *before* the write at 199) means a reader `set()` that fires before the waiter parks is not lost. Only the waiter destroys a `PendingRequest`, and store/take/remove all run under the lock, so no double-free or use-after-free even when a response lands at the timeout boundary. `next_id` is atomic.
- **Client teardown — no hang, no zombie, no thread leak.** `disconnect` sets `closing`, attempts bounded graceful shutdown, signals all waiters, closes the pipes (unblocking the reader's blocking read), then joins both threads ([`client.zig:406-432`](../../src/infra/zls/client.zig#L406)). Partial-init failure is cleaned by the caller's `errdefer`.
- **LSP framing — bounded.** Body capped at 10 MiB and header at 4 KiB *before* allocation; `readExact` loops for partial reads; the buffer persists across messages so coalesced reads are handled; `parseInt` overflow surfaces as a recoverable reader error. ([`transport.zig`](../../src/infra/zls/transport.zig))
- **Command runner — the four prior-pass claims all hold.** Monotonic `.awake` deadline; `child.kill` (which reaps) / `child.wait` exactly once on every exit path (no zombie); concurrent `MultiReader.fill` poll over both pipes (no stderr-fills-first deadlock); output bounded by *killing* the child on cap-hit. No `sh -c`. ([`command.zig`](../../src/infra/process/command.zig))
- **Diagnostics cache — byte accounting + concurrency correct.** Invariant `retained_bytes == Σ value.len` holds across insert/overwrite/evict; subtraction clamps at 0; eviction provably terminates; every method holds the leaf-level mutex; snapshots are deep-copied under the lock. ([`diagnostics_cache.zig`](../../src/infra/zls/diagnostics_cache.zig))
- **Workspace static containment — correct.** Prefix-sibling escape rejected (`isInside` requires a separator after the root, line 193); pre-existing outside-pointing symlinks caught by realpath (line 112); `..` collapsed and rejected lexically; user-supplied absolute paths re-checked.
- **stdout invariant — upheld.** No `getStdOut` / `stdout()` / `File.stdout` anywhere under `src/infra` (grep). Audit failures are swallowed to stderr/state, never propagated to fail a request (INFERRED, relayed).

---

## Test-coverage gaps (most material)

1. **No symlink-swap / TOCTOU test** for the workspace (inherent to M1; fixing via `resolve_beneath` makes it testable).
2. **No corrupt-registry tests** — malformed line, missing field, and especially `"bytes": -1` (the line-367 panic) are unexercised (L1).
3. **runtime_ux ring** — the test pushes only `max_jobs + 1` and asserts slot 0; pushing `max_jobs + 2` would have caught M2 immediately.
4. **ZLS client** — no concurrent reader-vs-timeout stress test, no cancellation-path test (`$/cancelRequest` / `error.Cancelled` never asserted), framing limits (`MessageTooLarge` / `HeaderTooLarge` / overflow) untested.
5. **Command runner** — no stderr-heavy concurrent-drain deadlock regression (stderr truncation is never tested), no post-timeout zombie-reap assertion, mid-run cancellation untested.
6. **Audit** — no append-to-real-file test; the disk-full → swallow path is uncovered.

---

## Out of scope / treated as known (not re-reported)

`argInt .float` panic (`usecase_support.zig:326`); reentrant dispatch (`protocol_client.zig:166`); npm cache poisoning (`packages/@zigars/mcp/src/install.ts:94`); `zig_code_action_batch` stub vs manifest; discovery tools text-only; negative `@intCast` (`patch_sessions.zig:848`, `artifacts/registry.zig` — now line 367, see L1); zon injection (`zon_dependencies.zig:193`); `audit.zig:101` non-atomic length+writePositional (latent only if dispatch becomes multi-threaded).
