//! ZLS child process lifecycle: spawn, kill, pipe hand-off, and restart.
//! The process owns its stdin/stdout/stderr pipes until `detachPipes` transfers
//! them to an LspClient. After detach, `deinit`/`kill` no longer close those handles.
const std = @import("std");

/// Manages ZLS child process lifecycle: spawn, health check, restart.
pub const ZlsProcess = struct {
    child: ?std.process.Child = null,
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    zls_path: []const u8,
    restart_count: u32 = 0,
    max_restarts: u32 = 5,

    /// Stores process configuration; `spawn` creates the child owned by `deinit`.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, zls_path: []const u8) ZlsProcess {
        return .{
            .allocator = allocator,
            .io = io,
            .workspace_path = workspace_path,
            .zls_path = zls_path,
        };
    }

    /// Spawns ZLS with piped stdin/stdout/stderr. Kills any existing child first.
    /// After a successful spawn the pipes are owned by this ZlsProcess until `detachPipes`.
    pub fn spawn(self: *ZlsProcess) !void {
        // Keep this logic centralized so callers observe one consistent behavior path.
        if (self.child != null) {
            self.kill();
        }

        var child = try std.process.spawn(self.io, .{
            .argv = &.{self.zls_path},
            .cwd = .{ .path = self.workspace_path },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        _ = &child;
        self.child = child;
    }

    /// Returns the ZLS stdin pipe, or null if not yet spawned or already detached.
    pub fn getStdin(self: *ZlsProcess) ?std.Io.File {
        const child = self.child orelse return null;
        return child.stdin;
    }

    /// Returns the ZLS stdout pipe, or null if not yet spawned or already detached.
    pub fn getStdout(self: *ZlsProcess) ?std.Io.File {
        const child = self.child orelse return null;
        return child.stdout;
    }

    /// Returns the ZLS stderr pipe, or null if not yet spawned or already detached.
    pub fn getStderr(self: *ZlsProcess) ?std.Io.File {
        const child = self.child orelse return null;
        return child.stderr;
    }

    /// Reports whether a child process slot is present (does not probe the OS).
    pub fn isAlive(self: *ZlsProcess) bool {
        return self.child != null;
    }

    /// Kills the ZLS child process and clears the child slot. No-op when not alive.
    pub fn kill(self: *ZlsProcess) void {
        if (self.child) |*child| {
            child.kill(self.io);
            self.child = null;
        }
    }

    /// Transfers pipe handle ownership to an external owner (typically LspClient).
    /// Nulls out stdin/stdout/stderr so kill/deinit no longer close them.
    pub fn detachPipes(self: *ZlsProcess) void {
        if (self.child) |*child| {
            child.stdin = null;
            child.stdout = null;
            child.stderr = null;
        }
    }

    /// Kills the current child and spawns a replacement, incrementing restart_count.
    /// Returns false (without error) when max_restarts is already reached, or when the
    /// spawn attempt fails — in the latter case restart_count is still incremented.
    pub fn restart(self: *ZlsProcess) !bool {
        // Keep this logic centralized so callers observe one consistent behavior path.
        if (self.restart_count >= self.max_restarts) {
            return false;
        }
        self.kill();
        self.restart_count += 1;
        self.spawn() catch return false;
        return true;
    }

    /// Releases owned allocations/resources; callers must not use the value afterward.
    pub fn deinit(self: *ZlsProcess) void {
        self.kill();
    }
};
