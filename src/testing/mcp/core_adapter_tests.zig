const std = @import("std");

const app_context = @import("../../app/context.zig");
const ports = @import("../../app/ports.zig");
const core_usecase = @import("../../app/usecases/core/zig_commands.zig");
const mcp_core = @import("../../adapters/mcp/tools/core.zig");
const mcp_result = @import("../../adapters/mcp/result.zig");
const fake_command = @import("../fakes/command_runner.zig");
const fake_workspace = @import("../fakes/workspace_store.zig");

test "core adapter renders compile error index text shape" {
    const allocator = std.testing.allocator;
    var args = std.json.ObjectMap.empty;
    defer args.deinit(allocator);
    try args.put(allocator, "text", .{ .string = "src/main.zig:1:2: error: bad\nsrc/main.zig:1:2: note: detail\n" });

    const context = app_context.CoreCommandContext{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .tool_paths = .{ .zig = "zig" },
        .timeouts = .{},
        .zls_state = .{},
        .command_runner = undefined,
        .workspace_store = undefined,
    };

    const result = try mcp_core.zigCompileErrorIndex(allocator, context, .{ .object = args });
    defer mcp_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zig_compile_error_index", obj.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("file_count").?.integer);
}

test "core adapter renders version result through typed ports" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "version" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zig version",
    }, .{ .stdout = "0.16.0\n" });
    try commands.expectRun(.{
        .argv = &.{ "/bin/zls", "--version" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zls version",
    }, .{ .stdout = "0.16.0\n" });

    const result = try mcp_core.zigVersion(allocator, testCoreContext(commands.port(), workspace.port()), null);
    defer mcp_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("0.16.0", obj.get("zig").?.string);
    try std.testing.expectEqualStrings("0.16.0", obj.get("zls").?.string);
    try std.testing.expectEqualStrings("connected", obj.get("zls_status").?.string);
    try commands.verify();
    try workspace.verify();
}

test "core adapter marks zls version unavailable without failing zig version" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "version" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zig version",
    }, .{ .stdout = "0.16.0\n" });
    try commands.expectRunError(.{
        .argv = &.{ "/bin/zls", "--version" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zls version",
    }, error.FileNotFound);

    const result = try mcp_core.zigVersion(allocator, testCoreContext(commands.port(), workspace.port()), null);
    defer mcp_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("unavailable", obj.get("zls").?.string);
    try std.testing.expect(!obj.get("zls_ok").?.bool);
    try commands.verify();
    try workspace.verify();
}

test "core adapter maps zig version backend failure through structured error" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRunError(.{
        .argv = &.{ "/bin/zig", "version" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zig version",
    }, error.FileNotFound);

    const result = try mcp_core.zigVersion(allocator, testCoreContext(commands.port(), workspace.port()), null);
    defer mcp_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("backend_error", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("executable_not_found", obj.get("error_kind").?.string);
    try commands.verify();
    try workspace.verify();
}

test "core adapter renders zig env and targets command wrappers" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "env" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zig env",
    }, .{ .stdout = "{\"zig_exe\":\"/bin/zig\"}\n" });
    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "targets" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zig targets",
    }, .{ .stdout = "{\"arch\":[\"x86_64\"]}\n" });

    const env_result = try mcp_core.zigEnv(allocator, testCoreContext(commands.port(), workspace.port()), null);
    defer mcp_result.deinitToolResult(allocator, env_result);
    try std.testing.expectEqualStrings("zig env", env_result.structuredContent.?.object.get("title").?.string);

    const targets_result = try mcp_core.zigTargets(allocator, testCoreContext(commands.port(), workspace.port()), null);
    defer mcp_result.deinitToolResult(allocator, targets_result);
    try std.testing.expectEqualStrings("zig targets", targets_result.structuredContent.?.object.get("title").?.string);

    try commands.verify();
    try workspace.verify();
}

test "core adapter renders command result diagnostics and stream metadata" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "build", "test", "--summary", "all" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zig build",
    }, .{
        .exit_code = 1,
        .stdout = "\xffok\n",
        .stderr = "src/main.zig:3:5: error: bad\nsrc/main.zig:3:5: note: detail\n",
        .stdout_truncated = true,
        .duration_ms = 9,
    });

    var args = std.json.ObjectMap.empty;
    defer args.deinit(allocator);
    try args.put(allocator, "args", .{ .string = "test --summary all" });
    const result = try mcp_core.zigBuild(allocator, testCoreContext(commands.port(), workspace.port()), .{ .object = args });
    defer mcp_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("command", obj.get("kind").?.string);
    try std.testing.expect(!obj.get("ok").?.bool);
    try std.testing.expect(obj.get("stdout_invalid_utf8").?.bool);
    try std.testing.expect(obj.get("stdout_truncated").?.bool);
    try std.testing.expectEqualStrings("compiler_error", obj.get("diagnostics").?.object.get("category").?.string);
    try commands.verify();
    try workspace.verify();
}

test "core adapter renders command port errors" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRunError(.{
        .argv = &.{ "/bin/zig", "build" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zig build",
    }, error.FileNotFound);

    const result = try mcp_core.zigBuild(allocator, testCoreContext(commands.port(), workspace.port()), null);
    defer mcp_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("command_error", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("FileNotFound", obj.get("error").?.string);
    try std.testing.expectEqualStrings("executable_not_found", obj.get("error_kind").?.string);
    try commands.verify();
    try workspace.verify();
}

test "core adapter marks command output-limit port errors with note" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRunError(.{
        .argv = &.{ "/bin/zig", "build" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zig build",
    }, error.StreamTooLong);

    const result = try mcp_core.zigBuild(allocator, testCoreContext(commands.port(), workspace.port()), null);
    defer mcp_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expect(obj.get("output_limit_exceeded").?.bool);
    try std.testing.expect(obj.get("note") != null);
    try commands.verify();
    try workspace.verify();
}

test "core adapter resolves workspace inputs for test and translate-c" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try workspace.expectResolve(.{ .path = "src/main.zig", .provenance = "zig_test source file" }, "/workspace/src/main.zig");
    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "test", "/workspace/src/main.zig", "--test-filter", "smoke", "--summary", "all" },
        .cwd = "/workspace",
        .timeout_ms = 30_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zig test",
    }, .{ .stdout = "1/1 passed\n" });
    try workspace.expectResolve(.{ .path = "src/main.c", .provenance = "zig_translate_c source file" }, "/workspace/src/main.c");
    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "translate-c", "/workspace/src/main.c", "-Dflag=1" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zig translate-c",
    }, .{ .stdout = "pub extern fn main() c_int;\n" });

    var test_args = std.json.ObjectMap.empty;
    defer test_args.deinit(allocator);
    try test_args.put(allocator, "file", .{ .string = "src/main.zig" });
    try test_args.put(allocator, "filter", .{ .string = "smoke" });
    try test_args.put(allocator, "args", .{ .string = "--summary all" });
    try test_args.put(allocator, "timeout_ms", .{ .integer = 30_000 });
    const test_result = try mcp_core.zigTest(allocator, testCoreContext(commands.port(), workspace.port()), .{ .object = test_args });
    defer mcp_result.deinitToolResult(allocator, test_result);
    try std.testing.expectEqualStrings("zig test", test_result.structuredContent.?.object.get("title").?.string);

    var translate_args = std.json.ObjectMap.empty;
    defer translate_args.deinit(allocator);
    try translate_args.put(allocator, "file", .{ .string = "src/main.c" });
    try translate_args.put(allocator, "args", .{ .string = "-Dflag=1" });
    const translate_result = try mcp_core.zigTranslateC(allocator, testCoreContext(commands.port(), workspace.port()), .{ .object = translate_args });
    defer mcp_result.deinitToolResult(allocator, translate_result);
    try std.testing.expectEqualStrings("zig translate-c", translate_result.structuredContent.?.object.get("title").?.string);

    try commands.verify();
    try workspace.verify();
}

test "core adapter maps argument and workspace errors" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    const missing_check = try mcp_core.zigCheck(allocator, testCoreContext(commands.port(), workspace.port()), null);
    defer mcp_result.deinitToolResult(allocator, missing_check);
    try std.testing.expectEqualStrings("argument_error", missing_check.structuredContent.?.object.get("kind").?.string);

    try workspace.expectResolveError(.{ .path = "../main.zig", .provenance = "zig_check source file" }, error.PathOutsideWorkspace);
    var check_args = std.json.ObjectMap.empty;
    defer check_args.deinit(allocator);
    try check_args.put(allocator, "file", .{ .string = "../main.zig" });
    const workspace_error = try mcp_core.zigCheck(allocator, testCoreContext(commands.port(), workspace.port()), .{ .object = check_args });
    defer mcp_result.deinitToolResult(allocator, workspace_error);
    try std.testing.expectEqualStrings("workspace_path_error", workspace_error.structuredContent.?.object.get("kind").?.string);

    var build_args = std.json.ObjectMap.empty;
    defer build_args.deinit(allocator);
    try build_args.put(allocator, "args", .{ .string = "\"unterminated" });
    const split_error = try mcp_core.zigBuild(allocator, testCoreContext(commands.port(), workspace.port()), .{ .object = build_args });
    defer mcp_result.deinitToolResult(allocator, split_error);
    try std.testing.expectEqualStrings("argument_error", split_error.structuredContent.?.object.get("kind").?.string);

    try commands.verify();
    try workspace.verify();
}

test "core adapter renders explain command result and invalid command errors" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "build", "test", "--summary", "all" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zig explain errors",
    }, .{
        .exit_code = 1,
        .stderr = "src/main.zig:1:1: error: bad\n",
    });

    var explain_args = std.json.ObjectMap.empty;
    defer explain_args.deinit(allocator);
    try explain_args.put(allocator, "command", .{ .string = "build-test" });
    try explain_args.put(allocator, "args", .{ .string = "--summary all" });
    const explain = try mcp_core.zigExplainErrors(allocator, testCoreContext(commands.port(), workspace.port()), .{ .object = explain_args });
    defer mcp_result.deinitToolResult(allocator, explain);
    try std.testing.expectEqualStrings("build-test", explain.structuredContent.?.object.get("mode").?.string);
    try std.testing.expectEqualStrings("compiler_error", explain.structuredContent.?.object.get("diagnostics").?.object.get("category").?.string);

    var invalid_args = std.json.ObjectMap.empty;
    defer invalid_args.deinit(allocator);
    try invalid_args.put(allocator, "command", .{ .string = "unknown" });
    const invalid = try mcp_core.zigCompileErrorIndex(allocator, testCoreContext(commands.port(), workspace.port()), .{ .object = invalid_args });
    defer mcp_result.deinitToolResult(allocator, invalid);
    try std.testing.expectEqualStrings("argument_error", invalid.structuredContent.?.object.get("kind").?.string);

    try commands.verify();
    try workspace.verify();
}

test "core adapter renders command-backed compile index and explain failures" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "build", "test" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zig compile error index",
    }, .{
        .exit_code = 1,
        .stderr = "src/main.zig:2:1: error: bad\n",
    });
    const index = try mcp_core.zigCompileErrorIndex(allocator, testCoreContext(commands.port(), workspace.port()), null);
    defer mcp_result.deinitToolResult(allocator, index);
    try std.testing.expectEqualStrings("zig_compile_error_index", index.structuredContent.?.object.get("index").?.object.get("kind").?.string);

    try commands.expectRunError(.{
        .argv = &.{ "/bin/zig", "build" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = core_usecase.command_output_limit,
        .max_stderr_bytes = core_usecase.command_output_limit,
        .provenance = "zig explain errors",
    }, error.FileNotFound);
    var explain_args = std.json.ObjectMap.empty;
    defer explain_args.deinit(allocator);
    try explain_args.put(allocator, "command", .{ .string = "build" });
    const explain = try mcp_core.zigExplainErrors(allocator, testCoreContext(commands.port(), workspace.port()), .{ .object = explain_args });
    defer mcp_result.deinitToolResult(allocator, explain);
    try std.testing.expectEqualStrings("backend_error", explain.structuredContent.?.object.get("kind").?.string);

    var missing_file_args = std.json.ObjectMap.empty;
    defer missing_file_args.deinit(allocator);
    try missing_file_args.put(allocator, "command", .{ .string = "check" });
    const missing = try mcp_core.zigExplainErrors(allocator, testCoreContext(commands.port(), workspace.port()), .{ .object = missing_file_args });
    defer mcp_result.deinitToolResult(allocator, missing);
    try std.testing.expectEqualStrings("argument_error", missing.structuredContent.?.object.get("kind").?.string);

    try commands.verify();
    try workspace.verify();
}

/// Builds the adapter test context with fake ports and allocator ownership.
fn testCoreContext(command_runner: ports.CommandRunner, workspace_store: ports.WorkspaceStore) app_context.CoreCommandContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .tool_paths = .{ .zig = "/bin/zig", .zls = "/bin/zls" },
        .timeouts = .{ .command_ms = 12_000, .zls_ms = 30_000 },
        .zls_state = .{ .status = "connected" },
        .command_runner = command_runner,
        .workspace_store = workspace_store,
    };
}
