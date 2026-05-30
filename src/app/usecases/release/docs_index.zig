//! Documentation indexing/search use-case over workspace docs, std docs, and autodoc artifacts.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const docs_domain = @import("../../../domain/release/docs_index.zig");

/// Default docs index limit used when the caller omits an explicit value.
pub const default_docs_index_limit: usize = 200;
/// Default docs query limit used when the caller omits an explicit value.
pub const default_docs_query_limit: usize = 20;
/// Default std limit used when the caller omits an explicit value.
pub const default_std_limit: usize = 20;
/// Default langref item limit used when the caller omits an explicit value.
pub const default_langref_item_limit: usize = 5;
/// Default autodoc limit used when the caller omits an explicit value.
pub const default_autodoc_limit: usize = 200;
/// Default doc example limit used when the caller omits an explicit value.
pub const default_doc_example_limit: usize = 50;
/// Default readme command limit used when the caller omits an explicit value.
pub const default_readme_command_limit: usize = 100;

/// Carries evidence request data across use case and port boundaries.
pub const EvidenceRequest = struct {
    content: ?[]const u8 = null,
    path: ?[]const u8 = null,
    default_path: ?[]const u8 = null,
    require: bool = true,
    provenance: []const u8,
};

/// Carries evidence input data across use case and port boundaries.
pub const EvidenceInput = struct {
    bytes: []const u8,
    source_kind: []const u8,
    path: ?[]const u8 = null,
    owned: ?[]const u8 = null,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: EvidenceInput, allocator: std.mem.Allocator) void {
        if (self.owned) |bytes| allocator.free(bytes);
    }
};

/// Errors from docs-index entrypoints: port failures plus MissingEvidence when a
/// required evidence input (content or path) was not supplied.
pub const Error = ports.PortError || error{
    MissingEvidence,
};

/// Carries owned text files data across use case and port boundaries.
const OwnedTextFiles = struct {
    files: []docs_domain.TextFile,
    skipped_files: usize = 0,
    walk_errors: usize = 0,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    fn deinit(self: OwnedTextFiles, allocator: std.mem.Allocator) void {
        for (self.files) |file| {
            allocator.free(file.path);
            if (file.source_path) |source_path| allocator.free(source_path);
            allocator.free(file.bytes);
        }
        allocator.free(self.files);
    }
};

/// Lists Zig builtin functions for the active toolchain, recording source-drift
/// status when the installed BuiltinFn.zig is available. Returns an
/// allocator-owned result the caller must deinit.
pub fn builtinList(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext) Error!docs_domain.BuiltinListResult {
    const input = try builtinIndexInput(allocator, context);
    return docs_domain.builtinList(input);
}

/// Looks up builtin-function docs matching `query` (limit floored at 1). Returns
/// an allocator-owned result the caller must deinit.
pub fn builtinDoc(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, query: []const u8, limit: usize) Error!docs_domain.BuiltinDocResult {
    const input = try builtinIndexInput(allocator, context);
    return docs_domain.builtinDoc(allocator, query, @max(limit, 1), input) catch return error.OutOfMemory;
}

/// Searches the installed std library sources for `query`, reporting files
/// scanned/skipped/walk errors alongside matches (limit floored at 1). Returns
/// an allocator-owned result the caller must deinit.
pub fn stdSearch(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, query: []const u8, limit: usize) Error!docs_domain.StdSearchResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const std_dir = try envValue(allocator, context, "std_dir", "release_docs.std_search");
    defer std_dir.deinit(allocator);
    var files = try collectStdFiles(allocator, context, std_dir.value);
    defer files.deinit(allocator);
    return docs_domain.stdSearch(allocator, std_dir.value, query, files.files, .{
        .files_scanned = files.files.len,
        .skipped_files = files.skipped_files,
        .walk_errors = files.walk_errors,
    }, @max(limit, 1)) catch return error.OutOfMemory;
}

/// Resolves a fully-qualified std declaration (e.g. std.mem.Allocator) to its
/// source matches across the installed std library (limit floored at 1). Returns
/// an allocator-owned result the caller must deinit.
pub fn stdItem(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, name: []const u8, limit: usize) Error!docs_domain.StdItemResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const std_dir = try envValue(allocator, context, "std_dir", "release_docs.std_item");
    defer std_dir.deinit(allocator);
    var files = try collectStdFiles(allocator, context, std_dir.value);
    defer files.deinit(allocator);
    return docs_domain.stdItem(allocator, std_dir.value, name, files.files, .{
        .files_scanned = files.files.len,
        .skipped_files = files.skipped_files,
        .walk_errors = files.walk_errors,
    }, @max(limit, 1)) catch return error.OutOfMemory;
}

/// Searches the Zig language reference for `query`. Probes known candidate paths
/// under the toolchain lib dir; the first that reads and looks like langref is
/// parsed (installed result), otherwise it falls back to the bundled langref with
/// a fallback_reason and probe tallies. Returns an allocator-owned result the
/// caller must deinit; limit is floored at 1.
pub fn langrefSearch(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, query: []const u8, limit: usize) Error!docs_domain.LangrefSearchResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const lib_dir = try envValue(allocator, context, "lib_dir", "release_docs.langref");
    defer lib_dir.deinit(allocator);
    var probe: docs_domain.LangrefProbe = .{};
    for (docs_domain.langref_candidates) |rel| {
        probe.candidates_checked += 1;
        const path = std.fs.path.join(allocator, &.{ lib_dir.value, rel }) catch return error.OutOfMemory;
        defer allocator.free(path);
        const read = context.docs_scanner.readAbsolute(allocator, .{
            .path = path,
            .max_bytes = docs_domain.langref_probe_read_limit,
            .provenance = "release_docs.langref_probe",
        }) catch {
            probe.unreadable_candidates += 1;
            continue;
        };
        defer read.deinit(allocator);
        if (docs_domain.looksLikeLangref(rel, read.bytes)) {
            probe.path = path;
            const full = context.docs_scanner.readAbsolute(allocator, .{
                .path = path,
                .max_bytes = docs_domain.langref_html_read_limit,
                .provenance = "release_docs.langref_read",
            }) catch {
                return docs_domain.langrefBundled(allocator, query, @max(limit, 1), .{
                    .installed_doc_available = true,
                    .candidate_count = probe.candidates_checked,
                    .skipped_candidate_count = probe.skippedCandidates(),
                    .rejected_candidate_count = probe.rejected_candidates,
                    .unreadable_candidate_count = probe.unreadable_candidates + 1,
                    .parse_failure_count = 1,
                    .fallback_reason = "installed_langref_read_failed",
                }) catch return error.OutOfMemory;
            };
            defer full.deinit(allocator);
            return docs_domain.langrefInstalled(allocator, path, full.bytes, query, @max(limit, 1), probe) catch return error.OutOfMemory;
        }
        probe.rejected_candidates += 1;
    }
    return docs_domain.langrefBundled(allocator, query, @max(limit, 1), .{
        .candidate_count = probe.candidates_checked,
        .skipped_candidate_count = probe.skippedCandidates(),
        .rejected_candidate_count = probe.rejected_candidates,
        .unreadable_candidate_count = probe.unreadable_candidates,
        .fallback_reason = "installed_langref_not_found",
    }) catch return error.OutOfMemory;
}

/// Builds a docs index over workspace files within `scope` (limit floored at 1),
/// folding skipped/walk-error counts into the result. Returns an allocator-owned
/// result the caller must deinit.
pub fn docsIndexBuild(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, scope: []const u8, limit: usize) Error!docs_domain.DocsIndexResult {
    var files = try collectWorkspaceDocsFiles(allocator, context, scope);
    defer files.deinit(allocator);
    return docs_domain.docsIndex(allocator, scope, files.files, files.skipped_files + files.walk_errors, @max(limit, 1)) catch return error.OutOfMemory;
}

/// Searches workspace docs within `scope` for `query`, optionally folding in
/// supplied autodoc text (limit floored at 1). Returns an allocator-owned result
/// the caller must deinit.
pub fn docsQuery(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, query: []const u8, scope: []const u8, autodoc_text: ?[]const u8, limit: usize) Error!docs_domain.DocsQueryResult {
    var files = try collectWorkspaceDocsFiles(allocator, context, scope);
    defer files.deinit(allocator);
    return docs_domain.docsQuery(allocator, query, scope, files.files, autodoc_text, files.skipped_files + files.walk_errors, @max(limit, 1)) catch return error.OutOfMemory;
}

/// Ingests autodoc evidence (inline content or a workspace path) and indexes its
/// declarations (limit floored at 1). Returns an allocator-owned result the
/// caller must deinit; errors with MissingEvidence per the request's require flag.
pub fn autodocIngest(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, request: EvidenceRequest, limit: usize) Error!docs_domain.AutodocIngestResult {
    const input = try readEvidence(allocator, context, request);
    defer input.deinit(allocator);
    return docs_domain.autodocIngest(allocator, input.source_kind, input.path, input.bytes, @max(limit, 1)) catch return error.OutOfMemory;
}

/// Checks fenced code examples in doc evidence (inline or workspace path) for
/// parse validity (limit floored at 1). Returns an allocator-owned result the
/// caller must deinit.
pub fn docExampleCheck(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, request: EvidenceRequest, limit: usize) Error!docs_domain.DocExampleCheckResult {
    const input = try readEvidence(allocator, context, request);
    defer input.deinit(allocator);
    return docs_domain.docExampleCheck(allocator, input.source_kind, input.path, input.bytes, @max(limit, 1)) catch return error.OutOfMemory;
}

/// Checks a single inline Zig snippet for parse validity. Returns an
/// allocator-owned result the caller must deinit.
pub fn snippetCheck(allocator: std.mem.Allocator, content: []const u8) Error!docs_domain.SnippetCheck {
    return docs_domain.snippetCheck(allocator, "inline", content) catch return error.OutOfMemory;
}

/// Extracts and checks shell commands documented in README-style evidence
/// (inline or workspace path), limit floored at 1. Returns an allocator-owned
/// result the caller must deinit.
pub fn readmeCommandCheck(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, request: EvidenceRequest, limit: usize) Error!docs_domain.ReadmeCommandCheckResult {
    const input = try readEvidence(allocator, context, request);
    defer input.deinit(allocator);
    return docs_domain.readmeCommandCheck(allocator, input.source_kind, input.path, input.bytes, @max(limit, 1)) catch return error.OutOfMemory;
}

/// Assembles the input for the builtin-functions index: the toolchain version
/// plus, when discoverable, the installed BuiltinFn.zig source (for drift
/// detection). Missing version/source degrade gracefully to a bundled index.
fn builtinIndexInput(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext) Error!docs_domain.BuiltinIndexInput {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const version = envValue(allocator, context, "version", "release_docs.builtin_version") catch null;
    errdefer if (version) |value| value.deinit(allocator);
    const std_dir = envValue(allocator, context, "std_dir", "release_docs.builtin_source") catch null;
    defer if (std_dir) |value| value.deinit(allocator);
    var source_path: ?[]u8 = null;
    var source_bytes: ?[]const u8 = null;
    if (std_dir) |dir| {
        source_path = std.fs.path.join(allocator, &.{ dir.value, "zig/BuiltinFn.zig" }) catch return error.OutOfMemory;
        if (source_path) |path| {
            defer allocator.free(path);
            const read = context.docs_scanner.readAbsolute(allocator, .{
                .path = path,
                .max_bytes = docs_domain.std_source_read_limit,
                .provenance = "release_docs.builtin_source",
            }) catch null;
            if (read) |value| source_bytes = value.bytes;
            defer if (read) |value| value.deinit(allocator);
            const input = docs_domain.buildBuiltinIndexInput(
                allocator,
                if (version) |value| value.value else null,
                path,
                source_bytes,
            ) catch return error.OutOfMemory;
            if (version) |value| value.deinit(allocator);
            return input;
        }
    }
    defer if (source_path) |path| allocator.free(path);
    const input = docs_domain.buildBuiltinIndexInput(
        allocator,
        if (version) |value| value.value else null,
        source_path,
        source_bytes,
    ) catch return error.OutOfMemory;
    if (version) |value| value.deinit(allocator);
    return input;
}

/// Reads a toolchain environment value (e.g. std_dir, lib_dir, version) through
/// the toolchain_env port. Returns a port-owned value the caller must deinit;
/// `provenance` tags the lookup for auditing.
fn envValue(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, key: []const u8, provenance: []const u8) ports.PortError!ports.ToolchainEnvValue {
    return context.toolchain_env.get(allocator, .{ .key = key, .provenance = provenance });
}

/// Scans the std library dir and reads each Zig source through the docs_scanner
/// port, returning allocator-owned TextFiles plus skip/walk tallies. Unreadable
/// files are skipped (counted), never fatal; the caller must deinit the result.
fn collectStdFiles(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, std_dir: []const u8) Error!OwnedTextFiles {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var scan = try context.docs_scanner.scanAbsoluteZigPaths(allocator, .{
        .root = std_dir,
        .max_files = docs_domain.default_path_scan_limit,
        .provenance = "release_docs.std_scan",
    });
    defer scan.deinit(allocator);
    var files: std.ArrayList(docs_domain.TextFile) = .empty;
    errdefer {
        for (files.items) |file| {
            allocator.free(file.path);
            if (file.source_path) |source_path| allocator.free(source_path);
            allocator.free(file.bytes);
        }
        files.deinit(allocator);
    }
    var skipped: usize = 0;
    for (scan.paths) |entry| {
        const source_path = std.fs.path.join(allocator, &.{ std_dir, entry.path }) catch return error.OutOfMemory;
        const read = context.docs_scanner.readAbsolute(allocator, .{
            .path = source_path,
            .max_bytes = docs_domain.std_source_read_limit,
            .provenance = "release_docs.std_read",
        }) catch {
            allocator.free(source_path);
            skipped += 1;
            continue;
        };
        var owned_path: ?[]u8 = null;
        var owned_bytes: ?[]const u8 = null;
        var committed = false;
        errdefer if (!committed) {
            if (owned_path) |path| allocator.free(path);
            allocator.free(source_path);
            if (owned_bytes) |bytes| allocator.free(bytes);
        };

        owned_path = allocator.dupe(u8, entry.path) catch return error.OutOfMemory;
        owned_bytes = if (read.owns_bytes) read.bytes else allocator.dupe(u8, read.bytes) catch return error.OutOfMemory;
        try files.append(allocator, .{
            .path = owned_path.?,
            .source_path = source_path,
            .bytes = owned_bytes.?,
        });
        committed = true;
    }
    return .{
        .files = try files.toOwnedSlice(allocator),
        .skipped_files = skipped,
        .walk_errors = scan.walk_errors,
    };
}

/// Scans workspace files and reads those matching the docs `scope` through the
/// sandboxed workspace_store, returning allocator-owned TextFiles plus
/// skip/walk tallies. Unreadable files are skipped; the caller must deinit.
fn collectWorkspaceDocsFiles(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, scope: []const u8) Error!OwnedTextFiles {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var scan = try context.docs_scanner.scanWorkspacePaths(allocator, .{
        .max_files = docs_domain.default_path_scan_limit,
        .provenance = "release_docs.workspace_docs_scan",
    });
    defer scan.deinit(allocator);
    var files: std.ArrayList(docs_domain.TextFile) = .empty;
    errdefer {
        for (files.items) |file| {
            allocator.free(file.path);
            allocator.free(file.bytes);
        }
        files.deinit(allocator);
    }
    var skipped: usize = 0;
    for (scan.paths) |entry| {
        if (!docs_domain.isDocsScopePath(scope, entry.path)) continue;
        const read = context.workspace_store.read(allocator, .{
            .path = entry.path,
            .max_bytes = docs_domain.std_source_read_limit,
            .provenance = "release_docs.workspace_docs_read",
        }) catch {
            skipped += 1;
            continue;
        };
        var owned_path: ?[]u8 = null;
        var owned_bytes: ?[]const u8 = null;
        var committed = false;
        errdefer if (!committed) {
            if (owned_path) |path| allocator.free(path);
            if (owned_bytes) |bytes| allocator.free(bytes);
        };

        owned_path = allocator.dupe(u8, entry.path) catch return error.OutOfMemory;
        owned_bytes = if (read.owns_bytes) read.bytes else allocator.dupe(u8, read.bytes) catch return error.OutOfMemory;
        try files.append(allocator, .{
            .path = owned_path.?,
            .bytes = owned_bytes.?,
        });
        committed = true;
    }
    return .{
        .files = try files.toOwnedSlice(allocator),
        .skipped_files = skipped,
        .walk_errors = scan.walk_errors,
    };
}

/// Resolves doc evidence from inline content (borrowed) or a workspace path read
/// through the sandbox (owned bytes in the `owned` field). Returns
/// error.MissingEvidence when neither is present and request.require is set;
/// otherwise an empty source. The caller must deinit the result.
fn readEvidence(allocator: std.mem.Allocator, context: app_context.ReleaseDocsContext, request: EvidenceRequest) Error!EvidenceInput {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (request.content) |content| return .{ .bytes = content, .source_kind = "inline_content" };
    const path = request.path orelse request.default_path;
    if (path) |value| {
        const read = try context.workspace_store.read(allocator, .{
            .path = value,
            .max_bytes = docs_domain.evidence_read_limit,
            .provenance = request.provenance,
        });
        return .{
            .bytes = read.bytes,
            .source_kind = "workspace_path",
            .path = value,
            .owned = if (read.owns_bytes) read.bytes else null,
        };
    }
    if (request.require) return error.MissingEvidence;
    return .{ .bytes = "", .source_kind = "empty" };
}
