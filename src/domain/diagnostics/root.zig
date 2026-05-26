pub const stacktrace = @import("stacktrace.zig");
pub const crash = @import("crash.zig");

test {
    _ = stacktrace;
    _ = crash;
    _ = @import("stacktrace_tests.zig");
    _ = @import("crash_tests.zig");
}
