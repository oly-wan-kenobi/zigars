const tool_manifest = @import("zigar").tool_manifest;

const agent = @import("tools/agent.zig");
const artifacts = @import("tools/artifacts.zig");
const ci = @import("tools/ci.zig");
const core = @import("tools/core.zig");
const discovery = @import("tools/discovery.zig");
const docs = @import("tools/docs.zig");
const edit_zls = @import("tools/edit_zls.zig");
const edit_zls_diagnostics = @import("tools/edit_zls_diagnostics.zig");
const observability = @import("tools/observability.zig");
const profiling = @import("tools/profiling.zig");
const release_drift = @import("tools/release_drift.zig");
const result_shape = @import("tools/result_shape.zig");
const static_analysis = @import("tools/static_analysis.zig");
const trust = @import("tools/trust.zig");
const zwanzig = @import("tools/zwanzig.zig");

pub const ToolHandler = tool_manifest.ToolHandler;

pub fn handlerFor(comptime id: tool_manifest.ToolId) ToolHandler {
    return handler(tool_manifest.entryFor(id).handler);
}

fn handler(comptime ref: tool_manifest.HandlerRef) ToolHandler {
    return switch (ref.module) {
        .discovery => @field(discovery, ref.name),
        .agent => @field(agent, ref.name),
        .artifacts => @field(artifacts, ref.name),
        .core => @field(core, ref.name),
        .edit_zls => @field(edit_zls, ref.name),
        .edit_zls_diagnostics => @field(edit_zls_diagnostics, ref.name),
        .docs => @field(docs, ref.name),
        .static_analysis => @field(static_analysis, ref.name),
        .ci => @field(ci, ref.name),
        .observability => @field(observability, ref.name),
        .zwanzig => @field(zwanzig, ref.name),
        .profiling => @field(profiling, ref.name),
        .trust => @field(trust, ref.name),
        .result_shape => @field(result_shape, ref.name),
        .release_drift => @field(release_drift, ref.name),
    };
}

test "all manifest handler references resolve to functions" {
    inline for (tool_manifest.entries) |entry| {
        _ = handler(entry.handler);
    }
}
