pub const BuiltinDriftInfo = struct {
    status: []const u8,
    confidence: []const u8,
    active_source_path: ?[]const u8 = null,
    active_count: usize = 0,
    curated_missing_count: usize = 0,
    active_extra_count: usize = 0,
    missing_names: []const []const u8 = &.{},
    extra_names_sample: []const []const u8 = &.{},
};

pub const BuiltinIndexInput = struct {
    toolchain_version: ?[]const u8 = null,
    drift: ?BuiltinDriftInfo = null,
};
