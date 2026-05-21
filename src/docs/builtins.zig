const std = @import("std");
const builtin_meta = @import("builtin_meta.zig");
const docs_source = @import("source.zig");
const json_result = @import("../json_result.zig");

pub const BuiltinDoc = struct {
    name: []const u8,
    signature: []const u8,
    summary: []const u8,
};

pub const BuiltinDriftInfo = builtin_meta.BuiltinDriftInfo;
pub const BuiltinIndexInput = builtin_meta.BuiltinIndexInput;

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

const builtin_list_ranking = "curated builtin declaration order";
const builtin_doc_ranking = "case-insensitive builtin-name substring match in curated order; limit is applied after matching";

pub fn builtinList(allocator: std.mem.Allocator, toolchain_version: ?[]const u8) ![]u8 {
    return builtinListWithInput(allocator, .{ .toolchain_version = toolchain_version });
}

pub fn builtinListWithInput(allocator: std.mem.Allocator, input: BuiltinIndexInput) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const source = docs_source.curatedBuiltins();
    const contract: docs_source.Contract = .{
        .result_count = builtins.len,
        .ranking = builtin_list_ranking,
    };
    try docs_source.appendTextHeader(allocator, &out, source);
    try docs_source.appendTextContract(allocator, &out, contract);
    try appendBuiltinIndexMetadataText(allocator, &out, input);
    try out.print(allocator, "Known Zig builtins ({d} curated entries):\n\n", .{builtins.len});
    for (builtins) |item| {
        try out.print(allocator, "- `{s}`: {s}\n", .{ item.signature, item.summary });
    }
    return out.toOwnedSlice(allocator);
}

pub fn builtinListValue(allocator: std.mem.Allocator, toolchain_version: ?[]const u8) !std.json.Value {
    return builtinListValueWithInput(allocator, .{ .toolchain_version = toolchain_version });
}

pub fn builtinListValueWithInput(allocator: std.mem.Allocator, input: BuiltinIndexInput) !std.json.Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return json_result.cloneValue(allocator, try builtinListValueImpl(arena.allocator(), input));
}

fn builtinListValueImpl(allocator: std.mem.Allocator, input: BuiltinIndexInput) !std.json.Value {
    var items = std.json.Array.init(allocator);
    errdefer items.deinit();
    for (builtins) |item| try items.append(try builtinItemValue(allocator, item, null));

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try docs_source.putContractFields(allocator, &obj, docs_source.curatedBuiltins(), .{
        .result_count = builtins.len,
        .ranking = builtin_list_ranking,
    });
    try obj.put(allocator, "index_metadata", try builtinIndexMetadataValue(allocator, input));
    try obj.put(allocator, "count", .{ .integer = @intCast(builtins.len) });
    try obj.put(allocator, "builtins", .{ .array = items });
    return .{ .object = obj };
}

pub fn builtinDoc(allocator: std.mem.Allocator, query: []const u8, limit: usize, toolchain_version: ?[]const u8) ![]u8 {
    return builtinDocWithInput(allocator, query, limit, .{ .toolchain_version = toolchain_version });
}

pub fn builtinDocWithInput(allocator: std.mem.Allocator, query: []const u8, limit: usize, input: BuiltinIndexInput) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);
    const normalized_limit = @max(limit, 1);

    const found = countBuiltinMatches(allocator, lower_query, normalized_limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    const contract: docs_source.Contract = .{
        .query = query,
        .limit = normalized_limit,
        .result_count = found,
        .no_result_reason = if (found == 0) "no_builtin_match" else null,
        .ranking = builtin_doc_ranking,
    };
    try docs_source.appendTextHeader(allocator, &out, docs_source.curatedBuiltins());
    try docs_source.appendTextContract(allocator, &out, contract);
    try appendBuiltinIndexMetadataText(allocator, &out, input);

    var emitted: usize = 0;
    for (builtins) |item| {
        const lower_name = try asciiLowerAlloc(allocator, item.name);
        defer allocator.free(lower_name);
        if (std.mem.indexOf(u8, lower_name, lower_query) != null or std.mem.indexOf(u8, lower_query, lower_name) != null) {
            if (emitted >= normalized_limit) break;
            emitted += 1;
            try out.print(allocator, "## {s}\n\n```zig\n{s}\n```\n\n{s}\n\n", .{ item.name, item.signature, item.summary });
        }
    }

    if (emitted == 0) {
        try out.print(allocator, "No curated builtin documentation matched `{s}`. Try `zig_builtin_list` for available entries.\n", .{query});
    }
    return out.toOwnedSlice(allocator);
}

pub fn builtinDocValue(allocator: std.mem.Allocator, query: []const u8, limit: usize, toolchain_version: ?[]const u8) !std.json.Value {
    return builtinDocValueWithInput(allocator, query, limit, .{ .toolchain_version = toolchain_version });
}

pub fn builtinDocValueWithInput(allocator: std.mem.Allocator, query: []const u8, limit: usize, input: BuiltinIndexInput) !std.json.Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return json_result.cloneValue(allocator, try builtinDocValueImpl(arena.allocator(), query, limit, input));
}

fn builtinDocValueImpl(allocator: std.mem.Allocator, query: []const u8, limit: usize, input: BuiltinIndexInput) !std.json.Value {
    const normalized_limit = @max(limit, 1);
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);

    var matches = std.json.Array.init(allocator);
    errdefer matches.deinit();
    var emitted: usize = 0;
    for (builtins) |item| {
        if (emitted >= normalized_limit) break;
        const lower_name = try asciiLowerAlloc(allocator, item.name);
        defer allocator.free(lower_name);
        if (std.mem.indexOf(u8, lower_name, lower_query) == null and std.mem.indexOf(u8, lower_query, lower_name) == null) continue;
        emitted += 1;
        try matches.append(try builtinItemValue(allocator, item, emitted));
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try docs_source.putContractFields(allocator, &obj, docs_source.curatedBuiltins(), .{
        .query = query,
        .limit = normalized_limit,
        .result_count = emitted,
        .no_result_reason = if (emitted == 0) "no_builtin_match" else null,
        .ranking = builtin_doc_ranking,
    });
    try obj.put(allocator, "index_metadata", try builtinIndexMetadataValue(allocator, input));
    try obj.put(allocator, "matches", .{ .array = matches });
    return .{ .object = obj };
}
fn builtinItemValue(allocator: std.mem.Allocator, item: BuiltinDoc, rank: ?usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    if (rank) |value_rank| try obj.put(allocator, "rank", .{ .integer = @intCast(value_rank) });
    try obj.put(allocator, "name", .{ .string = item.name });
    try obj.put(allocator, "signature", .{ .string = item.signature });
    try obj.put(allocator, "summary", .{ .string = item.summary });
    return .{ .object = obj };
}

fn builtinIndexMetadataValue(allocator: std.mem.Allocator, input: BuiltinIndexInput) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "index_strategy", .{ .string = "curated_builtin_index" });
    try obj.put(allocator, "completeness_mode", .{ .string = "partial_curated" });
    try obj.put(allocator, "curated_count", .{ .integer = @intCast(builtins.len) });
    if (input.toolchain_version) |version| {
        try obj.put(allocator, "toolchain_version", .{ .string = version });
    } else {
        try obj.put(allocator, "toolchain_version", .null);
    }
    const drift = input.drift orelse BuiltinDriftInfo{
        .status = if (input.toolchain_version == null) "toolchain_version_unavailable" else "toolchain_version_recorded_builtin_set_not_extracted",
        .confidence = "version_only",
    };
    try obj.put(allocator, "drift_check_status", .{ .string = drift.status });
    try obj.put(allocator, "drift_check_confidence", .{ .string = drift.confidence });
    if (drift.active_source_path) |path| try obj.put(allocator, "active_builtin_source_path", .{ .string = path }) else try obj.put(allocator, "active_builtin_source_path", .null);
    try obj.put(allocator, "active_builtin_count", .{ .integer = @intCast(drift.active_count) });
    try obj.put(allocator, "curated_missing_count", .{ .integer = @intCast(drift.curated_missing_count) });
    try obj.put(allocator, "active_extra_count", .{ .integer = @intCast(drift.active_extra_count) });
    try obj.put(allocator, "missing_curated_builtins", try stringArrayValue(allocator, drift.missing_names));
    try obj.put(allocator, "extra_active_builtins_sample", try stringArrayValue(allocator, drift.extra_names_sample));
    try obj.put(allocator, "drift_check_note", .{ .string = "When std/zig/BuiltinFn.zig is readable from the active Zig installation, zigar compares curated builtin entries against that offline source and reports missing curated names plus extra active names." });
    return .{ .object = obj };
}

fn appendBuiltinIndexMetadataText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: BuiltinIndexInput) !void {
    try out.print(allocator, "Index strategy: curated_builtin_index\nCurated entries: {d}\n", .{builtins.len});
    const drift = input.drift orelse BuiltinDriftInfo{ .status = if (input.toolchain_version == null) "toolchain_version_unavailable" else "toolchain_version_recorded_builtin_set_not_extracted", .confidence = "version_only" };
    if (input.toolchain_version) |version| {
        try out.print(allocator, "Toolchain version: {s}\n", .{version});
    } else {
        try out.appendSlice(allocator, "Toolchain version: unavailable\n");
    }
    if (drift.active_source_path) |path| try out.print(allocator, "Active builtin source: {s}\n", .{path});
    try out.print(allocator, "Drift check: {s}\nDrift confidence: {s}\nActive builtins: {d}\nCurated missing: {d}\nActive extras: {d}\n\n", .{ drift.status, drift.confidence, drift.active_count, drift.curated_missing_count, drift.active_extra_count });
}

fn stringArrayValue(allocator: std.mem.Allocator, strings: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (strings) |string| try array.append(.{ .string = string });
    return .{ .array = array };
}

fn countBuiltinMatches(allocator: std.mem.Allocator, lower_query: []const u8, limit: usize) !usize {
    var found: usize = 0;
    for (builtins) |item| {
        if (found >= limit) break;
        const lower_name = try asciiLowerAlloc(allocator, item.name);
        defer allocator.free(lower_name);
        if (std.mem.indexOf(u8, lower_name, lower_query) != null or std.mem.indexOf(u8, lower_query, lower_name) != null) found += 1;
    }
    return found;
}
fn asciiLowerAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}
