const std = @import("std");

pub const capture_semantics = "zigar does not execute or define profiler capture semantics; external profilers own sampling, permissions, symbols, privilege requirements, and output fidelity.";

pub const zflame_argv_shape = "zflame <format> [--title=<text>] [--subtitle=<text>] [--colors=<palette>] [--width=<px>] [--min-width=<px>] [--hash] <workspace-input>";
pub const zflame_compatibility_baseline = "zflame CLI with explicit format subcommand, --title=, --subtitle=, --colors=, --width=, --min-width=, --hash, and SVG on stdout";
pub const diff_folded_argv_shape = "diff-folded --output=<path> before.folded after.folded";
pub const diff_folded_compatibility_baseline = "diff-folded CLI with --output=<path> before.folded after.folded and non-empty folded-stack output";

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

    pub fn appendOwned(self: *BuiltArgv, allocator: std.mem.Allocator, arg: []const u8) !void {
        var owned_by_list = false;
        defer if (!owned_by_list) allocator.free(arg);
        try self.owned_args.append(allocator, arg);
        owned_by_list = true;
        try self.argv.append(allocator, arg);
    }
};

pub fn buildZflameArgv(allocator: std.mem.Allocator, spec: ZflameRenderSpec) !BuiltArgv {
    var built: BuiltArgv = .{};
    var built_owned = true;
    defer if (built_owned) built.deinit(allocator);
    try built.argv.appendSlice(allocator, &.{ spec.executable, spec.format.name() });
    try appendZflameStringOption(allocator, &built, .title, spec.options.title);
    try appendZflameStringOption(allocator, &built, .subtitle, spec.options.subtitle);
    try appendZflameStringOption(allocator, &built, .colors, spec.options.colors);
    try appendZflameIntOption(allocator, &built, .width, spec.options.width);
    try appendZflameIntOption(allocator, &built, .min_width, spec.options.min_width);
    if (spec.options.hash) try built.argv.append(allocator, "--hash");
    try built.argv.append(allocator, spec.input);
    built_owned = false;
    return built;
}

pub fn buildDiffFoldedArgv(allocator: std.mem.Allocator, spec: DiffFoldedSpec) !BuiltArgv {
    var built: BuiltArgv = .{};
    var built_owned = true;
    defer if (built_owned) built.deinit(allocator);
    try built.argv.append(allocator, spec.executable);
    try built.appendOwned(allocator, try std.fmt.allocPrint(allocator, "--output={s}", .{spec.output}));
    try built.argv.appendSlice(allocator, &.{ spec.before, spec.after });
    built_owned = false;
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
