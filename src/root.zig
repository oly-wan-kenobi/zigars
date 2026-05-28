//! Public root module re-exports architecture layers and wires cross-layer integration tests.
pub const adapters = @import("adapters/root.zig");
pub const app = @import("app/root.zig");
pub const bootstrap = @import("bootstrap/root.zig");
pub const domain = @import("domain/root.zig");
pub const infra = @import("infra/root.zig");
pub const manifest = @import("manifest/mod.zig");

test {
    _ = adapters;
    _ = app;
    _ = bootstrap;
    _ = domain;
    _ = infra;
    _ = manifest;
    _ = @import("testing/mcp/core_adapter_tests.zig");
    _ = @import("infra/observability/state_tests.zig");
    _ = @import("testing/mcp/server_tests.zig");
    _ = @import("testing/mcp/server_internal_tests.zig");
    _ = @import("testing/mcp/server_protocol_tests.zig");
    _ = @import("testing/mcp/server_task_tests.zig");
    _ = @import("testing/mcp/tool_call_memory_tests.zig");
    _ = @import("testing/mcp/handler_invariants.zig");
    _ = @import("testing/coverage_imports.zig");
    _ = @import("testing/manifest/static_analysis_contracts.zig");
    _ = @import("testing/infra/backend_probe_tests.zig");
    _ = @import("infra/zls/documents_tests.zig");
    _ = @import("infra/zls/client_tests.zig");
    _ = @import("testing/fakes/root.zig");
}
