# Runtime Observability And Audit

zigars keeps runtime observability process-local by default. Metrics reset when
the server restarts, and full request history is not retained unless opt-in
audit logging is enabled.

## Audit JSONL

Audit logging is off by default. Enable it with a workspace-scoped output path:

```sh
zigars --workspace /path/to/project --audit-log .zigars-cache/audit.jsonl
```

Enabled audit logging defaults to `metadata` mode. Metadata records JSONL events
for inbound and outbound MCP messages with method, request id, correlation
metadata, payload size, and payload SHA-256. It does not write raw payload text.

`--audit-log-mode redacted` parses JSON payloads and masks secret-looking fields
such as tokens, passwords, cookies, and API keys. Invalid JSON payloads are not
recorded raw in redacted mode.

`--audit-log-mode full` records raw MCP payloads. It requires the explicit flag
and prints a stderr privacy warning during startup. Use it only for intentional
local forensic debugging because MCP payloads can include prompts, file paths,
tool arguments, and tool results.

Audit logs are appended to the configured workspace path. stdout remains
reserved for MCP JSON-RPC in server mode.

## Cancellation

zigars accepts MCP `notifications/cancelled` messages and reuses the request
correlation model for request-id matching. Cancellation is cooperative: active
tool calls expose a request-scoped token to command, workspace-write, and ZLS
request ports. Unknown, already-completed, malformed, or non-cancellable targets
are counted in runtime metrics instead of creating a second request identity
system.

The server still dispatches tools sequentially. Cancellation support is
cooperative and does not imply broad concurrent tool execution.

## Startup And Latency Metrics

`zigars_metrics_v2` includes startup phase timings, audit status, cancellation
counters, MCP method latency, tool latency, command duration samples, and
bounded percentile summaries. Percentiles are withheld until enough samples are
retained, and all samples are bounded process-local rings.
