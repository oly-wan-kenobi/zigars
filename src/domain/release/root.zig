//! Release-domain helpers for docs evidence, release notes, and review packs.
pub const docs_index = @import("docs_index.zig");
pub const release_model = @import("release_model.zig");

test {
    _ = docs_index;
    _ = release_model;
    _ = @import("docs_index_tests.zig");
    _ = @import("release_model_tests.zig");
}
