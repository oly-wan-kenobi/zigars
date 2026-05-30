//! Render-only profiling use-case that normalizes path and backend failures.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const flamegraph_model = @import("../../../domain/profiling/flamegraph.zig");
const flamegraph = @import("flamegraph.zig");

/// Carries request data across use case and port boundaries.
pub const Request = struct {
    tool_name: []const u8 = "zig_flamegraph",
    operation: []const u8 = "render_flamegraph",
    input: []const u8,
    output: []const u8,
    format: flamegraph_model.ZflameFormat,
    options: flamegraph_model.ZflameRenderOptions = .{},
};

/// Carries path failure data across use case and port boundaries.
pub const PathFailure = struct {
    err: ports.PortError,
    path: []const u8,
    for_output: bool = false,
};

/// Carries run failure data across use case and port boundaries.
pub const RunFailure = struct {
    request: flamegraph.Request,
    input_abs: []const u8,
    output_abs: []const u8,
    failure: flamegraph.Failure,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *RunFailure, allocator: std.mem.Allocator) void {
        self.failure.deinit(allocator);
        allocator.free(self.input_abs);
        allocator.free(self.output_abs);
        self.* = undefined;
    }
};

/// Carries artifact data across use case and port boundaries.
pub const Artifact = struct {
    request: flamegraph.Request,
    input_abs: []const u8,
    output_abs: []const u8,
    artifact: flamegraph.Artifact,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        self.artifact.deinit(allocator);
        allocator.free(self.input_abs);
        allocator.free(self.output_abs);
        self.* = undefined;
    }
};

/// Represents failure alternatives carried across the workflow boundary.
pub const Failure = union(enum) {
    workspace_path_failed: PathFailure,
    render_failed: RunFailure,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *Failure, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .render_failed => |*failure| failure.deinit(allocator),
            .workspace_path_failed => {},
        }
        self.* = undefined;
    }
};

/// Represents result alternatives carried across the workflow boundary.
pub const Result = union(enum) {
    ok: Artifact,
    err: Failure,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*artifact| artifact.deinit(allocator),
            .err => |*failure| failure.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Resolves the input/output paths under the workspace sandbox, then delegates to the
/// flamegraph backend run. This is the thin facade over `flamegraph.run` that owns path
/// resolution and surfaces resolution failures as `workspace_path_failed` (with
/// `for_output` marking which side failed). On success the returned artifact owns the
/// resolved absolute paths and the backend artifact; the caller must `deinit` it.
pub fn run(allocator: std.mem.Allocator, context: app_context.ProfilingContext, request: Request) !Result {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const input_abs = resolvePath(allocator, context, request.input, false) catch |err| return .{ .err = .{ .workspace_path_failed = .{
        .err = err,
        .path = request.input,
        .for_output = false,
    } } };
    var input_owned = true;
    defer if (input_owned) allocator.free(input_abs);
    const output_abs = resolvePath(allocator, context, request.output, true) catch |err| {
        return .{ .err = .{ .workspace_path_failed = .{
            .err = err,
            .path = request.output,
            .for_output = true,
        } } };
    };
    var output_owned = true;
    defer if (output_owned) allocator.free(output_abs);

    const resolved_request = flamegraph.Request{
        .tool_name = request.tool_name,
        .operation = request.operation,
        .input = request.input,
        .input_abs = input_abs,
        .output = request.output,
        .output_abs = output_abs,
        .format = request.format,
        .options = request.options,
    };

    var result = try flamegraph.run(allocator, context, resolved_request);
    switch (result) {
        .ok => |artifact| {
            result = undefined;
            input_owned = false;
            output_owned = false;
            return .{ .ok = .{
                .request = resolved_request,
                .input_abs = input_abs,
                .output_abs = output_abs,
                .artifact = artifact,
            } };
        },
        .err => |failure| {
            result = undefined;
            input_owned = false;
            output_owned = false;
            return .{ .err = .{ .render_failed = .{
                .request = resolved_request,
                .input_abs = input_abs,
                .output_abs = output_abs,
                .failure = failure,
            } } };
        },
    }
}

/// Resolves resolve path from caller-provided inputs; borrowed data remains caller-owned and failures are propagated.
fn resolvePath(allocator: std.mem.Allocator, context: app_context.ProfilingContext, path: []const u8, for_output: bool) ports.PortError![]const u8 {
    // Normalize and constrain path handling here before any downstream filesystem action.
    const resolved = try context.workspace_store.resolve(allocator, .{
        .path = path,
        .for_output = for_output,
        .provenance = if (for_output) "profiling output path resolution" else "profiling input path resolution",
    });
    defer resolved.deinit(allocator);
    return allocator.dupe(u8, resolved.path) catch return error.OutOfMemory;
}
