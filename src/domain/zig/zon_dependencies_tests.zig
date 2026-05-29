const std = @import("std");

const zon = @import("zon_dependencies.zig");

const manifest =
    \\.{
    \\    .name = .fixture,
    \\    .version = "0.1.0",
    \\    .dependencies = .{
    \\        .alpha = .{
    \\            .url = "https://example.invalid/alpha.tar.gz",
    \\            .hash = "oldhash",
    \\        },
    \\        .beta = .{ .path = "vendor/beta" },
    \\        .@"gamma-dash" = .{ .url = "https://example.invalid/gamma.tar.gz" },
    \\    },
    \\}
    \\
;

test "zon dependency model parses URL path and quoted names" {
    var model = try zon.parse(std.testing.allocator, manifest);
    defer model.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), model.entries.len);
    try std.testing.expectEqual(@as(usize, 0), model.diagnostics.len);
    const alpha = model.find("alpha").?;
    try std.testing.expectEqualStrings("url", alpha.kind());
    try std.testing.expectEqualStrings("https://example.invalid/alpha.tar.gz", alpha.url.?.value);
    try std.testing.expectEqualStrings("oldhash", alpha.hash.?.value);
    try std.testing.expectEqualStrings("vendor/beta", model.find("beta").?.path.?.value);
    try std.testing.expect(model.find("gamma-dash") != null);
}

test "zon dependency hash replacement preserves surrounding manifest" {
    var model = try zon.parse(std.testing.allocator, manifest);
    defer model.deinit(std.testing.allocator);

    const updated = try zon.replaceHash(std.testing.allocator, model, "alpha", "newhash");
    defer std.testing.allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, ".hash = \"newhash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, ".beta = .{ .path = \"vendor/beta\" }") != null);
}

test "zon dependency add remove and upgrade are minimal text edits" {
    var model = try zon.parse(std.testing.allocator, manifest);
    defer model.deinit(std.testing.allocator);

    const added = try zon.addDependency(std.testing.allocator, model, "delta", "https://example.invalid/delta.tar.gz", "dhash", null);
    defer std.testing.allocator.free(added);
    try std.testing.expect(std.mem.indexOf(u8, added, ".delta = .{ .url = \"https://example.invalid/delta.tar.gz\", .hash = \"dhash\" },") != null);

    var added_model = try zon.parse(std.testing.allocator, added);
    defer added_model.deinit(std.testing.allocator);
    const removed = try zon.removeDependency(std.testing.allocator, added_model, "beta");
    defer std.testing.allocator.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "vendor/beta") == null);

    var removed_model = try zon.parse(std.testing.allocator, removed);
    defer removed_model.deinit(std.testing.allocator);
    const upgraded = try zon.upgradeDependency(std.testing.allocator, removed_model, "alpha", "https://example.invalid/alpha-2.tar.gz", "hash2");
    defer std.testing.allocator.free(upgraded);
    try std.testing.expect(std.mem.indexOf(u8, upgraded, "alpha-2.tar.gz") != null);
    try std.testing.expect(std.mem.indexOf(u8, upgraded, ".hash = \"hash2\"") != null);
}

test "zon dependency edits reject fields that would escape generated literals" {
    var model = try zon.parse(std.testing.allocator, manifest);
    defer model.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidDependencyField, zon.addDependency(std.testing.allocator, model, "bad-name", "https://example.invalid/delta.tar.gz", "dhash", null));
    try std.testing.expectError(error.InvalidDependencyField, zon.addDependency(std.testing.allocator, model, "delta", "https://example.invalid/\"}, .evil = .{ .path = \"x", "dhash", null));
    try std.testing.expectError(error.InvalidDependencyField, zon.addDependency(std.testing.allocator, model, "delta", "https://example.invalid/delta.tar.gz", "bad\nhash", null));
    try std.testing.expectError(error.InvalidDependencyField, zon.addDependency(std.testing.allocator, model, "local", null, null, "vendor\\beta"));
    try std.testing.expectError(error.InvalidDependencyField, zon.replaceHash(std.testing.allocator, model, "alpha", "hash\""));
    try std.testing.expectError(error.InvalidDependencyField, zon.upgradeDependency(std.testing.allocator, model, "alpha", "https://example.invalid/new\n.tar.gz", null));
}

test "zon dependency fields ignore lookalikes in comments and other values" {
    const commented =
        \\.{
        \\    .name = .fixture,
        \\    .dependencies = .{
        \\        .alpha = .{
        \\            // legacy mirror was .url = "https://old.invalid/alpha.tar.gz" with .hash = "DO_NOT_TOUCH"
        \\            .url = "https://example.invalid/alpha.tar.gz",
        \\            .hash = "realhash",
        \\        },
        \\    },
        \\}
        \\
    ;

    var model = try zon.parse(std.testing.allocator, commented);
    defer model.deinit(std.testing.allocator);

    // The token-aware scan must locate the real fields, not the commented lookalikes.
    const alpha = model.find("alpha").?;
    try std.testing.expectEqualStrings("https://example.invalid/alpha.tar.gz", alpha.url.?.value);
    try std.testing.expectEqualStrings("realhash", alpha.hash.?.value);

    const updated = try zon.replaceHash(std.testing.allocator, model, "alpha", "newhash");
    defer std.testing.allocator.free(updated);

    // Only the real hash field is rewritten; the comment text stays byte-for-byte intact.
    try std.testing.expect(std.mem.indexOf(u8, updated, ".hash = \"newhash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "DO_NOT_TOUCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "// legacy mirror was .url = \"https://old.invalid/alpha.tar.gz\" with .hash = \"DO_NOT_TOUCH\"") != null);
    // The URL line is untouched and the manifest still re-parses with the new hash.
    try std.testing.expect(std.mem.indexOf(u8, updated, ".url = \"https://example.invalid/alpha.tar.gz\"") != null);

    var reparsed = try zon.parse(std.testing.allocator, updated);
    defer reparsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("newhash", reparsed.find("alpha").?.hash.?.value);
}

test "zon dependency model reports unsupported or missing shapes as diagnostics" {
    var missing = try zon.parse(std.testing.allocator, ".{ .name = .fixture }\n");
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), missing.diagnostics.len);
    try std.testing.expectEqualStrings("missing_dependencies", missing.diagnostics[0].code);

    var malformed = try zon.parse(std.testing.allocator,
        \\.{
        \\    .dependencies = .{
        \\        .alpha = b.dependency("alpha", .{}),
        \\    },
        \\}
        \\
    );
    defer malformed.deinit(std.testing.allocator);
    try std.testing.expect(malformed.diagnostics.len >= 1);
    try std.testing.expectEqualStrings("unsupported_dependency_value", malformed.diagnostics[0].code);
}
