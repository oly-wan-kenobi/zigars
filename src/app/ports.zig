const std = @import("std");

const Allocator = std.mem.Allocator;

pub const PortError = error{
    UnexpectedCall,
    MissingExpectedCall,
    StaleArguments,
    MissingWrite,
    NotFound,
    FileNotFound,
    AlreadyExists,
    AccessDenied,
    PermissionDenied,
    Unavailable,
    InvalidRequest,
    Timeout,
    RequestTimeout,
    NoResponse,
    EndOfStream,
    BrokenPipe,
    PathOutsideWorkspace,
    EmptyPath,
    DocumentTooLarge,
    OpenDocumentLimitExceeded,
    RetainedContentLimitExceeded,
    OutputLimitExceeded,
    StreamTooLong,
    OutOfMemory,
};

pub const CommandRequest = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    max_stdout_bytes: ?usize = null,
    max_stderr_bytes: ?usize = null,
    provenance: []const u8 = "",
};

pub const CommandTerm = union(enum) {
    exited: i32,
    signal,
    stopped,
    unknown,

    pub fn name(self: CommandTerm) []const u8 {
        return switch (self) {
            .exited => "exited",
            .signal => "signal",
            .stopped => "stopped",
            .unknown => "unknown",
        };
    }

    pub fn exitCode(self: CommandTerm) ?i64 {
        return switch (self) {
            .exited => |code| @intCast(code),
            else => null,
        };
    }

    pub fn failed(self: CommandTerm) bool {
        return switch (self) {
            .exited => |code| code != 0,
            else => true,
        };
    }
};

pub const CommandResult = struct {
    exit_code: i32 = 0,
    term: CommandTerm = .{ .exited = 0 },
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    duration_ms: u64 = 0,
    timed_out: bool = false,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    provenance: []const u8 = "",
    owns_stdout: bool = false,
    owns_stderr: bool = false,

    pub fn deinit(self: CommandResult, allocator: Allocator) void {
        if (self.owns_stdout) allocator.free(self.stdout);
        if (self.owns_stderr) allocator.free(self.stderr);
    }

    pub fn effectiveTerm(self: CommandResult) CommandTerm {
        return switch (self.term) {
            .exited => |code| if (code == 0 and self.exit_code != 0) .{ .exited = self.exit_code } else .{ .exited = code },
            else => self.term,
        };
    }
};

pub const CommandRunner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn (*anyopaque, Allocator, CommandRequest) PortError!CommandResult,
    };

    pub fn run(self: CommandRunner, allocator: Allocator, request: CommandRequest) PortError!CommandResult {
        return self.vtable.run(self.ptr, allocator, request);
    }
};

pub const WorkspaceReadRequest = struct {
    path: []const u8,
    max_bytes: ?usize = null,
    provenance: []const u8 = "",
};

pub const WorkspaceResolveRequest = struct {
    path: []const u8,
    for_output: bool = false,
    provenance: []const u8 = "",
};

pub const WorkspaceResolveResult = struct {
    path: []const u8,
    owns_path: bool = false,

    pub fn deinit(self: WorkspaceResolveResult, allocator: Allocator) void {
        if (self.owns_path) allocator.free(self.path);
    }
};

pub const WorkspaceReadResult = struct {
    bytes: []const u8,
    owns_bytes: bool = false,

    pub fn deinit(self: WorkspaceReadResult, allocator: Allocator) void {
        if (self.owns_bytes) allocator.free(self.bytes);
    }
};

pub const WorkspaceWriteRequest = struct {
    path: []const u8,
    bytes: []const u8,
    create_parent_dirs: bool = true,
    replace_existing: bool = true,
    provenance: []const u8 = "",
};

pub const WorkspaceWriteResult = struct {
    bytes_written: usize,
    replaced_existing: bool = false,
};

pub const WorkspaceDeleteRequest = struct {
    path: []const u8,
    missing_ok: bool = true,
    provenance: []const u8 = "",
};

pub const WorkspaceDeleteResult = struct {
    deleted: bool,
};

pub const WorkspaceStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        resolve: ?*const fn (*anyopaque, Allocator, WorkspaceResolveRequest) PortError!WorkspaceResolveResult = null,
        read: *const fn (*anyopaque, Allocator, WorkspaceReadRequest) PortError!WorkspaceReadResult,
        write: *const fn (*anyopaque, WorkspaceWriteRequest) PortError!WorkspaceWriteResult,
        delete: ?*const fn (*anyopaque, WorkspaceDeleteRequest) PortError!WorkspaceDeleteResult = null,
    };

    pub fn resolve(self: WorkspaceStore, allocator: Allocator, request: WorkspaceResolveRequest) PortError!WorkspaceResolveResult {
        const resolve_fn = self.vtable.resolve orelse return error.UnexpectedCall;
        return resolve_fn(self.ptr, allocator, request);
    }

    pub fn read(self: WorkspaceStore, allocator: Allocator, request: WorkspaceReadRequest) PortError!WorkspaceReadResult {
        return self.vtable.read(self.ptr, allocator, request);
    }

    pub fn write(self: WorkspaceStore, request: WorkspaceWriteRequest) PortError!WorkspaceWriteResult {
        return self.vtable.write(self.ptr, request);
    }

    pub fn delete(self: WorkspaceStore, request: WorkspaceDeleteRequest) PortError!WorkspaceDeleteResult {
        const delete_fn = self.vtable.delete orelse return error.UnexpectedCall;
        return delete_fn(self.ptr, request);
    }
};

pub const ZlsCapabilityRequest = struct {
    capability: []const u8,
};

pub const ZlsCapabilityResult = struct {
    capability: []const u8,
    supported: bool,
    basis: []const u8 = "",
};

pub const ZlsSyncRequest = struct {
    file: []const u8,
    content: ?[]const u8 = null,
    provenance: []const u8 = "",
};

pub const ZlsSyncResult = struct {
    uri: []const u8,
    basis: []const u8 = "",
    owns_uri: bool = false,

    pub fn deinit(self: ZlsSyncResult, allocator: Allocator) void {
        if (self.owns_uri) allocator.free(self.uri);
    }
};

pub const ZlsRequest = struct {
    method: []const u8,
    uri: ?[]const u8 = null,
    payload: []const u8 = "",
};

pub const ZlsResponse = struct {
    method: []const u8,
    payload: []const u8 = "",
    owns_payload: bool = false,

    pub fn deinit(self: ZlsResponse, allocator: Allocator) void {
        if (self.owns_payload) allocator.free(self.payload);
    }
};

pub const ZlsGateway = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        capability: *const fn (*anyopaque, ZlsCapabilityRequest) PortError!ZlsCapabilityResult,
        sync: *const fn (*anyopaque, Allocator, ZlsSyncRequest) PortError!ZlsSyncResult,
        request: *const fn (*anyopaque, Allocator, ZlsRequest) PortError!ZlsResponse,
    };

    pub fn capability(self: ZlsGateway, capability_request: ZlsCapabilityRequest) PortError!ZlsCapabilityResult {
        return self.vtable.capability(self.ptr, capability_request);
    }

    pub fn sync(self: ZlsGateway, allocator: Allocator, sync_request: ZlsSyncRequest) PortError!ZlsSyncResult {
        return self.vtable.sync(self.ptr, allocator, sync_request);
    }

    pub fn request(self: ZlsGateway, allocator: Allocator, request_value: ZlsRequest) PortError!ZlsResponse {
        return self.vtable.request(self.ptr, allocator, request_value);
    }
};

pub const BackendProbeRequest = struct {
    backend: []const u8,
    required_capabilities: []const []const u8 = &.{},
    provenance: []const u8 = "",
};

pub const BackendAvailability = struct {
    backend: []const u8,
    available: bool,
    version: ?[]const u8 = null,
    capabilities: []const []const u8 = &.{},
    unavailable_reason: ?[]const u8 = null,
    basis: []const u8 = "",
    owns_memory: bool = false,

    pub fn deinit(self: BackendAvailability, allocator: Allocator) void {
        if (!self.owns_memory) return;
        allocator.free(self.backend);
        if (self.version) |value| allocator.free(value);
        for (self.capabilities) |capability| allocator.free(capability);
        allocator.free(self.capabilities);
        if (self.unavailable_reason) |value| allocator.free(value);
        allocator.free(self.basis);
    }
};

pub const BackendProbe = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        check: *const fn (*anyopaque, Allocator, BackendProbeRequest) PortError!BackendAvailability,
    };

    pub fn check(self: BackendProbe, allocator: Allocator, request: BackendProbeRequest) PortError!BackendAvailability {
        return self.vtable.check(self.ptr, allocator, request);
    }
};

pub const ArtifactWriteRequest = struct {
    namespace: []const u8,
    name: []const u8,
    kind: []const u8,
    bytes: []const u8,
    provenance: []const u8 = "",
};

pub const ArtifactRef = struct {
    id: []const u8,
    uri: []const u8,
    checksum: ?[]const u8 = null,
    bytes_written: usize,
    owns_memory: bool = false,

    pub fn deinit(self: ArtifactRef, allocator: Allocator) void {
        if (!self.owns_memory) return;
        allocator.free(self.id);
        allocator.free(self.uri);
        if (self.checksum) |value| allocator.free(value);
    }
};

pub const ArtifactReadRequest = struct {
    id: []const u8,
};

pub const ArtifactReadResult = struct {
    bytes: []const u8,
    owns_bytes: bool = false,

    pub fn deinit(self: ArtifactReadResult, allocator: Allocator) void {
        if (self.owns_bytes) allocator.free(self.bytes);
    }
};

pub const ArtifactStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (*anyopaque, Allocator, ArtifactWriteRequest) PortError!ArtifactRef,
        read: *const fn (*anyopaque, Allocator, ArtifactReadRequest) PortError!ArtifactReadResult,
    };

    pub fn put(self: ArtifactStore, allocator: Allocator, request: ArtifactWriteRequest) PortError!ArtifactRef {
        return self.vtable.put(self.ptr, allocator, request);
    }

    pub fn read(self: ArtifactStore, allocator: Allocator, request: ArtifactReadRequest) PortError!ArtifactReadResult {
        return self.vtable.read(self.ptr, allocator, request);
    }
};

pub const ObservationAttribute = struct {
    key: []const u8,
    value: []const u8,
};

pub const ObservationEvent = struct {
    name: []const u8,
    phase: []const u8,
    attributes: []const ObservationAttribute = &.{},
    duration_ms: ?u64 = null,
};

pub const ObservabilitySink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        emit: *const fn (*anyopaque, ObservationEvent) PortError!void,
    };

    pub fn emit(self: ObservabilitySink, event: ObservationEvent) PortError!void {
        return self.vtable.emit(self.ptr, event);
    }
};

pub const Instant = struct {
    unix_ms: i64,
    monotonic_ms: u64,
};

pub const IdRequest = struct {
    prefix: []const u8 = "",
};

pub const ClockAndIds = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now: *const fn (*anyopaque) PortError!Instant,
        nextId: *const fn (*anyopaque, Allocator, IdRequest) PortError![]const u8,
    };

    pub fn now(self: ClockAndIds) PortError!Instant {
        return self.vtable.now(self.ptr);
    }

    pub fn nextId(self: ClockAndIds, allocator: Allocator, request: IdRequest) PortError![]const u8 {
        return self.vtable.nextId(self.ptr, allocator, request);
    }
};

test "port requests and borrowed results do not require transport types" {
    const request = CommandRequest{
        .argv = &.{ "zig", "build", "test" },
        .cwd = ".",
        .timeout_ms = 30_000,
        .provenance = "unit",
    };
    try std.testing.expectEqual(@as(usize, 3), request.argv.len);
    try std.testing.expectEqualStrings("zig", request.argv[0]);

    const result = CommandResult{ .exit_code = 0, .stdout = "ok" };
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqualStrings("exited", result.effectiveTerm().name());
    try std.testing.expectEqual(@as(?i64, 0), result.effectiveTerm().exitCode());
    try std.testing.expectEqualStrings("ok", result.stdout);

    const delete_request = WorkspaceDeleteRequest{ .path = "src/generated.zig", .missing_ok = true };
    try std.testing.expectEqualStrings("src/generated.zig", delete_request.path);
}

test "command result terms preserve non-exited outcomes" {
    const signaled = CommandResult{ .term = .signal, .stdout = "partial" };
    try std.testing.expect(signaled.effectiveTerm().failed());
    try std.testing.expectEqualStrings("signal", signaled.effectiveTerm().name());
    try std.testing.expectEqual(@as(?i64, null), signaled.effectiveTerm().exitCode());

    const legacy_nonzero = CommandResult{ .exit_code = 7 };
    try std.testing.expectEqualStrings("exited", legacy_nonzero.effectiveTerm().name());
    try std.testing.expectEqual(@as(?i64, 7), legacy_nonzero.effectiveTerm().exitCode());
}

test "clock and id port contracts are deterministic data" {
    const instant = Instant{ .unix_ms = 1_700_000_000_000, .monotonic_ms = 42 };
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), instant.unix_ms);

    const request = IdRequest{ .prefix = "artifact" };
    try std.testing.expectEqualStrings("artifact", request.prefix);
}
