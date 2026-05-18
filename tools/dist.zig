const std = @import("std");
const builtin = @import("builtin");
const zigar = @import("zigar");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const PackageInput = struct {
    name: []const u8,
    exe_name: []const u8,
    binary_path: []const u8,
};

const ReleasePackage = struct {
    name: []const u8,
    exe_name: []const u8 = "zigar",
};

const release_packages = [_]ReleasePackage{
    .{ .name = "zigar-x86_64-linux-musl" },
    .{ .name = "zigar-aarch64-linux-musl" },
    .{ .name = "zigar-x86_64-macos" },
    .{ .name = "zigar-aarch64-macos" },
    .{ .name = "zigar-x86_64-windows", .exe_name = "zigar.exe" },
};

const ReleaseItem = struct {
    path: []const u8,
    directory: bool = false,
};

const release_items = [_]ReleaseItem{
    .{ .path = "README.md" },
    .{ .path = "CHANGELOG.md" },
    .{ .path = "CONTRIBUTING.md" },
    .{ .path = "SECURITY.md" },
    .{ .path = "LICENSE" },
    .{ .path = "NOTICE.md" },
    .{ .path = "docs", .directory = true },
    .{ .path = "examples", .directory = true },
};

const DistOptions = struct {
    out_dir: []const u8 = "dist",
    version: []const u8 = zigar.version.string,
    packages: std.ArrayList(PackageInput) = .empty,

    fn deinit(self: *DistOptions, allocator: Allocator) void {
        self.packages.deinit(allocator);
    }
};

pub fn printVersion(io: Io) !void {
    try stdoutPrint(io, "{s}\n", .{zigar.version.string});
}

pub fn buildArchives(allocator: Allocator, io: Io, args: []const []const u8) !void {
    var options = try parseDistOptions(allocator, args);
    defer options.deinit(allocator);
    if (options.packages.items.len == 0) return error.InvalidArguments;

    if (dirExists(io, options.out_dir)) try Io.Dir.cwd().deleteTree(io, options.out_dir);
    const assets_dir = try std.fs.path.join(allocator, &.{ options.out_dir, "assets" });
    defer allocator.free(assets_dir);
    const package_dir = try std.fs.path.join(allocator, &.{ options.out_dir, "package" });
    defer allocator.free(package_dir);
    try Io.Dir.cwd().createDirPath(io, assets_dir);
    try Io.Dir.cwd().createDirPath(io, package_dir);

    for (options.packages.items) |package| {
        try stagePackage(allocator, io, package_dir, package);
        try archivePackage(allocator, io, package_dir, assets_dir, package);
    }
    try writeChecksums(allocator, io, assets_dir, options.packages.items);
    try stdoutPrint(io, "dist ok: {d} archives for zigar {s}\n", .{ options.packages.items.len, options.version });
}

pub fn smoke(allocator: Allocator, io: Io, args: []const []const u8) !void {
    var assets_dir: []const u8 = "dist/assets";
    var version: []const u8 = zigar.version.string;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--assets-dir")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            assets_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--version")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            version = args[i];
        } else {
            return error.InvalidArguments;
        }
    }

    try verifyChecksums(allocator, io, assets_dir);
    for (release_packages) |package| {
        try verifyArchiveList(allocator, io, assets_dir, package);
    }
    try runNativeArchive(allocator, io, assets_dir, version);
    try stdoutPrint(io, "release asset smoke ok\n", .{});
}

fn parseDistOptions(allocator: Allocator, args: []const []const u8) !DistOptions {
    var options: DistOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out-dir")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.out_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--version")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            options.version = args[i];
        } else if (std.mem.eql(u8, args[i], "--package")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            const name = args[i];
            if (i + 4 >= args.len) return error.InvalidArguments;
            if (!std.mem.eql(u8, args[i + 1], "--exe")) return error.InvalidArguments;
            if (!std.mem.eql(u8, args[i + 3], "--binary")) return error.InvalidArguments;
            try options.packages.append(allocator, .{
                .name = name,
                .exe_name = args[i + 2],
                .binary_path = args[i + 4],
            });
            i += 4;
        } else {
            return error.InvalidArguments;
        }
    }
    return options;
}

fn stagePackage(allocator: Allocator, io: Io, package_dir: []const u8, package: PackageInput) !void {
    const root = try std.fs.path.join(allocator, &.{ package_dir, package.name });
    defer allocator.free(root);
    try Io.Dir.cwd().createDirPath(io, root);

    const binary_dest = try std.fs.path.join(allocator, &.{ root, package.exe_name });
    defer allocator.free(binary_dest);
    try copyFile(allocator, io, package.binary_path, binary_dest);

    for (release_items) |item| {
        const dest = try std.fs.path.join(allocator, &.{ root, item.path });
        defer allocator.free(dest);
        if (item.directory) {
            try copyDirectory(allocator, io, item.path, dest);
        } else {
            try copyFile(allocator, io, item.path, dest);
        }
    }
}

fn copyFile(allocator: Allocator, io: Io, source: []const u8, dest: []const u8) !void {
    const abs_source = try absolutePath(allocator, io, source);
    defer allocator.free(abs_source);
    const abs_dest = try absolutePath(allocator, io, dest);
    defer allocator.free(abs_dest);
    try Io.Dir.copyFileAbsolute(abs_source, abs_dest, io, .{ .replace = true, .make_path = true });
}

fn copyDirectory(allocator: Allocator, io: Io, source: []const u8, dest: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io, source, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                const rel_dest = try std.fs.path.join(allocator, &.{ dest, entry.path });
                defer allocator.free(rel_dest);
                try Io.Dir.cwd().createDirPath(io, rel_dest);
            },
            .file => {
                const rel_source = try std.fs.path.join(allocator, &.{ source, entry.path });
                defer allocator.free(rel_source);
                const rel_dest = try std.fs.path.join(allocator, &.{ dest, entry.path });
                defer allocator.free(rel_dest);
                try copyFile(allocator, io, rel_source, rel_dest);
            },
            else => {},
        }
    }
}

fn archivePackage(allocator: Allocator, io: Io, package_dir: []const u8, assets_dir: []const u8, package: PackageInput) !void {
    const root = try std.fs.path.join(allocator, &.{ package_dir, package.name });
    defer allocator.free(root);
    const archive_name = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{package.name});
    defer allocator.free(archive_name);
    const archive_path = try std.fs.path.join(allocator, &.{ assets_dir, archive_name });
    defer allocator.free(archive_path);
    try writeTarGzFromDirectory(allocator, io, root, package.name, package.exe_name, archive_path);
}

fn writeTarGzFromDirectory(
    allocator: Allocator,
    io: Io,
    root: []const u8,
    archive_root: []const u8,
    exe_name: []const u8,
    archive_path: []const u8,
) !void {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file) try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]u8, paths.items, {}, stringLessThan);

    var out_file = try Io.Dir.cwd().createFile(io, archive_path, .{ .truncate = true });
    defer out_file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = out_file.writerStreaming(io, &file_buffer);
    var compression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(
        &file_writer.interface,
        &compression_buffer,
        .gzip,
        std.compress.flate.Compress.Options.fastest,
    );
    var tar_writer = std.tar.Writer{ .underlying_writer = &compressor.writer };
    for (paths.items) |rel_path| {
        const source_path = try std.fs.path.join(allocator, &.{ root, rel_path });
        defer allocator.free(source_path);
        const normalized_rel = try normalizePath(allocator, rel_path);
        defer allocator.free(normalized_rel);
        const archive_rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ archive_root, normalized_rel });
        defer allocator.free(archive_rel);
        const is_root_exe = std.mem.indexOfScalar(u8, normalized_rel, '/') == null and std.mem.eql(u8, normalized_rel, exe_name);
        try writeTarFile(io, &tar_writer, source_path, archive_rel, if (is_root_exe) 0o755 else 0o644);
    }
    try tar_writer.finishPedantically();
    try compressor.finish();
    try file_writer.interface.flush();
}

fn writeTarFile(io: Io, tar_writer: *std.tar.Writer, source_path: []const u8, archive_path: []const u8, mode: u32) !void {
    var file = try Io.Dir.cwd().openFile(io, source_path, .{});
    defer file.close(io);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &reader_buffer);
    const size = try file_reader.getSize();
    try tar_writer.writeFileStream(archive_path, size, &file_reader.interface, .{ .mode = mode, .mtime = 0 });
}

fn writeChecksums(allocator: Allocator, io: Io, assets_dir: []const u8, packages: []const PackageInput) !void {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (packages) |package| {
        const archive_name = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{package.name});
        defer allocator.free(archive_name);
        const archive_path = try std.fs.path.join(allocator, &.{ assets_dir, archive_name });
        defer allocator.free(archive_path);
        const hex = try archiveSha256(allocator, io, archive_path);
        try out.writer.print("{s}  {s}\n", .{ hex[0..], archive_name });
    }
    const checksums_path = try std.fs.path.join(allocator, &.{ assets_dir, "zigar-checksums.txt" });
    defer allocator.free(checksums_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = checksums_path, .data = out.written() });
}

fn verifyChecksums(allocator: Allocator, io: Io, assets_dir: []const u8) !void {
    const checksums_path = try std.fs.path.join(allocator, &.{ assets_dir, "zigar-checksums.txt" });
    defer allocator.free(checksums_path);
    const checksums = try readFileAlloc(allocator, io, checksums_path, 1024 * 1024);
    defer allocator.free(checksums);

    for (release_packages) |package| {
        const archive_name = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{package.name});
        defer allocator.free(archive_name);
        const archive_path = try std.fs.path.join(allocator, &.{ assets_dir, archive_name });
        defer allocator.free(archive_path);
        const hex = try archiveSha256(allocator, io, archive_path);
        const line = try std.fmt.allocPrint(allocator, "{s}  {s}", .{ hex[0..], archive_name });
        defer allocator.free(line);
        if (!containsLine(checksums, line)) return error.ChecksumMismatch;
    }
}

fn verifyArchiveList(allocator: Allocator, io: Io, assets_dir: []const u8, package: ReleasePackage) !void {
    const archive_name = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{package.name});
    defer allocator.free(archive_name);
    const archive_path = try std.fs.path.join(allocator, &.{ assets_dir, archive_name });
    defer allocator.free(archive_path);
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "tar", "-tzf", archive_path } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!termOk(result.term)) return error.ArchiveListFailed;

    const required = [_][]const u8{
        package.exe_name,
        "README.md",
        "CHANGELOG.md",
        "SECURITY.md",
        "docs/tools.md",
        "examples/tool-calls.jsonl",
    };
    for (required) |rel| {
        const entry = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ package.name, rel });
        defer allocator.free(entry);
        if (!containsLine(result.stdout, entry)) return error.ArchiveMissingRequiredFile;
    }
}

fn runNativeArchive(allocator: Allocator, io: Io, assets_dir: []const u8, version: []const u8) !void {
    const package = nativePackage() orelse return;
    const archive_name = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{package.name});
    defer allocator.free(archive_name);
    const archive_path = try std.fs.path.join(allocator, &.{ assets_dir, archive_name });
    defer allocator.free(archive_path);

    const scratch = ".zig-cache/zigar-dist-smoke";
    if (dirExists(io, scratch)) try Io.Dir.cwd().deleteTree(io, scratch);
    try Io.Dir.cwd().createDirPath(io, scratch);
    const extract = try std.process.run(allocator, io, .{ .argv = &.{ "tar", "-xzf", archive_path, "-C", scratch } });
    defer allocator.free(extract.stdout);
    defer allocator.free(extract.stderr);
    if (!termOk(extract.term)) return error.ArchiveExtractFailed;

    const binary = try std.fs.path.join(allocator, &.{ scratch, package.name, package.exe_name });
    defer allocator.free(binary);
    const version_result = try std.process.run(allocator, io, .{ .argv = &.{ binary, "--version" } });
    defer allocator.free(version_result.stdout);
    defer allocator.free(version_result.stderr);
    if (!termOk(version_result.term)) return error.NativeArchiveRunFailed;
    if (std.mem.trim(u8, version_result.stdout, " \t\r\n").len != 0) return error.NativeArchiveUnexpectedStdout;
    const expected = try std.fmt.allocPrint(allocator, "zigar {s}", .{version});
    defer allocator.free(expected);
    const stderr = std.mem.trim(u8, version_result.stderr, " \t\r\n");
    if (!std.mem.eql(u8, stderr, expected)) return error.NativeArchiveVersionMismatch;
}

fn nativePackage() ?ReleasePackage {
    return switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .name = "zigar-x86_64-linux-musl" },
            .aarch64 => .{ .name = "zigar-aarch64-linux-musl" },
            else => null,
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => .{ .name = "zigar-x86_64-macos" },
            .aarch64 => .{ .name = "zigar-aarch64-macos" },
            else => null,
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => .{ .name = "zigar-x86_64-windows", .exe_name = "zigar.exe" },
            else => null,
        },
        else => null,
    };
}

fn archiveSha256(allocator: Allocator, io: Io, path: []const u8) ![Sha256.digest_length * 2]u8 {
    const bytes = try readFileAlloc(allocator, io, path, 1024 * 1024 * 1024);
    defer allocator.free(bytes);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn normalizePath(allocator: Allocator, path: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, path);
    if (std.fs.path.sep != '/') {
        std.mem.replaceScalar(u8, normalized, std.fs.path.sep, '/');
    }
    return normalized;
}

fn absolutePath(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.resolve(allocator, &.{ cwd_buf[0..cwd_len], path });
}

fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, limit: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

fn dirExists(io: Io, path: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

fn containsLine(haystack: []const u8, needle: []const u8) bool {
    var lines = std.mem.splitScalar(u8, haystack, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, "\r"), needle)) return true;
    }
    return false;
}

fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn stdoutPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "containsLine matches complete lines only" {
    try std.testing.expect(containsLine("a\nb\n", "b"));
    try std.testing.expect(!containsLine("abc\n", "b"));
}
