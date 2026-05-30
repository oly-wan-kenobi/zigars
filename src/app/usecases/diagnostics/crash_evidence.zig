//! Turns raw crash/sanitizer/panic text into typed evidence: a sanitizer and
//! failure-kind classification, parsed (count-bounded) stack frames, and a
//! stable crash identity. The identity is a prefixed 64-bit SHA-256 digest of
//! the input text, used to confirm a later reproduction yields the same crash.
//!
//! All returned structs own allocations; callers must call deinit. This is pure
//! evidence extraction — no command execution and no I/O — so the structured
//! workflows in workflows.zig can apply-gate any external tooling on top.
const std = @import("std");

const crash = @import("../../../domain/diagnostics/crash.zig");
const stacktrace = @import("../../../domain/diagnostics/stacktrace.zig");

/// Carries crash identity data across use case and port boundaries.
pub const CrashIdentity = struct {
    value: []const u8,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *CrashIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        self.* = undefined;
    }
};

/// Carries frame summary data across use case and port boundaries.
pub const FrameSummary = struct {
    source_kind: []const u8,
    frames: stacktrace.ParsedFrames,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *FrameSummary, allocator: std.mem.Allocator) void {
        self.frames.deinit(allocator);
        self.* = undefined;
    }
};

/// Carries sanitizer fusion data across use case and port boundaries.
pub const SanitizerFusion = struct {
    source_kind: []const u8,
    sanitizer: crash.Sanitizer,
    failure_kind: crash.FailureKind,
    crash_identity: CrashIdentity,
    frames: stacktrace.ParsedFrames,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *SanitizerFusion, allocator: std.mem.Allocator) void {
        self.crash_identity.deinit(allocator);
        self.frames.deinit(allocator);
        self.* = undefined;
    }
};

/// Carries panic trace data across use case and port boundaries.
pub const PanicTrace = struct {
    panic_message: []const u8,
    failure_kind: crash.FailureKind,
    crash_identity: CrashIdentity,
    frames: stacktrace.ParsedFrames,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *PanicTrace, allocator: std.mem.Allocator) void {
        self.crash_identity.deinit(allocator);
        self.frames.deinit(allocator);
        self.* = undefined;
    }
};

/// Carries crash repro plan data across use case and port boundaries.
pub const CrashReproPlan = struct {
    failure_kind: crash.FailureKind,
    crash_identity: CrashIdentity,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *CrashReproPlan, allocator: std.mem.Allocator) void {
        self.crash_identity.deinit(allocator);
        self.* = undefined;
    }
};

/// Carries evidence request data across use case and port boundaries.
pub const EvidenceRequest = struct {
    bytes: []const u8,
    source_kind: []const u8,
    limit: usize,
};

/// Parses up to `request.limit` stack frames from the evidence text. The
/// returned FrameSummary records the original count even when fewer frames are
/// retained, and owns its frames (caller must deinit).
pub fn summarizeFrames(allocator: std.mem.Allocator, request: EvidenceRequest) !FrameSummary {
    return .{
        .source_kind = request.source_kind,
        .frames = try stacktrace.parseFrames(allocator, request.bytes, normalizedLimit(request.limit)),
    };
}

/// Fuses sanitizer evidence: classifies the sanitizer and failure kind, derives
/// a crash identity keyed on the sanitizer name, and parses bounded frames.
/// Returns an owned SanitizerFusion (caller must deinit).
pub fn fuseSanitizer(allocator: std.mem.Allocator, request: EvidenceRequest) !SanitizerFusion {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const sanitizer = crash.classifySanitizer(request.bytes);
    return .{
        .source_kind = request.source_kind,
        .sanitizer = sanitizer,
        .failure_kind = crash.classifyFailure(request.bytes),
        .crash_identity = .{ .value = try identityFromText(allocator, request.bytes, sanitizer.name()) },
        .frames = try stacktrace.parseFrames(allocator, request.bytes, normalizedLimit(request.limit)),
    };
}

/// Analyzes a Zig panic trace: extracts the panic message (falling back to
/// "unknown panic" when none is found), classifies the failure kind, derives a
/// zig_panic-keyed crash identity, and parses bounded frames. Returns an owned
/// PanicTrace (caller must deinit).
pub fn analyzePanicTrace(allocator: std.mem.Allocator, request: EvidenceRequest) !PanicTrace {
    return .{
        .panic_message = crash.panicMessage(request.bytes) orelse "unknown panic",
        .failure_kind = crash.classifyFailure(request.bytes),
        .crash_identity = .{ .value = try identityFromText(allocator, request.bytes, "zig_panic") },
        .frames = try stacktrace.parseFrames(allocator, request.bytes, normalizedLimit(request.limit)),
    };
}

/// Classifies the failure kind and derives a crash-keyed identity for a
/// reproduction plan, without parsing frames. Returns an owned CrashReproPlan
/// (caller must deinit).
pub fn planCrashRepro(allocator: std.mem.Allocator, bytes: []const u8) !CrashReproPlan {
    return .{
        .failure_kind = crash.classifyFailure(bytes),
        .crash_identity = .{ .value = try identityFromText(allocator, bytes, "crash") },
    };
}

/// Clamps a requested frame limit to at least 1 so parsing always keeps the top
/// frame even when callers pass 0.
fn normalizedLimit(limit: usize) usize {
    return @max(1, limit);
}

/// Builds a stable crash identity as `prefix:<first 16 hex chars of SHA-256>`.
/// The truncated digest is enough to correlate identical crash text across runs
/// without being a security claim. Returns allocator-owned bytes.
fn identityFromText(allocator: std.mem.Allocator, text: []const u8, prefix: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ prefix, hex[0..16] });
}
