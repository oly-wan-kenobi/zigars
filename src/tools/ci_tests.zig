const std = @import("std");
const zigar = @import("zigar");

const ci = @import("ci.zig");

fn fakeRunResult(allocator: std.mem.Allocator, exit_code: u8, stdout: []const u8, stderr: []const u8) !zigar.command.RunResult {
    return .{
        .term = .{ .exited = exit_code },
        .stdout = try allocator.dupe(u8, stdout),
        .stderr = try allocator.dupe(u8, stderr),
    };
}

test "ci annotations expose parser basis confidence and details" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var annotations = std.json.Array.init(allocator);
    const summary = try ci.tryParseAnnotations(allocator, &annotations, "src/main.zig",
        \\src/main.zig:2:9: error: expected ';' after statement
        \\    _ = x
        \\        ^
        \\src/main.zig:1:1: note: declared here
        \\
    );
    try std.testing.expectEqual(@as(i64, 4), summary.input_lines);
    try std.testing.expectEqual(@as(i64, 2), summary.annotation_count);
    try std.testing.expectEqualStrings("high", summary.confidence());

    const first = annotations.items[0].object;
    try std.testing.expectEqualStrings("src/main.zig", first.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 2), first.get("start_line").?.integer);
    try std.testing.expectEqualStrings("failure", first.get("annotation_level").?.string);
    try std.testing.expectEqualStrings("located Zig compiler diagnostic", first.get("parsing_basis").?.string);
    try std.testing.expectEqual(@as(usize, 2), first.get("details").?.array.items.len);

    const note = annotations.items[1].object;
    try std.testing.expectEqualStrings("notice", note.get("annotation_level").?.string);
    try std.testing.expectEqualStrings("declared here", note.get("message").?.string);
}

test "junit command artifact escapes xml and declares command-level semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = &.{ "zig", "test", "src/bad.zig" };
    const result = try fakeRunResult(allocator, 1, "stdout <kept>&\n", "error: found <bad> & \"quoted\"\x01\n");
    const xml = try ci.junitXmlForCommand(allocator, argv, result);
    try std.testing.expect(std.mem.indexOf(u8, xml, "zigar.artifact_kind") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "command_level_junit") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "zig test src/bad.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "found &lt;bad&gt; &amp; &quot;quoted&quot;&#xFFFD;") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<system-out>stdout &lt;kept&gt;&amp;\n</system-out>") != null);
}

test "matrix entries expose direct status command and failure summaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ok_argv = &.{ "zig-ok", "build", "test" };
    const ok_run = try fakeRunResult(allocator, 0, "ok\n", "");
    const ok_entry = (try ci.matrixRunEntryValue(allocator, "zig-ok", ok_argv, ".", 1000, ok_run)).object;
    try std.testing.expect(ok_entry.get("ok").?.bool);
    try std.testing.expectEqualStrings("zig-ok", ok_entry.get("zig").?.string);
    try std.testing.expectEqualStrings("zig-ok build test", ok_entry.get("command").?.string);
    try std.testing.expect(ok_entry.get("failure_summary").?.object.get("ok").?.bool);

    const fail_argv = &.{ "zig-fail", "build", "test" };
    const fail_run = try fakeRunResult(allocator, 1, "", "src/main.zig:1:1: error: fixture failure\n");
    const fail_entry = (try ci.matrixRunEntryValue(allocator, "zig-fail", fail_argv, ".", 1000, fail_run)).object;
    try std.testing.expect(!fail_entry.get("ok").?.bool);
    try std.testing.expect(!fail_entry.get("failure_summary").?.object.get("ok").?.bool);

    const missing_argv = &.{ "missing-zig", "build", "test" };
    const missing_entry = (try ci.matrixCommandErrorEntryValue(allocator, "missing-zig", missing_argv, ".", 1000, error.FileNotFound)).object;
    try std.testing.expect(!missing_entry.get("ok").?.bool);
    try std.testing.expectEqualStrings("executable_not_found", missing_entry.get("error_kind").?.string);
    try std.testing.expectEqualStrings("missing-zig build test", missing_entry.get("command").?.string);
}
