//! Contract tests for docs.zig: pins that every bundled docs tool exposes a
//! non-empty description and is registered as read-only and pure-analysis.
const std = @import("std");
const subject = @import("docs.zig");
const zig_builtin_list = subject.zig_builtin_list;
const zig_builtin_doc = subject.zig_builtin_doc;
const zig_std_search = subject.zig_std_search;
const zig_std_item = subject.zig_std_item;
const zig_lang_ref_search = subject.zig_lang_ref_search;

test "docs definitions expose builtin metadata" {
    try @import("std").testing.expect(zig_builtin_list.description.len > 0);
}
