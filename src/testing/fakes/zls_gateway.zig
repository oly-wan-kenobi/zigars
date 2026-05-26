const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

/// ZlsGateway fake with ordered capability, sync, and request expectations.
pub const FakeZlsGateway = struct {
    allocator: Allocator,
    expected_capabilities: std.ArrayList(ExpectedCapability) = .empty,
    expected_syncs: std.ArrayList(ExpectedSync) = .empty,
    expected_requests: std.ArrayList(ExpectedRequest) = .empty,
    capability_records: std.ArrayList(ports.ZlsCapabilityRequest) = .empty,
    sync_records: std.ArrayList(ports.ZlsSyncRequest) = .empty,
    request_records: std.ArrayList(ports.ZlsRequest) = .empty,
    next_capability: usize = 0,
    next_sync: usize = 0,
    next_request: usize = 0,

    const Self = @This();

    /// Expected capability lookup and result/error.
    const ExpectedCapability = struct {
        request: ports.ZlsCapabilityRequest,
        outcome: CapabilityOutcome,

        /// Frees the cloned capability request and successful result payload.
        fn deinit(self: ExpectedCapability, allocator: Allocator) void {
            freeCapabilityRequest(allocator, self.request);
            switch (self.outcome) {
                .result => |result| freeCapabilityResult(allocator, result),
                .err => {},
            }
        }
    };

    /// Capability expectation outcome.
    const CapabilityOutcome = union(enum) {
        result: ports.ZlsCapabilityResult,
        err: ports.PortError,
    };

    /// Expected document sync and result/error.
    const ExpectedSync = struct {
        request: ports.ZlsSyncRequest,
        outcome: SyncOutcome,

        /// Frees the cloned sync request and successful sync result.
        fn deinit(self: ExpectedSync, allocator: Allocator) void {
            freeSyncRequest(allocator, self.request);
            switch (self.outcome) {
                .result => |result| freeSyncResult(allocator, result),
                .err => {},
            }
        }
    };

    /// Sync expectation outcome.
    const SyncOutcome = union(enum) {
        result: ports.ZlsSyncResult,
        err: ports.PortError,
    };

    /// Expected raw ZLS request and response/error.
    const ExpectedRequest = struct {
        request: ports.ZlsRequest,
        outcome: RequestOutcome,

        /// Frees the cloned raw request and successful response payload.
        fn deinit(self: ExpectedRequest, allocator: Allocator) void {
            freeRequest(allocator, self.request);
            switch (self.outcome) {
                .response => |response| freeResponse(allocator, response),
                .err => {},
            }
        }
    };

    /// Raw request expectation outcome.
    const RequestOutcome = union(enum) {
        response: ports.ZlsResponse,
        err: ports.PortError,
    };

    /// Creates an empty fake that owns expectations with `allocator`.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Frees expectations and recorded call snapshots.
    pub fn deinit(self: *Self) void {
        for (self.expected_capabilities.items) |expected| expected.deinit(self.allocator);
        self.expected_capabilities.deinit(self.allocator);

        for (self.expected_syncs.items) |expected| expected.deinit(self.allocator);
        self.expected_syncs.deinit(self.allocator);

        for (self.expected_requests.items) |expected| expected.deinit(self.allocator);
        self.expected_requests.deinit(self.allocator);

        for (self.capability_records.items) |record| freeCapabilityRequest(self.allocator, record);
        self.capability_records.deinit(self.allocator);

        for (self.sync_records.items) |record| freeSyncRequest(self.allocator, record);
        self.sync_records.deinit(self.allocator);

        for (self.request_records.items) |record| freeRequest(self.allocator, record);
        self.request_records.deinit(self.allocator);
        self.* = undefined;
    }

    /// Exposes this fake through the ZlsGateway vtable.
    pub fn port(self: *Self) ports.ZlsGateway {
        return .{
            .ptr = self,
            .vtable = &.{
                .capability = capability,
                .sync = sync,
                .request = request,
            },
        };
    }

    /// Adds an ordered successful capability expectation.
    pub fn expectCapability(self: *Self, request_value: ports.ZlsCapabilityRequest, result: ports.ZlsCapabilityResult) !void {
        const owned_request = try cloneCapabilityRequest(self.allocator, request_value);
        var request_owned = true;
        defer if (request_owned) freeCapabilityRequest(self.allocator, owned_request);
        const owned_result = try cloneCapabilityResult(self.allocator, result);
        var result_owned = true;
        defer if (result_owned) freeCapabilityResult(self.allocator, owned_result);
        try self.expected_capabilities.append(self.allocator, .{
            .request = owned_request,
            .outcome = .{ .result = owned_result },
        });
        request_owned = false;
        result_owned = false;
    }

    /// Records an expected capability error call, cloning request data and failing on allocation errors.
    pub fn expectCapabilityError(self: *Self, request_value: ports.ZlsCapabilityRequest, err: ports.PortError) !void {
        const owned_request = try cloneCapabilityRequest(self.allocator, request_value);
        var request_owned = true;
        defer if (request_owned) freeCapabilityRequest(self.allocator, owned_request);
        try self.expected_capabilities.append(self.allocator, .{
            .request = owned_request,
            .outcome = .{ .err = err },
        });
        request_owned = false;
    }

    /// Records an expected sync call, cloning request data and failing on allocation errors.
    pub fn expectSync(self: *Self, request_value: ports.ZlsSyncRequest, result: ports.ZlsSyncResult) !void {
        const owned_request = try cloneSyncRequest(self.allocator, request_value);
        var request_owned = true;
        defer if (request_owned) freeSyncRequest(self.allocator, owned_request);
        const owned_result = try cloneSyncResult(self.allocator, result);
        var result_owned = true;
        defer if (result_owned) freeSyncResult(self.allocator, owned_result);
        try self.expected_syncs.append(self.allocator, .{
            .request = owned_request,
            .outcome = .{ .result = owned_result },
        });
        request_owned = false;
        result_owned = false;
    }

    /// Records an expected sync error call, cloning request data and failing on allocation errors.
    pub fn expectSyncError(self: *Self, request_value: ports.ZlsSyncRequest, err: ports.PortError) !void {
        const owned_request = try cloneSyncRequest(self.allocator, request_value);
        var request_owned = true;
        defer if (request_owned) freeSyncRequest(self.allocator, owned_request);
        try self.expected_syncs.append(self.allocator, .{
            .request = owned_request,
            .outcome = .{ .err = err },
        });
        request_owned = false;
    }

    /// Records an expected request call, cloning request data and failing on allocation errors.
    pub fn expectRequest(self: *Self, request_value: ports.ZlsRequest, response: ports.ZlsResponse) !void {
        const owned_request = try cloneRequest(self.allocator, request_value);
        var request_owned = true;
        defer if (request_owned) freeRequest(self.allocator, owned_request);
        const owned_response = try cloneResponse(self.allocator, response);
        var response_owned = true;
        defer if (response_owned) freeResponse(self.allocator, owned_response);
        try self.expected_requests.append(self.allocator, .{
            .request = owned_request,
            .outcome = .{ .response = owned_response },
        });
        request_owned = false;
        response_owned = false;
    }

    /// Records an expected request error call, cloning request data and failing on allocation errors.
    pub fn expectRequestError(self: *Self, request_value: ports.ZlsRequest, err: ports.PortError) !void {
        const owned_request = try cloneRequest(self.allocator, request_value);
        var request_owned = true;
        defer if (request_owned) freeRequest(self.allocator, owned_request);
        try self.expected_requests.append(self.allocator, .{
            .request = owned_request,
            .outcome = .{ .err = err },
        });
        request_owned = false;
    }

    /// Returns recorded capability call snapshots owned by this fake.
    pub fn capabilityCalls(self: *const Self) []const ports.ZlsCapabilityRequest {
        return self.capability_records.items;
    }

    /// Returns recorded sync call snapshots owned by this fake.
    pub fn syncCalls(self: *const Self) []const ports.ZlsSyncRequest {
        return self.sync_records.items;
    }

    /// Returns recorded request call snapshots owned by this fake.
    pub fn requestCalls(self: *const Self) []const ports.ZlsRequest {
        return self.request_records.items;
    }

    /// Verifies that all queued expectations were consumed, returning the first missing-call error.
    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_capability != self.expected_capabilities.items.len) return error.MissingExpectedCall;
        if (self.next_sync != self.expected_syncs.items.len) return error.MissingExpectedCall;
        if (self.next_request != self.expected_requests.items.len) return error.MissingExpectedCall;
    }

    /// Reports whether the fake ZLS gateway supports a capability.
    fn capability(ptr: *anyopaque, request_value: ports.ZlsCapabilityRequest) ports.PortError!ports.ZlsCapabilityResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneCapabilityRequest(self.allocator, request_value);
        var record_owned = true;
        defer if (record_owned) freeCapabilityRequest(self.allocator, owned_call);
        try self.capability_records.append(self.allocator, owned_call);
        record_owned = false;

        if (self.next_capability >= self.expected_capabilities.items.len) return error.UnexpectedCall;
        const expected = self.expected_capabilities.items[self.next_capability];
        if (!capabilityRequestsEqual(expected.request, request_value)) return error.StaleArguments;
        self.next_capability += 1;
        return switch (expected.outcome) {
            .result => |result| result,
            .err => |err| err,
        };
    }

    /// Applies a text synchronization request through the fake ZLS gateway.
    fn sync(ptr: *anyopaque, allocator: Allocator, request_value: ports.ZlsSyncRequest) ports.PortError!ports.ZlsSyncResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneSyncRequest(self.allocator, request_value);
        var record_owned = true;
        defer if (record_owned) freeSyncRequest(self.allocator, owned_call);
        try self.sync_records.append(self.allocator, owned_call);
        record_owned = false;

        if (self.next_sync >= self.expected_syncs.items.len) return error.UnexpectedCall;
        const expected = self.expected_syncs.items[self.next_sync];
        if (!syncRequestsEqual(expected.request, request_value)) return error.StaleArguments;
        self.next_sync += 1;
        return switch (expected.outcome) {
            .result => |result| cloneSyncResultForCaller(allocator, result),
            .err => |err| err,
        };
    }

    /// Sends a raw request through the fake ZLS gateway.
    fn request(ptr: *anyopaque, allocator: Allocator, request_value: ports.ZlsRequest) ports.PortError!ports.ZlsResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneRequest(self.allocator, request_value);
        var record_owned = true;
        defer if (record_owned) freeRequest(self.allocator, owned_call);
        try self.request_records.append(self.allocator, owned_call);
        record_owned = false;

        if (self.next_request >= self.expected_requests.items.len) return error.UnexpectedCall;
        const expected = self.expected_requests.items[self.next_request];
        if (!requestsEqual(expected.request, request_value)) return error.StaleArguments;
        self.next_request += 1;

        return switch (expected.outcome) {
            .response => |response| blk: {
                const payload = try common.dupString(allocator, response.payload);
                break :blk .{
                    .method = response.method,
                    .payload = payload,
                    .owns_payload = true,
                };
            },
            .err => |err| err,
        };
    }

    /// Clones capability request into allocator-owned storage.
    fn cloneCapabilityRequest(allocator: Allocator, request_value: ports.ZlsCapabilityRequest) !ports.ZlsCapabilityRequest {
        return .{ .capability = try common.dupString(allocator, request_value.capability) };
    }

    /// Releases allocator-owned fields held by the cloned capability request.
    fn freeCapabilityRequest(allocator: Allocator, request_value: ports.ZlsCapabilityRequest) void {
        allocator.free(request_value.capability);
    }

    /// Clones capability result into allocator-owned storage.
    fn cloneCapabilityResult(allocator: Allocator, result: ports.ZlsCapabilityResult) !ports.ZlsCapabilityResult {
        const capability_name = try common.dupString(allocator, result.capability);
        var capability_owned = true;
        defer if (capability_owned) allocator.free(capability_name);
        const basis = try common.dupString(allocator, result.basis);
        var basis_owned = true;
        defer if (basis_owned) allocator.free(basis);
        capability_owned = false;
        basis_owned = false;
        return .{
            .capability = capability_name,
            .supported = result.supported,
            .basis = basis,
        };
    }

    /// Releases allocator-owned fields held by the cloned capability result.
    fn freeCapabilityResult(allocator: Allocator, result: ports.ZlsCapabilityResult) void {
        allocator.free(result.capability);
        allocator.free(result.basis);
    }

    /// Clones sync request into allocator-owned storage.
    fn cloneSyncRequest(allocator: Allocator, request_value: ports.ZlsSyncRequest) !ports.ZlsSyncRequest {
        const file = try common.dupString(allocator, request_value.file);
        var file_owned = true;
        defer if (file_owned) allocator.free(file);
        const content = try common.dupOptionalString(allocator, request_value.content);
        var content_owned = true;
        defer if (content_owned) common.freeOptionalString(allocator, content);
        const provenance = try common.dupString(allocator, request_value.provenance);
        var provenance_owned = true;
        defer if (provenance_owned) allocator.free(provenance);
        file_owned = false;
        content_owned = false;
        provenance_owned = false;
        return .{
            .file = file,
            .content = content,
            .provenance = provenance,
        };
    }

    /// Releases allocator-owned fields held by the cloned sync request.
    fn freeSyncRequest(allocator: Allocator, request_value: ports.ZlsSyncRequest) void {
        allocator.free(request_value.file);
        common.freeOptionalString(allocator, request_value.content);
        allocator.free(request_value.provenance);
    }

    /// Clones sync result into allocator-owned storage.
    fn cloneSyncResult(allocator: Allocator, result: ports.ZlsSyncResult) !ports.ZlsSyncResult {
        const uri = try common.dupString(allocator, result.uri);
        var uri_owned = true;
        defer if (uri_owned) allocator.free(uri);
        const basis = try common.dupString(allocator, result.basis);
        var basis_owned = true;
        defer if (basis_owned) allocator.free(basis);
        uri_owned = false;
        basis_owned = false;
        return .{
            .uri = uri,
            .basis = basis,
            .owns_uri = true,
        };
    }

    /// Releases allocator-owned fields held by the cloned sync result.
    fn freeSyncResult(allocator: Allocator, result: ports.ZlsSyncResult) void {
        if (result.owns_uri) allocator.free(result.uri);
        allocator.free(result.basis);
    }

    /// Clones sync result for caller into allocator-owned storage.
    fn cloneSyncResultForCaller(allocator: Allocator, result: ports.ZlsSyncResult) ports.PortError!ports.ZlsSyncResult {
        const uri = try common.dupString(allocator, result.uri);
        return .{
            .uri = uri,
            .basis = result.basis,
            .owns_uri = true,
        };
    }

    /// Clones request into allocator-owned storage.
    fn cloneRequest(allocator: Allocator, request_value: ports.ZlsRequest) !ports.ZlsRequest {
        const method = try common.dupString(allocator, request_value.method);
        var method_owned = true;
        defer if (method_owned) allocator.free(method);
        const uri = try common.dupOptionalString(allocator, request_value.uri);
        var uri_owned = true;
        defer if (uri_owned) common.freeOptionalString(allocator, uri);
        const payload = try common.dupString(allocator, request_value.payload);
        var payload_owned = true;
        defer if (payload_owned) allocator.free(payload);
        method_owned = false;
        uri_owned = false;
        payload_owned = false;
        return .{
            .method = method,
            .uri = uri,
            .payload = payload,
        };
    }

    /// Releases allocator-owned fields held by the cloned request.
    fn freeRequest(allocator: Allocator, request_value: ports.ZlsRequest) void {
        allocator.free(request_value.method);
        common.freeOptionalString(allocator, request_value.uri);
        allocator.free(request_value.payload);
    }

    /// Clones response into allocator-owned storage.
    fn cloneResponse(allocator: Allocator, response: ports.ZlsResponse) !ports.ZlsResponse {
        const method = try common.dupString(allocator, response.method);
        var method_owned = true;
        defer if (method_owned) allocator.free(method);
        const payload = try common.dupString(allocator, response.payload);
        var payload_owned = true;
        defer if (payload_owned) allocator.free(payload);
        method_owned = false;
        payload_owned = false;
        return .{
            .method = method,
            .payload = payload,
            .owns_payload = true,
        };
    }

    /// Releases allocator-owned fields held by the cloned response.
    fn freeResponse(allocator: Allocator, response: ports.ZlsResponse) void {
        allocator.free(response.method);
        if (response.owns_payload) allocator.free(response.payload);
    }

    /// Compares capability requests by the fields that affect behavior.
    fn capabilityRequestsEqual(expected: ports.ZlsCapabilityRequest, actual: ports.ZlsCapabilityRequest) bool {
        return std.mem.eql(u8, expected.capability, actual.capability);
    }

    /// Compares sync requests by the fields that affect behavior.
    fn syncRequestsEqual(expected: ports.ZlsSyncRequest, actual: ports.ZlsSyncRequest) bool {
        return std.mem.eql(u8, expected.file, actual.file) and
            common.optionalStringsEqual(expected.content, actual.content) and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

    /// Compares requests by the fields that affect behavior.
    fn requestsEqual(expected: ports.ZlsRequest, actual: ports.ZlsRequest) bool {
        return std.mem.eql(u8, expected.method, actual.method) and
            common.optionalStringsEqual(expected.uri, actual.uri) and
            std.mem.eql(u8, expected.payload, actual.payload);
    }
};

test "zls gateway records capability sync and request calls" {
    var fake = FakeZlsGateway.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectCapability(.{ .capability = "documentSymbol" }, .{
        .capability = "documentSymbol",
        .supported = true,
        .basis = "server capabilities",
    });
    try fake.expectSync(.{ .file = "src/main.zig", .content = "pub fn main() void {}\n", .provenance = "test" }, .{
        .uri = "file:///repo/src/main.zig",
        .basis = "opened",
    });
    try fake.expectRequest(.{
        .method = "textDocument/documentSymbol",
        .uri = "file:///repo/src/main.zig",
        .payload = "{}",
    }, .{
        .method = "textDocument/documentSymbol",
        .payload = "[]",
    });

    const capability_result = try fake.port().capability(.{ .capability = "documentSymbol" });
    try std.testing.expect(capability_result.supported);

    const sync_result = try fake.port().sync(std.testing.allocator, .{ .file = "src/main.zig", .content = "pub fn main() void {}\n", .provenance = "test" });
    defer sync_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("file:///repo/src/main.zig", sync_result.uri);

    const response = try fake.port().request(std.testing.allocator, .{
        .method = "textDocument/documentSymbol",
        .uri = "file:///repo/src/main.zig",
        .payload = "{}",
    });
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[]", response.payload);
    try std.testing.expectEqual(@as(usize, 1), fake.capabilityCalls().len);
    try std.testing.expectEqual(@as(usize, 1), fake.syncCalls().len);
    try std.testing.expectEqual(@as(usize, 1), fake.requestCalls().len);
    try fake.verify();
}

test "zls gateway rejects stale capability requests" {
    var fake = FakeZlsGateway.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectCapability(.{ .capability = "documentSymbol" }, .{
        .capability = "documentSymbol",
        .supported = true,
    });

    try std.testing.expectError(error.StaleArguments, fake.port().capability(.{ .capability = "workspaceSymbol" }));
    try std.testing.expectEqual(@as(usize, 1), fake.capabilityCalls().len);
    try std.testing.expectError(error.MissingExpectedCall, fake.verify());
}

test "zls gateway rejects stale request payloads" {
    var fake = FakeZlsGateway.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectRequest(.{ .method = "workspace/symbol", .payload = "{\"query\":\"main\"}" }, .{
        .method = "workspace/symbol",
        .payload = "[]",
    });

    try std.testing.expectError(error.StaleArguments, fake.port().request(std.testing.allocator, .{
        .method = "workspace/symbol",
        .payload = "{\"query\":\"old\"}",
    }));
}
