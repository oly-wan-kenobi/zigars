//! App-side port contracts that isolate usecases from filesystem/process/LSP
//! adapters. Owned buffers are explicitly tracked with `owns_*` flags.
const std = @import("std");
const cancellation = @import("cancellation");

const Allocator = std.mem.Allocator;

/// Borrowed cooperative cancellation token carried through runtime ports.
pub const CancellationToken = cancellation.Token;

/// Shared error set used by app ports to normalize adapter failures into one
/// transport-neutral vocabulary. `PathOutsideWorkspace`/`EmptyPath` are the
/// sandbox-boundary signals every path-taking adapter must raise rather than
/// touching the path; the limit variants encode the bounded-output/retention
/// caps adapters enforce so a usecase can never receive unbounded data.
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
    Cancelled,
    PathOutsideWorkspace,
    EmptyPath,
    DocumentTooLarge,
    OpenDocumentLimitExceeded,
    RetainedContentLimitExceeded,
    OutputLimitExceeded,
    StreamTooLong,
    OutOfMemory,
};

/// Protocol helper feature requested by an app use case through the MCP adapter.
pub const ProtocolFeature = enum {
    elicitation,
    sampling,
};

/// Normalized response status for server-to-client protocol helper requests.
pub const ProtocolResponseStatus = enum {
    accepted,
    declined,
    cancelled,
    malformed,
    timeout,
    unsupported,
    error_response,
};

/// Protocol helper request sent from a use case to the active MCP client.
pub const ProtocolRequest = struct {
    feature: ProtocolFeature,
    method: []const u8,
    params: std.json.Value,
    timeout_ms: ?u64 = null,
};

/// Protocol helper response with allocator-owned result when owns_result is true.
pub const ProtocolResponse = struct {
    supported: bool = false,
    used: bool = false,
    status: ProtocolResponseStatus = .unsupported,
    result: ?std.json.Value = null,
    owns_result: bool = false,
    unavailable_reason: []const u8 = "",
};

/// Vtable-backed MCP client protocol helper port.
pub const ProtocolClient = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request: *const fn (*anyopaque, Allocator, ProtocolRequest) PortError!ProtocolResponse,
    };

    /// Sends a protocol helper request through the active MCP transport. When the
    /// returned response has `owns_result` set, its `result` JSON value was cloned
    /// into `allocator` and the caller owns it; unlike most port results this
    /// struct has no `deinit`, so the caller frees it directly.
    pub fn request(self: ProtocolClient, allocator: Allocator, request_value: ProtocolRequest) PortError!ProtocolResponse {
        return self.vtable.request(self.ptr, allocator, request_value);
    }
};

/// Snapshot limits for bounded observability reads.
pub const max_observability_tool_stats = 64;
/// Maximum MCP method stats returned by a bounded observability snapshot.
pub const max_observability_method_stats = 32;
/// Maximum latency samples retained per observed key.
pub const max_observability_latency_samples = 64;
/// Minimum samples before latency percentiles should be rendered.
pub const min_observability_percentile_samples = 5;
/// Maximum recent MCP tool-call correlation rows returned by a bounded snapshot.
pub const max_observability_tool_call_correlations = 64;
/// Maximum retained request-id bytes for one observed tool-call correlation.
pub const max_observability_request_id_value_len = 64;
/// Maximum command event rows returned by a bounded observability snapshot.
pub const max_observability_command_events = 64;
/// Maximum backend event rows returned by a bounded observability snapshot.
pub const max_observability_backend_events = 64;
/// Maximum ZLS event rows returned by a bounded observability snapshot.
pub const max_observability_zls_events = 64;
/// Maximum startup phase timing rows returned by a bounded observability snapshot.
pub const max_observability_startup_phases = 24;
/// Maximum cancellation event rows returned by a bounded observability snapshot.
pub const max_observability_cancellation_events = 32;

/// Command invocation requested by app use cases.
/// Slices are borrowed; adapters decide whether returned output is owned.
pub const CommandRequest = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    max_stdout_bytes: ?usize = null,
    max_stderr_bytes: ?usize = null,
    provenance: []const u8 = "",
};

/// Normalized process termination kind.
pub const CommandTerm = union(enum) {
    exited: i32,
    signal,
    stopped,
    unknown,

    /// Stable string used in JSON result payloads.
    pub fn name(self: CommandTerm) []const u8 {
        return switch (self) {
            .exited => "exited",
            .signal => "signal",
            .stopped => "stopped",
            .unknown => "unknown",
        };
    }

    /// Returns the exit code only for normally exited processes.
    pub fn exitCode(self: CommandTerm) ?i64 {
        return switch (self) {
            .exited => |code| @intCast(code),
            else => null,
        };
    }

    /// Non-zero exits and non-exit terms are failures.
    pub fn failed(self: CommandTerm) bool {
        return switch (self) {
            .exited => |code| code != 0,
            else => true,
        };
    }
};

/// Command output returned by a CommandRunner.
/// stdout/stderr are borrowed unless the owns_* flags are set.
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

    /// Frees command output only when ownership was transferred by the port.
    pub fn deinit(self: CommandResult, allocator: Allocator) void {
        if (self.owns_stdout) allocator.free(self.stdout);
        if (self.owns_stderr) allocator.free(self.stderr);
    }

    /// Preserves the scalar exit-code fallback when term did not carry a non-zero exit.
    pub fn effectiveTerm(self: CommandResult) CommandTerm {
        return switch (self.term) {
            .exited => |code| if (code == 0 and self.exit_code != 0) .{ .exited = self.exit_code } else .{ .exited = code },
            else => self.term,
        };
    }
};

/// Vtable-backed process runner port.
pub const CommandRunner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing command execution.
    pub const VTable = struct {
        run: *const fn (*anyopaque, Allocator, CommandRequest) PortError!CommandResult,
    };

    /// Executes a command and returns output with explicit ownership flags.
    pub fn run(self: CommandRunner, allocator: Allocator, request: CommandRequest) PortError!CommandResult {
        return self.vtable.run(self.ptr, allocator, request);
    }
};

/// Workspace read request for paths resolved by the adapter.
pub const WorkspaceReadRequest = struct {
    path: []const u8,
    max_bytes: ?usize = null,
    for_output: ?bool = null,
    provenance: []const u8 = "",
};

/// Workspace path resolution request.
pub const WorkspaceResolveRequest = struct {
    path: []const u8,
    for_output: bool = false,
    provenance: []const u8 = "",
};

/// Resolved workspace path; path is borrowed unless owns_path is set.
pub const WorkspaceResolveResult = struct {
    path: []const u8,
    owns_path: bool = false,

    /// `path` is borrowed unless `owns_path` is set by the adapter.
    pub fn deinit(self: WorkspaceResolveResult, allocator: Allocator) void {
        if (self.owns_path) allocator.free(self.path);
    }
};

/// Bytes read from workspace storage; bytes are borrowed unless owns_bytes is set.
pub const WorkspaceReadResult = struct {
    bytes: []const u8,
    owns_bytes: bool = false,

    /// `bytes` is borrowed unless `owns_bytes` is set by the adapter.
    pub fn deinit(self: WorkspaceReadResult, allocator: Allocator) void {
        if (self.owns_bytes) allocator.free(self.bytes);
    }
};

/// Workspace write request for already-buffered content.
pub const WorkspaceWriteRequest = struct {
    path: []const u8,
    bytes: []const u8,
    create_parent_dirs: bool = true,
    replace_existing: bool = true,
    provenance: []const u8 = "",
};

/// Workspace write outcome.
pub const WorkspaceWriteResult = struct {
    bytes_written: usize,
    replaced_existing: bool = false,
};

/// Workspace delete request.
pub const WorkspaceDeleteRequest = struct {
    path: []const u8,
    missing_ok: bool = true,
    provenance: []const u8 = "",
};

/// Workspace delete outcome.
pub const WorkspaceDeleteResult = struct {
    deleted: bool,
};

/// Kind metadata returned by workspace existence checks.
pub const WorkspaceEntryKind = enum {
    file,
    directory,
};

/// Workspace existence request.
pub const WorkspaceExistsRequest = struct {
    path: []const u8,
    for_output: bool = false,
    provenance: []const u8 = "",
};

/// Workspace existence result with optional kind/count metadata.
pub const WorkspaceExistsResult = struct {
    exists: bool,
    kind: ?WorkspaceEntryKind = null,
    entry_count: ?usize = null,
};

/// Directory creation request.
pub const WorkspaceEnsureDirRequest = struct {
    path: []const u8,
    provenance: []const u8 = "",
};

/// Directory creation outcome.
pub const WorkspaceEnsureDirResult = struct {
    created_or_existing: bool = true,
};

/// Bounded directory scan request.
pub const WorkspaceDirectoryScanRequest = struct {
    path: []const u8,
    suffix: []const u8 = "",
    max_files: ?usize = null,
    for_output: bool = true,
    provenance: []const u8 = "",
};

/// Single directory scan entry.
pub const WorkspaceDirectoryEntry = struct {
    path: []const u8,
};

/// Directory scan result; entries are borrowed unless owns_memory is set.
pub const WorkspaceDirectoryScanResult = struct {
    entries: []WorkspaceDirectoryEntry,
    owns_memory: bool = false,

    /// Frees entry paths and the entries slice when owned by the result.
    pub fn deinit(self: WorkspaceDirectoryScanResult, allocator: Allocator) void {
        if (!self.owns_memory) return;
        for (self.entries) |entry| allocator.free(entry.path);
        allocator.free(self.entries);
    }
};

/// Workspace-wide scan request.
pub const WorkspaceScanRequest = struct {
    path_prefix: []const u8 = "",
    max_files: ?usize = null,
    provenance: []const u8 = "",
};

/// Single workspace scan file entry.
pub const WorkspaceScanFile = struct {
    path: []const u8,
};

/// Workspace scan result; file paths are borrowed unless owns_memory is set.
pub const WorkspaceScanResult = struct {
    files: []WorkspaceScanFile,
    owns_memory: bool = false,

    /// Frees file paths and the files slice when owned by the result.
    pub fn deinit(self: WorkspaceScanResult, allocator: Allocator) void {
        if (!self.owns_memory) return;
        for (self.files) |file| allocator.free(file.path);
        allocator.free(self.files);
    }
};

/// Vtable-backed workspace storage port.
pub const WorkspaceStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing workspace storage operations.
    pub const VTable = struct {
        resolve: ?*const fn (*anyopaque, Allocator, WorkspaceResolveRequest) PortError!WorkspaceResolveResult = null,
        read: *const fn (*anyopaque, Allocator, WorkspaceReadRequest) PortError!WorkspaceReadResult,
        write: *const fn (*anyopaque, WorkspaceWriteRequest) PortError!WorkspaceWriteResult,
        delete: ?*const fn (*anyopaque, WorkspaceDeleteRequest) PortError!WorkspaceDeleteResult = null,
        exists: ?*const fn (*anyopaque, Allocator, WorkspaceExistsRequest) PortError!WorkspaceExistsResult = null,
        ensure_dir: ?*const fn (*anyopaque, WorkspaceEnsureDirRequest) PortError!WorkspaceEnsureDirResult = null,
        scan_directory: ?*const fn (*anyopaque, Allocator, WorkspaceDirectoryScanRequest) PortError!WorkspaceDirectoryScanResult = null,
    };

    /// Resolves a workspace path, or returns UnexpectedCall if the adapter lacks resolve support.
    pub fn resolve(self: WorkspaceStore, allocator: Allocator, request: WorkspaceResolveRequest) PortError!WorkspaceResolveResult {
        const resolve_fn = self.vtable.resolve orelse return error.UnexpectedCall;
        return resolve_fn(self.ptr, allocator, request);
    }

    /// Reads workspace bytes with explicit result ownership.
    pub fn read(self: WorkspaceStore, allocator: Allocator, request: WorkspaceReadRequest) PortError!WorkspaceReadResult {
        return self.vtable.read(self.ptr, allocator, request);
    }

    /// Writes bytes after the adapter resolves the path under the workspace
    /// sandbox. This port does not enforce the source-mutation apply gate; that
    /// is a usecase-layer decision made before any write request reaches here.
    pub fn write(self: WorkspaceStore, request: WorkspaceWriteRequest) PortError!WorkspaceWriteResult {
        return self.vtable.write(self.ptr, request);
    }

    /// Deletes a workspace path, or returns UnexpectedCall if unsupported.
    pub fn delete(self: WorkspaceStore, request: WorkspaceDeleteRequest) PortError!WorkspaceDeleteResult {
        const delete_fn = self.vtable.delete orelse return error.UnexpectedCall;
        return delete_fn(self.ptr, request);
    }

    /// Checks path existence, or returns UnexpectedCall if unsupported.
    pub fn exists(self: WorkspaceStore, allocator: Allocator, request: WorkspaceExistsRequest) PortError!WorkspaceExistsResult {
        const exists_fn = self.vtable.exists orelse return error.UnexpectedCall;
        return exists_fn(self.ptr, allocator, request);
    }

    /// Ensures a directory exists, or returns UnexpectedCall if unsupported.
    pub fn ensureDir(self: WorkspaceStore, request: WorkspaceEnsureDirRequest) PortError!WorkspaceEnsureDirResult {
        const ensure_dir_fn = self.vtable.ensure_dir orelse return error.UnexpectedCall;
        return ensure_dir_fn(self.ptr, request);
    }

    /// Scans a directory, or returns UnexpectedCall if unsupported.
    pub fn scanDirectory(self: WorkspaceStore, allocator: Allocator, request: WorkspaceDirectoryScanRequest) PortError!WorkspaceDirectoryScanResult {
        const scan_directory_fn = self.vtable.scan_directory orelse return error.UnexpectedCall;
        return scan_directory_fn(self.ptr, allocator, request);
    }
};

/// Vtable-backed workspace scanner specialized for source discovery.
pub const WorkspaceScanner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing source scans.
    pub const VTable = struct {
        scan_zig_files: *const fn (*anyopaque, Allocator, WorkspaceScanRequest) PortError!WorkspaceScanResult,
    };

    /// Scans for Zig source files and returns owned entries only when marked.
    pub fn scanZigFiles(self: WorkspaceScanner, allocator: Allocator, request: WorkspaceScanRequest) PortError!WorkspaceScanResult {
        return self.vtable.scan_zig_files(self.ptr, allocator, request);
    }
};

/// Toolchain environment lookup request.
pub const ToolchainEnvRequest = struct {
    key: []const u8,
    provenance: []const u8 = "",
};

/// Environment value; value is borrowed unless owns_value is set.
pub const ToolchainEnvValue = struct {
    value: []const u8,
    owns_value: bool = false,

    /// Frees the value only when ownership was transferred by the port.
    pub fn deinit(self: ToolchainEnvValue, allocator: Allocator) void {
        if (self.owns_value) allocator.free(self.value);
    }
};

/// Vtable-backed toolchain environment port.
pub const ToolchainEnv = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing toolchain environment reads.
    pub const VTable = struct {
        get: *const fn (*anyopaque, Allocator, ToolchainEnvRequest) PortError!ToolchainEnvValue,
    };

    /// Reads one environment-derived value.
    pub fn get(self: ToolchainEnv, allocator: Allocator, request: ToolchainEnvRequest) PortError!ToolchainEnvValue {
        return self.vtable.get(self.ptr, allocator, request);
    }
};

/// Absolute documentation file read request.
pub const DocsReadAbsoluteRequest = struct {
    path: []const u8,
    max_bytes: usize,
    provenance: []const u8 = "",
};

/// Documentation bytes; bytes are borrowed unless owns_bytes is set.
pub const DocsReadResult = struct {
    bytes: []const u8,
    owns_bytes: bool = false,

    /// Frees the byte buffer only when owned by the result.
    pub fn deinit(self: DocsReadResult, allocator: Allocator) void {
        if (self.owns_bytes) allocator.free(self.bytes);
    }
};

/// Absolute-root Zig path scan request.
pub const DocsScanAbsoluteZigPathsRequest = struct {
    root: []const u8,
    max_files: ?usize = null,
    provenance: []const u8 = "",
};

/// Workspace documentation path scan request.
pub const DocsScanWorkspacePathsRequest = struct {
    max_files: ?usize = null,
    provenance: []const u8 = "",
};

/// Borrowed documentation path entry.
pub const DocsPath = struct {
    path: []const u8,
};

/// Documentation path scan result with bounded walk diagnostics.
pub const DocsPathScanResult = struct {
    paths: []DocsPath,
    walk_errors: usize = 0,
    truncated: bool = false,
    owns_memory: bool = false,

    /// Frees path strings and the path slice when owned by the result.
    pub fn deinit(self: DocsPathScanResult, allocator: Allocator) void {
        if (!self.owns_memory) return;
        for (self.paths) |path| allocator.free(path.path);
        allocator.free(self.paths);
    }
};

/// Vtable-backed documentation scanner for std, autodoc, and workspace docs.
pub const DocsScanner = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing documentation reads and scans.
    pub const VTable = struct {
        read_absolute: *const fn (*anyopaque, Allocator, DocsReadAbsoluteRequest) PortError!DocsReadResult,
        scan_absolute_zig_paths: *const fn (*anyopaque, Allocator, DocsScanAbsoluteZigPathsRequest) PortError!DocsPathScanResult,
        scan_workspace_paths: *const fn (*anyopaque, Allocator, DocsScanWorkspacePathsRequest) PortError!DocsPathScanResult,
    };

    /// Reads an absolute documentation path.
    pub fn readAbsolute(self: DocsScanner, allocator: Allocator, request: DocsReadAbsoluteRequest) PortError!DocsReadResult {
        return self.vtable.read_absolute(self.ptr, allocator, request);
    }

    /// Scans an absolute root for Zig documentation sources.
    pub fn scanAbsoluteZigPaths(self: DocsScanner, allocator: Allocator, request: DocsScanAbsoluteZigPathsRequest) PortError!DocsPathScanResult {
        return self.vtable.scan_absolute_zig_paths(self.ptr, allocator, request);
    }

    /// Scans workspace documentation paths.
    pub fn scanWorkspacePaths(self: DocsScanner, allocator: Allocator, request: DocsScanWorkspacePathsRequest) PortError!DocsPathScanResult {
        return self.vtable.scan_workspace_paths(self.ptr, allocator, request);
    }
};

/// Request to check a ZLS capability name.
pub const ZlsCapabilityRequest = struct {
    capability: []const u8,
};

/// ZLS capability check result.
pub const ZlsCapabilityResult = struct {
    capability: []const u8,
    supported: bool,
    basis: []const u8 = "",
};

/// Request to synchronize file content with the ZLS adapter.
pub const ZlsSyncRequest = struct {
    file: []const u8,
    content: ?[]const u8 = null,
    provenance: []const u8 = "",
};

/// ZLS sync result; uri is borrowed unless owns_uri is set.
pub const ZlsSyncResult = struct {
    uri: []const u8,
    basis: []const u8 = "",
    owns_uri: bool = false,

    /// Frees the URI only when ownership was transferred by the port.
    pub fn deinit(self: ZlsSyncResult, allocator: Allocator) void {
        if (self.owns_uri) allocator.free(self.uri);
    }
};

/// Raw LSP request passed through the ZLS gateway.
pub const ZlsRequest = struct {
    method: []const u8,
    uri: ?[]const u8 = null,
    payload: []const u8 = "",
};

/// Raw LSP response; payload is borrowed unless owns_payload is set.
pub const ZlsResponse = struct {
    method: []const u8,
    payload: []const u8 = "",
    owns_payload: bool = false,

    /// Frees the payload only when ownership was transferred by the port.
    pub fn deinit(self: ZlsResponse, allocator: Allocator) void {
        if (self.owns_payload) allocator.free(self.payload);
    }
};

/// Memory and eviction counters for cached ZLS diagnostics.
pub const ZlsDiagnosticsStatus = struct {
    files: usize = 0,
    retained_bytes: usize = 0,
    max_bytes: usize = 0,
    evicted_files: usize = 0,
    evicted_bytes: usize = 0,
    dropped_oversized: usize = 0,
};

/// Cached raw publishDiagnostics messages; messages are owned when `owns_messages` is set.
pub const ZlsDiagnosticsSnapshot = struct {
    messages: []const []const u8 = &.{},
    status: ZlsDiagnosticsStatus = .{},
    owns_messages: bool = false,

    /// Frees cloned diagnostic messages only when ownership was transferred by the port.
    pub fn deinit(self: ZlsDiagnosticsSnapshot, allocator: Allocator) void {
        if (!self.owns_messages) return;
        for (self.messages) |message| allocator.free(message);
        allocator.free(self.messages);
    }
};

/// Vtable-backed ZLS gateway that owns protocol state in the adapter.
pub const ZlsGateway = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing ZLS capability, sync, and request operations.
    pub const VTable = struct {
        capability: *const fn (*anyopaque, ZlsCapabilityRequest) PortError!ZlsCapabilityResult,
        sync: *const fn (*anyopaque, Allocator, ZlsSyncRequest) PortError!ZlsSyncResult,
        request: *const fn (*anyopaque, Allocator, ZlsRequest) PortError!ZlsResponse,
        diagnostics: *const fn (*anyopaque, Allocator) PortError!ZlsDiagnosticsSnapshot,
    };

    /// Checks whether a named ZLS capability is available.
    pub fn capability(self: ZlsGateway, capability_request: ZlsCapabilityRequest) PortError!ZlsCapabilityResult {
        return self.vtable.capability(self.ptr, capability_request);
    }

    /// Synchronizes document state before requests that need a URI.
    pub fn sync(self: ZlsGateway, allocator: Allocator, sync_request: ZlsSyncRequest) PortError!ZlsSyncResult {
        return self.vtable.sync(self.ptr, allocator, sync_request);
    }

    /// Sends a raw LSP request through ZLS and returns a possibly-owned payload.
    pub fn request(self: ZlsGateway, allocator: Allocator, request_value: ZlsRequest) PortError!ZlsResponse {
        return self.vtable.request(self.ptr, allocator, request_value);
    }

    /// Returns cached raw workspace diagnostics without issuing a new ZLS request.
    pub fn diagnostics(self: ZlsGateway, allocator: Allocator) PortError!ZlsDiagnosticsSnapshot {
        return self.vtable.diagnostics(self.ptr, allocator);
    }
};

/// Backend availability probe request.
pub const BackendProbeRequest = struct {
    backend: []const u8,
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    required_capabilities: []const []const u8 = &.{},
    provenance: []const u8 = "",
};

/// Backend availability result; fields are borrowed unless owns_memory is set.
pub const BackendAvailability = struct {
    backend: []const u8,
    available: bool,
    version: ?[]const u8 = null,
    capabilities: []const []const u8 = &.{},
    unavailable_reason: ?[]const u8 = null,
    basis: []const u8 = "",
    owns_memory: bool = false,

    /// Frees backend availability fields when owned by the result.
    pub fn deinit(self: BackendAvailability, allocator: Allocator) void {
        // Only release owned state here to avoid invalidating borrowed data.
        if (!self.owns_memory) return;
        allocator.free(self.backend);
        if (self.version) |value| allocator.free(value);
        for (self.capabilities) |capability| allocator.free(capability);
        allocator.free(self.capabilities);
        if (self.unavailable_reason) |value| allocator.free(value);
        allocator.free(self.basis);
    }
};

/// Vtable-backed backend availability probe.
pub const BackendProbe = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing backend availability checks.
    pub const VTable = struct {
        check: *const fn (*anyopaque, Allocator, BackendProbeRequest) PortError!BackendAvailability,
    };

    /// Checks backend availability and transfers ownership only when marked.
    pub fn check(self: BackendProbe, allocator: Allocator, request: BackendProbeRequest) PortError!BackendAvailability {
        return self.vtable.check(self.ptr, allocator, request);
    }
};

/// Static cache metadata snapshot.
pub const StaticCacheStatus = struct {
    cached: bool = false,
    signature: u64 = 0,
    hits: usize = 0,
    refreshes: usize = 0,
    bytes_len: usize = 0,
};

/// Static cache load result; bytes are borrowed unless owns_bytes is set.
pub const StaticCacheLoadResult = struct {
    status: StaticCacheStatus,
    bytes: ?[]const u8 = null,
    owns_bytes: bool = false,

    /// Frees cached bytes only when ownership was transferred by the port.
    pub fn deinit(self: StaticCacheLoadResult, allocator: Allocator) void {
        if (self.owns_bytes) if (self.bytes) |bytes| allocator.free(bytes);
    }
};

/// Static cache store request.
pub const StaticCacheStoreRequest = struct {
    signature: u64,
    bytes: []const u8,
    provenance: []const u8 = "",
};

/// Vtable-backed static cache port for expensive source-derived indexes.
pub const StaticCache = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing static cache state operations.
    pub const VTable = struct {
        status: *const fn (*anyopaque) PortError!StaticCacheStatus,
        load: *const fn (*anyopaque, Allocator) PortError!StaticCacheLoadResult,
        store: *const fn (*anyopaque, Allocator, StaticCacheStoreRequest) PortError!StaticCacheStatus,
        record_hit: *const fn (*anyopaque) PortError!StaticCacheStatus,
    };

    /// Returns cache metadata without loading cached bytes.
    pub fn status(self: StaticCache) PortError!StaticCacheStatus {
        return self.vtable.status(self.ptr);
    }

    /// Loads cached bytes when present, with ownership indicated by the result.
    pub fn load(self: StaticCache, allocator: Allocator) PortError!StaticCacheLoadResult {
        return self.vtable.load(self.ptr, allocator);
    }

    /// Stores cache bytes and returns the updated status.
    pub fn store(self: StaticCache, allocator: Allocator, request: StaticCacheStoreRequest) PortError!StaticCacheStatus {
        return self.vtable.store(self.ptr, allocator, request);
    }

    /// Records a cache hit and returns the updated status.
    pub fn recordHit(self: StaticCache) PortError!StaticCacheStatus {
        return self.vtable.record_hit(self.ptr);
    }
};

/// Artifact write request for generated evidence outside source files.
pub const ArtifactWriteRequest = struct {
    namespace: []const u8,
    name: []const u8,
    kind: []const u8,
    bytes: []const u8,
    provenance: []const u8 = "",
};

/// Reference to a written artifact; strings are borrowed unless owns_memory is set.
pub const ArtifactRef = struct {
    id: []const u8,
    uri: []const u8,
    checksum: ?[]const u8 = null,
    bytes_written: usize,
    owns_memory: bool = false,

    /// Frees artifact identity strings when owned by the result.
    pub fn deinit(self: ArtifactRef, allocator: Allocator) void {
        if (!self.owns_memory) return;
        allocator.free(self.id);
        allocator.free(self.uri);
        if (self.checksum) |value| allocator.free(value);
    }
};

/// Toolchain paths recorded with workspace artifact provenance.
pub const ArtifactToolchain = struct {
    zig_path: []const u8 = "",
    zls_path: []const u8 = "",
    zflame_path: []const u8 = "",
    diff_folded_path: []const u8 = "",
};

/// Registry record request for an artifact already present in the workspace.
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

/// Registry reference for a workspace artifact; strings are borrowed unless owned.
pub const WorkspaceArtifactRef = struct {
    path: []const u8,
    abs_path: []const u8,
    bytes: usize,
    sha256: []const u8,
    indexed_at_unix_ms: i64,
    owns_memory: bool = false,

    /// Frees registry reference strings when owned by the result.
    pub fn deinit(self: WorkspaceArtifactRef, allocator: Allocator) void {
        if (!self.owns_memory) return;
        allocator.free(self.path);
        allocator.free(self.abs_path);
        allocator.free(self.sha256);
    }
};

/// Artifact read request by artifact id.
pub const ArtifactReadRequest = struct {
    id: []const u8,
};

/// Artifact bytes; bytes are borrowed unless owns_bytes is set.
pub const ArtifactReadResult = struct {
    bytes: []const u8,
    owns_bytes: bool = false,

    /// Frees artifact bytes only when ownership was transferred by the port.
    pub fn deinit(self: ArtifactReadResult, allocator: Allocator) void {
        if (self.owns_bytes) allocator.free(self.bytes);
    }
};

/// Vtable-backed artifact store and optional workspace registry port.
pub const ArtifactStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing artifact storage operations.
    pub const VTable = struct {
        put: *const fn (*anyopaque, Allocator, ArtifactWriteRequest) PortError!ArtifactRef,
        read: *const fn (*anyopaque, Allocator, ArtifactReadRequest) PortError!ArtifactReadResult,
        record_workspace: ?*const fn (*anyopaque, Allocator, WorkspaceArtifactRecordRequest) PortError!WorkspaceArtifactRef = null,
    };

    /// Writes a generated artifact and returns its reference.
    pub fn put(self: ArtifactStore, allocator: Allocator, request: ArtifactWriteRequest) PortError!ArtifactRef {
        return self.vtable.put(self.ptr, allocator, request);
    }

    /// Reads artifact bytes by id.
    pub fn read(self: ArtifactStore, allocator: Allocator, request: ArtifactReadRequest) PortError!ArtifactReadResult {
        return self.vtable.read(self.ptr, allocator, request);
    }

    /// Records an existing workspace artifact, or returns UnexpectedCall if unsupported.
    pub fn recordWorkspace(self: ArtifactStore, allocator: Allocator, request: WorkspaceArtifactRecordRequest) PortError!WorkspaceArtifactRef {
        const record_fn = self.vtable.record_workspace orelse return error.UnexpectedCall;
        return record_fn(self.ptr, allocator, request);
    }
};

/// Runtime UX job lifecycle state.
pub const RuntimeJobStatus = enum {
    queued,
    running,
    completed,
    failed,
    cancelled,

    /// Stable JSON text for this status.
    pub fn text(self: RuntimeJobStatus) []const u8 {
        return @tagName(self);
    }

    /// True for statuses that should not receive further progress updates.
    pub fn terminal(self: RuntimeJobStatus) bool {
        return switch (self) {
            .completed, .failed, .cancelled => true,
            else => false,
        };
    }
};

/// Borrowed snapshot of one runtime UX job.
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

/// Borrowed snapshot of one runtime UX event.
pub const RuntimeEventSnapshot = struct {
    sequence: u64,
    job_id: []const u8,
    event: []const u8,
    stream: []const u8,
    message: []const u8,
    text: []const u8,
    elapsed_ms: i64,
};

/// Borrowed snapshot of one runtime UX subscription.
pub const RuntimeSubscriptionSnapshot = struct {
    id: []const u8,
    uri: []const u8,
    active: bool,
    created_sequence: u64,
};

/// Borrowed snapshot of one runtime UX workspace root.
pub const RuntimeRootSnapshot = struct {
    id: []const u8,
    path: []const u8,
    uri: []const u8,
    name: []const u8,
    selected: bool,
};

/// Completion payload used to finalize a runtime UX job.
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

/// Vtable-backed runtime UX session port.
pub const RuntimeSession = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing runtime UX session operations.
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

    /// Ensures the session has a default workspace root.
    pub fn ensureDefaultRoot(self: RuntimeSession, workspace_root: []const u8) PortError!void {
        return self.vtable.ensure_default_root(self.ptr, workspace_root);
    }

    /// Starts a runtime job and returns its snapshot.
    pub fn startJob(self: RuntimeSession, label: []const u8, command_text: []const u8, timeout_ms: i64) PortError!RuntimeJobSnapshot {
        return self.vtable.start_job(self.ptr, label, command_text, timeout_ms);
    }

    /// Marks a runtime job complete and returns its updated snapshot.
    pub fn finishJob(self: RuntimeSession, job_id: []const u8, finish: RuntimeJobFinish) PortError!RuntimeJobSnapshot {
        return self.vtable.finish_job(self.ptr, job_id, finish);
    }

    /// Marks a runtime job failed and returns its updated snapshot.
    pub fn failJob(self: RuntimeSession, job_id: []const u8, err_name: []const u8, duration_ms: i64) PortError!RuntimeJobSnapshot {
        return self.vtable.fail_job(self.ptr, job_id, err_name, duration_ms);
    }

    /// Requests runtime job cancellation and returns its updated snapshot.
    pub fn cancelJob(self: RuntimeSession, job_id: []const u8, reason: []const u8) PortError!RuntimeJobSnapshot {
        return self.vtable.cancel_job(self.ptr, job_id, reason);
    }

    /// Returns a runtime job snapshot by id.
    pub fn jobById(self: RuntimeSession, job_id: []const u8) PortError!RuntimeJobSnapshot {
        return self.vtable.job_by_id(self.ptr, job_id);
    }

    /// Returns the number of tracked runtime jobs.
    pub fn jobCount(self: RuntimeSession) PortError!usize {
        return self.vtable.job_count(self.ptr);
    }

    /// Returns a runtime job snapshot by index.
    pub fn jobAt(self: RuntimeSession, index: usize) PortError!RuntimeJobSnapshot {
        return self.vtable.job_at(self.ptr, index);
    }

    /// Returns the total runtime event count.
    pub fn eventCount(self: RuntimeSession) PortError!u64 {
        return self.vtable.event_count(self.ptr);
    }

    /// Returns a runtime event snapshot by sequence.
    pub fn eventAtSequence(self: RuntimeSession, sequence: u64) PortError!RuntimeEventSnapshot {
        return self.vtable.event_at_sequence(self.ptr, sequence);
    }

    /// Subscribes a runtime event URI and returns the subscription snapshot.
    pub fn subscribe(self: RuntimeSession, uri: []const u8) PortError!RuntimeSubscriptionSnapshot {
        return self.vtable.subscribe(self.ptr, uri);
    }

    /// Removes a runtime event subscription and returns its final snapshot.
    pub fn unsubscribe(self: RuntimeSession, id: []const u8, uri: ?[]const u8) PortError!RuntimeSubscriptionSnapshot {
        return self.vtable.unsubscribe(self.ptr, id, uri);
    }

    /// Synchronizes runtime workspace roots, optionally applying the update.
    pub fn syncRoots(self: RuntimeSession, workspace_root: []const u8, roots_text: []const u8, apply: bool) PortError!void {
        return self.vtable.sync_roots(self.ptr, workspace_root, roots_text, apply);
    }

    /// Selects a runtime workspace root, optionally applying the update.
    pub fn selectRoot(self: RuntimeSession, root_id: []const u8, apply: bool) PortError!RuntimeRootSnapshot {
        return self.vtable.select_root(self.ptr, root_id, apply);
    }

    /// Returns the number of tracked runtime roots.
    pub fn rootCount(self: RuntimeSession) PortError!usize {
        return self.vtable.root_count(self.ptr);
    }

    /// Returns the selected root index.
    pub fn selectedRootIndex(self: RuntimeSession) PortError!usize {
        return self.vtable.selected_root_index(self.ptr);
    }

    /// Returns a runtime root snapshot by index.
    pub fn rootAt(self: RuntimeSession, index: usize) PortError!RuntimeRootSnapshot {
        return self.vtable.root_at(self.ptr, index);
    }
};

/// Tool catalog text; text is borrowed unless owns_text is set.
pub const ToolCatalogText = struct {
    text: []const u8,
    owns_text: bool = false,

    /// Frees catalog text only when ownership was transferred by the port.
    pub fn deinit(self: ToolCatalogText, allocator: Allocator) void {
        if (self.owns_text) allocator.free(self.text);
    }
};

/// Vtable-backed read-only tool catalog port.
pub const ToolCatalog = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing tool catalog reads.
    pub const VTable = struct {
        text: *const fn (*anyopaque, Allocator) PortError!ToolCatalogText,
    };

    /// Returns catalog text with explicit ownership.
    pub fn text(self: ToolCatalog, allocator: Allocator) PortError!ToolCatalogText {
        return self.vtable.text(self.ptr, allocator);
    }
};

/// Declarative side-effect flags for tool planning and client hints.
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

/// Command argument policy for tools with optional file inputs.
pub const FileCommandPlan = struct {
    file_args: []const []const u8 = &.{},
    fallback_args: []const []const u8 = &.{},
};

/// Manifest command planning strategy.
pub const CommandPlan = union(enum) {
    argv: []const []const u8,
    optional_file: FileCommandPlan,
    required_file: []const []const u8,
    required_path: []const []const u8,
};

/// Manifest metadata for ZLS-backed tools.
pub const ZlsPlan = struct {
    method: []const u8,
    requires_document_sync: bool = false,
    mutates_document_state: bool = false,
    required_capability: ?[]const u8 = null,
};

/// Tool manifest execution policy used by planning surfaces.
pub const PlanPolicy = union(enum) {
    exact_command: CommandPlan,
    dynamic_command: []const u8,
    zls_request: ZlsPlan,
    apply_gated_mutation: []const u8,
    workspace_artifact: []const u8,
    pure_analysis: []const u8,
    not_plannable: []const u8,
};

/// Borrowed manifest entry describing one registered tool.
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

/// Vtable-backed read-only manifest catalog port.
pub const ToolManifestCatalog = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing manifest catalog reads.
    pub const VTable = struct {
        count: *const fn (*anyopaque) usize,
        entry_at: *const fn (*anyopaque, usize) ?ToolManifestEntry,
        find: *const fn (*anyopaque, []const u8) ?ToolManifestEntry,
    };

    /// Returns the number of manifest entries.
    pub fn count(self: ToolManifestCatalog) usize {
        return self.vtable.count(self.ptr);
    }

    /// Returns a borrowed manifest entry by index.
    pub fn entryAt(self: ToolManifestCatalog, index: usize) ?ToolManifestEntry {
        return self.vtable.entry_at(self.ptr, index);
    }

    /// Finds a borrowed manifest entry by tool name.
    pub fn find(self: ToolManifestCatalog, name: []const u8) ?ToolManifestEntry {
        return self.vtable.find(self.ptr, name);
    }
};

/// Single observability event attribute.
pub const ObservationAttribute = struct {
    key: []const u8,
    value: []const u8,
};

/// Observability event emitted by app workflows.
pub const ObservationEvent = struct {
    name: []const u8,
    phase: []const u8,
    attributes: []const ObservationAttribute = &.{},
    duration_ms: ?u64 = null,
};

/// Vtable-backed write-only observability port.
pub const ObservabilitySink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing observability emission.
    pub const VTable = struct {
        emit: *const fn (*anyopaque, ObservationEvent) PortError!void,
    };

    /// Emits one event; event slices are borrowed for the duration of the call.
    pub fn emit(self: ObservabilitySink, event: ObservationEvent) PortError!void {
        return self.vtable.emit(self.ptr, event);
    }
};

/// Aggregated tool call metrics for one tool.
pub const ObservabilityToolStats = struct {
    name: []const u8 = "",
    calls: u64 = 0,
    errors: u64 = 0,
    total_latency_ms: u64 = 0,
    max_latency_ms: u64 = 0,
    last_latency_ms: u64 = 0,
    last_error: bool = false,
    latency_samples: [max_observability_latency_samples]u64 = [_]u64{0} ** max_observability_latency_samples,
    latency_sample_count: u64 = 0,
};

/// Aggregated MCP request method metrics for one method.
pub const ObservabilityMethodStats = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    name_truncated: bool = false,
    calls: u64 = 0,
    errors: u64 = 0,
    total_latency_ms: u64 = 0,
    max_latency_ms: u64 = 0,
    last_latency_ms: u64 = 0,
    last_error: bool = false,
    latency_samples: [max_observability_latency_samples]u64 = [_]u64{0} ** max_observability_latency_samples,
    latency_sample_count: u64 = 0,

    /// Returns the retained method name.
    pub fn nameSlice(self: *const ObservabilityMethodStats) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Borrowed MCP tool-call correlation snapshot.
pub const ObservabilityToolCallCorrelation = struct {
    sequence: u64 = 0,
    tool_name: []const u8 = "",
    is_error: bool = false,
    mcp_request_id_type: []const u8 = "null",
    mcp_request_id_value: [max_observability_request_id_value_len]u8 = [_]u8{0} ** max_observability_request_id_value_len,
    mcp_request_id_value_len: usize = 0,
    mcp_request_id_truncated: bool = false,
    trace_id: [32]u8 = [_]u8{'0'} ** 32,
    span_id: [16]u8 = [_]u8{'0'} ** 16,
    parent_span_id: ?[16]u8 = null,
    tool_call_id: [22]u8 = [_]u8{0} ** 22,
    tool_call_id_len: usize = 0,

    /// Returns the retained request-id value, or null when the request had no id.
    pub fn requestIdValue(self: *const ObservabilityToolCallCorrelation) ?[]const u8 {
        if (std.mem.eql(u8, self.mcp_request_id_type, "null")) return null;
        return self.mcp_request_id_value[0..self.mcp_request_id_value_len];
    }

    /// Returns the retained trace id.
    pub fn traceId(self: *const ObservabilityToolCallCorrelation) []const u8 {
        return self.trace_id[0..];
    }

    /// Returns the retained span id.
    pub fn spanId(self: *const ObservabilityToolCallCorrelation) []const u8 {
        return self.span_id[0..];
    }

    /// Returns the retained parent span id, when present.
    pub fn parentSpanId(self: *const ObservabilityToolCallCorrelation) ?[]const u8 {
        return if (self.parent_span_id) |span| span[0..] else null;
    }

    /// Returns the retained tool-call id.
    pub fn toolCallId(self: *const ObservabilityToolCallCorrelation) []const u8 {
        return self.tool_call_id[0..self.tool_call_id_len];
    }
};

/// Borrowed backend probe event snapshot.
pub const ObservabilityBackendEvent = struct {
    sequence: u64 = 0,
    backend: []const u8 = "",
    ok: bool = false,
    status: []const u8 = "",
    resolution: []const u8 = "",
};

/// Borrowed ZLS lifecycle event snapshot.
pub const ObservabilityZlsEvent = struct {
    sequence: u64 = 0,
    status: []const u8 = "",
    failure: ?[]const u8 = null,
    restart_attempts: u64 = 0,
};

/// Borrowed command execution event snapshot.
pub const ObservabilityCommandEvent = struct {
    sequence: u64 = 0,
    title: []const u8 = "",
    argv0: []const u8 = "",
    duration_ms: i64 = 0,
    ok: bool = false,
    error_name: ?[]const u8 = null,
};

/// Borrowed startup phase timing snapshot.
pub const ObservabilityStartupPhase = struct {
    sequence: u64 = 0,
    name: []const u8 = "",
    start_ms: u64 = 0,
    duration_ms: u64 = 0,
};

/// Borrowed cancellation notification outcome snapshot.
pub const ObservabilityCancellationEvent = struct {
    sequence: u64 = 0,
    status: []const u8 = "",
    mcp_request_id_type: []const u8 = "null",
    mcp_request_id_value: [max_observability_request_id_value_len]u8 = [_]u8{0} ** max_observability_request_id_value_len,
    mcp_request_id_value_len: usize = 0,
    mcp_request_id_truncated: bool = false,
    method: [64]u8 = [_]u8{0} ** 64,
    method_len: usize = 0,
    method_truncated: bool = false,

    /// Returns the retained request-id value, or null when none was present.
    pub fn requestIdValue(self: *const ObservabilityCancellationEvent) ?[]const u8 {
        if (std.mem.eql(u8, self.mcp_request_id_type, "null")) return null;
        return self.mcp_request_id_value[0..self.mcp_request_id_value_len];
    }

    /// Returns the retained method name.
    pub fn methodSlice(self: *const ObservabilityCancellationEvent) []const u8 {
        return self.method[0..self.method_len];
    }
};

/// Bounded metrics snapshot; slices are borrowed unless owns_memory is set.
pub const ObservabilitySnapshot = struct {
    tool_stats: []const ObservabilityToolStats = &.{},
    method_stats: []const ObservabilityMethodStats = &.{},
    tool_call_correlations: []const ObservabilityToolCallCorrelation = &.{},
    command_events: []const ObservabilityCommandEvent = &.{},
    backend_events: []const ObservabilityBackendEvent = &.{},
    zls_events: []const ObservabilityZlsEvent = &.{},
    startup_phases: []const ObservabilityStartupPhase = &.{},
    cancellation_events: []const ObservabilityCancellationEvent = &.{},
    total_tool_calls: u64 = 0,
    total_tool_errors: u64 = 0,
    total_mcp_requests: u64 = 0,
    total_mcp_request_errors: u64 = 0,
    total_command_duration_ms: u64 = 0,
    command_latency_samples: [max_observability_latency_samples]u64 = [_]u64{0} ** max_observability_latency_samples,
    command_latency_sample_count: u64 = 0,
    tool_call_correlation_count: u64 = 0,
    command_event_count: u64 = 0,
    backend_event_count: u64 = 0,
    zls_event_count: u64 = 0,
    startup_phase_count: u64 = 0,
    cancellation_event_count: u64 = 0,
    audit_enabled: bool = false,
    audit_mode: []const u8 = "disabled",
    audit_path: ?[]const u8 = null,
    audit_records_written: u64 = 0,
    audit_write_errors: u64 = 0,
    audit_last_error: ?[]const u8 = null,
    cancellation_requested: u64 = 0,
    cancellation_unknown: u64 = 0,
    cancellation_completed: u64 = 0,
    cancellation_uncancellable: u64 = 0,
    owns_memory: bool = false,

    /// Frees snapshot slices when owned by the result.
    pub fn deinit(self: ObservabilitySnapshot, allocator: Allocator) void {
        // Only release owned state here to avoid invalidating borrowed data.
        if (!self.owns_memory) return;
        allocator.free(self.tool_stats);
        allocator.free(self.method_stats);
        allocator.free(self.tool_call_correlations);
        allocator.free(self.command_events);
        allocator.free(self.backend_events);
        allocator.free(self.zls_events);
        allocator.free(self.startup_phases);
        allocator.free(self.cancellation_events);
    }
};

/// Vtable-backed read-only observability port.
pub const ObservabilityReader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing observability snapshots.
    pub const VTable = struct {
        snapshot: *const fn (*anyopaque, Allocator) PortError!ObservabilitySnapshot,
    };

    /// Returns a bounded metrics snapshot.
    pub fn snapshot(self: ObservabilityReader, allocator: Allocator) PortError!ObservabilitySnapshot {
        return self.vtable.snapshot(self.ptr, allocator);
    }
};

/// Write-only observability recorder used by the MCP server adapter to record
/// adapter-level lifecycle events without depending on a concrete metrics
/// implementation. All calls are infallible best-effort sinks (counters/rings);
/// the borrowed slices are valid only for the duration of the call.
pub const ObservabilityRecorder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing best-effort observability recording.
    pub const VTable = struct {
        record_mcp_request: *const fn (*anyopaque, method: []const u8, latency_ms: u64, is_error: bool) void,
        record_cancellation: *const fn (*anyopaque, status: []const u8, request_id_type: []const u8, request_id_value: ?[]const u8, method: ?[]const u8) void,
        record_startup_phase: *const fn (*anyopaque, name: []const u8, start_ms: u64, duration_ms: u64) void,
        record_audit_write_ok: *const fn (*anyopaque) void,
        record_audit_write_error: *const fn (*anyopaque, err_name: []const u8) void,
    };

    /// Records per-MCP-method request latency and error counters.
    pub fn recordMcpRequest(self: ObservabilityRecorder, method: []const u8, latency_ms: u64, is_error: bool) void {
        self.vtable.record_mcp_request(self.ptr, method, latency_ms, is_error);
    }

    /// Records one inbound cancellation notification outcome.
    pub fn recordCancellation(self: ObservabilityRecorder, status: []const u8, request_id_type: []const u8, request_id_value: ?[]const u8, method: ?[]const u8) void {
        self.vtable.record_cancellation(self.ptr, status, request_id_type, request_id_value, method);
    }

    /// Records one monotonic startup phase timing.
    pub fn recordStartupPhase(self: ObservabilityRecorder, name: []const u8, start_ms: u64, duration_ms: u64) void {
        self.vtable.record_startup_phase(self.ptr, name, start_ms, duration_ms);
    }

    /// Records one successful audit append.
    pub fn recordAuditWriteOk(self: ObservabilityRecorder) void {
        self.vtable.record_audit_write_ok(self.ptr);
    }

    /// Records one failed audit append.
    pub fn recordAuditWriteError(self: ObservabilityRecorder, err_name: []const u8) void {
        self.vtable.record_audit_write_error(self.ptr, err_name);
    }
};

/// Correlation snapshot carried with one audit event. Slices are borrowed for
/// the duration of the `AuditSink.append` call.
pub const AuditCorrelation = struct {
    schema_version: u8 = 1,
    mcp_request_id_type: []const u8 = "null",
    mcp_request_id_value: ?[]const u8 = null,
    mcp_method: []const u8 = "",
    tool_name: ?[]const u8 = null,
    trace_id: []const u8 = "",
    span_id: []const u8 = "",
    parent_span_id: ?[]const u8 = null,
    tool_call_id: []const u8 = "",
};

/// One audit event the adapter emits to the audit sink. Slices are borrowed for
/// the duration of the `AuditSink.append` call.
pub const AuditEvent = struct {
    event: []const u8,
    direction: []const u8,
    transport: []const u8,
    mcp_method: ?[]const u8 = null,
    mcp_request_id_type: []const u8 = "null",
    mcp_request_id_value: ?[]const u8 = null,
    correlation: ?AuditCorrelation = null,
    tool_name: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    ok: ?bool = null,
    is_error: bool = false,
    payload: ?[]const u8 = null,
};

/// Vtable-backed opt-in audit sink. The adapter never learns whether audit is
/// enabled; a disabled sink is simply absent. Append failures are swallowed by
/// the implementation and must never reach stdout or fail a request.
pub const AuditSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing audit event persistence.
    pub const VTable = struct {
        append: *const fn (*anyopaque, Allocator, AuditEvent) AuditError!void,
    };

    /// Errors raised by an audit append; callers swallow them best-effort.
    pub const AuditError = error{
        AuditDisabled,
        OutOfMemory,
        WriteFailed,
    };

    /// Appends one audit event through the configured writer.
    pub fn append(self: AuditSink, allocator: Allocator, event: AuditEvent) AuditError!void {
        return self.vtable.append(self.ptr, allocator, event);
    }
};

/// Wall-clock and monotonic timestamp pair.
pub const Instant = struct {
    unix_ms: i64,
    monotonic_ms: u64,
};

/// Request for a generated id with an optional prefix.
pub const IdRequest = struct {
    prefix: []const u8 = "",
};

/// Vtable-backed clock and id generation port.
pub const ClockAndIds = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// Adapter callbacks implementing clock and id generation.
    pub const VTable = struct {
        now: *const fn (*anyopaque) PortError!Instant,
        nextId: *const fn (*anyopaque, Allocator, IdRequest) PortError![]const u8,
    };

    /// Returns the current wall-clock and monotonic time.
    pub fn now(self: ClockAndIds) PortError!Instant {
        return self.vtable.now(self.ptr);
    }

    /// Allocates and returns a new id; caller owns the returned buffer.
    pub fn nextId(self: ClockAndIds, allocator: Allocator, request: IdRequest) PortError![]const u8 {
        return self.vtable.nextId(self.ptr, allocator, request);
    }
};
