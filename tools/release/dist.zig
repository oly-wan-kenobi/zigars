//! Release packaging: builds per-platform archives and runs a smoke check.
//! `buildArchives` produces deterministic tar.gz files plus a SHA-256
//! checksum manifest; `smoke` verifies those archives are well-formed and
//! that the native binary reports the expected version on stderr.
const std = @import("std");
const release_targets = @import("release_targets.zig");
const zigars = @import("zigars");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// One release package requested by the build pipeline.
const PackageInput = struct {
    name: []const u8,
    exe_name: []const u8,
    binary_path: []const u8,
};

/// Repository file or directory copied into every release archive.
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

/// Parsed options for archive building.
const DistOptions = struct {
    out_dir: []const u8 = "dist",
    version: []const u8 = zigars.manifest.version.string,
    packages: std.ArrayList(PackageInput) = .empty,

    /// Releases package-list storage.
    fn deinit(self: *DistOptions, allocator: Allocator) void {
        self.packages.deinit(allocator);
    }
};

/// Prints the zigars version string to stdout followed by a newline.
pub fn printVersion(io: Io) !void {
    try stdoutPrint(io, "{s}\n", .{zigars.manifest.version.string});
}

/// Builds one tar.gz per `--package` flag and writes a SHA-256 checksum file.
/// Expects `--package <name> --exe <exe_name> --binary <path>` triples for
/// every configured release target; returns `error.InvalidArguments` when the
/// set is incomplete, has unknown names, duplicates, or wrong executable names.
/// The output directory is wiped and recreated unconditionally before staging.
pub fn buildArchives(allocator: Allocator, io: Io, args: []const []const u8) !void {
    // Construct this value in a single path so required fields cannot drift.
    var options = try parseDistOptions(allocator, args);
    defer options.deinit(allocator);
    if (options.packages.items.len == 0) return error.InvalidArguments;
    try validateReleasePackageInputs(io, options.packages.items);

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
    try stdoutPrint(io, "dist ok: {d} archives for zigars {s}\n", .{ options.packages.items.len, options.version });
}

/// Verifies the dist archive set: confirms checksum count and content, checks
/// that each archive contains required files, then extracts the native archive
/// and runs the binary to confirm it reports the right version on stderr.
/// Accepts `--assets-dir <dir>` and `--version <v>` flags; all other arguments
/// return `error.InvalidArguments`.
pub fn smoke(allocator: Allocator, io: Io, args: []const []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var assets_dir: []const u8 = "dist/assets";
    var version: []const u8 = zigars.manifest.version.string;
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
    for (release_targets.all) |package| {
        try verifyArchiveList(allocator, io, assets_dir, package);
    }
    try runNativeArchive(allocator, io, assets_dir, version);
    try stdoutPrint(io, "release asset smoke ok\n", .{});
}

/// Validates that package inputs exactly match the configured release targets.
fn validateReleasePackageInputs(io: ?Io, packages: []const PackageInput) !void {
    // Reject incompatible inputs early so callers get a precise failure reason.
    if (packages.len != release_targets.all.len) {
        if (io) |output| try stderrPrint(output, "dist expected {d} release packages, got {d}\n", .{ release_targets.all.len, packages.len });
        return error.InvalidArguments;
    }

    var seen = [_]bool{false} ** release_targets.all.len;
    for (packages) |package| {
        const index = release_targets.indexByPackageName(package.name) orelse {
            if (io) |output| try stderrPrint(output, "dist package is not a configured release target: {s}\n", .{package.name});
            return error.InvalidArguments;
        };
        if (seen[index]) {
            if (io) |output| try stderrPrint(output, "dist package was provided more than once: {s}\n", .{package.name});
            return error.InvalidArguments;
        }
        const expected = release_targets.all[index];
        if (!std.mem.eql(u8, package.exe_name, expected.exe_name)) {
            if (io) |output| try stderrPrint(output, "dist package {s} expected executable {s}, got {s}\n", .{ package.name, expected.exe_name, package.exe_name });
            return error.InvalidArguments;
        }
        seen[index] = true;
    }
}

/// Parses archive-builder CLI flags into a `DistOptions` value.
fn parseDistOptions(allocator: Allocator, args: []const []const u8) !DistOptions {
    // Normalize input here so downstream paths can rely on validated shape.
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

/// Stages one package directory with the binary and all release items.
fn stagePackage(allocator: Allocator, io: Io, package_dir: []const u8, package: PackageInput) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Copies one repository-relative file to the staged package tree.
fn copyFile(allocator: Allocator, io: Io, source: []const u8, dest: []const u8) !void {
    const abs_source = try absolutePath(allocator, io, source);
    defer allocator.free(abs_source);
    const abs_dest = try absolutePath(allocator, io, dest);
    defer allocator.free(abs_dest);
    try Io.Dir.copyFileAbsolute(abs_source, abs_dest, io, .{ .replace = true, .make_path = true });
}

/// Recursively copies a repository-relative directory into the package tree.
fn copyDirectory(allocator: Allocator, io: Io, source: []const u8, dest: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Writes one staged package directory as a compressed tar archive.
fn archivePackage(allocator: Allocator, io: Io, package_dir: []const u8, assets_dir: []const u8, package: PackageInput) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const root = try std.fs.path.join(allocator, &.{ package_dir, package.name });
    defer allocator.free(root);
    const archive_name = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{package.name});
    defer allocator.free(archive_name);
    const archive_path = try std.fs.path.join(allocator, &.{ assets_dir, archive_name });
    defer allocator.free(archive_path);
    try writeTarGzFromDirectory(allocator, io, root, package.name, package.exe_name, archive_path);
}

/// Streams a staged package directory into a deterministic gzip-compressed tar.
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
    // Sort paths so archive entry order is deterministic regardless of filesystem traversal order.
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
        // The root-level executable gets 0o755; every other entry is 0o644.
        const is_root_exe = std.mem.indexOfScalar(u8, normalized_rel, '/') == null and std.mem.eql(u8, normalized_rel, exe_name);
        try writeTarFile(io, &tar_writer, source_path, archive_rel, if (is_root_exe) 0o755 else 0o644);
    }
    try tar_writer.finishPedantically();
    try compressor.finish();
    try file_writer.interface.flush();
}

/// Streams one file from `source_path` into `tar_writer` at `archive_path`.
/// `mode` is the POSIX permission bits stored in the tar header; mtime is set
/// to zero for deterministic output.
fn writeTarFile(io: Io, tar_writer: *std.tar.Writer, source_path: []const u8, archive_path: []const u8, mode: u32) !void {
    var file = try Io.Dir.cwd().openFile(io, source_path, .{});
    defer file.close(io);
    var reader_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &reader_buffer);
    const size = try file_reader.getSize();
    try tar_writer.writeFileStream(archive_path, size, &file_reader.interface, .{ .mode = mode, .mtime = 0 });
}

/// Writes the checksum manifest for all release archives.
fn writeChecksums(allocator: Allocator, io: Io, assets_dir: []const u8, packages: []const PackageInput) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
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
    const checksums_path = try std.fs.path.join(allocator, &.{ assets_dir, "zigars-checksums.txt" });
    defer allocator.free(checksums_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = checksums_path, .data = out.written() });
}

/// Verifies checksum count and content against the current release target set.
fn verifyChecksums(allocator: Allocator, io: Io, assets_dir: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const checksums_path = try std.fs.path.join(allocator, &.{ assets_dir, "zigars-checksums.txt" });
    defer allocator.free(checksums_path);
    const checksums = try readFileAlloc(allocator, io, checksums_path, 1024 * 1024);
    defer allocator.free(checksums);

    const line_count = countNonEmptyLines(checksums);
    if (line_count != release_targets.all.len) {
        try stderrPrint(io, "checksum file expected {d} entries, got {d}\n", .{ release_targets.all.len, line_count });
        return error.ChecksumMismatch;
    }

    for (release_targets.all) |package| {
        const archive_name = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{package.package_name});
        defer allocator.free(archive_name);
        const archive_path = try std.fs.path.join(allocator, &.{ assets_dir, archive_name });
        defer allocator.free(archive_path);
        const hex = try archiveSha256(allocator, io, archive_path);
        const line = try std.fmt.allocPrint(allocator, "{s}  {s}", .{ hex[0..], archive_name });
        defer allocator.free(line);
        if (!containsLine(checksums, line)) {
            try stderrPrint(io, "checksum file missing or stale for {s}\n", .{archive_name});
            return error.ChecksumMismatch;
        }
    }
}

/// Verifies that one release archive contains the required package files.
fn verifyArchiveList(allocator: Allocator, io: Io, assets_dir: []const u8, package: release_targets.Target) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const archive_name = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{package.package_name});
    defer allocator.free(archive_name);
    const archive_path = try std.fs.path.join(allocator, &.{ assets_dir, archive_name });
    defer allocator.free(archive_path);
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "tar", "-tzf", archive_path } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!termOk(result.term)) {
        try stderrPrint(io, "tar failed to list {s}: {s}\n", .{ archive_name, result.stderr });
        return error.ArchiveListFailed;
    }

    const required = [_][]const u8{
        package.exe_name,
        "README.md",
        "CHANGELOG.md",
        "SECURITY.md",
        "docs/tools.md",
        "examples/tool-calls.jsonl",
    };
    for (required) |rel| {
        const entry = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ package.package_name, rel });
        defer allocator.free(entry);
        if (!containsLine(result.stdout, entry)) {
            try stderrPrint(io, "{s} is missing required file {s}\n", .{ archive_name, rel });
            return error.ArchiveMissingRequiredFile;
        }
    }
}

/// Extracts the native-platform archive to a temporary scratch directory and
/// runs the binary with `--version`.  The binary must produce no stdout output
/// and exactly "zigars <version>" on stderr.  Silently skips unsupported host
/// platforms (where `native()` returns null).
fn runNativeArchive(allocator: Allocator, io: Io, assets_dir: []const u8, version: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const package = release_targets.native() orelse return;
    const archive_name = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{package.package_name});
    defer allocator.free(archive_name);
    const archive_path = try std.fs.path.join(allocator, &.{ assets_dir, archive_name });
    defer allocator.free(archive_path);

    const scratch = ".zig-cache/zigars-dist-smoke";
    if (dirExists(io, scratch)) try Io.Dir.cwd().deleteTree(io, scratch);
    try Io.Dir.cwd().createDirPath(io, scratch);
    const extract = try std.process.run(allocator, io, .{ .argv = &.{ "tar", "-xzf", archive_path, "-C", scratch } });
    defer allocator.free(extract.stdout);
    defer allocator.free(extract.stderr);
    if (!termOk(extract.term)) return error.ArchiveExtractFailed;

    const binary = try std.fs.path.join(allocator, &.{ scratch, package.package_name, package.exe_name });
    defer allocator.free(binary);
    const version_result = try std.process.run(allocator, io, .{ .argv = &.{ binary, "--version" } });
    defer allocator.free(version_result.stdout);
    defer allocator.free(version_result.stderr);
    if (!termOk(version_result.term)) return error.NativeArchiveRunFailed;
    if (std.mem.trim(u8, version_result.stdout, " \t\r\n").len != 0) return error.NativeArchiveUnexpectedStdout;
    const expected = try std.fmt.allocPrint(allocator, "zigars {s}", .{version});
    defer allocator.free(expected);
    const stderr = std.mem.trim(u8, version_result.stderr, " \t\r\n");
    if (!std.mem.eql(u8, stderr, expected)) return error.NativeArchiveVersionMismatch;
}

/// Computes the lowercase hex SHA-256 digest for an archive file.
fn archiveSha256(allocator: Allocator, io: Io, path: []const u8) ![Sha256.digest_length * 2]u8 {
    const bytes = try readFileAlloc(allocator, io, path, 1024 * 1024 * 1024);
    defer allocator.free(bytes);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Returns a copy of `path` with the platform separator replaced by '/'.
/// Caller owns the returned slice and must free it with `allocator`.
/// On POSIX hosts this is a plain dupe; the replacement only applies on Windows.
fn normalizePath(allocator: Allocator, path: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, path);
    if (std.fs.path.sep != '/') {
        std.mem.replaceScalar(u8, normalized, std.fs.path.sep, '/');
    }
    return normalized;
}

/// Resolves `path` to an absolute path using the current working directory.
fn absolutePath(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    return std.fs.path.resolve(allocator, &.{ cwd_buf[0..cwd_len], path });
}

/// Reads a repository-relative file with a byte limit.
fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, limit: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

/// Returns whether `path` is an openable directory.
fn dirExists(io: Io, path: []const u8) bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Reports whether `needle` appears as a complete line in `haystack`.
fn containsLine(haystack: []const u8, needle: []const u8) bool {
    var lines = std.mem.splitScalar(u8, haystack, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, "\r"), needle)) return true;
    }
    return false;
}

/// Counts non-empty lines after trimming whitespace.
fn countNonEmptyLines(bytes: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        if (std.mem.trim(u8, raw, " \t\r").len != 0) count += 1;
    }
    return count;
}

/// Reports whether a child process exited successfully.
fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Sort predicate for deterministic archive entry ordering.
fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

/// Writes a formatted message to stdout.
fn stdoutPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

/// Writes a formatted diagnostic to stderr.
fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "containsLine matches complete lines only" {
    try std.testing.expect(containsLine("a\nb\n", "b"));
    try std.testing.expect(!containsLine("abc\n", "b"));
}

test "dist package validation requires the configured release set" {
    const packages = [_]PackageInput{
        .{ .name = "zigars-x86_64-linux-gnu", .exe_name = "zigars", .binary_path = "bin/linux-gnu-x64" },
        .{ .name = "zigars-aarch64-linux-gnu", .exe_name = "zigars", .binary_path = "bin/linux-gnu-arm64" },
        .{ .name = "zigars-x86_64-linux-musl", .exe_name = "zigars", .binary_path = "bin/linux-x64" },
        .{ .name = "zigars-aarch64-linux-musl", .exe_name = "zigars", .binary_path = "bin/linux-arm64" },
        .{ .name = "zigars-x86_64-macos", .exe_name = "zigars", .binary_path = "bin/macos-x64" },
        .{ .name = "zigars-aarch64-macos", .exe_name = "zigars", .binary_path = "bin/macos-arm64" },
        .{ .name = "zigars-x86_64-windows-gnu", .exe_name = "zigars.exe", .binary_path = "bin/windows-x64" },
        .{ .name = "zigars-aarch64-windows-gnu", .exe_name = "zigars.exe", .binary_path = "bin/windows-arm64" },
    };
    try validateReleasePackageInputs(null, &packages);

    var missing = packages[0 .. packages.len - 1].*;
    try std.testing.expectError(error.InvalidArguments, validateReleasePackageInputs(null, &missing));

    var duplicate = packages;
    duplicate[1].name = duplicate[0].name;
    try std.testing.expectError(error.InvalidArguments, validateReleasePackageInputs(null, &duplicate));

    var wrong_exe = packages;
    wrong_exe[6].exe_name = "zigars";
    try std.testing.expectError(error.InvalidArguments, validateReleasePackageInputs(null, &wrong_exe));

    var missing_with_io = packages[0 .. packages.len - 1].*;
    try std.testing.expectError(error.InvalidArguments, validateReleasePackageInputs(std.testing.io, &missing_with_io));

    var unknown_with_io = packages;
    unknown_with_io[0].name = "zigars-unknown";
    try std.testing.expectError(error.InvalidArguments, validateReleasePackageInputs(std.testing.io, &unknown_with_io));
}

test "countNonEmptyLines ignores trailing blank lines" {
    try std.testing.expectEqual(@as(usize, 0), countNonEmptyLines(""));
    try std.testing.expectEqual(@as(usize, 1), countNonEmptyLines("one\n\n"));
    try std.testing.expectEqual(@as(usize, 2), countNonEmptyLines("one\r\ntwo\n"));
}
