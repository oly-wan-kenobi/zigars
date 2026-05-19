const std = @import("std");

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
        \\Provenance: {s}
        \\Completeness: {s}
        \\
    , .{ source.id, source.provenance, source.completeness.text() });
    if (source.version) |version| {
        try out.print(allocator, "Version: {s}\n", .{version});
    } else {
        try out.appendSlice(allocator, "Version: unavailable\n");
    }
    if (source.path) |path| try out.print(allocator, "Path: {s}\n", .{path});
    try out.append(allocator, '\n');
}

pub fn value(allocator: std.mem.Allocator, source: Source) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "id", .{ .string = source.id });
    try obj.put(allocator, "label", .{ .string = source.label });
    try obj.put(allocator, "provenance", .{ .string = source.provenance });
    try obj.put(allocator, "completeness", .{ .string = source.completeness.text() });
    if (source.version) |version| {
        try obj.put(allocator, "version", .{ .string = version });
    } else {
        try obj.put(allocator, "version", .{ .string = "unavailable" });
    }
    if (source.path) |path| {
        try obj.put(allocator, "path", .{ .string = path });
    } else {
        try obj.put(allocator, "path", .null);
    }
    return .{ .object = obj };
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
