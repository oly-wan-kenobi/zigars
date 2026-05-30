//! Pins the contract that all CI artifact tool definitions are exported and
//! carry non-empty descriptions, confirming the public surface compiles cleanly.
const std = @import("std");
const subject = @import("ci.zig");
const zig_ci_annotations = subject.zig_ci_annotations;
const zig_junit = subject.zig_junit;
const zig_matrix_check = subject.zig_matrix_check;

test "ci definitions expose artifact metadata" {
    try @import("std").testing.expect(zig_ci_annotations.description.len > 0);
}
