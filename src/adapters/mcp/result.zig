//! Shared ownership and serialization helpers for MCP tool, resource, and
//! prompt results returned by adapter handlers.
const std = @import("std");
const mcp = @import("mcp");

/// Ownership contract for zigar tool results:
/// - `structured`, `structuredError`, `structuredOwned`, and `jsonTextOnly`
///   return content slices owned by the callback allocator.
/// - Text content payloads in those slices are owned by the same allocator.
/// - `structuredContent`, when present, is a deep clone owned by the same
///   allocator, including object keys, arrays, strings, and number strings.
/// Call this after the MCP response has been serialized and no response value
/// still borrows from the result.
pub fn deinitToolResult(allocator: std.mem.Allocator, result: mcp.tools.ToolResult) void {
    if (result.structuredContent) |structured_content| deinitOwnedValue(allocator, structured_content);
    for (result.content) |content_item| deinitOwnedContentBlock(allocator, content_item);
    if (result.content.len > 0) allocator.free(result.content);
}

/// Ownership contract for zigar resource results:
/// - `uri` and `mimeType` borrow the registered resource/request data.
/// - `text`, `blob`, and `_meta`, when present, are owned by the callback
///   allocator and must stay alive through response serialization.
pub fn deinitResourceContent(allocator: std.mem.Allocator, content: mcp.resources.ResourceContent) void {
    if (content.text) |text| allocator.free(text);
    if (content.blob) |blob| allocator.free(blob);
    if (content._meta) |meta| deinitOwnedValue(allocator, meta);
}

/// Ownership contract for zigar prompt results:
/// - The message slice is owned by the callback allocator.
/// - Each content block payload is owned according to `deinitOwnedContentBlock`.
/// Call this only for prompts that explicitly opt into the zigar-owned contract.
pub fn deinitPromptMessages(allocator: std.mem.Allocator, messages: []const mcp.prompts.PromptMessage) void {
    for (messages) |message| deinitOwnedContentBlock(allocator, message.content);
    if (messages.len > 0) allocator.free(messages);
}

/// Serializes `value` into text content and clones it into structuredContent.
pub fn structured(allocator: std.mem.Allocator, value: std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structuredWithErrorFlag(allocator, value, false);
}

/// Same shape as `structured`, but marks the ToolResult as an MCP tool error.
pub fn structuredError(allocator: std.mem.Allocator, value: std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structuredWithErrorFlag(allocator, value, true);
}

fn structuredWithErrorFlag(allocator: std.mem.Allocator, value: std.json.Value, is_error: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    const bytes = serializeAlloc(allocator, value) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);

    const structured_value = cloneValue(allocator, value) catch return error.OutOfMemory;
    errdefer deinitClonedValue(allocator, structured_value);

    const content = allocator.alloc(mcp.types.ContentBlock, 1) catch return error.OutOfMemory;
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = bytes } };
    return .{
        .content = content,
        .structuredContent = structured_value,
        .is_error = is_error,
    };
}

/// Consumes an allocator-owned JSON tree after cloning/serializing it.
pub fn structuredOwned(allocator: std.mem.Allocator, value: std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Use only with JSON trees whose object keys and owned string payloads were
    // allocated by this allocator, or with values produced by cloneValue.
    defer deinitOwnedValue(allocator, value);
    return structured(allocator, value);
}

/// Deep-clones a JSON value, including object keys and string payloads.
pub fn cloneValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |array| blk: {
            var cloned = std.json.Array.init(allocator);
            errdefer deinitClonedArray(allocator, &cloned);
            for (array.items) |item| {
                const cloned_item = try cloneValue(allocator, item);
                errdefer deinitClonedValue(allocator, cloned_item);
                try cloned.append(cloned_item);
            }
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned = std.json.ObjectMap.empty;
            errdefer deinitClonedObject(allocator, &cloned);
            var it = object.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                const cloned_value = try cloneValue(allocator, entry.value_ptr.*);
                errdefer deinitClonedValue(allocator, cloned_value);
                try cloned.put(allocator, key, cloned_value);
            }
            break :blk .{ .object = cloned };
        },
    };
}

/// Frees a JSON tree previously cloned or built with allocator-owned keys/strings.
pub fn deinitOwnedValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    deinitClonedValue(allocator, value);
}

/// Frees payloads inside a content block that follows zigar-owned allocation rules.
pub fn deinitOwnedContentBlock(allocator: std.mem.Allocator, content_item: mcp.types.ContentBlock) void {
    switch (content_item) {
        .text => |text| {
            allocator.free(text.text);
            if (text._meta) |meta| deinitOwnedValue(allocator, meta);
        },
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mimeType);
            if (image._meta) |meta| deinitOwnedValue(allocator, meta);
        },
        .audio => |audio| {
            allocator.free(audio.data);
            allocator.free(audio.mimeType);
            if (audio._meta) |meta| deinitOwnedValue(allocator, meta);
        },
        .resource => |resource| {
            deinitProtocolResourceContent(allocator, resource.resource);
            if (resource._meta) |meta| deinitOwnedValue(allocator, meta);
        },
        .resource_link => |link| {
            allocator.free(link.name);
            if (link.title) |title| allocator.free(title);
            allocator.free(link.uri);
            if (link.description) |description| allocator.free(description);
            if (link.mimeType) |mime| allocator.free(mime);
            if (link._meta) |meta| deinitOwnedValue(allocator, meta);
        },
    }
}

fn deinitProtocolResourceContent(allocator: std.mem.Allocator, content: mcp.types.ResourceContent) void {
    if (content.text) |text| allocator.free(text);
    if (content.blob) |blob| allocator.free(blob);
    if (content._meta) |meta| deinitOwnedValue(allocator, meta);
}

fn deinitClonedValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |array| {
            var mutable = array;
            deinitClonedArray(allocator, &mutable);
        },
        .object => |object| {
            var mutable = object;
            deinitClonedObject(allocator, &mutable);
        },
        else => {},
    }
}

fn deinitClonedArray(allocator: std.mem.Allocator, array: *std.json.Array) void {
    for (array.items) |item| deinitClonedValue(allocator, item);
    array.deinit();
}

fn deinitClonedObject(allocator: std.mem.Allocator, object: *std.json.ObjectMap) void {
    var it = object.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        deinitClonedValue(allocator, entry.value_ptr.*);
    }
    object.deinit(allocator);
}

/// Allocates compact JSON text for an in-memory Value.
pub fn serializeAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var bytes_list: std.ArrayList(u8) = .empty;
    errdefer bytes_list.deinit(allocator);
    try serializeValue(allocator, &bytes_list, value);
    return bytes_list.toOwnedSlice(allocator);
}

/// Appends compact JSON text without taking ownership of `value`.
pub fn serializeValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| try out.print(allocator, "{d}", .{i}),
        .float => |f| try out.print(allocator, "{d}", .{f}),
        .number_string => |s| try out.appendSlice(allocator, s),
        .string => |s| try serializeString(allocator, out, s),
        .array => |array| {
            try out.append(allocator, '[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try out.append(allocator, ',');
                try serializeValue(allocator, out, item);
            }
            try out.append(allocator, ']');
        },
        .object => |object| {
            try out.append(allocator, '{');
            var it = object.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.append(allocator, ',');
                first = false;
                try serializeString(allocator, out, entry.key_ptr.*);
                try out.append(allocator, ':');
                try serializeValue(allocator, out, entry.value_ptr.*);
            }
            try out.append(allocator, '}');
        },
    }
}

/// Appends a JSON string literal with required control-character escaping.
pub fn serializeString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789abcdef";
    try out.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0c => try out.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                try out.appendSlice(allocator, "\\u00");
                try out.append(allocator, hex[c >> 4]);
                try out.append(allocator, hex[c & 0x0f]);
            },
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}
