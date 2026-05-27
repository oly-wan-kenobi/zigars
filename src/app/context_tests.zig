const std = @import("std");

const app_context = @import("context.zig");
const ports = @import("ports.zig");

const BackendProbeCacheSnapshot = app_context.BackendProbeCacheSnapshot;
const CacheState = app_context.CacheState;
const Context = app_context.Context;
const ContextError = app_context.ContextError;
const CounterHandles = app_context.CounterHandles;

test "default context is transport free and has no effect ports" {
    const ctx = Context{};
    try std.testing.expect(!ctx.workspace.configured());
    try std.testing.expect(!ctx.ports.hasEffects());
    try std.testing.expectError(ContextError.MissingPort, ctx.requireCommandRunner());
}

test "profiling context requires only the pilot runtime capabilities" {
    const Stub = struct {
        /// Invokes command run with caller-owned inputs; command and allocation failures propagate.
        fn commandRun(_: *anyopaque, _: std.mem.Allocator, _: ports.CommandRequest) ports.PortError!ports.CommandResult {
            return .{ .exit_code = 0, .stdout = "ok" };
        }

        /// Reads workspace fixture bytes for the requested path.
        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return .{ .bytes = "" };
        }

        /// Stores workspace fixture bytes for the requested path.
        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

        const command_vtable = ports.CommandRunner.VTable{ .run = commandRun };
        const workspace_vtable = ports.WorkspaceStore.VTable{
            .read = workspaceRead,
            .write = workspaceWrite,
        };
    };

    var token: u8 = 0;
    const ctx = Context{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .tool_paths = .{ .zflame = "/bin/zflame", .diff_folded = "/bin/diff-folded" },
        .timeouts = .{ .command_ms = 5_000, .zls_ms = 7_000 },
        .ports = .{
            .command_runner = .{ .ptr = &token, .vtable = &Stub.command_vtable },
            .workspace = .{ .ptr = &token, .vtable = &Stub.workspace_vtable },
        },
    };

    const profiling_ctx = try ctx.profiling();
    try std.testing.expectEqualStrings("/workspace", profiling_ctx.workspace.root);
    try std.testing.expectEqualStrings("/bin/zflame", profiling_ctx.tool_paths.zflame);
    try std.testing.expectEqual(@as(i64, 5_000), profiling_ctx.timeouts.command_ms);
    try std.testing.expect(profiling_ctx.backend_probe == null);

    const command = try profiling_ctx.command_runner.run(std.testing.allocator, .{ .argv = &.{"zig"} });
    defer command.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", command.stdout);
    const read = try profiling_ctx.workspace_store.read(std.testing.allocator, .{ .path = "README.md" });
    defer read.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", read.bytes);
    const write = try profiling_ctx.workspace_store.write(.{ .path = "out.txt", .bytes = "bytes" });
    try std.testing.expectEqual(@as(usize, 5), write.bytes_written);
}

test "validation context requires command workspace and clock ports" {
    const Stub = struct {
        /// Invokes command run with caller-owned inputs; command and allocation failures propagate.
        fn commandRun(_: *anyopaque, _: std.mem.Allocator, _: ports.CommandRequest) ports.PortError!ports.CommandResult {
            return .{ .exit_code = 0 };
        }

        /// Reads workspace fixture bytes for the requested path.
        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return .{ .bytes = "" };
        }

        /// Stores workspace fixture bytes for the requested path.
        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

        /// Returns the fixture clock timestamp.
        fn now(_: *anyopaque) ports.PortError!ports.Instant {
            return .{ .unix_ms = 1_700_000_000_000, .monotonic_ms = 1 };
        }

        /// Allocates the next deterministic fixture identifier.
        fn nextId(_: *anyopaque, allocator: std.mem.Allocator, request: ports.IdRequest) ports.PortError![]const u8 {
            return std.fmt.allocPrint(allocator, "{s}-1", .{request.prefix});
        }

        const command_vtable = ports.CommandRunner.VTable{ .run = commandRun };
        const workspace_vtable = ports.WorkspaceStore.VTable{
            .read = workspaceRead,
            .write = workspaceWrite,
        };
        const clock_vtable = ports.ClockAndIds.VTable{
            .now = now,
            .nextId = nextId,
        };
    };

    var token: u8 = 0;
    var missing_clock = Context{
        .ports = .{
            .command_runner = .{ .ptr = &token, .vtable = &Stub.command_vtable },
            .workspace = .{ .ptr = &token, .vtable = &Stub.workspace_vtable },
        },
    };
    try std.testing.expectError(ContextError.MissingPort, missing_clock.validation());

    missing_clock.ports.clock_and_ids = .{ .ptr = &token, .vtable = &Stub.clock_vtable };
    const validation_ctx = try missing_clock.validation();
    try std.testing.expectEqualStrings("zig", validation_ctx.tool_paths.zig);
    try std.testing.expectEqual(@as(i64, 30_000), validation_ctx.timeouts.command_ms);

    const command = try validation_ctx.command_runner.run(std.testing.allocator, .{ .argv = &.{"zig"} });
    defer command.deinit(std.testing.allocator);
    const read = try validation_ctx.workspace_store.read(std.testing.allocator, .{ .path = "build.zig" });
    defer read.deinit(std.testing.allocator);
    const write = try validation_ctx.workspace_store.write(.{ .path = "build.zig", .bytes = "pub fn main() void {}" });
    try std.testing.expectEqual(@as(usize, 21), write.bytes_written);
    const instant = try validation_ctx.clock_and_ids.now();
    try std.testing.expectEqual(@as(u64, 1), instant.monotonic_ms);
    const id = try validation_ctx.clock_and_ids.nextId(std.testing.allocator, .{ .prefix = "run" });
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("run-1", id);
}

test "editing context requires workspace and clock ports" {
    const Stub = struct {
        /// Reads workspace fixture bytes for the requested path.
        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return .{ .bytes = "" };
        }

        /// Stores workspace fixture bytes for the requested path.
        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

        /// Returns the fixture clock timestamp.
        fn now(_: *anyopaque) ports.PortError!ports.Instant {
            return .{ .unix_ms = 1_700_000_000_000, .monotonic_ms = 1 };
        }

        /// Allocates the next deterministic fixture identifier.
        fn nextId(_: *anyopaque, allocator: std.mem.Allocator, request: ports.IdRequest) ports.PortError![]const u8 {
            return std.fmt.allocPrint(allocator, "{s}1", .{request.prefix});
        }

        const workspace_vtable = ports.WorkspaceStore.VTable{
            .read = workspaceRead,
            .write = workspaceWrite,
        };
        const clock_vtable = ports.ClockAndIds.VTable{
            .now = now,
            .nextId = nextId,
        };
    };

    var token: u8 = 0;
    const ctx = Context{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .ports = .{
            .workspace = .{ .ptr = &token, .vtable = &Stub.workspace_vtable },
            .clock_and_ids = .{ .ptr = &token, .vtable = &Stub.clock_vtable },
        },
    };

    const editing_ctx = try ctx.editing();
    try std.testing.expectEqualStrings("/workspace", editing_ctx.workspace.root);
    const read = try editing_ctx.workspace_store.read(std.testing.allocator, .{ .path = "src/main.zig" });
    defer read.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", read.bytes);
    const write = try editing_ctx.workspace_store.write(.{ .path = "src/main.zig", .bytes = "const x = 1;" });
    try std.testing.expectEqual(@as(usize, 12), write.bytes_written);
    const instant = try editing_ctx.clock_and_ids.now();
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), instant.unix_ms);
    const id = try editing_ctx.clock_and_ids.nextId(std.testing.allocator, .{ .prefix = "edit-" });
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("edit-1", id);
}

test "counter handles are optional runtime bridges" {
    var command_calls: usize = 1;
    var zls_requests: usize = 2;
    var tool_errors: usize = 3;
    const counters = CounterHandles{
        .command_calls = &command_calls,
        .zls_requests = &zls_requests,
        .tool_errors = &tool_errors,
    };

    counters.incrementCommandCalls();
    counters.incrementZlsRequests();
    counters.incrementToolErrors();

    try std.testing.expectEqual(@as(usize, 2), command_calls);
    try std.testing.expectEqual(@as(usize, 3), zls_requests);
    try std.testing.expectEqual(@as(usize, 4), tool_errors);
}

test "cache snapshots expose status without concrete cache ownership" {
    const state = CacheState{
        .backend_probe = .{ .zig = true },
        .analysis = .{ .cached = true, .signature = 42, .hits = 3, .refreshes = 1 },
    };

    try std.testing.expect(state.backend_probe.anyCached());
    try std.testing.expect((BackendProbeCacheSnapshot{ .diff_folded = true }).anyCached());
    try std.testing.expect(state.analysis.cached);
    try std.testing.expectEqual(@as(u64, 42), state.analysis.signature);
}

test "static analysis context carries optional command and cache ports" {
    const Stub = struct {
        /// Invokes command run with caller-owned inputs; command and allocation failures propagate.
        fn commandRun(_: *anyopaque, _: std.mem.Allocator, _: ports.CommandRequest) ports.PortError!ports.CommandResult {
            return .{ .exit_code = 0 };
        }

        /// Reads workspace fixture bytes for the requested path.
        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return .{ .bytes = "" };
        }

        /// Stores workspace fixture bytes for the requested path.
        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

        /// Scans fixture workspace entries and returns matching paths.
        fn scanZigFiles(_: *anyopaque, allocator: std.mem.Allocator, _: ports.WorkspaceScanRequest) ports.PortError!ports.WorkspaceScanResult {
            return .{ .files = try allocator.alloc(ports.WorkspaceScanFile, 0), .owns_memory = true };
        }

        /// Implements cache status workflow logic using caller-owned inputs.
        fn cacheStatus(_: *anyopaque) ports.PortError!ports.StaticCacheStatus {
            return .{ .cached = true, .signature = 99, .bytes_len = 2 };
        }

        /// Implements cache load workflow logic using caller-owned inputs.
        fn cacheLoad(_: *anyopaque, _: std.mem.Allocator) ports.PortError!ports.StaticCacheLoadResult {
            return .{ .status = .{ .cached = true, .signature = 99, .bytes_len = 2 }, .bytes = "{}" };
        }

        /// Implements cache store workflow logic using caller-owned inputs.
        fn cacheStore(_: *anyopaque, _: std.mem.Allocator, request: ports.StaticCacheStoreRequest) ports.PortError!ports.StaticCacheStatus {
            return .{ .cached = true, .signature = request.signature, .bytes_len = request.bytes.len, .refreshes = 1 };
        }

        /// Implements cache hit workflow logic using caller-owned inputs.
        fn cacheHit(_: *anyopaque) ports.PortError!ports.StaticCacheStatus {
            return .{ .cached = true, .signature = 99, .bytes_len = 2, .hits = 1 };
        }

        const command_vtable = ports.CommandRunner.VTable{ .run = commandRun };
        const workspace_vtable = ports.WorkspaceStore.VTable{
            .read = workspaceRead,
            .write = workspaceWrite,
        };
        const scanner_vtable = ports.WorkspaceScanner.VTable{ .scan_zig_files = scanZigFiles };
        const cache_vtable = ports.StaticCache.VTable{
            .status = cacheStatus,
            .load = cacheLoad,
            .store = cacheStore,
            .record_hit = cacheHit,
        };
    };

    var token: u8 = 0;
    const ctx = Context{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .tool_paths = .{ .zlint = "/bin/zlint" },
        .ports = .{
            .command_runner = .{ .ptr = &token, .vtable = &Stub.command_vtable },
            .workspace = .{ .ptr = &token, .vtable = &Stub.workspace_vtable },
            .workspace_scanner = .{ .ptr = &token, .vtable = &Stub.scanner_vtable },
            .semantic_index_cache = .{ .ptr = &token, .vtable = &Stub.cache_vtable },
        },
    };

    const static_ctx = try ctx.staticAnalysis();
    try std.testing.expect(static_ctx.command_runner != null);
    try std.testing.expect(static_ctx.semantic_index_cache != null);
    try std.testing.expectEqualStrings("/bin/zlint", static_ctx.tool_paths.zlint);

    const command = try static_ctx.command_runner.?.run(std.testing.allocator, .{ .argv = &.{"zig"} });
    defer command.deinit(std.testing.allocator);
    const read = try static_ctx.workspace_store.read(std.testing.allocator, .{ .path = "src/lib.zig" });
    defer read.deinit(std.testing.allocator);
    const write = try static_ctx.workspace_store.write(.{ .path = "src/lib.zig", .bytes = "pub fn lib() void {}" });
    try std.testing.expectEqual(@as(usize, 20), write.bytes_written);
    const scan = try static_ctx.workspace_scanner.scanZigFiles(std.testing.allocator, .{});
    defer scan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), scan.files.len);
    const status = try static_ctx.semantic_index_cache.?.status();
    try std.testing.expectEqual(@as(u64, 99), status.signature);
    const loaded = try static_ctx.semantic_index_cache.?.load(std.testing.allocator);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{}", loaded.bytes.?);
    const stored = try static_ctx.semantic_index_cache.?.store(std.testing.allocator, .{ .signature = 7, .bytes = "[]" });
    try std.testing.expectEqual(@as(u64, 7), stored.signature);
    const hit = try static_ctx.semantic_index_cache.?.recordHit();
    try std.testing.expectEqual(@as(usize, 1), hit.hits);
}
