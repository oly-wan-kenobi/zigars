const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

pub fn failUsage(
    io: Io,
    command: []const u8,
    usage_hint: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) error{InvalidArguments} {
    stderrPrint(io, "zigar-tools {s}: ", .{command}) catch {};
    stderrPrint(io, fmt ++ "\n", args) catch {};
    if (usage_hint.len > 0) {
        stderrPrint(io, "usage: zigar-tools {s}\n", .{usage_hint}) catch {};
    }
    return error.InvalidArguments;
}

pub fn missingFlagValue(io: Io, command: []const u8, flag: []const u8, usage_hint: []const u8) error{InvalidArguments} {
    return failUsage(io, command, usage_hint, "missing value for {s}", .{flag});
}

pub fn unexpectedArgument(io: Io, command: []const u8, arg: []const u8, usage_hint: []const u8) error{InvalidArguments} {
    return failUsage(io, command, usage_hint, "unexpected argument `{s}`", .{arg});
}

pub fn flagValue(
    args: []const []const u8,
    index: *usize,
    io: Io,
    command: []const u8,
    flag: []const u8,
    usage_hint: []const u8,
) error{InvalidArguments}![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return missingFlagValue(io, command, flag, usage_hint);
    return args[index.*];
}

pub fn reportInvalidArguments(
    io: Io,
    command: []const u8,
    usage_hint: []const u8,
    err: anyerror,
) anyerror {
    if (err == error.InvalidArguments) {
        stderrPrint(io, "zigar-tools {s}: invalid arguments\n", .{command}) catch {};
        if (usage_hint.len > 0) {
            stderrPrint(io, "usage: zigar-tools {s}\n", .{usage_hint}) catch {};
        }
    }
    return err;
}

pub fn stdoutWrite(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

pub fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

pub fn executableName(path: []const u8) []const u8 {
    var name = std.fs.path.basename(path);
    if (builtin.os.tag == .windows and std.mem.endsWith(u8, name, ".exe")) {
        name = name[0 .. name.len - 4];
    }
    return name;
}

pub fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, limit: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

pub fn writeFile(io: Io, path: []const u8, bytes: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

pub fn jsonStringifyAlloc(allocator: Allocator, value: JsonValue, options: std.json.Stringify.Options) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try std.json.Stringify.value(value, options, &aw.writer);
    return try aw.toOwnedSlice();
}

pub fn parseJsonFile(allocator: Allocator, io: Io, path: []const u8) !std.json.Parsed(JsonValue) {
    const bytes = try readFileAlloc(allocator, io, path, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    return try std.json.parseFromSlice(JsonValue, allocator, bytes, .{});
}
