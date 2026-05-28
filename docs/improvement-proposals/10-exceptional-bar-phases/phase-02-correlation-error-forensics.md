# Phase 2 - Correlation And Error Forensics

Status: ready for implementation
Primary source sections:
[08 section 3.3](../08-exceptional-bar-action-plan.md#33-forensic-operation),
[09 section 5](../09-exceptional-bar-deep-research-findings.md#5-operational-research)

## Objective

Add request correlation that follows an inbound JSON-RPC request through MCP
tool result metadata, stderr diagnostics, structured errors, and observability
state. This phase should not add audit-log persistence or cancellation; those
belong to Phase 3.

## Ordered Tasks

### P2-T1 Define A Correlation Model

Add a small internal correlation model with:

- normalized MCP request id, preserving integer and string forms;
- `mcp_method`;
- `tool_name` when applicable;
- `trace_id`;
- `span_id`;
- optional `parent_span_id`;
- `tool_call_id`.

Acceptance criteria:

- The model can represent request ids that are integer, string, or absent.
- Generated IDs are deterministic in shape but not claimed stable across
  process restarts.
- Tests cover integer ids, string ids, notifications, and tool calls.

Likely files:

- `src/adapters/mcp/server.zig`
- `src/adapters/mcp/result.zig`
- new focused module under `src/adapters/mcp/` or `src/infra/observability/`

### P2-T2 Attach Correlation To Tool Results

Attach correlation in MCP result `_meta` using the key
`dev.zigars/correlation`. Do not duplicate these fields in every semantic
`structuredContent` object.

Target shape:

```json
{
  "_meta": {
    "dev.zigars/correlation": {
      "schema_version": 1,
      "mcp_request_id": { "type": "integer|string|null", "value": "42" },
      "mcp_method": "tools/call",
      "tool_name": "zig_build",
      "trace_id": "32 lowercase hex chars",
      "span_id": "16 lowercase hex chars",
      "parent_span_id": null,
      "tool_call_id": "zigars-tc-000000000001"
    }
  }
}
```

Acceptance criteria:

- Normal `tools/call` responses include correlation metadata.
- Error results include correlation metadata.
- Existing `structuredContent` content remains backward compatible.

### P2-T3 Add Correlation To Stderr Diagnostics

Update stderr logging so request-scoped diagnostics include a compact request
or trace identifier.

Acceptance criteria:

- stdout remains reserved for MCP JSON-RPC in server mode.
- Stderr logs for startup or request failures include enough correlation to
  match a result or audit record later.
- Tests or fixtures assert stdout/stderr separation where practical.

Likely files:

- `src/infra/observability/logging.zig`
- `src/adapters/mcp/server.zig`
- `src/bootstrap/runtime.zig`

### P2-T4 Attach Correlation To Structured Errors

Keep the existing structured error fields, then add correlation metadata at the
MCP result level.

Acceptance criteria:

- Existing error fields such as `kind`, `ok=false`, `tool`, `operation`,
  `phase`, `code`, `category`, `resolution`, and `error_kind` remain present
  where they already exist.
- No caller has to parse stderr to find the request id for an MCP-visible error.
- Tests cover argument errors and at least one expected runtime/backend error.

Likely files:

- `src/adapters/mcp/errors.zig`
- `src/app/errors.zig`
- `src/adapters/mcp/result.zig`

### P2-T5 Surface Correlation In Observability State

Record enough request correlation data for process-local observability tools to
connect latency/error counters to request ids or trace ids.

Acceptance criteria:

- Existing observability tools remain backward compatible.
- New fields are bounded and process-local; they do not persist transcripts.
- Tests cover bounded retention and reset-on-restart behavior where applicable.

Likely files:

- `src/infra/observability/state.zig`
- `src/app/usecases/observability/workflows.zig`
- `src/adapters/mcp/tools/runtime_metrics.zig`

## Out Of Scope

- No audit JSONL file.
- No cancellation token plumbing.
- No p99 histogram work.
- No broad parallel dispatch.

## Validation

```sh
zig fmt build.zig build.zig.zon src tools
zig build test
zig build docs-check json-check
```

If MCP smoke fixtures encode result shapes, update the smallest representative
fixture and run the relevant smoke target.
