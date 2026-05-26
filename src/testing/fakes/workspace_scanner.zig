const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

/// WorkspaceScanner fake with ordered scan expectations and call snapshots.
pub const FakeWorkspaceScanner = struct {
    allocator: Allocator,
    expected_scans: std.ArrayList(ExpectedScan) = .empty,
    call_records: std.ArrayList(ports.WorkspaceScanRequest) = .empty,
    next_scan: usize = 0,

    const Self = @This();

    /// Expected scan request and owned result.
    const ExpectedScan = struct {
        request: ports.WorkspaceScanRequest,
        result: ExpectedScanResult,

        fn deinit(self: ExpectedScan, allocator: Allocator) void {
            freeRequest(allocator, self.request);
            self.result.deinit(allocator);
        }
    };

    /// Stored scan result for one expected request.
    const ExpectedScanResult = union(enum) {
        ok: []ports.WorkspaceScanFile,
        err: ports.PortError,

        fn deinit(self: ExpectedScanResult, allocator: Allocator) void {
            switch (self) {
                .ok => |files| {
                    for (files) |file| allocator.free(file.path);
                    allocator.free(files);
                },
                .err => {},
            }
        }
    };

    /// Creates an empty fake that owns expectations with `allocator`.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Frees expectations and recorded call snapshots.
    pub fn deinit(self: *Self) void {
        for (self.expected_scans.items) |expected| expected.deinit(self.allocator);
        self.expected_scans.deinit(self.allocator);

        for (self.call_records.items) |request| freeRequest(self.allocator, request);
        self.call_records.deinit(self.allocator);
        self.* = undefined;
    }

    /// Exposes this fake through the WorkspaceScanner vtable.
    pub fn port(self: *Self) ports.WorkspaceScanner {
        return .{
            .ptr = self,
            .vtable = &.{
                .scan_zig_files = scanZigFiles,
            },
        };
    }

    /// Adds an ordered successful scan expectation and clones returned file paths.
    pub fn expectScan(self: *Self, request: ports.WorkspaceScanRequest, files: []const []const u8) !void {
        const owned_request = try cloneRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeRequest(self.allocator, owned_request);
        const owned_files = try self.allocator.alloc(ports.WorkspaceScanFile, files.len);
        var files_owned = true;
        var filled: usize = 0;
        defer if (files_owned) {
            for (owned_files[0..filled]) |file| self.allocator.free(file.path);
            self.allocator.free(owned_files);
        };
        for (files, 0..) |path, index| {
            owned_files[index] = .{ .path = try common.dupString(self.allocator, path) };
            filled += 1;
        }
        try self.expected_scans.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = owned_files },
        });
        request_owned = false;
        files_owned = false;
    }

    /// Adds an ordered failing scan expectation.
    pub fn expectScanError(self: *Self, request: ports.WorkspaceScanRequest, err: ports.PortError) !void {
        const owned_request = try cloneRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeRequest(self.allocator, owned_request);
        try self.expected_scans.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
        request_owned = false;
    }

    /// Fails if any ordered scan expectation was not consumed.
    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_scan != self.expected_scans.items.len) return error.MissingExpectedCall;
    }

    fn scanZigFiles(
        ptr: *anyopaque,
        allocator: Allocator,
        request: ports.WorkspaceScanRequest,
    ) ports.PortError!ports.WorkspaceScanResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneRequest(self.allocator, request);
        var record_owned = false;
        errdefer if (!record_owned) freeRequest(self.allocator, owned_call);
        try self.call_records.append(self.allocator, owned_call);
        record_owned = true;

        if (self.next_scan >= self.expected_scans.items.len) return error.UnexpectedCall;
        const expected = self.expected_scans.items[self.next_scan];
        if (!requestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_scan += 1;

        const expected_files = switch (expected.result) {
            .ok => |files| files,
            .err => |err| return err,
        };

        const copied = try allocator.alloc(ports.WorkspaceScanFile, expected_files.len);
        errdefer allocator.free(copied);
        for (expected_files, 0..) |file, index| {
            copied[index] = .{ .path = try common.dupString(allocator, file.path) };
        }
        return .{ .files = copied, .owns_memory = true };
    }

    fn cloneRequest(allocator: Allocator, request: ports.WorkspaceScanRequest) !ports.WorkspaceScanRequest {
        const path_prefix = try common.dupString(allocator, request.path_prefix);
        var path_prefix_owned = true;
        defer if (path_prefix_owned) allocator.free(path_prefix);
        const provenance = try common.dupString(allocator, request.provenance);
        path_prefix_owned = false;
        return .{
            .path_prefix = path_prefix,
            .max_files = request.max_files,
            .provenance = provenance,
        };
    }

    fn freeRequest(allocator: Allocator, request: ports.WorkspaceScanRequest) void {
        allocator.free(request.path_prefix);
        allocator.free(request.provenance);
    }

    fn requestsEqual(expected: ports.WorkspaceScanRequest, actual: ports.WorkspaceScanRequest) bool {
        return std.mem.eql(u8, expected.path_prefix, actual.path_prefix) and
            expected.max_files == actual.max_files and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }
};

test "workspace scanner fake returns expected files" {
    var fake = FakeWorkspaceScanner.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectScan(.{ .path_prefix = "src", .max_files = 2, .provenance = "scan" }, &.{ "src/main.zig", "src/lib.zig" });
    const result = try fake.port().scanZigFiles(std.testing.allocator, .{
        .path_prefix = "src",
        .max_files = 2,
        .provenance = "scan",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.files.len);
    try fake.verify();
}

test "workspace scanner fake expectations clean partial allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expectWorkspaceScannerWithAllocator, .{});
}

fn expectWorkspaceScannerWithAllocator(allocator: Allocator) !void {
    var fake = FakeWorkspaceScanner.init(allocator);
    defer fake.deinit();

    try fake.expectScan(.{ .path_prefix = "src", .max_files = 2, .provenance = "scan" }, &.{ "src/main.zig", "src/lib.zig" });
    try fake.expectScanError(.{ .path_prefix = "bad", .provenance = "scan" }, error.AccessDenied);
}
