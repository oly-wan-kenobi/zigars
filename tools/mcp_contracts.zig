const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn checkNoPatchContract(allocator: Allocator, io: Io) !bool {
    var ok = true;
    const build_files = [_][]const u8{ "build.zig", "build.zig.zon" };
    const forbidden = [_][]const u8{
        "third_party/mcp_zigar_patch",
        "mcp_upstream",
        "addMcpModule",
    };
    for (build_files) |path| {
        const bytes = readFileAlloc(allocator, io, path, 1024 * 1024) catch |err| {
            try stderrPrint(io, "MCP no-patch check could not read {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        for (forbidden) |needle| {
            if (std.mem.indexOf(u8, bytes, needle) != null) {
                try stderrPrint(io, "MCP no-patch check found `{s}` in {s}; build must use the pinned upstream mcp module directly\n", .{ needle, path });
                ok = false;
            }
        }
    }

    const adapter = readFileAlloc(allocator, io, "src/mcp_server.zig", 2 * 1024 * 1024) catch |err| {
        try stderrPrint(io, "MCP no-patch check could not read src/mcp_server.zig: {s}\n", .{@errorName(err)});
        return false;
    };
    defer allocator.free(adapter);
    const required = [_][]const u8{
        "First-party MCP server adapter",
        "pinned upstream MCP dependency",
        "ToolResultDeinit",
        "ResourceContentDeinit",
        "PromptMessagesDeinit",
        "deinit_result",
        "addResourceWithDeinit",
        "addPromptWithDeinit",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, adapter, needle) == null) {
            try stderrPrint(io, "MCP no-patch check missing `{s}` in src/mcp_server.zig\n", .{needle});
            ok = false;
        }
    }
    return ok;
}

pub fn checkAdvertisedCapabilityContract(allocator: Allocator, io: Io) !bool {
    const rules = [_]struct {
        path: []const u8,
        token: []const u8,
        reason: []const u8,
    }{
        .{
            .path = "src/main.zig",
            .token = "enableTasks(",
            .reason = "public server startup must not advertise MCP task support until zigar implements the task lifecycle",
        },
        .{
            .path = "src/mcp_server.zig",
            .token = "capabilities.tasks",
            .reason = "MCP task capabilities must not be emitted without implemented task methods",
        },
        .{
            .path = "src/mcp_server.zig",
            .token = "handleTasks",
            .reason = "stub task handlers must not remain in the public protocol surface",
        },
        .{
            .path = "docs/architecture.md",
            .token = "empty task-list",
            .reason = "architecture docs must not advertise MCP task support until zigar implements the task lifecycle",
        },
    };

    var ok = true;
    for (rules) |rule| {
        const bytes = readFileAlloc(allocator, io, rule.path, 2 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "MCP capability-contract check could not read {s}: {s}\n", .{ rule.path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, rule.token) != null) {
            try stderrPrint(io, "MCP capability-contract violation in {s}: `{s}` ({s})\n", .{ rule.path, rule.token, rule.reason });
            ok = false;
        }
    }
    return ok;
}

fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, limit: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}
