//! First-party MCP adapter surface: re-exports the registration, request
//! handling, correlation, error-mapping, schema, and result-projection modules.
//! Subsystem invariant: stdout is reserved for MCP JSON-RPC; logs go to stderr.
pub const args = @import("args.zig");
pub const artifacts = @import("tools/artifacts.zig");
pub const core = @import("tools/core.zig");
pub const correlation = @import("correlation.zig");
pub const dependencies = @import("tools/dependencies.zig");
pub const diagnostics = @import("tools/diagnostics.zig");
pub const discovery = @import("tools/discovery.zig");
pub const environment = @import("tools/environment.zig");
pub const errors = @import("errors.zig");
pub const handlers = @import("handlers.zig");
pub const prompts = @import("prompts.zig");
pub const registration = @import("registration.zig");
pub const registry = @import("registry.zig");
pub const result = @import("result.zig");
pub const observability = @import("tools/runtime_metrics.zig");
pub const performance = @import("tools/performance.zig");
pub const release = @import("tools/release.zig");
pub const profiling = @import("tools/profiling.zig");
pub const resources = @import("resources.zig");
pub const result_shape = @import("tools/result_shape.zig");
pub const runtime_ux = @import("tools/runtime_ux.zig");
pub const schema = @import("schema.zig");
pub const server = @import("server.zig");
pub const project_intelligence = @import("tools/project_intelligence.zig");
pub const static_analysis = @import("tools/static_analysis.zig");
pub const static_source_summary = @import("tools/static_source_summary.zig");
pub const transactional_editing = @import("tools/transactional_editing.zig");
pub const zls = @import("tools/zls.zig");

test {
    _ = @import("../../testing/mcp/adapter_tests.zig");
    _ = @import("../../testing/mcp/adapters/mcp/args_tests.zig");
    _ = @import("../../testing/mcp/adapters/mcp/errors_tests.zig");
    _ = @import("../../testing/mcp/adapters/mcp/resource_errors_tests.zig");
    _ = @import("../../testing/mcp/adapters/mcp/result_tests.zig");
    _ = @import("../../testing/mcp/adapters/mcp/root_tests.zig");
    _ = @import("../../testing/mcp/adapters/mcp/schema_tests.zig");
    _ = @import("../../testing/mcp/adapters/mcp/server/http_runner_tests.zig");
    _ = @import("../../testing/mcp/adapters/mcp/server/http_transport_tests.zig");
    _ = @import("../../testing/mcp/adapters/mcp/server/pagination_tests.zig");
    _ = @import("../../testing/mcp/adapters/mcp/tools/all_tests.zig");
}
