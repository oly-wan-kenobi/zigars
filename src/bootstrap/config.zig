//! Parses process startup flags into an owned Config and exposes the CLI help text.
//! All string fields are heap-allocated; callers must release them via Config.deinit.
const std = @import("std");
const audit = @import("../infra/observability/audit.zig");

/// Startup transport selected for the MCP server process.
pub const Transport = enum {
    stdio,
    http,
};

/// Parsed process configuration.
/// String fields are allocator-owned and must be released with deinit.
pub const Config = struct {
    workspace: []const u8,
    zig_path: []const u8 = "zig",
    zls_path: []const u8 = "zls",
    zlint_path: []const u8 = "zlint",
    zwanzig_path: []const u8 = "zwanzig",
    zflame_path: []const u8 = "zflame",
    diff_folded_path: []const u8 = "diff-folded",
    transport: Transport = .stdio,
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    cache_dir: ?[]const u8 = null,
    audit_log_path: ?[]const u8 = null,
    audit_log_mode: audit.Mode = .metadata,
    timeout_ms: i64 = 30_000,
    zls_timeout_ms: i64 = 30_000,

    /// Frees every owned string captured by parse or ownedDefaults.
    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace);
        allocator.free(self.zig_path);
        allocator.free(self.zls_path);
        allocator.free(self.zlint_path);
        allocator.free(self.zwanzig_path);
        allocator.free(self.zflame_path);
        allocator.free(self.diff_folded_path);
        allocator.free(self.host);
        if (self.cache_dir) |cache_dir| allocator.free(cache_dir);
        if (self.audit_log_path) |audit_log_path| allocator.free(audit_log_path);
        self.* = undefined;
    }
};

/// User-facing startup errors that map to process exits rather than tool results.
pub const ParseError = error{
    HelpRequested,
    VersionRequested,
    MissingValue,
    UnknownArgument,
    InvalidPort,
    InvalidTimeout,
    InvalidTransport,
    InvalidAuditLogMode,
    InvalidAuditLogPath,
    EmptyFlagValue,
    UnsafeHttpHost,
};

/// Parses argv-style startup flags into an owned Config.
/// The returned config owns duplicated strings and must be deinitialized by the caller.
pub fn parse(allocator: std.mem.Allocator, io: std.Io, raw_args: []const []const u8) !Config {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];
    var result = try ownedDefaults(allocator, cwd);
    errdefer result.deinit(allocator);

    var i: usize = 1;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return ParseError.HelpRequested;
        if (std.mem.eql(u8, arg, "--version")) return ParseError.VersionRequested;

        if (std.mem.eql(u8, arg, "--workspace")) {
            try replaceOwned(allocator, &result.workspace, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--zig-path")) {
            try replaceOwned(allocator, &result.zig_path, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--zls-path")) {
            try replaceOwned(allocator, &result.zls_path, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--zlint-path")) {
            try replaceOwned(allocator, &result.zlint_path, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--zwanzig-path")) {
            try replaceOwned(allocator, &result.zwanzig_path, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--zflame-path")) {
            try replaceOwned(allocator, &result.zflame_path, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--diff-folded-path")) {
            try replaceOwned(allocator, &result.diff_folded_path, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--host")) {
            try replaceOwned(allocator, &result.host, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--cache-dir")) {
            const value = try dupeNext(allocator, raw_args, &i);
            if (value.len == 0) {
                allocator.free(value);
                return ParseError.EmptyFlagValue;
            }
            if (result.cache_dir) |old| allocator.free(old);
            result.cache_dir = value;
        } else if (std.mem.eql(u8, arg, "--audit-log")) {
            const value = try dupeNext(allocator, raw_args, &i);
            if (value.len == 0) {
                allocator.free(value);
                return ParseError.InvalidAuditLogPath;
            }
            if (result.audit_log_path) |old| allocator.free(old);
            result.audit_log_path = value;
        } else if (std.mem.eql(u8, arg, "--audit-log-mode")) {
            const value = try dupeNext(allocator, raw_args, &i);
            defer allocator.free(value);
            result.audit_log_mode = audit.parseMode(value) orelse return ParseError.InvalidAuditLogMode;
        } else if (std.mem.eql(u8, arg, "--transport")) {
            const value = try dupeNext(allocator, raw_args, &i);
            defer allocator.free(value);
            if (std.mem.eql(u8, value, "stdio")) {
                result.transport = .stdio;
            } else if (std.mem.eql(u8, value, "http")) {
                result.transport = .http;
            } else {
                return ParseError.InvalidTransport;
            }
        } else if (std.mem.eql(u8, arg, "--port")) {
            const value = try dupeNext(allocator, raw_args, &i);
            defer allocator.free(value);
            result.port = std.fmt.parseInt(u16, value, 10) catch return ParseError.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            const value = try dupeNext(allocator, raw_args, &i);
            defer allocator.free(value);
            result.timeout_ms = std.fmt.parseInt(i64, value, 10) catch return ParseError.InvalidTimeout;
            if (result.timeout_ms <= 0) return ParseError.InvalidTimeout;
        } else if (std.mem.eql(u8, arg, "--zls-timeout-ms")) {
            const value = try dupeNext(allocator, raw_args, &i);
            defer allocator.free(value);
            result.zls_timeout_ms = std.fmt.parseInt(i64, value, 10) catch return ParseError.InvalidTimeout;
            if (result.zls_timeout_ms <= 0) return ParseError.InvalidTimeout;
        } else {
            return ParseError.UnknownArgument;
        }
    }

    if (result.transport == .http and !isLoopbackHttpHost(result.host)) return ParseError.UnsafeHttpHost;
    return result;
}

/// Returns true only for hosts that keep the HTTP transport bound to loopback.
pub fn isLoopbackHttpHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "[::1]") or
        std.ascii.eqlIgnoreCase(host, "localhost");
}

/// Allocates default config string values so every field is always allocator-owned.
/// Uniform ownership allows Config.deinit to free all fields unconditionally.
fn ownedDefaults(allocator: std.mem.Allocator, cwd: []const u8) !Config {
    const workspace = try allocator.dupe(u8, cwd);
    errdefer allocator.free(workspace);
    const zig_path = try allocator.dupe(u8, "zig");
    errdefer allocator.free(zig_path);
    const zls_path = try allocator.dupe(u8, "zls");
    errdefer allocator.free(zls_path);
    const zlint_path = try allocator.dupe(u8, "zlint");
    errdefer allocator.free(zlint_path);
    const zwanzig_path = try allocator.dupe(u8, "zwanzig");
    errdefer allocator.free(zwanzig_path);
    const zflame_path = try allocator.dupe(u8, "zflame");
    errdefer allocator.free(zflame_path);
    const diff_folded_path = try allocator.dupe(u8, "diff-folded");
    errdefer allocator.free(diff_folded_path);
    const host = try allocator.dupe(u8, "127.0.0.1");
    errdefer allocator.free(host);

    return .{
        .workspace = workspace,
        .zig_path = zig_path,
        .zls_path = zls_path,
        .zlint_path = zlint_path,
        .zwanzig_path = zwanzig_path,
        .zflame_path = zflame_path,
        .diff_folded_path = diff_folded_path,
        .host = host,
    };
}

/// Replaces an owned string field with the next argv value, freeing the old value.
/// Empty values are rejected so path-like flags fail at startup rather than at first use.
fn replaceOwned(allocator: std.mem.Allocator, field: *[]const u8, args: []const []const u8, index: *usize) !void {
    const value = try dupeNext(allocator, args, index);
    if (value.len == 0) {
        allocator.free(value);
        return ParseError.EmptyFlagValue;
    }
    allocator.free(field.*);
    field.* = value;
}

/// Duplicates the argv value after index and advances index to that value.
fn dupeNext(allocator: std.mem.Allocator, args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return ParseError.MissingValue;
    return allocator.dupe(u8, args[index.*]);
}

/// Static CLI help text; stdout remains reserved for MCP JSON-RPC.
pub fn usage() []const u8 {
    return
    \\zigars - deterministic Zig development MCP server
    \\
    \\Usage:
    \\  zigars [--workspace <path>] [--zig-path <path>] [--zls-path <path>]
    \\        [--zlint-path <path>] [--zwanzig-path <path>] [--zflame-path <path>]
    \\        [--diff-folded-path <path>]
    \\        [--transport stdio|http] [--host 127.0.0.1|localhost|::1] [--port 8080]
    \\        [--cache-dir <path>] [--timeout-ms <n>] [--zls-timeout-ms <n>]
    \\        [--audit-log <workspace-path>] [--audit-log-mode metadata|redacted|full]
    \\  zigars cli workspace-info --workspace <path> --json
    \\  zigars cli doctor --workspace <path> --probe-backends=false --json
    \\
    \\stdio is the safest default for Codex. http is local-only and must bind loopback.
    \\Audit logging is off by default. Full audit mode records raw MCP payloads and should
    \\only be used intentionally for local forensic debugging.
    \\stdout is reserved for MCP JSON-RPC in server mode. In explicit cli mode,
    \\successful command output is JSON on stdout and diagnostics go to stderr.
    \\
    ;
}
