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

pub const max_observability_tool_stats = 64;
pub const max_observability_command_events = 64;
pub const max_observability_backend_events = 64;
pub const max_observability_zls_events = 64;

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
    for_output: ?bool = null,
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

pub const WorkspaceEntryKind = enum {
    file,
    directory,
};

pub const WorkspaceExistsRequest = struct {
    path: []const u8,
    for_output: bool = false,
    provenance: []const u8 = "",
};

pub const WorkspaceExistsResult = struct {
    exists: bool,
    kind: ?WorkspaceEntryKind = null,
    entry_count: ?usize = null,
};

pub const WorkspaceEnsureDirRequest = struct {
    path: []const u8,
    provenance: []const u8 = "",
};

pub const WorkspaceEnsureDirResult = struct {
    created_or_existing: bool = true,
};

pub const WorkspaceDirectoryScanRequest = struct {
    path: []const u8,
    suffix: []const u8 = "",
    max_files: ?usize = null,
    for_output: bool = true,
    provenance: []const u8 = "",
};

pub const WorkspaceDirectoryEntry = struct {
    path: []const u8,
};

pub const WorkspaceDirectoryScanResult = struct {
    entries: []WorkspaceDirectoryEntry,
    owns_memory: bool = false,

    pub fn deinit(self: WorkspaceDirectoryScanResult, allocator: Allocator) void {
        if (!self.owns_memory) return;
        for (self.entries) |entry| allocator.free(entry.path);
        allocator.free(self.entries);
    }
};

pub const WorkspaceScanRequest = struct {
    path_prefix: []const u8 = "",
    max_files: ?usize = null,
    provenance: []const u8 = "",
};

pub const WorkspaceScanFile = struct {
    path: []const u8,
};

pub const WorkspaceScanResult = struct {
    files: []WorkspaceScanFile,
    owns_memory: bool = false,

    pub fn deinit(self: WorkspaceScanResult, allocator: Allocator) void {
        if (!self.owns_memory) return;
        for (self.files) |file| allocator.free(file.path);
        allocator.free(self.files);
    }
};

pub const WorkspaceStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        resolve: ?*const fn (*anyopaque, Allocator, WorkspaceResolveRequest) PortError!WorkspaceResolveResult = null,
        read: *const fn (*anyopaque, Allocator, WorkspaceReadRequest) PortError!WorkspaceReadResult,
        write: *const fn (*anyopaque, WorkspaceWriteRequest) PortError!WorkspaceWriteResult,
        delete: ?*const fn (*anyopaque, WorkspaceDeleteRequest) PortError!WorkspaceDeleteResult = null,
        exists: ?*const fn (*anyopaque, Allocator, WorkspaceExistsRequest) PortError!WorkspaceExistsResult = null,
        ensure_dir: ?*const fn (*anyopaque, WorkspaceEnsureDirRequest) PortError!WorkspaceEnsureDirResult = null,
        scan_directory: ?*const fn (*anyopaque, Allocator, WorkspaceDirectoryScanRequest) PortError!WorkspaceDirectoryScanResult = null,
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

    pub fn exists(self: WorkspaceStore, allocator: Allocator, request: WorkspaceExistsRequest) PortError!WorkspaceExistsResult {
        const exists_fn = self.vtable.exists orelse return error.UnexpectedCall;
        return exists_fn(self.ptr, allocator, request);
    }

    pub fn ensureDir(self: WorkspaceStore, request: WorkspaceEnsureDirRequest) PortError!WorkspaceEnsureDirResult {
        const ensure_dir_fn = self.vtable.ensure_dir orelse return error.UnexpectedCall;
        return ensure_dir_fn(self.ptr, request);
    }

    pub fn scanDirectory(self: WorkspaceStore, allocator: Allocator, request: WorkspaceDirectoryScanRequest) PortError!WorkspaceDirectoryScanResult {
        const scan_directory_fn = self.vtable.scan_directory orelse return error.UnexpectedCall;
        return scan_directory_fn(self.ptr, allocator, request);
    }
};

pub const WorkspaceScanner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        scan_zig_files: *const fn (*anyopaque, Allocator, WorkspaceScanRequest) PortError!WorkspaceScanResult,
    };

    pub fn scanZigFiles(self: WorkspaceScanner, allocator: Allocator, request: WorkspaceScanRequest) PortError!WorkspaceScanResult {
        return self.vtable.scan_zig_files(self.ptr, allocator, request);
    }
};

pub const ToolchainEnvRequest = struct {
    key: []const u8,
    provenance: []const u8 = "",
};

pub const ToolchainEnvValue = struct {
    value: []const u8,
    owns_value: bool = false,

    pub fn deinit(self: ToolchainEnvValue, allocator: Allocator) void {
        if (self.owns_value) allocator.free(self.value);
    }
};

pub const ToolchainEnv = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (*anyopaque, Allocator, ToolchainEnvRequest) PortError!ToolchainEnvValue,
    };

    pub fn get(self: ToolchainEnv, allocator: Allocator, request: ToolchainEnvRequest) PortError!ToolchainEnvValue {
        return self.vtable.get(self.ptr, allocator, request);
    }
};

pub const DocsReadAbsoluteRequest = struct {
    path: []const u8,
    max_bytes: usize,
    provenance: []const u8 = "",
};

pub const DocsReadResult = struct {
    bytes: []const u8,
    owns_bytes: bool = false,

    pub fn deinit(self: DocsReadResult, allocator: Allocator) void {
        if (self.owns_bytes) allocator.free(self.bytes);
    }
};

pub const DocsScanAbsoluteZigPathsRequest = struct {
    root: []const u8,
    max_files: ?usize = null,
    provenance: []const u8 = "",
};

pub const DocsScanWorkspacePathsRequest = struct {
    max_files: ?usize = null,
    provenance: []const u8 = "",
};

pub const DocsPath = struct {
    path: []const u8,
};

pub const DocsPathScanResult = struct {
    paths: []DocsPath,
    walk_errors: usize = 0,
    truncated: bool = false,
    owns_memory: bool = false,

    pub fn deinit(self: DocsPathScanResult, allocator: Allocator) void {
        if (!self.owns_memory) return;
        for (self.paths) |path| allocator.free(path.path);
        allocator.free(self.paths);
    }
};

pub const DocsScanner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read_absolute: *const fn (*anyopaque, Allocator, DocsReadAbsoluteRequest) PortError!DocsReadResult,
        scan_absolute_zig_paths: *const fn (*anyopaque, Allocator, DocsScanAbsoluteZigPathsRequest) PortError!DocsPathScanResult,
        scan_workspace_paths: *const fn (*anyopaque, Allocator, DocsScanWorkspacePathsRequest) PortError!DocsPathScanResult,
    };

    pub fn readAbsolute(self: DocsScanner, allocator: Allocator, request: DocsReadAbsoluteRequest) PortError!DocsReadResult {
        return self.vtable.read_absolute(self.ptr, allocator, request);
    }

    pub fn scanAbsoluteZigPaths(self: DocsScanner, allocator: Allocator, request: DocsScanAbsoluteZigPathsRequest) PortError!DocsPathScanResult {
        return self.vtable.scan_absolute_zig_paths(self.ptr, allocator, request);
    }

    pub fn scanWorkspacePaths(self: DocsScanner, allocator: Allocator, request: DocsScanWorkspacePathsRequest) PortError!DocsPathScanResult {
        return self.vtable.scan_workspace_paths(self.ptr, allocator, request);
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
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
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

pub const StaticCacheStatus = struct {
    cached: bool = false,
    signature: u64 = 0,
    hits: usize = 0,
    refreshes: usize = 0,
    bytes_len: usize = 0,
};

pub const StaticCacheLoadResult = struct {
    status: StaticCacheStatus,
    bytes: ?[]const u8 = null,
    owns_bytes: bool = false,

    pub fn deinit(self: StaticCacheLoadResult, allocator: Allocator) void {
        if (self.owns_bytes) if (self.bytes) |bytes| allocator.free(bytes);
    }
};

pub const StaticCacheStoreRequest = struct {
    signature: u64,
    bytes: []const u8,
    provenance: []const u8 = "",
};

pub const StaticCache = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        status: *const fn (*anyopaque) PortError!StaticCacheStatus,
        load: *const fn (*anyopaque, Allocator) PortError!StaticCacheLoadResult,
        store: *const fn (*anyopaque, Allocator, StaticCacheStoreRequest) PortError!StaticCacheStatus,
        record_hit: *const fn (*anyopaque) PortError!StaticCacheStatus,
    };

    pub fn status(self: StaticCache) PortError!StaticCacheStatus {
        return self.vtable.status(self.ptr);
    }

    pub fn load(self: StaticCache, allocator: Allocator) PortError!StaticCacheLoadResult {
        return self.vtable.load(self.ptr, allocator);
    }

    pub fn store(self: StaticCache, allocator: Allocator, request: StaticCacheStoreRequest) PortError!StaticCacheStatus {
        return self.vtable.store(self.ptr, allocator, request);
    }

    pub fn recordHit(self: StaticCache) PortError!StaticCacheStatus {
        return self.vtable.record_hit(self.ptr);
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

pub const ArtifactToolchain = struct {
    zig_path: []const u8 = "",
    zls_path: []const u8 = "",
    zflame_path: []const u8 = "",
    diff_folded_path: []const u8 = "",
};

pub const WorkspaceArtifactRecordRequest = struct {
    path: []const u8,
    bytes: ?[]const u8 = null,
    producer: []const u8,
    artifact_kind: []const u8,
    command_argv: []const []const u8 = &.{},
    backend_name: []const u8 = "",
    backend_version: []const u8 = "",
    target: []const u8 = "",
    baseline_identity: []const u8 = "",
    notes: []const u8 = "",
    toolchain: ArtifactToolchain = .{},
    indexed_at_unix_ms: i64 = 0,
    provenance: []const u8 = "",
};

pub const WorkspaceArtifactRef = struct {
    path: []const u8,
    abs_path: []const u8,
    bytes: usize,
    sha256: []const u8,
    indexed_at_unix_ms: i64,
    owns_memory: bool = false,

    pub fn deinit(self: WorkspaceArtifactRef, allocator: Allocator) void {
        if (!self.owns_memory) return;
        allocator.free(self.path);
        allocator.free(self.abs_path);
        allocator.free(self.sha256);
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
        record_workspace: ?*const fn (*anyopaque, Allocator, WorkspaceArtifactRecordRequest) PortError!WorkspaceArtifactRef = null,
    };

    pub fn put(self: ArtifactStore, allocator: Allocator, request: ArtifactWriteRequest) PortError!ArtifactRef {
        return self.vtable.put(self.ptr, allocator, request);
    }

    pub fn read(self: ArtifactStore, allocator: Allocator, request: ArtifactReadRequest) PortError!ArtifactReadResult {
        return self.vtable.read(self.ptr, allocator, request);
    }

    pub fn recordWorkspace(self: ArtifactStore, allocator: Allocator, request: WorkspaceArtifactRecordRequest) PortError!WorkspaceArtifactRef {
        const record_fn = self.vtable.record_workspace orelse return error.UnexpectedCall;
        return record_fn(self.ptr, allocator, request);
    }
};

pub const RuntimeJobStatus = enum {
    queued,
    running,
    completed,
    failed,
    cancelled,

    pub fn text(self: RuntimeJobStatus) []const u8 {
        return @tagName(self);
    }

    pub fn terminal(self: RuntimeJobStatus) bool {
        return switch (self) {
            .completed, .failed, .cancelled => true,
            else => false,
        };
    }
};

pub const RuntimeJobSnapshot = struct {
    id: []const u8,
    label: []const u8,
    command: []const u8,
    status: RuntimeJobStatus,
    ok: bool,
    created_sequence: u64,
    updated_sequence: u64,
    duration_ms: i64,
    timeout_ms: i64,
    term: []const u8,
    exit_code: ?i64,
    stdout_tail: []const u8,
    stderr_tail: []const u8,
    stdout_truncated: bool,
    stderr_truncated: bool,
    cancellation_requested: bool,
    cancellation_reason: []const u8,
};

pub const RuntimeEventSnapshot = struct {
    sequence: u64,
    job_id: []const u8,
    event: []const u8,
    stream: []const u8,
    message: []const u8,
    text: []const u8,
    elapsed_ms: i64,
};

pub const RuntimeSubscriptionSnapshot = struct {
    id: []const u8,
    uri: []const u8,
    active: bool,
    created_sequence: u64,
};

pub const RuntimeRootSnapshot = struct {
    id: []const u8,
    path: []const u8,
    uri: []const u8,
    name: []const u8,
    selected: bool,
};

pub const RuntimeJobFinish = struct {
    status: RuntimeJobStatus,
    ok: bool,
    duration_ms: i64,
    term: []const u8,
    exit_code: ?i64,
    stdout_tail: []const u8,
    stderr_tail: []const u8,
    stdout_truncated: bool,
    stderr_truncated: bool,
};

pub const RuntimeSession = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        ensure_default_root: *const fn (*anyopaque, []const u8) PortError!void,
        start_job: *const fn (*anyopaque, []const u8, []const u8, i64) PortError!RuntimeJobSnapshot,
        finish_job: *const fn (*anyopaque, []const u8, RuntimeJobFinish) PortError!RuntimeJobSnapshot,
        fail_job: *const fn (*anyopaque, []const u8, []const u8, i64) PortError!RuntimeJobSnapshot,
        cancel_job: *const fn (*anyopaque, []const u8, []const u8) PortError!RuntimeJobSnapshot,
        job_by_id: *const fn (*anyopaque, []const u8) PortError!RuntimeJobSnapshot,
        job_count: *const fn (*anyopaque) PortError!usize,
        job_at: *const fn (*anyopaque, usize) PortError!RuntimeJobSnapshot,
        event_count: *const fn (*anyopaque) PortError!u64,
        event_at_sequence: *const fn (*anyopaque, u64) PortError!RuntimeEventSnapshot,
        subscribe: *const fn (*anyopaque, []const u8) PortError!RuntimeSubscriptionSnapshot,
        unsubscribe: *const fn (*anyopaque, []const u8, ?[]const u8) PortError!RuntimeSubscriptionSnapshot,
        sync_roots: *const fn (*anyopaque, []const u8, []const u8, bool) PortError!void,
        select_root: *const fn (*anyopaque, []const u8, bool) PortError!RuntimeRootSnapshot,
        root_count: *const fn (*anyopaque) PortError!usize,
        selected_root_index: *const fn (*anyopaque) PortError!usize,
        root_at: *const fn (*anyopaque, usize) PortError!RuntimeRootSnapshot,
    };

    pub fn ensureDefaultRoot(self: RuntimeSession, workspace_root: []const u8) PortError!void {
        return self.vtable.ensure_default_root(self.ptr, workspace_root);
    }

    pub fn startJob(self: RuntimeSession, label: []const u8, command_text: []const u8, timeout_ms: i64) PortError!RuntimeJobSnapshot {
        return self.vtable.start_job(self.ptr, label, command_text, timeout_ms);
    }

    pub fn finishJob(self: RuntimeSession, job_id: []const u8, finish: RuntimeJobFinish) PortError!RuntimeJobSnapshot {
        return self.vtable.finish_job(self.ptr, job_id, finish);
    }

    pub fn failJob(self: RuntimeSession, job_id: []const u8, err_name: []const u8, duration_ms: i64) PortError!RuntimeJobSnapshot {
        return self.vtable.fail_job(self.ptr, job_id, err_name, duration_ms);
    }

    pub fn cancelJob(self: RuntimeSession, job_id: []const u8, reason: []const u8) PortError!RuntimeJobSnapshot {
        return self.vtable.cancel_job(self.ptr, job_id, reason);
    }

    pub fn jobById(self: RuntimeSession, job_id: []const u8) PortError!RuntimeJobSnapshot {
        return self.vtable.job_by_id(self.ptr, job_id);
    }

    pub fn jobCount(self: RuntimeSession) PortError!usize {
        return self.vtable.job_count(self.ptr);
    }

    pub fn jobAt(self: RuntimeSession, index: usize) PortError!RuntimeJobSnapshot {
        return self.vtable.job_at(self.ptr, index);
    }

    pub fn eventCount(self: RuntimeSession) PortError!u64 {
        return self.vtable.event_count(self.ptr);
    }

    pub fn eventAtSequence(self: RuntimeSession, sequence: u64) PortError!RuntimeEventSnapshot {
        return self.vtable.event_at_sequence(self.ptr, sequence);
    }

    pub fn subscribe(self: RuntimeSession, uri: []const u8) PortError!RuntimeSubscriptionSnapshot {
        return self.vtable.subscribe(self.ptr, uri);
    }

    pub fn unsubscribe(self: RuntimeSession, id: []const u8, uri: ?[]const u8) PortError!RuntimeSubscriptionSnapshot {
        return self.vtable.unsubscribe(self.ptr, id, uri);
    }

    pub fn syncRoots(self: RuntimeSession, workspace_root: []const u8, roots_text: []const u8, apply: bool) PortError!void {
        return self.vtable.sync_roots(self.ptr, workspace_root, roots_text, apply);
    }

    pub fn selectRoot(self: RuntimeSession, root_id: []const u8, apply: bool) PortError!RuntimeRootSnapshot {
        return self.vtable.select_root(self.ptr, root_id, apply);
    }

    pub fn rootCount(self: RuntimeSession) PortError!usize {
        return self.vtable.root_count(self.ptr);
    }

    pub fn selectedRootIndex(self: RuntimeSession) PortError!usize {
        return self.vtable.selected_root_index(self.ptr);
    }

    pub fn rootAt(self: RuntimeSession, index: usize) PortError!RuntimeRootSnapshot {
        return self.vtable.root_at(self.ptr, index);
    }
};

pub const ToolCatalogText = struct {
    text: []const u8,
    owns_text: bool = false,

    pub fn deinit(self: ToolCatalogText, allocator: Allocator) void {
        if (self.owns_text) allocator.free(self.text);
    }
};

pub const ToolCatalog = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        text: *const fn (*anyopaque, Allocator) PortError!ToolCatalogText,
    };

    pub fn text(self: ToolCatalog, allocator: Allocator) PortError!ToolCatalogText {
        return self.vtable.text(self.ptr, allocator);
    }
};

pub const ToolRisk = struct {
    writes_source: bool = false,
    writes_artifacts: bool = false,
    writes_require_apply: bool = false,
    preview_by_default: bool = false,
    mutates_lsp_state: bool = false,
    executes_project_code: bool = false,
    executes_user_command: bool = false,
    executes_backend: bool = false,
};

pub const FileCommandPlan = struct {
    file_args: []const []const u8 = &.{},
    fallback_args: []const []const u8 = &.{},
};

pub const CommandPlan = union(enum) {
    argv: []const []const u8,
    optional_file: FileCommandPlan,
    required_file: []const []const u8,
    required_path: []const []const u8,
};

pub const ZlsPlan = struct {
    method: []const u8,
    requires_document_sync: bool = false,
    mutates_document_state: bool = false,
    required_capability: ?[]const u8 = null,
};

pub const PlanPolicy = union(enum) {
    exact_command: CommandPlan,
    dynamic_command: []const u8,
    zls_request: ZlsPlan,
    apply_gated_mutation: []const u8,
    workspace_artifact: []const u8,
    pure_analysis: []const u8,
    not_plannable: []const u8,
};

pub const ToolManifestEntry = struct {
    name: []const u8,
    description: []const u8 = "",
    group: []const u8 = "",
    read_only: bool = true,
    mcp_read_only_hint: bool = true,
    plan_kind: []const u8 = "pure_analysis",
    plan: PlanPolicy = .{ .pure_analysis = "" },
    risk: ToolRisk = .{},
};

pub const ToolManifestCatalog = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        count: *const fn (*anyopaque) usize,
        entry_at: *const fn (*anyopaque, usize) ?ToolManifestEntry,
        find: *const fn (*anyopaque, []const u8) ?ToolManifestEntry,
    };

    pub fn count(self: ToolManifestCatalog) usize {
        return self.vtable.count(self.ptr);
    }

    pub fn entryAt(self: ToolManifestCatalog, index: usize) ?ToolManifestEntry {
        return self.vtable.entry_at(self.ptr, index);
    }

    pub fn find(self: ToolManifestCatalog, name: []const u8) ?ToolManifestEntry {
        return self.vtable.find(self.ptr, name);
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

pub const ObservabilityToolStats = struct {
    name: []const u8 = "",
    calls: u64 = 0,
    errors: u64 = 0,
    total_latency_ms: u64 = 0,
    max_latency_ms: u64 = 0,
    last_latency_ms: u64 = 0,
    last_error: bool = false,
};

pub const ObservabilityBackendEvent = struct {
    sequence: u64 = 0,
    backend: []const u8 = "",
    ok: bool = false,
    status: []const u8 = "",
    resolution: []const u8 = "",
};

pub const ObservabilityZlsEvent = struct {
    sequence: u64 = 0,
    status: []const u8 = "",
    failure: ?[]const u8 = null,
    restart_attempts: u64 = 0,
};

pub const ObservabilityCommandEvent = struct {
    sequence: u64 = 0,
    title: []const u8 = "",
    argv0: []const u8 = "",
    duration_ms: i64 = 0,
    ok: bool = false,
    error_name: ?[]const u8 = null,
};

pub const ObservabilitySnapshot = struct {
    tool_stats: []const ObservabilityToolStats = &.{},
    command_events: []const ObservabilityCommandEvent = &.{},
    backend_events: []const ObservabilityBackendEvent = &.{},
    zls_events: []const ObservabilityZlsEvent = &.{},
    total_tool_calls: u64 = 0,
    total_tool_errors: u64 = 0,
    total_command_duration_ms: u64 = 0,
    command_event_count: u64 = 0,
    backend_event_count: u64 = 0,
    zls_event_count: u64 = 0,
    owns_memory: bool = false,

    pub fn deinit(self: ObservabilitySnapshot, allocator: Allocator) void {
        if (!self.owns_memory) return;
        allocator.free(self.tool_stats);
        allocator.free(self.command_events);
        allocator.free(self.backend_events);
        allocator.free(self.zls_events);
    }
};

pub const ObservabilityReader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        snapshot: *const fn (*anyopaque, Allocator) PortError!ObservabilitySnapshot,
    };

    pub fn snapshot(self: ObservabilityReader, allocator: Allocator) PortError!ObservabilitySnapshot {
        return self.vtable.snapshot(self.ptr, allocator);
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
