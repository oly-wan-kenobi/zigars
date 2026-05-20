const std = @import("std");
const zigar = @import("zigar");

const backend_contracts = zigar.backend_contracts;

pub const ZflameRenderOptions = struct {
    title: ?[]const u8 = null,
    subtitle: ?[]const u8 = null,
    colors: ?[]const u8 = null,
    width: ?i64 = null,
    min_width: ?i64 = null,
    hash: bool = false,
};

pub const ZflameRenderSpec = struct {
    executable: []const u8,
    format: backend_contracts.ZflameFormat,
    input: []const u8,
    options: ZflameRenderOptions = .{},
};

pub const DiffFoldedSpec = struct {
    executable: []const u8,
    output: []const u8,
    before: []const u8,
    after: []const u8,
};

pub const BuiltArgv = struct {
    argv: std.ArrayList([]const u8) = .empty,
    owned_args: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *BuiltArgv, allocator: std.mem.Allocator) void {
        for (self.owned_args.items) |arg| allocator.free(arg);
        self.owned_args.deinit(allocator);
        self.argv.deinit(allocator);
    }

    fn appendOwned(self: *BuiltArgv, allocator: std.mem.Allocator, arg: []const u8) !void {
        errdefer allocator.free(arg);
        try self.owned_args.append(allocator, arg);
        try self.argv.append(allocator, arg);
    }
};

pub fn buildZflameArgv(allocator: std.mem.Allocator, spec: ZflameRenderSpec) !BuiltArgv {
    var built: BuiltArgv = .{};
    errdefer built.deinit(allocator);
    try built.argv.appendSlice(allocator, &.{ spec.executable, spec.format.name() });
    try appendZflameStringOption(allocator, &built, .title, spec.options.title);
    try appendZflameStringOption(allocator, &built, .subtitle, spec.options.subtitle);
    try appendZflameStringOption(allocator, &built, .colors, spec.options.colors);
    try appendZflameIntOption(allocator, &built, .width, spec.options.width);
    try appendZflameIntOption(allocator, &built, .min_width, spec.options.min_width);
    if (spec.options.hash) try built.argv.append(allocator, "--hash");
    try built.argv.append(allocator, spec.input);
    return built;
}

pub fn buildDiffFoldedArgv(allocator: std.mem.Allocator, spec: DiffFoldedSpec) !BuiltArgv {
    var built: BuiltArgv = .{};
    errdefer built.deinit(allocator);
    try built.argv.append(allocator, spec.executable);
    try built.appendOwned(allocator, try std.fmt.allocPrint(allocator, "--output={s}", .{spec.output}));
    try built.argv.appendSlice(allocator, &.{ spec.before, spec.after });
    return built;
}

fn appendZflameStringOption(allocator: std.mem.Allocator, built: *BuiltArgv, option: backend_contracts.ZflameOption, value: ?[]const u8) !void {
    if (value) |text| try built.appendOwned(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ option.flagPrefix(), text }));
}

fn appendZflameIntOption(allocator: std.mem.Allocator, built: *BuiltArgv, option: backend_contracts.ZflameOption, value: ?i64) !void {
    if (value) |number| try built.appendOwned(allocator, try std.fmt.allocPrint(allocator, "{s}{d}", .{ option.flagPrefix(), number }));
}

pub fn looksLikeSvg(bytes: []const u8) bool {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "<svg")) return true;
    return std.mem.startsWith(u8, trimmed, "<?xml") and std.mem.indexOf(u8, trimmed, "<svg") != null;
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
    inline for (std.meta.tags(backend_contracts.ZflameFormat)) |format| {
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
    try std.testing.expect(backend_contracts.parseZflameFormat("guess") == null);
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
