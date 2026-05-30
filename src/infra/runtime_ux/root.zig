//! Public surface of the runtime UX subsystem: tool catalog rendering and
//! in-process job/event/root/subscription session management.
pub const catalog = @import("catalog.zig");
pub const session = @import("session.zig");

const catalog_tests = @import("catalog_tests.zig");
const session_tests = @import("session_tests.zig");

test {
    _ = catalog;
    _ = session;
    _ = catalog_tests;
    _ = session_tests;
}
