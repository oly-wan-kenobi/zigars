//! Public surface of the clock subsystem: real-time clock and atomic ID
//! generation for the runtime ClockAndIds port.
pub const clock_and_ids = @import("clock_and_ids.zig");

const clock_and_ids_tests = @import("clock_and_ids_tests.zig");

test {
    _ = clock_and_ids;
    _ = clock_and_ids_tests;
}
