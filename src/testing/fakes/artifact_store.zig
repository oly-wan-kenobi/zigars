const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

pub const FakeArtifactStore = struct {
    allocator: Allocator,
    expected_puts: std.ArrayList(ExpectedPut) = .empty,
    expected_reads: std.ArrayList(ExpectedRead) = .empty,
    put_records: std.ArrayList(ports.ArtifactWriteRequest) = .empty,
    read_records: std.ArrayList(ports.ArtifactReadRequest) = .empty,
    next_put: usize = 0,
    next_read: usize = 0,

    const Self = @This();

    const ExpectedPut = struct {
        request: ports.ArtifactWriteRequest,
        ref: ports.ArtifactRef,

        fn deinit(self: ExpectedPut, allocator: Allocator) void {
            freeWriteRequest(allocator, self.request);
            self.ref.deinit(allocator);
        }
    };

    const ExpectedRead = struct {
        request: ports.ArtifactReadRequest,
        bytes: []const u8,

        fn deinit(self: ExpectedRead, allocator: Allocator) void {
            freeReadRequest(allocator, self.request);
            allocator.free(self.bytes);
        }
    };

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.expected_puts.items) |expected| expected.deinit(self.allocator);
        self.expected_puts.deinit(self.allocator);

        for (self.expected_reads.items) |expected| expected.deinit(self.allocator);
        self.expected_reads.deinit(self.allocator);

        for (self.put_records.items) |record| freeWriteRequest(self.allocator, record);
        self.put_records.deinit(self.allocator);

        for (self.read_records.items) |record| freeReadRequest(self.allocator, record);
        self.read_records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn port(self: *Self) ports.ArtifactStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .put = put,
                .read = read,
            },
        };
    }

    pub fn expectPut(self: *Self, request: ports.ArtifactWriteRequest, ref: ports.ArtifactRef) !void {
        const owned_request = try cloneWriteRequest(self.allocator, request);
        errdefer freeWriteRequest(self.allocator, owned_request);
        const owned_ref = try cloneRef(self.allocator, ref);
        errdefer owned_ref.deinit(self.allocator);

        try self.expected_puts.append(self.allocator, .{
            .request = owned_request,
            .ref = owned_ref,
        });
    }

    pub fn expectRead(self: *Self, request: ports.ArtifactReadRequest, bytes: []const u8) !void {
        const owned_request = try cloneReadRequest(self.allocator, request);
        errdefer freeReadRequest(self.allocator, owned_request);
        const owned_bytes = try common.dupString(self.allocator, bytes);
        errdefer self.allocator.free(owned_bytes);

        try self.expected_reads.append(self.allocator, .{
            .request = owned_request,
            .bytes = owned_bytes,
        });
    }

    pub fn putCalls(self: *const Self) []const ports.ArtifactWriteRequest {
        return self.put_records.items;
    }

    pub fn readCalls(self: *const Self) []const ports.ArtifactReadRequest {
        return self.read_records.items;
    }

    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_put != self.expected_puts.items.len) return error.MissingWrite;
        if (self.next_read != self.expected_reads.items.len) return error.MissingExpectedCall;
    }

    fn put(ptr: *anyopaque, allocator: Allocator, request: ports.ArtifactWriteRequest) ports.PortError!ports.ArtifactRef {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneWriteRequest(self.allocator, request);
        var record_owned = false;
        errdefer if (!record_owned) freeWriteRequest(self.allocator, owned_call);
        try self.put_records.append(self.allocator, owned_call);
        record_owned = true;

        if (self.next_put >= self.expected_puts.items.len) return error.UnexpectedCall;
        const expected = self.expected_puts.items[self.next_put];
        if (!writeRequestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_put += 1;
        return try cloneRef(allocator, expected.ref);
    }

    fn read(ptr: *anyopaque, allocator: Allocator, request: ports.ArtifactReadRequest) ports.PortError!ports.ArtifactReadResult {
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

        const bytes = try common.dupString(allocator, expected.bytes);
        return .{ .bytes = bytes, .owns_bytes = true };
    }

    fn cloneWriteRequest(allocator: Allocator, request: ports.ArtifactWriteRequest) !ports.ArtifactWriteRequest {
        const namespace = try common.dupString(allocator, request.namespace);
        errdefer allocator.free(namespace);
        const name = try common.dupString(allocator, request.name);
        errdefer allocator.free(name);
        const kind = try common.dupString(allocator, request.kind);
        errdefer allocator.free(kind);
        const bytes = try common.dupString(allocator, request.bytes);
        errdefer allocator.free(bytes);
        const provenance = try common.dupString(allocator, request.provenance);
        errdefer allocator.free(provenance);
        return .{
            .namespace = namespace,
            .name = name,
            .kind = kind,
            .bytes = bytes,
            .provenance = provenance,
        };
    }

    fn freeWriteRequest(allocator: Allocator, request: ports.ArtifactWriteRequest) void {
        allocator.free(request.namespace);
        allocator.free(request.name);
        allocator.free(request.kind);
        allocator.free(request.bytes);
        allocator.free(request.provenance);
    }

    fn cloneReadRequest(allocator: Allocator, request: ports.ArtifactReadRequest) !ports.ArtifactReadRequest {
        return .{ .id = try common.dupString(allocator, request.id) };
    }

    fn freeReadRequest(allocator: Allocator, request: ports.ArtifactReadRequest) void {
        allocator.free(request.id);
    }

    fn cloneRef(allocator: Allocator, ref: ports.ArtifactRef) !ports.ArtifactRef {
        const id = try common.dupString(allocator, ref.id);
        errdefer allocator.free(id);
        const uri = try common.dupString(allocator, ref.uri);
        errdefer allocator.free(uri);
        const checksum = try common.dupOptionalString(allocator, ref.checksum);
        errdefer common.freeOptionalString(allocator, checksum);
        return .{
            .id = id,
            .uri = uri,
            .checksum = checksum,
            .bytes_written = ref.bytes_written,
            .owns_memory = true,
        };
    }

    fn writeRequestsEqual(expected: ports.ArtifactWriteRequest, actual: ports.ArtifactWriteRequest) bool {
        return std.mem.eql(u8, expected.namespace, actual.namespace) and
            std.mem.eql(u8, expected.name, actual.name) and
            std.mem.eql(u8, expected.kind, actual.kind) and
            std.mem.eql(u8, expected.bytes, actual.bytes) and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }

    fn readRequestsEqual(expected: ports.ArtifactReadRequest, actual: ports.ArtifactReadRequest) bool {
        return std.mem.eql(u8, expected.id, actual.id);
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
        .uri = "zigar://artifact/artifact-1",
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
        .uri = "zigar://artifact/artifact-2",
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
