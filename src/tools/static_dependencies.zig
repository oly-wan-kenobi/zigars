const std = @import("std");
const zigar = @import("zigar");

const analysis_contract = zigar.analysis_contract;
const static_build = @import("static_build.zig");
const common = @import("common.zig");

const App = common.App;
const ownedString = common.ownedString;

pub const DependencyRecord = struct {
    name: []const u8,
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    path: ?[]const u8 = null,
    line: usize,
};

pub fn cachePathStatusValue(allocator: std.mem.Allocator, a: *App, path: []const u8) !std.json.Value {
    const resolved = a.workspace.resolve(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => a.workspace.resolveOutput(path) catch null,
    };
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", try ownedString(allocator, path));
    if (resolved) |abs| {
        defer allocator.free(abs);
        try obj.put(allocator, "abs", try ownedString(allocator, abs));
        const count = countTopLevelEntries(allocator, a.io, abs) catch null;
        if (count) |n| {
            try obj.put(allocator, "exists", .{ .bool = true });
            try obj.put(allocator, "kind", .{ .string = "directory" });
            try obj.put(allocator, "entry_count", .{ .integer = @intCast(n) });
        } else if (std.Io.Dir.cwd().readFileAlloc(a.io, abs, allocator, .limited(1)) catch null) |bytes| {
            allocator.free(bytes);
            try obj.put(allocator, "exists", .{ .bool = true });
            try obj.put(allocator, "kind", .{ .string = "file" });
            try obj.put(allocator, "entry_count", .null);
        } else {
            try obj.put(allocator, "exists", .{ .bool = false });
            try obj.put(allocator, "kind", .null);
            try obj.put(allocator, "entry_count", .null);
        }
    } else {
        try obj.put(allocator, "abs", .null);
        try obj.put(allocator, "exists", .{ .bool = false });
        try obj.put(allocator, "kind", .null);
        try obj.put(allocator, "entry_count", .null);
    }
    return .{ .object = obj };
}

pub fn countTopLevelEntries(allocator: std.mem.Allocator, io: std.Io, abs: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(io, abs, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var count: usize = 0;
    while ((walker.next(io) catch null)) |entry| {
        if (std.mem.indexOfScalar(u8, entry.path, std.fs.path.sep) == null) count += 1;
    }
    return count;
}

pub fn dependencyInspectionValue(allocator: std.mem.Allocator, a: *App, bytes: []const u8) !std.json.Value {
    var deps = std.json.Array.init(allocator);
    var issues = std.json.Array.init(allocator);
    var current: ?DependencyRecord = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (dependencyBlockNameFromLine(trimmed)) |name| {
            if (current) |record| try appendDependencyRecord(allocator, &deps, &issues, record);
            current = .{ .name = name, .line = line_no };
            continue;
        }
        if (current) |*record| {
            if (std.mem.indexOf(u8, trimmed, ".url") != null) {
                record.url = static_build.quotedString(trimmed);
            } else if (std.mem.indexOf(u8, trimmed, ".hash") != null) {
                record.hash = static_build.quotedString(trimmed);
            } else if (std.mem.indexOf(u8, trimmed, ".path") != null) {
                record.path = static_build.quotedString(trimmed);
            } else if (std.mem.startsWith(u8, trimmed, "},")) {
                try appendDependencyRecord(allocator, &deps, &issues, record.*);
                current = null;
            }
        }
    }
    if (current) |record| try appendDependencyRecord(allocator, &deps, &issues, record);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_dependency_inspect" });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "dependencies", .{ .array = deps });
    try obj.put(allocator, "dependency_count", .{ .integer = @intCast(deps.items.len) });
    try obj.put(allocator, "issues", .{ .array = issues });
    try obj.put(allocator, "zig_pkg_cache", try cachePathStatusValue(allocator, a, "zig-pkg"));
    try analysis_contract.putMetadata(allocator, &obj, "zig_dependency_inspect");
    return .{ .object = obj };
}

pub fn dependencyBlockNameFromLine(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "= .{") == null) return null;
    const name = static_build.dependencyNameFromLine(line) orelse return null;
    if (std.mem.eql(u8, name, "dependencies") or
        std.mem.eql(u8, name, "paths") or
        std.mem.eql(u8, name, "url") or
        std.mem.eql(u8, name, "hash") or
        std.mem.eql(u8, name, "path")) return null;
    return name;
}

pub fn appendDependencyRecord(allocator: std.mem.Allocator, deps: *std.json.Array, issues: *std.json.Array, record: DependencyRecord) !void {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, record.name));
    try obj.put(allocator, "line", .{ .integer = @intCast(record.line) });
    if (record.url) |url| try obj.put(allocator, "url", try ownedString(allocator, url)) else try obj.put(allocator, "url", .null);
    if (record.hash) |hash| try obj.put(allocator, "hash", try ownedString(allocator, hash)) else try obj.put(allocator, "hash", .null);
    if (record.path) |path| try obj.put(allocator, "path", try ownedString(allocator, path)) else try obj.put(allocator, "path", .null);
    try deps.append(.{ .object = obj });
    if (record.url != null and record.hash == null) {
        try issues.append(.{ .string = try std.fmt.allocPrint(allocator, "dependency `{s}` has a URL but no hash", .{record.name}) });
    }
    if (record.url != null and record.path != null) {
        try issues.append(.{ .string = try std.fmt.allocPrint(allocator, "dependency `{s}` declares both url and path", .{record.name}) });
    }
}
