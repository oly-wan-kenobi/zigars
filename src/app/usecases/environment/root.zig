pub const adoption = @import("adoption.zig");
pub const backend_catalog = @import("backend_catalog.zig");
pub const trust = @import("trust.zig");
pub const workflows = @import("workflows.zig");

test {
    _ = adoption;
    _ = backend_catalog;
    _ = trust;
    _ = workflows;
}
