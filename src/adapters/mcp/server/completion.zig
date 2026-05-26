//! Implements completions/complete by deriving argument suggestions from registered prompts/resources.
const std = @import("std");
const mcp = @import("mcp");

const jsonrpc = mcp.jsonrpc;

/// Handles completions/complete and returns up to 100 prefix-matched values.
pub fn handle(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    var response_arena = std.heap.ArenaAllocator.init(allocator);
    defer response_arena.deinit();
    const response_allocator = response_arena.allocator();

    var ref_type: []const u8 = "";
    var arg_name: []const u8 = "";
    var prefix: []const u8 = "";
    if (request.params) |params| {
        if (params == .object) {
            if (params.object.get("ref")) |ref| {
                if (ref == .object) {
                    if (ref.object.get("type")) |t| {
                        if (t == .string) ref_type = t.string;
                    }
                }
            }
            if (params.object.get("argument")) |argument| {
                if (argument == .object) {
                    if (argument.object.get("name")) |name| {
                        if (name == .string) arg_name = name.string;
                    }
                    if (argument.object.get("value")) |value| {
                        if (value == .string) prefix = value.string;
                    }
                }
            }
        }
    }

    var values_array: std.json.Array = .init(response_allocator);
    if (std.mem.eql(u8, ref_type, "ref/prompt")) {
        var iter = server.prompts.iterator();
        while (iter.next()) |entry| try appendValue(&values_array, prefix, entry.value_ptr.name);
    } else if (std.mem.eql(u8, ref_type, "ref/resource")) {
        var iter = server.resources.iterator();
        while (iter.next()) |entry| try appendValue(&values_array, prefix, entry.value_ptr.uri);
        for (resource_templates) |value| try appendValue(&values_array, prefix, value);
    } else if (std.mem.eql(u8, arg_name, "command")) {
        for (commands) |value| try appendValue(&values_array, prefix, value);
    } else if (std.mem.eql(u8, arg_name, "client")) {
        for (clients) |value| try appendValue(&values_array, prefix, value);
    } else if (std.mem.eql(u8, arg_name, "workflow")) {
        for (workflows) |value| try appendValue(&values_array, prefix, value);
    } else {
        var prompt_iter = server.prompts.iterator();
        while (prompt_iter.next()) |entry| try appendValue(&values_array, prefix, entry.value_ptr.name);
        var resource_iter = server.resources.iterator();
        while (resource_iter.next()) |entry| try appendValue(&values_array, prefix, entry.value_ptr.uri);
    }

    var completion: std.json.ObjectMap = .empty;
    try completion.put(response_allocator, "values", .{ .array = values_array });
    try completion.put(response_allocator, "total", .{ .integer = @intCast(values_array.items.len) });
    try completion.put(response_allocator, "hasMore", .{ .bool = false });

    var result: std.json.ObjectMap = .empty;
    try result.put(response_allocator, "completion", .{ .object = completion });
    const response = jsonrpc.createResponse(request.id, .{ .object = result });
    try server.sendResponse(io, allocator, .{ .response = response });
}

/// Appends a suggestion when it matches the prefix and result cap.
fn appendValue(values: *std.json.Array, prefix: []const u8, value: []const u8) !void {
    if (prefix.len > 0 and !std.mem.startsWith(u8, value, prefix)) return;
    if (values.items.len >= 100) return;
    try values.append(.{ .string = value });
}

/// Command argument suggestions for runtime job tools.
const commands = [_][]const u8{ "build", "build-test", "test", "check", "fmt-check" };
/// Client argument suggestions for guide/prompt tools.
const clients = [_][]const u8{ "codex", "claude", "gemini", "generic" };
/// Dynamic resource URI templates surfaced to completion clients.
const resource_templates = [_][]const u8{ "zigar://jobs", "zigar://run/events", "zigar://workspace/roots", "zigar://file/{path}/symbols", "zigar://file/{path}/diagnostics", "zigar://file/{path}/imports" };
/// Workflow prompt suggestions exposed through workflow arguments.
const workflows = [_][]const u8{ "zigar_compile_error_workflow", "zigar_test_workflow", "zigar_refactor_workflow", "zigar_api_change_workflow", "zigar_release_workflow", "zigar_perf_workflow" };
