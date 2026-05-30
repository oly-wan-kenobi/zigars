//! Slim shared entrypoint for the integration smoke suite. Re-exports the
//! focused helpers from `common/` so fixture files use a single `smoke.*`
//! import surface. The actual logic lives in the sibling modules; only add
//! policy here when it applies uniformly across HTTP and stdio fixtures.

const json_query = @import("../common/json_query.zig");
const smoke_assert = @import("common/smoke_assert.zig");
const smoke_http = @import("common/smoke_http.zig");
const smoke_port = @import("common/smoke_port.zig");

/// JSON path lookup shared with the contract fixtures.
pub const valueAt = json_query.valueAt;

/// Base port used by deterministic loopback-port selection.
pub const port_base = smoke_port.port_base;
/// Search window used by deterministic loopback-port selection.
pub const port_window = smoke_port.port_window;
/// Real-clock nanosecond timestamp helper for temporary workspace names.
pub const nowNs = smoke_port.nowNs;
/// Deterministic port candidate helper for retry loops.
pub const candidatePort = smoke_port.candidatePort;
/// Live bind-probe helper that returns a currently-free loopback port.
pub const reserveLoopbackPort = smoke_port.reserveLoopbackPort;
/// Best-effort deterministic port picker retained for callers without retry logic.
pub const pickPort = smoke_port.pickPort;

/// Parsed HTTP `tools/call` envelope returned by smoke helpers.
pub const ToolCallResult = smoke_http.ToolCallResult;
/// Calls an HTTP MCP tool and returns the parsed tool envelope.
pub const callHttpTool = smoke_http.callHttpTool;
/// Calls an HTTP MCP tool and returns the structured content object.
pub const callHttpToolJson = smoke_http.callHttpToolJson;
/// Asserts whether the parsed tool envelope was marked as an MCP tool error.
pub const expectToolIsError = smoke_http.expectToolIsError;
/// Sends a JSON-RPC request over HTTP and returns the response bytes.
pub const rpc = smoke_http.rpc;
/// Sends a raw HTTP request to the smoke server and returns the response bytes.
pub const rawHttp = smoke_http.rawHttp;
/// Asserts that a raw HTTP response contains an expected byte sequence.
pub const assertRawHttpContains = smoke_http.assertRawHttpContains;
/// Asserts that an HTTP JSON-RPC response contains an expected byte sequence.
pub const assertHttpRpcContains = smoke_http.assertHttpRpcContains;

/// Converts fixture-relative paths into absolute paths for smoke requests.
pub const absolutePath = smoke_assert.absolutePath;
/// Finds a named tool in a `tools/list` response.
pub const findTool = smoke_assert.findTool;
/// Recursively compares JSON values and reports the failing path.
pub const expectJsonEq = smoke_assert.expectJsonEq;
/// Asserts that a fixture path was not created by a negative scenario.
pub const expectFileAbsent = smoke_assert.expectFileAbsent;
/// Compares strings with a labeled diagnostic on mismatch.
pub const expectStringEq = smoke_assert.expectStringEq;
/// Enforces scenario-count floors for broad smoke coverage.
pub const assertMinimumCount = smoke_assert.assertMinimumCount;
/// Shared stderr diagnostic helper for fixture assertions.
pub const stderrPrint = smoke_assert.stderrPrint;

test {
    _ = smoke_assert;
    _ = smoke_http;
    _ = smoke_port;
}
