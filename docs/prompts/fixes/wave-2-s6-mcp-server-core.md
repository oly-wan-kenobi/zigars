# S6 — MCP server core: protocol timeout, HTTP origin, lifecycle/leak lows (Wave 2)

> **Cold-start session.** Repo `zigars`, **Zig 0.16**, **ReleaseSafe**. Read `AGENTS.md` first.
> Threat model is local-dev (the MCP client is the user's own agent), so these are
> robustness/liveness/hygiene, not cross-principal vulns — but they're real bugs.
> **Rules:** verify first · stay within *Files in scope* · regression test (fails before / passes
> after) · branch `git switch -c fix/mcp-server-core` · validate and report.

**Review:** `docs/reviews/2026-05-29-mcp-server-core-protocol-transports-review.md` —
MEDIUM-2, MEDIUM-3, LOW-1, LOW-2, LOW-5.

## Files in scope (only these)

- `src/adapters/mcp/server.zig`
- `src/adapters/mcp/errors.zig`
- `src/adapters/mcp/server/protocol_client.zig`
- `src/adapters/mcp/server/http_runner.zig`
- `src/adapters/mcp/resources.zig`
- `src/app/ports.zig` (the `timeout_ms` field only)

Do **not** touch `src/adapters/mcp/server/tasks.zig` or `src/infra/runtime_ux/state.zig` (owned by S7).

## Findings

1. **[MEDIUM-2] No timeout on server→client protocol requests; `timeout_ms` is dead**
   (`protocol_client.zig` ~106; field `ports.zig` ~62 `timeout_ms: ?u64 = null`). The receive loop
   exits only on a matching reply / `EndOfStream` / transport error, never consulting `timeout_ms`;
   the only callers (elicitation, sampling) never set it. A silent client wedges the entire serial
   server; a client streaming non-matching frames live-locks it and grows the audit log. **Fix:**
   honor `timeout_ms` with a deadline on `transport.receive` (or a clock check per iteration),
   returning `.status = .timeout`; give elicitation/sampling a sane default timeout.

2. **[MEDIUM-3] Built-in HTTP transport has no Origin/Host validation and binds non-loopback as-given**
   (`http_runner.zig` ~18). Default `localhost`→`127.0.0.1` is safe, but any other configured host
   (e.g. `0.0.0.0`) is bound verbatim with zero auth, and the missing `Origin` check leaves even
   loopback open to DNS-rebinding (`tools/call` from a malicious web page). HTTP is opt-in (stdio is
   default). **Fix:** validate `Origin`/`Host` against an allowlist (reject cross-origin), document
   loopback-only, and refuse non-loopback binds without an explicit opt-in flag.

3. **[LOW-1] Raw Zig error names leak into client-visible results** (`server.zig` ~778 →
   `errors.zig` ~64 puts `@errorName(err)` into `structuredContent.error` beside the safe coarsened
   `error_kind`; same at `server.zig` ~914 / ~1085). Disclosure ceiling is a fixed vocabulary of
   internal symbol names (mild fingerprinting), and the raw `error` is redundant with `error_kind`.
   **Fix:** drop the raw `error`/`@errorName` from client-visible fields; keep `error_kind`; retain
   `@errorName` only in the stderr log/audit (already done).

4. **[LOW-2] `notifications/initialized` has no lifecycle guard** (`server.zig` ~1182) — it sets
   `state = .ready` unconditionally, even from `.uninitialized` (notifications skip the request
   guard). **Fix:** honor the transition only when `state == .initializing`.

5. **[LOW-5] Configured workspace root in a resource error detail** (`resources.zig` ~203). Adjudicated
   **trivial/hygiene** — it's the server's own root, already exposed via `zigars://workspace`, leaks
   nothing new. **Fix (only if doing zero-absolute-paths):** emit the relative marker `"."` instead of
   the absolute root. Otherwise leave a one-line comment noting it's intentional and skip.

## Acceptance

- Tests: a never-replying / non-matching-frame-streaming client makes `requestClientProtocol`
  terminate via timeout; a cross-origin HTTP `tools/call` is rejected and a non-loopback bind without
  opt-in is refused; the `anyerror` fallback does **not** put `@errorName` into client-visible
  `content`/`structuredContent`; `notifications/initialized` from `.uninitialized` does not reach
  `.ready`.
- No `http_runner` tests exist today — add at least the origin/bind ones.
- `zig fmt build.zig build.zig.zon src tools` · `zig build test` · `zig build smoke` ·
  `zig build -Doptimize=ReleaseSafe` green. Report commands run.
