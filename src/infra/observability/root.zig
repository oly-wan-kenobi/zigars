//! Observability subsystem public surface: metrics reader, audit writer, and
//! state primitives for the current server process.  All output goes to stderr
//! or to the configured audit file; stdout is reserved for MCP JSON-RPC.

pub const metrics = @import("metrics.zig");
pub const audit = @import("audit.zig");

const logging_tests = @import("logging_tests.zig");
const metrics_tests = @import("metrics_tests.zig");

test {
    _ = metrics;
    _ = audit;
    _ = logging_tests;
    _ = metrics_tests;
}
