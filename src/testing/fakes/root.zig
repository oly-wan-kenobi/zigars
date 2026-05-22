pub const artifact_store = @import("artifact_store.zig");
pub const backend_probe = @import("backend_probe.zig");
pub const clock_and_ids = @import("clock_and_ids.zig");
pub const command_runner = @import("command_runner.zig");
pub const common = @import("common.zig");
pub const observability_sink = @import("observability_sink.zig");
pub const workspace_store = @import("workspace_store.zig");
pub const zls_gateway = @import("zls_gateway.zig");

pub const FakeArtifactStore = artifact_store.FakeArtifactStore;
pub const FakeBackendProbe = backend_probe.FakeBackendProbe;
pub const FakeClockAndIds = clock_and_ids.FakeClockAndIds;
pub const FakeCommandRunner = command_runner.FakeCommandRunner;
pub const FakeObservabilitySink = observability_sink.FakeObservabilitySink;
pub const FakeWorkspaceStore = workspace_store.FakeWorkspaceStore;
pub const FakeZlsGateway = zls_gateway.FakeZlsGateway;

test {
    _ = artifact_store;
    _ = backend_probe;
    _ = clock_and_ids;
    _ = command_runner;
    _ = common;
    _ = observability_sink;
    _ = workspace_store;
    _ = zls_gateway;
}
