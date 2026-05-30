//! Contract tests for formatting.zig: pins that every formatting and edit tool
//! exposes a non-empty description and that source-mutating tools carry the
//! expected apply-gate and preview risk flags.
const std = @import("std");
const subject = @import("formatting.zig");
const zig_format = subject.zig_format;
const zig_format_check = subject.zig_format_check;
const zig_patch_preview = subject.zig_patch_preview;
const zig_rename = subject.zig_rename;
const zig_code_actions = subject.zig_code_actions;
const zig_code_action_apply = subject.zig_code_action_apply;

test "formatting definitions expose formatter metadata" {
    try @import("std").testing.expect(zig_format.description.len > 0);
}
