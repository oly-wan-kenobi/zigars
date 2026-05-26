const catalog = @import("../../domain/zig/backend_catalog.zig");

pub const supported_zig_version = catalog.supported_zig_version;
pub const Backend = catalog.Backend;
pub const Paths = catalog.Paths;
pub const backends = catalog.backends;
