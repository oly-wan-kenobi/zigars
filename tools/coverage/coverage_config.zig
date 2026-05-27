const std = @import("std");
const builtin = @import("builtin");

pub const min_total_tests: i64 = 500;
pub const min_http_smoke_scenarios: usize = 155;
pub const min_stdio_fixture_tool_calls: usize = 77;
pub const kcov_include_path = "src,tools";
pub const kcov_exclude_path = "zig-pkg,.zig-cache,zig-out,coverage,dist,tools/fuzz_test_runner.zig";
pub const kcov_exclude_line_pattern = "KCOV_EXCL_LINE";
pub const kcov_exclude_region_pattern = "KCOV_EXCL_START:KCOV_EXCL_STOP";
pub const kcov_exclude_line_arg = "--exclude-line=" ++ kcov_exclude_line_pattern;
pub const kcov_exclude_region_arg = "--exclude-region=" ++ kcov_exclude_region_pattern;
pub const min_line_coverage_basis_points: u32 = 10000;
pub const min_src_line_coverage_basis_points: u32 = 10000;
pub const min_tools_line_coverage_basis_points: u32 = 10000;

pub const TestBinary = struct {
    name: []const u8,
    unix_path: []const u8,
    windows_path: []const u8,
    min_tests: i64,

    pub fn path(self: TestBinary) []const u8 {
        return if (builtin.os.tag == .windows) self.windows_path else self.unix_path;
    }
};

pub const test_binaries = [_]TestBinary{
    .{
        .name = "zigars-lib-tests",
        .unix_path = "zig-out/test-bin/zigars-lib-tests",
        .windows_path = "zig-out/test-bin/zigars-lib-tests.exe",
        .min_tests = 480,
    },
    .{
        .name = "zigars-exe-tests",
        .unix_path = "zig-out/test-bin/zigars-exe-tests",
        .windows_path = "zig-out/test-bin/zigars-exe-tests.exe",
        .min_tests = 1,
    },
    .{
        .name = "zigars-tools-tests",
        .unix_path = "zig-out/test-bin/zigars-tools-tests",
        .windows_path = "zig-out/test-bin/zigars-tools-tests.exe",
        .min_tests = 26,
    },
    .{
        .name = "zigars-fuzz-tests",
        .unix_path = "zig-out/test-bin/zigars-fuzz-tests",
        .windows_path = "zig-out/test-bin/zigars-fuzz-tests.exe",
        .min_tests = 2,
    },
};

test "test binaries have stable paths" {
    try std.testing.expectEqual(@as(usize, 4), test_binaries.len);
    try std.testing.expectEqualStrings("zigars-lib-tests", test_binaries[0].name);
    try std.testing.expect(std.mem.endsWith(u8, test_binaries[0].path(), if (builtin.os.tag == .windows) ".exe" else "zigars-lib-tests"));
    for (test_binaries) |binary| {
        try std.testing.expect(binary.min_tests > 0);
        try std.testing.expect(std.mem.startsWith(u8, binary.path(), "zig-out/test-bin/"));
    }
}

test "coverage test floor is positive" {
    try std.testing.expect(min_total_tests > 0);
    try std.testing.expect(min_http_smoke_scenarios > 0);
    try std.testing.expect(min_stdio_fixture_tool_calls > 0);
    try std.testing.expect(kcov_exclude_line_pattern.len > 0);
    try std.testing.expect(kcov_exclude_region_pattern.len > 0);
    try std.testing.expect(min_line_coverage_basis_points > 0);
    try std.testing.expect(min_src_line_coverage_basis_points > 0);
    try std.testing.expect(min_tools_line_coverage_basis_points > 0);
}

test "coverage floors require strict complete coverage" {
    try std.testing.expectEqual(@as(i64, 500), min_total_tests);
    try std.testing.expectEqual(@as(i64, 480), test_binaries[0].min_tests);
    try std.testing.expectEqual(@as(i64, 1), test_binaries[1].min_tests);
    try std.testing.expectEqual(@as(i64, 26), test_binaries[2].min_tests);
    try std.testing.expectEqual(@as(i64, 2), test_binaries[3].min_tests);
    try std.testing.expectEqual(@as(usize, 155), min_http_smoke_scenarios);
    try std.testing.expectEqual(@as(usize, 77), min_stdio_fixture_tool_calls);
    try std.testing.expectEqualStrings("--exclude-line=KCOV_EXCL_LINE", kcov_exclude_line_arg);
    try std.testing.expectEqualStrings("--exclude-region=KCOV_EXCL_START:KCOV_EXCL_STOP", kcov_exclude_region_arg);
    try std.testing.expectEqual(@as(u32, 10000), min_line_coverage_basis_points);
    try std.testing.expectEqual(@as(u32, 10000), min_src_line_coverage_basis_points);
    try std.testing.expectEqual(@as(u32, 10000), min_tools_line_coverage_basis_points);
}
