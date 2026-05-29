# Security/Correctness Review — MCP server core, protocol lifecycle & transports

- **Date:** 2026-05-29
- **Scope:** `src/adapters/mcp/server.zig`; `src/adapters/mcp/server/{http_runner,http_transport,protocol_client,completion,pagination,tasks,resource_subscriptions,json_helpers}.zig`; `src/adapters/mcp/correlation.zig`; `src/adapters/mcp/resources.zig`; `src/adapters/mcp/prompts.zig`; `src/adapters/mcp/resource_errors.zig`; `src/domain/cancellation.zig`.
- **Method:** 4 parallel subagents with non-overlapping file scopes; every key claim independently re-verified against source by the lead reviewer before inclusion. Findings are marked **VERIFIED** (source re-read by the lead) or **INFERRED** (relied on subagent analysis not personally re-derived). The JSON-RPC wire framing lives in a vendored `mcp` package and is out of scope — only this code's *use* of it was reviewed.
- **Invariants checked:** workspace sandbox (every user path resolves under the workspace root before access); source-mutating tools require `apply=true`; stdout reserved for MCP JSON-RPC (diagnostics → stderr); structured MCP results (`structuredContent` + text fallback); pure-Zig shipped tree.
- **Build context:** server runs in ReleaseSafe, so a failed `@intCast`/`@intFromFloat`, `unreachable`, or `.?`-on-null panics and crashes the process (DoS).

## Headline

No Critical or High defect found in this surface. The workspace sandbox holds, stdout discipline holds, and the JSON-RPC error path does not leak paths or stack traces. **Two items the brief listed as known-open are actually already fixed** (verified below). The real issues are three Mediums — a broken retained-job eviction policy, no timeout on server→client protocol requests, and a missing HTTP origin/auth check — plus several Lows and test-coverage gaps. Two subagent severities were **downgraded** during re-verification (see notes inline).

### Brief's known-open items — both now STALE / FIXED (VERIFIED)

- **"Unguarded re-initialize resets state (server.zig:495)"** → fixed. `server.zig:449-461` rejects a second `initialize` while `state != .uninitialized` with `INVALID_REQUEST`; state and capabilities are not reset. Line 495 is now a `tasks/list` dispatch — the note predates this guard.

  ```zig
  if (std.mem.eql(u8, request.method, "initialize")) {
      if (self.state != .uninitialized) {
          self.logWithCorrelation(io, &request_correlation, "Server already initialized");
          request_is_error = true;
          const error_response = jsonrpc.createErrorResponse(
              request.id, jsonrpc.ErrorCode.INVALID_REQUEST, "Server already initialized", null);
          try self.sendResponse(io, allocator, .{ .error_response = error_response });
          return;
      }
  ```

- **"Reentrant dispatch via elicitation (protocol_client.zig:166)"** → fixed / does not persist. While a tool blocks awaiting an elicitation/sampling reply, an inbound *request* is routed to `rejectNestedRequest`, which only emits an `INVALID_REQUEST` error — it never calls `handleRequest`. No recursive tool dispatch, and nested elicitations cannot stack.

  ```zig
  // protocol_client.zig:166
  .request => |inbound_request| try rejectNestedRequest(server, io, allocator, inbound_request),
  .notification => |notification| try server.handleNotification(io, notification, data),
  ```

  `handleNotification` only mutates state/logs; `handleResponse`/`handleErrorResponse` only do `pending_requests.remove`. No path re-enters the dispatcher.

---

## Findings (ranked by severity)

### MEDIUM-1 — Retained-job buffer is not a ring; jobs beyond 32 are unobservable and `tasks/list` mis-orders after saturation — VERIFIED

`src/infra/runtime_ux/state.zig:279-286`

```zig
fn reserveJobSlot(self: *State) *JobRecord {
    if (self.job_count < self.jobs.len) {
        const slot = &self.jobs[self.job_count];
        self.job_count += 1;
        return slot;
    }
    return &self.jobs[0];   // once full: ALWAYS slot 0, never rotates
}
```

`max_jobs = 32`. Once `job_count == 32`, every new job overwrites slot 0; `job_count` never advances, so slots 1–31 freeze holding jobs #2–#32 forever while jobs #33+ each clobber the previous occupant of slot 0. The repo's own test documents it: after 33 jobs, `jobs[0] == "job-33"`, `job_count == 32` (`state.zig:435-436`). `tasks/list` iterates slot order (`tasks.zig:153`), so after saturation the list reads `[newest, job2, job3, …, job32]`, and a client polling a recent task by id (`tasks.zig:125` → `jobById` linear scan) loses it as soon as the next job starts.

- **Impact:** A developer running >32 background tasks cannot reliably retrieve results for the 33rd+ task (racy window before the next `startJob`), and the visible history is permanently stuck at jobs #2–#32. Correctness/usability defect in exactly the "retained-job ring eviction" the brief flagged. Not a crash; no security impact.
- **Note (subagent correction):** the cluster reviewer framed this primarily as a pagination skip/duplicate bug. That part is narrower than claimed — `job_count` is stable at 32 and slots 1–31 are frozen, so a paged sequence over indices ≥1 is consistent; only index 0 churns. The real defect is the eviction policy itself.
- **Fix:** Implement a true ring (track a head index, overwrite `jobs[head % max_jobs]`, advance head) and project `tasks/list` sorted by `created_sequence` (the field already exists, `state.zig:131`). If 32 is a hard cap, return an explicit "evicted" status for unknown-but-recent ids rather than a bare "Task not found".
- **Related (INFERRED, reachability unconfirmed):** `State.subscribe` at `state.zig:193-216` has the identical non-rotating-overwrite pattern (`slot = &self.subscriptions[0]` when full). The cluster reviewer reports the MCP `resources/subscribe` handler is a stateless ack that does not reach this path, so it may be dead from the protocol surface — worth confirming.

### MEDIUM-2 — No timeout on server→client protocol requests; the `timeout_ms` knob is dead — VERIFIED

`src/adapters/mcp/server/protocol_client.zig:106`

```zig
while (true) {
    const message_data = server.transport.?.receive(io, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EndOfStream => return .{ .supported = true, .used = false, .status = .timeout, ... },
        else => return .{ .supported = true, .used = false, .status = .timeout, ... },
    };
    // ...matching reply returns; non-matching request → rejectNestedRequest; notification → handleNotification...
}
```

The loop exits only on a matching reply, `EndOfStream`, null, a transport error, or malformed JSON. It never consults `ProtocolRequest.timeout_ms` (`src/app/ports.zig:62`, `timeout_ms: ?u64 = null`), and the only callers — elicitation (`tools/transactional_editing.zig:427`) and sampling (`tools/project_intelligence.zig:376`) — never set it. The field is entirely inert.

- **Impact:** Because the transport is serial/single-threaded, a tool that issues an elicitation (e.g. transactional-edit apply confirmation) wedges the **entire server** if the client never replies; if the client streams non-matching frames (so `EndOfStream` never fires) the loop also live-locks and grows the audit log. There is no recovery path, and the field that looks like the mitigation does nothing. In the local-dev threat model the client is the user's own agent, so this is a robustness/liveness gap, not a cross-principal DoS.
- **Note (subagent correction):** the cluster reviewer rated this **HIGH DoS**; downgraded to **MEDIUM** given the serial-transport baseline (a silent client can always stall a serial server) and local threat model — but the dead `timeout_ms` makes it a genuine bug, not merely inherent behavior.
- **Fix:** Honor `timeout_ms` with a deadline on `transport.receive` (or a clock check per iteration) and return `.status = .timeout`; give elicitation/sampling a sane default timeout.

### MEDIUM-3 — Built-in HTTP transport has no Origin/Host validation and binds non-loopback hosts as-given — VERIFIED

`src/adapters/mcp/server/http_runner.zig:18`

```zig
const bind_host = if (std.mem.eql(u8, config.host, "localhost")) "127.0.0.1" else config.host;
```

No `Origin`/`Host` header check exists anywhere in the runner, and there is no authentication. The default (`"localhost"` → `127.0.0.1`) is safe, but (a) any other configured host — e.g. `"0.0.0.0"` — is bound verbatim with zero auth, and (b) even on loopback, the absence of an `Origin` check leaves it open to DNS rebinding: a malicious web page can POST JSON-RPC `tools/call` to `127.0.0.1:<port>` and drive tools that read the workspace or run builds.

- **Impact:** Conditional on the HTTP transport being enabled (it is opt-in; stdio is the MCP default). When enabled, a real DNS-rebinding / unauthenticated-exposure vector.
- **Fix:** Validate `Origin`/`Host` against an allowlist (reject cross-origin), document loopback-only, and refuse non-loopback binds without an explicit opt-in flag.

### LOW-1 — Raw Zig error names leak into client-visible tool-error results — VERIFIED

`src/adapters/mcp/server.zig:778` puts `@errorName(err)` into the visible `content` text, and `src/adapters/mcp/errors.zig:64` adds it as `structuredContent.error`, alongside the already-safe coarsened `error_kind` (`errors.zig:65`, `kindForError`):

```zig
// errors.zig:62
pub fn valueFromError(allocator: std.mem.Allocator, spec: Spec, err: anyerror) !std.json.Value {
    var result_value = try value(allocator, spec);
    try result_value.object.put(allocator, "error", .{ .string = @errorName(err) });       // raw
    try result_value.object.put(allocator, "error_kind", .{ .string = kindForError(err) }); // safe
    return result_value;
}
```

- **Impact:** Information disclosure only. Zig `@errorName` yields a compile-time symbolic identifier (e.g. `FileNotFound`, an internal `ZlsHandshakeFailed`) — never a path, stack, or runtime data — so the disclosure ceiling is a fixed vocabulary of internal error names (mild fingerprinting). The raw `error` is redundant with the safe `error_kind`. Same pattern at `server.zig:914` (`resourceHandlerErrorValue`) and `server.zig:1085` (`promptHandlerErrorValue`).
- **Note (subagent correction):** the cluster reviewer rated this **HIGH** ("must NOT leak internal error names"). Downgraded to **LOW**: for a local dev-tool MCP server whose client is the user's own agent this is hygiene, not a vulnerability, and the symbolic-name ceiling bounds the disclosure.
- **Fix (cheap):** drop the raw `error`/`@errorName` text from client-visible fields and keep `error_kind`; retain `@errorName` only in the stderr log/audit (already done at `server.zig:739`).

### LOW-2 — `notifications/initialized` has no lifecycle guard — VERIFIED

`src/adapters/mcp/server.zig:1182-1184`

```zig
if (std.mem.eql(u8, notification.method, "notifications/initialized")) {
    self.state = .ready;
    self.logWithCorrelation(io, &notification_correlation, "Server initialized and ready");
}
```

This sets `state = .ready` unconditionally — even from `.uninitialized` (notifications skip the `.uninitialized` request guard at `server.zig:436`). A client can reach `.ready` without ever sending `initialize`, leaving `client_info`/capabilities at defaults.

- **Impact:** Robustness only — there is no post-shutdown resurrection, because the message loop stops reading once `.shutting_down` is set (`server.zig:342`).
- **Fix:** Honor the transition only when `state == .initializing`.

### LOW-3 — `tasks/result` duplicates raw, unnormalized job fields beside the spec `task` — VERIFIED

`src/adapters/mcp/server/tasks.zig:131-138`

```zig
try result.put(a, "task", try taskValue(a, job));      // status normalized to "working"
try result.put(a, "job_id", .{ .string = job.id });
try result.put(a, "status", .{ .string = job.status }); // raw internal "queued"/"running"
try result.put(a, "ok", .{ .bool = job.ok });
try result.put(a, "stdout_tail", .{ .string = job.stdout_tail });
```

- **Impact:** Contract inconsistency — the top-level `status` exposes internal vocabulary that disagrees with the normalized `task.status`. Cosmetic; the tails are the program's own captured output (not sensitive).
- **Fix:** Drop the raw duplicates or normalize them; keep the payload inside `task` / `structuredContent`.

### LOW-4 — Synchronous audit file I/O on the serial request hot path — VERIFIED (mechanism), opt-in

`appendAudit` runs inline on every inbound request and outbound message; the writer does `length()` + `writePositionalAll()` under a mutex. Failures are correctly swallowed and never reach stdout (`server.zig:1373-1380`):

```zig
fn appendAudit(self: *Self, allocator: std.mem.Allocator, event: audit.Event) void {
    const writer = self.audit_writer orelse return;
    writer.append(allocator, event) catch |err| {
        if (self.observability) |observability| observability.recordAuditWriteError(@errorName(err));
        return;
    };
    if (self.observability) |observability| observability.recordAuditWriteOk();
}
```

- **Impact:** Latency only, and only when audit is enabled (a slow/full disk stalls request processing). Cannot crash; never corrupts stdout.
- **Fix (optional):** batch/background the appends if forensic-mode latency matters.

### LOW-5 — Configured workspace root appears in a resource error detail — INFERRED

`src/adapters/mcp/resources.zig:203` (subagent claim, not personally re-read) embeds `context.workspace.root` (an absolute server path) in a client-visible error `details`. It is the server's *own* root, already exposed via `zigars://workspace`, so it leaks nothing new and is not the traversal target.

- **Fix (if zero absolute paths is desired):** emit the relative marker `"."`.

---

## Verified-safe areas

Re-read by the lead reviewer:

- **Workspace sandbox routing holds.** The dynamic-file resource passes the *raw* client path straight to `workspace_store.read` → `resolveInsideRoot` with no direct `std.fs` open and a 1 MiB cap; no URL-decoding, so `%2e%2e` cannot synthesize `..` (`src/app/usecases/runtime_ux/workflows.zig:454-458`). Artifact reads validate a 64-char lowercase-hex sha (`isSha256Hex`) then route through `workspace_store.resolve` + `read` (`resources.zig:289`, `:299`). `zigars://file/../../../etc/passwd/imports` → path `../../../etc/passwd` → rejected by the sandbox primitive.
- **stdout discipline holds.** No `std_options`/`logFn` override exists repo-wide, so `std.log` defaults to stderr; the only `std.log` call is HTTP-only (`http_runner.zig:33`). No `std.debug.print`/stdout writes in the core; `log`/`logError` route through `writeStderr`.
- **Lifecycle.** Post-shutdown requests are impossible — `handleShutdown` sets `.shutting_down` (`server.zig:627`) and `messageLoop` stops reading (`server.zig:342`); `.uninitialized` non-`initialize` requests → `SERVER_NOT_INITIALIZED` (`server.zig:436`).
- **Bounded structures.** `completed_requests` is a fixed `[64]` ring (`server.zig:97`); `pending_requests` is bounded by serial execution + nested-request rejection (one entry at a time, `defer`-removed at `protocol_client.zig:101`).
- **request-id handling.** `requestIdEqual` checks `kind` before comparing (no int/string conflation); `handleResponse`/`handleErrorResponse` ignore string ids and key pending on `i64`; outbound ids are server-minted monotonic `i64`. No `@intCast` on hostile ids.
- **HTTP framing.** Body bounded at 4 MiB; missing/zero/oversize `Content-Length` → 400, non-POST → 405, no-response → 204; error bodies are static strings (no leak); per-connection errors are caught without killing the accept loop (`http_runner.zig:32`).
- **`job_at` is bounds-checked** (`index >= job_count → null`, `tasks.zig:52`) — the broken eviction (MEDIUM-1) is a correctness bug, not an out-of-bounds read.

INFERRED-safe (subagent, high-confidence, not personally re-read):

- `pagination.fromParams` clamps limit ≤ 500 and rejects negative/garbage cursors with `InvalidCursor`.
- `completion` `total`/`has_more` honesty with a 100-entry cap; type-guarded JSON access throughout.
- `json_helpers` has no unchecked `.?`/`@intCast`; double-free guards on error paths are correct.
- `prompts.zig` arg handling is total (an injected `workflow` arg falls through to static default text, never echoed/allocated).
- `domain/cancellation.State` is race-free under the serial model and `defer`-restored within scope (consistent with the lifecycle verified above).
- `resources.zig` exposes only the two dynamic URI families (`zigars://file/`, `zigars://artifacts/`) plus pre-registered static resources — no generic `file://` read path.

---

## Test-coverage gaps

1. No test that the tool-handler `anyerror` fallback does **not** leak `@errorName` to client-visible `content`/`structuredContent` (LOW-1 regression guard).
2. No test that a nested inbound request during a pending elicitation is **rejected, not dispatched** — the core reentrancy guarantee is untested.
3. No timeout/never-reply test for `requestClientProtocol`; nothing asserts the wait loop can terminate without a matching reply or EOF (MEDIUM-2).
4. No `tasks/list`/`tasks/get` test that pages or polls **after 32 jobs** — the eviction behavior (MEDIUM-1) is only exercised at the unit level, never through the MCP handlers.
5. No `http_runner` tests at all (oversize/missing `Content-Length`, short-body read error, non-POST, 204 path), and none asserting the HTTP path emits nothing to stdout.
6. No test for `notifications/initialized` sent from `.uninitialized` or twice (LOW-2), nor that requests during `.initializing` behave as intended.
7. No traversal test at the **resources.zig dynamic-file layer** (`zigars://file/../../etc/passwd/imports`) or URL-encoded-URI pass-through — the only escape test targets the artifact path via a fake store; real protection lives in `workspace.zig`'s own tests (a layering/coverage gap, not an exposure).
