# Phase 3 - Audit, Cancellation, And Performance Evidence

Status: ready for implementation
Primary source sections:
[08 section 3.3](../08-exceptional-bar-action-plan.md#33-forensic-operation),
[08 section 5.3](../08-exceptional-bar-action-plan.md#53-full-parallel-dispatch),
[09 section 5](../09-exceptional-bar-deep-research-findings.md#5-operational-research)

## Objective

Build the second layer of forensic operation: opt-in audit JSONL, request
cancellation plumbing, startup phase timings, and latency percentile support.
Phase 2 request correlation should be in place first.

## Ordered Tasks

### P3-T1 Add Audit Configuration

Add startup configuration for:

- `--audit-log <path>`;
- `--audit-log-mode metadata|redacted|full`, defaulting to `metadata` when
  audit logging is enabled.

Acceptance criteria:

- Audit logging is off by default.
- Audit paths obey workspace/cache path policy chosen for this feature.
- Full mode requires an explicit flag and emits a stderr privacy warning.
- Config tests cover defaults, invalid modes, invalid paths, and explicit full
  mode.

Likely files:

- `src/bootstrap/config.zig`
- `src/bootstrap/config_tests.zig`
- `README.md` or `docs/trust.md`

### P3-T2 Implement Audit JSONL Writer

Write append-only JSONL records for request, response, notification, tool, and
startup events.

Required fields:

- `schema_version`;
- `ts_unix_ms`;
- `event`;
- `direction`;
- `transport`;
- `mcp_method`;
- normalized `mcp_request_id`;
- `correlation`;
- `tool_name` when applicable;
- `duration_ms` when known;
- `ok`;
- `is_error`;
- `payload` mode, hash, and size;
- `redactions`.

Acceptance criteria:

- Disabled mode creates no audit file.
- Metadata mode stores hashes and sizes, not raw request or response bodies.
- Redacted mode masks secret-looking keys and sensitive headers.
- Full mode records raw payloads only when explicitly configured.
- Audit write failures are reported to stderr and structured startup/runtime
  state without corrupting JSON-RPC stdout.

Likely files:

- new `src/infra/observability/audit.zig`
- `src/adapters/mcp/server.zig`
- `src/infra/observability/state.zig`

### P3-T3 Implement Request Cancellation Tokens

Handle MCP `notifications/cancelled` for normal requests by normalized
JSON-RPC id.

Acceptance criteria:

- Unknown, completed, and uncancellable request ids are ignored but observable.
- Long-running cooperative work can see a cancellation token.
- Command-backed calls terminate subprocesses where the command runner supports
  safe termination.
- ZLS-backed calls map to LSP `$/cancelRequest` where supported.
- Cancellation before a source write prevents the write.
- Cancellation during atomic apply finishes or fails with recovery evidence;
  it does not silently leave partial source edits.

Likely files:

- `src/adapters/mcp/server.zig`
- `src/app/ports.zig`
- command runner implementation modules
- `src/app/usecases/runtime_ux/workflows.zig`
- ZLS workflow modules under `src/app/usecases/zls/`

### P3-T4 Add Startup Phase Timings

Record monotonic startup timings for config parse, workspace resolution,
runtime state init, manifest/tool registration, resource/prompt registration,
ZLS spawn/initialize when configured, transport bind, server ready, and first
`initialize`.

Acceptance criteria:

- Timings are visible through an existing observability tool or a narrowly
  extended one.
- Startup timing fields are documented as runtime-specific.
- Tests cover at least serialization shape and phase ordering.

Likely files:

- `src/bootstrap/runtime.zig`
- `src/bootstrap/runtime_state.zig`
- `src/infra/observability/state.zig`
- `src/app/usecases/observability/workflows.zig`

### P3-T5 Add Latency Samples Or Histograms

Extend observability so p50/p95/p99 can be computed when enough samples exist.

Acceptance criteria:

- Samples are bounded per method, tool, and backend class.
- If sample count is too low, results say so instead of publishing misleading
  p99.
- Existing avg/max/last fields remain available or are migrated compatibly.

Likely files:

- `src/infra/observability/metrics.zig`
- `src/infra/observability/state.zig`
- `src/app/usecases/observability/workflows.zig`

### P3-T6 Add `docs/perf.md`

Create the first performance evidence page.

Acceptance criteria:

- It documents startup phases and latency fields.
- It gives initial budgets only where measurement exists.
- It states that startup and latency data are process-local and
  runtime-specific.

## Out Of Scope

- Do not add broad concurrent tool dispatch.
- Do not persist complete request history unless audit logging is explicitly
  enabled.
- Do not implement MCP tasks unless they are already available and needed for a
  minimal cancellation test.

## Validation

```sh
zig fmt build.zig build.zig.zon src tools
zig build test
zig build docs-check json-check
```

Add focused HTTP or stdio smoke fixture updates if result or notification
behavior changes at the protocol boundary.
