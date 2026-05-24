const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

pub const FakeDocsScanner = struct {
    allocator: Allocator,
    expected_reads: std.ArrayList(ExpectedRead) = .empty,
    expected_absolute_scans: std.ArrayList(ExpectedAbsoluteScan) = .empty,
    expected_workspace_scans: std.ArrayList(ExpectedWorkspaceScan) = .empty,
    next_read: usize = 0,
    next_absolute_scan: usize = 0,
    next_workspace_scan: usize = 0,

    const Self = @This();

    const ExpectedRead = struct {
        request: ports.DocsReadAbsoluteRequest,
        result: ReadResult,

        fn deinit(self: ExpectedRead, allocator: Allocator) void {
            freeReadRequest(allocator, self.request);
            self.result.deinit(allocator);
        }
    };

    const ReadResult = union(enum) {
        ok: []const u8,
        err: ports.PortError,

        fn deinit(self: ReadResult, allocator: Allocator) void {
            switch (self) {
                .ok => |bytes| allocator.free(bytes),
                .err => {},
            }
        }
    };

    const ExpectedAbsoluteScan = struct {
        request: ports.DocsScanAbsoluteZigPathsRequest,
        result: ScanResult,

        fn deinit(self: ExpectedAbsoluteScan, allocator: Allocator) void {
            freeAbsoluteScanRequest(allocator, self.request);
            self.result.deinit(allocator);
        }
    };

    const ExpectedWorkspaceScan = struct {
        request: ports.DocsScanWorkspacePathsRequest,
        result: ScanResult,

        fn deinit(self: ExpectedWorkspaceScan, allocator: Allocator) void {
            freeWorkspaceScanRequest(allocator, self.request);
            self.result.deinit(allocator);
        }
    };

    const ScanResult = union(enum) {
        ok: []ports.DocsPath,
        err: ports.PortError,

        fn deinit(self: ScanResult, allocator: Allocator) void {
            switch (self) {
                .ok => |paths| {
                    for (paths) |path| allocator.free(path.path);
                    allocator.free(paths);
                },
                .err => {},
            }
        }
    };

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.expected_reads.items) |expected| expected.deinit(self.allocator);
        self.expected_reads.deinit(self.allocator);
        for (self.expected_absolute_scans.items) |expected| expected.deinit(self.allocator);
        self.expected_absolute_scans.deinit(self.allocator);
        for (self.expected_workspace_scans.items) |expected| expected.deinit(self.allocator);
        self.expected_workspace_scans.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn port(self: *Self) ports.DocsScanner {
        return .{
            .ptr = self,
            .vtable = &.{
                .read_absolute = readAbsolute,
                .scan_absolute_zig_paths = scanAbsoluteZigPaths,
                .scan_workspace_paths = scanWorkspacePaths,
            },
        };
    }

    pub fn expectRead(self: *Self, request: ports.DocsReadAbsoluteRequest, bytes: []const u8) !void {
        const owned_request = try cloneReadRequest(self.allocator, request);
        errdefer freeReadRequest(self.allocator, owned_request);
        try self.expected_reads.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = try common.dupString(self.allocator, bytes) },
        });
    }

    pub fn expectReadError(self: *Self, request: ports.DocsReadAbsoluteRequest, err: ports.PortError) !void {
        const owned_request = try cloneReadRequest(self.allocator, request);
        errdefer freeReadRequest(self.allocator, owned_request);
        try self.expected_reads.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
    }

    pub fn expectAbsoluteScan(self: *Self, request: ports.DocsScanAbsoluteZigPathsRequest, paths: []const []const u8) !void {
        const owned_request = try cloneAbsoluteScanRequest(self.allocator, request);
        errdefer freeAbsoluteScanRequest(self.allocator, owned_request);
        try self.expected_absolute_scans.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = try clonePaths(self.allocator, paths) },
        });
    }

    pub fn expectWorkspaceScan(self: *Self, request: ports.DocsScanWorkspacePathsRequest, paths: []const []const u8) !void {
        const owned_request = try cloneWorkspaceScanRequest(self.allocator, request);
        errdefer freeWorkspaceScanRequest(self.allocator, owned_request);
        try self.expected_workspace_scans.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = try clonePaths(self.allocator, paths) },
        });
    }

    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_read != self.expected_reads.items.len) return error.MissingExpectedCall;
        if (self.next_absolute_scan != self.expected_absolute_scans.items.len) return error.MissingExpectedCall;
        if (self.next_workspace_scan != self.expected_workspace_scans.items.len) return error.MissingExpectedCall;
    }

    fn readAbsolute(ptr: *anyopaque, allocator: Allocator, request: ports.DocsReadAbsoluteRequest) ports.PortError!ports.DocsReadResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.next_read >= self.expected_reads.items.len) return error.UnexpectedCall;
        const expected = self.expected_reads.items[self.next_read];
        if (!readRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_read += 1;
        return switch (expected.result) {
            .ok => |bytes| .{ .bytes = try common.dupString(allocator, bytes), .owns_bytes = true },
            .err => |err| err,
        };
    }

    fn scanAbsoluteZigPaths(ptr: *anyopaque, allocator: Allocator, request: ports.DocsScanAbsoluteZigPathsRequest) ports.PortError!ports.DocsPathScanResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.next_absolute_scan >= self.expected_absolute_scans.items.len) return error.UnexpectedCall;
        const expected = self.expected_absolute_scans.items[self.next_absolute_scan];
        if (!absoluteScanRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_absolute_scan += 1;
        return switch (expected.result) {
            .ok => |paths| .{ .paths = try copyPaths(allocator, paths), .owns_memory = true },
            .err => |err| err,
        };
    }

    fn scanWorkspacePaths(ptr: *anyopaque, allocator: Allocator, request: ports.DocsScanWorkspacePathsRequest) ports.PortError!ports.DocsPathScanResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.next_workspace_scan >= self.expected_workspace_scans.items.len) return error.UnexpectedCall;
        const expected = self.expected_workspace_scans.items[self.next_workspace_scan];
        if (!workspaceScanRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_workspace_scan += 1;
        return switch (expected.result) {
            .ok => |paths| .{ .paths = try copyPaths(allocator, paths), .owns_memory = true },
            .err => |err| err,
        };
    }

    fn cloneReadRequest(allocator: Allocator, request: ports.DocsReadAbsoluteRequest) !ports.DocsReadAbsoluteRequest {
        return .{
            .path = try common.dupString(allocator, request.path),
            .max_bytes = request.max_bytes,
            .provenance = try common.dupString(allocator, request.provenance),
        };
    }

    fn freeReadRequest(allocator: Allocator, request: ports.DocsReadAbsoluteRequest) void {
        allocator.free(request.path);
        allocator.free(request.provenance);
    }

    fn cloneAbsoluteScanRequest(allocator: Allocator, request: ports.DocsScanAbsoluteZigPathsRequest) !ports.DocsScanAbsoluteZigPathsRequest {
        return .{
            .root = try common.dupString(allocator, request.root),
            .max_files = request.max_files,
            .provenance = try common.dupString(allocator, request.provenance),
        };
    }

    fn freeAbsoluteScanRequest(allocator: Allocator, request: ports.DocsScanAbsoluteZigPathsRequest) void {
        allocator.free(request.root);
        allocator.free(request.provenance);
    }

    fn cloneWorkspaceScanRequest(allocator: Allocator, request: ports.DocsScanWorkspacePathsRequest) !ports.DocsScanWorkspacePathsRequest {
        return .{
            .max_files = request.max_files,
            .provenance = try common.dupString(allocator, request.provenance),
        };
    }

    fn freeWorkspaceScanRequest(allocator: Allocator, request: ports.DocsScanWorkspacePathsRequest) void {
        allocator.free(request.provenance);
    }

    fn clonePaths(allocator: Allocator, raw_paths: []const []const u8) ![]ports.DocsPath {
        const paths = try allocator.alloc(ports.DocsPath, raw_paths.len);
        errdefer allocator.free(paths);
        for (raw_paths, 0..) |path, index| {
            paths[index] = .{ .path = try common.dupString(allocator, path) };
        }
        return paths;
    }

    fn copyPaths(allocator: Allocator, paths: []ports.DocsPath) ![]ports.DocsPath {
        const copied = try allocator.alloc(ports.DocsPath, paths.len);
        errdefer allocator.free(copied);
        for (paths, 0..) |path, index| {
            copied[index] = .{ .path = try common.dupString(allocator, path.path) };
        }
        return copied;
    }

    fn readRequestsEqual(expected: ports.DocsReadAbsoluteRequest, actual: ports.DocsReadAbsoluteRequest) bool {
        return std.mem.eql(u8, expected.path, actual.path) and
            expected.max_bytes == actual.max_bytes and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

    fn absoluteScanRequestsEqual(expected: ports.DocsScanAbsoluteZigPathsRequest, actual: ports.DocsScanAbsoluteZigPathsRequest) bool {
        return std.mem.eql(u8, expected.root, actual.root) and
            expected.max_files == actual.max_files and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

    fn workspaceScanRequestsEqual(expected: ports.DocsScanWorkspacePathsRequest, actual: ports.DocsScanWorkspacePathsRequest) bool {
        return expected.max_files == actual.max_files and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }
};

test "docs scanner fake returns expected paths and reads" {
    var fake = FakeDocsScanner.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectWorkspaceScan(.{ .max_files = 2, .provenance = "docs" }, &.{ "README.md", "src/main.zig" });
    try fake.expectRead(.{ .path = "/zig/lib/doc/langref.html", .max_bytes = 64, .provenance = "langref" }, "<h1>Zig Language Reference</h1>");

    const scan = try fake.port().scanWorkspacePaths(std.testing.allocator, .{ .max_files = 2, .provenance = "docs" });
    defer scan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), scan.paths.len);

    const read = try fake.port().readAbsolute(std.testing.allocator, .{ .path = "/zig/lib/doc/langref.html", .max_bytes = 64, .provenance = "langref" });
    defer read.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, read.bytes, "Language Reference") != null);
    try fake.verify();
}
