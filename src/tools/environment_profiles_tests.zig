const std = @import("std");
const zigar = @import("zigar");

const common = @import("common.zig");
const environment_profiles = @import("environment_profiles.zig");

const App = common.App;
const json_result = zigar.json_result;

var env_test_counter = std.atomic.Value(u64).init(0);

const EnvTest = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp_root: []const u8,
    root: []const u8,
    app: App,

    fn init(allocator: std.mem.Allocator) !EnvTest {
        const io = std.testing.io;
        const id = env_test_counter.fetchAdd(1, .monotonic);
        const tmp_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/environment-profile-test-{x}-{d}", .{ std.Thread.getCurrentId(), id });
        errdefer allocator.free(tmp_root);
        errdefer cleanupTemp(io, tmp_root);

        const root_rel = try std.fs.path.join(allocator, &.{ tmp_root, "root" });
        defer allocator.free(root_rel);
        try std.Io.Dir.cwd().createDirPath(io, root_rel);
        try writeFixtureFile(io, allocator, root_rel, "build.zig",
            \\const std = @import("std");
            \\pub fn build(b: *std.Build) void {
            \\    _ = b;
            \\}
            \\
        );
        try writeFixtureFile(io, allocator, root_rel, "build.zig.zon",
            \\.{
            \\    .name = "fixture",
            \\    .version = "0.0.0",
            \\    .minimum_zig_version = "0.16.0",
            \\}
            \\
        );
        try writeFixtureFile(io, allocator, root_rel, "src/main.zig", "pub fn main() void {}\n");

        const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, tmp_root, allocator);
        defer allocator.free(base_z);
        const root = try std.fs.path.join(allocator, &.{ base_z[0..], "root" });
        errdefer allocator.free(root);

        var config = try zigar.config.parse(allocator, io, &.{
            "zigar",
            "--workspace",
            root,
            "--zls-path",
            "/definitely/missing/zls",
            "--timeout-ms",
            "1000",
        });
        errdefer config.deinit(allocator);
        var workspace = try zigar.workspace.Workspace.init(allocator, io, root, null);
        errdefer workspace.deinit();

        return .{
            .allocator = allocator,
            .io = io,
            .tmp_root = tmp_root,
            .root = root,
            .app = .{ .allocator = allocator, .io = io, .config = config, .workspace = workspace },
        };
    }

    fn deinit(self: *EnvTest) void {
        self.app.workspace.deinit();
        self.app.config.deinit(self.allocator);
        self.allocator.free(self.root);
        cleanupTemp(self.io, self.tmp_root);
        self.allocator.free(self.tmp_root);
    }

    fn fileExists(self: *EnvTest, path: []const u8) bool {
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

test "profile v2 bootstrap apply and read expose validation contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = try EnvTest.init(allocator);
    defer env.deinit();

    const preview = try environment_profiles.zigarProjectProfileV2(&env.app, allocator, null);
    defer json_result.deinitToolResult(allocator, preview);
    const preview_obj = preview.structuredContent.?.object;
    try std.testing.expect(!preview_obj.get("applied").?.bool);
    try std.testing.expect(preview_obj.get("requires_apply").?.bool);
    try std.testing.expectEqual(@as(i64, 2), preview_obj.get("profile").?.object.get("schema_version").?.integer);
    try std.testing.expect(preview_obj.get("validation").?.object.get("valid").?.bool);
    try std.testing.expect(!env.fileExists(".zigar/profile.json"));

    var apply_args = std.json.ObjectMap.empty;
    try apply_args.put(allocator, "apply", .{ .bool = true });
    const applied = try environment_profiles.zigarProjectProfileV2(&env.app, allocator, .{ .object = apply_args });
    defer json_result.deinitToolResult(allocator, applied);
    try std.testing.expect(applied.structuredContent.?.object.get("applied").?.bool);
    try std.testing.expect(env.fileExists(".zigar/profile.json"));

    const read = try environment_profiles.zigarProfileRead(&env.app, allocator, null);
    defer json_result.deinitToolResult(allocator, read);
    const read_obj = read.structuredContent.?.object;
    try std.testing.expect(read_obj.get("exists").?.bool);
    try std.testing.expect(read_obj.get("validation").?.object.get("valid").?.bool);
    try std.testing.expectEqualStrings("high", read_obj.get("validation").?.object.get("confidence").?.string);
}

test "profile import rejects invalid v2 content before apply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = try EnvTest.init(allocator);
    defer env.deinit();

    const args = try parseArgs(allocator,
        \\{"content":"{\"schema_version\":1}","apply":true}
    );
    defer args.deinit();
    const result = try environment_profiles.zigarProfileImport(&env.app, allocator, args.value);
    defer json_result.deinitToolResult(allocator, result);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("argument_error", result.structuredContent.?.object.get("kind").?.string);
    try std.testing.expect(!env.fileExists(".zigar/profile.json"));
}

test "environment exports and toolchain pins are apply gated artifacts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = try EnvTest.init(allocator);
    defer env.deinit();

    const preview_args = try parseArgs(allocator,
        \\{"output":".zigar-cache/env/test-pack.json","apply":false,"probe_backends":false,"include_hashes":false}
    );
    defer preview_args.deinit();
    const preview = try environment_profiles.zigarEnvExport(&env.app, allocator, preview_args.value);
    defer json_result.deinitToolResult(allocator, preview);
    try std.testing.expect(!preview.structuredContent.?.object.get("applied").?.bool);
    try std.testing.expect(!env.fileExists(".zigar-cache/env/test-pack.json"));

    const apply_args = try parseArgs(allocator,
        \\{"output":".zigar-cache/env/test-pack.json","apply":true,"probe_backends":false,"include_hashes":false}
    );
    defer apply_args.deinit();
    const exported = try environment_profiles.zigarEnvExport(&env.app, allocator, apply_args.value);
    defer json_result.deinitToolResult(allocator, exported);
    try std.testing.expect(exported.structuredContent.?.object.get("applied").?.bool);
    try std.testing.expect(env.fileExists(".zigar-cache/env/test-pack.json"));
    try std.testing.expect(env.fileExists(".zigar-cache/artifacts/registry.jsonl"));

    const pin_args = try parseArgs(allocator,
        \\{"apply":true,"zig_version":"0.16.0","zls_version":"0.16.0"}
    );
    defer pin_args.deinit();
    const pin = try environment_profiles.zigToolchainPin(&env.app, allocator, pin_args.value);
    defer json_result.deinitToolResult(allocator, pin);
    try std.testing.expect(pin.structuredContent.?.object.get("applied").?.bool);
    try std.testing.expect(env.fileExists(".zigar/toolchain.json"));
}

test "zvm and backend setup tools return inert plans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = try EnvTest.init(allocator);
    defer env.deinit();

    const zvm_args = try parseArgs(allocator, "{\"version\":\"0.16.0\"}");
    defer zvm_args.deinit();
    const install = try environment_profiles.zigarZvmInstallPlan(&env.app, allocator, zvm_args.value);
    defer json_result.deinitToolResult(allocator, install);
    const install_obj = install.structuredContent.?.object;
    try std.testing.expect(install_obj.get("plan_only").?.bool);
    try std.testing.expect(!install_obj.get("mutates_environment").?.bool);
    try std.testing.expectEqualStrings("zvm", install_obj.get("argv").?.array.items[0].string);
    try std.testing.expectEqualStrings("install", install_obj.get("argv").?.array.items[1].string);

    const backend_args = try parseArgs(allocator, "{\"backend\":\"zflame\",\"manager\":\"manual\"}");
    defer backend_args.deinit();
    const plan = try environment_profiles.zigarBackendInstallPlan(&env.app, allocator, backend_args.value);
    defer json_result.deinitToolResult(allocator, plan);
    const plan_obj = plan.structuredContent.?.object;
    try std.testing.expect(plan_obj.get("plan_only").?.bool);
    try std.testing.expect(!plan_obj.get("mutates_environment").?.bool);
    try std.testing.expectEqualStrings("zflame", plan_obj.get("plans").?.array.items[0].object.get("backend").?.string);
}

test "dev environment and backend evidence tools stay preview first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = try EnvTest.init(allocator);
    defer env.deinit();

    const dev_args = try parseArgs(allocator, "{\"kind\":\"mise\",\"apply\":false}");
    defer dev_args.deinit();
    const dev = try environment_profiles.zigarDevEnvGenerate(&env.app, allocator, dev_args.value);
    defer json_result.deinitToolResult(allocator, dev);
    const dev_obj = dev.structuredContent.?.object;
    try std.testing.expect(!dev_obj.get("applied").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, dev_obj.get("content").?.string, "zig") != null);
    try std.testing.expect(!env.fileExists(".zigar-cache/dev-env/mise.toml"));

    const conformance_args = try parseArgs(allocator, "{\"backend\":\"zflame\",\"probe_backends\":false}");
    defer conformance_args.deinit();
    const conformance = try environment_profiles.zigarBackendConformance(&env.app, allocator, conformance_args.value);
    defer json_result.deinitToolResult(allocator, conformance);
    const conformance_obj = conformance.structuredContent.?.object;
    try std.testing.expectEqualStrings("plan_only", conformance_obj.get("run_state").?.string);
    try std.testing.expectEqualStrings("zflame_recursive_folded_svg", conformance_obj.get("scenarios").?.array.items[0].object.get("name").?.string);

    const evidence = try environment_profiles.zigarBackendEvidencePack(&env.app, allocator, null);
    defer json_result.deinitToolResult(allocator, evidence);
    const evidence_obj = evidence.structuredContent.?.object;
    try std.testing.expect(!evidence_obj.get("evidence").?.object.get("available").?.bool);
    try std.testing.expect(!evidence_obj.get("applied").?.bool);
}
