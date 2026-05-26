const std = @import("std");
const subject = @import("core.zig");
const zig_version = subject.zig_version;
const zig_env = subject.zig_env;
const zig_targets = subject.zig_targets;
const zig_build = subject.zig_build;
const zig_test = subject.zig_test;
const zig_check = subject.zig_check;
const zig_compile_error_index = subject.zig_compile_error_index;
const zig_explain_errors = subject.zig_explain_errors;
const zig_translate_c = subject.zig_translate_c;

test "core definitions expose zig version metadata" {
    try @import("std").testing.expect(zig_version.description.len > 0);
}
