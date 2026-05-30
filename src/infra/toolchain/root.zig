//! Public surface of the toolchain subsystem: runtime discovery of Zig
//! toolchain settings via `zig env`.
pub const env = @import("env.zig");

test {
    _ = env;
}
