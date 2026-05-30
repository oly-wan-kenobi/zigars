//! Workspace scanning use-cases for import graph and targeted source extraction.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");

/// Default scan limit used when the caller omits an explicit value.
pub const default_scan_limit: usize = 200;
/// Default source read limit used when the caller omits an explicit value.
pub const default_source_read_limit: usize = 512 * 1024;

/// Carries import graph request data across use case and port boundaries.
pub const ImportGraphRequest = struct {
    limit: usize = default_scan_limit,
    max_bytes: usize = default_source_read_limit,
};

/// Carries import edge data across use case and port boundaries.
pub const ImportEdge = struct {
    import: []const u8,
};

/// Carries import file data across use case and port boundaries.
pub const ImportFile = struct {
    file: []const u8,
    imports: []ImportEdge,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: ImportFile, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        for (self.imports) |item| allocator.free(item.import);
        allocator.free(self.imports);
    }
};

/// Carries skipped file data across use case and port boundaries.
pub const SkippedFile = struct {
    path: []const u8,
    error_name: []const u8,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: SkippedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.error_name);
    }
};

/// Carries import graph result data across use case and port boundaries.
pub const ImportGraphResult = struct {
    files: []ImportFile,
    skipped_files: []SkippedFile,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: ImportGraphResult, allocator: std.mem.Allocator) void {
        for (self.files) |file| file.deinit(allocator);
        allocator.free(self.files);
        for (self.skipped_files) |item| item.deinit(allocator);
        allocator.free(self.skipped_files);
    }
};

/// Carries test decl data across use case and port boundaries.
pub const TestDecl = struct {
    file: []const u8,
    line: usize,
    declaration: []const u8,
    command: []const u8,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: TestDecl, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.declaration);
        allocator.free(self.command);
    }
};

/// Carries test discover request data across use case and port boundaries.
pub const TestDiscoverRequest = struct {
    limit: usize = 500,
    max_bytes: usize = default_source_read_limit,
};

/// Carries test discover result data across use case and port boundaries.
pub const TestDiscoverResult = struct {
    tests: []TestDecl,
    skipped_files: []SkippedFile,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: TestDiscoverResult, allocator: std.mem.Allocator) void {
        for (self.tests) |item| item.deinit(allocator);
        allocator.free(self.tests);
        for (self.skipped_files) |item| item.deinit(allocator);
        allocator.free(self.skipped_files);
    }
};

/// Builds an advisory import graph by scanning each workspace .zig file for
/// string-literal `@import("...")` targets (no parse, so dynamic or aliased
/// imports are missed). Unreadable files are recorded in `skipped_files`
/// instead of failing the scan. The returned result owns every slice and string;
/// the caller `deinit`s it.
pub fn importGraph(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: ImportGraphRequest) ports.PortError!ImportGraphResult {
    const normalized_limit = @max(request.limit, 1);
    var scan = try context.workspace_scanner.scanZigFiles(allocator, .{
        .max_files = normalized_limit,
        .provenance = "static_analysis.import_graph",
    });
    defer scan.deinit(allocator);

    // `*_owned` flags drive the defers: while true the list (and its entries) are
    // freed on any early error; once ownership is handed to the result they flip
    // to false so success does not double-free what the caller now owns.
    var files: std.ArrayList(ImportFile) = .empty;
    var files_owned = true;
    defer if (files_owned) files.deinit(allocator);
    defer if (files_owned) for (files.items) |item| item.deinit(allocator);
    var skipped_files: std.ArrayList(SkippedFile) = .empty;
    var skipped_owned = true;
    defer if (skipped_owned) skipped_files.deinit(allocator);
    defer if (skipped_owned) for (skipped_files.items) |item| item.deinit(allocator);

    for (scan.files) |file| {
        const read = context.workspace_store.read(allocator, .{
            .path = file.path,
            .max_bytes = request.max_bytes,
            .provenance = "static_analysis.import_graph",
        }) catch |err| {
            try skipped_files.append(allocator, .{
                .path = try allocator.dupe(u8, file.path),
                .error_name = try allocator.dupe(u8, @errorName(err)),
            });
            continue;
        };
        defer read.deinit(allocator);

        var imports = std.ArrayList(ImportEdge).empty;
        var imports_owned = true;
        defer if (imports_owned) imports.deinit(allocator);
        defer if (imports_owned) for (imports.items) |item| allocator.free(item.import);
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, read.bytes, pos, "@import(\"")) |hit| {
            const start = hit + "@import(\"".len;
            const end = std.mem.indexOfScalarPos(u8, read.bytes, start, '"') orelse break;
            try imports.append(allocator, .{ .import = try allocator.dupe(u8, read.bytes[start..end]) });
            pos = end + 1;
        }

        const owned_file = try allocator.dupe(u8, file.path);
        var file_owned = true;
        defer if (file_owned) allocator.free(owned_file);
        const owned_imports = try imports.toOwnedSlice(allocator);
        imports_owned = false;
        try files.append(allocator, .{
            .file = owned_file,
            .imports = owned_imports,
        });
        file_owned = false;
    }

    const owned_files = try files.toOwnedSlice(allocator);
    files_owned = false;
    const owned_skipped = try skipped_files.toOwnedSlice(allocator);
    skipped_owned = false;
    return .{
        .files = owned_files,
        .skipped_files = owned_skipped,
    };
}

/// Renders an `importGraph` result as advisory Markdown (one section per file).
/// Borrows `result`; the returned text is allocator-owned and freed by the caller.
pub fn importGraphText(allocator: std.mem.Allocator, result: ImportGraphResult) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var out_owned = true;
    defer if (out_owned) out.deinit(allocator);
    try out.appendSlice(allocator, "# Import graph\n\n");
    try out.appendSlice(allocator, "Capability tier: advisory_orientation. Confidence: medium heuristic string-literal @import scan (orientation_only). Use `zig_ast_imports` or compiler/ZLS checks when precision matters.\n\n");

    for (result.files) |file| {
        try out.print(allocator, "## {s}\n", .{file.file});
        if (file.imports.len == 0) {
            try out.appendSlice(allocator, "- no string-literal imports found\n\n");
            continue;
        }
        for (file.imports) |item| {
            try out.print(allocator, "- {s}\n", .{item.import});
        }
        try out.append(allocator, '\n');
    }
    if (result.skipped_files.len > 0) {
        try out.print(allocator, "\nSkipped unreadable files: {d}\n", .{result.skipped_files.len});
    }
    const text = try out.toOwnedSlice(allocator);
    out_owned = false;
    return text;
}

/// Discovers `test ...` declarations by line prefix across workspace .zig files,
/// emitting a per-test `zig test <file>` command. Capped at `request.limit` tests;
/// unreadable files land in `skipped_files`. The returned result owns its slices;
/// the caller `deinit`s it.
pub fn testDiscover(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: TestDiscoverRequest) ports.PortError!TestDiscoverResult {
    const normalized_limit = @max(request.limit, 1);
    var scan = try context.workspace_scanner.scanZigFiles(allocator, .{
        .max_files = normalized_limit,
        .provenance = "static_analysis.test_discover",
    });
    defer scan.deinit(allocator);

    var tests: std.ArrayList(TestDecl) = .empty;
    var tests_owned = true;
    defer if (tests_owned) tests.deinit(allocator);
    defer if (tests_owned) for (tests.items) |item| item.deinit(allocator);
    var skipped_files: std.ArrayList(SkippedFile) = .empty;
    var skipped_owned = true;
    defer if (skipped_owned) skipped_files.deinit(allocator);
    defer if (skipped_owned) for (skipped_files.items) |item| item.deinit(allocator);

    for (scan.files) |file| {
        if (tests.items.len >= normalized_limit) break;
        const read = context.workspace_store.read(allocator, .{
            .path = file.path,
            .max_bytes = request.max_bytes,
            .provenance = "static_analysis.test_discover",
        }) catch |err| {
            try skipped_files.append(allocator, .{
                .path = try allocator.dupe(u8, file.path),
                .error_name = try allocator.dupe(u8, @errorName(err)),
            });
            continue;
        };
        defer read.deinit(allocator);

        var lines = std.mem.splitScalar(u8, read.bytes, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            if (tests.items.len >= normalized_limit) break;
            const trimmed = std.mem.trim(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, "test ")) continue;
            try tests.append(allocator, .{
                .file = try allocator.dupe(u8, file.path),
                .line = line_no,
                .declaration = try allocator.dupe(u8, trimmed),
                .command = try std.fmt.allocPrint(allocator, "zig test {s}", .{file.path}),
            });
        }
    }

    const owned_tests = try tests.toOwnedSlice(allocator);
    tests_owned = false;
    const owned_skipped = try skipped_files.toOwnedSlice(allocator);
    skipped_owned = false;
    return .{
        .tests = owned_tests,
        .skipped_files = owned_skipped,
    };
}
