const std = @import("std");
const subject = @import("transactional_editing.zig");
const zigar_patch_session_create = subject.zigar_patch_session_create;
const zigar_patch_session_preview = subject.zigar_patch_session_preview;
const zigar_patch_session_apply = subject.zigar_patch_session_apply;
const zigar_patch_session_validate = subject.zigar_patch_session_validate;
const zigar_patch_session_revert = subject.zigar_patch_session_revert;
const zig_generated_file_trace = subject.zig_generated_file_trace;
const zigar_edit_policy_check = subject.zigar_edit_policy_check;
const zigar_generated_route = subject.zigar_generated_route;
const zig_move_decl = subject.zig_move_decl;
const zig_extract_decl = subject.zig_extract_decl;
const zig_update_imports = subject.zig_update_imports;
const zig_organize_imports = subject.zig_organize_imports;
const zig_code_action_batch = subject.zig_code_action_batch;

test "transactional editing definitions expose patch metadata" {
    try @import("std").testing.expect(zigar_patch_session_create.description.len > 0);
}
