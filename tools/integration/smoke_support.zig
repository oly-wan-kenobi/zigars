//! Slim shared entrypoint for the integration smoke suite. Re-exports the
//! focused helpers from `common/` so fixture files use a single `smoke.*`
//! import surface. The actual logic lives in the sibling modules; only add
//! policy here when it applies uniformly across HTTP and stdio fixtures.

const json_query = @import("../common/json_query.zig");
const smoke_assert = @import("common/smoke_assert.zig");
const smoke_http = @import("common/smoke_http.zig");
const smoke_port = @import("common/smoke_port.zig");

// JSON path lookup shared with the contract fixtures.
pub const valueAt = json_query.valueAt;

// Deterministic loopback-port selection (LOW-9). See `common/smoke_port.zig`.
pub const port_base = smoke_port.port_base;
pub const port_window = smoke_port.port_window;
pub const nowNs = smoke_port.nowNs;
pub const candidatePort = smoke_port.candidatePort;
pub const reserveLoopbackPort = smoke_port.reserveLoopbackPort;
pub const pickPort = smoke_port.pickPort;

// No-panic HTTP request + `tools/call` envelope helpers. See `common/smoke_http.zig`.
pub const ToolCallResult = smoke_http.ToolCallResult;
pub const callHttpTool = smoke_http.callHttpTool;
pub const callHttpToolJson = smoke_http.callHttpToolJson;
pub const expectToolIsError = smoke_http.expectToolIsError;
pub const rpc = smoke_http.rpc;
pub const rawHttp = smoke_http.rawHttp;
pub const assertRawHttpContains = smoke_http.assertRawHttpContains;
pub const assertHttpRpcContains = smoke_http.assertHttpRpcContains;

// Assertion, path, and filesystem-gating helpers. See `common/smoke_assert.zig`.
pub const absolutePath = smoke_assert.absolutePath;
pub const findTool = smoke_assert.findTool;
pub const expectJsonEq = smoke_assert.expectJsonEq;
pub const expectFileAbsent = smoke_assert.expectFileAbsent;
pub const expectStringEq = smoke_assert.expectStringEq;
pub const assertMinimumCount = smoke_assert.assertMinimumCount;
pub const stderrPrint = smoke_assert.stderrPrint;

test {
    _ = smoke_assert;
    _ = smoke_http;
    _ = smoke_port;
}
