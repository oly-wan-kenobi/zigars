const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const zig_analysis = @import("../../../domain/zig/analysis.zig");

pub const default_source_read_limit: usize = 512 * 1024;
pub const provenance = "static_analysis.source_summary";

pub const SourceTextKind = enum {
    decl_summary,
    allocations,
    error_sets,
    public_api,
    dead_decl_candidates,
};

pub const SourceRequest = struct {
    file: []const u8,
    contents: []const u8,
};

pub const WorkspaceSourceRequest = struct {
    file: []const u8,
    max_bytes: usize = default_source_read_limit,
};

pub const SourceError = ports.PortError || error{
    SkippedWorkspacePath,
};

pub const SourceRead = struct {
    file: []const u8,
    bytes: []const u8,
    owns_bytes: bool = false,

    pub fn deinit(self: SourceRead, allocator: std.mem.Allocator) void {
        if (self.owns_bytes) allocator.free(self.bytes);
    }
};

pub fn textSummary(allocator: std.mem.Allocator, kind: SourceTextKind, request: SourceRequest) ![]u8 {
    return switch (kind) {
        .decl_summary => zig_analysis.declarationSummaryText(allocator, request.file, request.contents),
        .allocations => zig_analysis.allocationSummaryText(allocator, request.file, request.contents),
        .error_sets => zig_analysis.errorSetSummaryText(allocator, request.file, request.contents),
        .public_api => zig_analysis.publicApiSummaryText(allocator, request.file, request.contents),
        .dead_decl_candidates => zig_analysis.deadDeclCandidatesText(allocator, request.file, request.contents),
    };
}

pub fn parserSummary(allocator: std.mem.Allocator, request: SourceRequest) !zig_analysis.SourceSummary {
    return zig_analysis.parseSourceSummary(allocator, request.file, request.contents);
}

pub fn heuristicDeclarations(allocator: std.mem.Allocator, request: SourceRequest) !zig_analysis.DeclarationList {
    return zig_analysis.heuristicDeclarations(allocator, request.contents);
}

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

pub fn readParserSummary(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: WorkspaceSourceRequest) SourceError!zig_analysis.SourceSummary {
    const source = try readSource(allocator, context, request);
    defer source.deinit(allocator);
    return parserSummary(allocator, .{ .file = source.file, .contents = source.bytes }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidRequest,
    };
}
