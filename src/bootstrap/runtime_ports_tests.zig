const std = @import("std");
const runtime_mod = @import("runtime_state.zig");
const subject = @import("runtime_ports.zig");
const Options = subject.Options;
const RuntimePorts = subject.RuntimePorts;

test "runtime ports wire reusable infra adapters into app context" {
    var runtime = runtime_mod.App{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .config = .{
            .workspace = "/workspace",
            .zig_path = "/bin/zig",
            .zls_path = "/bin/zls",
            .zflame_path = "/bin/zflame",
            .diff_folded_path = "/bin/diff-folded",
        },
        .workspace = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .root = "/workspace",
            .cache_root = "/workspace/.zigars-cache",
        },
    };

    var runtime_ports = RuntimePorts.init(&runtime, .{ .record_command_observability = true });
    const ctx = runtime_ports.context();
    try std.testing.expect(ctx.ports.command_runner != null);
    try std.testing.expect(ctx.ports.workspace != null);
    try std.testing.expect(ctx.ports.backend_probe != null);
    try std.testing.expect(ctx.ports.analysis_cache != null);
    try std.testing.expect(ctx.ports.semantic_index_cache != null);
    try std.testing.expect(ctx.ports.toolchain_env != null);
    try std.testing.expect(ctx.ports.docs_scanner != null);
    try std.testing.expect(ctx.ports.artifact_store != null);
    try std.testing.expect(ctx.ports.runtime_session != null);
    try std.testing.expect(ctx.ports.tool_catalog != null);
    try std.testing.expect(ctx.ports.clock_and_ids != null);
    try std.testing.expect(ctx.ports.zls_gateway != null);
    try std.testing.expect(ctx.ports.observability_reader != null);
    try std.testing.expectEqualStrings("/bin/zig", (try runtime_ports.coreContext()).tool_paths.zig);
}
