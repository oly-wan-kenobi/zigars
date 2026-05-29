const std = @import("std");

const ports = @import("../../app/ports.zig");

/// Tool manifest catalog fake backed by a caller-provided entry slice.
///
/// Defaults to an empty catalog so app tests that only need to satisfy the
/// `ToolManifestCatalog` context field (without exercising manifest lookups)
/// can construct one with `.{}`. Entries are borrowed for the fake's lifetime.
pub const FakeToolManifestCatalog = struct {
    entries: []const ports.ToolManifestEntry = &.{},

    /// Borrows `entries` for the lifetime of the fake.
    pub fn init(entries: []const ports.ToolManifestEntry) FakeToolManifestCatalog {
        return .{ .entries = entries };
    }

    /// Exposes this implementation through its application port vtable.
    pub fn port(self: *FakeToolManifestCatalog) ports.ToolManifestCatalog {
        return .{
            .ptr = self,
            .vtable = &.{
                .count = count,
                .entry_at = entryAt,
                .find = find,
            },
        };
    }

    /// Returns the number of configured entries.
    fn count(ptr: *anyopaque) usize {
        return self_(ptr).entries.len;
    }

    /// Returns the configured entry at the index, or null when out of range.
    fn entryAt(ptr: *anyopaque, index: usize) ?ports.ToolManifestEntry {
        const self = self_(ptr);
        if (index >= self.entries.len) return null;
        return self.entries[index];
    }

    /// Finds a configured entry by tool name, or null when absent.
    fn find(ptr: *anyopaque, name: []const u8) ?ports.ToolManifestEntry {
        for (self_(ptr).entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    fn self_(ptr: *anyopaque) *FakeToolManifestCatalog {
        return @ptrCast(@alignCast(ptr));
    }
};

test "fake tool manifest catalog defaults to empty" {
    var fake = FakeToolManifestCatalog{};
    const catalog = fake.port();
    try std.testing.expectEqual(@as(usize, 0), catalog.count());
    try std.testing.expect(catalog.entryAt(0) == null);
    try std.testing.expect(catalog.find("zig_build") == null);
}

test "fake tool manifest catalog exposes configured entries" {
    const entries = [_]ports.ToolManifestEntry{
        .{ .name = "zig_build", .group = "build" },
        .{ .name = "zig_test", .group = "build" },
    };
    var fake = FakeToolManifestCatalog.init(entries[0..]);
    const catalog = fake.port();
    try std.testing.expectEqual(@as(usize, 2), catalog.count());
    try std.testing.expectEqualStrings("zig_build", catalog.entryAt(0).?.name);
    try std.testing.expectEqualStrings("zig_test", catalog.find("zig_test").?.name);
    try std.testing.expect(catalog.find("absent") == null);
}
