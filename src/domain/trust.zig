const std = @import("std");

const zig_analysis = @import("zig/analysis.zig");

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

pub fn riskLevel(risk: ToolRisk) []const u8 {
    if (risk.writes_source or risk.executes_user_command) return "high";
    if (risk.executes_project_code or risk.writes_artifacts) return "medium";
    if (risk.mutates_lsp_state or risk.executes_backend) return "low";
    return "none";
}

pub fn statusLinePath(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, if (line.len > 3) line[3..] else "", " \t");
    if (std.mem.indexOf(u8, trimmed, " -> ")) |arrow| return trimmed[arrow + " -> ".len ..];
    return trimmed;
}

pub fn quotedValue(line: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const rest = line[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..second];
}

pub fn isGeneratedOrVendored(path: []const u8) bool {
    return zig_analysis.skipWorkspacePath(path);
}

pub fn cleanTreeGateFromStatus(allocator: std.mem.Allocator, workspace_root: []const u8, stdout: []const u8, git_ok: bool, evidence_command: []const u8) !std.json.Value {
    var paths = std.json.Array.init(allocator);
    errdefer paths.deinit();
    var untracked: usize = 0;
    var generated_or_vendored: usize = 0;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const path = statusLinePath(line);
        if (path.len == 0) continue;
        const generated = isGeneratedOrVendored(path);
        if (generated) generated_or_vendored += 1;
        if (std.mem.startsWith(u8, line, "??")) untracked += 1;
        var item = std.json.ObjectMap.empty;
        errdefer item.deinit(allocator);
        try item.put(allocator, "path", .{ .string = try allocator.dupe(u8, path) });
        try item.put(allocator, "status", .{ .string = try allocator.dupe(u8, std.mem.trim(u8, line[0..2], " ")) });
        try item.put(allocator, "generated_or_vendored", .{ .bool = generated });
        try paths.append(.{ .object = item });
    }

    const clean = git_ok and paths.items.len == 0;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_clean_tree_gate" });
    try obj.put(allocator, "ok", .{ .bool = clean });
    try obj.put(allocator, "clean", .{ .bool = clean });
    try obj.put(allocator, "workspace", .{ .string = workspace_root });
    try obj.put(allocator, "changed_count", .{ .integer = @intCast(paths.items.len) });
    try obj.put(allocator, "untracked_count", .{ .integer = @intCast(untracked) });
    try obj.put(allocator, "generated_or_vendored_count", .{ .integer = @intCast(generated_or_vendored) });
    try obj.put(allocator, "changed_paths", .{ .array = paths });
    try obj.put(allocator, "evidence", try evidenceValue(allocator, evidence_command, "git status --porcelain stdout", if (git_ok) "high" else "low"));
    try obj.put(allocator, "resolution", .{ .string = if (clean) "workspace tree is clean according to git status" else "review, commit, stash, or intentionally account for changed paths before release decisions" });
    return .{ .object = obj };
}

pub fn evidenceValue(allocator: std.mem.Allocator, source: []const u8, reference: []const u8, confidence: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "source", .{ .string = source });
    try obj.put(allocator, "reference", .{ .string = reference });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    return .{ .object = obj };
}

pub fn stringArray(allocator: std.mem.Allocator, items: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (items) |item| try array.append(.{ .string = try allocator.dupe(u8, item) });
    return .{ .array = array };
}

test "risk metadata classifies execution and mutation levels" {
    try std.testing.expectEqualStrings("high", riskLevel(.{ .writes_source = true }));
    try std.testing.expectEqualStrings("medium", riskLevel(.{ .writes_artifacts = true }));
    try std.testing.expectEqualStrings("low", riskLevel(.{ .executes_backend = true }));
    try std.testing.expectEqualStrings("none", riskLevel(.{}));
}

test "clean tree gate parses porcelain status with generated path evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try cleanTreeGateFromStatus(arena.allocator(), "/tmp/work", " M src/main.zig\n?? zig-out/bin/app\n", true, "fixture");
    const obj = value.object;
    try std.testing.expectEqualStrings("zigar_clean_tree_gate", obj.get("kind").?.string);
    try std.testing.expect(!obj.get("clean").?.bool);
    try std.testing.expectEqual(@as(i64, 2), obj.get("changed_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("untracked_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), obj.get("generated_or_vendored_count").?.integer);
}
