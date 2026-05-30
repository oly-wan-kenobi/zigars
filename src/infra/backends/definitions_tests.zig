//! Smoke-tests that the infra/backends re-export shim correctly forwards the
//! domain catalog: at least one backend is defined and the Zig version string
//! is non-empty.
const std = @import("std");
const definitions = @import("definitions.zig");

const backends = definitions.backends;
const supported_zig_version = definitions.supported_zig_version;

test "infra backend definitions re-export domain catalog" {
    try @import("std").testing.expect(backends.len > 0);
    try @import("std").testing.expect(supported_zig_version.len > 0);
}
