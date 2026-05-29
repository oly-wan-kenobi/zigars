pub const artifact_store = @import("artifact_store.zig");
pub const backend_probe = @import("backend_probe.zig");
pub const clock_and_ids = @import("clock_and_ids.zig");
pub const command_runner = @import("command_runner.zig");
pub const common = @import("common.zig");
pub const docs_scanner = @import("docs_scanner.zig");
pub const observability_sink = @import("observability_sink.zig");
pub const runtime_session = @import("runtime_session.zig");
pub const static_cache = @import("static_cache.zig");
pub const tool_catalog = @import("tool_catalog.zig");
pub const tool_manifest_catalog = @import("tool_manifest_catalog.zig");
pub const toolchain_env = @import("toolchain_env.zig");
pub const workspace_store = @import("workspace_store.zig");
pub const workspace_scanner = @import("workspace_scanner.zig");
pub const zls_gateway = @import("zls_gateway.zig");

pub const FakeArtifactStore = artifact_store.FakeArtifactStore;
pub const FakeBackendProbe = backend_probe.FakeBackendProbe;
pub const FakeClockAndIds = clock_and_ids.FakeClockAndIds;
pub const FakeCommandRunner = command_runner.FakeCommandRunner;
pub const FakeDocsScanner = docs_scanner.FakeDocsScanner;
pub const FakeObservabilitySink = observability_sink.FakeObservabilitySink;
pub const FakeRuntimeSession = runtime_session.FakeRuntimeSession;
pub const FakeStaticCache = static_cache.FakeStaticCache;
pub const FakeToolCatalog = tool_catalog.FakeToolCatalog;
pub const FakeToolManifestCatalog = tool_manifest_catalog.FakeToolManifestCatalog;
pub const FakeToolchainEnv = toolchain_env.FakeToolchainEnv;
pub const FakeWorkspaceStore = workspace_store.FakeWorkspaceStore;
pub const FakeWorkspaceScanner = workspace_scanner.FakeWorkspaceScanner;
pub const FakeZlsGateway = zls_gateway.FakeZlsGateway;

test {
    _ = artifact_store;
    _ = backend_probe;
    _ = clock_and_ids;
    _ = command_runner;
    _ = common;
    _ = docs_scanner;
    _ = observability_sink;
    _ = runtime_session;
    _ = static_cache;
    _ = tool_catalog;
    _ = tool_manifest_catalog;
    _ = toolchain_env;
    _ = workspace_store;
    _ = workspace_scanner;
    _ = zls_gateway;
}
