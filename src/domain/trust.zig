const std = @import("std");

const zig_analysis = @import("zig/analysis.zig");

/// Captures behavior that affects tool safety or side-effect scope.
pub const ToolRisk = struct {
    writes_source: bool = false,
    writes_artifacts: bool = false,
    writes_require_apply: bool = false,
    preview_by_default: bool = false,
    mutates_lsp_state: bool = false,
    executes_project_code: bool = false,
    executes_user_command: bool = false,
    executes_backend: bool = false,
};

/// Maps risk flags to an external policy severity bucket.
pub fn riskLevel(risk: ToolRisk) []const u8 {
    if (risk.writes_source or risk.executes_user_command) return "high";
    if (risk.executes_project_code or risk.writes_artifacts) return "medium";
    if (risk.mutates_lsp_state or risk.executes_backend) return "low";
    return "none";
}

/// Extracts the path segment from a porcelain status line, including rename targets.
pub fn statusLinePath(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, if (line.len > 3) line[3..] else "", " \t");
    if (std.mem.indexOf(u8, trimmed, " -> ")) |arrow| return trimmed[arrow + " -> ".len ..];
    return trimmed;
}

/// Returns the first quoted segment when parsing diagnostic lines.
pub fn quotedValue(line: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const rest = line[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..second];
}

/// Returns whether is generated or vendored is true for the supplied input.
pub fn isGeneratedOrVendored(path: []const u8) bool {
    return zig_analysis.skipWorkspacePath(path);
}

/// Builds clean tree gate from status; allocation failures are returned to the caller.
pub fn cleanTreeGateFromStatus(allocator: std.mem.Allocator, workspace_root: []const u8, stdout: []const u8, git_ok: bool, evidence_command: []const u8) !std.json.Value {
    var paths = std.json.Array.init(allocator);
    var paths_owned = true;
    defer if (paths_owned) deinitOwnedValue(allocator, .{ .array = paths });
    var untracked: usize = 0;
    var generated_or_vendored: usize = 0;

    // Preserve each changed path as evidence so policy decisions are auditable.
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const path = statusLinePath(line);
        if (path.len == 0) continue;
        const generated = isGeneratedOrVendored(path);
        if (generated) generated_or_vendored += 1;
        if (std.mem.startsWith(u8, line, "??")) untracked += 1;
        var item = std.json.ObjectMap.empty;
        var item_owned = true;
        defer if (item_owned) deinitOwnedValue(allocator, .{ .object = item });
        try putOwned(allocator, &item, "path", try ownedString(allocator, path));
        try putOwned(allocator, &item, "status", try ownedString(allocator, std.mem.trim(u8, line[0..2], " ")));
        try putOwned(allocator, &item, "generated_or_vendored", .{ .bool = generated });
        item_owned = false;
        try appendOwned(allocator, &paths, .{ .object = item });
    }

    const clean = git_ok and paths.items.len == 0;
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) deinitOwnedValue(allocator, .{ .object = obj });
    try putOwned(allocator, &obj, "kind", try ownedString(allocator, "zigars_clean_tree_gate"));
    try putOwned(allocator, &obj, "ok", .{ .bool = clean });
    try putOwned(allocator, &obj, "clean", .{ .bool = clean });
    try putOwned(allocator, &obj, "workspace", try ownedString(allocator, workspace_root));
    try putOwned(allocator, &obj, "changed_count", .{ .integer = @intCast(paths.items.len) });
    try putOwned(allocator, &obj, "untracked_count", .{ .integer = @intCast(untracked) });
    try putOwned(allocator, &obj, "generated_or_vendored_count", .{ .integer = @intCast(generated_or_vendored) });
    paths_owned = false;
    try putOwned(allocator, &obj, "changed_paths", .{ .array = paths });
    try putOwned(allocator, &obj, "evidence", try evidenceValue(allocator, evidence_command, "git status --porcelain stdout", if (git_ok) "high" else "low"));
    try putOwned(allocator, &obj, "resolution", try ownedString(allocator, if (clean) "workspace tree is clean according to git status" else "review, commit, stash, or intentionally account for changed paths before release decisions"));
    obj_owned = false;
    return .{ .object = obj };
}

/// Builds a JSON evidence object; allocation failures are returned.
pub fn evidenceValue(allocator: std.mem.Allocator, source: []const u8, reference: []const u8, confidence: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) deinitOwnedValue(allocator, .{ .object = obj });
    try putOwned(allocator, &obj, "source", try ownedString(allocator, source));
    try putOwned(allocator, &obj, "reference", try ownedString(allocator, reference));
    try putOwned(allocator, &obj, "confidence", try ownedString(allocator, confidence));
    obj_owned = false;
    return .{ .object = obj };
}

/// Builds string array; allocation failures are returned to the caller.
pub fn stringArray(allocator: std.mem.Allocator, items: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) deinitOwnedValue(allocator, .{ .array = array });
    for (items) |item| try appendOwned(allocator, &array, try ownedString(allocator, item));
    array_owned = false;
    return .{ .array = array };
}

/// Duplicates bytes into allocator-owned JSON string storage.
fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

/// Frees JSON values produced by this module; object keys are borrowed field names.
pub fn deinitOwnedValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |text| allocator.free(text),
        .array => |array| {
            var mutable = array;
            for (mutable.items) |item| deinitOwnedValue(allocator, item);
            mutable.deinit();
        },
        .object => |object| {
            var mutable = object;
            var it = mutable.iterator();
            while (it.next()) |entry| deinitOwnedValue(allocator, entry.value_ptr.*);
            mutable.deinit(allocator);
        },
        else => {},
    }
}

/// Inserts a value into an object, freeing the value if the object allocation fails.
fn putOwned(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    errdefer deinitOwnedValue(allocator, value);
    try obj.put(allocator, key, value);
}

/// Appends a value into an array, freeing the value if the append allocation fails.
fn appendOwned(allocator: std.mem.Allocator, array: *std.json.Array, value: std.json.Value) !void {
    errdefer deinitOwnedValue(allocator, value);
    try array.append(value);
}
