const std = @import("std");
const cli_io = @import("cli_io.zig");
const smoke = @import("smoke_support.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const stderrPrint = cli_io.stderrPrint;
const valueAt = smoke.valueAt;

pub fn run(allocator: std.mem.Allocator, io: Io, port: u16, expected: JsonValue, scenarios: *usize) !void {
    const crash = "thread 1 panic: reached unreachable code\\n#0 0x1 in parse src/main.zig:10\\n==1==ERROR: AddressSanitizer: heap-use-after-free\\n";
    const heaptrack = "peak heap memory: 1024 bytes\\nallocations: 7 allocations\\n";
    const valgrind = "definitely lost: 32 bytes in 1 blocks\\nERROR SUMMARY: 2 errors from 2 contexts\\n";
    const callgrind = "events: Ir Dr\\nfn=parse\\n10 42\\n";
    const crash_args = try std.fmt.allocPrint(allocator, "{{\"content\":\"{s}\",\"command\":\"zig build test\",\"limit\":5}}", .{crash});
    defer allocator.free(crash_args);
    const heaptrack_args = try std.fmt.allocPrint(allocator, "{{\"content\":\"{s}\"}}", .{heaptrack});
    defer allocator.free(heaptrack_args);
    const valgrind_args = try std.fmt.allocPrint(allocator, "{{\"content\":\"{s}\"}}", .{valgrind});
    defer allocator.free(valgrind_args);
    const callgrind_args = try std.fmt.allocPrint(allocator, "{{\"content\":\"{s}\"}}", .{callgrind});
    defer allocator.free(callgrind_args);

    try assertToolPaths(allocator, io, port, 194, "zig_debug_plan", "{\"binary\":\"build.zig\",\"probe_backend\":false}", expected, "debug_plan_paths", scenarios);
    try assertToolPaths(allocator, io, port, 195, "zig_lldb_backtrace", "{\"binary\":\"build.zig\",\"apply\":false}", expected, "lldb_backtrace_paths", scenarios);
    try assertToolPaths(allocator, io, port, 196, "zig_core_inspect", "{\"binary\":\"build.zig\",\"core\":\"build.zig\",\"apply\":false}", expected, "core_inspect_paths", scenarios);
    try assertToolPaths(allocator, io, port, 197, "zig_debug_frame_summary", crash_args, expected, "debug_frame_paths", scenarios);
    try assertToolPaths(allocator, io, port, 198, "zig_sanitizer_fusion", crash_args, expected, "sanitizer_fusion_paths", scenarios);
    try assertToolPaths(allocator, io, port, 199, "zig_panic_trace_analyze", crash_args, expected, "panic_trace_paths", scenarios);
    try assertToolPaths(allocator, io, port, 200, "zig_crash_repro_plan", crash_args, expected, "crash_repro_paths", scenarios);
    try assertToolPaths(allocator, io, port, 201, "zig_heaptrack_run", "{\"command\":\"zig --version\",\"apply\":false}", expected, "heaptrack_run_paths", scenarios);
    try assertToolPaths(allocator, io, port, 202, "zig_heaptrack_summary", heaptrack_args, expected, "heaptrack_summary_paths", scenarios);
    try assertToolPaths(allocator, io, port, 203, "zig_valgrind_memcheck", "{\"command\":\"zig --version\",\"apply\":false}", expected, "valgrind_memcheck_paths", scenarios);
    try assertToolPaths(allocator, io, port, 204, "zig_callgrind_report", callgrind_args, expected, "callgrind_report_paths", scenarios);
    try assertToolPaths(allocator, io, port, 205, "zig_fuzz_plan", "{\"target\":\"native\",\"command\":\"zig build test\"}", expected, "fuzz_plan_paths", scenarios);
    try assertToolPaths(allocator, io, port, 206, "zig_afl_run", "{\"command\":\"zig --version\",\"corpus\":\"tests/fixtures/static-analysis\",\"apply\":false}", expected, "afl_run_paths", scenarios);
    try assertToolPaths(allocator, io, port, 207, "zig_libfuzzer_run", "{\"command\":\"zig --version\",\"apply\":false}", expected, "libfuzzer_run_paths", scenarios);
    try assertToolPaths(allocator, io, port, 208, "zig_fuzz_crash_minimize", crash_args, expected, "fuzz_minimize_paths", scenarios);
    try assertToolPaths(allocator, io, port, 209, "zig_fuzz_corpus_summary", "{\"path\":\"tests/fixtures/static-analysis\",\"limit\":3}", expected, "fuzz_corpus_paths", scenarios);
    try assertToolPaths(allocator, io, port, 210, "zig_binary_size", "{\"path\":\"build.zig\"}", expected, "binary_size_paths", scenarios);
    try assertToolPaths(allocator, io, port, 211, "zig_binary_size_diff", "{\"path\":\"build.zig\",\"baseline\":\"README.md\"}", expected, "binary_size_diff_paths", scenarios);
    try assertToolPaths(allocator, io, port, 212, "zig_objdump_summary", "{\"path\":\"build.zig\",\"apply\":false}", expected, "objdump_summary_paths", scenarios);
    try assertToolPaths(allocator, io, port, 213, "zig_dwarfdump_check", "{\"path\":\"build.zig\",\"apply\":false}", expected, "dwarfdump_check_paths", scenarios);
    try assertToolPaths(allocator, io, port, 214, "zig_symbolize", "{\"path\":\"build.zig\",\"addresses\":\"0x1\",\"apply\":false}", expected, "symbolize_paths", scenarios);
    try assertToolPaths(allocator, io, port, 215, "zig_qemu_test", "{\"target\":\"x86_64-linux-gnu\",\"command\":\"zig --version\",\"apply\":false}", expected, "qemu_test_paths", scenarios);
    try assertToolPaths(allocator, io, port, 216, "zig_cross_smoke", "{\"targets\":\"x86_64-linux-gnu wasm32-freestanding\"}", expected, "cross_smoke_paths", scenarios);
    try assertToolPaths(allocator, io, port, 217, "zig_target_runtime_plan", "{\"target\":\"wasm32-freestanding\"}", expected, "target_runtime_plan_paths", scenarios);
    try assertToolPaths(allocator, io, port, 218, "zig_embedded_detect", "{\"limit\":5}", expected, "embedded_detect_paths", scenarios);
    try assertToolPaths(allocator, io, port, 219, "zig_microzig_plan", "{\"board\":\"rp2040\"}", expected, "microzig_plan_paths", scenarios);
    try assertToolPaths(allocator, io, port, 220, "zig_board_profile", "{\"board\":\"rp2040\"}", expected, "board_profile_paths", scenarios);
    try assertToolPaths(allocator, io, port, 221, "zig_flash_plan", "{\"board\":\"rp2040\",\"image\":\"build.zig\",\"probe_backend\":false}", expected, "flash_plan_paths", scenarios);
}

fn assertToolPaths(
    allocator: std.mem.Allocator,
    io: Io,
    port: u16,
    id: i64,
    tool_name: []const u8,
    args_json_owned_or_static: []const u8,
    expected_root: JsonValue,
    expected_key: []const u8,
    scenario_count: *usize,
) !void {
    const tool_json = try smoke.callHttpToolJson(allocator, io, port, id, tool_name, args_json_owned_or_static);
    defer allocator.free(tool_json);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, tool_json, .{});
    defer parsed.deinit();
    const expected_paths = expected_root.object.get(expected_key).?.object;
    var it = expected_paths.iterator();
    while (it.next()) |entry| {
        const actual = valueAt(parsed.value, entry.key_ptr.*) orelse {
            try stderrPrint(io, "{s}: missing path {s}\n", .{ tool_name, entry.key_ptr.* });
            return error.AssertionFailed;
        };
        try smoke.expectJsonEq(io, actual, entry.value_ptr.*, entry.key_ptr.*);
    }
    scenario_count.* += 1;
}

test "http diagnostics smoke exposes run entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
