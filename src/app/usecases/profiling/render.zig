const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const flamegraph_model = @import("../../../domain/profiling/flamegraph.zig");
const flamegraph = @import("flamegraph.zig");

pub const Request = struct {
    tool_name: []const u8 = "zig_flamegraph",
    operation: []const u8 = "render_flamegraph",
    input: []const u8,
    output: []const u8,
    format: flamegraph_model.ZflameFormat,
    options: flamegraph_model.ZflameRenderOptions = .{},
};

pub const PathFailure = struct {
    err: ports.PortError,
    path: []const u8,
    for_output: bool = false,
};

pub const RunFailure = struct {
    request: flamegraph.Request,
    input_abs: []const u8,
    output_abs: []const u8,
    failure: flamegraph.Failure,

    pub fn deinit(self: *RunFailure, allocator: std.mem.Allocator) void {
        self.failure.deinit(allocator);
        allocator.free(self.input_abs);
        allocator.free(self.output_abs);
        self.* = undefined;
    }
};

pub const Artifact = struct {
    request: flamegraph.Request,
    input_abs: []const u8,
    output_abs: []const u8,
    artifact: flamegraph.Artifact,

    pub fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        self.artifact.deinit(allocator);
        allocator.free(self.input_abs);
        allocator.free(self.output_abs);
        self.* = undefined;
    }
};

pub const Failure = union(enum) {
    workspace_path_failed: PathFailure,
    render_failed: RunFailure,

    pub fn deinit(self: *Failure, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .render_failed => |*failure| failure.deinit(allocator),
            .workspace_path_failed => {},
        }
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    ok: Artifact,
    err: Failure,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*artifact| artifact.deinit(allocator),
            .err => |*failure| failure.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub fn run(allocator: std.mem.Allocator, context: app_context.ProfilingContext, request: Request) !Result {
    const input_abs = resolvePath(allocator, context, request.input, false) catch |err| return .{ .err = .{ .workspace_path_failed = .{
        .err = err,
        .path = request.input,
        .for_output = false,
    } } };
    errdefer allocator.free(input_abs);
    const output_abs = resolvePath(allocator, context, request.output, true) catch |err| {
        allocator.free(input_abs);
        return .{ .err = .{ .workspace_path_failed = .{
            .err = err,
            .path = request.output,
            .for_output = true,
        } } };
    };
    errdefer allocator.free(output_abs);

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
            return .{ .ok = .{
                .request = resolved_request,
                .input_abs = input_abs,
                .output_abs = output_abs,
                .artifact = artifact,
            } };
        },
        .err => |failure| {
            result = undefined;
            return .{ .err = .{ .render_failed = .{
                .request = resolved_request,
                .input_abs = input_abs,
                .output_abs = output_abs,
                .failure = failure,
            } } };
        },
    }
}

fn resolvePath(allocator: std.mem.Allocator, context: app_context.ProfilingContext, path: []const u8, for_output: bool) ports.PortError![]const u8 {
    const resolved = try context.workspace_store.resolve(allocator, .{
        .path = path,
        .for_output = for_output,
        .provenance = if (for_output) "profiling output path resolution" else "profiling input path resolution",
    });
    defer resolved.deinit(allocator);
    return allocator.dupe(u8, resolved.path) catch return error.OutOfMemory;
}
