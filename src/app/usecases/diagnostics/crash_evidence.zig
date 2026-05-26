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

/// Implements summarize frames workflow logic using caller-owned inputs.
pub fn summarizeFrames(allocator: std.mem.Allocator, request: EvidenceRequest) !FrameSummary {
    return .{
        .source_kind = request.source_kind,
        .frames = try stacktrace.parseFrames(allocator, request.bytes, normalizedLimit(request.limit)),
    };
}

/// Implements fuse sanitizer workflow logic using caller-owned inputs.
pub fn fuseSanitizer(allocator: std.mem.Allocator, request: EvidenceRequest) !SanitizerFusion {
    const sanitizer = crash.classifySanitizer(request.bytes);
    return .{
        .source_kind = request.source_kind,
        .sanitizer = sanitizer,
        .failure_kind = crash.classifyFailure(request.bytes),
        .crash_identity = .{ .value = try identityFromText(allocator, request.bytes, sanitizer.name()) },
        .frames = try stacktrace.parseFrames(allocator, request.bytes, normalizedLimit(request.limit)),
    };
}

/// Implements analyze panic trace workflow logic using caller-owned inputs.
pub fn analyzePanicTrace(allocator: std.mem.Allocator, request: EvidenceRequest) !PanicTrace {
    return .{
        .panic_message = crash.panicMessage(request.bytes) orelse "unknown panic",
        .failure_kind = crash.classifyFailure(request.bytes),
        .crash_identity = .{ .value = try identityFromText(allocator, request.bytes, "zig_panic") },
        .frames = try stacktrace.parseFrames(allocator, request.bytes, normalizedLimit(request.limit)),
    };
}

/// Implements plan crash repro workflow logic using caller-owned inputs.
pub fn planCrashRepro(allocator: std.mem.Allocator, bytes: []const u8) !CrashReproPlan {
    return .{
        .failure_kind = crash.classifyFailure(bytes),
        .crash_identity = .{ .value = try identityFromText(allocator, bytes, "crash") },
    };
}

/// Normalizes numeric input into the bounded value used by this workflow.
fn normalizedLimit(limit: usize) usize {
    return @max(1, limit);
}

/// Implements identity from text workflow logic using caller-owned inputs.
fn identityFromText(allocator: std.mem.Allocator, text: []const u8, prefix: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ prefix, hex[0..16] });
}
