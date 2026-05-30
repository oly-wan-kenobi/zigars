//! Public surface of the release subsystem: documentation path scanning and
//! bounded file reads used by release-readiness checks.
pub const docs_scanner = @import("docs_scanner.zig");

const docs_scanner_tests = @import("docs_scanner_tests.zig");

test {
    _ = docs_scanner;
    _ = docs_scanner_tests;
}
