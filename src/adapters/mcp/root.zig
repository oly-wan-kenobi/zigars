pub const args = @import("args.zig");
pub const artifacts = @import("tools/artifacts.zig");
pub const core = @import("tools/core.zig");
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
    _ = @import("server/http_transport.zig");
}

test {
    _ = args;
    _ = artifacts;
    _ = core;
    _ = dependencies;
    _ = diagnostics;
    _ = discovery;
    _ = environment;
    _ = errors;
    _ = handlers;
    _ = prompts;
    _ = registration;
    _ = registry;
    _ = result;
    _ = observability;
    _ = performance;
    _ = release;
    _ = profiling;
    _ = resources;
    _ = result_shape;
    _ = runtime_ux;
    _ = schema;
    _ = server;
    _ = project_intelligence;
    _ = static_analysis;
    _ = static_source_summary;
    _ = transactional_editing;
    _ = zls;
}
