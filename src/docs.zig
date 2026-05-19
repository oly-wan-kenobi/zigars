const std = @import("std");
const builtin = @import("builtin");
const langref = @import("docs/langref.zig");

pub const BuiltinDoc = struct {
    name: []const u8,
    signature: []const u8,
    summary: []const u8,
};

pub const LangRefSection = langref.Section;

pub const builtins = [_]BuiltinDoc{
    .{ .name = "@import", .signature = "@import(comptime path: []const u8) type", .summary = "Imports a Zig source file or package module at comptime." },
    .{ .name = "@This", .signature = "@This() type", .summary = "Returns the innermost container type." },
    .{ .name = "@TypeOf", .signature = "@TypeOf(...) type", .summary = "Returns the type of an expression or peer-resolved expressions." },
    .{ .name = "@as", .signature = "@as(comptime T: type, expression) T", .summary = "Performs an explicit type coercion." },
    .{ .name = "@intCast", .signature = "@intCast(integer) anytype", .summary = "Casts an integer to the inferred integer type with safety checks when enabled." },
    .{ .name = "@floatFromInt", .signature = "@floatFromInt(int) anytype", .summary = "Converts an integer to the inferred floating-point type." },
    .{ .name = "@ptrCast", .signature = "@ptrCast(value) anytype", .summary = "Changes pointer type without changing the address." },
    .{ .name = "@alignCast", .signature = "@alignCast(ptr) anytype", .summary = "Asserts or adjusts pointer alignment to the inferred alignment." },
    .{ .name = "@field", .signature = "@field(lhs, comptime field_name: []const u8) anytype", .summary = "Accesses a field by comptime-known name." },
    .{ .name = "@hasDecl", .signature = "@hasDecl(comptime Container: type, comptime name: []const u8) bool", .summary = "Checks whether a container has a declaration." },
    .{ .name = "@hasField", .signature = "@hasField(comptime Container: type, comptime name: []const u8) bool", .summary = "Checks whether a container type has a field." },
    .{ .name = "@compileError", .signature = "@compileError(comptime msg: []const u8) noreturn", .summary = "Emits a compile error during semantic analysis." },
    .{ .name = "@compileLog", .signature = "@compileLog(...) void", .summary = "Prints compile-time debugging information." },
    .{ .name = "@memcpy", .signature = "@memcpy(noalias dest, noalias source) void", .summary = "Copies memory from source to destination." },
    .{ .name = "@memset", .signature = "@memset(dest, elem) void", .summary = "Sets all elements of a destination to a value." },
    .{ .name = "@sizeOf", .signature = "@sizeOf(comptime T: type) comptime_int", .summary = "Returns the ABI size of a type in bytes." },
    .{ .name = "@alignOf", .signature = "@alignOf(comptime T: type) comptime_int", .summary = "Returns the ABI alignment of a type." },
    .{ .name = "@bitSizeOf", .signature = "@bitSizeOf(comptime T: type) comptime_int", .summary = "Returns the bit size of a type." },
    .{ .name = "@errorName", .signature = "@errorName(err: anyerror) [:0]const u8", .summary = "Returns the name of an error value." },
    .{ .name = "@tagName", .signature = "@tagName(value: anytype) [:0]const u8", .summary = "Returns the tag name of an enum value." },
    .{ .name = "@embedFile", .signature = "@embedFile(comptime path: []const u8) *const [N:0]u8", .summary = "Embeds a file in the binary at compile time." },
    .{ .name = "@src", .signature = "@src() std.builtin.SourceLocation", .summary = "Returns source location information." },
    .{ .name = "@panic", .signature = "@panic(message: []const u8) noreturn", .summary = "Terminates execution with a panic message." },
};

pub const langref_sections = langref.sections;

pub fn builtinList(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "Known Zig builtins ({d} curated entries):\n\n", .{builtins.len});
    for (builtins) |item| {
        try out.print(allocator, "- `{s}`: {s}\n", .{ item.signature, item.summary });
    }
    return out.toOwnedSlice(allocator);
}

pub fn builtinDoc(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);

    var found: usize = 0;
    for (builtins) |item| {
        const lower_name = try asciiLowerAlloc(allocator, item.name);
        defer allocator.free(lower_name);
        if (std.mem.indexOf(u8, lower_name, lower_query) != null or std.mem.indexOf(u8, lower_query, lower_name) != null) {
            found += 1;
            try out.print(allocator, "## {s}\n\n```zig\n{s}\n```\n\n{s}\n\n", .{ item.name, item.signature, item.summary });
        }
    }

    if (found == 0) {
        try out.print(allocator, "No curated builtin documentation matched `{s}`. Try `zig_builtin_list` for available entries.\n", .{query});
    }
    return out.toOwnedSlice(allocator);
}

pub fn searchStd(
    allocator: std.mem.Allocator,
    io: std.Io,
    std_dir: []const u8,
    query: []const u8,
    limit: usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);

    var dir = try std.Io.Dir.openDirAbsolute(io, std_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var count: usize = 0;
    var skipped_files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (count >= limit) break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const abs = try std.fs.path.join(allocator, &.{ std_dir, entry.path });
        defer allocator.free(abs);
        const contents = std.Io.Dir.cwd().readFileAlloc(io, abs, allocator, .limited(512 * 1024)) catch {
            skipped_files += 1;
            continue;
        };
        defer allocator.free(contents);

        const lower_contents = try asciiLowerAlloc(allocator, contents);
        defer allocator.free(lower_contents);
        const hit = std.mem.indexOf(u8, lower_contents, lower_query) orelse continue;

        count += 1;
        const line_no = lineNumber(contents, hit);
        const snippet = lineAt(contents, hit);
        try out.print(allocator, "### std/{s}:{d}\n\n```zig\n{s}\n```\n\n", .{ entry.path, line_no, snippet });
    }

    if (count == 0) {
        try out.print(allocator, "No stdlib matches for `{s}` under {s}.\n", .{ query, std_dir });
    }
    if (skipped_files > 0) {
        try out.print(allocator, "\nSkipped {d} unreadable or oversized Zig files while scanning.\n", .{skipped_files});
    }
    return out.toOwnedSlice(allocator);
}

pub fn langRefSearch(allocator: std.mem.Allocator, io: std.Io, lib_dir: []const u8, query: []const u8, limit: usize) ![]u8 {
    return langref.search(allocator, io, lib_dir, query, limit);
}

fn asciiLowerAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn lineNumber(text: []const u8, index: usize) usize {
    var line: usize = 1;
    for (text[0..@min(index, text.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

fn lineAt(text: []const u8, index: usize) []const u8 {
    var start = index;
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    var end = index;
    while (end < text.len and text[end] != '\n') end += 1;
    return text[start..end];
}

test "builtin docs find import" {
    const text = try builtinDoc(std.testing.allocator, "import");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "@import") != null);
}

test {
    _ = langref;
}

test "std search ignores non-zig documentation files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "std");
    try tmp.dir.writeFile(io, .{ .sub_path = "std/readme.md", .data = "docs_only_token\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "std/main.zig", .data = "pub const x = 1;\n" });

    const std_dir = try tmpAbs(allocator, io, tmp.sub_path[0..], "std");
    defer allocator.free(std_dir);
    const text = try searchStd(allocator, io, std_dir, "docs_only_token", 10);
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "No stdlib matches") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "readme.md") == null);
}

fn tmpAbs(allocator: std.mem.Allocator, io: std.Io, tmp_sub_path: []const u8, child: []const u8) ![]u8 {
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp_sub_path });
    defer allocator.free(rel_base);
    const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    return std.fs.path.join(allocator, &.{ base_z[0..], child });
}
