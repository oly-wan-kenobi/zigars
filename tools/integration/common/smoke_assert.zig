//! Shared assertion and filesystem-gating helpers for the smoke suite.
//! All diagnostic output goes to stderr; stdout is reserved for MCP JSON-RPC.
//! Callers own any memory they pass in; this module never holds references
//! beyond the current call frame.

const std = @import("std");

const Io = std.Io;
const JsonValue = std.json.Value;

/// Resolves `path` to an absolute path using the process working directory when
/// relative. The returned slice is allocated by `allocator` and must be freed
/// by the caller.
pub fn absolutePath(allocator: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.resolve(allocator, &.{ cwd_buf[0..cwd_len], path });
}

/// Searches a `tools/list` JSON array for the entry whose `name` field equals
/// `name`. Returns `null` when not found, so callers can distinguish "missing"
/// from assertion failure without a separate error path.
pub fn findTool(tools: []JsonValue, name: []const u8) ?JsonValue {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.object.get("name").?.string, name)) return tool;
    }
    return null;
}

/// Asserts that `actual` equals `expected` for string, bool, and integer
/// variants. On mismatch the failing path and expected value are written to
/// stderr before returning `error.AssertionFailed`. The `else` branch returns
/// `error.UnsupportedExpectation` so fixture authors get an explicit signal
/// rather than a silent pass.
pub fn expectJsonEq(io: Io, actual: JsonValue, expected: JsonValue, path: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    switch (expected) {
        .string => |s| if (actual != .string or !std.mem.eql(u8, actual.string, s)) {
            try stderrPrint(io, "assertion failed at {s}: expected string {s}\n", .{ path, s });
            return error.AssertionFailed;
        },
        .bool => |b| if (actual != .bool or actual.bool != b) {
            try stderrPrint(io, "assertion failed at {s}: expected bool {}\n", .{ path, b });
            return error.AssertionFailed;
        },
        .integer => |n| if (actual != .integer or actual.integer != n) {
            try stderrPrint(io, "assertion failed at {s}: expected integer {d}\n", .{ path, n });
            return error.AssertionFailed;
        },
        else => return error.UnsupportedExpectation,
    }
}

/// Asserts a workspace-relative path does not exist on disk. Used to verify that
/// a blocked or sandbox-rejected apply leaves nothing behind (MEDIUM-5): the HTTP
/// server's workspace is the process cwd, so the same relative path the tool was
/// asked to write is checked here against the real filesystem rather than relying
/// on the tool's self-reported `applied:false`.
pub fn expectFileAbsent(io: Io, rel: []const u8) !void {
    Io.Dir.cwd().access(io, rel, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try stderrPrint(io, "expected no file written at {s}, but it exists on disk\n", .{rel});
    return error.AssertionFailed;
}

/// Asserts exact byte equality between `actual` and `expected`. `label` is
/// printed on failure to locate the scenario in fixture output.
pub fn expectStringEq(io: Io, actual: []const u8, expected: []const u8, label: []const u8) !void {
    if (!std.mem.eql(u8, actual, expected)) {
        try stderrPrint(io, "{s}: expected `{s}`, got `{s}`\n", .{ label, expected, actual });
        return error.AssertionFailed;
    }
}

/// Fails with `error.AssertionFailed` when `actual` is below the minimum
/// `expected` count, printing `label` and both values to stderr. Used to
/// enforce that coverage thresholds are met across fixture runs.
pub fn assertMinimumCount(io: Io, label: []const u8, actual: usize, expected: usize) !void {
    if (actual >= expected) return;
    try stderrPrint(io, "{s}: expected at least {d}, got {d}\n", .{ label, expected, actual });
    return error.AssertionFailed;
}

/// Writes a formatted diagnostic line to stderr. All fixture assertion helpers
/// funnel failures through this so stderr output stays consistent and stdout
/// remains reserved for MCP JSON-RPC traffic.
pub fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "findTool locates JSON tool entries by name" {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "name", .{ .string = "zig_check" });
    var tools = [_]JsonValue{.{ .object = obj }};
    try std.testing.expect(findTool(&tools, "zig_check") != null);
    try std.testing.expect(findTool(&tools, "zig_missing") == null);
}
