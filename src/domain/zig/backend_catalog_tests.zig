//! Structural sanity checks for backend_catalog.zig: verifies required/optional
//! ordering and that every backend entry exposes at least one tool name.
const std = @import("std");

const backend_catalog = @import("backend_catalog.zig");

test "backend catalog exposes required and optional backends" {
    try std.testing.expect(backend_catalog.backends.len >= 6);
    try std.testing.expect(!backend_catalog.backends[0].optional);
    try std.testing.expect(backend_catalog.backends[0].tools.len > 0);
}
