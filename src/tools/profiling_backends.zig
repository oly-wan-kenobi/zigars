const std = @import("std");
const zigar = @import("zigar");

const backend_contracts = zigar.backend_contracts;
const flamegraph_model = zigar.domain.profiling.flamegraph;

pub const ZflameFormat = flamegraph_model.ZflameFormat;
pub const ZflameOption = flamegraph_model.ZflameOption;
pub const ZflameRenderOptions = flamegraph_model.ZflameRenderOptions;
pub const ZflameRenderSpec = flamegraph_model.ZflameRenderSpec;
pub const BuiltArgv = flamegraph_model.BuiltArgv;
pub const buildZflameArgv = flamegraph_model.buildZflameArgv;
pub const looksLikeSvg = flamegraph_model.looksLikeSvg;
pub const parseZflameFormat = flamegraph_model.parseZflameFormat;
pub const zflame_format_names = flamegraph_model.zflame_format_names;

pub const DiffFoldedSpec = struct {
    executable: []const u8,
    output: []const u8,
    before: []const u8,
    after: []const u8,
};

pub fn buildDiffFoldedArgv(allocator: std.mem.Allocator, spec: DiffFoldedSpec) !BuiltArgv {
    var built: BuiltArgv = .{};
    errdefer built.deinit(allocator);
    try built.argv.append(allocator, spec.executable);
    try built.appendOwned(allocator, try std.fmt.allocPrint(allocator, "--output={s}", .{spec.output}));
    try built.argv.appendSlice(allocator, &.{ spec.before, spec.after });
    return built;
}

test "zflame argv uses explicit formats and upstream option syntax" {
    var argv = try buildZflameArgv(std.testing.allocator, .{
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
    inline for (std.meta.tags(ZflameFormat)) |format| {
        var argv = try buildZflameArgv(std.testing.allocator, .{
            .executable = "zflame",
            .format = format,
            .input = "/workspace/input.profile",
        });
        defer argv.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("zflame", argv.argv.items[0]);
        try std.testing.expectEqualStrings(format.name(), argv.argv.items[1]);
        try std.testing.expectEqualStrings("/workspace/input.profile", argv.argv.items[2]);
    }
    try std.testing.expect(parseZflameFormat("guess") == null);
}

test "zflame domain format names match public backend contract schema names" {
    try std.testing.expectEqual(backend_contracts.zflame_format_names.len, zflame_format_names.len);
    for (backend_contracts.zflame_format_names, zflame_format_names) |public_name, domain_name| {
        try std.testing.expectEqualStrings(public_name, domain_name);
        try std.testing.expect(parseZflameFormat(public_name) != null);
    }
}

test "diff-folded argv writes explicit output file" {
    var argv = try buildDiffFoldedArgv(std.testing.allocator, .{
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
    try std.testing.expect(looksLikeSvg("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"));
    try std.testing.expect(looksLikeSvg("<?xml version=\"1.0\"?><svg></svg>"));
    try std.testing.expect(!looksLikeSvg(""));
    try std.testing.expect(!looksLikeSvg("main;folded 1\n"));
}
