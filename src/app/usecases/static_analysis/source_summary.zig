//! Source-summary adapter that maps analyzed files or text into typed JSON summaries.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const zig_analysis = @import("../../../domain/zig/analysis.zig");

/// Default source read limit used when the caller omits an explicit value.
pub const default_source_read_limit: usize = 512 * 1024;
/// Provenance tag attached to workspace reads from this workflow.
pub const provenance = "static_analysis.source_summary";

/// Defines the allowed source text kind variants accepted by this workflow.
pub const SourceTextKind = enum {
    decl_summary,
    allocations,
    error_sets,
    public_api,
    dead_decl_candidates,
};

/// Carries source request data across use case and port boundaries.
pub const SourceRequest = struct {
    file: []const u8,
    contents: []const u8,
};

/// Carries workspace source request data across use case and port boundaries.
pub const WorkspaceSourceRequest = struct {
    file: []const u8,
    max_bytes: usize = default_source_read_limit,
};

/// Error set returned by source workflow failures.
pub const SourceError = ports.PortError || error{
    SkippedWorkspacePath,
};

/// Carries source read data across use case and port boundaries.
pub const SourceRead = struct {
    file: []const u8,
    bytes: []const u8,
    owns_bytes: bool = false,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: SourceRead, allocator: std.mem.Allocator) void {
        if (self.owns_bytes) allocator.free(self.bytes);
    }
};

/// Implements text summary workflow logic using caller-owned inputs.
pub fn textSummary(allocator: std.mem.Allocator, kind: SourceTextKind, request: SourceRequest) ![]u8 {
    return switch (kind) {
        .decl_summary => zig_analysis.declarationSummaryText(allocator, request.file, request.contents),
        .allocations => zig_analysis.allocationSummaryText(allocator, request.file, request.contents),
        .error_sets => zig_analysis.errorSetSummaryText(allocator, request.file, request.contents),
        .public_api => zig_analysis.publicApiSummaryText(allocator, request.file, request.contents),
        .dead_decl_candidates => zig_analysis.deadDeclCandidatesText(allocator, request.file, request.contents),
    };
}

/// Parses source-summary input using caller-provided storage; malformed input and allocation failures propagate.
pub fn parserSummary(allocator: std.mem.Allocator, request: SourceRequest) !zig_analysis.SourceSummary {
    return zig_analysis.parseSourceSummary(allocator, request.file, request.contents);
}

/// Implements heuristic declarations workflow logic using caller-owned inputs.
pub fn heuristicDeclarations(allocator: std.mem.Allocator, request: SourceRequest) !zig_analysis.DeclarationList {
    return zig_analysis.heuristicDeclarations(allocator, request.contents);
}

/// Reads source data from the provided context without taking ownership of inputs.
pub fn readSource(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: WorkspaceSourceRequest) SourceError!SourceRead {
    if (zig_analysis.skipWorkspacePath(request.file)) return error.SkippedWorkspacePath;
    const read = try context.workspace_store.read(allocator, .{
        .path = request.file,
        .max_bytes = request.max_bytes,
        .provenance = provenance,
    });
    return .{
        .file = request.file,
        .bytes = read.bytes,
        .owns_bytes = read.owns_bytes,
    };
}

/// Reads parser summary data from the provided context without taking ownership of inputs.
pub fn readParserSummary(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: WorkspaceSourceRequest) SourceError!zig_analysis.SourceSummary {
    const source = try readSource(allocator, context, request);
    defer source.deinit(allocator);
    return parserSummary(allocator, .{ .file = source.file, .contents = source.bytes }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidRequest,
    };
}
