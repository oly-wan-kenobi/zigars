//! Deterministic loopback-port selection for the smoke suite.
//! Ports are derived from the process ID rather than the wall clock so
//! concurrent test runs start from different offsets (LOW-9). A live bind
//! probe confirms each candidate is free before it is returned.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

/// Loopback-only smoke port search window. Bounded so concurrent runs converge
/// quickly while staying clear of well-known service ports.
pub const port_base: u16 = 41000;
/// Number of loopback ports available to deterministic smoke-test selection.
pub const port_window: u16 = 8000;

/// Returns the current real-clock time in nanoseconds. Used by fixture runners
/// to stamp temporary workspace directory names so parallel runs do not
/// collide on the same path.
pub fn nowNs(io: Io) i96 {
    return Io.Clock.now(.real, io).nanoseconds;
}

/// Process-stable identifier used to seed deterministic port selection. Unlike a
/// wall-clock reading it is fixed for the run and differs between concurrent
/// processes, so two smoke runs do not derive the same starting port (LOW-9).
fn currentProcessId() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .wasi => 1,
        else => @bitCast(@as(i32, @truncate(std.posix.system.getpid()))),
    };
}

/// Returns the n-th deterministic candidate port in the loopback search window.
/// The starting offset is derived from the process id (LOW-9: no wall-clock
/// derivation), and successive attempts walk the window so a lingering socket on
/// one port is skipped on the next attempt.
pub fn candidatePort(attempt: u16) u16 {
    const seed: u32 = currentProcessId();
    const offset: u32 = (seed +% attempt) % port_window;
    return port_base + @as(u16, @intCast(offset));
}

/// Reserves a currently-free loopback port by binding it in this process and
/// immediately releasing it, so the returned port is verified free at selection
/// time rather than guessed from the wall clock (LOW-9). The bind also proves the
/// port is not held by a lingering socket from a previous run. The returned port
/// is handed to the child server, which rebinds it; callers should still treat a
/// failed child startup as a signal to retry with a fresh port to absorb the
/// (small) bind/rebind race.
pub fn reserveLoopbackPort(io: Io) !u16 {
    const max_attempts: u16 = 64;
    var attempt: u16 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        const port = candidatePort(attempt);
        const address = Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        var listener = Io.net.IpAddress.listen(&address, io, .{}) catch |err| switch (err) {
            error.AddressInUse, error.AddressUnavailable => continue,
            else => return err,
        };
        listener.deinit(io);
        return port;
    }
    return error.NoFreePort;
}

/// Retained for callers that only need a deterministic candidate without a live
/// bind probe; prefer `reserveLoopbackPort`.
pub fn pickPort(io: Io) u16 {
    return reserveLoopbackPort(io) catch candidatePort(0);
}
