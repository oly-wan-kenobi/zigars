//! Fake implementation of the `ports.DocsScanner` port.
//! Simulates reading Zig stdlib documentation files and scanning source trees
//! for documentation paths. Supports both absolute and workspace-relative scans,
//! and can inject read or scan errors to exercise error-handling paths.

const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

/// DocsScanner fake with ordered read and path-scan expectations.
pub const FakeDocsScanner = struct {
    allocator: Allocator,
    expected_reads: std.ArrayList(ExpectedRead) = .empty,
    expected_absolute_scans: std.ArrayList(ExpectedAbsoluteScan) = .empty,
    expected_workspace_scans: std.ArrayList(ExpectedWorkspaceScan) = .empty,
    next_read: usize = 0,
    next_absolute_scan: usize = 0,
    next_workspace_scan: usize = 0,

    const Self = @This();

    /// Expected absolute read and owned bytes/error.
    const ExpectedRead = struct {
        request: ports.DocsReadAbsoluteRequest,
        result: ReadResult,

        /// Frees the cloned read request and stored read outcome.
        fn deinit(self: ExpectedRead, allocator: Allocator) void {
            freeReadRequest(allocator, self.request);
            self.result.deinit(allocator);
        }
    };

    /// Read expectation outcome.
    const ReadResult = union(enum) {
        ok: []const u8,
        err: ports.PortError,

        /// Releases owned bytes for successful read outcomes.
        fn deinit(self: ReadResult, allocator: Allocator) void {
            switch (self) {
                .ok => |bytes| allocator.free(bytes),
                .err => {},
            }
        }
    };

    /// Expected absolute Zig path scan.
    const ExpectedAbsoluteScan = struct {
        request: ports.DocsScanAbsoluteZigPathsRequest,
        result: ScanResult,

        /// Frees the cloned absolute-scan request and stored scan outcome.
        fn deinit(self: ExpectedAbsoluteScan, allocator: Allocator) void {
            freeAbsoluteScanRequest(allocator, self.request);
            self.result.deinit(allocator);
        }
    };

    /// Expected workspace docs path scan.
    const ExpectedWorkspaceScan = struct {
        request: ports.DocsScanWorkspacePathsRequest,
        result: ScanResult,

        /// Frees the cloned workspace-scan request and stored scan outcome.
        fn deinit(self: ExpectedWorkspaceScan, allocator: Allocator) void {
            freeWorkspaceScanRequest(allocator, self.request);
            self.result.deinit(allocator);
        }
    };

    /// Scan expectation outcome with owned paths.
    const ScanResult = union(enum) {
        ok: []ports.DocsPath,
        err: ports.PortError,

        /// Releases owned path entries for successful scan outcomes.
        fn deinit(self: ScanResult, allocator: Allocator) void {
            // Only release owned state here to avoid invalidating borrowed data.
            switch (self) {
                .ok => |paths| {
                    for (paths) |path| allocator.free(path.path);
                    allocator.free(paths);
                },
                .err => {},
            }
        }
    };

    /// Creates an empty fake that owns expectations with `allocator`.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Frees all expected read and scan results.
    pub fn deinit(self: *Self) void {
        // Only release owned state here to avoid invalidating borrowed data.
        for (self.expected_reads.items) |expected| expected.deinit(self.allocator);
        self.expected_reads.deinit(self.allocator);
        for (self.expected_absolute_scans.items) |expected| expected.deinit(self.allocator);
        self.expected_absolute_scans.deinit(self.allocator);
        for (self.expected_workspace_scans.items) |expected| expected.deinit(self.allocator);
        self.expected_workspace_scans.deinit(self.allocator);
        self.* = undefined;
    }

    /// Exposes this fake through the DocsScanner vtable.
    pub fn port(self: *Self) ports.DocsScanner {
        // Keep this logic centralized so callers observe one consistent behavior path.
        return .{
            .ptr = self,
            .vtable = &.{
                .read_absolute = readAbsolute,
                .scan_absolute_zig_paths = scanAbsoluteZigPaths,
                .scan_workspace_paths = scanWorkspacePaths,
            },
        };
    }

    /// Adds an ordered successful absolute read expectation.
    pub fn expectRead(self: *Self, request: ports.DocsReadAbsoluteRequest, bytes: []const u8) !void {
        // Keep this logic centralized so callers observe one consistent behavior path.
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

    /// Records an expected read error call, cloning request data and failing on allocation errors.
    pub fn expectReadError(self: *Self, request: ports.DocsReadAbsoluteRequest, err: ports.PortError) !void {
        // Preserve a single error-shaping path so callers receive consistent metadata.
        const owned_request = try cloneReadRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeReadRequest(self.allocator, owned_request);
        try self.expected_reads.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .err = err },
        });
        request_owned = false;
    }

    /// Records an expected absolute scan call, cloning request data and failing on allocation errors.
    pub fn expectAbsoluteScan(self: *Self, request: ports.DocsScanAbsoluteZigPathsRequest, paths: []const []const u8) !void {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const owned_request = try cloneAbsoluteScanRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeAbsoluteScanRequest(self.allocator, owned_request);
        const owned_paths = try clonePaths(self.allocator, paths);
        var paths_owned = true;
        defer if (paths_owned) {
            const result = ScanResult{ .ok = owned_paths };
            result.deinit(self.allocator);
        };
        try self.expected_absolute_scans.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = owned_paths },
        });
        request_owned = false;
        paths_owned = false;
    }

    /// Records an expected workspace scan call, cloning request data and failing on allocation errors.
    pub fn expectWorkspaceScan(self: *Self, request: ports.DocsScanWorkspacePathsRequest, paths: []const []const u8) !void {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const owned_request = try cloneWorkspaceScanRequest(self.allocator, request);
        var request_owned = true;
        defer if (request_owned) freeWorkspaceScanRequest(self.allocator, owned_request);
        const owned_paths = try clonePaths(self.allocator, paths);
        var paths_owned = true;
        defer if (paths_owned) {
            const result = ScanResult{ .ok = owned_paths };
            result.deinit(self.allocator);
        };
        try self.expected_workspace_scans.append(self.allocator, .{
            .request = owned_request,
            .result = .{ .ok = owned_paths },
        });
        request_owned = false;
        paths_owned = false;
    }

    /// Verifies that all queued expectations were consumed, returning the first missing-call error.
    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_read != self.expected_reads.items.len) return error.MissingExpectedCall;
        if (self.next_absolute_scan != self.expected_absolute_scans.items.len) return error.MissingExpectedCall;
        if (self.next_workspace_scan != self.expected_workspace_scans.items.len) return error.MissingExpectedCall;
    }

    /// Reads bytes from an absolute path through this port.
    fn readAbsolute(ptr: *anyopaque, allocator: Allocator, request: ports.DocsReadAbsoluteRequest) ports.PortError!ports.DocsReadResult {
        // Keep this logic centralized so callers observe one consistent behavior path.
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

    /// Scans absolute Zig source paths through this port.
    fn scanAbsoluteZigPaths(ptr: *anyopaque, allocator: Allocator, request: ports.DocsScanAbsoluteZigPathsRequest) ports.PortError!ports.DocsPathScanResult {
        // Normalize and constrain path handling here before any downstream filesystem action.
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

    /// Scans workspace-relative paths through this port.
    fn scanWorkspacePaths(ptr: *anyopaque, allocator: Allocator, request: ports.DocsScanWorkspacePathsRequest) ports.PortError!ports.DocsPathScanResult {
        // Normalize and constrain path handling here before any downstream filesystem action.
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

    /// Clones read request into allocator-owned storage.
    fn cloneReadRequest(allocator: Allocator, request: ports.DocsReadAbsoluteRequest) !ports.DocsReadAbsoluteRequest {
        // Keep this logic centralized so callers observe one consistent behavior path.
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
            .provenance = provenance,
        };
    }

    /// Releases allocator-owned fields held by the cloned read request.
    fn freeReadRequest(allocator: Allocator, request: ports.DocsReadAbsoluteRequest) void {
        allocator.free(request.path);
        allocator.free(request.provenance);
    }

    /// Clones absolute scan request into allocator-owned storage.
    fn cloneAbsoluteScanRequest(allocator: Allocator, request: ports.DocsScanAbsoluteZigPathsRequest) !ports.DocsScanAbsoluteZigPathsRequest {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const root = try common.dupString(allocator, request.root);
        var root_owned = true;
        defer if (root_owned) allocator.free(root);
        const provenance = try common.dupString(allocator, request.provenance);
        var provenance_owned = true;
        defer if (provenance_owned) allocator.free(provenance);
        root_owned = false;
        provenance_owned = false;
        return .{
            .root = root,
            .max_files = request.max_files,
            .provenance = provenance,
        };
    }

    /// Releases allocator-owned fields held by the cloned absolute scan request.
    fn freeAbsoluteScanRequest(allocator: Allocator, request: ports.DocsScanAbsoluteZigPathsRequest) void {
        allocator.free(request.root);
        allocator.free(request.provenance);
    }

    /// Clones workspace scan request into allocator-owned storage.
    fn cloneWorkspaceScanRequest(allocator: Allocator, request: ports.DocsScanWorkspacePathsRequest) !ports.DocsScanWorkspacePathsRequest {
        return .{
            .max_files = request.max_files,
            .provenance = try common.dupString(allocator, request.provenance),
        };
    }

    /// Releases allocator-owned fields held by the cloned workspace scan request.
    fn freeWorkspaceScanRequest(allocator: Allocator, request: ports.DocsScanWorkspacePathsRequest) void {
        allocator.free(request.provenance);
    }

    /// Clones paths into allocator-owned storage.
    fn clonePaths(allocator: Allocator, raw_paths: []const []const u8) ![]ports.DocsPath {
        // Normalize and constrain path handling here before any downstream filesystem action.
        const paths = try allocator.alloc(ports.DocsPath, raw_paths.len);
        var initialized: usize = 0;
        errdefer {
            for (paths[0..initialized]) |path| allocator.free(path.path);
            allocator.free(paths);
        }
        for (raw_paths, 0..) |path, index| {
            paths[index] = .{ .path = try common.dupString(allocator, path) };
            initialized += 1;
        }
        return paths;
    }

    /// Clones path slices into allocator-owned storage.
    fn copyPaths(allocator: Allocator, paths: []ports.DocsPath) ![]ports.DocsPath {
        // Normalize and constrain path handling here before any downstream filesystem action.
        const copied = try allocator.alloc(ports.DocsPath, paths.len);
        var initialized: usize = 0;
        errdefer {
            for (copied[0..initialized]) |path| allocator.free(path.path);
            allocator.free(copied);
        }
        for (paths, 0..) |path, index| {
            copied[index] = .{ .path = try common.dupString(allocator, path.path) };
            initialized += 1;
        }
        return copied;
    }

    /// Compares read requests by the fields that affect behavior.
    fn readRequestsEqual(expected: ports.DocsReadAbsoluteRequest, actual: ports.DocsReadAbsoluteRequest) bool {
        return std.mem.eql(u8, expected.path, actual.path) and
            expected.max_bytes == actual.max_bytes and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

    /// Compares absolute scan requests by the fields that affect behavior.
    fn absoluteScanRequestsEqual(expected: ports.DocsScanAbsoluteZigPathsRequest, actual: ports.DocsScanAbsoluteZigPathsRequest) bool {
        return std.mem.eql(u8, expected.root, actual.root) and
            expected.max_files == actual.max_files and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

    /// Compares workspace scan requests by the fields that affect behavior.
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

test "docs scanner fake expectations clean partial allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expectDocsScannerWithAllocator, .{});
}

/// Records an expected docs scanner with allocator call, cloning request data and failing on allocation errors.
fn expectDocsScannerWithAllocator(allocator: Allocator) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var fake = FakeDocsScanner.init(allocator);
    defer fake.deinit();

    try fake.expectRead(.{ .path = "/zig/doc/langref.html", .max_bytes = 64, .provenance = "read" }, "langref");
    try fake.expectReadError(.{ .path = "/missing.html", .max_bytes = 64, .provenance = "missing" }, error.FileNotFound);
    try fake.expectAbsoluteScan(.{ .root = "/zig", .max_files = 2, .provenance = "abs" }, &.{ "lib/std/std.zig", "lib/std/mem.zig" });
    try fake.expectWorkspaceScan(.{ .max_files = 2, .provenance = "workspace" }, &.{ "README.md", "src/main.zig" });
}
