const std = @import("std");

/// Stable diagnostic emitted by the build.zig.zon dependency model.
pub const Diagnostic = struct {
    code: []const u8,
    message: []const u8,
    line: usize,

    /// Releases owned diagnostic text.
    pub fn deinit(self: Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
    }
};

/// Source span for a string-valued dependency field.
pub const Field = struct {
    value: []const u8,
    value_start: usize,
    value_end: usize,
};

/// One dependency entry borrowed from the original manifest text.
pub const Dependency = struct {
    name: []const u8,
    line: usize,
    entry_start: usize,
    entry_end: usize,
    body_start: usize,
    body_end: usize,
    url: ?Field = null,
    hash: ?Field = null,
    path: ?Field = null,

    /// Classifies this entry using the fields supported by Zig 0.16 dependency literals.
    pub fn kind(self: Dependency) []const u8 {
        if (self.path != null) return "path";
        if (self.url != null) return "url";
        return "unknown";
    }
};

/// Parsed dependency block model. Entry and field slices borrow `text`.
pub const Model = struct {
    text: []const u8,
    dependencies_start: ?usize = null,
    dependencies_end: ?usize = null,
    entries: []Dependency = &.{},
    diagnostics: []Diagnostic = &.{},

    /// Releases owned slices and diagnostics. The source text is caller-owned.
    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        for (self.diagnostics) |diag| diag.deinit(allocator);
        allocator.free(self.diagnostics);
        self.* = undefined;
    }

    /// Looks up one dependency by exact manifest key.
    pub fn find(self: Model, name: []const u8) ?Dependency {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

/// Error set for text-preserving dependency edits.
pub const EditError = error{
    MissingDependenciesBlock,
    DependencyNotFound,
    DependencyAlreadyExists,
    UnsupportedDependencyShape,
    MissingUrl,
    OutOfMemory,
};

/// Parses the dependency entries from a Zig 0.16 build.zig.zon manifest.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Model {
    var entries: std.ArrayList(Dependency) = .empty;
    errdefer entries.deinit(allocator);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |diag| diag.deinit(allocator);
        diagnostics.deinit(allocator);
    }

    const block = findDependenciesBlock(text) orelse {
        try appendDiagnostic(allocator, &diagnostics, "missing_dependencies", "manifest has no .dependencies = .{ ... } block", 1);
        return .{
            .text = text,
            .entries = try entries.toOwnedSlice(allocator),
            .diagnostics = try diagnostics.toOwnedSlice(allocator),
        };
    };

    var cursor = block.open_brace + 1;
    while (cursor < block.close_brace) {
        cursor = skipSpaceAndComments(text, cursor, block.close_brace);
        if (cursor >= block.close_brace) break;
        if (text[cursor] != '.') {
            cursor += 1;
            continue;
        }

        const line = lineNumber(text, cursor);
        const parsed_name = parseName(text, cursor) orelse {
            try appendDiagnostic(allocator, &diagnostics, "unsupported_dependency_name", "dependency entry uses an unsupported name literal", line);
            cursor += 1;
            continue;
        };
        var after_name = skipHorizontal(text, parsed_name.end, block.close_brace);
        if (after_name >= block.close_brace or text[after_name] != '=') {
            cursor = parsed_name.end;
            continue;
        }
        after_name = skipHorizontal(text, after_name + 1, block.close_brace);
        if (after_name + 1 >= block.close_brace or text[after_name] != '.' or text[after_name + 1] != '{') {
            try appendDiagnostic(allocator, &diagnostics, "unsupported_dependency_value", "dependency entry is not a direct .{ ... } literal", line);
            cursor = parsed_name.end;
            continue;
        }

        const body_open = after_name + 1;
        const body_close = findMatchingBrace(text, body_open) orelse {
            try appendDiagnostic(allocator, &diagnostics, "unterminated_dependency", "dependency entry literal is not closed", line);
            break;
        };
        if (body_close > block.close_brace) {
            try appendDiagnostic(allocator, &diagnostics, "dependency_outside_block", "dependency entry extends past the dependencies block", line);
            break;
        }

        var entry_end = body_close + 1;
        entry_end = skipHorizontal(text, entry_end, text.len);
        if (entry_end < text.len and text[entry_end] == ',') entry_end += 1;
        while (entry_end < text.len and (text[entry_end] == '\r' or text[entry_end] == '\n')) : (entry_end += 1) {}

        const entry_text = text[cursor .. body_close + 1];
        try entries.append(allocator, .{
            .name = parsed_name.value,
            .line = line,
            .entry_start = cursor,
            .entry_end = entry_end,
            .body_start = body_open,
            .body_end = body_close,
            .url = fieldInEntry(text, cursor, entry_text, ".url"),
            .hash = fieldInEntry(text, cursor, entry_text, ".hash"),
            .path = fieldInEntry(text, cursor, entry_text, ".path"),
        });
        cursor = entry_end;
    }

    return .{
        .text = text,
        .dependencies_start = block.open_brace,
        .dependencies_end = block.close_brace,
        .entries = try entries.toOwnedSlice(allocator),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

/// Replaces or inserts the hash field for a URL dependency.
pub fn replaceHash(allocator: std.mem.Allocator, model: Model, name: []const u8, new_hash: []const u8) EditError![]u8 {
    const entry = model.find(name) orelse return error.DependencyNotFound;
    if (entry.url == null or entry.path != null) return error.UnsupportedDependencyShape;
    if (entry.hash) |hash| {
        return replaceRange(allocator, model.text, hash.value_start, hash.value_end, new_hash);
    }
    const insert_at = entry.body_end;
    const indent = try detectFieldIndent(allocator, model.text, entry);
    defer allocator.free(indent);
    const fragment = try std.fmt.allocPrint(allocator, "\n{s}.hash = \"{s}\",", .{ indent, new_hash });
    defer allocator.free(fragment);
    return insertRange(allocator, model.text, insert_at, fragment);
}

/// Adds a direct URL or local path dependency to the dependencies block.
pub fn addDependency(
    allocator: std.mem.Allocator,
    model: Model,
    name: []const u8,
    url: ?[]const u8,
    hash: ?[]const u8,
    path: ?[]const u8,
) EditError![]u8 {
    if (model.dependencies_end == null) return error.MissingDependenciesBlock;
    if (model.find(name) != null) return error.DependencyAlreadyExists;
    if ((url == null and path == null) or (url != null and path != null)) return error.UnsupportedDependencyShape;
    const indent = try detectBlockIndent(allocator, model.text, model.dependencies_end.?);
    defer allocator.free(indent);
    const fragment = if (url) |dep_url|
        try std.fmt.allocPrint(allocator, "\n{s}.{s} = .{{ .url = \"{s}\", .hash = \"{s}\" }},", .{ indent, name, dep_url, hash orelse "" })
    else
        try std.fmt.allocPrint(allocator, "\n{s}.{s} = .{{ .path = \"{s}\" }},", .{ indent, name, path.? });
    defer allocator.free(fragment);
    return insertRange(allocator, model.text, model.dependencies_end.?, fragment);
}

/// Removes one dependency entry from the dependencies block.
pub fn removeDependency(allocator: std.mem.Allocator, model: Model, name: []const u8) EditError![]u8 {
    const entry = model.find(name) orelse return error.DependencyNotFound;
    return replaceRange(allocator, model.text, entry.entry_start, entry.entry_end, "");
}

/// Updates URL and optional hash fields for an existing URL dependency.
pub fn upgradeDependency(allocator: std.mem.Allocator, model: Model, name: []const u8, new_url: []const u8, new_hash: ?[]const u8) EditError![]u8 {
    const entry = model.find(name) orelse return error.DependencyNotFound;
    const url = entry.url orelse return error.MissingUrl;
    if (entry.path != null) return error.UnsupportedDependencyShape;
    var updated = try replaceRange(allocator, model.text, url.value_start, url.value_end, new_url);
    errdefer allocator.free(updated);
    if (new_hash) |hash_value| {
        var reparsed = try parse(allocator, updated);
        defer reparsed.deinit(allocator);
        const with_hash = try replaceHash(allocator, reparsed, name, hash_value);
        allocator.free(updated);
        updated = with_hash;
    }
    return updated;
}

const Block = struct {
    open_brace: usize,
    close_brace: usize,
};

const ParsedName = struct {
    value: []const u8,
    end: usize,
};

fn findDependenciesBlock(text: []const u8) ?Block {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_start, ".dependencies")) |idx| {
        var cursor = idx + ".dependencies".len;
        cursor = skipHorizontal(text, cursor, text.len);
        if (cursor < text.len and text[cursor] == '=') {
            cursor = skipHorizontal(text, cursor + 1, text.len);
            if (cursor + 1 < text.len and text[cursor] == '.' and text[cursor + 1] == '{') {
                const open = cursor + 1;
                if (findMatchingBrace(text, open)) |close| return .{ .open_brace = open, .close_brace = close };
                return null;
            }
        }
        search_start = idx + ".dependencies".len;
    }
    return null;
}

fn parseName(text: []const u8, start: usize) ?ParsedName {
    if (start >= text.len or text[start] != '.') return null;
    if (start + 2 < text.len and text[start + 1] == '@' and text[start + 2] == '"') {
        const value_start = start + 3;
        const value_end = scanStringEnd(text, value_start) orelse return null;
        return .{ .value = text[value_start..value_end], .end = value_end + 1 };
    }
    var end = start + 1;
    while (end < text.len) : (end += 1) {
        const c = text[end];
        if (!std.ascii.isAlphanumeric(c) and c != '_') break;
    }
    if (end == start + 1) return null;
    return .{ .value = text[start + 1 .. end], .end = end };
}

fn fieldInEntry(_: []const u8, entry_start: usize, entry_text: []const u8, field_name: []const u8) ?Field {
    const field_idx = std.mem.indexOf(u8, entry_text, field_name) orelse return null;
    var cursor = field_idx + field_name.len;
    cursor = skipHorizontal(entry_text, cursor, entry_text.len);
    if (cursor >= entry_text.len or entry_text[cursor] != '=') return null;
    cursor = skipHorizontal(entry_text, cursor + 1, entry_text.len);
    if (cursor >= entry_text.len or entry_text[cursor] != '"') return null;
    const value_start_local = cursor + 1;
    const value_end_local = scanStringEnd(entry_text, value_start_local) orelse return null;
    return .{
        .value = entry_text[value_start_local..value_end_local],
        .value_start = entry_start + value_start_local,
        .value_end = entry_start + value_end_local,
    };
}

fn scanStringEnd(text: []const u8, value_start: usize) ?usize {
    var cursor = value_start;
    var escaping = false;
    while (cursor < text.len) : (cursor += 1) {
        const c = text[cursor];
        if (escaping) {
            escaping = false;
            continue;
        }
        if (c == '\\') {
            escaping = true;
            continue;
        }
        if (c == '"') return cursor;
    }
    return null;
}

fn findMatchingBrace(text: []const u8, open: usize) ?usize {
    if (open >= text.len or text[open] != '{') return null;
    var depth: usize = 0;
    var cursor = open;
    var in_string = false;
    var escaping = false;
    while (cursor < text.len) : (cursor += 1) {
        const c = text[cursor];
        if (in_string) {
            if (escaping) {
                escaping = false;
            } else if (c == '\\') {
                escaping = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) return cursor;
        }
    }
    return null;
}

fn skipHorizontal(text: []const u8, start: usize, end: usize) usize {
    var cursor = start;
    while (cursor < end and (text[cursor] == ' ' or text[cursor] == '\t')) : (cursor += 1) {}
    return cursor;
}

fn skipSpaceAndComments(text: []const u8, start: usize, end: usize) usize {
    var cursor = start;
    while (cursor < end) {
        while (cursor < end and std.ascii.isWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor + 1 < end and text[cursor] == '/' and text[cursor + 1] == '/') {
            cursor += 2;
            while (cursor < end and text[cursor] != '\n') : (cursor += 1) {}
            continue;
        }
        break;
    }
    return cursor;
}

fn lineNumber(text: []const u8, offset: usize) usize {
    var line: usize = 1;
    for (text[0..@min(offset, text.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

fn lineStart(text: []const u8, offset: usize) usize {
    var cursor = @min(offset, text.len);
    while (cursor > 0 and text[cursor - 1] != '\n') : (cursor -= 1) {}
    return cursor;
}

fn detectFieldIndent(allocator: std.mem.Allocator, text: []const u8, entry: Dependency) ![]u8 {
    if (entry.url) |field| {
        const start = lineStart(text, field.value_start);
        var end = start;
        while (end < text.len and (text[end] == ' ' or text[end] == '\t')) : (end += 1) {}
        if (end > start) return allocator.dupe(u8, text[start..end]);
    }
    const entry_line = lineStart(text, entry.entry_start);
    var end = entry_line;
    while (end < text.len and (text[end] == ' ' or text[end] == '\t')) : (end += 1) {}
    return std.fmt.allocPrint(allocator, "{s}    ", .{text[entry_line..end]});
}

fn detectBlockIndent(allocator: std.mem.Allocator, text: []const u8, close_brace: usize) ![]u8 {
    const block_line = lineStart(text, close_brace);
    var end = block_line;
    while (end < text.len and (text[end] == ' ' or text[end] == '\t')) : (end += 1) {}
    return std.fmt.allocPrint(allocator, "{s}    ", .{text[block_line..end]});
}

fn replaceRange(allocator: std.mem.Allocator, text: []const u8, start: usize, end: usize, replacement: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(allocator, text.len - (end - start) + replacement.len);
    try out.appendSlice(allocator, text[0..start]);
    try out.appendSlice(allocator, replacement);
    try out.appendSlice(allocator, text[end..]);
    return out.toOwnedSlice(allocator);
}

fn insertRange(allocator: std.mem.Allocator, text: []const u8, at: usize, fragment: []const u8) ![]u8 {
    return replaceRange(allocator, text, at, at, fragment);
}

fn appendDiagnostic(allocator: std.mem.Allocator, diagnostics: *std.ArrayList(Diagnostic), code: []const u8, message: []const u8, line: usize) !void {
    try diagnostics.append(allocator, .{
        .code = try allocator.dupe(u8, code),
        .message = try allocator.dupe(u8, message),
        .line = line,
    });
}
