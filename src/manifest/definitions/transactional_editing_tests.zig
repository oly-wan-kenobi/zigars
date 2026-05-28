const std = @import("std");
const subject = @import("transactional_editing.zig");
const zigars_patch_session_create = subject.zigars_patch_session_create;
const zigars_patch_session_preview = subject.zigars_patch_session_preview;
const zigars_patch_session_apply = subject.zigars_patch_session_apply;
const zigars_patch_session_validate = subject.zigars_patch_session_validate;
const zigars_patch_session_revert = subject.zigars_patch_session_revert;
const zig_generated_file_trace = subject.zig_generated_file_trace;
const zigars_edit_policy_check = subject.zigars_edit_policy_check;
const zigars_generated_route = subject.zigars_generated_route;
const zig_move_decl = subject.zig_move_decl;
const zig_extract_decl = subject.zig_extract_decl;
const zig_update_imports = subject.zig_update_imports;
const zig_organize_imports = subject.zig_organize_imports;
const zig_code_action_batch = subject.zig_code_action_batch;

test "transactional editing definitions expose patch metadata" {
    try @import("std").testing.expect(zigars_patch_session_create.description.len > 0);
}

test "code action batch definition matches unavailable stub behavior" {
    try std.testing.expect(zig_code_action_batch.read_only);
    try std.testing.expectEqual(@as(usize, 0), zig_code_action_batch.input_schema.fields.len);
    try std.testing.expect(!zig_code_action_batch.risk.writes_source);
    try std.testing.expect(!zig_code_action_batch.risk.writes_require_apply);
    try std.testing.expect(!zig_code_action_batch.risk.mutates_lsp_state);
    switch (zig_code_action_batch.plan) {
        .pure_analysis => {},
        else => return error.TestExpectedEqual,
    }
}
