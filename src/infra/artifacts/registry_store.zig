const std = @import("std");

const ports = @import("../../app/ports.zig");
const artifacts = @import("../../artifacts.zig");
const workspace_mod = @import("../../workspace.zig");

const artifact_root = ".zigar-cache/artifacts";

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
        errdefer allocator.free(id);
        const uri = std.fmt.allocPrint(allocator, "zigar://artifact/{s}", .{rel_path}) catch return error.OutOfMemory;
        errdefer allocator.free(uri);
        const checksum = allocator.dupe(u8, identity.sha256) catch return error.OutOfMemory;
        errdefer allocator.free(checksum);
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

test "artifact registry store writes reads and records provenance" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
    defer allocator.free(root);

    var workspace = try workspace_mod.Workspace.init(allocator, io, root, null);
    defer workspace.deinit();
    var store = Store.init(&workspace, io, .{ .zig_path = "zig", .zls_path = "zls", .zflame_path = "zflame", .diff_folded_path = "diff-folded" });

    const ref = try store.port().put(allocator, .{
        .namespace = "reports",
        .name = "summary.json",
        .kind = "json_report",
        .bytes = "{\"ok\":true}\n",
        .provenance = "artifact_test",
    });
    defer ref.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 12), ref.bytes_written);
    try std.testing.expectEqualStrings(".zigar-cache/artifacts/reports/summary.json", ref.id);

    const read_result = try store.port().read(allocator, .{ .id = ref.id });
    defer read_result.deinit(allocator);
    try std.testing.expectEqualStrings("{\"ok\":true}\n", read_result.bytes);

    const registry_abs = try workspace.resolveOutput(artifacts.default_registry_path);
    defer workspace.allocator.free(registry_abs);
    var registry = try artifacts.loadRegistry(allocator, io, registry_abs);
    defer registry.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), registry.entries.items.len);
    try std.testing.expectEqualStrings(ref.id, registry.entries.items[0].path);
    try std.testing.expectEqualStrings("artifact_test", registry.entries.items[0].producer);
    try std.testing.expectEqualStrings("json_report", registry.entries.items[0].artifact_kind);
    try std.testing.expectEqualStrings(ref.checksum.?, registry.entries.items[0].sha256);
}

test "artifact registry store rejects path traversal names" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root");
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
    defer allocator.free(root);

    var workspace = try workspace_mod.Workspace.init(allocator, io, root, null);
    defer workspace.deinit();
    var store = Store.init(&workspace, io, .{ .zig_path = "zig" });

    try std.testing.expectError(error.InvalidRequest, store.port().put(allocator, .{
        .namespace = "reports",
        .name = "../escape.json",
        .kind = "json_report",
        .bytes = "{}",
    }));
}

test "artifact registry store read is scoped to artifact ids" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "root/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/src/main.zig", .data = "pub const not_artifact = true;\n" });
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "root" });
    defer allocator.free(base);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(io, base, allocator);
    defer allocator.free(root);

    var workspace = try workspace_mod.Workspace.init(allocator, io, root, null);
    defer workspace.deinit();
    var store = Store.init(&workspace, io, .{ .zig_path = "zig" });

    const ref = try store.port().put(allocator, .{
        .namespace = "reports",
        .name = "scoped.txt",
        .kind = "text",
        .bytes = "artifact bytes",
        .provenance = "artifact_read_scope_test",
    });
    defer ref.deinit(allocator);
    const read_result = try store.port().read(allocator, .{ .id = ref.id });
    defer read_result.deinit(allocator);
    try std.testing.expectEqualStrings("artifact bytes", read_result.bytes);

    try std.testing.expectError(error.InvalidRequest, store.port().read(allocator, .{ .id = "src/main.zig" }));
    try std.testing.expectError(error.InvalidRequest, store.port().read(allocator, .{ .id = ".zigar-cache/artifacts/reports/../escape.txt" }));
    try std.testing.expectError(error.InvalidRequest, store.port().read(allocator, .{ .id = "/tmp/escape.txt" }));
}
