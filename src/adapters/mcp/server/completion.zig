//! Implements completions/complete by deriving argument suggestions from registered prompts/resources.
const std = @import("std");
const mcp = @import("mcp");

const jsonrpc = mcp.jsonrpc;
const manifest = @import("../../../manifest/mod.zig");
const tooling = manifest.tooling;

/// MCP caps a completion response at 100 values; surplus matches are counted in
/// `total` and flagged via `hasMore` rather than returned.
const completion_cap = 100;

/// Bounded, de-duplicating accumulator of prefix-matched completion candidates.
/// Tracks the full match `total` even past `completion_cap` so the response can
/// report `hasMore` accurately.
const CompletionSet = struct {
    allocator: std.mem.Allocator,
    values: std.json.Array,
    seen: std.StringHashMap(void),
    total: usize = 0,
    has_more: bool = false,

    /// Initializes a bounded completion accumulator.
    fn init(allocator: std.mem.Allocator) CompletionSet {
        return .{ .allocator = allocator, .values = .init(allocator), .seen = std.StringHashMap(void).init(allocator) };
    }

    /// Releases accumulator bookkeeping. Response values are owned by the response arena.
    fn deinit(self: *CompletionSet) void {
        self.seen.deinit();
    }

    /// Appends a unique prefix-matched candidate or records that more values exist.
    fn append(self: *CompletionSet, prefix: []const u8, value: []const u8) !void {
        // Append in deterministic order so completion and snapshot output remain stable.
        if (prefix.len > 0 and !std.mem.startsWith(u8, value, prefix)) return;
        if (self.seen.contains(value)) return;
        try self.seen.put(value, {});
        self.total += 1;
        if (self.values.items.len >= completion_cap) {
            self.has_more = true;
            return;
        }
        try self.values.append(.{ .string = value });
    }
};

/// Handles completions/complete and returns up to 100 prefix-matched values.
pub fn handle(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    var response_arena = std.heap.ArenaAllocator.init(allocator);
    defer response_arena.deinit();
    const response_allocator = response_arena.allocator();

    var ref_type: []const u8 = "";
    var ref_name: []const u8 = "";
    var arg_name: []const u8 = "";
    var prefix: []const u8 = "";
    if (request.params) |params| {
        if (params == .object) {
            if (params.object.get("ref")) |ref| {
                if (ref == .object) {
                    if (ref.object.get("type")) |t| {
                        if (t == .string) ref_type = t.string;
                    }
                    if (ref.object.get("name")) |n| {
                        if (n == .string) ref_name = n.string;
                    } else if (ref.object.get("id")) |id| {
                        if (id == .string) ref_name = id.string;
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

    // Dispatch by completion reference: a prompt ref completes prompt names, a
    // resource ref completes resource/template URIs, otherwise try manifest tool
    // argument hints keyed by (tool, arg). If none of those apply, fall back to
    // the union of prompt names and resource URIs.
    var completions = CompletionSet.init(response_allocator);
    defer completions.deinit();
    if (std.mem.eql(u8, ref_type, "ref/prompt")) {
        var iter = server.prompts.iterator();
        while (iter.next()) |entry| try completions.append(prefix, entry.value_ptr.name);
    } else if (std.mem.eql(u8, ref_type, "ref/resource")) {
        try appendResourceUris(server, &completions, prefix);
    } else if (arg_name.len > 0 and try appendManifestArgumentCompletions(server, &completions, ref_name, arg_name, prefix)) {
        // Manifest-backed enum or dynamic argument completions handled the request.
    } else {
        var prompt_iter = server.prompts.iterator();
        while (prompt_iter.next()) |entry| try completions.append(prefix, entry.value_ptr.name);
        try appendResourceUris(server, &completions, prefix);
    }

    var completion: std.json.ObjectMap = .empty;
    try completion.put(response_allocator, "values", .{ .array = completions.values });
    try completion.put(response_allocator, "total", .{ .integer = @intCast(completions.total) });
    try completion.put(response_allocator, "hasMore", .{ .bool = completions.has_more });

    var result: std.json.ObjectMap = .empty;
    try result.put(response_allocator, "completion", .{ .object = completion });
    const response = jsonrpc.createResponse(request.id, .{ .object = result });
    try server.sendResponse(io, allocator, .{ .response = response });
}

/// Appends argument completions derived from manifest field hints, returning
/// whether any spec supplied candidates. With a known `tool_name` only that
/// spec is consulted; with an empty name every spec is scanned so an
/// untargeted completion can still surface matching enum/dynamic values.
fn appendManifestArgumentCompletions(server: anytype, completions: *CompletionSet, tool_name: []const u8, arg_name: []const u8, prefix: []const u8) !bool {
    // Append in deterministic order so completion and snapshot output remain stable.
    var handled = false;
    if (tool_name.len > 0) {
        if (manifest.find(tool_name)) |spec| {
            handled = try appendSpecArgumentCompletions(server, completions, spec, arg_name, prefix);
        }
        return handled;
    }

    for (manifest.specs) |spec| {
        handled = (try appendSpecArgumentCompletions(server, completions, spec, arg_name, prefix)) or handled;
    }
    return handled;
}

/// Appends one tool spec's manifest-backed argument completions.
fn appendSpecArgumentCompletions(server: anytype, completions: *CompletionSet, spec: manifest.ToolMeta, arg_name: []const u8, prefix: []const u8) !bool {
    // Append in deterministic order so completion and snapshot output remain stable.
    for (spec.input_schema.fields) |field| {
        if (!std.mem.eql(u8, field[0], arg_name)) continue;
        const hint = tooling.hintFor(spec.input_schema, field);
        var handled = false;
        for (hint.enum_values) |value| {
            try completions.append(prefix, value);
            handled = true;
        }
        if (hint.completion_source) |source| {
            switch (source) {
                .resource_uri => try appendResourceUris(server, completions, prefix),
            }
            handled = true;
        }
        return handled;
    }
    return false;
}

/// Appends registered resources and resource templates from live server state.
fn appendResourceUris(server: anytype, completions: *CompletionSet, prefix: []const u8) !void {
    var iter = server.resources.iterator();
    while (iter.next()) |entry| try completions.append(prefix, entry.value_ptr.uri);
    var template_iter = server.resource_templates.iterator();
    while (template_iter.next()) |entry| try completions.append(prefix, entry.value_ptr.uriTemplate);
}

test "completion set tracks total matches beyond response cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var completions = CompletionSet.init(allocator);
    defer completions.deinit();

    for (0..completion_cap + 5) |index| {
        const value = try std.fmt.allocPrint(allocator, "item-{d}", .{index});
        try completions.append("item-", value);
    }

    try std.testing.expectEqual(@as(usize, completion_cap), completions.values.items.len);
    try std.testing.expectEqual(@as(usize, completion_cap + 5), completions.total);
    try std.testing.expect(completions.has_more);

    try completions.append("item-", "item-0");
    try completions.append("other-", "item-999");
    try std.testing.expectEqual(@as(usize, completion_cap + 5), completions.total);
}
