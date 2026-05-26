const std = @import("std");
const subject = @import("docs.zig");
const zig_builtin_list = subject.zig_builtin_list;
const zig_builtin_list_json = subject.zig_builtin_list_json;
const zig_builtin_doc = subject.zig_builtin_doc;
const zig_builtin_doc_json = subject.zig_builtin_doc_json;
const zig_std_search = subject.zig_std_search;
const zig_std_search_json = subject.zig_std_search_json;
const zig_std_item = subject.zig_std_item;
const zig_std_item_json = subject.zig_std_item_json;
const zig_lang_ref_search = subject.zig_lang_ref_search;
const zig_lang_ref_search_json = subject.zig_lang_ref_search_json;

test "docs definitions expose builtin metadata" {
    try @import("std").testing.expect(zig_builtin_list.description.len > 0);
}
