const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

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

    const ExpectedCapability = struct {
        request: ports.ZlsCapabilityRequest,
        outcome: CapabilityOutcome,

        fn deinit(self: ExpectedCapability, allocator: Allocator) void {
            freeCapabilityRequest(allocator, self.request);
            switch (self.outcome) {
                .result => |result| freeCapabilityResult(allocator, result),
                .err => {},
            }
        }
    };

    const CapabilityOutcome = union(enum) {
        result: ports.ZlsCapabilityResult,
        err: ports.PortError,
    };

    const ExpectedSync = struct {
        request: ports.ZlsSyncRequest,
        outcome: SyncOutcome,

        fn deinit(self: ExpectedSync, allocator: Allocator) void {
            freeSyncRequest(allocator, self.request);
            switch (self.outcome) {
                .result => |result| freeSyncResult(allocator, result),
                .err => {},
            }
        }
    };

    const SyncOutcome = union(enum) {
        result: ports.ZlsSyncResult,
        err: ports.PortError,
    };

    const ExpectedRequest = struct {
        request: ports.ZlsRequest,
        outcome: RequestOutcome,

        fn deinit(self: ExpectedRequest, allocator: Allocator) void {
            freeRequest(allocator, self.request);
            switch (self.outcome) {
                .response => |response| freeResponse(allocator, response),
                .err => {},
            }
        }
    };

    const RequestOutcome = union(enum) {
        response: ports.ZlsResponse,
        err: ports.PortError,
    };

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

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

    pub fn expectCapability(self: *Self, request_value: ports.ZlsCapabilityRequest, result: ports.ZlsCapabilityResult) !void {
        const owned_request = try cloneCapabilityRequest(self.allocator, request_value);
        errdefer freeCapabilityRequest(self.allocator, owned_request);
        const owned_result = try cloneCapabilityResult(self.allocator, result);
        errdefer freeCapabilityResult(self.allocator, owned_result);
        try self.expected_capabilities.append(self.allocator, .{
            .request = owned_request,
            .outcome = .{ .result = owned_result },
        });
    }

    pub fn expectCapabilityError(self: *Self, request_value: ports.ZlsCapabilityRequest, err: ports.PortError) !void {
        const owned_request = try cloneCapabilityRequest(self.allocator, request_value);
        errdefer freeCapabilityRequest(self.allocator, owned_request);
        try self.expected_capabilities.append(self.allocator, .{
            .request = owned_request,
            .outcome = .{ .err = err },
        });
    }

    pub fn expectSync(self: *Self, request_value: ports.ZlsSyncRequest, result: ports.ZlsSyncResult) !void {
        const owned_request = try cloneSyncRequest(self.allocator, request_value);
        errdefer freeSyncRequest(self.allocator, owned_request);
        const owned_result = try cloneSyncResult(self.allocator, result);
        errdefer freeSyncResult(self.allocator, owned_result);
        try self.expected_syncs.append(self.allocator, .{
            .request = owned_request,
            .outcome = .{ .result = owned_result },
        });
    }

    pub fn expectSyncError(self: *Self, request_value: ports.ZlsSyncRequest, err: ports.PortError) !void {
        const owned_request = try cloneSyncRequest(self.allocator, request_value);
        errdefer freeSyncRequest(self.allocator, owned_request);
        try self.expected_syncs.append(self.allocator, .{
            .request = owned_request,
            .outcome = .{ .err = err },
        });
    }

    pub fn expectRequest(self: *Self, request_value: ports.ZlsRequest, response: ports.ZlsResponse) !void {
        const owned_request = try cloneRequest(self.allocator, request_value);
        errdefer freeRequest(self.allocator, owned_request);
        const owned_response = try cloneResponse(self.allocator, response);
        errdefer freeResponse(self.allocator, owned_response);
        try self.expected_requests.append(self.allocator, .{
            .request = owned_request,
            .outcome = .{ .response = owned_response },
        });
    }

    pub fn expectRequestError(self: *Self, request_value: ports.ZlsRequest, err: ports.PortError) !void {
        const owned_request = try cloneRequest(self.allocator, request_value);
        errdefer freeRequest(self.allocator, owned_request);
        try self.expected_requests.append(self.allocator, .{
            .request = owned_request,
            .outcome = .{ .err = err },
        });
    }

    pub fn capabilityCalls(self: *const Self) []const ports.ZlsCapabilityRequest {
        return self.capability_records.items;
    }

    pub fn syncCalls(self: *const Self) []const ports.ZlsSyncRequest {
        return self.sync_records.items;
    }

    pub fn requestCalls(self: *const Self) []const ports.ZlsRequest {
        return self.request_records.items;
    }

    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_capability != self.expected_capabilities.items.len) return error.MissingExpectedCall;
        if (self.next_sync != self.expected_syncs.items.len) return error.MissingExpectedCall;
        if (self.next_request != self.expected_requests.items.len) return error.MissingExpectedCall;
    }

    fn capability(ptr: *anyopaque, request_value: ports.ZlsCapabilityRequest) ports.PortError!ports.ZlsCapabilityResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneCapabilityRequest(self.allocator, request_value);
        var record_owned = false;
        errdefer if (!record_owned) freeCapabilityRequest(self.allocator, owned_call);
        try self.capability_records.append(self.allocator, owned_call);
        record_owned = true;

        if (self.next_capability >= self.expected_capabilities.items.len) return error.UnexpectedCall;
        const expected = self.expected_capabilities.items[self.next_capability];
        if (!capabilityRequestsEqual(expected.request, request_value)) return error.StaleArguments;
        self.next_capability += 1;
        return switch (expected.outcome) {
            .result => |result| result,
            .err => |err| err,
        };
    }

    fn sync(ptr: *anyopaque, allocator: Allocator, request_value: ports.ZlsSyncRequest) ports.PortError!ports.ZlsSyncResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneSyncRequest(self.allocator, request_value);
        var record_owned = false;
        errdefer if (!record_owned) freeSyncRequest(self.allocator, owned_call);
        try self.sync_records.append(self.allocator, owned_call);
        record_owned = true;

        if (self.next_sync >= self.expected_syncs.items.len) return error.UnexpectedCall;
        const expected = self.expected_syncs.items[self.next_sync];
        if (!syncRequestsEqual(expected.request, request_value)) return error.StaleArguments;
        self.next_sync += 1;
        return switch (expected.outcome) {
            .result => |result| cloneSyncResultForCaller(allocator, result),
            .err => |err| err,
        };
    }

    fn request(ptr: *anyopaque, allocator: Allocator, request_value: ports.ZlsRequest) ports.PortError!ports.ZlsResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneRequest(self.allocator, request_value);
        var record_owned = false;
        errdefer if (!record_owned) freeRequest(self.allocator, owned_call);
        try self.request_records.append(self.allocator, owned_call);
        record_owned = true;

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

    fn cloneCapabilityRequest(allocator: Allocator, request_value: ports.ZlsCapabilityRequest) !ports.ZlsCapabilityRequest {
        return .{ .capability = try common.dupString(allocator, request_value.capability) };
    }

    fn freeCapabilityRequest(allocator: Allocator, request_value: ports.ZlsCapabilityRequest) void {
        allocator.free(request_value.capability);
    }

    fn cloneCapabilityResult(allocator: Allocator, result: ports.ZlsCapabilityResult) !ports.ZlsCapabilityResult {
        const capability_name = try common.dupString(allocator, result.capability);
        errdefer allocator.free(capability_name);
        const basis = try common.dupString(allocator, result.basis);
        errdefer allocator.free(basis);
        return .{
            .capability = capability_name,
            .supported = result.supported,
            .basis = basis,
        };
    }

    fn freeCapabilityResult(allocator: Allocator, result: ports.ZlsCapabilityResult) void {
        allocator.free(result.capability);
        allocator.free(result.basis);
    }

    fn cloneSyncRequest(allocator: Allocator, request_value: ports.ZlsSyncRequest) !ports.ZlsSyncRequest {
        const file = try common.dupString(allocator, request_value.file);
        errdefer allocator.free(file);
        const content = try common.dupOptionalString(allocator, request_value.content);
        errdefer common.freeOptionalString(allocator, content);
        const provenance = try common.dupString(allocator, request_value.provenance);
        errdefer allocator.free(provenance);
        return .{
            .file = file,
            .content = content,
            .provenance = provenance,
        };
    }

    fn freeSyncRequest(allocator: Allocator, request_value: ports.ZlsSyncRequest) void {
        allocator.free(request_value.file);
        common.freeOptionalString(allocator, request_value.content);
        allocator.free(request_value.provenance);
    }

    fn cloneSyncResult(allocator: Allocator, result: ports.ZlsSyncResult) !ports.ZlsSyncResult {
        const uri = try common.dupString(allocator, result.uri);
        errdefer allocator.free(uri);
        const basis = try common.dupString(allocator, result.basis);
        errdefer allocator.free(basis);
        return .{
            .uri = uri,
            .basis = basis,
            .owns_uri = true,
        };
    }

    fn freeSyncResult(allocator: Allocator, result: ports.ZlsSyncResult) void {
        if (result.owns_uri) allocator.free(result.uri);
        allocator.free(result.basis);
    }

    fn cloneSyncResultForCaller(allocator: Allocator, result: ports.ZlsSyncResult) ports.PortError!ports.ZlsSyncResult {
        const uri = try common.dupString(allocator, result.uri);
        return .{
            .uri = uri,
            .basis = result.basis,
            .owns_uri = true,
        };
    }

    fn cloneRequest(allocator: Allocator, request_value: ports.ZlsRequest) !ports.ZlsRequest {
        const method = try common.dupString(allocator, request_value.method);
        errdefer allocator.free(method);
        const uri = try common.dupOptionalString(allocator, request_value.uri);
        errdefer common.freeOptionalString(allocator, uri);
        const payload = try common.dupString(allocator, request_value.payload);
        errdefer allocator.free(payload);
        return .{
            .method = method,
            .uri = uri,
            .payload = payload,
        };
    }

    fn freeRequest(allocator: Allocator, request_value: ports.ZlsRequest) void {
        allocator.free(request_value.method);
        common.freeOptionalString(allocator, request_value.uri);
        allocator.free(request_value.payload);
    }

    fn cloneResponse(allocator: Allocator, response: ports.ZlsResponse) !ports.ZlsResponse {
        const method = try common.dupString(allocator, response.method);
        errdefer allocator.free(method);
        const payload = try common.dupString(allocator, response.payload);
        errdefer allocator.free(payload);
        return .{
            .method = method,
            .payload = payload,
            .owns_payload = true,
        };
    }

    fn freeResponse(allocator: Allocator, response: ports.ZlsResponse) void {
        allocator.free(response.method);
        if (response.owns_payload) allocator.free(response.payload);
    }

    fn capabilityRequestsEqual(expected: ports.ZlsCapabilityRequest, actual: ports.ZlsCapabilityRequest) bool {
        return std.mem.eql(u8, expected.capability, actual.capability);
    }

    fn syncRequestsEqual(expected: ports.ZlsSyncRequest, actual: ports.ZlsSyncRequest) bool {
        return std.mem.eql(u8, expected.file, actual.file) and
            common.optionalStringsEqual(expected.content, actual.content) and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

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
