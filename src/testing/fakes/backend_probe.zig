const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

pub const FakeBackendProbe = struct {
    allocator: Allocator,
    expected_checks: std.ArrayList(ExpectedCheck) = .empty,
    call_records: std.ArrayList(ports.BackendProbeRequest) = .empty,
    next_check: usize = 0,

    const Self = @This();

    const ExpectedCheck = struct {
        request: ports.BackendProbeRequest,
        availability: ports.BackendAvailability,

        fn deinit(self: ExpectedCheck, allocator: Allocator) void {
            freeRequest(allocator, self.request);
            self.availability.deinit(allocator);
        }
    };

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.expected_checks.items) |expected| expected.deinit(self.allocator);
        self.expected_checks.deinit(self.allocator);

        for (self.call_records.items) |record| freeRequest(self.allocator, record);
        self.call_records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn port(self: *Self) ports.BackendProbe {
        return .{
            .ptr = self,
            .vtable = &.{
                .check = check,
            },
        };
    }

    pub fn expectCheck(self: *Self, request: ports.BackendProbeRequest, availability: ports.BackendAvailability) !void {
        const owned_request = try cloneRequest(self.allocator, request);
        errdefer freeRequest(self.allocator, owned_request);
        const owned_availability = try cloneAvailability(self.allocator, availability);
        errdefer owned_availability.deinit(self.allocator);

        try self.expected_checks.append(self.allocator, .{
            .request = owned_request,
            .availability = owned_availability,
        });
    }

    pub fn calls(self: *const Self) []const ports.BackendProbeRequest {
        return self.call_records.items;
    }

    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_check != self.expected_checks.items.len) return error.MissingExpectedCall;
    }

    fn check(ptr: *anyopaque, allocator: Allocator, request: ports.BackendProbeRequest) ports.PortError!ports.BackendAvailability {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_call = try cloneRequest(self.allocator, request);
        var record_owned = false;
        errdefer if (!record_owned) freeRequest(self.allocator, owned_call);
        try self.call_records.append(self.allocator, owned_call);
        record_owned = true;

        if (self.next_check >= self.expected_checks.items.len) return error.UnexpectedCall;
        const expected = self.expected_checks.items[self.next_check];
        if (!requestsEqual(expected.request, request)) return error.StaleArguments;
        self.next_check += 1;
        return try cloneAvailability(allocator, expected.availability);
    }

    fn cloneRequest(allocator: Allocator, request: ports.BackendProbeRequest) !ports.BackendProbeRequest {
        const backend = try common.dupString(allocator, request.backend);
        errdefer allocator.free(backend);
        const argv = try common.dupStringList(allocator, request.argv);
        errdefer common.freeStringList(allocator, argv);
        const cwd = try common.dupOptionalString(allocator, request.cwd);
        errdefer common.freeOptionalString(allocator, cwd);
        const required_capabilities = try common.dupStringList(allocator, request.required_capabilities);
        errdefer common.freeStringList(allocator, required_capabilities);
        const provenance = try common.dupString(allocator, request.provenance);
        errdefer allocator.free(provenance);
        return .{
            .backend = backend,
            .argv = argv,
            .cwd = cwd,
            .timeout_ms = request.timeout_ms,
            .required_capabilities = required_capabilities,
            .provenance = provenance,
        };
    }

    fn freeRequest(allocator: Allocator, request: ports.BackendProbeRequest) void {
        allocator.free(request.backend);
        common.freeStringList(allocator, request.argv);
        common.freeOptionalString(allocator, request.cwd);
        common.freeStringList(allocator, request.required_capabilities);
        allocator.free(request.provenance);
    }

    fn cloneAvailability(allocator: Allocator, availability: ports.BackendAvailability) !ports.BackendAvailability {
        const backend = try common.dupString(allocator, availability.backend);
        errdefer allocator.free(backend);
        const version = try common.dupOptionalString(allocator, availability.version);
        errdefer common.freeOptionalString(allocator, version);
        const capabilities = try common.dupStringList(allocator, availability.capabilities);
        errdefer common.freeStringList(allocator, capabilities);
        const unavailable_reason = try common.dupOptionalString(allocator, availability.unavailable_reason);
        errdefer common.freeOptionalString(allocator, unavailable_reason);
        const basis = try common.dupString(allocator, availability.basis);
        errdefer allocator.free(basis);

        return .{
            .backend = backend,
            .available = availability.available,
            .version = version,
            .capabilities = capabilities,
            .unavailable_reason = unavailable_reason,
            .basis = basis,
            .owns_memory = true,
        };
    }

    fn requestsEqual(expected: ports.BackendProbeRequest, actual: ports.BackendProbeRequest) bool {
        return std.mem.eql(u8, expected.backend, actual.backend) and
            common.stringListsEqual(expected.argv, actual.argv) and
            common.optionalStringsEqual(expected.cwd, actual.cwd) and
            expected.timeout_ms == actual.timeout_ms and
            common.stringListsEqual(expected.required_capabilities, actual.required_capabilities) and
            std.mem.eql(u8, expected.provenance, actual.provenance);
    }
};

test "backend probe returns available backend responses" {
    var fake = FakeBackendProbe.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectCheck(.{
        .backend = "zls",
        .required_capabilities = &.{ "symbols", "diagnostics" },
    }, .{
        .backend = "zls",
        .available = true,
        .version = "0.14.0",
        .capabilities = &.{ "symbols", "diagnostics" },
        .basis = "fake probe",
    });

    const availability = try fake.port().check(std.testing.allocator, .{
        .backend = "zls",
        .required_capabilities = &.{ "symbols", "diagnostics" },
    });
    defer availability.deinit(std.testing.allocator);

    try std.testing.expect(availability.available);
    try std.testing.expectEqualStrings("0.14.0", availability.version.?);
    try std.testing.expectEqualStrings("diagnostics", availability.capabilities[1]);
    try std.testing.expectEqual(@as(usize, 1), fake.calls().len);
    try fake.verify();
}

test "backend probe can return unavailable backend responses" {
    var fake = FakeBackendProbe.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectCheck(.{ .backend = "zflame" }, .{
        .backend = "zflame",
        .available = false,
        .unavailable_reason = "not installed",
        .basis = "PATH probe",
    });

    const availability = try fake.port().check(std.testing.allocator, .{ .backend = "zflame" });
    defer availability.deinit(std.testing.allocator);

    try std.testing.expect(!availability.available);
    try std.testing.expectEqualStrings("not installed", availability.unavailable_reason.?);
    try fake.verify();
}

test "backend probe rejects stale check requests" {
    var fake = FakeBackendProbe.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectCheck(.{
        .backend = "zls",
        .required_capabilities = &.{"symbols"},
    }, .{
        .backend = "zls",
        .available = true,
        .capabilities = &.{"symbols"},
    });

    try std.testing.expectError(error.StaleArguments, fake.port().check(std.testing.allocator, .{
        .backend = "zls",
        .required_capabilities = &.{"diagnostics"},
    }));
    try std.testing.expectEqual(@as(usize, 1), fake.calls().len);
    try std.testing.expectError(error.MissingExpectedCall, fake.verify());
}

test "backend probe rejects unexpected calls" {
    var fake = FakeBackendProbe.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(error.UnexpectedCall, fake.port().check(std.testing.allocator, .{ .backend = "zwanzig" }));
}

test "backend probe expected checks clean partial allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expectBackendCheckWithAllocator, .{});
}

fn expectBackendCheckWithAllocator(allocator: Allocator) !void {
    var fake = FakeBackendProbe.init(allocator);
    defer fake.deinit();

    try fake.expectCheck(.{
        .backend = "zls",
        .argv = &.{ "zls", "--version" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .required_capabilities = &.{ "symbols", "diagnostics" },
        .provenance = "test-probe",
    }, .{
        .backend = "zls",
        .available = true,
        .version = "0.14.0",
        .capabilities = &.{ "symbols", "diagnostics" },
        .basis = "fake probe",
    });
}
