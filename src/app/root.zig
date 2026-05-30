//! App-layer public surface: the single import seam transports and adapters use
//! to reach context, ports, error contracts, result contracts, and usecases.
//! `result_shape` is JSON-builder helper code consumed by adapters directly, so
//! it is only pulled in here for test aggregation, not re-exported.
pub const context = @import("context.zig");
pub const errors = @import("errors.zig");
pub const ports = @import("ports.zig");
pub const result_contracts = @import("result_contracts.zig");
pub const usecases = @import("usecases/root.zig");

const context_tests = @import("context_tests.zig");
const errors_tests = @import("errors_tests.zig");
const ports_tests = @import("ports_tests.zig");
const result_contracts_tests = @import("result_contracts_tests.zig");
const result_shape_tests = @import("result_shape_tests.zig");

test {
    _ = context;
    _ = errors;
    _ = ports;
    _ = result_contracts;
    _ = usecases;
    _ = context_tests;
    _ = errors_tests;
    _ = ports_tests;
    _ = result_contracts_tests;
    _ = result_shape_tests;
}
