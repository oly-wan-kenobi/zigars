const std = @import("std");
const zigar = @import("zigar");

const adoption = @import("adoption.zig");
const common = @import("common.zig");

const App = common.App;
const json_result = zigar.json_result;

var adoption_test_counter = std.atomic.Value(u64).init(0);

const AdoptionTest = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp_root: []const u8,
    root: []const u8,
    app: App,

    fn init(allocator: std.mem.Allocator) !AdoptionTest {
        const io = std.testing.io;
        const id = adoption_test_counter.fetchAdd(1, .monotonic);
        const tmp_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/adoption-test-{x}-{d}", .{ std.Thread.getCurrentId(), id });
        errdefer allocator.free(tmp_root);
        errdefer cleanupTemp(io, tmp_root);

        const root_rel = try std.fs.path.join(allocator, &.{ tmp_root, "root" });
        defer allocator.free(root_rel);
        try std.Io.Dir.cwd().createDirPath(io, root_rel);
        try writeFixtureFile(io, allocator, root_rel, "build.zig", "pub fn build(_: *@import(\"std\").Build) void {}\n");
        try writeFixtureFile(io, allocator, root_rel, "src/main.zig", "pub fn main() void {}\n");

        const base = try std.Io.Dir.cwd().realPathFileAlloc(io, tmp_root, allocator);
        defer allocator.free(base);
        const root = try std.fs.path.join(allocator, &.{ base[0..], "root" });
        errdefer allocator.free(root);
        var config = try zigar.config.parse(allocator, io, &.{ "zigar", "--workspace", root, "--zls-path", "/definitely/missing/zls" });
        errdefer config.deinit(allocator);
        var workspace = try zigar.workspace.Workspace.init(allocator, io, root, null);
        errdefer workspace.deinit();
        return .{ .allocator = allocator, .io = io, .tmp_root = tmp_root, .root = root, .app = .{ .allocator = allocator, .io = io, .config = config, .workspace = workspace } };
    }

    fn deinit(self: *AdoptionTest) void {
        self.app.workspace.deinit();
        self.app.config.deinit(self.allocator);
        self.allocator.free(self.root);
        cleanupTemp(self.io, self.tmp_root);
        self.allocator.free(self.tmp_root);
    }

    fn fileExists(self: *AdoptionTest, path: []const u8) bool {
        const resolved = self.app.workspace.resolve(path) catch return false;
        defer self.app.workspace.allocator.free(resolved);
        std.Io.Dir.cwd().access(self.io, resolved, .{}) catch return false;
        return true;
    }
};

fn cleanupTemp(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

fn writeFixtureFile(io: std.Io, allocator: std.mem.Allocator, root: []const u8, rel: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ root, rel });
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn parseArgs(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

test "client config generation is preview apply gated and registers provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = try AdoptionTest.init(allocator);
    defer env.deinit();

    const preview_args = try parseArgs(allocator,
        \\{"client":"codex","kind":"codex-toml","output":".zigar-cache/adoption/codex.toml","apply":false}
    );
    defer preview_args.deinit();
    const preview = try adoption.zigarClientConfigGenerate(&env.app, allocator, preview_args.value);
    defer json_result.deinitToolResult(allocator, preview);
    try std.testing.expect(!preview.structuredContent.?.object.get("applied").?.bool);
    try std.testing.expect(!env.fileExists(".zigar-cache/adoption/codex.toml"));

    const apply_args = try parseArgs(allocator,
        \\{"client":"codex","kind":"codex-toml","output":".zigar-cache/adoption/codex.toml","apply":true}
    );
    defer apply_args.deinit();
    const applied = try adoption.zigarClientConfigGenerate(&env.app, allocator, apply_args.value);
    defer json_result.deinitToolResult(allocator, applied);
    try std.testing.expect(applied.structuredContent.?.object.get("applied").?.bool);
    try std.testing.expect(env.fileExists(".zigar-cache/adoption/codex.toml"));
    try std.testing.expect(env.fileExists(zigar.artifacts.default_registry_path));
    try std.testing.expectEqualStrings("zigar_client_config_generate", applied.structuredContent.?.object.get("provenance").?.object.get("producer").?.string);

    const http_json_args = try parseArgs(allocator,
        \\{"client":"gemini","kind":"gemini-json","transport":"http","output":".zigar-cache/adoption/gemini.json","apply":false}
    );
    defer http_json_args.deinit();
    const http_json = try adoption.zigarClientConfigGenerate(&env.app, allocator, http_json_args.value);
    defer json_result.deinitToolResult(allocator, http_json);
    try std.testing.expectEqualStrings("http", http_json.structuredContent.?.object.get("client_identity").?.object.get("transport").?.string);
    try std.testing.expect(std.mem.indexOf(u8, http_json.structuredContent.?.object.get("content").?.string, "http://127.0.0.1:8080") != null);

    const markdown_args = try parseArgs(allocator,
        \\{"client":"hermes","kind":"markdown","output":".zigar-cache/adoption/client.md","apply":false}
    );
    defer markdown_args.deinit();
    const markdown = try adoption.zigarClientConfigGenerate(&env.app, allocator, markdown_args.value);
    defer json_result.deinitToolResult(allocator, markdown);
    try std.testing.expectEqualStrings("markdown", markdown.structuredContent.?.object.get("generated_config").?.object.get("kind").?.string);
}

test "conformance report only allows claims with passed evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = try AdoptionTest.init(allocator);
    defer env.deinit();

    const args = try parseArgs(allocator,
        \\{"backend":"all","content":"{\"kind\":\"zigar_backend_conformance_report\",\"compatibility_matrix\":[{\"backend\":\"zflame\",\"status\":\"passed\"},{\"backend\":\"zls\",\"status\":\"failed\"}]}"}
    );
    defer args.deinit();
    const result = try adoption.zigarConformanceReport(&env.app, allocator, args.value);
    defer json_result.deinitToolResult(allocator, result);
    const claims = result.structuredContent.?.object.get("report").?.object.get("backend_support_claims").?.array.items;
    try std.testing.expect(claimAllowed(claims, "zflame"));
    try std.testing.expect(!claimAllowed(claims, "zls"));
    try std.testing.expect(!result.structuredContent.?.object.get("applied").?.bool);

    const missing = try adoption.zigarConformanceReport(&env.app, allocator, null);
    defer json_result.deinitToolResult(allocator, missing);
    try std.testing.expect(!missing.structuredContent.?.object.get("report").?.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("missing_evidence", missing.structuredContent.?.object.get("report").?.object.get("status").?.string);

    try writeFixtureFile(env.io, allocator, env.root, ".zigar-cache/backend-conformance/report.json",
        \\{"kind":"zigar_release_readiness_report","backends":{"diff-folded":{"ok":true}}}
    );
    const apply_args = try parseArgs(allocator,
        \\{"backend":"diff-folded","input":".zigar-cache/backend-conformance/report.json","output":".zigar-cache/adoption/report.json","apply":true}
    );
    defer apply_args.deinit();
    const applied = try adoption.zigarConformanceReport(&env.app, allocator, apply_args.value);
    defer json_result.deinitToolResult(allocator, applied);
    try std.testing.expect(applied.structuredContent.?.object.get("applied").?.bool);
    try std.testing.expect(env.fileExists(".zigar-cache/adoption/report.json"));
}

test "smoke plan reports unsupported platform as structured result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = try AdoptionTest.init(allocator);
    defer env.deinit();

    const valid_args = try parseArgs(allocator, "{\"backend\":\"zflame\",\"platform\":\"linux\",\"timeout_ms\":1000}");
    defer valid_args.deinit();
    const valid = try adoption.zigarSmokePlan(&env.app, allocator, valid_args.value);
    defer json_result.deinitToolResult(allocator, valid);
    try std.testing.expectEqualStrings("zigar_smoke_plan", valid.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("backend_verify", valid.structuredContent.?.object.get("scenarios").?.array.items[8].object.get("id").?.string);

    const args = try parseArgs(allocator, "{\"platform\":\"plan9\"}");
    defer args.deinit();
    const result = try adoption.zigarSmokePlan(&env.app, allocator, args.value);
    defer json_result.deinitToolResult(allocator, result);
    const obj = result.structuredContent.?.object;
    try std.testing.expect(!obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("unsupported_platform", obj.get("status").?.string);

    const timeout_args = try parseArgs(allocator, "{\"timeout_ms\":10}");
    defer timeout_args.deinit();
    const timeout = try adoption.zigarSmokePlan(&env.app, allocator, timeout_args.value);
    defer json_result.deinitToolResult(allocator, timeout);
    try std.testing.expectEqualStrings("timeout_budget_too_low", timeout.structuredContent.?.object.get("status").?.string);
}

test "client config output is workspace bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = try AdoptionTest.init(allocator);
    defer env.deinit();

    const args = try parseArgs(allocator, "{\"output\":\"../outside.json\",\"apply\":true}");
    defer args.deinit();
    const result = try adoption.zigarClientConfigGenerate(&env.app, allocator, args.value);
    defer json_result.deinitToolResult(allocator, result);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", result.structuredContent.?.object.get("kind").?.string);

    const bad_client_args = try parseArgs(allocator, "{\"client\":\"unknown\"}");
    defer bad_client_args.deinit();
    const bad_client = try adoption.zigarAdoptionPack(&env.app, allocator, bad_client_args.value);
    defer json_result.deinitToolResult(allocator, bad_client);
    try std.testing.expectEqualStrings("argument_error", bad_client.structuredContent.?.object.get("kind").?.string);
}

test "adoption pack reports catalog and backend status without probing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = try AdoptionTest.init(allocator);
    defer env.deinit();

    const args = try parseArgs(allocator, "{\"client\":\"claude\",\"transport\":\"http\",\"backend\":\"zls\",\"mode\":\"deep\"}");
    defer args.deinit();
    const pack = try adoption.zigarAdoptionPack(&env.app, allocator, args.value);
    defer json_result.deinitToolResult(allocator, pack);
    const obj = pack.structuredContent.?.object;
    try std.testing.expectEqualStrings("zigar_adoption_pack", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("http", obj.get("client_identity").?.object.get("transport").?.string);
    try std.testing.expectEqualStrings("missing_configured_path", obj.get("backend_setup_status").?.array.items[0].object.get("status").?.string);
}

fn claimAllowed(claims: []const std.json.Value, backend: []const u8) bool {
    for (claims) |claim| {
        if (claim != .object) continue;
        const name = claim.object.get("backend") orelse continue;
        if (name != .string or !std.mem.eql(u8, name.string, backend)) continue;
        const allowed = claim.object.get("claim_allowed") orelse return false;
        return allowed == .bool and allowed.bool;
    }
    return false;
}
