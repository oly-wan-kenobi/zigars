const std = @import("std");
const mcp = @import("mcp");

const result_mod = @import("../../../../adapters/mcp/result.zig");

test "serializeString escapes JSON control characters" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try result_mod.serializeString(std.testing.allocator, &out, "a\"b\\c\n\r\t\x08\x0c\x1b");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u001b\"", out.items);
}

test "serializeAlloc produces parseable JSON" {
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "ok", .{ .bool = true });
    const bytes = try result_mod.serializeAlloc(std.testing.allocator, .{ .object = obj });
    defer std.testing.allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("ok").?.bool);
}

test "cloneValue owns nested strings" {
    const allocator = std.testing.allocator;
    var source_obj = std.json.ObjectMap.empty;
    defer source_obj.deinit(allocator);
    try source_obj.put(allocator, "name", .{ .string = "zigars" });
    var source_array = std.json.Array.init(allocator);
    defer source_array.deinit();
    try source_array.append(.{ .string = "fmt" });
    try source_obj.put(allocator, "keywords", .{ .array = source_array });

    const cloned = try result_mod.cloneValue(allocator, .{ .object = source_obj });
    defer result_mod.deinitOwnedValue(allocator, cloned);

    const cloned_obj = cloned.object;
    try std.testing.expectEqualStrings("zigars", cloned_obj.get("name").?.string);
    try std.testing.expectEqualStrings("fmt", cloned_obj.get("keywords").?.array.items[0].string);
}

test "cloneValue cleans up partial array clones on allocation failure" {
    var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing.deinit();
    const arena_allocator = backing.allocator();

    var source_array = std.json.Array.init(arena_allocator);
    try source_array.append(.{ .string = "first" });
    try source_array.append(.{ .string = "second" });
    try source_array.append(.{ .string = "third" });

    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing_backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer failing_backing.deinit();
        var failing = std.testing.FailingAllocator.init(failing_backing.allocator(), .{ .fail_index = fail_index });
        if (result_mod.cloneValue(failing.allocator(), .{ .array = source_array })) |cloned| {
            result_mod.deinitOwnedValue(failing.allocator(), cloned);
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

test "deinitToolResult releases nested structured result allocations" {
    const allocator = std.testing.allocator;
    var obj = std.json.ObjectMap.empty;
    try putOwnedString(allocator, &obj, "name", "zigars");
    try putOwnedNumberString(allocator, &obj, "ratio", "1.25");

    var nested = std.json.ObjectMap.empty;
    var nested_owned = true;
    defer if (nested_owned) result_mod.deinitOwnedValue(allocator, .{ .object = nested });
    try putOwnedString(allocator, &nested, "status", "ok");

    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) result_mod.deinitOwnedValue(allocator, .{ .array = array });
    try appendOwnedString(allocator, &array, "first");
    try appendOwnedNumberString(allocator, &array, "42.5");
    try putOwnedValue(allocator, &nested, "items", .{ .array = array });
    array_owned = false;

    try putOwnedValue(allocator, &obj, "nested", .{ .object = nested });
    nested_owned = false;

    const result = try result_mod.structuredOwned(allocator, .{ .object = obj });
    defer result_mod.deinitToolResult(allocator, result);

    const structured_content = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zigars", structured_content.get("name").?.string);
    try std.testing.expectEqualStrings("1.25", structured_content.get("ratio").?.number_string);
    try std.testing.expectEqualStrings("first", structured_content.get("nested").?.object.get("items").?.array.items[0].string);
    try std.testing.expectEqualStrings("42.5", structured_content.get("nested").?.object.get("items").?.array.items[1].number_string);
}

test "structuredOwned releases input value after cloning result" {
    const allocator = std.testing.allocator;
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, "zigars") });

    const result = try result_mod.structuredOwned(allocator, .{ .object = obj });
    defer result_mod.deinitToolResult(allocator, result);

    try std.testing.expectEqualStrings("zigars", result.structuredContent.?.object.get("name").?.string);
}

test "structuredWithResourceLink emits text fallback and resource link" {
    const allocator = std.testing.allocator;
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "artifact" });

    const result = try result_mod.structuredWithResourceLink(allocator, .{ .object = obj }, .{
        .name = "artifact.txt",
        .uri = "zigars://artifacts/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .title = "Artifact",
        .description = "desc",
        .mimeType = "text/plain",
    });
    defer result_mod.deinitToolResult(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.content.len);
    try std.testing.expectEqualStrings("resource_link", result.content[1].resource_link.type);
    try std.testing.expectEqualStrings("artifact", result.structuredContent.?.object.get("kind").?.string);
}

test "deinit helpers release all owned content block variants" {
    const allocator = std.testing.allocator;
    const meta = try result_mod.cloneValue(allocator, .{ .string = "meta" });
    result_mod.deinitOwnedContentBlock(allocator, .{ .image = .{
        .data = try allocator.dupe(u8, "image-data"),
        .mimeType = try allocator.dupe(u8, "image/png"),
        ._meta = meta,
    } });

    const audio_meta = try result_mod.cloneValue(allocator, .{ .string = "audio-meta" });
    result_mod.deinitOwnedContentBlock(allocator, .{ .audio = .{
        .data = try allocator.dupe(u8, "audio-data"),
        .mimeType = try allocator.dupe(u8, "audio/wav"),
        ._meta = audio_meta,
    } });

    const resource_meta = try result_mod.cloneValue(allocator, .{ .string = "resource-meta" });
    const embedded_meta = try result_mod.cloneValue(allocator, .{ .string = "embedded-meta" });
    result_mod.deinitOwnedContentBlock(allocator, .{ .resource = .{
        .resource = .{
            .uri = "zigars://resource",
            .text = try allocator.dupe(u8, "resource text"),
            .blob = try allocator.dupe(u8, "YmxvYg=="),
            ._meta = resource_meta,
        },
        ._meta = embedded_meta,
    } });

    const link_meta = try result_mod.cloneValue(allocator, .{ .string = "link-meta" });
    result_mod.deinitOwnedContentBlock(allocator, .{ .resource_link = .{
        .name = try allocator.dupe(u8, "artifact"),
        .title = try allocator.dupe(u8, "Artifact"),
        .uri = try allocator.dupe(u8, "zigars://artifact/1"),
        .description = try allocator.dupe(u8, "desc"),
        .mimeType = try allocator.dupe(u8, "application/json"),
        ._meta = link_meta,
    } });
}

test "resource and prompt deinit helpers accept empty and populated payloads" {
    const allocator = std.testing.allocator;

    result_mod.deinitResourceContent(allocator, .{
        .uri = "zigars://resource",
        .text = try allocator.dupe(u8, "text"),
        .blob = try allocator.dupe(u8, "YmxvYg=="),
        ._meta = try result_mod.cloneValue(allocator, .{ .string = "resource-meta" }),
    });

    const messages = try allocator.alloc(mcp.prompts.PromptMessage, 1);
    messages[0] = .{
        .role = .user,
        .content = .{ .text = .{
            .text = try allocator.dupe(u8, "prompt text"),
            ._meta = try result_mod.cloneValue(allocator, .{ .string = "prompt-meta" }),
        } },
    };
    result_mod.deinitPromptMessages(allocator, messages);

    result_mod.deinitPromptMessages(allocator, &.{});
}

test "owned JSON helper rollbacks handle allocation failure" {
    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer backing.deinit();
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        const allocator = failing.allocator();

        var obj = std.json.ObjectMap.empty;
        if (putOwnedString(allocator, &obj, "name", "zigars")) |_| {
            result_mod.deinitOwnedValue(allocator, .{ .object = obj });
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);

        var number_obj = std.json.ObjectMap.empty;
        if (putOwnedNumberString(allocator, &number_obj, "ratio", "1.25")) |_| {
            result_mod.deinitOwnedValue(allocator, .{ .object = number_obj });
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);

        var array = std.json.Array.init(allocator);
        if (appendOwnedString(allocator, &array, "first")) |_| {
            result_mod.deinitOwnedValue(allocator, .{ .array = array });
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);

        var number_array = std.json.Array.init(allocator);
        if (appendOwnedNumberString(allocator, &number_array, "42.5")) |_| {
            result_mod.deinitOwnedValue(allocator, .{ .array = number_array });
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

/// Inserts an owned JSON value into an object.
fn putOwnedValue(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try obj.put(allocator, owned_key, value);
}

/// Inserts an allocator-owned string into a JSON object.
fn putOwnedString(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try putOwnedValue(allocator, obj, key, .{ .string = owned_value });
}

/// Inserts a number encoded as an owned JSON string.
fn putOwnedNumberString(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try putOwnedValue(allocator, obj, key, .{ .number_string = owned_value });
}

/// Appends an allocator-owned string to a JSON array.
fn appendOwnedString(allocator: std.mem.Allocator, array: *std.json.Array, value: []const u8) !void {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try array.append(.{ .string = owned_value });
}

/// Appends a number encoded as an owned JSON string.
fn appendOwnedNumberString(allocator: std.mem.Allocator, array: *std.json.Array, value: []const u8) !void {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try array.append(.{ .number_string = owned_value });
}
