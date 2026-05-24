const std = @import("std");

pub const std_source_read_limit: usize = 512 * 1024;
pub const langref_probe_read_limit: usize = 128 * 1024;
pub const langref_html_read_limit: usize = 2 * 1024 * 1024;
pub const evidence_read_limit: usize = 8 * 1024 * 1024;
pub const default_path_scan_limit: usize = 10_000;

const builtin_list_ranking = "curated builtin declaration order";
const builtin_doc_ranking = "case-insensitive builtin-name substring match in curated order; limit is applied after matching";
const std_search_ranking = "case-insensitive declaration/source hit sorted by relative path then line; limit is applied after sorting";
const std_item_ranking = "exact declaration-name match, preferring the path implied by a qualified std name, then relative path and line; limit is applied after sorting";
pub const std_scan_limitations = "Source scan only: no semantic import resolution, no rendered autodoc, and declaration docs are adjacent triple-slash comments only.";
const bundled_ranking = "bundled curated sections with title or anchor matches before summary/body matches; limit is applied after ranking";
const installed_ranking = "installed HTML heading order for matching language-reference sections; limit is applied after document-order ranking";

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

pub fn curatedBuiltinsSource() Source {
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

pub fn installedLangrefSource(path: []const u8, version: ?[]const u8) Source {
    return .{
        .id = "installed_langref_html",
        .label = "Installed Zig language reference HTML",
        .provenance = "local Zig installation language reference HTML",
        .completeness = .installed_complete,
        .version = version,
        .path = path,
    };
}

pub fn bundledLangrefSource() Source {
    return .{
        .id = "bundled_langref_index",
        .label = "Bundled Zig language-reference index",
        .provenance = "curated zigar fallback data",
        .completeness = .partial_curated,
        .version = "zigar-bundled",
    };
}

pub const BuiltinDoc = struct {
    name: []const u8,
    signature: []const u8,
    summary: []const u8,
};

pub const BuiltinDriftInfo = struct {
    status: []const u8,
    confidence: []const u8,
    active_source_path: ?[]const u8 = null,
    active_count: usize = 0,
    curated_missing_count: usize = 0,
    active_extra_count: usize = 0,
    missing_names: []const []const u8 = &.{},
    extra_names_sample: []const []const u8 = &.{},
};

pub const BuiltinIndexInput = struct {
    toolchain_version: ?[]const u8 = null,
    owns_toolchain_version: bool = false,
    drift: ?BuiltinDriftInfo = null,
    owns_active_source_path: bool = false,
};

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

pub const BuiltinListResult = struct {
    input: BuiltinIndexInput,

    pub fn deinit(self: BuiltinListResult, allocator: std.mem.Allocator) void {
        deinitBuiltinIndexInput(self.input, allocator);
    }
};

pub const BuiltinDocMatch = struct {
    rank: usize,
    item: BuiltinDoc,
};

pub const BuiltinDocResult = struct {
    query: []const u8,
    limit: usize,
    input: BuiltinIndexInput,
    matches: []BuiltinDocMatch,

    pub fn deinit(self: BuiltinDocResult, allocator: std.mem.Allocator) void {
        deinitBuiltinIndexInput(self.input, allocator);
        allocator.free(self.matches);
    }
};

pub fn deinitBuiltinIndexInput(input: BuiltinIndexInput, allocator: std.mem.Allocator) void {
    if (input.owns_toolchain_version) if (input.toolchain_version) |version| allocator.free(version);
    if (input.drift) |drift| {
        if (input.owns_active_source_path) if (drift.active_source_path) |path| allocator.free(path);
        allocator.free(drift.missing_names);
        allocator.free(drift.extra_names_sample);
    }
}

pub fn builtinList(input: BuiltinIndexInput) BuiltinListResult {
    return .{ .input = input };
}

pub fn builtinDoc(allocator: std.mem.Allocator, query: []const u8, limit: usize, input: BuiltinIndexInput) !BuiltinDocResult {
    const normalized_limit = @max(limit, 1);
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);

    var matches: std.ArrayList(BuiltinDocMatch) = .empty;
    errdefer matches.deinit(allocator);
    for (builtins) |item| {
        if (matches.items.len >= normalized_limit) break;
        const lower_name = try asciiLowerAlloc(allocator, item.name);
        defer allocator.free(lower_name);
        if (std.mem.indexOf(u8, lower_name, lower_query) == null and std.mem.indexOf(u8, lower_query, lower_name) == null) continue;
        try matches.append(allocator, .{ .rank = matches.items.len + 1, .item = item });
    }

    return .{
        .query = query,
        .limit = normalized_limit,
        .input = input,
        .matches = try matches.toOwnedSlice(allocator),
    };
}

pub fn buildBuiltinIndexInput(
    allocator: std.mem.Allocator,
    toolchain_version: ?[]const u8,
    active_source_path: ?[]const u8,
    active_source: ?[]const u8,
) !BuiltinIndexInput {
    const owned_version = if (toolchain_version) |version| try allocator.dupe(u8, version) else null;
    errdefer if (owned_version) |version| allocator.free(version);
    const owned_source_path = if (active_source_path) |path| try allocator.dupe(u8, path) else null;
    errdefer if (owned_source_path) |path| allocator.free(path);
    var drift = BuiltinDriftInfo{
        .status = if (owned_version == null) "toolchain_version_unavailable" else "toolchain_builtin_source_unavailable",
        .confidence = if (owned_version == null) "unavailable" else "version_only",
        .active_source_path = owned_source_path,
    };
    if (active_source) |source| {
        try fillBuiltinDrift(allocator, source, &drift);
    }
    return .{
        .toolchain_version = owned_version,
        .owns_toolchain_version = owned_version != null,
        .drift = drift,
        .owns_active_source_path = owned_source_path != null,
    };
}

const max_drift_name_sample = 16;

fn fillBuiltinDrift(allocator: std.mem.Allocator, source: []const u8, drift: *BuiltinDriftInfo) !void {
    const active_names = try parseActiveBuiltinNames(allocator, source);
    defer allocator.free(active_names);
    drift.active_count = active_names.len;
    drift.confidence = "source_backed";
    if (active_names.len == 0) {
        drift.status = "active_builtin_source_parse_failed";
        return;
    }
    var missing: std.ArrayList([]const u8) = .empty;
    var extra: std.ArrayList([]const u8) = .empty;
    errdefer {
        missing.deinit(allocator);
        extra.deinit(allocator);
    }
    for (builtins) |item| {
        if (!nameIn(active_names, item.name)) {
            drift.curated_missing_count += 1;
            if (missing.items.len < max_drift_name_sample) try missing.append(allocator, item.name);
        }
    }
    for (active_names) |name| {
        if (!curatedBuiltinName(name)) {
            drift.active_extra_count += 1;
            if (extra.items.len < max_drift_name_sample) try extra.append(allocator, name);
        }
    }
    drift.missing_names = try missing.toOwnedSlice(allocator);
    drift.extra_names_sample = try extra.toOwnedSlice(allocator);
    drift.status = if (drift.curated_missing_count == 0) "curated_subset_matches_active_builtin_source" else "curated_entries_missing_from_active_builtin_source";
}

fn parseActiveBuiltinNames(allocator: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    const list_start = std.mem.indexOf(u8, source, "pub const list") orelse return allocator.alloc([]const u8, 0);
    const list_end = std.mem.indexOfPos(u8, source, list_start, "});") orelse source.len;
    const list_source = source[list_start..list_end];
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, list_source, pos, "\"@")) |hit| {
        const start = hit + 1;
        const end = std.mem.indexOfScalarPos(u8, list_source, start, '"') orelse break;
        const name = list_source[start..end];
        if (looksLikeBuiltinName(name) and !nameIn(names.items, name)) try names.append(allocator, name);
        pos = end + 1;
    }
    return names.toOwnedSlice(allocator);
}

fn looksLikeBuiltinName(name: []const u8) bool {
    if (name.len < 2 or name[0] != '@') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn curatedBuiltinName(name: []const u8) bool {
    for (builtins) |item| if (std.mem.eql(u8, item.name, name)) return true;
    return false;
}

fn nameIn(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, needle)) return true;
    return false;
}

pub const TextFile = struct {
    path: []const u8,
    source_path: ?[]const u8 = null,
    bytes: []const u8,
};

pub const StdIndexMetadata = struct {
    files_scanned: usize = 0,
    skipped_files: usize = 0,
    walk_errors: usize = 0,
};

pub const StdSourceMatch = struct {
    rank: usize,
    root: []const u8 = "std",
    path: []const u8,
    source_path: []const u8,
    line: usize,
    snippet: []const u8,
    match_kind: []const u8,
    decl_name: ?[]const u8 = null,
    qualified_name: ?[]const u8 = null,
    import_hint: ?[]const u8 = null,
    doc_comments: []const u8,
    doc_comment_count: usize,

    fn deinit(self: StdSourceMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source_path);
        allocator.free(self.snippet);
        if (self.decl_name) |value| allocator.free(value);
        if (self.qualified_name) |value| allocator.free(value);
        if (self.import_hint) |value| allocator.free(value);
        allocator.free(self.doc_comments);
    }
};

pub const StdSearchResult = struct {
    std_dir: []const u8,
    query: []const u8,
    limit: usize,
    total_match_count: usize,
    metadata: StdIndexMetadata,
    matches: []StdSourceMatch,

    pub fn deinit(self: StdSearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.std_dir);
        allocator.free(self.query);
        for (self.matches) |match| match.deinit(allocator);
        allocator.free(self.matches);
    }
};

pub fn stdSearch(allocator: std.mem.Allocator, std_dir: []const u8, query: []const u8, files: []const TextFile, metadata: StdIndexMetadata, limit: usize) !StdSearchResult {
    const normalized_limit = @max(limit, 1);
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);
    var collected: std.ArrayList(StdSourceMatch) = .empty;
    errdefer {
        for (collected.items) |item| item.deinit(allocator);
        collected.deinit(allocator);
    }

    for (files) |file| {
        const lower_contents = try asciiLowerAlloc(allocator, file.bytes);
        defer allocator.free(lower_contents);
        const hit = std.mem.indexOf(u8, lower_contents, lower_query) orelse continue;
        const hit_line = lineAt(file.bytes, hit);
        const parsed_decl = parseDeclaration(hit_line);
        const qualified_name = if (parsed_decl) |decl| try qualifiedNameForDecl(allocator, file.path, decl.name) else null;
        errdefer if (qualified_name) |value| allocator.free(value);
        const doc_comments = if (parsed_decl != null) try docCommentsBefore(allocator, file.bytes, hit) else try allocator.dupe(u8, "");
        errdefer allocator.free(doc_comments);
        try collected.append(allocator, .{
            .rank = 0,
            .path = try allocator.dupe(u8, file.path),
            .source_path = try allocator.dupe(u8, file.source_path orelse file.path),
            .line = lineNumber(file.bytes, hit),
            .snippet = try allocator.dupe(u8, hit_line),
            .match_kind = if (parsed_decl) |decl| decl.kind else "source_line",
            .decl_name = if (parsed_decl) |decl| try allocator.dupe(u8, decl.name) else null,
            .qualified_name = qualified_name,
            .import_hint = if (qualified_name) |name| try allocator.dupe(u8, name) else null,
            .doc_comments = doc_comments,
            .doc_comment_count = countDocCommentLines(doc_comments),
        });
    }
    std.mem.sort(StdSourceMatch, collected.items, {}, stdSourceMatchLessThan);
    const total_match_count = collected.items.len;
    const result_count = @min(collected.items.len, normalized_limit);
    for (collected.items[0..result_count], 0..) |*match, index| match.rank = index + 1;

    const matches = try allocator.alloc(StdSourceMatch, result_count);
    errdefer allocator.free(matches);
    @memcpy(matches, collected.items[0..result_count]);
    if (result_count < collected.items.len) {
        for (collected.items[result_count..]) |item| item.deinit(allocator);
    }
    collected.clearRetainingCapacity();
    return .{
        .std_dir = try allocator.dupe(u8, std_dir),
        .query = try allocator.dupe(u8, query),
        .limit = normalized_limit,
        .total_match_count = total_match_count,
        .metadata = metadata,
        .matches = matches,
    };
}

pub const StdItemMatch = struct {
    rank: usize,
    name: []const u8,
    decl_name: []const u8,
    match_kind: []const u8,
    path: []const u8,
    source_path: []const u8,
    line: usize,
    snippet: []const u8,
    doc_comments: []const u8,
    doc_comment_count: usize,
    preferred_path: bool,
    qualified_name: []const u8,

    fn deinit(self: StdItemMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.decl_name);
        allocator.free(self.path);
        allocator.free(self.source_path);
        allocator.free(self.snippet);
        allocator.free(self.doc_comments);
        allocator.free(self.qualified_name);
    }
};

pub const StdItemResult = struct {
    std_dir: []const u8,
    name: []const u8,
    decl_name: []const u8,
    qualified_path_hint: ?[]const u8,
    limit: usize,
    total_match_count: usize,
    metadata: StdIndexMetadata,
    matches: []StdItemMatch,

    pub fn deinit(self: StdItemResult, allocator: std.mem.Allocator) void {
        allocator.free(self.std_dir);
        allocator.free(self.name);
        allocator.free(self.decl_name);
        if (self.qualified_path_hint) |value| allocator.free(value);
        for (self.matches) |match| match.deinit(allocator);
        allocator.free(self.matches);
    }
};

pub fn stdItem(allocator: std.mem.Allocator, std_dir: []const u8, name: []const u8, files: []const TextFile, metadata: StdIndexMetadata, limit: usize) !StdItemResult {
    const normalized_limit = @max(limit, 1);
    const item_name = lastNameSegment(name);
    const path_hint = try qualifiedStdPathHint(allocator, name);
    errdefer if (path_hint) |value| allocator.free(value);
    const has_item_name = item_name.len > 0;

    var collected: std.ArrayList(StdItemMatch) = .empty;
    errdefer {
        for (collected.items) |item| item.deinit(allocator);
        collected.deinit(allocator);
    }

    if (has_item_name) {
        for (files) |file| {
            var line_no: usize = 1;
            var pending_doc_comments: std.ArrayList(u8) = .empty;
            defer pending_doc_comments.deinit(allocator);
            var pending_doc_comment_count: usize = 0;
            var lines = std.mem.splitScalar(u8, file.bytes, '\n');
            while (lines.next()) |line| : (line_no += 1) {
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (docCommentText(trimmed)) |comment| {
                    if (pending_doc_comments.items.len > 0) try pending_doc_comments.append(allocator, '\n');
                    try pending_doc_comments.appendSlice(allocator, comment);
                    pending_doc_comment_count += 1;
                    continue;
                }
                const kind = declarationKind(line, item_name) orelse {
                    if (trimmed.len != 0) {
                        pending_doc_comments.clearRetainingCapacity();
                        pending_doc_comment_count = 0;
                    }
                    continue;
                };
                try collected.append(allocator, .{
                    .rank = 0,
                    .name = try allocator.dupe(u8, name),
                    .decl_name = try allocator.dupe(u8, item_name),
                    .match_kind = kind,
                    .path = try allocator.dupe(u8, file.path),
                    .source_path = try allocator.dupe(u8, file.source_path orelse file.path),
                    .line = line_no,
                    .snippet = try allocator.dupe(u8, std.mem.trim(u8, line, " \t\r\n")),
                    .doc_comments = try allocator.dupe(u8, pending_doc_comments.items),
                    .doc_comment_count = pending_doc_comment_count,
                    .preferred_path = if (path_hint) |hint| pathMatchesHint(file.path, hint) else false,
                    .qualified_name = try qualifiedNameForDecl(allocator, file.path, item_name),
                });
                pending_doc_comments.clearRetainingCapacity();
                pending_doc_comment_count = 0;
            }
        }
    }
    std.mem.sort(StdItemMatch, collected.items, {}, stdItemMatchLessThan);
    const result_count = @min(collected.items.len, normalized_limit);
    for (collected.items[0..result_count], 0..) |*match, index| match.rank = index + 1;

    const matches = try allocator.alloc(StdItemMatch, result_count);
    errdefer allocator.free(matches);
    @memcpy(matches, collected.items[0..result_count]);
    if (result_count < collected.items.len) {
        for (collected.items[result_count..]) |item| item.deinit(allocator);
    }
    const total_match_count = collected.items.len;
    collected.clearRetainingCapacity();
    return .{
        .std_dir = try allocator.dupe(u8, std_dir),
        .name = try allocator.dupe(u8, name),
        .decl_name = try allocator.dupe(u8, item_name),
        .qualified_path_hint = path_hint,
        .limit = normalized_limit,
        .total_match_count = total_match_count,
        .metadata = metadata,
        .matches = matches,
    };
}

fn stdSourceMatchLessThan(_: void, lhs: StdSourceMatch, rhs: StdSourceMatch) bool {
    const path_order = std.mem.order(u8, lhs.path, rhs.path);
    if (path_order != .eq) return path_order == .lt;
    return lhs.line < rhs.line;
}

fn stdItemMatchLessThan(_: void, lhs: StdItemMatch, rhs: StdItemMatch) bool {
    if (lhs.preferred_path != rhs.preferred_path) return lhs.preferred_path;
    const path_order = std.mem.order(u8, lhs.path, rhs.path);
    if (path_order != .eq) return path_order == .lt;
    return lhs.line < rhs.line;
}

pub const Section = struct {
    title: []const u8,
    anchor: []const u8,
    summary: []const u8,
    body: []const u8,
};

pub const sections = [_]Section{
    .{ .title = "Assignment", .anchor = "Assignment", .summary = "Assignment writes a value to a mutable memory location.", .body = "Use var for mutable local variables and const for immutable bindings. Assignment is not an expression and does not produce a value." },
    .{ .title = "Arrays", .anchor = "Arrays", .summary = "Arrays have a compile-time-known length and element type.", .body = "Array syntax is [N]T. Slices use []T and carry pointer plus length at runtime." },
    .{ .title = "Builtins", .anchor = "Builtin-Functions", .summary = "Builtin functions are compiler-provided operations whose names start with @.", .body = "Examples include @import, @as, @sizeOf, @alignOf, @TypeOf, @compileError, and @panic." },
    .{ .title = "Compile-Time Parameters", .anchor = "comptime", .summary = "comptime marks values and parameters that must be known during semantic analysis.", .body = "comptime enables generic functions, type construction, and compile-time execution. Branches and loops can also execute at comptime when their controlling values are comptime-known." },
    .{ .title = "Defer", .anchor = "defer", .summary = "defer schedules an expression to run when control leaves the current scope.", .body = "Deferred expressions run in reverse order. errdefer runs only when the scope exits with an error and is commonly used for cleanup after partial initialization." },
    .{ .title = "Enums", .anchor = "enum", .summary = "Enums define a set of named values with an optional integer tag type.", .body = "Use @tagName to get the current tag name. Extern and packed enum layout have ABI and storage implications." },
    .{ .title = "Error Sets", .anchor = "Error-Set-Type", .summary = "Error sets describe named error values.", .body = "Error unions combine an error set with a payload type using E!T. Use try, catch, if, and switch to handle or propagate errors." },
    .{ .title = "Functions", .anchor = "Functions", .summary = "Functions declare typed parameters and a return type.", .body = "Function bodies are analyzed when referenced. Parameters can be comptime-known, noalias, or ordinary runtime values." },
    .{ .title = "If", .anchor = "if", .summary = "if selects between branches using a boolean condition.", .body = "if can unwrap optionals and error unions. if expressions require compatible branch result types when used as a value." },
    .{ .title = "Optionals", .anchor = "Optional-Type", .summary = "Optional types represent either null or a payload value.", .body = "Optional syntax is ?T. Use if optional capture, orelse, or.? to handle nullable values explicitly." },
    .{ .title = "Pointers", .anchor = "Pointers", .summary = "Pointers reference memory and carry mutability, alignment, sentinel, and address-space information.", .body = "Single-item pointers use *T, many-item pointers use [*]T, and slices use []T. Pointer casts require explicit builtins and should preserve alignment and const rules." },
    .{ .title = "Slices", .anchor = "Slices", .summary = "Slices are runtime views over contiguous memory.", .body = "A slice stores a pointer and a length. Sentinel-terminated slices carry a known sentinel value after the final element." },
    .{ .title = "Structs", .anchor = "struct", .summary = "Structs group named fields and declarations.", .body = "Struct declarations can contain fields, methods, comptime declarations, and nested types. Layout defaults to Zig-defined unless extern or packed is requested." },
    .{ .title = "Switch", .anchor = "switch", .summary = "switch performs exhaustive selection over values.", .body = "Switch is commonly used with enums, tagged unions, integers, and error sets. Exhaustive handling is required unless an else branch is present." },
    .{ .title = "Tests", .anchor = "Zig-Test", .summary = "test declarations define code executed by zig test.", .body = "Use std.testing helpers for expectations and allocations. Test declarations are discovered by the test runner when their containing file is analyzed." },
    .{ .title = "Undefined", .anchor = "undefined", .summary = "undefined leaves a value uninitialized.", .body = "Reading undefined memory is illegal behavior. It is useful only when every byte will be initialized before the value is observed." },
    .{ .title = "Unions", .anchor = "union", .summary = "Unions store one field at a time, optionally with a tag.", .body = "Tagged unions combine a union payload with an enum tag and work naturally with switch." },
    .{ .title = "While", .anchor = "while", .summary = "while repeats a body while a condition holds.", .body = "while supports continue expressions, optional captures, error-union captures, and else clauses for natural completion." },
};

pub const langref_candidates = [_][]const u8{
    "doc/langref.html",
    "doc/langref.html.in",
    "docs/langref.html",
    "docs/langref.html.in",
    "langref.html",
    "docs/index.html",
};

pub const LangrefProbe = struct {
    path: ?[]const u8 = null,
    candidates_checked: usize = 0,
    rejected_candidates: usize = 0,
    unreadable_candidates: usize = 0,

    pub fn skippedCandidates(self: LangrefProbe) usize {
        return self.rejected_candidates + self.unreadable_candidates;
    }
};

pub fn looksLikeLangref(rel_path: []const u8, bytes: []const u8) bool {
    if (std.mem.eql(u8, rel_path, "docs/index.html")) return false;
    if (std.mem.indexOf(u8, bytes, "Language Reference") != null or
        std.mem.indexOf(u8, bytes, "Zig Language Reference") != null)
    {
        return true;
    }
    if (std.mem.indexOf(u8, rel_path, "langref") == null) return false;
    return std.mem.indexOf(u8, bytes, "Zig") != null or std.mem.indexOf(u8, bytes, "zig") != null;
}

pub const BundledFallbackMetadata = struct {
    installed_doc_available: bool = false,
    candidate_count: usize = 0,
    skipped_candidate_count: usize = 0,
    rejected_candidate_count: usize = 0,
    unreadable_candidate_count: usize = 0,
    parse_failure_count: usize = 0,
    fallback_reason: []const u8 = "installed_langref_not_found",
};

pub const LangrefIndexMetadata = struct {
    strategy: []const u8,
    source_path: ?[]const u8 = null,
    indexed_sections: usize,
    heading_count: usize = 0,
    skipped_heading_count: usize = 0,
    installed_doc_available: bool,
    candidate_count: usize = 0,
    skipped_candidate_count: usize = 0,
    rejected_candidate_count: usize = 0,
    unreadable_candidate_count: usize = 0,
    parse_failure_count: usize = 0,
    fallback_reason: ?[]const u8 = null,
};

pub const LangrefMatch = struct {
    rank: usize,
    title: []const u8,
    anchor: []const u8,
    summary: []const u8,
    body: ?[]const u8 = null,
    snippet: ?[]const u8 = null,
    match_pass: []const u8,
    source_path: ?[]const u8 = null,

    fn deinit(self: LangrefMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.anchor);
        allocator.free(self.summary);
        if (self.body) |value| allocator.free(value);
        if (self.snippet) |value| allocator.free(value);
        if (self.source_path) |value| allocator.free(value);
    }
};

pub const LangrefSearchResult = struct {
    query: []const u8,
    limit: usize,
    source: Source,
    metadata: LangrefIndexMetadata,
    matches: []LangrefMatch,

    pub fn deinit(self: LangrefSearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
        if (self.source.path) |path| allocator.free(path);
        if (self.metadata.source_path) |path| allocator.free(path);
        for (self.matches) |match| match.deinit(allocator);
        allocator.free(self.matches);
    }
};

pub fn langrefBundled(allocator: std.mem.Allocator, query: []const u8, limit: usize, fallback: BundledFallbackMetadata) !LangrefSearchResult {
    const normalized_limit = @max(limit, 1);
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);

    var matches: std.ArrayList(LangrefMatch) = .empty;
    errdefer {
        for (matches.items) |match| match.deinit(allocator);
        matches.deinit(allocator);
    }
    _ = try appendBundledMatches(allocator, &matches, lower_query, normalized_limit, .title);
    if (matches.items.len < normalized_limit) {
        _ = try appendBundledMatches(allocator, &matches, lower_query, normalized_limit - matches.items.len, .body);
    }

    return .{
        .query = try allocator.dupe(u8, query),
        .limit = normalized_limit,
        .source = bundledLangrefSource(),
        .metadata = .{
            .strategy = "bundled_curated_langref_index",
            .indexed_sections = sections.len,
            .installed_doc_available = fallback.installed_doc_available,
            .candidate_count = fallback.candidate_count,
            .skipped_candidate_count = fallback.skipped_candidate_count,
            .rejected_candidate_count = fallback.rejected_candidate_count,
            .unreadable_candidate_count = fallback.unreadable_candidate_count,
            .parse_failure_count = fallback.parse_failure_count,
            .fallback_reason = fallback.fallback_reason,
        },
        .matches = try matches.toOwnedSlice(allocator),
    };
}

pub fn langrefInstalled(allocator: std.mem.Allocator, path: []const u8, html: []const u8, query: []const u8, limit: usize, probe: LangrefProbe) !LangrefSearchResult {
    const normalized_limit = @max(limit, 1);
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);

    var matches: std.ArrayList(LangrefMatch) = .empty;
    errdefer {
        for (matches.items) |match| match.deinit(allocator);
        matches.deinit(allocator);
    }
    var heading_count: usize = 0;
    var skipped_heading_count: usize = 0;
    var pos: usize = 0;
    while (true) {
        const heading = nextHeading(html, pos) orelse break;
        heading_count += 1;
        pos = heading.end;
        const next = nextHeading(html, pos);
        const section_end = if (next) |n| n.start else html.len;
        const section_html = html[heading.start..section_end];
        const text = try stripHtmlAlloc(allocator, section_html);
        defer allocator.free(text);
        const stripped_title = try stripHtmlAlloc(allocator, heading.title_html);
        defer allocator.free(stripped_title);
        const title = std.mem.trim(u8, stripped_title, " \t\r\n");
        if (title.len == 0 or heading.anchor.len == 0) {
            skipped_heading_count += 1;
            continue;
        }
        const lower_text = try asciiLowerAlloc(allocator, text);
        defer allocator.free(lower_text);
        if (std.mem.indexOf(u8, lower_text, lower_query) == null) continue;
        if (matches.items.len >= normalized_limit) continue;
        const snippet = snippetForQuery(text, lower_text, lower_query);
        const summary = boundedSummary(text);
        try matches.append(allocator, .{
            .rank = matches.items.len + 1,
            .title = try allocator.dupe(u8, title),
            .anchor = try allocator.dupe(u8, heading.anchor),
            .summary = try allocator.dupe(u8, summary),
            .snippet = try allocator.dupe(u8, std.mem.trim(u8, snippet, " \t\r\n")),
            .match_pass = "html_section",
            .source_path = try allocator.dupe(u8, path),
        });
    }

    const source_path = try allocator.dupe(u8, path);
    errdefer allocator.free(source_path);
    const metadata_source_path = try allocator.dupe(u8, path);
    errdefer allocator.free(metadata_source_path);
    return .{
        .query = try allocator.dupe(u8, query),
        .limit = normalized_limit,
        .source = installedLangrefSource(source_path, null),
        .metadata = .{
            .strategy = "installed_html_heading_scan",
            .source_path = metadata_source_path,
            .indexed_sections = heading_count - skipped_heading_count,
            .heading_count = heading_count,
            .skipped_heading_count = skipped_heading_count,
            .installed_doc_available = true,
            .candidate_count = probe.candidates_checked,
            .skipped_candidate_count = probe.skippedCandidates(),
            .rejected_candidate_count = probe.rejected_candidates,
            .unreadable_candidate_count = probe.unreadable_candidates,
        },
        .matches = try matches.toOwnedSlice(allocator),
    };
}

const MatchPass = enum { title, body };

fn appendBundledMatches(allocator: std.mem.Allocator, matches: *std.ArrayList(LangrefMatch), lower_query: []const u8, limit: usize, pass: MatchPass) !usize {
    var count: usize = 0;
    for (sections) |section| {
        if (count >= limit) break;
        if (!sectionMatches(section, lower_query, pass)) continue;
        count += 1;
        try matches.append(allocator, .{
            .rank = matches.items.len + 1,
            .title = try allocator.dupe(u8, section.title),
            .anchor = try allocator.dupe(u8, section.anchor),
            .summary = try allocator.dupe(u8, section.summary),
            .body = try allocator.dupe(u8, section.body),
            .match_pass = @tagName(pass),
        });
    }
    return count;
}

fn sectionMatches(section: Section, lower_query: []const u8, pass: MatchPass) bool {
    const title_hit = containsLowered(section.title, lower_query) or containsLowered(section.anchor, lower_query);
    return switch (pass) {
        .title => title_hit,
        .body => !title_hit and (containsLowered(section.summary, lower_query) or containsLowered(section.body, lower_query)),
    };
}

fn containsLowered(haystack: []const u8, lower_query: []const u8) bool {
    if (lower_query.len == 0) return true;
    if (lower_query.len > haystack.len) return false;
    var start: usize = 0;
    while (start + lower_query.len <= haystack.len) : (start += 1) {
        for (lower_query, 0..) |query_char, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != query_char) break;
        } else return true;
    }
    return false;
}

const HtmlHeading = struct {
    start: usize,
    end: usize,
    anchor: []const u8,
    title_html: []const u8,
};

fn nextHeading(html: []const u8, start_pos: usize) ?HtmlHeading {
    var pos = start_pos;
    while (std.mem.indexOfPos(u8, html, pos, "<h")) |start| {
        if (start + 2 >= html.len or !std.ascii.isDigit(html[start + 2])) {
            pos = start + 2;
            continue;
        }
        const open_end = std.mem.indexOfScalarPos(u8, html, start, '>') orelse return null;
        const close = std.mem.indexOfPos(u8, html, open_end, "</h") orelse return null;
        const close_end = std.mem.indexOfScalarPos(u8, html, close, '>') orelse return null;
        const open_tag = html[start .. open_end + 1];
        const title_html = html[open_end + 1 .. close];
        const anchor = headingAnchor(open_tag, title_html) orelse "";
        return .{
            .start = start,
            .end = close_end + 1,
            .anchor = anchor,
            .title_html = title_html,
        };
    }
    return null;
}

fn headingAnchor(open_tag: []const u8, title_html: []const u8) ?[]const u8 {
    return attrValue(open_tag, "id") orelse
        attrValue(open_tag, "name") orelse
        attrValue(title_html, "id") orelse
        attrValue(title_html, "name") orelse
        anchorHrefFragment(title_html);
}

fn attrValue(text: []const u8, name: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, name) orelse return null;
    var pos = start + name.len;
    while (pos < text.len and std.ascii.isWhitespace(text[pos])) pos += 1;
    if (pos >= text.len or text[pos] != '=') return null;
    pos += 1;
    while (pos < text.len and std.ascii.isWhitespace(text[pos])) pos += 1;
    if (pos >= text.len or (text[pos] != '"' and text[pos] != '\'')) return null;
    const quote = text[pos];
    const value_start = pos + 1;
    const value_end = std.mem.indexOfScalarPos(u8, text, value_start, quote) orelse return null;
    return text[value_start..value_end];
}

fn anchorHrefFragment(text: []const u8) ?[]const u8 {
    const href = attrValue(text, "href") orelse return null;
    if (href.len < 2 or href[0] != '#') return null;
    return href[1..];
}

fn stripHtmlAlloc(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var in_tag = false;
    var i: usize = 0;
    while (i < html.len) : (i += 1) {
        const c = html[i];
        if (c == '<') {
            in_tag = true;
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(allocator, ' ');
            continue;
        }
        if (c == '>') {
            in_tag = false;
            continue;
        }
        if (in_tag) continue;
        if (c == '&') {
            if (consumeEntity(html[i..])) |entity| {
                try out.append(allocator, entity.char);
                i += entity.len - 1;
                continue;
            }
        }
        try out.append(allocator, if (std.ascii.isWhitespace(c)) ' ' else c);
    }
    return out.toOwnedSlice(allocator);
}

const Entity = struct { char: u8, len: usize };

fn consumeEntity(text: []const u8) ?Entity {
    const entities = [_]struct { name: []const u8, char: u8 }{
        .{ .name = "&lt;", .char = '<' },
        .{ .name = "&gt;", .char = '>' },
        .{ .name = "&amp;", .char = '&' },
        .{ .name = "&quot;", .char = '"' },
        .{ .name = "&#39;", .char = '\'' },
    };
    for (entities) |entity| {
        if (std.mem.startsWith(u8, text, entity.name)) return .{ .char = entity.char, .len = entity.name.len };
    }
    return null;
}

fn snippetForQuery(text: []const u8, lower_text: []const u8, lower_query: []const u8) []const u8 {
    const hit = std.mem.indexOf(u8, lower_text, lower_query) orelse return text[0..@min(text.len, 240)];
    var start = hit;
    while (start > 0 and text[start - 1] != '.' and text[start - 1] != '\n') start -= 1;
    var end = hit + lower_query.len;
    while (end < text.len and text[end] != '.' and text[end] != '\n') end += 1;
    if (end < text.len) end += 1;
    if (end - start > 320) end = @min(text.len, start + 320);
    return text[start..end];
}

fn boundedSummary(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return trimmed[0..@min(trimmed.len, 360)];
}

pub const DocsEntry = struct {
    path: []const u8,
    source_family: []const u8,
    bytes: usize,
    first_heading: ?[]const u8 = null,

    fn deinit(self: DocsEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.first_heading) |value| allocator.free(value);
    }
};

pub const DocsMatch = struct {
    path: []const u8,
    source_family: []const u8,
    line: usize,
    snippet: []const u8,
    confidence: []const u8 = "medium",

    fn deinit(self: DocsMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.snippet);
    }
};

pub const DocsIndexResult = struct {
    scope: []const u8,
    files_scanned: usize,
    skipped_files: usize,
    entries: []DocsEntry,

    pub fn deinit(self: DocsIndexResult, allocator: std.mem.Allocator) void {
        allocator.free(self.scope);
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
};

pub const DocsQueryResult = struct {
    query: []const u8,
    scope: []const u8,
    files_scanned: usize,
    skipped_files: usize,
    matches: []DocsMatch,

    pub fn deinit(self: DocsQueryResult, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
        allocator.free(self.scope);
        for (self.matches) |match| match.deinit(allocator);
        allocator.free(self.matches);
    }
};

pub fn docsIndex(allocator: std.mem.Allocator, scope: []const u8, files: []const TextFile, skipped_files: usize, limit: usize) !DocsIndexResult {
    var entries: std.ArrayList(DocsEntry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    const normalized_limit = @max(limit, 1);
    var files_scanned: usize = 0;
    for (files) |file| {
        if (entries.items.len >= normalized_limit) break;
        if (!isDocsScopePath(scope, file.path)) continue;
        files_scanned += 1;
        try entries.append(allocator, try docsEntrySummary(allocator, file.path, file.bytes));
    }
    return .{
        .scope = try allocator.dupe(u8, scope),
        .files_scanned = files_scanned,
        .skipped_files = skipped_files,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

pub fn docsQuery(allocator: std.mem.Allocator, query: []const u8, scope: []const u8, files: []const TextFile, autodoc_text: ?[]const u8, skipped_files: usize, limit: usize) !DocsQueryResult {
    const normalized_limit = @max(limit, 1);
    const lower_query = try asciiLowerAlloc(allocator, query);
    defer allocator.free(lower_query);
    var matches: std.ArrayList(DocsMatch) = .empty;
    errdefer {
        for (matches.items) |match| match.deinit(allocator);
        matches.deinit(allocator);
    }
    var files_scanned: usize = 0;
    for (files) |file| {
        if (matches.items.len >= normalized_limit) break;
        if (!isDocsScopePath(scope, file.path)) continue;
        files_scanned += 1;
        const lower = try asciiLowerAlloc(allocator, file.bytes);
        defer allocator.free(lower);
        const hit = std.mem.indexOf(u8, lower, lower_query) orelse continue;
        try matches.append(allocator, try docsMatch(allocator, file.path, file.bytes, hit, "workspace_text"));
    }
    if (autodoc_text) |text| {
        if (matches.items.len < normalized_limit) {
            const lower_text = try asciiLowerAlloc(allocator, text);
            defer allocator.free(lower_text);
            const hit = std.mem.indexOf(u8, lower_text, lower_query);
            if (hit) |index| try matches.append(allocator, try docsMatch(allocator, "inline_autodoc", text, index, "autodoc"));
        }
    }
    return .{
        .query = try allocator.dupe(u8, query),
        .scope = try allocator.dupe(u8, scope),
        .files_scanned = files_scanned,
        .skipped_files = skipped_files,
        .matches = try matches.toOwnedSlice(allocator),
    };
}

pub fn isDocsScopePath(scope: []const u8, path: []const u8) bool {
    if (std.mem.startsWith(u8, path, ".") or std.mem.indexOf(u8, path, "zig-cache") != null or std.mem.startsWith(u8, path, "zig-out/")) return false;
    const is_md = std.mem.endsWith(u8, path, ".md");
    const is_zig = std.mem.endsWith(u8, path, ".zig");
    if (std.mem.eql(u8, scope, "docs")) return is_md and (std.mem.startsWith(u8, path, "docs/") or std.mem.eql(u8, path, "README.md"));
    if (std.mem.eql(u8, scope, "src")) return is_zig and std.mem.startsWith(u8, path, "src/");
    if (std.mem.eql(u8, scope, "all")) return is_md or is_zig;
    return is_md or (is_zig and std.mem.startsWith(u8, path, "src/"));
}

fn docsEntrySummary(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !DocsEntry {
    return .{
        .path = try allocator.dupe(u8, path),
        .source_family = if (std.mem.endsWith(u8, path, ".zig")) "source_comments" else "project_docs",
        .bytes = bytes.len,
        .first_heading = if (firstMarkdownHeading(bytes)) |heading| try allocator.dupe(u8, heading) else null,
    };
}

pub fn docsMatch(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, hit: usize, source: []const u8) !DocsMatch {
    return .{
        .path = try allocator.dupe(u8, path),
        .source_family = source,
        .line = lineNumber(bytes, hit),
        .snippet = try allocator.dupe(u8, lineAt(bytes, hit)),
    };
}

fn firstMarkdownHeading(bytes: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "#")) return trimmed;
    }
    return null;
}

pub const RawReference = struct {
    source_kind: []const u8,
    path: ?[]const u8 = null,
    bytes: usize,
    sha256: [64]u8,
};

pub fn rawReference(source_kind: []const u8, path: ?[]const u8, bytes: []const u8) RawReference {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{
        .source_kind = source_kind,
        .path = path,
        .bytes = bytes.len,
        .sha256 = std.fmt.bytesToHex(digest, .lower),
    };
}

pub const AutodocEntry = struct {
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    docs: ?[]const u8 = null,
    line: ?usize = null,
    source_family: []const u8,

    fn deinit(self: AutodocEntry, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.path) |value| allocator.free(value);
        if (self.docs) |value| allocator.free(value);
    }
};

pub const AutodocIngestResult = struct {
    raw_reference: RawReference,
    entries: []AutodocEntry,

    pub fn deinit(self: AutodocIngestResult, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
};

pub fn autodocIngest(allocator: std.mem.Allocator, source_kind: []const u8, path: ?[]const u8, bytes: []const u8, limit: usize) !AutodocIngestResult {
    var entries: std.ArrayList(AutodocEntry) = .empty;
    errdefer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    if (std.json.parseFromSlice(std.json.Value, allocator, bytes, .{})) |parsed| {
        defer parsed.deinit();
        try collectJsonDocEntries(allocator, parsed.value, &entries, @max(limit, 1));
    } else |_| {
        try appendTextDocEntries(allocator, &entries, bytes, @max(limit, 1));
    }
    return .{
        .raw_reference = rawReference(source_kind, path, bytes),
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn collectJsonDocEntries(allocator: std.mem.Allocator, value: std.json.Value, entries: *std.ArrayList(AutodocEntry), limit: usize) !void {
    if (entries.items.len >= limit) return;
    switch (value) {
        .object => |obj| {
            if (stringField(obj, "name") != null or stringField(obj, "docs") != null or stringField(obj, "path") != null) {
                try entries.append(allocator, .{
                    .name = if (stringField(obj, "name")) |field_value| try allocator.dupe(u8, field_value) else null,
                    .path = if (stringField(obj, "path")) |field_value| try allocator.dupe(u8, field_value) else null,
                    .docs = if (stringField(obj, "docs") orelse stringField(obj, "doc")) |field_value| try allocator.dupe(u8, field_value) else null,
                    .source_family = "autodoc_json",
                });
            }
            var it = obj.iterator();
            while (it.next()) |field| try collectJsonDocEntries(allocator, field.value_ptr.*, entries, limit);
        },
        .array => |array| for (array.items) |item| try collectJsonDocEntries(allocator, item, entries, limit),
        else => {},
    }
}

fn appendTextDocEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(AutodocEntry), text: []const u8, limit: usize) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (entries.items.len >= limit) break;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        try entries.append(allocator, .{
            .line = line_no,
            .docs = try shortString(allocator, trimmed, 240),
            .source_family = "autodoc_text",
        });
    }
}

pub const SnippetCheck = struct {
    label: []const u8,
    parse_status: []const u8,
    ok: bool,
    parse_error_count: usize,
    confidence: []const u8 = "high",
    source_bytes: usize,

    pub fn deinit(self: SnippetCheck, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
    }
};

pub const DocExampleCheckResult = struct {
    raw_reference: RawReference,
    snippets: []SnippetCheck,
    ok: bool,

    pub fn deinit(self: DocExampleCheckResult, allocator: std.mem.Allocator) void {
        for (self.snippets) |snippet| snippet.deinit(allocator);
        allocator.free(self.snippets);
    }
};

pub fn snippetCheck(allocator: std.mem.Allocator, label: []const u8, content: []const u8) !SnippetCheck {
    const source = try allocator.dupeZ(u8, content);
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer {
        const parsed_source = tree.source;
        tree.deinit(allocator);
        allocator.free(parsed_source);
    }
    return .{
        .label = try allocator.dupe(u8, label),
        .parse_status = if (tree.errors.len == 0) "ok" else "syntax_errors",
        .ok = tree.errors.len == 0,
        .parse_error_count = tree.errors.len,
        .source_bytes = content.len,
    };
}

pub fn docExampleCheck(allocator: std.mem.Allocator, source_kind: []const u8, path: ?[]const u8, bytes: []const u8, limit: usize) !DocExampleCheckResult {
    var snippets: std.ArrayList(SnippetCheck) = .empty;
    errdefer {
        for (snippets.items) |snippet| snippet.deinit(allocator);
        snippets.deinit(allocator);
    }
    try collectFencedZigSnippets(allocator, bytes, &snippets, @max(limit, 1));
    var ok = true;
    for (snippets.items) |snippet| {
        if (!snippet.ok) ok = false;
    }
    return .{
        .raw_reference = rawReference(source_kind, path, bytes),
        .snippets = try snippets.toOwnedSlice(allocator),
        .ok = ok,
    };
}

fn collectFencedZigSnippets(allocator: std.mem.Allocator, text: []const u8, snippets: *std.ArrayList(SnippetCheck), limit: usize) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_zig = false;
    var fence_line: usize = 0;
    var line_no: usize = 1;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (!in_zig) {
                const lang = std.mem.trim(u8, trimmed[3..], " \t");
                in_zig = std.mem.eql(u8, lang, "zig") or std.mem.eql(u8, lang, "zig,no_run");
                if (in_zig) {
                    fence_line = line_no;
                    body.clearRetainingCapacity();
                }
            } else {
                if (snippets.items.len < limit) {
                    const label = try std.fmt.allocPrint(allocator, "fence:{d}", .{fence_line});
                    defer allocator.free(label);
                    try snippets.append(allocator, try snippetCheck(allocator, label, body.items));
                }
                in_zig = false;
                body.clearRetainingCapacity();
            }
            continue;
        }
        if (in_zig) {
            try body.appendSlice(allocator, line);
            try body.append(allocator, '\n');
        }
    }
}

pub const ReadmeCommand = struct {
    line: usize,
    command: []const u8,
    classification: []const u8,

    fn deinit(self: ReadmeCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
    }
};

pub const ReadmeCommandCheckResult = struct {
    raw_reference: RawReference,
    commands: []ReadmeCommand,

    pub fn deinit(self: ReadmeCommandCheckResult, allocator: std.mem.Allocator) void {
        for (self.commands) |command| command.deinit(allocator);
        allocator.free(self.commands);
    }
};

pub fn readmeCommandCheck(allocator: std.mem.Allocator, source_kind: []const u8, path: ?[]const u8, bytes: []const u8, limit: usize) !ReadmeCommandCheckResult {
    var commands: std.ArrayList(ReadmeCommand) = .empty;
    errdefer {
        for (commands.items) |command| command.deinit(allocator);
        commands.deinit(allocator);
    }
    var in_shell = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (commands.items.len >= @max(limit, 1)) break;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            const lang = std.mem.trim(u8, trimmed[3..], " \t");
            if (in_shell) {
                in_shell = false;
            } else {
                in_shell = std.mem.eql(u8, lang, "sh") or std.mem.eql(u8, lang, "shell") or std.mem.eql(u8, lang, "bash") or std.mem.eql(u8, lang, "console");
            }
            continue;
        }
        if (!in_shell and !std.mem.startsWith(u8, trimmed, "zig ")) continue;
        if (!std.mem.startsWith(u8, trimmed, "zig ")) continue;
        try commands.append(allocator, .{
            .line = line_no,
            .command = try allocator.dupe(u8, trimmed),
            .classification = if (std.mem.indexOf(u8, trimmed, "build") != null or std.mem.indexOf(u8, trimmed, "test") != null) "zig_validation_command" else "zig_command",
        });
    }
    return .{
        .raw_reference = rawReference(source_kind, path, bytes),
        .commands = try commands.toOwnedSlice(allocator),
    };
}

fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return switch (obj.get(field) orelse .null) {
        .string => |value| value,
        else => null,
    };
}

fn docCommentText(trimmed_line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, trimmed_line, "///")) return null;
    if (std.mem.startsWith(u8, trimmed_line, "////")) return null;
    return std.mem.trim(u8, trimmed_line[3..], " \t\r\n");
}

fn lastNameSegment(name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (std.mem.lastIndexOfScalar(u8, trimmed, '.')) |dot| return std.mem.trim(u8, trimmed[dot + 1 ..], " \t\r\n");
    return trimmed;
}

fn qualifiedStdPathHint(allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "std.")) return null;
    const last_dot = std.mem.lastIndexOfScalar(u8, trimmed, '.') orelse return null;
    if (last_dot <= "std.".len) return null;
    const qualifier = trimmed["std.".len..last_dot];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (qualifier) |c| {
        try out.append(allocator, if (c == '.') '/' else c);
    }
    try out.appendSlice(allocator, ".zig");
    return try out.toOwnedSlice(allocator);
}

fn pathMatchesHint(path: []const u8, hint: []const u8) bool {
    return std.mem.eql(u8, path, hint) or std.mem.endsWith(u8, path, hint);
}

const ParsedDecl = struct { name: []const u8, kind: []const u8 };

fn declarationKind(line: []const u8, name: []const u8) ?[]const u8 {
    const decl = parseDeclaration(line) orelse return null;
    return if (std.mem.eql(u8, decl.name, name)) decl.kind else null;
}

fn parseDeclaration(line: []const u8) ?ParsedDecl {
    var rest = std.mem.trim(u8, line, " \t");
    if (std.mem.startsWith(u8, rest, "pub ")) rest = rest[4..];
    while (true) {
        if (std.mem.startsWith(u8, rest, "inline ")) rest = rest[7..] else if (std.mem.startsWith(u8, rest, "extern ")) rest = rest[7..] else break;
    }
    const kinds = [_]struct { prefix: []const u8, kind: []const u8 }{
        .{ .prefix = "const ", .kind = "const" },
        .{ .prefix = "fn ", .kind = "fn" },
        .{ .prefix = "var ", .kind = "var" },
    };
    for (kinds) |entry| {
        if (!std.mem.startsWith(u8, rest, entry.prefix)) continue;
        const name_start = entry.prefix.len;
        var name_end = name_start;
        while (name_end < rest.len and isIdentChar(rest[name_end])) name_end += 1;
        if (name_end > name_start) return .{ .name = rest[name_start..name_end], .kind = entry.kind };
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn qualifiedNameForDecl(allocator: std.mem.Allocator, path: []const u8, decl_name: []const u8) ![]const u8 {
    const stem = if (std.mem.endsWith(u8, path, ".zig")) path[0 .. path.len - 4] else path;
    var module: std.ArrayList(u8) = .empty;
    defer module.deinit(allocator);
    try module.appendSlice(allocator, "std");
    if (!std.mem.eql(u8, stem, "std")) {
        try module.append(allocator, '.');
        for (stem) |c| try module.append(allocator, if (c == '/') '.' else c);
    }
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ module.items, decl_name });
}

fn docCommentsBefore(allocator: std.mem.Allocator, text: []const u8, index: usize) ![]const u8 {
    const start = lineStart(text, index);
    var first = start;
    while (first > 0) {
        const prev_end = first - 1;
        const prev_start = lineStart(text, prev_end);
        const trimmed = std.mem.trim(u8, text[prev_start..prev_end], " \t\r\n");
        if (docCommentText(trimmed) == null) break;
        first = prev_start;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (first < start) {
        const end = std.mem.indexOfScalarPos(u8, text, first, '\n') orelse start;
        if (docCommentText(std.mem.trim(u8, text[first..end], " \t\r\n"))) |comment| {
            if (out.items.len > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, comment);
        }
        first = @min(end + 1, start);
    }
    return out.toOwnedSlice(allocator);
}

fn countDocCommentLines(comments: []const u8) usize {
    if (comments.len == 0) return 0;
    var count: usize = 1;
    for (comments) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

fn lineStart(text: []const u8, index: usize) usize {
    var start = @min(index, text.len);
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    return start;
}

pub fn lineNumber(text: []const u8, index: usize) usize {
    var line: usize = 1;
    for (text[0..@min(index, text.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

pub fn lineAt(text: []const u8, index: usize) []const u8 {
    var start = @min(index, text.len);
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    var end = @min(index, text.len);
    while (end < text.len and text[end] != '\n') end += 1;
    return std.mem.trim(u8, text[start..end], " \t\r\n");
}

fn shortString(allocator: std.mem.Allocator, input: []const u8, limit: usize) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len <= limit) return allocator.dupe(u8, trimmed);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, trimmed[0..limit]);
    try out.appendSlice(allocator, "...");
    return out.toOwnedSlice(allocator);
}

fn asciiLowerAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

test "builtin drift parser compares curated names with offline BuiltinFn source" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "pub const list = list: { break :list std.StaticStringMap(BuiltinFn).initComptime([_]struct { []const u8, BuiltinFn }{\n");
    for (builtins) |item| try source.print(allocator, ".{{ \"{s}\", .{{ .param_count = 1 }} }},\n", .{item.name});
    try source.appendSlice(allocator, ".{ \"@newBuiltin\", .{ .param_count = 0 } },\n}); };\n");

    const input = try buildBuiltinIndexInput(allocator, "0.16.0", "/zig/std/zig/BuiltinFn.zig", source.items);
    const drift = input.drift.?;
    defer deinitBuiltinIndexInput(input, allocator);

    try std.testing.expectEqualStrings("curated_subset_matches_active_builtin_source", drift.status);
    try std.testing.expectEqualStrings("source_backed", drift.confidence);
    try std.testing.expectEqual(@as(usize, builtins.len + 1), drift.active_count);
    try std.testing.expectEqual(@as(usize, 0), drift.curated_missing_count);
    try std.testing.expectEqual(@as(usize, 1), drift.active_extra_count);
    try std.testing.expectEqualStrings("@newBuiltin", drift.extra_names_sample[0]);
}

test "docs snippet checks report syntax status without execution" {
    const allocator = std.testing.allocator;
    var examples = try docExampleCheck(allocator, "inline_content", null,
        \\```zig
        \\pub fn ok() void {}
        \\```
    , 10);
    defer examples.deinit(allocator);
    try std.testing.expect(examples.ok);
    try std.testing.expectEqual(@as(usize, 1), examples.snippets.len);

    const bad = try snippetCheck(allocator, "bad", "pub fn bad() void { const x = ; _ = x; }");
    defer bad.deinit(allocator);
    try std.testing.expect(!bad.ok);
    try std.testing.expectEqualStrings("syntax_errors", bad.parse_status);
}
