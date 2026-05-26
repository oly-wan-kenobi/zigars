const catalog = @import("../../domain/zig/backend_catalog.zig");

/// Default Zig version advertised by the backend catalog.
pub const supported_zig_version = catalog.supported_zig_version;
/// Backend metadata contract used by environment and catalog renderers.
pub const Backend = catalog.Backend;
/// Configured executable paths for optional backend integrations.
pub const Paths = catalog.Paths;
/// Static backend definitions exposed by the catalog.
pub const backends = catalog.backends;
