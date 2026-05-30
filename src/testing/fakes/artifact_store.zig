//! Fake implementation of the `ports.ArtifactStore` port.
//! Stores named binary artifacts (SVGs, JSON, logs) and records workspace
//! artifact metadata. Enforces ordered expectations: every put, read, and
//! recordWorkspace call must match the next queued expectation; out-of-order
//! or unexpected calls return `error.StaleArguments` or `error.UnexpectedCall`.

const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

/// ArtifactStore fake with ordered expectations and owned call snapshots.
pub const FakeArtifactStore = struct {
    allocator: Allocator,
    expected_puts: std.ArrayList(ExpectedPut) = .empty,
    expected_reads: std.ArrayList(ExpectedRead) = .empty,
    expected_records: std.ArrayList(ExpectedRecord) = .empty,
    put_records: std.ArrayList(ports.ArtifactWriteRequest) = .empty,
    read_records: std.ArrayList(ports.ArtifactReadRequest) = .empty,
    record_workspace_records: std.ArrayList(ports.WorkspaceArtifactRecordRequest) = .empty,
    next_put: usize = 0,
    next_read: usize = 0,
    next_record: usize = 0,

    const Self = @This();

    /// Expected artifact write plus the owned reference to return.
    const ExpectedPut = struct {
        request: ports.ArtifactWriteRequest,
        ref: ports.ArtifactRef,

        /// Frees the cloned write request and returned artifact reference.
        fn deinit(self: ExpectedPut, allocator: Allocator) void {
            freeWriteRequest(allocator, self.request);
            self.ref.deinit(allocator);
        }
    };

    /// Expected artifact read plus the owned byte payload to return.
    const ExpectedRead = struct {
        request: ports.ArtifactReadRequest,
        bytes: []const u8,

        /// Frees the cloned read request and owned payload bytes.
        fn deinit(self: ExpectedRead, allocator: Allocator) void {
            freeReadRequest(allocator, self.request);
            allocator.free(self.bytes);
        }
    };

    /// Expected workspace artifact record plus the owned reference to return.
    const ExpectedRecord = struct {
        request: ports.WorkspaceArtifactRecordRequest,
        ref: ports.WorkspaceArtifactRef,

        /// Frees the cloned record request and returned workspace reference.
        fn deinit(self: ExpectedRecord, allocator: Allocator) void {
            freeRecordRequest(allocator, self.request);
            self.ref.deinit(allocator);
        }
    };

    /// Creates an empty fake that owns expectations with `allocator`.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Frees expectations and recorded call snapshots.
    pub fn deinit(self: *Self) void {
        for (self.expected_puts.items) |expected| expected.deinit(self.allocator);
        self.expected_puts.deinit(self.allocator);

        for (self.expected_reads.items) |expected| expected.deinit(self.allocator);
        self.expected_reads.deinit(self.allocator);

        for (self.expected_records.items) |expected| expected.deinit(self.allocator);
        self.expected_records.deinit(self.allocator);

        for (self.put_records.items) |record| freeWriteRequest(self.allocator, record);
        self.put_records.deinit(self.allocator);

        for (self.read_records.items) |record| freeReadRequest(self.allocator, record);
        self.read_records.deinit(self.allocator);

        for (self.record_workspace_records.items) |record| freeRecordRequest(self.allocator, record);
        self.record_workspace_records.deinit(self.allocator);
        self.* = undefined;
    }

    /// Exposes this fake through the ArtifactStore vtable.
    pub fn port(self: *Self) ports.ArtifactStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .put = put,
                .read = read,
                .record_workspace = recordWorkspace,
            },
        };
    }

    /// Adds an ordered write expectation and clones all borrowed request data.
    pub fn expectPut(self: *Self, request: ports.ArtifactWriteRequest, ref: ports.ArtifactRef) !void {
        const owned_request = try cloneWriteRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeWriteRequest(self.allocator, owned_request);
        const owned_ref = try cloneRef(self.allocator, ref);
        var ref_owned = true;
        defer if (ref_owned) owned_ref.deinit(self.allocator);

        try self.expected_puts.append(self.allocator, .{
            .request = owned_request,
            .ref = owned_ref,
        });
        request_owned = false;
        ref_owned = false;
    }

    /// Adds an ordered read expectation and clones the returned bytes.
    pub fn expectRead(self: *Self, request: ports.ArtifactReadRequest, bytes: []const u8) !void {
        const owned_request = try cloneReadRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeReadRequest(self.allocator, owned_request);
        const owned_bytes = try common.dupString(self.allocator, bytes);
        var bytes_owned = true;
        defer if (bytes_owned) self.allocator.free(owned_bytes);

        try self.expected_reads.append(self.allocator, .{
            .request = owned_request,
            .bytes = owned_bytes,
        });
        request_owned = false;
        bytes_owned = false;
    }

    /// Adds an ordered workspace-record expectation and clones returned metadata.
    pub fn expectRecordWorkspace(self: *Self, request: ports.WorkspaceArtifactRecordRequest, ref: ports.WorkspaceArtifactRef) !void {
        const owned_request = try cloneRecordRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeRecordRequest(self.allocator, owned_request);
        const owned_ref = try cloneWorkspaceRef(self.allocator, ref);
        var ref_owned = true;
        defer if (ref_owned) owned_ref.deinit(self.allocator);

        try self.expected_records.append(self.allocator, .{
            .request = owned_request,
            .ref = owned_ref,
        });
        request_owned = false;
        ref_owned = false;
    }

    /// Returns immutable snapshots of attempted write calls.
    pub fn putCalls(self: *const Self) []const ports.ArtifactWriteRequest {
        return self.put_records.items;
    }

    /// Returns immutable snapshots of attempted read calls.
    pub fn readCalls(self: *const Self) []const ports.ArtifactReadRequest {
        return self.read_records.items;
    }

    /// Returns immutable snapshots of attempted workspace-record calls.
    pub fn recordWorkspaceCalls(self: *const Self) []const ports.WorkspaceArtifactRecordRequest {
        return self.record_workspace_records.items;
    }

    /// Fails if any ordered expectation was not consumed.
    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_put != self.expected_puts.items.len) return error.MissingWrite;
        if (self.next_read != self.expected_reads.items.len) return error.MissingExpectedCall;
        if (self.next_record != self.expected_records.items.len) return error.MissingExpectedCall;
    }

    /// Writes an artifact through this port implementation.
    fn put(ptr: *anyopaque, allocator: Allocator, request: ports.ArtifactWriteRequest) ports.PortError!ports.ArtifactRef {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneWriteRequest(self.allocator, request);
        var record_owned = true;
        defer if (record_owned) freeWriteRequest(self.allocator, owned_call);
        try self.put_records.append(self.allocator, owned_call);
        record_owned = false;

        if (self.next_put >= self.expected_puts.items.len) return error.UnexpectedCall;
        const expected = self.expected_puts.items[self.next_put];
        if (!writeRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_put += 1;
        return try cloneRef(allocator, expected.ref);
    }

    /// Reads stored data through this port implementation.
    fn read(ptr: *anyopaque, allocator: Allocator, request: ports.ArtifactReadRequest) ports.PortError!ports.ArtifactReadResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneReadRequest(self.allocator, request);
        var record_owned = true;
        defer if (record_owned) freeReadRequest(self.allocator, owned_call);
        try self.read_records.append(self.allocator, owned_call);
        record_owned = false;

        if (self.next_read >= self.expected_reads.items.len) return error.UnexpectedCall;
        const expected = self.expected_reads.items[self.next_read];
        if (!readRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_read += 1;

        const bytes = try common.dupString(allocator, expected.bytes);
        return .{ .bytes = bytes, .owns_bytes = true };
    }

    /// Records a workspace artifact through this port implementation.
    fn recordWorkspace(ptr: *anyopaque, allocator: Allocator, request: ports.WorkspaceArtifactRecordRequest) ports.PortError!ports.WorkspaceArtifactRef {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneRecordRequest(self.allocator, request);
        var record_owned = true;
        defer if (record_owned) freeRecordRequest(self.allocator, owned_call);
        try self.record_workspace_records.append(self.allocator, owned_call);
        record_owned = false;

        if (self.next_record >= self.expected_records.items.len) return error.UnexpectedCall;
        const expected = self.expected_records.items[self.next_record];
        if (!recordRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_record += 1;
        return try cloneWorkspaceRef(allocator, expected.ref);
    }

    /// Clones write request into allocator-owned storage.
    fn cloneWriteRequest(allocator: Allocator, request: ports.ArtifactWriteRequest) !ports.ArtifactWriteRequest {
        const namespace = try common.dupString(allocator, request.namespace);
        var namespace_owned = true;
        defer if (namespace_owned) allocator.free(namespace);
        const name = try common.dupString(allocator, request.name);
        var name_owned = true;
        defer if (name_owned) allocator.free(name);
        const kind = try common.dupString(allocator, request.kind);
        var kind_owned = true;
        defer if (kind_owned) allocator.free(kind);
        const bytes = try common.dupString(allocator, request.bytes);
        var bytes_owned = true;
        defer if (bytes_owned) allocator.free(bytes);
        const provenance = try common.dupString(allocator, request.provenance);
        var provenance_owned = true;
        defer if (provenance_owned) allocator.free(provenance);
        namespace_owned = false;
        name_owned = false;
        kind_owned = false;
        bytes_owned = false;
        provenance_owned = false;
        return .{
            .namespace = namespace,
            .name = name,
            .kind = kind,
            .bytes = bytes,
            .provenance = provenance,
        };
    }

    /// Releases allocator-owned fields held by the cloned write request.
    fn freeWriteRequest(allocator: Allocator, request: ports.ArtifactWriteRequest) void {
        allocator.free(request.namespace);
        allocator.free(request.name);
        allocator.free(request.kind);
        allocator.free(request.bytes);
        allocator.free(request.provenance);
    }

    /// Clones read request into allocator-owned storage.
    fn cloneReadRequest(allocator: Allocator, request: ports.ArtifactReadRequest) !ports.ArtifactReadRequest {
        return .{ .id = try common.dupString(allocator, request.id) };
    }

    /// Releases allocator-owned fields held by the cloned read request.
    fn freeReadRequest(allocator: Allocator, request: ports.ArtifactReadRequest) void {
        allocator.free(request.id);
    }

    /// Clones record request into allocator-owned storage.
    fn cloneRecordRequest(allocator: Allocator, request: ports.WorkspaceArtifactRecordRequest) !ports.WorkspaceArtifactRecordRequest {
        // Clone every nested string before transferring ownership; each
        // ownership flag prevents leaks if a later field allocation fails.
        const path = try common.dupString(allocator, request.path);
        var path_owned = true;
        defer if (path_owned) allocator.free(path);
        const bytes = try common.dupOptionalString(allocator, request.bytes);
        var bytes_owned = true;
        defer if (bytes_owned) common.freeOptionalString(allocator, bytes);
        const producer = try common.dupString(allocator, request.producer);
        var producer_owned = true;
        defer if (producer_owned) allocator.free(producer);
        const artifact_kind = try common.dupString(allocator, request.artifact_kind);
        var artifact_kind_owned = true;
        defer if (artifact_kind_owned) allocator.free(artifact_kind);
        const command_argv = try common.dupStringList(allocator, request.command_argv);
        var command_argv_owned = true;
        defer if (command_argv_owned) common.freeStringList(allocator, command_argv);
        const backend_name = try common.dupString(allocator, request.backend_name);
        var backend_name_owned = true;
        defer if (backend_name_owned) allocator.free(backend_name);
        const backend_version = try common.dupString(allocator, request.backend_version);
        var backend_version_owned = true;
        defer if (backend_version_owned) allocator.free(backend_version);
        const target = try common.dupString(allocator, request.target);
        var target_owned = true;
        defer if (target_owned) allocator.free(target);
        const baseline_identity = try common.dupString(allocator, request.baseline_identity);
        var baseline_identity_owned = true;
        defer if (baseline_identity_owned) allocator.free(baseline_identity);
        const notes = try common.dupString(allocator, request.notes);
        var notes_owned = true;
        defer if (notes_owned) allocator.free(notes);
        const provenance = try common.dupString(allocator, request.provenance);
        var provenance_owned = true;
        defer if (provenance_owned) allocator.free(provenance);
        const zig_path = try common.dupString(allocator, request.toolchain.zig_path);
        var zig_path_owned = true;
        defer if (zig_path_owned) allocator.free(zig_path);
        const zls_path = try common.dupString(allocator, request.toolchain.zls_path);
        var zls_path_owned = true;
        defer if (zls_path_owned) allocator.free(zls_path);
        const zflame_path = try common.dupString(allocator, request.toolchain.zflame_path);
        var zflame_path_owned = true;
        defer if (zflame_path_owned) allocator.free(zflame_path);
        const diff_folded_path = try common.dupString(allocator, request.toolchain.diff_folded_path);
        var diff_folded_path_owned = true;
        defer if (diff_folded_path_owned) allocator.free(diff_folded_path);
        path_owned = false;
        bytes_owned = false;
        producer_owned = false;
        artifact_kind_owned = false;
        command_argv_owned = false;
        backend_name_owned = false;
        backend_version_owned = false;
        target_owned = false;
        baseline_identity_owned = false;
        notes_owned = false;
        provenance_owned = false;
        zig_path_owned = false;
        zls_path_owned = false;
        zflame_path_owned = false;
        diff_folded_path_owned = false;
        return .{
            .path = path,
            .bytes = bytes,
            .producer = producer,
            .artifact_kind = artifact_kind,
            .command_argv = command_argv,
            .backend_name = backend_name,
            .backend_version = backend_version,
            .target = target,
            .baseline_identity = baseline_identity,
            .notes = notes,
            .toolchain = .{
                .zig_path = zig_path,
                .zls_path = zls_path,
                .zflame_path = zflame_path,
                .diff_folded_path = diff_folded_path,
            },
            .indexed_at_unix_ms = request.indexed_at_unix_ms,
            .provenance = provenance,
        };
    }

    /// Releases allocator-owned fields held by the cloned record request.
    fn freeRecordRequest(allocator: Allocator, request: ports.WorkspaceArtifactRecordRequest) void {
        allocator.free(request.path);
        common.freeOptionalString(allocator, request.bytes);
        allocator.free(request.producer);
        allocator.free(request.artifact_kind);
        common.freeStringList(allocator, request.command_argv);
        allocator.free(request.backend_name);
        allocator.free(request.backend_version);
        allocator.free(request.target);
        allocator.free(request.baseline_identity);
        allocator.free(request.notes);
        allocator.free(request.toolchain.zig_path);
        allocator.free(request.toolchain.zls_path);
        allocator.free(request.toolchain.zflame_path);
        allocator.free(request.toolchain.diff_folded_path);
        allocator.free(request.provenance);
    }

    /// Clones ref into allocator-owned storage.
    fn cloneRef(allocator: Allocator, ref: ports.ArtifactRef) !ports.ArtifactRef {
        const id = try common.dupString(allocator, ref.id);
        var id_owned = true;
        defer if (id_owned) allocator.free(id);
        const uri = try common.dupString(allocator, ref.uri);
        var uri_owned = true;
        defer if (uri_owned) allocator.free(uri);
        const checksum = try common.dupOptionalString(allocator, ref.checksum);
        var checksum_owned = true;
        defer if (checksum_owned) common.freeOptionalString(allocator, checksum);
        id_owned = false;
        uri_owned = false;
        checksum_owned = false;
        return .{
            .id = id,
            .uri = uri,
            .checksum = checksum,
            .bytes_written = ref.bytes_written,
            .owns_memory = true,
        };
    }

    /// Clones workspace ref into allocator-owned storage.
    fn cloneWorkspaceRef(allocator: Allocator, ref: ports.WorkspaceArtifactRef) !ports.WorkspaceArtifactRef {
        const path = try common.dupString(allocator, ref.path);
        var path_owned = true;
        defer if (path_owned) allocator.free(path);
        const abs_path = try common.dupString(allocator, ref.abs_path);
        var abs_path_owned = true;
        defer if (abs_path_owned) allocator.free(abs_path);
        const sha256 = try common.dupString(allocator, ref.sha256);
        var sha256_owned = true;
        defer if (sha256_owned) allocator.free(sha256);
        path_owned = false;
        abs_path_owned = false;
        sha256_owned = false;
        return .{
            .path = path,
            .abs_path = abs_path,
            .bytes = ref.bytes,
            .sha256 = sha256,
            .indexed_at_unix_ms = ref.indexed_at_unix_ms,
            .owns_memory = true,
        };
    }

    /// Compares write requests by the fields that affect behavior.
    fn writeRequestsEqual(expected: ports.ArtifactWriteRequest, actual: ports.ArtifactWriteRequest) bool {
        return std.mem.eql(u8, expected.namespace, actual.namespace) and
            std.mem.eql(u8, expected.name, actual.name) and
            std.mem.eql(u8, expected.kind, actual.kind) and
            std.mem.eql(u8, expected.bytes, actual.bytes) and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

    /// Compares read requests by the fields that affect behavior.
    fn readRequestsEqual(expected: ports.ArtifactReadRequest, actual: ports.ArtifactReadRequest) bool {
        return std.mem.eql(u8, expected.id, actual.id);
    }

    /// Compares record requests by the fields that affect behavior.
    fn recordRequestsEqual(expected: ports.WorkspaceArtifactRecordRequest, actual: ports.WorkspaceArtifactRecordRequest) bool {
        return std.mem.eql(u8, expected.path, actual.path) and
            common.optionalStringsEqual(expected.bytes, actual.bytes) and
            std.mem.eql(u8, expected.producer, actual.producer) and
            std.mem.eql(u8, expected.artifact_kind, actual.artifact_kind) and
            common.stringListsEqual(expected.command_argv, actual.command_argv) and
            std.mem.eql(u8, expected.backend_name, actual.backend_name) and
            std.mem.eql(u8, expected.backend_version, actual.backend_version) and
            std.mem.eql(u8, expected.target, actual.target) and
            std.mem.eql(u8, expected.baseline_identity, actual.baseline_identity) and
            std.mem.eql(u8, expected.notes, actual.notes) and
            std.mem.eql(u8, expected.toolchain.zig_path, actual.toolchain.zig_path) and
            std.mem.eql(u8, expected.toolchain.zls_path, actual.toolchain.zls_path) and
            std.mem.eql(u8, expected.toolchain.zflame_path, actual.toolchain.zflame_path) and
            std.mem.eql(u8, expected.toolchain.diff_folded_path, actual.toolchain.diff_folded_path) and
            expected.indexed_at_unix_ms == actual.indexed_at_unix_ms and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }
};

test "artifact store records put and read calls" {
    var fake = FakeArtifactStore.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectPut(.{
        .namespace = "profile",
        .name = "flame.svg",
        .kind = "svg",
        .bytes = "<svg></svg>",
    }, .{
        .id = "artifact-1",
        .uri = "zigars://artifact/artifact-1",
        .checksum = "sha256:test",
        .bytes_written = 11,
    });
    try fake.expectRead(.{ .id = "artifact-1" }, "<svg></svg>");

    const ref = try fake.port().put(std.testing.allocator, .{
        .namespace = "profile",
        .name = "flame.svg",
        .kind = "svg",
        .bytes = "<svg></svg>",
    });
    defer ref.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("artifact-1", ref.id);

    const read_result = try fake.port().read(std.testing.allocator, .{ .id = "artifact-1" });
    defer read_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("<svg></svg>", read_result.bytes);
    try std.testing.expectEqual(@as(usize, 1), fake.putCalls().len);
    try std.testing.expectEqual(@as(usize, 1), fake.readCalls().len);
    try fake.verify();
}

test "artifact store verify catches missing artifact writes" {
    var fake = FakeArtifactStore.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectPut(.{
        .namespace = "report",
        .name = "summary.json",
        .kind = "json",
        .bytes = "{}",
    }, .{
        .id = "artifact-2",
        .uri = "zigars://artifact/artifact-2",
        .bytes_written = 2,
    });

    try std.testing.expectError(error.MissingWrite, fake.verify());
}

test "artifact store rejects stale read requests" {
    var fake = FakeArtifactStore.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectRead(.{ .id = "artifact-1" }, "payload");
    try std.testing.expectError(error.StaleArguments, fake.port().read(std.testing.allocator, .{ .id = "artifact-2" }));
    try std.testing.expectEqual(@as(usize, 1), fake.readCalls().len);
    try std.testing.expectError(error.MissingExpectedCall, fake.verify());
}

test "artifact store records workspace artifact registrations" {
    var fake = FakeArtifactStore.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectRecordWorkspace(.{
        .path = "zig-out/report.json",
        .bytes = "{}",
        .producer = "tool",
        .artifact_kind = "json",
        .command_argv = &.{ "zig", "build" },
        .backend_name = "backend",
        .backend_version = "1.0.0",
        .target = "native",
        .baseline_identity = "base",
        .notes = "unit",
        .toolchain = .{
            .zig_path = "/bin/zig",
            .zls_path = "/bin/zls",
            .zflame_path = "/bin/zflame",
            .diff_folded_path = "/bin/diff-folded",
        },
        .indexed_at_unix_ms = 123,
        .provenance = "record",
    }, .{
        .path = "zig-out/report.json",
        .abs_path = "/repo/zig-out/report.json",
        .bytes = 2,
        .sha256 = "hash",
        .indexed_at_unix_ms = 123,
    });

    const ref = try fake.port().recordWorkspace(std.testing.allocator, .{
        .path = "zig-out/report.json",
        .bytes = "{}",
        .producer = "tool",
        .artifact_kind = "json",
        .command_argv = &.{ "zig", "build" },
        .backend_name = "backend",
        .backend_version = "1.0.0",
        .target = "native",
        .baseline_identity = "base",
        .notes = "unit",
        .toolchain = .{
            .zig_path = "/bin/zig",
            .zls_path = "/bin/zls",
            .zflame_path = "/bin/zflame",
            .diff_folded_path = "/bin/diff-folded",
        },
        .indexed_at_unix_ms = 123,
        .provenance = "record",
    });
    defer ref.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/repo/zig-out/report.json", ref.abs_path);
    try std.testing.expectEqual(@as(usize, 1), fake.recordWorkspaceCalls().len);
    try fake.verify();
}

test "artifact store rejects stale workspace artifact records" {
    var fake = FakeArtifactStore.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectRecordWorkspace(.{
        .path = "zig-out/a.json",
        .producer = "tool",
        .artifact_kind = "json",
    }, .{
        .path = "zig-out/a.json",
        .abs_path = "/repo/zig-out/a.json",
        .bytes = 0,
        .sha256 = "hash",
        .indexed_at_unix_ms = 0,
    });

    try std.testing.expectError(error.StaleArguments, fake.port().recordWorkspace(std.testing.allocator, .{
        .path = "zig-out/b.json",
        .producer = "tool",
        .artifact_kind = "json",
    }));
    try std.testing.expectEqual(@as(usize, 1), fake.recordWorkspaceCalls().len);
    try std.testing.expectError(error.MissingExpectedCall, fake.verify());
}
