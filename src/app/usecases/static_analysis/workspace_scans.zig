const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");

pub const default_scan_limit: usize = 200;
pub const default_source_read_limit: usize = 512 * 1024;

pub const ImportGraphRequest = struct {
    limit: usize = default_scan_limit,
    max_bytes: usize = default_source_read_limit,
};

pub const ImportEdge = struct {
    import: []const u8,
};

pub const ImportFile = struct {
    file: []const u8,
    imports: []ImportEdge,

    pub fn deinit(self: ImportFile, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        for (self.imports) |item| allocator.free(item.import);
        allocator.free(self.imports);
    }
};

pub const SkippedFile = struct {
    path: []const u8,
    error_name: []const u8,

    pub fn deinit(self: SkippedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.error_name);
    }
};

pub const ImportGraphResult = struct {
    files: []ImportFile,
    skipped_files: []SkippedFile,

    pub fn deinit(self: ImportGraphResult, allocator: std.mem.Allocator) void {
        for (self.files) |file| file.deinit(allocator);
        allocator.free(self.files);
        for (self.skipped_files) |item| item.deinit(allocator);
        allocator.free(self.skipped_files);
    }
};

pub const TestDecl = struct {
    file: []const u8,
    line: usize,
    declaration: []const u8,
    command: []const u8,

    pub fn deinit(self: TestDecl, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        allocator.free(self.declaration);
        allocator.free(self.command);
    }
};

pub const TestDiscoverRequest = struct {
    limit: usize = 500,
    max_bytes: usize = default_source_read_limit,
};

pub const TestDiscoverResult = struct {
    tests: []TestDecl,
    skipped_files: []SkippedFile,

    pub fn deinit(self: TestDiscoverResult, allocator: std.mem.Allocator) void {
        for (self.tests) |item| item.deinit(allocator);
        allocator.free(self.tests);
        for (self.skipped_files) |item| item.deinit(allocator);
        allocator.free(self.skipped_files);
    }
};

pub fn importGraph(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: ImportGraphRequest) ports.PortError!ImportGraphResult {
    const normalized_limit = @max(request.limit, 1);
    var scan = try context.workspace_scanner.scanZigFiles(allocator, .{
        .max_files = normalized_limit,
        .provenance = "static_analysis.import_graph",
    });
    defer scan.deinit(allocator);

    var files: std.ArrayList(ImportFile) = .empty;
    errdefer {
        for (files.items) |item| item.deinit(allocator);
        files.deinit(allocator);
    }
    var skipped_files: std.ArrayList(SkippedFile) = .empty;
    errdefer {
        for (skipped_files.items) |item| item.deinit(allocator);
        skipped_files.deinit(allocator);
    }

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
        errdefer {
            for (imports.items) |item| allocator.free(item.import);
            imports.deinit(allocator);
        }
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, read.bytes, pos, "@import(\"")) |hit| {
            const start = hit + "@import(\"".len;
            const end = std.mem.indexOfScalarPos(u8, read.bytes, start, '"') orelse break;
            try imports.append(allocator, .{ .import = try allocator.dupe(u8, read.bytes[start..end]) });
            pos = end + 1;
        }

        try files.append(allocator, .{
            .file = try allocator.dupe(u8, file.path),
            .imports = try imports.toOwnedSlice(allocator),
        });
    }

    return .{
        .files = try files.toOwnedSlice(allocator),
        .skipped_files = try skipped_files.toOwnedSlice(allocator),
    };
}

pub fn importGraphText(allocator: std.mem.Allocator, result: ImportGraphResult) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
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
    return out.toOwnedSlice(allocator);
}

pub fn testDiscover(allocator: std.mem.Allocator, context: app_context.StaticAnalysisContext, request: TestDiscoverRequest) ports.PortError!TestDiscoverResult {
    const normalized_limit = @max(request.limit, 1);
    var scan = try context.workspace_scanner.scanZigFiles(allocator, .{
        .max_files = normalized_limit,
        .provenance = "static_analysis.test_discover",
    });
    defer scan.deinit(allocator);

    var tests: std.ArrayList(TestDecl) = .empty;
    errdefer {
        for (tests.items) |item| item.deinit(allocator);
        tests.deinit(allocator);
    }
    var skipped_files: std.ArrayList(SkippedFile) = .empty;
    errdefer {
        for (skipped_files.items) |item| item.deinit(allocator);
        skipped_files.deinit(allocator);
    }

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

    return .{
        .tests = try tests.toOwnedSlice(allocator),
        .skipped_files = try skipped_files.toOwnedSlice(allocator),
    };
}
