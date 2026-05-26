const std = @import("std");

const flamegraph = @import("flamegraph.zig");

test "zflame argv uses explicit formats and upstream option syntax" {
    var argv = try flamegraph.buildZflameArgv(std.testing.allocator, .{
        .executable = "zflame",
        .format = .recursive,
        .input = "/workspace/stacks.folded",
        .options = .{
            .title = "profile",
            .subtitle = "fixture",
            .colors = "hot",
            .width = 1200,
            .min_width = 5,
            .hash = true,
        },
    });
    defer argv.deinit(std.testing.allocator);
    const expected = [_][]const u8{ "zflame", "recursive", "--title=profile", "--subtitle=fixture", "--colors=hot", "--width=1200", "--min-width=5", "--hash", "/workspace/stacks.folded" };
    try std.testing.expectEqual(expected.len, argv.argv.items.len);
    for (expected, argv.argv.items) |expected_arg, actual_arg| try std.testing.expectEqualStrings(expected_arg, actual_arg);
}

test "zflame argv covers every advertised input format without guessing" {
    for (flamegraph.zflame_format_names) |name| {
        const format = flamegraph.parseZflameFormat(name) orelse return error.MissingFormat;
        var argv = try flamegraph.buildZflameArgv(std.testing.allocator, .{
            .executable = "zflame",
            .format = format,
            .input = "/workspace/input.profile",
        });
        defer argv.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("zflame", argv.argv.items[0]);
        try std.testing.expectEqualStrings(format.name(), argv.argv.items[1]);
        try std.testing.expectEqualStrings("/workspace/input.profile", argv.argv.items[2]);
    }
    try std.testing.expect(flamegraph.parseZflameFormat("guess") == null);
}

test "diff-folded argv writes explicit output file" {
    var argv = try flamegraph.buildDiffFoldedArgv(std.testing.allocator, .{
        .executable = "diff-folded",
        .output = "/workspace/.zigar-cache/profile/diff-0.folded",
        .before = "/workspace/before.folded",
        .after = "/workspace/after.folded",
    });
    defer argv.deinit(std.testing.allocator);
    const expected = [_][]const u8{ "diff-folded", "--output=/workspace/.zigar-cache/profile/diff-0.folded", "/workspace/before.folded", "/workspace/after.folded" };
    try std.testing.expectEqual(expected.len, argv.argv.items.len);
    for (expected, argv.argv.items) |expected_arg, actual_arg| try std.testing.expectEqualStrings(expected_arg, actual_arg);
}

test "svg validation catches empty and non-svg backend output" {
    try std.testing.expect(flamegraph.looksLikeSvg("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"));
    try std.testing.expect(flamegraph.looksLikeSvg("<?xml version=\"1.0\"?><svg></svg>"));
    try std.testing.expect(!flamegraph.looksLikeSvg(""));
    try std.testing.expect(!flamegraph.looksLikeSvg("main;folded 1\n"));
}
