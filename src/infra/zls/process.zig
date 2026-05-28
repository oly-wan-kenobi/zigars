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

    /// Spawn the ZLS child process with piped stdin/stdout/stderr.
    pub fn spawn(self: *ZlsProcess) !void {
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

    /// Get the stdin pipe for writing to ZLS.
    pub fn getStdin(self: *ZlsProcess) ?std.Io.File {
        const child = self.child orelse return null;
        return child.stdin;
    }

    /// Get the stdout pipe for reading from ZLS.
    pub fn getStdout(self: *ZlsProcess) ?std.Io.File {
        const child = self.child orelse return null;
        return child.stdout;
    }

    /// Get the stderr pipe for reading ZLS stderr.
    pub fn getStderr(self: *ZlsProcess) ?std.Io.File {
        const child = self.child orelse return null;
        return child.stderr;
    }

    /// Check if ZLS is currently alive.
    pub fn isAlive(self: *ZlsProcess) bool {
        return self.child != null;
    }

    /// Kill the ZLS child process.
    pub fn kill(self: *ZlsProcess) void {
        if (self.child) |*child| {
            child.kill(self.io);
            self.child = null;
        }
    }

    /// Mark pipe handles as externally owned (e.g., by LspClient).
    /// Prevents double-close during deinit.
    pub fn detachPipes(self: *ZlsProcess) void {
        if (self.child) |*child| {
            child.stdin = null;
            child.stdout = null;
            child.stderr = null;
        }
    }

    /// Attempt to restart ZLS. Returns false if max restarts exceeded.
    pub fn restart(self: *ZlsProcess) !bool {
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
