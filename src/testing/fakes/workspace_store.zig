const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

pub const FakeWorkspaceStore = struct {
    allocator: Allocator,
    expected_resolves: std.ArrayList(ExpectedResolve) = .empty,
    expected_reads: std.ArrayList(ExpectedRead) = .empty,
    expected_writes: std.ArrayList(ExpectedWrite) = .empty,
    expected_deletes: std.ArrayList(ExpectedDelete) = .empty,
    resolve_records: std.ArrayList(ports.WorkspaceResolveRequest) = .empty,
    read_records: std.ArrayList(ports.WorkspaceReadRequest) = .empty,
    write_records: std.ArrayList(ports.WorkspaceWriteRequest) = .empty,
    delete_records: std.ArrayList(ports.WorkspaceDeleteRequest) = .empty,
    next_resolve: usize = 0,
    next_read: usize = 0,
    next_write: usize = 0,
    next_delete: usize = 0,

    const Self = @This();

    const ExpectedResolve = struct {
        request: ports.WorkspaceResolveRequest,
        result: ExpectedResolveResult,

        fn deinit(self: ExpectedResolve, allocator: Allocator) void {
            freeResolveRequest(allocator, self.request);
            self.result.deinit(allocator);
        }
    };

    const ExpectedRead = struct {
        request: ports.WorkspaceReadRequest,
        result: ExpectedReadResult,

        fn deinit(self: ExpectedRead, allocator: Allocator) void {
            freeReadRequest(allocator, self.request);
            self.result.deinit(allocator);
        }
    };

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

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.expected_resolves.items) |expected| expected.deinit(self.allocator);
        self.expected_resolves.deinit(self.allocator);

        for (self.expected_reads.items) |expected| expected.deinit(self.allocator);
        self.expected_reads.deinit(self.allocator);

        for (self.expected_writes.items) |expected| expected.deinit(self.allocator);
        self.expected_writes.deinit(self.allocator);

        for (self.expected_deletes.items) |expected| expected.deinit(self.allocator);
        self.expected_deletes.deinit(self.allocator);

        for (self.resolve_records.items) |record| freeResolveRequest(self.allocator, record);
        self.resolve_records.deinit(self.allocator);

        for (self.read_records.items) |record| freeReadRequest(self.allocator, record);
        self.read_records.deinit(self.allocator);

        for (self.write_records.items) |record| freeWriteRequest(self.allocator, record);
        self.write_records.deinit(self.allocator);

        for (self.delete_records.items) |record| freeDeleteRequest(self.allocator, record);
        self.delete_records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn port(self: *Self) ports.WorkspaceStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .resolve = resolve,
                .read = read,
                .write = write,
                .delete = delete,
            },
        };
    }

    pub fn expectResolve(self: *Self, request: ports.WorkspaceResolveRequest, path: []const u8) !void {
        const owned_request = try cloneResolveRequest(self.allocator, request);
        errdefer freeResolveRequest(self.allocator, owned_request);
        const owned_path = try common.dupString(self.allocator, path);
        errdefer self.allocator.free(owned_path);

        try self.expected_resolves.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = owned_path },
        });
    }

    pub fn expectResolveError(self: *Self, request: ports.WorkspaceResolveRequest, err: ports.PortError) !void {
        const owned_request = try cloneResolveRequest(self.allocator, request);
        errdefer freeResolveRequest(self.allocator, owned_request);
        try self.expected_resolves.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
    }

    pub fn expectRead(self: *Self, request: ports.WorkspaceReadRequest, bytes: []const u8) !void {
        const owned_request = try cloneReadRequest(self.allocator, request);
        errdefer freeReadRequest(self.allocator, owned_request);
        const owned_bytes = try common.dupString(self.allocator, bytes);
        errdefer self.allocator.free(owned_bytes);

        try self.expected_reads.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = owned_bytes },
        });
    }

    pub fn expectReadError(self: *Self, request: ports.WorkspaceReadRequest, err: ports.PortError) !void {
        const owned_request = try cloneReadRequest(self.allocator, request);
        errdefer freeReadRequest(self.allocator, owned_request);
        try self.expected_reads.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
    }

    pub fn expectWrite(self: *Self, request: ports.WorkspaceWriteRequest, result: ports.WorkspaceWriteResult) !void {
        const owned_request = try cloneWriteRequest(self.allocator, request);
        errdefer freeWriteRequest(self.allocator, owned_request);
        try self.expected_writes.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = result },
        });
    }

    pub fn expectWriteError(self: *Self, request: ports.WorkspaceWriteRequest, err: ports.PortError) !void {
        const owned_request = try cloneWriteRequest(self.allocator, request);
        errdefer freeWriteRequest(self.allocator, owned_request);
        try self.expected_writes.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
    }

    pub fn expectDelete(self: *Self, request: ports.WorkspaceDeleteRequest, result: ports.WorkspaceDeleteResult) !void {
        const owned_request = try cloneDeleteRequest(self.allocator, request);
        errdefer freeDeleteRequest(self.allocator, owned_request);
        try self.expected_deletes.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = result },
        });
    }

    pub fn expectDeleteError(self: *Self, request: ports.WorkspaceDeleteRequest, err: ports.PortError) !void {
        const owned_request = try cloneDeleteRequest(self.allocator, request);
        errdefer freeDeleteRequest(self.allocator, owned_request);
        try self.expected_deletes.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
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

    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_resolve != self.expected_resolves.items.len) return error.MissingExpectedCall;
        if (self.next_read != self.expected_reads.items.len) return error.MissingExpectedCall;
        if (self.next_write != self.expected_writes.items.len) return error.MissingWrite;
        if (self.next_delete != self.expected_deletes.items.len) return error.MissingWrite;
    }

    fn resolve(ptr: *anyopaque, allocator: Allocator, request: ports.WorkspaceResolveRequest) ports.PortError!ports.WorkspaceResolveResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneResolveRequest(self.allocator, request);
        var record_owned = false;
        errdefer if (!record_owned) freeResolveRequest(self.allocator, owned_call);
        try self.resolve_records.append(self.allocator, owned_call);
        record_owned = true;

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
        var record_owned = false;
        errdefer if (!record_owned) freeReadRequest(self.allocator, owned_call);
        try self.read_records.append(self.allocator, owned_call);
        record_owned = true;

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
        var record_owned = false;
        errdefer if (!record_owned) freeWriteRequest(self.allocator, owned_call);
        try self.write_records.append(self.allocator, owned_call);
        record_owned = true;

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
        var record_owned = false;
        errdefer if (!record_owned) freeDeleteRequest(self.allocator, owned_call);
        try self.delete_records.append(self.allocator, owned_call);
        record_owned = true;

        if (self.next_delete >= self.expected_deletes.items.len) return error.UnexpectedCall;
        const expected = self.expected_deletes.items[self.next_delete];
        if (!deleteRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_delete += 1;
        return switch (expected.result) {
            .ok => |result| result,
            .err => |err| err,
        };
    }

    fn cloneResolveRequest(allocator: Allocator, request: ports.WorkspaceResolveRequest) !ports.WorkspaceResolveRequest {
        const path = try common.dupString(allocator, request.path);
        errdefer allocator.free(path);
        const provenance = try common.dupString(allocator, request.provenance);
        errdefer allocator.free(provenance);
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
        errdefer allocator.free(path);
        const provenance = try common.dupString(allocator, request.provenance);
        errdefer allocator.free(provenance);
        return .{
            .path = path,
            .max_bytes = request.max_bytes,
            .provenance = provenance,
        };
    }

    fn freeReadRequest(allocator: Allocator, request: ports.WorkspaceReadRequest) void {
        allocator.free(request.path);
        allocator.free(request.provenance);
    }

    fn cloneWriteRequest(allocator: Allocator, request: ports.WorkspaceWriteRequest) !ports.WorkspaceWriteRequest {
        const path = try common.dupString(allocator, request.path);
        errdefer allocator.free(path);
        const bytes = try common.dupString(allocator, request.bytes);
        errdefer allocator.free(bytes);
        const provenance = try common.dupString(allocator, request.provenance);
        errdefer allocator.free(provenance);
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
        errdefer allocator.free(path);
        const provenance = try common.dupString(allocator, request.provenance);
        errdefer allocator.free(provenance);
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

    fn resolveRequestsEqual(expected: ports.WorkspaceResolveRequest, actual: ports.WorkspaceResolveRequest) bool {
        return std.mem.eql(u8, expected.path, actual.path) and
            expected.for_output == actual.for_output and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

    fn readRequestsEqual(expected: ports.WorkspaceReadRequest, actual: ports.WorkspaceReadRequest) bool {
        return std.mem.eql(u8, expected.path, actual.path) and
            expected.max_bytes == actual.max_bytes and
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
