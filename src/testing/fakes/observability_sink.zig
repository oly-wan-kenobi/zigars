//! Fake implementation of the `ports.ObservabilitySink` port.
//! Records every emitted observation event and enforces ordered expectations.
//! Use `expectEvent` to assert that a named phase event with specific attributes
//! arrives in sequence; `verify` confirms no expected event was skipped.

const std = @import("std");

const ports = @import("../../app/ports.zig");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

/// ObservabilitySink fake that enforces ordered event expectations.
pub const FakeObservabilitySink = struct {
    allocator: Allocator,
    expected_events: std.ArrayList(ports.ObservationEvent) = .empty,
    event_records: std.ArrayList(ports.ObservationEvent) = .empty,
    next_event: usize = 0,

    const Self = @This();

    /// Creates an empty fake that owns expected and recorded events.
    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Frees expected and recorded event snapshots.
    pub fn deinit(self: *Self) void {
        for (self.expected_events.items) |event| freeEvent(self.allocator, event);
        self.expected_events.deinit(self.allocator);

        for (self.event_records.items) |event| freeEvent(self.allocator, event);
        self.event_records.deinit(self.allocator);
        self.* = undefined;
    }

    /// Exposes this fake through the ObservabilitySink vtable.
    pub fn port(self: *Self) ports.ObservabilitySink {
        return .{
            .ptr = self,
            .vtable = &.{
                .emit = emit,
            },
        };
    }

    /// Adds an ordered expected observation event.
    pub fn expectEvent(self: *Self, event: ports.ObservationEvent) !void {
        const owned_event = try cloneEvent(self.allocator, event);
        errdefer freeEvent(self.allocator, owned_event);
        try self.expected_events.append(self.allocator, owned_event);
    }

    /// Returns immutable snapshots of emitted events.
    pub fn events(self: *const Self) []const ports.ObservationEvent {
        return self.event_records.items;
    }

    /// Fails if any expected event was not emitted.
    pub fn verify(self: *const Self) ports.PortError!void {
        if (self.next_event != self.expected_events.items.len) return error.MissingExpectedCall;
    }

    /// Records an observability event in the fake sink.
    fn emit(ptr: *anyopaque, event: ports.ObservationEvent) ports.PortError!void {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const self: *Self = @ptrCast(@alignCast(ptr));
        const owned_event = try cloneEvent(self.allocator, event);
        var record_owned = false;
        errdefer if (!record_owned) freeEvent(self.allocator, owned_event);
        try self.event_records.append(self.allocator, owned_event);
        record_owned = true;

        if (self.next_event >= self.expected_events.items.len) return error.UnexpectedCall;
        const expected = self.expected_events.items[self.next_event];
        if (!eventsEqual(expected, event)) return error.StaleArguments;
        self.next_event += 1;
    }

    /// Clones event into allocator-owned storage.
    fn cloneEvent(allocator: Allocator, event: ports.ObservationEvent) !ports.ObservationEvent {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const name = try common.dupString(allocator, event.name);
        errdefer allocator.free(name);
        const phase = try common.dupString(allocator, event.phase);
        errdefer allocator.free(phase);
        const attributes = try cloneAttributes(allocator, event.attributes);
        errdefer freeAttributes(allocator, attributes);
        return .{
            .name = name,
            .phase = phase,
            .attributes = attributes,
            .duration_ms = event.duration_ms,
        };
    }

    /// Releases allocator-owned fields held by the cloned event.
    fn freeEvent(allocator: Allocator, event: ports.ObservationEvent) void {
        allocator.free(event.name);
        allocator.free(event.phase);
        freeAttributes(allocator, event.attributes);
    }

    /// Clones attributes into allocator-owned storage.
    fn cloneAttributes(allocator: Allocator, attributes: []const ports.ObservationAttribute) ![]const ports.ObservationAttribute {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const copied = try allocator.alloc(ports.ObservationAttribute, attributes.len);
        errdefer allocator.free(copied);

        var copied_count: usize = 0;
        errdefer {
            for (copied[0..copied_count]) |attribute| {
                allocator.free(attribute.key);
                allocator.free(attribute.value);
            }
        }

        for (attributes, 0..) |attribute, index| {
            const key = try common.dupString(allocator, attribute.key);
            errdefer allocator.free(key);
            const value = try common.dupString(allocator, attribute.value);
            copied[index] = .{ .key = key, .value = value };
            copied_count += 1;
        }
        return copied;
    }

    /// Releases allocator-owned fields held by the cloned attributes.
    fn freeAttributes(allocator: Allocator, attributes: []const ports.ObservationAttribute) void {
        for (attributes) |attribute| {
            allocator.free(attribute.key);
            allocator.free(attribute.value);
        }
        allocator.free(attributes);
    }

    /// Compares events by the fields that affect behavior.
    fn eventsEqual(expected: ports.ObservationEvent, actual: ports.ObservationEvent) bool {
        return std.mem.eql(u8, expected.name, actual.name) and
            std.mem.eql(u8, expected.phase, actual.phase) and
            expected.duration_ms == actual.duration_ms and
            attributesEqual(expected.attributes, actual.attributes);
    }

    /// Compares attributes by the fields that affect behavior.
    fn attributesEqual(expected: []const ports.ObservationAttribute, actual: []const ports.ObservationAttribute) bool {
        if (expected.len != actual.len) return false;
        for (expected, actual) |expected_attribute, actual_attribute| {
            if (!std.mem.eql(u8, expected_attribute.key, actual_attribute.key)) return false;
            if (!std.mem.eql(u8, expected_attribute.value, actual_attribute.value)) return false;
        }
        return true;
    }
};

test "observability sink records expected events" {
    var fake = FakeObservabilitySink.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectEvent(.{
        .name = "profile.run",
        .phase = "complete",
        .attributes = &.{
            .{ .key = "backend", .value = "zflame" },
            .{ .key = "status", .value = "ok" },
        },
        .duration_ms = 14,
    });

    try fake.port().emit(.{
        .name = "profile.run",
        .phase = "complete",
        .attributes = &.{
            .{ .key = "backend", .value = "zflame" },
            .{ .key = "status", .value = "ok" },
        },
        .duration_ms = 14,
    });

    try std.testing.expectEqual(@as(usize, 1), fake.events().len);
    try std.testing.expectEqualStrings("profile.run", fake.events()[0].name);
    try fake.verify();
}

test "observability sink rejects stale expected events" {
    var fake = FakeObservabilitySink.init(std.testing.allocator);
    defer fake.deinit();

    try fake.expectEvent(.{
        .name = "profile.run",
        .phase = "complete",
        .attributes = &.{.{ .key = "status", .value = "ok" }},
    });

    try std.testing.expectError(error.StaleArguments, fake.port().emit(.{
        .name = "profile.run",
        .phase = "complete",
        .attributes = &.{.{ .key = "status", .value = "failed" }},
    }));
    try std.testing.expectEqual(@as(usize, 1), fake.events().len);
    try std.testing.expectError(error.MissingExpectedCall, fake.verify());
}

test "observability sink fails unexpected events" {
    var fake = FakeObservabilitySink.init(std.testing.allocator);
    defer fake.deinit();

    try std.testing.expectError(error.UnexpectedCall, fake.port().emit(.{
        .name = "profile.run",
        .phase = "complete",
    }));
}

test "observability sink event cloning cleans partial allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expectObservabilityEventWithAllocator, .{});
}

/// Records an expected observability event with allocator call, cloning request data and failing on allocation errors.
fn expectObservabilityEventWithAllocator(allocator: Allocator) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var fake = FakeObservabilitySink.init(allocator);
    defer fake.deinit();

    try fake.expectEvent(.{
        .name = "profile.run",
        .phase = "complete",
        .attributes = &.{
            .{ .key = "backend", .value = "zflame" },
            .{ .key = "status", .value = "ok" },
        },
        .duration_ms = 14,
    });
}
