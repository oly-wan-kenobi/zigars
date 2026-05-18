const std = @import("std");
const builtin = @import("builtin");

pub const min_total_tests: i64 = 135;
pub const min_http_smoke_scenarios: usize = 25;
pub const min_stdio_fixture_tool_calls: usize = 12;
pub const kcov_include_path = "src,tools";
pub const kcov_exclude_path = "zig-pkg,.zig-cache,zig-out,coverage,dist";
pub const min_line_coverage_basis_points: u32 = 9000;
pub const min_src_line_coverage_basis_points: u32 = 9000;
pub const min_tools_line_coverage_basis_points: u32 = 9000;

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
        .name = "zigar-lib-tests",
        .unix_path = "zig-out/test-bin/zigar-lib-tests",
        .windows_path = "zig-out/test-bin/zigar-lib-tests.exe",
        .min_tests = 115,
    },
    .{
        .name = "zigar-exe-tests",
        .unix_path = "zig-out/test-bin/zigar-exe-tests",
        .windows_path = "zig-out/test-bin/zigar-exe-tests.exe",
        .min_tests = 3,
    },
    .{
        .name = "zigar-tools-tests",
        .unix_path = "zig-out/test-bin/zigar-tools-tests",
        .windows_path = "zig-out/test-bin/zigar-tools-tests.exe",
        .min_tests = 10,
    },
};

test "test binaries have stable paths" {
    try std.testing.expectEqual(@as(usize, 3), test_binaries.len);
    try std.testing.expectEqualStrings("zigar-lib-tests", test_binaries[0].name);
    try std.testing.expect(std.mem.endsWith(u8, test_binaries[0].path(), if (builtin.os.tag == .windows) ".exe" else "zigar-lib-tests"));
    for (test_binaries) |binary| {
        try std.testing.expect(binary.min_tests > 0);
        try std.testing.expect(std.mem.startsWith(u8, binary.path(), "zig-out/test-bin/"));
    }
}

test "coverage test floor is positive" {
    try std.testing.expect(min_total_tests > 0);
    try std.testing.expect(min_http_smoke_scenarios > 0);
    try std.testing.expect(min_stdio_fixture_tool_calls > 0);
    try std.testing.expect(min_line_coverage_basis_points > 0);
    try std.testing.expect(min_src_line_coverage_basis_points > 0);
    try std.testing.expect(min_tools_line_coverage_basis_points > 0);
}
