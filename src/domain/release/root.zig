pub const release_model = @import("release_model.zig");

test {
    _ = release_model;
    _ = @import("release_model_tests.zig");
}
