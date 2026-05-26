const catalog = @import("../../domain/zig/backend_catalog.zig");

pub const supported_zig_version = catalog.supported_zig_version;
pub const Backend = catalog.Backend;
pub const Paths = catalog.Paths;
pub const backends = catalog.backends;

test "infra backend definitions re-export domain catalog" {
    try @import("std").testing.expect(backends.len > 0);
    try @import("std").testing.expect(supported_zig_version.len > 0);
}
