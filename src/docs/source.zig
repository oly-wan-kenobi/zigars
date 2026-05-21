const std = @import("std");
const json_result = @import("../json_result.zig");

pub const Completeness = enum {
    installed_complete,
    partial_curated,
    source_scan,

    pub fn text(self: Completeness) []const u8 {
        return switch (self) {
            .installed_complete => "installed_complete",
            .partial_curated => "partial_curated",
            .source_scan => "source_scan",
        };
    }
};

pub const Source = struct {
    id: []const u8,
    label: []const u8,
    provenance: []const u8,
    completeness: Completeness,
    version: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

pub const Contract = struct {
    query: ?[]const u8 = null,
    limit: ?usize = null,
    result_count: usize,
    no_result_reason: ?[]const u8 = null,
    ranking: []const u8,
};

pub fn curatedBuiltins() Source {
    return .{
        .id = "curated_zigar_builtins",
        .label = "Curated Zig builtin documentation bundled with zigar",
        .provenance = "curated zigar data",
        .completeness = .partial_curated,
        .version = "zigar-bundled",
    };
}

pub fn stdlibSource(path: []const u8, version: ?[]const u8) Source {
    return .{
        .id = "local_stdlib_zig_source",
        .label = "Local Zig standard-library source files",
        .provenance = "local Zig installation std_dir .zig source scan",
        .completeness = .source_scan,
        .version = version,
        .path = path,
    };
}

pub fn installedLangref(path: []const u8, version: ?[]const u8) Source {
    return .{
        .id = "installed_langref_html",
        .label = "Installed Zig language reference HTML",
        .provenance = "local Zig installation language reference HTML",
        .completeness = .installed_complete,
        .version = version,
        .path = path,
    };
}

pub fn bundledLangref() Source {
    return .{
        .id = "bundled_langref_index",
        .label = "Bundled Zig language-reference index",
        .provenance = "curated zigar fallback data",
        .completeness = .partial_curated,
        .version = "zigar-bundled",
    };
}

pub fn appendTextHeader(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source: Source) !void {
    try out.print(allocator,
        \\Docs source: {s}
        \\Source label: {s}
        \\Provenance: {s}
        \\Completeness: {s}
        \\
    , .{ source.id, source.label, source.provenance, source.completeness.text() });
    if (source.version) |version| {
        try out.print(allocator, "Version: {s}\n", .{version});
    } else {
        try out.appendSlice(allocator, "Version: unavailable\n");
    }
    if (source.path) |path| try out.print(allocator, "Path: {s}\n", .{path});
    try out.append(allocator, '\n');
}

pub fn appendTextContract(allocator: std.mem.Allocator, out: *std.ArrayList(u8), contract: Contract) !void {
    if (contract.query) |query| {
        try out.print(allocator, "Query: `{s}`\n", .{query});
    } else {
        try out.appendSlice(allocator, "Query: none\n");
    }
    if (contract.limit) |limit| {
        try out.print(allocator, "Limit: {d}\n", .{limit});
    } else {
        try out.appendSlice(allocator, "Limit: none\n");
    }
    try out.print(allocator, "Result count: {d}\n", .{contract.result_count});
    if (contract.no_result_reason) |reason| {
        try out.print(allocator, "No result reason: {s}\n", .{reason});
    } else {
        try out.appendSlice(allocator, "No result reason: none\n");
    }
    try out.print(allocator, "Ranking: {s}\n\n", .{contract.ranking});
}

pub fn value(allocator: std.mem.Allocator, source: Source) !std.json.Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return json_result.cloneValue(allocator, try valueImpl(arena.allocator(), source));
}

fn valueImpl(allocator: std.mem.Allocator, source: Source) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "id", .{ .string = source.id });
    try obj.put(allocator, "label", .{ .string = source.label });
    try obj.put(allocator, "provenance", .{ .string = source.provenance });
    try obj.put(allocator, "completeness", .{ .string = source.completeness.text() });
    if (source.version) |version| {
        try obj.put(allocator, "version", .{ .string = version });
        try obj.put(allocator, "version_status", .{ .string = if (std.mem.eql(u8, version, "zigar-bundled")) "bundled" else "available" });
    } else {
        try obj.put(allocator, "version", .{ .string = "unavailable" });
        try obj.put(allocator, "version_status", .{ .string = "unavailable" });
    }
    if (source.path) |path| {
        try obj.put(allocator, "path", .{ .string = path });
        try obj.put(allocator, "source_path", .{ .string = path });
    } else {
        try obj.put(allocator, "path", .null);
        try obj.put(allocator, "source_path", .null);
    }
    return .{ .object = obj };
}

pub fn putContractFields(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, source: Source, contract: Contract) !void {
    try obj.put(allocator, "source", try valueImpl(allocator, source));
    try obj.put(allocator, "completeness_level", .{ .string = source.completeness.text() });
    if (contract.query) |query| {
        try obj.put(allocator, "query", .{ .string = query });
    } else {
        try obj.put(allocator, "query", .null);
    }
    if (contract.limit) |limit| {
        try obj.put(allocator, "limit", .{ .integer = @intCast(limit) });
    } else {
        try obj.put(allocator, "limit", .null);
    }
    try obj.put(allocator, "result_count", .{ .integer = @intCast(contract.result_count) });
    if (contract.no_result_reason) |reason| {
        try obj.put(allocator, "no_result_reason", .{ .string = reason });
    } else {
        try obj.put(allocator, "no_result_reason", .null);
    }
    try obj.put(allocator, "ranking", .{ .string = contract.ranking });
}

test "docs sources expose provenance and completeness" {
    const builtin = curatedBuiltins();
    try std.testing.expectEqualStrings("curated_zigar_builtins", builtin.id);
    try std.testing.expectEqualStrings("partial_curated", builtin.completeness.text());

    const stdlib = stdlibSource("/opt/zig/lib/std", null);
    try std.testing.expectEqualStrings("local_stdlib_zig_source", stdlib.id);
    try std.testing.expectEqualStrings("source_scan", stdlib.completeness.text());

    const langref = installedLangref("/opt/zig/lib/doc/langref.html", "0.16.0");
    try std.testing.expectEqualStrings("installed_langref_html", langref.id);
    try std.testing.expectEqualStrings("installed_complete", langref.completeness.text());
}

test "docs source JSON exposes explicit version and source path state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const missing_version = try value(allocator, stdlibSource("/opt/zig/lib/std", null));
    defer json_result.deinitOwnedValue(allocator, missing_version);
    const source_obj = missing_version.object;
    try std.testing.expectEqualStrings("unavailable", source_obj.get("version").?.string);
    try std.testing.expectEqualStrings("unavailable", source_obj.get("version_status").?.string);
    try std.testing.expectEqualStrings("/opt/zig/lib/std", source_obj.get("source_path").?.string);

    var contract_obj = std.json.ObjectMap.empty;
    try putContractFields(allocator, &contract_obj, curatedBuiltins(), .{
        .query = "@import",
        .limit = 1,
        .result_count = 1,
        .ranking = "test ranking",
    });
    const query = contract_obj.get("query").?;
    try std.testing.expectEqualStrings("@import", query.string);
    try std.testing.expectEqualStrings("partial_curated", contract_obj.get("completeness_level").?.string);
    try std.testing.expectEqual(@as(i64, 1), contract_obj.get("limit").?.integer);
    try std.testing.expectEqual(@as(i64, 1), contract_obj.get("result_count").?.integer);
    try std.testing.expect(contract_obj.get("no_result_reason").? == .null);
}
