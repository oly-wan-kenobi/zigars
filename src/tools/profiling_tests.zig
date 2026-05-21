const std = @import("std");
const builtin = @import("builtin");
const zigar = @import("zigar");
const common = @import("common.zig");
const profiling = @import("profiling.zig");

const backend_contracts = zigar.backend_contracts;
const json_result = zigar.json_result;
const App = common.App;
const profilePlanValue = profiling.profilePlanValue;
const zigFlamegraph = profiling.zigFlamegraph;
const zigFlamegraphDiff = profiling.zigFlamegraphDiff;

test "profile plan returns structured external capture plans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var args = std.json.ObjectMap.empty;
    try args.put(arena.allocator(), "binary", .{ .string = "zig-out/bin/demo" });
    try args.put(arena.allocator(), "platform", .{ .string = "linux" });
    try args.put(arena.allocator(), "output_prefix", .{ .string = ".zigar-cache/profile/demo" });

    const value = try profilePlanValue(arena.allocator(), .{ .object = args });
    const root = value.object;
    try std.testing.expectEqualStrings("zig_profile_plan", root.get("kind").?.string);
    try std.testing.expectEqualStrings("linux", root.get("selected_platform").?.string);
    try std.testing.expect(std.mem.indexOf(u8, root.get("capture_semantics").?.string, "does not execute or define") != null);
    try std.testing.expectEqual(@as(usize, 6), root.get("plans").?.array.items.len);
    try std.testing.expectEqual(@as(usize, backend_contracts.zflame_format_names.len), root.get("supported_zflame_formats").?.array.items.len);
    try std.testing.expectEqualStrings("linux_perf", root.get("recommended_plan_ids").?.array.items[0].string);
    try std.testing.expectEqualStrings("diff-folded", root.get("diff_workflow").?.object.get("canonical_diff_backend").?.string);
    try std.testing.expectEqualStrings("zflame recursive", root.get("diff_workflow").?.object.get("canonical_renderer").?.string);

    const perf = root.get("plans").?.array.items[0].object;
    try std.testing.expectEqualStrings("linux_perf", perf.get("id").?.string);
    try std.testing.expectEqualStrings("perf", perf.get("zflame_input_format").?.string);
    try std.testing.expectEqualStrings("zig_flamegraph", perf.get("next_zigar_command").?.object.get("tool").?.string);
    try std.testing.expect(std.mem.indexOf(u8, perf.get("next_zigar_command").?.object.get("command").?.string, "zig_flamegraph") != null);

    const folded = root.get("plans").?.array.items[5].object;
    try std.testing.expectEqualStrings("already_folded_recursive", folded.get("id").?.string);
    try std.testing.expectEqualStrings("recursive", folded.get("zflame_input_format").?.string);
}

const zflame_ok_script =
    \\#!/bin/sh
    \\if [ "$1" = "--help" ]; then echo "fake zflame help"; exit 0; fi
    \\printf '<svg xmlns="http://www.w3.org/2000/svg"><title>%s</title></svg>\n' "$1"
    \\
;

const zflame_non_svg_script =
    \\#!/bin/sh
    \\if [ "$1" = "--help" ]; then echo "fake zflame help"; exit 0; fi
    \\echo "main;not-svg 1"
    \\
;

const diff_ok_script =
    \\#!/bin/sh
    \\if [ "$1" = "--help" ]; then echo "fake diff-folded help"; exit 0; fi
    \\case "$1" in --output=*) out=${1#--output=};; *) echo "missing output" >&2; exit 2;; esac
    \\mkdir -p "$(dirname "$out")"
    \\printf 'main;delta 2\n' > "$out"
    \\
;

const diff_empty_script =
    \\#!/bin/sh
    \\case "$1" in --output=*) out=${1#--output=};; *) echo "missing output" >&2; exit 2;; esac
    \\mkdir -p "$(dirname "$out")"
    \\: > "$out"
    \\
;

const diff_fail_script =
    \\#!/bin/sh
    \\echo "diff failed" >&2
    \\exit 9
    \\
;

var profiling_test_counter = std.atomic.Value(u64).init(0);

const ProfilingTestEnv = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp_root: []const u8,
    root: []const u8,
    zflame_path: []const u8,
    diff_folded_path: []const u8,
    app: App,

    fn init(allocator: std.mem.Allocator, zflame_script: []const u8, diff_script: []const u8) !ProfilingTestEnv {
        const io = std.testing.io;
        const tmp_id = profiling_test_counter.fetchAdd(1, .monotonic);
        const tmp_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/profiling-test-{x}-{d}", .{ std.Thread.getCurrentId(), tmp_id });
        errdefer allocator.free(tmp_root);
        errdefer cleanupProfilingTemp(io, tmp_root);
        const root_rel = try std.fs.path.join(allocator, &.{ tmp_root, "root" });
        defer allocator.free(root_rel);
        const bin_rel = try std.fs.path.join(allocator, &.{ root_rel, "bin" });
        defer allocator.free(bin_rel);
        try std.Io.Dir.cwd().createDirPath(io, bin_rel);
        try writeFixtureFile(io, allocator, root_rel, "stacks.folded", "main;work 7\n");
        try writeFixtureFile(io, allocator, root_rel, "before.folded", "main;old 3\n");
        try writeFixtureFile(io, allocator, root_rel, "after.folded", "main;new 5\n");

        const rel_base = tmp_root;
        const base_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
        defer allocator.free(base_z);
        const root = try std.fs.path.join(allocator, &.{ base_z[0..], "root" });
        errdefer allocator.free(root);
        const zflame_path = try std.fs.path.join(allocator, &.{ root, "bin", "zflame-fixture" });
        errdefer allocator.free(zflame_path);
        const diff_folded_path = try std.fs.path.join(allocator, &.{ root, "bin", "diff-folded-fixture" });
        errdefer allocator.free(diff_folded_path);
        try writeExecutableFile(io, zflame_path, zflame_script);
        try writeExecutableFile(io, diff_folded_path, diff_script);

        var config = try zigar.config.parse(allocator, io, &.{
            "zigar",
            "--workspace",
            root,
            "--zflame-path",
            zflame_path,
            "--diff-folded-path",
            diff_folded_path,
            "--timeout-ms",
            "5000",
        });
        errdefer config.deinit(allocator);
        var workspace = try zigar.workspace.Workspace.init(allocator, io, root, null);
        errdefer workspace.deinit();
        return .{
            .allocator = allocator,
            .io = io,
            .tmp_root = tmp_root,
            .root = root,
            .zflame_path = zflame_path,
            .diff_folded_path = diff_folded_path,
            .app = .{ .allocator = allocator, .io = io, .config = config, .workspace = workspace },
        };
    }

    fn deinit(self: *ProfilingTestEnv) void {
        self.app.workspace.deinit();
        self.app.config.deinit(self.allocator);
        self.allocator.free(self.root);
        self.allocator.free(self.zflame_path);
        self.allocator.free(self.diff_folded_path);
        cleanupProfilingTemp(self.io, self.tmp_root);
        self.allocator.free(self.tmp_root);
    }

    fn readWorkspaceFile(self: *ProfilingTestEnv, path: []const u8) ![]u8 {
        return self.app.workspace.readFileAlloc(self.io, path, 1024 * 1024);
    }
};

fn cleanupProfilingTemp(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch |err| {
        std.debug.print("profiling test cleanup failed for {s}: {s}\n", .{ path, @errorName(err) });
    };
}

fn writeFixtureFile(io: std.Io, allocator: std.mem.Allocator, root: []const u8, name: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ root, name });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn writeExecutableFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes, .flags = .{ .permissions = .executable_file } });
}

fn parseArgs(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

test "flamegraph handler writes svg and reports zflame metadata" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var env = try ProfilingTestEnv.init(allocator, zflame_ok_script, diff_ok_script);
    defer env.deinit();
    env.app.backend_probe_cache.zflame = .{ .ok = true, .status = "ok", .resolution = "cached zflame probe" };

    const args = try parseArgs(allocator, "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\",\"title\":\"fixture\",\"subtitle\":\"unit\",\"colors\":\"hot\",\"width\":1200,\"min_width\":5,\"hash\":true}");
    defer args.deinit();
    const result = try zigFlamegraph(&env.app, allocator, args.value);
    defer json_result.deinitToolResult(allocator, result);

    try std.testing.expect(!result.is_error);
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zig_flamegraph", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("zflame", obj.get("backend").?.string);
    try std.testing.expectEqualStrings("recursive", obj.get("format").?.string);
    try std.testing.expectEqualStrings("recursive", obj.get("input_format").?.string);
    try std.testing.expect(obj.get("bytes").?.integer > 0);
    try std.testing.expectEqual(@as(usize, 64), obj.get("sha256").?.string.len);
    try std.testing.expectEqualStrings(env.zflame_path, obj.get("backend_executable_path").?.string);
    try std.testing.expectEqualStrings("rendered_ok", obj.get("compatibility_status").?.string);
    try std.testing.expectEqualStrings("rendered_ok", obj.get("backend_metadata").?.object.get("compatibility_status").?.string);
    try std.testing.expectEqualStrings("probe_ok", obj.get("backend_metadata").?.object.get("probe_status").?.string);
    try std.testing.expectEqualStrings("recursive", obj.get("argv").?.array.items[1].string);
    try std.testing.expectEqualStrings("--title=fixture", obj.get("argv").?.array.items[2].string);
    try std.testing.expectEqualStrings("--hash", obj.get("argv").?.array.items[7].string);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("argv_shape").?.string, "zflame") != null);
    try std.testing.expect(obj.get("warnings").?.array.items.len >= 1);

    const svg = try env.readWorkspaceFile("profile.svg");
    defer allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
}

test "flamegraph diff handler reports diff-folded metadata and rendered svg" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var env = try ProfilingTestEnv.init(allocator, zflame_ok_script, diff_ok_script);
    defer env.deinit();
    env.app.backend_probe_cache.diff_folded = .{ .ok = true, .status = "ok", .resolution = "cached diff-folded probe" };

    const args = try parseArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"intermediate\":\"profile/delta.folded\",\"title\":\"diff fixture\"}");
    defer args.deinit();
    const result = try zigFlamegraphDiff(&env.app, allocator, args.value);
    defer json_result.deinitToolResult(allocator, result);

    try std.testing.expect(!result.is_error);
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zig_flamegraph_diff", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("diff-folded", obj.get("diff_backend").?.string);
    try std.testing.expectEqualStrings("profile/delta.folded", obj.get("intermediate").?.string);
    try std.testing.expect(obj.get("intermediate_bytes").?.integer > 0);
    try std.testing.expectEqual(@as(usize, 64), obj.get("sha256").?.string.len);
    try std.testing.expectEqual(@as(usize, 64), obj.get("intermediate_sha256").?.string.len);
    try std.testing.expectEqualStrings("recursive", obj.get("argv").?.array.items[1].string);

    const folded_meta = obj.get("intermediate_folded").?.object;
    try std.testing.expectEqualStrings("diff-folded", folded_meta.get("backend").?.string);
    try std.testing.expectEqual(@as(usize, 64), folded_meta.get("sha256").?.string.len);
    try std.testing.expectEqualStrings("diff_written_and_read_ok", folded_meta.get("compatibility_status").?.string);
    try std.testing.expectEqualStrings("diff_written_and_read_ok", folded_meta.get("backend_metadata").?.object.get("compatibility_status").?.string);
    try std.testing.expectEqualStrings("probe_ok", folded_meta.get("backend_metadata").?.object.get("probe_status").?.string);
    try std.testing.expectEqualStrings(env.diff_folded_path, folded_meta.get("argv").?.array.items[0].string);
    try std.testing.expect(std.mem.indexOf(u8, folded_meta.get("argv_shape").?.string, "diff-folded") != null);

    const svg = try env.readWorkspaceFile("diff.svg");
    defer allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    const folded = try env.readWorkspaceFile("profile/delta.folded");
    defer allocator.free(folded);
    try std.testing.expectEqualStrings("main;delta 2", std.mem.trim(u8, folded, " \t\r\n"));
}

test "profiling handlers return structured argument and input errors" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var env = try ProfilingTestEnv.init(allocator, zflame_ok_script, diff_ok_script);
    defer env.deinit();

    const missing_input_args = try parseArgs(allocator, "{\"format\":\"recursive\",\"output\":\"profile.svg\"}");
    defer missing_input_args.deinit();
    const missing_input = try zigFlamegraph(&env.app, allocator, missing_input_args.value);
    defer json_result.deinitToolResult(allocator, missing_input);
    try std.testing.expect(missing_input.is_error);
    try std.testing.expectEqualStrings("argument_error", missing_input.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("missing_required_argument", missing_input.structuredContent.?.object.get("code").?.string);
    try std.testing.expectEqualStrings("input", missing_input.structuredContent.?.object.get("field").?.string);

    const guess_args = try parseArgs(allocator, "{\"format\":\"guess\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\"}");
    defer guess_args.deinit();
    const guess = try zigFlamegraph(&env.app, allocator, guess_args.value);
    defer json_result.deinitToolResult(allocator, guess);
    try std.testing.expect(guess.is_error);
    try std.testing.expectEqualStrings("invalid_argument", guess.structuredContent.?.object.get("code").?.string);
    try std.testing.expectEqualStrings("format", guess.structuredContent.?.object.get("field").?.string);
    try std.testing.expectEqualStrings("guess", guess.structuredContent.?.object.get("actual").?.string);

    const width_args = try parseArgs(allocator, "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\",\"width\":0}");
    defer width_args.deinit();
    const width = try zigFlamegraph(&env.app, allocator, width_args.value);
    defer json_result.deinitToolResult(allocator, width);
    try std.testing.expect(width.is_error);
    try std.testing.expectEqualStrings("width", width.structuredContent.?.object.get("field").?.string);

    const missing_file_args = try parseArgs(allocator, "{\"format\":\"recursive\",\"input\":\"missing.folded\",\"output\":\"profile.svg\"}");
    defer missing_file_args.deinit();
    const missing_file = try zigFlamegraph(&env.app, allocator, missing_file_args.value);
    defer json_result.deinitToolResult(allocator, missing_file);
    try std.testing.expect(missing_file.is_error);
    try std.testing.expectEqualStrings("workspace_input_read_failed", missing_file.structuredContent.?.object.get("code").?.string);
    try std.testing.expectEqualStrings("read_workspace_input", missing_file.structuredContent.?.object.get("phase").?.string);
}

test "flamegraph handler rejects non-svg backend output" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var env = try ProfilingTestEnv.init(allocator, zflame_non_svg_script, diff_ok_script);
    defer env.deinit();

    const args = try parseArgs(allocator, "{\"format\":\"recursive\",\"input\":\"stacks.folded\",\"output\":\"profile.svg\"}");
    defer args.deinit();
    const result = try zigFlamegraph(&env.app, allocator, args.value);
    defer json_result.deinitToolResult(allocator, result);

    try std.testing.expect(result.is_error);
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("backend_output_malformed", obj.get("code").?.string);
    try std.testing.expectEqualStrings("validate_svg", obj.get("phase").?.string);
    try std.testing.expectEqualStrings("zflame", obj.get("backend").?.string);
    try std.testing.expectEqualStrings("recursive", obj.get("format").?.string);
}

test "flamegraph diff reports empty and nonzero diff-folded outputs" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var empty_env = try ProfilingTestEnv.init(allocator, zflame_ok_script, diff_empty_script);
    defer empty_env.deinit();
    const empty_args = try parseArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\",\"intermediate\":\"profile/empty.folded\"}");
    defer empty_args.deinit();
    const empty = try zigFlamegraphDiff(&empty_env.app, allocator, empty_args.value);
    defer json_result.deinitToolResult(allocator, empty);
    try std.testing.expect(empty.is_error);
    try std.testing.expectEqualStrings("backend_output_malformed", empty.structuredContent.?.object.get("code").?.string);
    try std.testing.expectEqualStrings("verify_intermediate_diff", empty.structuredContent.?.object.get("operation").?.string);

    var fail_env = try ProfilingTestEnv.init(allocator, zflame_ok_script, diff_fail_script);
    defer fail_env.deinit();
    const fail_args = try parseArgs(allocator, "{\"before\":\"before.folded\",\"after\":\"after.folded\",\"output\":\"diff.svg\"}");
    defer fail_args.deinit();
    const failed = try zigFlamegraphDiff(&fail_env.app, allocator, fail_args.value);
    defer json_result.deinitToolResult(allocator, failed);
    try std.testing.expect(failed.is_error);
    try std.testing.expectEqualStrings("diff_folded_command_failed", failed.structuredContent.?.object.get("code").?.string);
    try std.testing.expectEqualStrings("run_diff_folded", failed.structuredContent.?.object.get("phase").?.string);
    try std.testing.expectEqualStrings("diff-folded", failed.structuredContent.?.object.get("backend").?.string);
    try std.testing.expectEqual(@as(i64, 9), failed.structuredContent.?.object.get("exit_code").?.integer);
}

test "profiling handlers reject workspace escapes before backend execution" {
    const allocator = std.testing.allocator;
    var config = try zigar.config.parse(allocator, std.testing.io, &.{ "zigar", "--timeout-ms", "1" });
    defer config.deinit(allocator);
    var workspace = try zigar.workspace.Workspace.init(allocator, std.testing.io, ".", null);
    defer workspace.deinit();
    var app = App{ .allocator = allocator, .io = std.testing.io, .config = config, .workspace = workspace };

    const flame_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"format\":\"recursive\",\"input\":\"build.zig\",\"output\":\"../outside.svg\"}", .{});
    defer flame_args.deinit();
    const flame = try zigFlamegraph(&app, allocator, flame_args.value);
    defer json_result.deinitToolResult(allocator, flame);
    try std.testing.expect(flame.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", flame.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("path_outside_workspace", flame.structuredContent.?.object.get("code").?.string);

    const diff_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"before\":\"build.zig\",\"after\":\"build.zig\",\"output\":\".zigar-cache/profile/diff.svg\",\"intermediate\":\"../outside.folded\"}", .{});
    defer diff_args.deinit();
    const diff = try zigFlamegraphDiff(&app, allocator, diff_args.value);
    defer json_result.deinitToolResult(allocator, diff);
    try std.testing.expect(diff.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", diff.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("../outside.folded", diff.structuredContent.?.object.get("path").?.string);

    const diff_output_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"before\":\"build.zig\",\"after\":\"build.zig\",\"output\":\"../outside.svg\"}", .{});
    defer diff_output_args.deinit();
    const diff_output = try zigFlamegraphDiff(&app, allocator, diff_output_args.value);
    defer json_result.deinitToolResult(allocator, diff_output);
    try std.testing.expect(diff_output.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", diff_output.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("../outside.svg", diff_output.structuredContent.?.object.get("path").?.string);
}
