const std = @import("std");

pub const capture_semantics = "zigar does not execute or define profiler capture semantics; external profilers own sampling, permissions, symbols, privilege requirements, and output fidelity.";

pub const zflame_argv_shape = "zflame <format> [--title=<text>] [--subtitle=<text>] [--colors=<palette>] [--width=<px>] [--min-width=<px>] [--hash] <workspace-input>";
pub const zflame_compatibility_baseline = "zflame CLI with explicit format subcommand, --title=, --subtitle=, --colors=, --width=, --min-width=, --hash, and SVG on stdout";

pub const ZflameFormat = enum {
    perf,
    dtrace,
    sample,
    vtune,
    xctrace,
    recursive,

    pub fn name(self: ZflameFormat) []const u8 {
        return @tagName(self);
    }
};

pub const zflame_format_names = [_][]const u8{
    "perf",
    "dtrace",
    "sample",
    "vtune",
    "xctrace",
    "recursive",
};

pub fn parseZflameFormat(raw: []const u8) ?ZflameFormat {
    inline for (std.meta.tags(ZflameFormat)) |tag| {
        if (std.mem.eql(u8, raw, @tagName(tag))) return tag;
    }
    return null;
}

pub fn supportedZflameFormatsText() []const u8 {
    return "perf, dtrace, sample, vtune, xctrace, recursive";
}

pub const ZflameOption = enum {
    title,
    subtitle,
    colors,
    width,
    min_width,

    pub fn fieldName(self: ZflameOption) []const u8 {
        return switch (self) {
            .title => "title",
            .subtitle => "subtitle",
            .colors => "colors",
            .width => "width",
            .min_width => "min_width",
        };
    }

    pub fn flagPrefix(self: ZflameOption) []const u8 {
        return switch (self) {
            .title => "--title=",
            .subtitle => "--subtitle=",
            .colors => "--colors=",
            .width => "--width=",
            .min_width => "--min-width=",
        };
    }
};

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
    format: ZflameFormat,
    input: []const u8,
    options: ZflameRenderOptions = .{},
};

pub const BuiltArgv = struct {
    argv: std.ArrayList([]const u8) = .empty,
    owned_args: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *BuiltArgv, allocator: std.mem.Allocator) void {
        for (self.owned_args.items) |arg| allocator.free(arg);
        self.owned_args.deinit(allocator);
        self.argv.deinit(allocator);
    }

    pub fn appendOwned(self: *BuiltArgv, allocator: std.mem.Allocator, arg: []const u8) !void {
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

pub fn looksLikeSvg(bytes: []const u8) bool {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "<svg")) return true;
    return std.mem.startsWith(u8, trimmed, "<?xml") and std.mem.indexOf(u8, trimmed, "<svg") != null;
}

fn appendZflameStringOption(allocator: std.mem.Allocator, built: *BuiltArgv, option: ZflameOption, value: ?[]const u8) !void {
    if (value) |text| try built.appendOwned(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ option.flagPrefix(), text }));
}

fn appendZflameIntOption(allocator: std.mem.Allocator, built: *BuiltArgv, option: ZflameOption, value: ?i64) !void {
    if (value) |number| try built.appendOwned(allocator, try std.fmt.allocPrint(allocator, "{s}{d}", .{ option.flagPrefix(), number }));
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
    for (zflame_format_names) |name| {
        const format = parseZflameFormat(name) orelse return error.MissingFormat;
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

test "svg validation catches empty and non-svg backend output" {
    try std.testing.expect(looksLikeSvg("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"));
    try std.testing.expect(looksLikeSvg("<?xml version=\"1.0\"?><svg></svg>"));
    try std.testing.expect(!looksLikeSvg(""));
    try std.testing.expect(!looksLikeSvg("main;folded 1\n"));
}
