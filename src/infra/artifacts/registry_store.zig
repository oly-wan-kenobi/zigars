const std = @import("std");

const ports = @import("../../app/ports.zig");
const artifacts = @import("registry.zig");
const workspace_mod = @import("../workspace/workspace.zig");

const artifact_root = ".zigar-cache/artifacts";
const max_workspace_record_bytes = 16 * 1024 * 1024;

pub const Store = struct {
    workspace: *workspace_mod.Workspace,
    io: std.Io,
    toolchain: artifacts.Toolchain,

    const Self = @This();

    pub fn init(workspace: *workspace_mod.Workspace, io: std.Io, toolchain: artifacts.Toolchain) Self {
        return .{
            .workspace = workspace,
            .io = io,
            .toolchain = toolchain,
        };
    }

    pub fn port(self: *Self) ports.ArtifactStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .put = put,
                .read = read,
                .record_workspace = recordWorkspace,
            },
        };
    }

    fn put(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.ArtifactWriteRequest) ports.PortError!ports.ArtifactRef {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const rel_path = artifactPath(allocator, request.namespace, request.name) catch |err| return mapPortError(err);
        defer allocator.free(rel_path);

        self.workspace.writeFile(self.io, rel_path, request.bytes) catch |err| return mapPortError(err);
        const artifact_abs = self.workspace.resolveOutput(rel_path) catch |err| return mapPortError(err);
        defer self.workspace.allocator.free(artifact_abs);
        const abs_owned = allocator.dupe(u8, artifact_abs) catch return error.OutOfMemory;
        defer allocator.free(abs_owned);
        const identity = artifacts.identityFromBytes(allocator, rel_path, abs_owned, request.bytes) catch |err| return mapPortError(err);
        defer allocator.free(identity.sha256);

        const registry_abs = self.workspace.resolveOutput(artifacts.default_registry_path) catch |err| return mapPortError(err);
        defer self.workspace.allocator.free(registry_abs);
        var registry = artifacts.loadRegistry(allocator, self.io, registry_abs) catch |err| return mapPortError(err);
        defer registry.deinit(allocator);
        artifacts.upsert(&registry, allocator, .{
            .identity = identity,
            .provenance = .{
                .producer = if (request.provenance.len > 0) request.provenance else request.namespace,
                .artifact_kind = request.kind,
                .notes = "artifact_store.put",
                .toolchain = self.toolchain,
            },
            .indexed_at_unix_ms = unixMs(self.io),
        }) catch |err| return mapPortError(err);
        artifacts.writeRegistry(allocator, self.io, registry_abs, registry) catch |err| return mapPortError(err);

        const id = allocator.dupe(u8, rel_path) catch return error.OutOfMemory;
        var id_owned = true;
        defer if (id_owned) allocator.free(id);
        const uri = std.fmt.allocPrint(allocator, "zigar://artifact/{s}", .{rel_path}) catch return error.OutOfMemory;
        var uri_owned = true;
        defer if (uri_owned) allocator.free(uri);
        const checksum = allocator.dupe(u8, identity.sha256) catch return error.OutOfMemory;
        var checksum_owned = true;
        defer if (checksum_owned) allocator.free(checksum);
        id_owned = false;
        uri_owned = false;
        checksum_owned = false;
        return .{
            .id = id,
            .uri = uri,
            .checksum = checksum,
            .bytes_written = request.bytes.len,
            .owns_memory = true,
        };
    }

    fn read(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.ArtifactReadRequest) ports.PortError!ports.ArtifactReadResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (!safeArtifactId(request.id)) return error.InvalidRequest;
        const resolved = self.workspace.resolve(request.id) catch |err| return mapPortError(err);
        defer self.workspace.allocator.free(resolved);
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, resolved, allocator, .limited(artifacts.default_read_limit)) catch |err| return mapPortError(err);
        errdefer allocator.free(bytes);
        return .{
            .bytes = bytes,
            .owns_bytes = true,
        };
    }

    fn recordWorkspace(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.WorkspaceArtifactRecordRequest) ports.PortError!ports.WorkspaceArtifactRef {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const bytes = if (request.bytes) |provided| provided else blk: {
            const resolved = self.workspace.resolve(request.path) catch |err| return mapPortError(err);
            defer self.workspace.allocator.free(resolved);
            const data = std.Io.Dir.cwd().readFileAlloc(self.io, resolved, allocator, .limited(max_workspace_record_bytes)) catch |err| return mapPortError(err);
            break :blk data;
        };
        const owns_read = request.bytes == null;
        defer if (owns_read) allocator.free(bytes);

        if (request.bytes != null) {
            self.workspace.writeFile(self.io, request.path, bytes) catch |err| return mapPortError(err);
        }
        const artifact_abs = self.workspace.resolveOutput(request.path) catch |err| return mapPortError(err);
        defer self.workspace.allocator.free(artifact_abs);
        const abs_owned = allocator.dupe(u8, artifact_abs) catch return error.OutOfMemory;
        var abs_owned_guard = true;
        defer if (abs_owned_guard) allocator.free(abs_owned);
        const path_owned = allocator.dupe(u8, request.path) catch return error.OutOfMemory;
        var path_owned_guard = true;
        defer if (path_owned_guard) allocator.free(path_owned);
        const identity = artifacts.identityFromBytes(allocator, path_owned, abs_owned, bytes) catch |err| return mapPortError(err);
        var sha_owned_guard = true;
        defer if (sha_owned_guard) allocator.free(identity.sha256);

        const registry_abs = self.workspace.resolveOutput(artifacts.default_registry_path) catch |err| return mapPortError(err);
        defer self.workspace.allocator.free(registry_abs);
        var registry = artifacts.loadRegistry(allocator, self.io, registry_abs) catch |err| return mapPortError(err);
        defer registry.deinit(allocator);
        artifacts.upsert(&registry, allocator, .{
            .identity = identity,
            .provenance = .{
                .producer = request.producer,
                .artifact_kind = request.artifact_kind,
                .command_argv = request.command_argv,
                .backend_name = request.backend_name,
                .backend_version = request.backend_version,
                .target = request.target,
                .baseline_identity = request.baseline_identity,
                .notes = request.notes,
                .toolchain = .{
                    .zig_path = request.toolchain.zig_path,
                    .zls_path = request.toolchain.zls_path,
                    .zflame_path = request.toolchain.zflame_path,
                    .diff_folded_path = request.toolchain.diff_folded_path,
                },
            },
            .indexed_at_unix_ms = if (request.indexed_at_unix_ms != 0) request.indexed_at_unix_ms else unixMs(self.io),
        }) catch |err| return mapPortError(err);
        artifacts.writeRegistry(allocator, self.io, registry_abs, registry) catch |err| return mapPortError(err);

        path_owned_guard = false;
        abs_owned_guard = false;
        sha_owned_guard = false;
        return .{
            .path = path_owned,
            .abs_path = abs_owned,
            .bytes = bytes.len,
            .sha256 = identity.sha256,
            .indexed_at_unix_ms = if (request.indexed_at_unix_ms != 0) request.indexed_at_unix_ms else unixMs(self.io),
            .owns_memory = true,
        };
    }
};

fn artifactPath(allocator: std.mem.Allocator, namespace: []const u8, name: []const u8) ![]u8 {
    if (!safeRelativeComponent(namespace) or !safeRelativeComponent(name)) return error.InvalidArguments;
    return std.fs.path.join(allocator, &.{ artifact_root, namespace, name });
}

fn safeArtifactId(id: []const u8) bool {
    if (id.len == 0) return false;
    if (std.fs.path.isAbsolute(id)) return false;
    if (id[0] == '/' or id[0] == '\\') return false;

    var part_index: usize = 0;
    var start: usize = 0;
    for (id, 0..) |byte, index| {
        if (byte != '/' and byte != '\\') continue;
        if (!safeArtifactIdPart(part_index, id[start..index])) return false;
        part_index += 1;
        start = index + 1;
    }
    if (!safeArtifactIdPart(part_index, id[start..])) return false;
    return part_index >= 2;
}

fn safeArtifactIdPart(index: usize, part: []const u8) bool {
    if (part.len == 0) return false;
    if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return switch (index) {
        0 => std.mem.eql(u8, part, ".zigar-cache"),
        1 => std.mem.eql(u8, part, "artifacts"),
        else => true,
    };
}

fn safeRelativeComponent(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.fs.path.isAbsolute(value)) return false;
    var start: usize = 0;
    for (value, 0..) |byte, index| {
        if (byte != '/' and byte != '\\') continue;
        if (!safePathPart(value[start..index])) return false;
        start = index + 1;
    }
    return safePathPart(value[start..]);
}

fn safePathPart(value: []const u8) bool {
    if (value.len == 0) return true;
    return !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..");
}

fn unixMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_ms));
}

pub fn mapPortError(err: anyerror) ports.PortError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.Timeout => error.Timeout,
        error.RequestTimeout => error.RequestTimeout,
        error.EndOfStream => error.EndOfStream,
        error.BrokenPipe => error.BrokenPipe,
        error.PathOutsideWorkspace => error.PathOutsideWorkspace,
        error.EmptyPath => error.EmptyPath,
        error.StreamTooLong => error.StreamTooLong,
        error.InvalidArguments => error.InvalidRequest,
        error.InvalidArtifactRegistryEntry => error.InvalidRequest,
        else => error.Unavailable,
    };
}

test "artifact registry store records existing workspace artifacts and nested components" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/zig-out/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/zig-out/nested/report.txt", .data = "existing artifact\n" });
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
    defer allocator.free(root);

    var workspace = try workspace_mod.Workspace.init(allocator, io, root, null);
    defer workspace.deinit();
    var store = Store.init(&workspace, io, .{ .zig_path = "zig" });

    const nested_path = try artifactPath(allocator, "nested/reports", "summary.json");
    defer allocator.free(nested_path);
    try std.testing.expectEqualStrings(".zigar-cache/artifacts/nested/reports/summary.json", nested_path);

    const ref = try store.port().recordWorkspace(allocator, .{
        .path = "zig-out/nested/report.txt",
        .producer = "artifact-test",
        .artifact_kind = "text",
        .toolchain = .{ .zig_path = "zig" },
        .indexed_at_unix_ms = 42,
    });
    defer ref.deinit(allocator);
    try std.testing.expectEqualStrings("zig-out/nested/report.txt", ref.path);
    try std.testing.expectEqual(@as(usize, "existing artifact\n".len), ref.bytes);
    try std.testing.expectEqual(@as(i64, 42), ref.indexed_at_unix_ms);
}
