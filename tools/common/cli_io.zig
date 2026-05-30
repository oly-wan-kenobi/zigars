//! Shared CLI I/O helpers for repository tooling.
//!
//! Tool helpers use stderr for diagnostics and reserve stdout for explicit
//! machine-readable command output.
const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

/// Prints a formatted error to stderr, optionally followed by a usage line,
/// then returns `error.InvalidArguments`. The `usage_hint` is omitted when
/// empty. Callers propagate the returned error; they do not return a separate
/// diagnostic because this function already emits one.
pub fn failUsage(
    io: Io,
    command: []const u8,
    usage_hint: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) anyerror {
    stderrPrint(io, "zigars-tools {s}: ", .{command}) catch |err| return err;
    stderrPrint(io, fmt ++ "\n", args) catch |err| return err;
    if (usage_hint.len > 0) {
        stderrPrint(io, "usage: zigars-tools {s}\n", .{usage_hint}) catch |err| return err;
    }
    return error.InvalidArguments;
}

/// Specialization of `failUsage` for a flag that requires a following value
/// but received none (e.g. `--out-dir` with no next argument).
pub fn missingFlagValue(io: Io, command: []const u8, flag: []const u8, usage_hint: []const u8) anyerror {
    return failUsage(io, command, usage_hint, "missing value for {s}", .{flag});
}

/// Specialization of `failUsage` for an argument token that was not expected
/// by the calling command.
pub fn unexpectedArgument(io: Io, command: []const u8, arg: []const u8, usage_hint: []const u8) anyerror {
    return failUsage(io, command, usage_hint, "unexpected argument `{s}`", .{arg});
}

/// Advances `index` and returns the next argument as the value for `flag`.
/// Returns `missingFlagValue` when the slice is exhausted. Callers pass a
/// mutable index so flag scanning loops do not need a separate peek.
pub fn flagValue(
    args: []const []const u8,
    index: *usize,
    io: Io,
    command: []const u8,
    flag: []const u8,
    usage_hint: []const u8,
) anyerror![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return missingFlagValue(io, command, flag, usage_hint);
    return args[index.*];
}

/// If `err` is `error.InvalidArguments`, emits a usage diagnostic to stderr
/// and re-returns `err`. For all other errors the function returns `err`
/// unchanged, preserving the original error identity for the caller.
/// Use this at the top of `main` to add a usage hint without duplicating the
/// error message inside each sub-command.
pub fn reportInvalidArguments(
    io: Io,
    command: []const u8,
    usage_hint: []const u8,
    err: anyerror,
) anyerror {
    if (err == error.InvalidArguments) {
        stderrPrint(io, "zigars-tools {s}: invalid arguments\n", .{command}) catch |print_err| return print_err;
        if (usage_hint.len > 0) {
            stderrPrint(io, "usage: zigars-tools {s}\n", .{usage_hint}) catch |print_err| return print_err;
        }
    }
    return err;
}

/// Writes `bytes` verbatim to stdout. Stdout is reserved for MCP JSON-RPC and
/// machine-readable output; all diagnostics must use `stderrPrint` instead.
pub fn stdoutWrite(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

/// Formats and writes a diagnostic message to stderr using a 4 KiB stack buffer.
/// Flushes immediately so each message appears even if the process exits after.
pub fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

/// Returns the basename of `path`, stripping a `.exe` suffix on Windows so
/// callers get a consistent `"zigars-tools"` regardless of platform.
pub fn executableName(path: []const u8) []const u8 {
    var name = std.fs.path.basename(path);
    if (builtin.os.tag == .windows and std.mem.endsWith(u8, name, ".exe")) {
        name = name[0 .. name.len - 4];
    }
    return name;
}

/// Reads `path` into a caller-owned heap slice. `limit` caps the allocation;
/// returns an error (e.g. `error.FileTooBig`) when the file exceeds it.
/// The caller is responsible for freeing the returned slice.
pub fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, limit: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

/// Atomically-ish replaces or creates `path` with `bytes` relative to cwd.
pub fn writeFile(io: Io, path: []const u8, bytes: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// Serializes `value` to a heap-allocated JSON string with the given options.
/// The caller owns the returned slice and must free it.
pub fn jsonStringifyAlloc(allocator: Allocator, value: JsonValue, options: std.json.Stringify.Options) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try std.json.Stringify.value(value, options, &aw.writer);
    return try aw.toOwnedSlice();
}

/// Reads and parses `path` as JSON (up to 16 MiB). The returned `Parsed`
/// value owns its arena; call `.deinit()` to release it.
pub fn parseJsonFile(allocator: Allocator, io: Io, path: []const u8) !std.json.Parsed(JsonValue) {
    const bytes = try readFileAlloc(allocator, io, path, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    return try std.json.parseFromSlice(JsonValue, allocator, bytes, .{});
}

test "executableName strips directories and platform suffix" {
    try std.testing.expectEqualStrings("zigars-tools", executableName("/tmp/zigars-tools"));
}
