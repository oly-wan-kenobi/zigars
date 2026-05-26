//! Zig toolchain-facing domain APIs (analysis, contracts, and output parsing).
pub const analysis = @import("analysis.zig");
pub const backend_catalog = @import("backend_catalog.zig");
pub const backend_contracts = @import("backend_contracts.zig");
pub const compiler_output = @import("compiler_output.zig");
pub const static_analysis_contracts = @import("static_analysis_contracts.zig");

test {
    _ = analysis;
    _ = backend_catalog;
    _ = backend_contracts;
    _ = compiler_output;
    _ = static_analysis_contracts;
    _ = @import("analysis_tests.zig");
    _ = @import("backend_catalog_tests.zig");
    _ = @import("backend_contracts_tests.zig");
    _ = @import("compiler_output_tests.zig");
    _ = @import("static_analysis_contracts_tests.zig");
}
