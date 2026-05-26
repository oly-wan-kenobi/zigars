const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

/// WorkspaceStore fake with ordered expectations for every filesystem operation.
pub const FakeWorkspaceStore = struct {
    allocator: Allocator,
    expected_resolves: std.ArrayList(ExpectedResolve) = .empty,
    expected_reads: std.ArrayList(ExpectedRead) = .empty,
    expected_writes: std.ArrayList(ExpectedWrite) = .empty,
    expected_deletes: std.ArrayList(ExpectedDelete) = .empty,
    expected_exists: std.ArrayList(ExpectedExists) = .empty,
    expected_ensure_dirs: std.ArrayList(ExpectedEnsureDir) = .empty,
    expected_scans: std.ArrayList(ExpectedDirectoryScan) = .empty,
    resolve_records: std.ArrayList(ports.WorkspaceResolveRequest) = .empty,
    read_records: std.ArrayList(ports.WorkspaceReadRequest) = .empty,
    write_records: std.ArrayList(ports.WorkspaceWriteRequest) = .empty,
    delete_records: std.ArrayList(ports.WorkspaceDeleteRequest) = .empty,
    exists_records: std.ArrayList(ports.WorkspaceExistsRequest) = .empty,
    ensure_dir_records: std.ArrayList(ports.WorkspaceEnsureDirRequest) = .empty,
    scan_records: std.ArrayList(ports.WorkspaceDirectoryScanRequest) = .empty,
    next_resolve: usize = 0,
    next_read: usize = 0,
    next_write: usize = 0,
    next_delete: usize = 0,
    next_exists: usize = 0,
    next_ensure_dir: usize = 0,
    next_scan: usize = 0,

    const Self = @This();

    /// Expected resolve call and owned result.
    const ExpectedResolve = struct {
        request: ports.WorkspaceResolveRequest,
        result: ExpectedResolveResult,

        fn deinit(self: ExpectedResolve, allocator: Allocator) void {
            freeResolveRequest(allocator, self.request);
            self.result.deinit(allocator);
        }
    };

    /// Expected read call and owned result.
    const ExpectedRead = struct {
        request: ports.WorkspaceReadRequest,
        result: ExpectedReadResult,

        fn deinit(self: ExpectedRead, allocator: Allocator) void {
            freeReadRequest(allocator, self.request);
            self.result.deinit(allocator);
        }
    };

    /// Expected write call and result status.
    const ExpectedWrite = struct {
        request: ports.WorkspaceWriteRequest,
        result: ExpectedWriteResult,

        fn deinit(self: ExpectedWrite, allocator: Allocator) void {
            freeWriteRequest(allocator, self.request);
        }
    };

    const ExpectedDelete = struct {
        request: ports.WorkspaceDeleteRequest,
        result: ExpectedDeleteResult,

        fn deinit(self: ExpectedDelete, allocator: Allocator) void {
            freeDeleteRequest(allocator, self.request);
        }
    };

    const ExpectedExists = struct {
        request: ports.WorkspaceExistsRequest,
        result: ExpectedExistsResult,

        fn deinit(self: ExpectedExists, allocator: Allocator) void {
            freeExistsRequest(allocator, self.request);
        }
    };

    const ExpectedEnsureDir = struct {
        request: ports.WorkspaceEnsureDirRequest,
        result: ExpectedEnsureDirResult,

        fn deinit(self: ExpectedEnsureDir, allocator: Allocator) void {
            freeEnsureDirRequest(allocator, self.request);
        }
    };

    const ExpectedDirectoryScan = struct {
        request: ports.WorkspaceDirectoryScanRequest,
        result: ExpectedDirectoryScanResult,

        fn deinit(self: ExpectedDirectoryScan, allocator: Allocator) void {
            freeDirectoryScanRequest(allocator, self.request);
            self.result.deinit(allocator);
        }
    };

    const ExpectedReadResult = union(enum) {
        ok: []const u8,
        err: ports.PortError,

        fn deinit(self: ExpectedReadResult, allocator: Allocator) void {
            switch (self) {
                .ok => |bytes| allocator.free(bytes),
                .err => {},
            }
        }
    };

    const ExpectedResolveResult = union(enum) {
        ok: []const u8,
        err: ports.PortError,

        fn deinit(self: ExpectedResolveResult, allocator: Allocator) void {
            switch (self) {
                .ok => |path| allocator.free(path),
                .err => {},
            }
        }
    };

    const ExpectedWriteResult = union(enum) {
        ok: ports.WorkspaceWriteResult,
        err: ports.PortError,
    };

    const ExpectedDeleteResult = union(enum) {
        ok: ports.WorkspaceDeleteResult,
        err: ports.PortError,
    };

    const ExpectedExistsResult = union(enum) {
        ok: ports.WorkspaceExistsResult,
        err: ports.PortError,
    };

    const ExpectedEnsureDirResult = union(enum) {
        ok: ports.WorkspaceEnsureDirResult,
        err: ports.PortError,
    };

    const ExpectedDirectoryScanResult = union(enum) {
        ok: []ports.WorkspaceDirectoryEntry,
        err: ports.PortError,

        fn deinit(self: ExpectedDirectoryScanResult, allocator: Allocator) void {
            switch (self) {
                .ok => |entries| {
                    for (entries) |entry| allocator.free(entry.path);
                    allocator.free(entries);
                },
                .err => {},
            }
        }
    };

    /// Creates an empty fake that owns expectations with `allocator`.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Frees all expectations and recorded call snapshots.
    pub fn deinit(self: *Self) void {
        for (self.expected_resolves.items) |expected| expected.deinit(self.allocator);
        self.expected_resolves.deinit(self.allocator);

        for (self.expected_reads.items) |expected| expected.deinit(self.allocator);
        self.expected_reads.deinit(self.allocator);

        for (self.expected_writes.items) |expected| expected.deinit(self.allocator);
        self.expected_writes.deinit(self.allocator);

        for (self.expected_deletes.items) |expected| expected.deinit(self.allocator);
        self.expected_deletes.deinit(self.allocator);

        for (self.expected_exists.items) |expected| expected.deinit(self.allocator);
        self.expected_exists.deinit(self.allocator);

        for (self.expected_ensure_dirs.items) |expected| expected.deinit(self.allocator);
        self.expected_ensure_dirs.deinit(self.allocator);

        for (self.expected_scans.items) |expected| expected.deinit(self.allocator);
        self.expected_scans.deinit(self.allocator);

        for (self.resolve_records.items) |record| freeResolveRequest(self.allocator, record);
        self.resolve_records.deinit(self.allocator);

        for (self.read_records.items) |record| freeReadRequest(self.allocator, record);
        self.read_records.deinit(self.allocator);

        for (self.write_records.items) |record| freeWriteRequest(self.allocator, record);
        self.write_records.deinit(self.allocator);

        for (self.delete_records.items) |record| freeDeleteRequest(self.allocator, record);
        self.delete_records.deinit(self.allocator);

        for (self.exists_records.items) |record| freeExistsRequest(self.allocator, record);
        self.exists_records.deinit(self.allocator);

        for (self.ensure_dir_records.items) |record| freeEnsureDirRequest(self.allocator, record);
        self.ensure_dir_records.deinit(self.allocator);

        for (self.scan_records.items) |record| freeDirectoryScanRequest(self.allocator, record);
        self.scan_records.deinit(self.allocator);
        self.* = undefined;
    }

    /// Exposes this fake through the WorkspaceStore vtable.
    pub fn port(self: *Self) ports.WorkspaceStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .resolve = resolve,
                .read = read,
                .write = write,
                .delete = delete,
                .exists = exists,
                .ensure_dir = ensureDir,
                .scan_directory = scanDirectory,
            },
        };
    }

    pub fn expectResolve(self: *Self, request: ports.WorkspaceResolveRequest, path: []const u8) !void {
        const owned_request = try cloneResolveRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeResolveRequest(self.allocator, owned_request);
        const owned_path = try common.dupString(self.allocator, path);
        var path_owned = true;
        defer if (path_owned) self.allocator.free(owned_path);

        try self.expected_resolves.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = owned_path },
        });
        request_owned = false;
        path_owned = false;
    }

    pub fn expectResolveError(self: *Self, request: ports.WorkspaceResolveRequest, err: ports.PortError) !void {
        const owned_request = try cloneResolveRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeResolveRequest(self.allocator, owned_request);
        try self.expected_resolves.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
        request_owned = false;
    }

    pub fn expectRead(self: *Self, request: ports.WorkspaceReadRequest, bytes: []const u8) !void {
        const owned_request = try cloneReadRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeReadRequest(self.allocator, owned_request);
        const owned_bytes = try common.dupString(self.allocator, bytes);
        var bytes_owned = true;
        defer if (bytes_owned) self.allocator.free(owned_bytes);

        try self.expected_reads.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = owned_bytes },
        });
        request_owned = false;
        bytes_owned = false;
    }

    pub fn expectReadError(self: *Self, request: ports.WorkspaceReadRequest, err: ports.PortError) !void {
        const owned_request = try cloneReadRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeReadRequest(self.allocator, owned_request);
        try self.expected_reads.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
        request_owned = false;
    }

    pub fn expectWrite(self: *Self, request: ports.WorkspaceWriteRequest, result: ports.WorkspaceWriteResult) !void {
        const owned_request = try cloneWriteRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeWriteRequest(self.allocator, owned_request);
        try self.expected_writes.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = result },
        });
        request_owned = false;
    }

    pub fn expectWriteError(self: *Self, request: ports.WorkspaceWriteRequest, err: ports.PortError) !void {
        const owned_request = try cloneWriteRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeWriteRequest(self.allocator, owned_request);
        try self.expected_writes.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
        request_owned = false;
    }

    pub fn expectDelete(self: *Self, request: ports.WorkspaceDeleteRequest, result: ports.WorkspaceDeleteResult) !void {
        const owned_request = try cloneDeleteRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeDeleteRequest(self.allocator, owned_request);
        try self.expected_deletes.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = result },
        });
        request_owned = false;
    }

    pub fn expectDeleteError(self: *Self, request: ports.WorkspaceDeleteRequest, err: ports.PortError) !void {
        const owned_request = try cloneDeleteRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeDeleteRequest(self.allocator, owned_request);
        try self.expected_deletes.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
        request_owned = false;
    }

    pub fn expectExists(self: *Self, request: ports.WorkspaceExistsRequest, result: ports.WorkspaceExistsResult) !void {
        const owned_request = try cloneExistsRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeExistsRequest(self.allocator, owned_request);
        try self.expected_exists.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = result },
        });
        request_owned = false;
    }

    pub fn expectExistsError(self: *Self, request: ports.WorkspaceExistsRequest, err: ports.PortError) !void {
        const owned_request = try cloneExistsRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeExistsRequest(self.allocator, owned_request);
        try self.expected_exists.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
        request_owned = false;
    }

    pub fn expectEnsureDir(self: *Self, request: ports.WorkspaceEnsureDirRequest, result: ports.WorkspaceEnsureDirResult) !void {
        const owned_request = try cloneEnsureDirRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeEnsureDirRequest(self.allocator, owned_request);
        try self.expected_ensure_dirs.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = result },
        });
        request_owned = false;
    }

    pub fn expectEnsureDirError(self: *Self, request: ports.WorkspaceEnsureDirRequest, err: ports.PortError) !void {
        const owned_request = try cloneEnsureDirRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeEnsureDirRequest(self.allocator, owned_request);
        try self.expected_ensure_dirs.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
        request_owned = false;
    }

    pub fn expectScanDirectory(self: *Self, request: ports.WorkspaceDirectoryScanRequest, paths: []const []const u8) !void {
        const owned_request = try cloneDirectoryScanRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeDirectoryScanRequest(self.allocator, owned_request);
        const entries = try self.allocator.alloc(ports.WorkspaceDirectoryEntry, paths.len);
        var entries_owned = true;
        defer if (entries_owned) self.allocator.free(entries);
        for (paths, 0..) |path, index| {
            entries[index] = .{ .path = try common.dupString(self.allocator, path) };
        }
        try self.expected_scans.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = entries },
        });
        request_owned = false;
        entries_owned = false;
    }

    pub fn expectScanDirectoryError(self: *Self, request: ports.WorkspaceDirectoryScanRequest, err: ports.PortError) !void {
        const owned_request = try cloneDirectoryScanRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeDirectoryScanRequest(self.allocator, owned_request);
        try self.expected_scans.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
        request_owned = false;
    }

    pub fn resolveCalls(self: *const Self) []const ports.WorkspaceResolveRequest {
        return self.resolve_records.items;
    }

    pub fn readCalls(self: *const Self) []const ports.WorkspaceReadRequest {
        return self.read_records.items;
    }

    pub fn writeCalls(self: *const Self) []const ports.WorkspaceWriteRequest {
        return self.write_records.items;
    }

    pub fn deleteCalls(self: *const Self) []const ports.WorkspaceDeleteRequest {
        return self.delete_records.items;
    }

    pub fn existsCalls(self: *const Self) []const ports.WorkspaceExistsRequest {
        return self.exists_records.items;
    }

    pub fn ensureDirCalls(self: *const Self) []const ports.WorkspaceEnsureDirRequest {
        return self.ensure_dir_records.items;
    }

    pub fn scanDirectoryCalls(self: *const Self) []const ports.WorkspaceDirectoryScanRequest {
        return self.scan_records.items;
    }

    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_resolve != self.expected_resolves.items.len) return error.MissingExpectedCall;
        if (self.next_read != self.expected_reads.items.len) return error.MissingExpectedCall;
        if (self.next_write != self.expected_writes.items.len) return error.MissingWrite;
        if (self.next_delete != self.expected_deletes.items.len) return error.MissingWrite;
        if (self.next_exists != self.expected_exists.items.len) return error.MissingExpectedCall;
        if (self.next_ensure_dir != self.expected_ensure_dirs.items.len) return error.MissingExpectedCall;
        if (self.next_scan != self.expected_scans.items.len) return error.MissingExpectedCall;
    }

    fn resolve(ptr: *anyopaque, allocator: Allocator, request: ports.WorkspaceResolveRequest) ports.PortError!ports.WorkspaceResolveResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneResolveRequest(self.allocator, request);
        var record_owned = true;
        defer if (record_owned) freeResolveRequest(self.allocator, owned_call);
        try self.resolve_records.append(self.allocator, owned_call);
        record_owned = false;

        if (self.next_resolve >= self.expected_resolves.items.len) return error.UnexpectedCall;
        const expected = self.expected_resolves.items[self.next_resolve];
        if (!resolveRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_resolve += 1;

        const expected_path = switch (expected.result) {
            .ok => |path| path,
            .err => |err| return err,
        };
        const path = try common.dupString(allocator, expected_path);
        return .{ .path = path, .owns_path = true };
    }

    fn read(ptr: *anyopaque, allocator: Allocator, request: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
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

        const expected_bytes = switch (expected.result) {
            .ok => |bytes| bytes,
            .err => |err| return err,
        };
        const bytes = try common.dupString(allocator, expected_bytes);
        return .{ .bytes = bytes, .owns_bytes = true };
    }

    fn write(ptr: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneWriteRequest(self.allocator, request);
        var record_owned = true;
        defer if (record_owned) freeWriteRequest(self.allocator, owned_call);
        try self.write_records.append(self.allocator, owned_call);
        record_owned = false;

        if (self.next_write >= self.expected_writes.items.len) return error.UnexpectedCall;
        const expected = self.expected_writes.items[self.next_write];
        if (!writeRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_write += 1;
        return switch (expected.result) {
            .ok => |result| result,
            .err => |err| err,
        };
    }

    fn delete(ptr: *anyopaque, request: ports.WorkspaceDeleteRequest) ports.PortError!ports.WorkspaceDeleteResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneDeleteRequest(self.allocator, request);
        var record_owned = true;
        defer if (record_owned) freeDeleteRequest(self.allocator, owned_call);
        try self.delete_records.append(self.allocator, owned_call);
        record_owned = false;

        if (self.next_delete >= self.expected_deletes.items.len) return error.UnexpectedCall;
        const expected = self.expected_deletes.items[self.next_delete];
        if (!deleteRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_delete += 1;
        return switch (expected.result) {
            .ok => |result| result,
            .err => |err| err,
        };
    }

    fn exists(ptr: *anyopaque, _: Allocator, request: ports.WorkspaceExistsRequest) ports.PortError!ports.WorkspaceExistsResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneExistsRequest(self.allocator, request);
        var record_owned = true;
        defer if (record_owned) freeExistsRequest(self.allocator, owned_call);
        try self.exists_records.append(self.allocator, owned_call);
        record_owned = false;

        if (self.next_exists >= self.expected_exists.items.len) return error.UnexpectedCall;
        const expected = self.expected_exists.items[self.next_exists];
        if (!existsRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_exists += 1;
        return switch (expected.result) {
            .ok => |result| result,
            .err => |err| err,
        };
    }

    fn ensureDir(ptr: *anyopaque, request: ports.WorkspaceEnsureDirRequest) ports.PortError!ports.WorkspaceEnsureDirResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneEnsureDirRequest(self.allocator, request);
        var record_owned = true;
        defer if (record_owned) freeEnsureDirRequest(self.allocator, owned_call);
        try self.ensure_dir_records.append(self.allocator, owned_call);
        record_owned = false;

        if (self.next_ensure_dir >= self.expected_ensure_dirs.items.len) return error.UnexpectedCall;
        const expected = self.expected_ensure_dirs.items[self.next_ensure_dir];
        if (!ensureDirRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_ensure_dir += 1;
        return switch (expected.result) {
            .ok => |result| result,
            .err => |err| err,
        };
    }

    fn scanDirectory(ptr: *anyopaque, allocator: Allocator, request: ports.WorkspaceDirectoryScanRequest) ports.PortError!ports.WorkspaceDirectoryScanResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneDirectoryScanRequest(self.allocator, request);
        var record_owned = true;
        defer if (record_owned) freeDirectoryScanRequest(self.allocator, owned_call);
        try self.scan_records.append(self.allocator, owned_call);
        record_owned = false;

        if (self.next_scan >= self.expected_scans.items.len) return error.UnexpectedCall;
        const expected = self.expected_scans.items[self.next_scan];
        if (!directoryScanRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_scan += 1;

        const expected_entries = switch (expected.result) {
            .ok => |entries| entries,
            .err => |err| return err,
        };
        const copied = try allocator.alloc(ports.WorkspaceDirectoryEntry, expected_entries.len);
        var copied_owned = true;
        defer if (copied_owned) allocator.free(copied);
        for (expected_entries, 0..) |entry, index| {
            copied[index] = .{ .path = try common.dupString(allocator, entry.path) };
        }
        copied_owned = false;
        return .{ .entries = copied, .owns_memory = true };
    }

    fn cloneResolveRequest(allocator: Allocator, request: ports.WorkspaceResolveRequest) !ports.WorkspaceResolveRequest {
        const path = try common.dupString(allocator, request.path);
        var path_owned = true;
        defer if (path_owned) allocator.free(path);
        const provenance = try common.dupString(allocator, request.provenance);
        var provenance_owned = true;
        defer if (provenance_owned) allocator.free(provenance);
        path_owned = false;
        provenance_owned = false;
        return .{
            .path = path,
            .for_output = request.for_output,
            .provenance = provenance,
        };
    }

    fn freeResolveRequest(allocator: Allocator, request: ports.WorkspaceResolveRequest) void {
        allocator.free(request.path);
        allocator.free(request.provenance);
    }

    fn cloneReadRequest(allocator: Allocator, request: ports.WorkspaceReadRequest) !ports.WorkspaceReadRequest {
        const path = try common.dupString(allocator, request.path);
        var path_owned = true;
        defer if (path_owned) allocator.free(path);
        const provenance = try common.dupString(allocator, request.provenance);
        var provenance_owned = true;
        defer if (provenance_owned) allocator.free(provenance);
        path_owned = false;
        provenance_owned = false;
        return .{
            .path = path,
            .max_bytes = request.max_bytes,
            .for_output = request.for_output,
            .provenance = provenance,
        };
    }

    fn freeReadRequest(allocator: Allocator, request: ports.WorkspaceReadRequest) void {
        allocator.free(request.path);
        allocator.free(request.provenance);
    }

    fn cloneWriteRequest(allocator: Allocator, request: ports.WorkspaceWriteRequest) !ports.WorkspaceWriteRequest {
        const path = try common.dupString(allocator, request.path);
        var path_owned = true;
        defer if (path_owned) allocator.free(path);
        const bytes = try common.dupString(allocator, request.bytes);
        var bytes_owned = true;
        defer if (bytes_owned) allocator.free(bytes);
        const provenance = try common.dupString(allocator, request.provenance);
        var provenance_owned = true;
        defer if (provenance_owned) allocator.free(provenance);
        path_owned = false;
        bytes_owned = false;
        provenance_owned = false;
        return .{
            .path = path,
            .bytes = bytes,
            .create_parent_dirs = request.create_parent_dirs,
            .replace_existing = request.replace_existing,
            .provenance = provenance,
        };
    }

    fn freeWriteRequest(allocator: Allocator, request: ports.WorkspaceWriteRequest) void {
        allocator.free(request.path);
        allocator.free(request.bytes);
        allocator.free(request.provenance);
    }

    fn cloneDeleteRequest(allocator: Allocator, request: ports.WorkspaceDeleteRequest) !ports.WorkspaceDeleteRequest {
        const path = try common.dupString(allocator, request.path);
        var path_owned = true;
        defer if (path_owned) allocator.free(path);
        const provenance = try common.dupString(allocator, request.provenance);
        var provenance_owned = true;
        defer if (provenance_owned) allocator.free(provenance);
        path_owned = false;
        provenance_owned = false;
        return .{
            .path = path,
            .missing_ok = request.missing_ok,
            .provenance = provenance,
        };
    }

    fn freeDeleteRequest(allocator: Allocator, request: ports.WorkspaceDeleteRequest) void {
        allocator.free(request.path);
        allocator.free(request.provenance);
    }

    fn cloneExistsRequest(allocator: Allocator, request: ports.WorkspaceExistsRequest) !ports.WorkspaceExistsRequest {
        const path = try common.dupString(allocator, request.path);
        var path_owned = true;
        defer if (path_owned) allocator.free(path);
        const provenance = try common.dupString(allocator, request.provenance);
        var provenance_owned = true;
        defer if (provenance_owned) allocator.free(provenance);
        path_owned = false;
        provenance_owned = false;
        return .{
            .path = path,
            .for_output = request.for_output,
            .provenance = provenance,
        };
    }

    fn freeExistsRequest(allocator: Allocator, request: ports.WorkspaceExistsRequest) void {
        allocator.free(request.path);
        allocator.free(request.provenance);
    }

    fn cloneEnsureDirRequest(allocator: Allocator, request: ports.WorkspaceEnsureDirRequest) !ports.WorkspaceEnsureDirRequest {
        const path = try common.dupString(allocator, request.path);
        var path_owned = true;
        defer if (path_owned) allocator.free(path);
        const provenance = try common.dupString(allocator, request.provenance);
        var provenance_owned = true;
        defer if (provenance_owned) allocator.free(provenance);
        path_owned = false;
        provenance_owned = false;
        return .{
            .path = path,
            .provenance = provenance,
        };
    }

    fn freeEnsureDirRequest(allocator: Allocator, request: ports.WorkspaceEnsureDirRequest) void {
        allocator.free(request.path);
        allocator.free(request.provenance);
    }

    fn cloneDirectoryScanRequest(allocator: Allocator, request: ports.WorkspaceDirectoryScanRequest) !ports.WorkspaceDirectoryScanRequest {
        const path = try common.dupString(allocator, request.path);
        var path_owned = true;
        defer if (path_owned) allocator.free(path);
        const suffix = try common.dupString(allocator, request.suffix);
        var suffix_owned = true;
        defer if (suffix_owned) allocator.free(suffix);
        const provenance = try common.dupString(allocator, request.provenance);
        var provenance_owned = true;
        defer if (provenance_owned) allocator.free(provenance);
        path_owned = false;
        suffix_owned = false;
        provenance_owned = false;
        return .{
            .path = path,
            .suffix = suffix,
            .max_files = request.max_files,
            .for_output = request.for_output,
            .provenance = provenance,
        };
    }

    fn freeDirectoryScanRequest(allocator: Allocator, request: ports.WorkspaceDirectoryScanRequest) void {
        allocator.free(request.path);
        allocator.free(request.suffix);
        allocator.free(request.provenance);
    }

    fn resolveRequestsEqual(expected: ports.WorkspaceResolveRequest, actual: ports.WorkspaceResolveRequest) bool {
        return std.mem.eql(u8, expected.path, actual.path) and
            expected.for_output == actual.for_output and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

    fn readRequestsEqual(expected: ports.WorkspaceReadRequest, actual: ports.WorkspaceReadRequest) bool {
        return std.mem.eql(u8, expected.path, actual.path) and
            expected.max_bytes == actual.max_bytes and
            expected.for_output == actual.for_output and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

    fn writeRequestsEqual(expected: ports.WorkspaceWriteRequest, actual: ports.WorkspaceWriteRequest) bool {
        return std.mem.eql(u8, expected.path, actual.path) and
            std.mem.eql(u8, expected.bytes, actual.bytes) and
            expected.create_parent_dirs == actual.create_parent_dirs and
            expected.replace_existing == actual.replace_existing and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

    fn deleteRequestsEqual(expected: ports.WorkspaceDeleteRequest, actual: ports.WorkspaceDeleteRequest) bool {
        return std.mem.eql(u8, expected.path, actual.path) and
            expected.missing_ok == actual.missing_ok and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

    fn existsRequestsEqual(expected: ports.WorkspaceExistsRequest, actual: ports.WorkspaceExistsRequest) bool {
        return std.mem.eql(u8, expected.path, actual.path) and
            expected.for_output == actual.for_output and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

    fn ensureDirRequestsEqual(expected: ports.WorkspaceEnsureDirRequest, actual: ports.WorkspaceEnsureDirRequest) bool {
        return std.mem.eql(u8, expected.path, actual.path) and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

    fn directoryScanRequestsEqual(expected: ports.WorkspaceDirectoryScanRequest, actual: ports.WorkspaceDirectoryScanRequest) bool {
        return std.mem.eql(u8, expected.path, actual.path) and
            std.mem.eql(u8, expected.suffix, actual.suffix) and
            expected.max_files == actual.max_files and
            expected.for_output == actual.for_output and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }
};

test "workspace store records reads and writes" {
    var fake = FakeWorkspaceStore.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectRead(.{ .path = "src/main.zig", .max_bytes = 1024 }, "pub fn main() void {}\n");
    try fake.expectWrite(.{
        .path = "zig-out/report.txt",
        .bytes = "ok\n",
        .provenance = "report",
    }, .{
        .bytes_written = 3,
        .replaced_existing = false,
    });
    try fake.expectDelete(.{
        .path = "zig-out/old.txt",
        .provenance = "cleanup",
    }, .{
        .deleted = true,
    });

    const read_result = try fake.port().read(std.testing.allocator, .{ .path = "src/main.zig", .max_bytes = 1024 });
    defer read_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("pub fn main() void {}\n", read_result.bytes);

    const write_result = try fake.port().write(.{
        .path = "zig-out/report.txt",
        .bytes = "ok\n",
        .provenance = "report",
    });
    try std.testing.expectEqual(@as(usize, 3), write_result.bytes_written);
    const delete_result = try fake.port().delete(.{
        .path = "zig-out/old.txt",
        .provenance = "cleanup",
    });
    try std.testing.expect(delete_result.deleted);
    try std.testing.expectEqual(@as(usize, 1), fake.readCalls().len);
    try std.testing.expectEqual(@as(usize, 1), fake.writeCalls().len);
    try std.testing.expectEqual(@as(usize, 1), fake.deleteCalls().len);
    try fake.verify();
}

test "workspace store verify catches missing writes" {
    var fake = FakeWorkspaceStore.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectWrite(.{ .path = "out.txt", .bytes = "expected" }, .{ .bytes_written = 8 });
    try std.testing.expectError(error.MissingWrite, fake.verify());
}

test "workspace store rejects stale read requests" {
    var fake = FakeWorkspaceStore.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectRead(.{ .path = "src/main.zig", .max_bytes = 1024 }, "main");
    try std.testing.expectError(error.StaleArguments, fake.port().read(std.testing.allocator, .{
        .path = "src/lib.zig",
        .max_bytes = 1024,
    }));
    try std.testing.expectEqual(@as(usize, 1), fake.readCalls().len);
    try std.testing.expectError(error.MissingExpectedCall, fake.verify());
}

test "workspace store rejects stale write bytes" {
    var fake = FakeWorkspaceStore.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectWrite(.{ .path = "out.txt", .bytes = "expected" }, .{ .bytes_written = 8 });
    try std.testing.expectError(error.StaleArguments, fake.port().write(.{ .path = "out.txt", .bytes = "actual" }));
}

test "workspace store rejects stale delete requests" {
    var fake = FakeWorkspaceStore.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectDelete(.{ .path = "old.txt", .missing_ok = true }, .{ .deleted = true });
    try std.testing.expectError(error.StaleArguments, fake.port().delete(.{ .path = "new.txt", .missing_ok = true }));
}

test "workspace store supports ensure-dir and directory scan ports" {
    var fake = FakeWorkspaceStore.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectEnsureDir(.{ .path = "zig-out", .provenance = "mkdir" }, .{ .created_or_existing = true });
    try fake.expectScanDirectory(.{
        .path = ".",
        .suffix = ".zig",
        .max_files = 2,
        .for_output = false,
        .provenance = "scan",
    }, &.{ "build.zig", "src/main.zig" });

    const mkdir = try fake.port().ensureDir(.{ .path = "zig-out", .provenance = "mkdir" });
    try std.testing.expect(mkdir.created_or_existing);
    var scan = try fake.port().scanDirectory(std.testing.allocator, .{
        .path = ".",
        .suffix = ".zig",
        .max_files = 2,
        .for_output = false,
        .provenance = "scan",
    });
    defer scan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), scan.entries.len);
    try std.testing.expectEqualStrings("src/main.zig", scan.entries[1].path);
    try std.testing.expectEqual(@as(usize, 1), fake.ensureDirCalls().len);
    try std.testing.expectEqual(@as(usize, 1), fake.scanDirectoryCalls().len);
    try fake.verify();
}

test "workspace store reports ensure-dir and scan errors" {
    var fake = FakeWorkspaceStore.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectEnsureDirError(.{ .path = "../out" }, error.PathOutsideWorkspace);
    try fake.expectScanDirectoryError(.{ .path = "missing", .provenance = "scan" }, error.FileNotFound);

    try std.testing.expectError(error.PathOutsideWorkspace, fake.port().ensureDir(.{ .path = "../out" }));
    try std.testing.expectError(error.FileNotFound, fake.port().scanDirectory(std.testing.allocator, .{ .path = "missing", .provenance = "scan" }));
    try fake.verify();
}

test "workspace store rejects stale ensure-dir and scan requests" {
    var fake = FakeWorkspaceStore.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectEnsureDir(.{ .path = "zig-out", .provenance = "mkdir" }, .{});
    try fake.expectScanDirectory(.{ .path = ".", .suffix = ".zig" }, &.{"build.zig"});

    try std.testing.expectError(error.StaleArguments, fake.port().ensureDir(.{ .path = "zig-cache", .provenance = "mkdir" }));
    try std.testing.expectError(error.StaleArguments, fake.port().scanDirectory(std.testing.allocator, .{ .path = ".", .suffix = ".zon" }));
    try std.testing.expectEqual(@as(usize, 1), fake.ensureDirCalls().len);
    try std.testing.expectEqual(@as(usize, 1), fake.scanDirectoryCalls().len);
    try std.testing.expectError(error.MissingExpectedCall, fake.verify());
}
