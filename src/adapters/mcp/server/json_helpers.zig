const std = @import("std");
const mcp = @import("mcp");

const types = mcp.types;

pub fn appendToolContentValue(allocator: std.mem.Allocator, content_array: *std.json.Array, content_item: types.ContentBlock) !void {
    var item_obj: std.json.ObjectMap = .empty;
    var item_obj_in_array = false;
    errdefer if (!item_obj_in_array) deinitBorrowedJsonContainers(allocator, .{ .object = item_obj });

    switch (content_item) {
        .text => |text| {
            try item_obj.put(allocator, "type", .{ .string = "text" });
            try item_obj.put(allocator, "text", .{ .string = text.text });
        },
        .image => |img| {
            try item_obj.put(allocator, "type", .{ .string = "image" });
            try item_obj.put(allocator, "data", .{ .string = img.data });
            try item_obj.put(allocator, "mimeType", .{ .string = img.mimeType });
        },
        .audio => |aud| {
            try item_obj.put(allocator, "type", .{ .string = "audio" });
            try item_obj.put(allocator, "data", .{ .string = aud.data });
            try item_obj.put(allocator, "mimeType", .{ .string = aud.mimeType });
        },
        .resource_link => |link| {
            try item_obj.put(allocator, "type", .{ .string = "resource_link" });
            try item_obj.put(allocator, "uri", .{ .string = link.uri });
            try item_obj.put(allocator, "name", .{ .string = link.name });
            if (link.title) |t| try item_obj.put(allocator, "title", .{ .string = t });
            if (link.description) |d| try item_obj.put(allocator, "description", .{ .string = d });
            if (link.mimeType) |m| try item_obj.put(allocator, "mimeType", .{ .string = m });
        },
        .resource => |res| {
            try item_obj.put(allocator, "type", .{ .string = "resource" });
            var res_obj: std.json.ObjectMap = .empty;
            var res_obj_in_item = false;
            errdefer if (!res_obj_in_item) res_obj.deinit(allocator);
            try res_obj.put(allocator, "uri", .{ .string = res.resource.uri });
            if (res.resource.text) |text| try res_obj.put(allocator, "text", .{ .string = text });
            if (res.resource.mimeType) |mime| try res_obj.put(allocator, "mimeType", .{ .string = mime });
            try item_obj.put(allocator, "resource", .{ .object = res_obj });
            res_obj_in_item = true;
        },
    }

    try content_array.append(.{ .object = item_obj });
    item_obj_in_array = true;
}

pub fn deinitToolCallResponseObject(allocator: std.mem.Allocator, result: *std.json.ObjectMap) void {
    var it = result.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "structuredContent")) continue;
        deinitBorrowedJsonContainers(allocator, entry.value_ptr.*);
    }
    result.deinit(allocator);
}

pub fn deinitBorrowedJsonContainers(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .array => |array| {
            var mutable = array;
            for (mutable.items) |item| deinitBorrowedJsonContainers(allocator, item);
            mutable.deinit();
        },
        .object => |object| {
            var mutable = object;
            var it = mutable.iterator();
            while (it.next()) |entry| deinitBorrowedJsonContainers(allocator, entry.value_ptr.*);
            mutable.deinit(allocator);
        },
        else => {},
    }
}
