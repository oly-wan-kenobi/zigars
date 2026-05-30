//! Dependency inspection, package lookup, and dependency-session workflows.
//!
//! Results are allocator-owned JSON values; source writes remain apply-gated
//! through dependency session state.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const support = @import("../usecase_support.zig");
const patch_sessions = @import("../editing/patch_sessions.zig");
const sessions = @import("../sessions/envelope.zig");
const patch_domain = @import("../../../domain/editing/patch_session.zig");
const zon = @import("../../../domain/zig/zon_dependencies.zig");

/// App facade for dependency lifecycle workflows.
pub const App = support.UsecaseApp(app_context.ReleaseWorkflowContext);
/// Structured result wrapper used by MCP adapters.
pub const Result = support.Result;

const schema_version: i64 = 1;
const default_manifest_path = "build.zig.zon";
const manifest_read_limit: usize = 2 * 1024 * 1024;
const migration_session_kind = "dependency_migration";
const dependency_elicitation_reason = "MCP elicitation is not invoked by this deterministic dependency workflow; apply=true and expected preimages remain the fallback confirmation contract.";

const ManifestInput = struct {
    path: []const u8,
    bytes: []const u8,
    owned: ?[]u8 = null,
    is_inline: bool = false,

    fn deinit(self: ManifestInput, allocator: std.mem.Allocator) void {
        if (self.owned) |bytes| allocator.free(bytes);
    }
};

const Operation = enum {
    sync,
    add,
    remove,
    upgrade,

    fn toolName(self: Operation) []const u8 {
        return switch (self) {
            .sync => "zig_zon_dep_sync",
            .add => "zig_deps_add",
            .remove => "zig_deps_remove",
            .upgrade => "zig_deps_upgrade",
        };
    }
};

/// Synchronizes one build.zig.zon URL dependency hash using `zig fetch`.
pub fn zigZonDepSync(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readManifest(a, allocator, args, "zig_zon_dep_sync") catch |err| return dependencyError(allocator, "zig_zon_dep_sync", "read_manifest", err);
    defer input.deinit(allocator);
    const dependency = support.argString(args, "dependency") orelse return support.missingArgumentResult(allocator, "zig_zon_dep_sync", "dependency", "dependency name");

    var model = zon.parse(allocator, input.bytes) catch return error.OutOfMemory;
    defer model.deinit(allocator);
    const entry = model.find(dependency) orelse return dependencyFailure(allocator, "zig_zon_dep_sync", "dependency_not_found", "No dependency with that name exists in build.zig.zon.", dependency);
    const url = if (support.argString(args, "url")) |override| override else if (entry.url) |field| field.value else return dependencyFailure(allocator, "zig_zon_dep_sync", "missing_url", "The selected dependency does not have a URL and cannot be synced with zig fetch.", dependency);

    const argv = [_][]const u8{ a.context.tool_paths.zig, "fetch", url };
    const timeout_ms = support.toolTimeout(a, args);
    const command_result = support.runCommand(allocator, a, &argv, timeout_ms) catch |err| return dependencyError(allocator, "zig_zon_dep_sync", "zig_fetch", err);
    defer command_result.deinit(allocator);

    const fetched_hash = extractFetchedHash(command_result.stdout) orelse extractFetchedHash(command_result.stderr);
    // Only rewrite the hash when fetch both succeeded and yielded a hash; a
    // failed or hash-less fetch returns a no-mutation failure result instead of
    // writing an unverified value into build.zig.zon.
    if (fetched_hash == null or !command_result.succeeded()) {
        return syncCommandFailure(allocator, a, input.path, dependency, url, &argv, timeout_ms, command_result, fetched_hash);
    }

    const updated = zon.replaceHash(allocator, model, dependency, fetched_hash.?) catch |err| return dependencyError(allocator, "zig_zon_dep_sync", "replace_hash", err);
    defer allocator.free(updated);
    return mutationResult(allocator, a.context, args, .sync, input.path, input.bytes, updated, dependency, model, .{
        .command_argv = &argv,
        .timeout_ms = timeout_ms,
        .command_result = command_result,
        .fetched_hash = fetched_hash.?,
        .url = url,
    });
}

/// Previews or applies adding a direct URL or path dependency.
pub fn zigDepsAdd(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return directMutation(a, allocator, args, .add);
}

/// Previews or applies removing one dependency entry.
pub fn zigDepsRemove(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return directMutation(a, allocator, args, .remove);
}

/// Previews or applies upgrading one direct URL dependency.
pub fn zigDepsUpgrade(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return directMutation(a, allocator, args, .upgrade);
}

/// Searches deterministic provider metadata for dependency packages.
pub fn zigPkgSearch(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const query = support.argString(args, "query") orelse support.argString(args, "url") orelse "";
    const provider = support.argString(args, "provider") orelse "direct";
    return support.structured(allocator, try registryResult(scratch, "zig_pkg_search", provider, query, support.argBool(args, "offline", false), .search));
}

/// Returns deterministic package metadata for direct URL/ref inputs, or provider unavailable metadata.
pub fn zigPkgInfo(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const query = support.argString(args, "name") orelse support.argString(args, "url") orelse support.argString(args, "query") orelse "";
    const provider = support.argString(args, "provider") orelse "direct";
    return support.structured(allocator, try registryResult(scratch, "zig_pkg_info", provider, query, support.argBool(args, "offline", false), .info));
}

/// Returns deterministic version/ref metadata for direct URL/ref inputs.
pub fn zigPkgVersions(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const query = support.argString(args, "name") orelse support.argString(args, "url") orelse support.argString(args, "query") orelse "";
    const provider = support.argString(args, "provider") orelse "direct";
    return support.structured(allocator, try registryResult(scratch, "zig_pkg_versions", provider, query, support.argBool(args, "offline", false), .versions));
}

/// Returns README availability metadata without unbounded network access.
pub fn zigPkgReadme(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const query = support.argString(args, "name") orelse support.argString(args, "url") orelse support.argString(args, "query") orelse "";
    const provider = support.argString(args, "provider") orelse "direct";
    return support.structured(allocator, try registryResult(scratch, "zig_pkg_readme", provider, query, support.argBool(args, "offline", false), .readme));
}

/// Builds, persists, inspects, or resumes a dependency migration session envelope.
pub fn zigDependencyMigrate(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const mode = support.argString(args, "mode") orelse "plan";
    const session_id_arg = support.argString(args, "migration_session_id");
    if (std.mem.eql(u8, mode, "inspect") or std.mem.eql(u8, mode, "resume")) {
        const session_id = session_id_arg orelse return support.missingArgumentResult(allocator, "zig_dependency_migrate", "migration_session_id", "migration session id");
        const viewed = sessions.view(scratch, a.context.workspace_store, migration_session_kind, session_id, "dependencies.migration_session_read") catch |err| return dependencyError(allocator, "zig_dependency_migrate", "read_session", err);
        var obj = std.json.ObjectMap.empty;
        try putBase(scratch, &obj, "zig_dependency_migrate", "dependency migration session envelope", "medium");
        try obj.put(scratch, "mode", .{ .string = mode });
        try obj.put(scratch, "migration_session_id", .{ .string = session_id });
        try obj.put(scratch, "session_path", .{ .string = viewed.object.get("path").?.string });
        try obj.put(scratch, "session_json", .{ .string = viewed.object.get("raw_jsonl").?.string });
        try obj.put(scratch, "session", viewed);
        try obj.put(scratch, "resumable", .{ .bool = true });
        return support.structured(allocator, .{ .object = obj });
    }
    if (std.mem.eql(u8, mode, "close")) {
        const session_id = session_id_arg orelse return support.missingArgumentResult(allocator, "zig_dependency_migrate", "migration_session_id", "migration session id");
        const apply = support.argBool(args, "apply", false);
        const viewed = sessions.view(scratch, a.context.workspace_store, migration_session_kind, session_id, "dependencies.migration_session_close_read") catch |err| return dependencyError(allocator, "zig_dependency_migrate", "read_session", err);
        const envelope = viewed.object.get("envelope") orelse .null;
        if (!apply) {
            var obj = std.json.ObjectMap.empty;
            try putBase(scratch, &obj, "zig_dependency_migrate", "dependency migration close preview", "medium");
            try obj.put(scratch, "mode", .{ .string = "close" });
            try obj.put(scratch, "migration_session_id", .{ .string = session_id });
            try obj.put(scratch, "session_path", .{ .string = viewed.object.get("path").?.string });
            try obj.put(scratch, "applied", .{ .bool = false });
            try obj.put(scratch, "requires_apply", .{ .bool = true });
            try obj.put(scratch, "session", viewed);
            return support.structured(allocator, .{ .object = obj });
        }
        const now = nowMs(a.context.clock_and_ids);
        const created_at = intField(envelope, "created_at") orelse now;
        const closed = try sessions.envelopeValue(scratch, .{
            .id = session_id,
            .kind = migration_session_kind,
            .status = "closed",
            .workspace_root = a.context.workspace.root,
            .created_at = created_at,
            .updated_at = now,
            .preimages = objectField(envelope, "preimages") orelse emptyArray(scratch),
            .artifacts = objectField(envelope, "artifacts") orelse emptyArray(scratch),
            .events = try appendEventArray(scratch, objectField(envelope, "events"), try sessions.eventValue(scratch, "closed", "dependency migration session closed", now)),
            .validation = objectField(envelope, "validation") orelse emptyObject(),
        });
        const path = sessions.appendSnapshot(scratch, a.context.workspace_store, migration_session_kind, session_id, closed, "dependencies.migration_session_close") catch |err| return dependencyError(allocator, "zig_dependency_migrate", "write_session", err);
        var obj = std.json.ObjectMap.empty;
        try putBase(scratch, &obj, "zig_dependency_migrate", "dependency migration session closed", "medium");
        try obj.put(scratch, "mode", .{ .string = "close" });
        try obj.put(scratch, "migration_session_id", .{ .string = session_id });
        try obj.put(scratch, "session_path", .{ .string = path });
        try obj.put(scratch, "applied", .{ .bool = true });
        try obj.put(scratch, "requires_apply", .{ .bool = false });
        try obj.put(scratch, "session", closed);
        return support.structured(allocator, .{ .object = obj });
    }

    var input = readManifest(a, allocator, args, "zig_dependency_migrate") catch |err| return dependencyError(allocator, "zig_dependency_migrate", "read_manifest", err);
    defer input.deinit(allocator);
    const model = zon.parse(scratch, input.bytes) catch return error.OutOfMemory;
    const dependency = support.argString(args, "dependency") orelse support.argString(args, "name") orelse "all";
    const session_id = if (session_id_arg) |id|
        try scratch.dupe(u8, id)
    else
        try patch_domain.sessionId(scratch, "dependency-migration-", support.argString(args, "goal"), input.path, dependency, support.argString(args, "target_url"));

    const now = nowMs(a.context.clock_and_ids);
    var envelope = try migrationEnvelopeValue(scratch, a.context.workspace.root, now, session_id, input.path, dependency, support.argString(args, "target_url"), model);
    const apply = support.argBool(args, "apply", false);
    const session_path = try sessions.sessionPath(scratch, migration_session_kind, session_id);
    if (apply) {
        _ = sessions.appendSnapshot(scratch, a.context.workspace_store, migration_session_kind, session_id, envelope, "dependencies.migration_session_write") catch |err| return dependencyError(allocator, "zig_dependency_migrate", "write_session", err);
    }
    try envelope.object.put(scratch, "session_path", .{ .string = session_path });
    try envelope.object.put(scratch, "applied", .{ .bool = apply });
    try envelope.object.put(scratch, "requires_apply", .{ .bool = !apply });
    return support.structured(allocator, envelope);
}

const MutationExtra = struct {
    command_argv: ?[]const []const u8 = null,
    timeout_ms: ?i64 = null,
    command_result: ?support.CommandRunResult = null,
    fetched_hash: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

/// Shared add/remove/upgrade path: reads the manifest, applies the text-preserving
/// zon edit for `op`, and hands the before/after pair to `mutationResult` for
/// apply-gated previewing. `.sync` is unreachable here (it has its own fetch path).
fn directMutation(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, op: Operation) !Result {
    var input = readManifest(a, allocator, args, op.toolName()) catch |err| return dependencyError(allocator, op.toolName(), "read_manifest", err);
    defer input.deinit(allocator);
    const dependency = support.argString(args, "dependency") orelse support.argString(args, "name") orelse return support.missingArgumentResult(allocator, op.toolName(), "dependency", "dependency name");
    var model = zon.parse(allocator, input.bytes) catch return error.OutOfMemory;
    defer model.deinit(allocator);
    const updated = switch (op) {
        .add => zon.addDependency(allocator, model, dependency, support.argString(args, "url"), support.argString(args, "hash"), support.argString(args, "path")),
        .remove => zon.removeDependency(allocator, model, dependency),
        .upgrade => blk: {
            const url = support.argString(args, "url") orelse return support.missingArgumentResult(allocator, op.toolName(), "url", "replacement package URL");
            break :blk zon.upgradeDependency(allocator, model, dependency, url, support.argString(args, "hash"));
        },
        .sync => unreachable,
    } catch |err| return dependencyError(allocator, op.toolName(), "edit_manifest", err);
    defer allocator.free(updated);
    return mutationResult(allocator, a.context, args, op, input.path, input.bytes, updated, dependency, model, .{ .url = support.argString(args, "url") });
}

/// Renders the preview/apply result for a manifest mutation. The actual write
/// is delegated to a patch session, so the apply gate, expected-preimage check,
/// and rollback history all come from that path rather than being re-implemented
/// here. `apply` defaults to false, so omitting it yields a preview. Returns an
/// allocator-owned structured Result.
fn mutationResult(
    allocator: std.mem.Allocator,
    context: app_context.ReleaseWorkflowContext,
    args: ?std.json.Value,
    op: Operation,
    manifest_path: []const u8,
    before: []const u8,
    after: []const u8,
    dependency: []const u8,
    model: zon.Model,
    extra: MutationExtra,
) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const apply = support.argBool(args, "apply", false);
    const editing_context = app_context.EditingContext{
        .workspace = context.workspace,
        .workspace_store = context.workspace_store,
        // Patch sessions need a clock for history timestamps; if none is wired,
        // fail closed rather than mutate source without a rollback record.
        .clock_and_ids = context.clock_and_ids orelse return dependencyError(allocator, op.toolName(), "patch_session", error.Unavailable),
        .observability = context.observability,
    };
    const session_id = try patch_domain.sessionId(scratch, op.toolName(), support.argString(args, "goal"), manifest_path, dependency, extra.fetched_hash orelse extra.url);
    const replacement = patch_sessions.Replacement{ .file = manifest_path, .content = after };
    const expected = try expectedPreimages(scratch, args, manifest_path, before, apply);
    var patch = patch_sessions.replacementSession(scratch, editing_context, .{
        .operation = if (apply) .apply else .preview,
        .session_id = session_id,
        .goal = support.argString(args, "goal") orelse op.toolName(),
        .replacements = &.{replacement},
        .expected_preimages = expected,
        .apply = apply,
    }) catch |err| return dependencyError(allocator, op.toolName(), "patch_session", err);
    defer patch.deinit(scratch);

    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, op.toolName(), "build.zig.zon dependency lifecycle mutation", "medium");
    try obj.put(scratch, "operation", .{ .string = @tagName(op) });
    try obj.put(scratch, "manifest_path", .{ .string = manifest_path });
    try obj.put(scratch, "dependency", .{ .string = dependency });
    try obj.put(scratch, "current_manifest_entry", try dependencyEntryValue(scratch, model.find(dependency)));
    if (extra.fetched_hash) |hash| try obj.put(scratch, "fetched_hash", .{ .string = hash }) else try obj.put(scratch, "fetched_hash", .null);
    if (extra.url) |url| try obj.put(scratch, "url", .{ .string = url }) else try obj.put(scratch, "url", .null);
    try obj.put(scratch, "replacement_fragment", try replacementFragmentValue(scratch, after, dependency));
    try obj.put(scratch, "unified_diff", .{ .string = if (patch.files.len > 0) patch.files[0].diff else "" });
    try obj.put(scratch, "expected_preimages", try expectedPreimagesValue(scratch, patch.expected_preimages));
    try obj.put(scratch, "patch_session", try patchSessionValue(scratch, patch));
    try obj.put(scratch, "applied", .{ .bool = patch.applied });
    try obj.put(scratch, "requires_apply", .{ .bool = patch.requires_apply });
    try support.putElicitationUnavailable(scratch, &obj, dependency_elicitation_reason);
    try obj.put(scratch, "validation_recommendations", try stringArray(scratch, &.{ "zig build --fetch", "zig build test" }));
    try obj.put(scratch, "diagnostics", try diagnosticsValue(scratch, model.diagnostics));
    if (extra.command_argv) |argv| {
        try obj.put(scratch, "fetch_command", try commandEvidenceValue(scratch, context.workspace.root, argv, extra.timeout_ms orelse context.timeouts.command_ms, extra.command_result.?));
    }
    return support.structured(allocator, .{ .object = obj });
}

/// Resolves the manifest to operate on. A `manifest` arg that looks like manifest
/// source (contains a newline or `.dependencies`) is treated as inline bytes and
/// is NOT read from disk; otherwise it is a path read through the workspace store
/// (sandbox-enforced) and capped at `manifest_read_limit`. `.owned` is set only
/// when the read result owns its bytes, so deinit frees exactly what was alloc'd.
fn readManifest(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, provenance_tool: []const u8) !ManifestInput {
    const manifest_arg = support.argString(args, "manifest");
    if (manifest_arg) |value| {
        // Heuristic: real manifest text spans lines or names .dependencies, so
        // treat it as inline content rather than a filesystem path to read.
        if (std.mem.indexOf(u8, value, "\n") != null or std.mem.indexOf(u8, value, ".dependencies") != null) {
            return .{ .path = support.argString(args, "manifest_path") orelse default_manifest_path, .bytes = value, .is_inline = true };
        }
    }
    const path = support.argString(args, "manifest_path") orelse manifest_arg orelse default_manifest_path;
    const read = try a.context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = manifest_read_limit,
        .provenance = provenance_tool,
    });
    return .{ .path = path, .bytes = read.bytes, .owned = if (read.owns_bytes) @constCast(read.bytes) else null };
}

/// Builds the expected-preimage guard for the apply pass. Previews need no
/// guard, so it returns empty when `!apply`. Otherwise the guard defaults to the
/// just-read `before` bytes; a caller may instead pin an explicit
/// `expected_preimage_sha256`/`_bytes` so the apply is refused unless the file
/// on disk still matches what the caller reviewed. Result is caller-owned.
fn expectedPreimages(allocator: std.mem.Allocator, args: ?std.json.Value, file: []const u8, before: []const u8, apply: bool) ![]patch_sessions.ExpectedPreimage {
    if (!apply) return &.{};
    var identity = try patch_domain.identityFromBytes(allocator, true, before);
    errdefer identity.deinit(allocator);
    if (support.argString(args, "expected_preimage_sha256")) |sha| {
        if (identity.sha256) |owned| allocator.free(owned);
        identity.sha256 = try allocator.dupe(u8, sha);
        identity.bytes = @intCast(@max(0, support.argInt(args, "expected_preimage_bytes", @intCast(before.len))));
    }
    const out = try allocator.alloc(patch_sessions.ExpectedPreimage, 1);
    errdefer allocator.free(out);
    out[0] = .{ .file = try allocator.dupe(u8, file), .identity = identity };
    return out;
}

/// Scans `zig fetch` output for the package hash, accepting both the bare
/// `hash: <value>` stdout form and a `.hash = "<value>"` manifest-style line.
/// Returns a borrowed slice into `text`, or null when no hash line is present.
fn extractFetchedHash(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "hash:")) {
            return std.mem.trim(u8, trimmed["hash:".len..], " \t\r\n");
        }
        if (std.mem.startsWith(u8, trimmed, ".hash = \"")) {
            const start = ".hash = \"".len;
            const end = std.mem.indexOfScalarPos(u8, trimmed, start, '"') orelse continue;
            return trimmed[start..end];
        }
    }
    return null;
}

fn syncCommandFailure(
    allocator: std.mem.Allocator,
    a: *App,
    manifest_path: []const u8,
    dependency: []const u8,
    url: []const u8,
    argv: []const []const u8,
    timeout_ms: i64,
    command_result: support.CommandRunResult,
    fetched_hash: ?[]const u8,
) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, "zig_zon_dep_sync", "zig fetch did not produce a usable dependency hash", "medium");
    try obj.put(scratch, "ok", .{ .bool = false });
    try obj.put(scratch, "manifest_path", .{ .string = manifest_path });
    try obj.put(scratch, "dependency", .{ .string = dependency });
    try obj.put(scratch, "url", .{ .string = url });
    if (fetched_hash) |hash| try obj.put(scratch, "fetched_hash", .{ .string = hash }) else try obj.put(scratch, "fetched_hash", .null);
    try obj.put(scratch, "fetch_command", try commandEvidenceValue(scratch, a.context.workspace.root, argv, timeout_ms, command_result));
    try obj.put(scratch, "applied", .{ .bool = false });
    try obj.put(scratch, "requires_apply", .{ .bool = true });
    try support.putElicitationUnavailable(scratch, &obj, dependency_elicitation_reason);
    try obj.put(scratch, "resolution", .{ .string = "Run the exact fetch command manually or retry after confirming the URL and network access; no source was changed." });
    return support.structured(allocator, .{ .object = obj });
}

const RegistryMode = enum { search, info, versions, readme };

fn registryResult(allocator: std.mem.Allocator, tool_name: []const u8, provider: []const u8, query: []const u8, offline: bool, mode: RegistryMode) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, tool_name, "dependency registry provider result", "medium");
    try obj.put(allocator, "query", .{ .string = query });
    try obj.put(allocator, "provider", try providerMetadataValue(allocator, provider, query, offline));
    var packages = std.json.Array.init(allocator);
    var unavailable = false;
    if (std.mem.eql(u8, provider, "direct")) {
        if (looksLikeUrl(query)) {
            var pkg = std.json.ObjectMap.empty;
            try pkg.put(allocator, "name", .{ .string = packageNameFromUrl(query) });
            try pkg.put(allocator, "url", .{ .string = query });
            try pkg.put(allocator, "version", .{ .string = refFromUrl(query) orelse "direct-url" });
            try pkg.put(allocator, "confidence", .{ .string = "medium" });
            try pkg.put(allocator, "trust_basis", .{ .string = "caller supplied direct URL/ref; zigars did not fetch registry metadata" });
            try packages.append(.{ .object = pkg });
        }
    } else {
        unavailable = true;
    }
    try obj.put(allocator, "packages", .{ .array = packages });
    try obj.put(allocator, "package_count", .{ .integer = @intCast(packages.items.len) });
    try obj.put(allocator, "versions", if (mode == .versions and packages.items.len > 0) try stringArray(allocator, &.{refFromUrl(query) orelse "direct-url"}) else .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "readme", if (mode == .readme and !unavailable) .{ .string = "" } else .null);
    try obj.put(allocator, "unavailable", .{ .bool = unavailable or (offline and !std.mem.eql(u8, provider, "direct")) });
    try obj.put(allocator, "offline", .{ .bool = offline });
    try obj.put(allocator, "resolution", .{ .string = if (unavailable) "The selected registry provider is not contacted by this deterministic build; use direct URL/ref inputs or retry when a bounded provider backend is configured." else "Review provider metadata and verify the package with zig fetch before mutating build.zig.zon." });
    return .{ .object = obj };
}

fn providerMetadataValue(allocator: std.mem.Allocator, provider: []const u8, query: []const u8, offline: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "id", .{ .string = provider });
    try obj.put(allocator, "trust_basis", .{ .string = if (std.mem.eql(u8, provider, "direct")) "caller supplied direct URL/ref" else "community index metadata; not authoritative package provenance" });
    try obj.put(allocator, "retrieved_url", if (std.mem.eql(u8, provider, "zigistry")) .{ .string = "https://zigistry.dev/" } else if (looksLikeUrl(query)) .{ .string = query } else .null);
    try obj.put(allocator, "cache_behavior", .{ .string = "no persistent network cache; direct provider is input-only" });
    try obj.put(allocator, "offline_behavior", .{ .string = if (offline) "offline requested; network providers return structured unavailable results" else "network providers remain unavailable unless a bounded backend is configured" });
    return .{ .object = obj };
}

fn migrationEnvelopeValue(allocator: std.mem.Allocator, workspace_root: []const u8, now: i64, session_id: []const u8, manifest_path: []const u8, dependency: []const u8, target_url: ?[]const u8, model: zon.Model) !std.json.Value {
    var events = std.json.Array.init(allocator);
    try events.append(try sessions.eventValue(allocator, "planned", "dependency migration session planned", now));
    var validation = std.json.ObjectMap.empty;
    try validation.put(allocator, "hooks", try stringArray(allocator, &.{ "zig_dependency_fetch_check", "zig_dependency_lock_audit", "zig_dependency_impact", "zig_dependency_security_report", "zig build test" }));
    try validation.put(allocator, "stale_preimage_policy", .{ .string = "source mutations are delegated to apply-gated dependency tools backed by patch-session preimages" });
    const value = try sessions.envelopeValue(allocator, .{
        .id = session_id,
        .kind = migration_session_kind,
        .status = "planned",
        .workspace_root = workspace_root,
        .created_at = now,
        .updated_at = now,
        .events = .{ .array = events },
        .validation = .{ .object = validation },
    });
    var obj = value.object;
    try obj.put(allocator, "tool", .{ .string = "zig_dependency_migrate" });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "evidence_source", .{ .string = "resumable dependency migration plan" });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "limitations", .{ .string = "build.zig.zon edits are text-preserving for common Zig 0.16 dependency literals; unsupported computed expressions are reported as diagnostics." });
    try obj.put(allocator, "migration_session_id", .{ .string = session_id });
    try obj.put(allocator, "session_kind", .{ .string = migration_session_kind });
    try obj.put(allocator, "state", .{ .string = "planned" });
    try obj.put(allocator, "manifest_path", .{ .string = manifest_path });
    try obj.put(allocator, "dependency", .{ .string = dependency });
    if (target_url) |url| try obj.put(allocator, "target_url", .{ .string = url }) else try obj.put(allocator, "target_url", .null);
    try obj.put(allocator, "steps", try stringArray(allocator, &.{ "inspect build.zig.zon", "preview add/upgrade/sync", "run zig build --fetch", "audit dependency lock/cache state", "run impact/security checks", "run validation" }));
    try obj.put(allocator, "validation_hooks", try stringArray(allocator, &.{ "zig_dependency_fetch_check", "zig_dependency_lock_audit", "zig_dependency_impact", "zig_dependency_security_report", "zig build test" }));
    try obj.put(allocator, "rollback", .{ .string = "Use patch-session preimages from applied mutation tools; migration session records the plan only." });
    try obj.put(allocator, "dependency_count", .{ .integer = @intCast(model.entries.len) });
    try obj.put(allocator, "diagnostics", try diagnosticsValue(allocator, model.diagnostics));
    return .{ .object = obj };
}

fn looksLikeUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "https://") or std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "git+https://");
}

fn packageNameFromUrl(url: []const u8) []const u8 {
    const without_query = if (std.mem.indexOfScalar(u8, url, '?')) |idx| url[0..idx] else url;
    const slash = std.mem.lastIndexOfScalar(u8, without_query, '/') orelse return without_query;
    var name = without_query[slash + 1 ..];
    if (std.mem.endsWith(u8, name, ".tar.gz")) name = name[0 .. name.len - ".tar.gz".len];
    if (std.mem.endsWith(u8, name, ".tgz")) name = name[0 .. name.len - ".tgz".len];
    return name;
}

fn refFromUrl(url: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, url, "?ref=")) |idx| return url[idx + "?ref=".len ..];
    if (std.mem.indexOf(u8, url, "#")) |idx| return url[idx + 1 ..];
    return null;
}

fn putBase(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, kind: []const u8, evidence_source: []const u8, confidence: []const u8) !void {
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "evidence_source", .{ .string = evidence_source });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    try obj.put(allocator, "limitations", .{ .string = "build.zig.zon edits are text-preserving for common Zig 0.16 dependency literals; unsupported computed expressions are reported as diagnostics." });
}

fn dependencyEntryValue(allocator: std.mem.Allocator, entry: ?zon.Dependency) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    if (entry) |dep| {
        try obj.put(allocator, "name", .{ .string = dep.name });
        try obj.put(allocator, "line", .{ .integer = @intCast(dep.line) });
        try obj.put(allocator, "kind", .{ .string = dep.kind() });
        if (dep.url) |field| try obj.put(allocator, "url", .{ .string = field.value }) else try obj.put(allocator, "url", .null);
        if (dep.hash) |field| try obj.put(allocator, "hash", .{ .string = field.value }) else try obj.put(allocator, "hash", .null);
        if (dep.path) |field| try obj.put(allocator, "path", .{ .string = field.value }) else try obj.put(allocator, "path", .null);
    } else {
        try obj.put(allocator, "name", .null);
    }
    return .{ .object = obj };
}

fn replacementFragmentValue(allocator: std.mem.Allocator, text: []const u8, dependency: []const u8) !std.json.Value {
    var model = zon.parse(allocator, text) catch return .null;
    defer model.deinit(allocator);
    const dep = model.find(dependency) orelse return .null;
    return .{ .string = text[dep.entry_start..dep.entry_end] };
}

fn patchSessionValue(allocator: std.mem.Allocator, patch: patch_sessions.ReplacementResult) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "session_id", .{ .string = patch.session_id });
    try obj.put(allocator, "applied", .{ .bool = patch.applied });
    try obj.put(allocator, "requires_apply", .{ .bool = patch.requires_apply });
    try obj.put(allocator, "safe_to_apply", .{ .bool = patch.safe_to_apply });
    try obj.put(allocator, "blocked", .{ .bool = patch.blocked });
    try obj.put(allocator, "changed_file_count", .{ .integer = @intCast(patch.changed_file_count) });
    var files = std.json.Array.init(allocator);
    for (patch.files) |file| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", .{ .string = file.file });
        try item.put(allocator, "changed", .{ .bool = file.changed });
        try item.put(allocator, "expected_preimage_matched", .{ .bool = file.expected_preimage_matched });
        try item.put(allocator, "diff", .{ .string = file.diff });
        try item.put(allocator, "preimage_identity", try identityValue(allocator, file.preimage_identity));
        try item.put(allocator, "updated_identity", try identityValue(allocator, file.updated_identity));
        try files.append(.{ .object = item });
    }
    try obj.put(allocator, "files", .{ .array = files });
    return .{ .object = obj };
}

fn expectedPreimagesValue(allocator: std.mem.Allocator, items: []const patch_sessions.ExpectedPreimage) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (items) |item| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "file", .{ .string = item.file });
        try obj.put(allocator, "identity", try identityValue(allocator, item.identity));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn identityValue(allocator: std.mem.Allocator, identity: patch_domain.Identity) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exists", .{ .bool = identity.exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(identity.bytes) });
    if (identity.sha256) |sha| try obj.put(allocator, "sha256", .{ .string = sha }) else try obj.put(allocator, "sha256", .null);
    return .{ .object = obj };
}

fn commandEvidenceValue(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, timeout_ms: i64, result: support.CommandRunResult) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "argv", try support.argvValue(allocator, argv));
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "stdout", .{ .string = result.stdout });
    try obj.put(allocator, "stderr", .{ .string = result.stderr });
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    try obj.put(allocator, "term", try commandTermValue(allocator, result.term));
    try obj.put(allocator, "ok", .{ .bool = result.succeeded() });
    return .{ .object = obj };
}

fn diagnosticsValue(allocator: std.mem.Allocator, diagnostics: []const zon.Diagnostic) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (diagnostics) |diag| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "code", .{ .string = diag.code });
        try obj.put(allocator, "message", .{ .string = diag.message });
        try obj.put(allocator, "line", .{ .integer = @intCast(diag.line) });
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn stringArray(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

fn appendEventArray(allocator: std.mem.Allocator, existing: ?std.json.Value, event: std.json.Value) !std.json.Value {
    var array = std.json.Array.init(allocator);
    if (existing) |value| {
        if (value == .array) {
            for (value.array.items) |item| try array.append(try support.cloneValue(allocator, item));
        }
    }
    try array.append(event);
    return .{ .array = array };
}

fn objectField(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn intField(value: std.json.Value, name: []const u8) ?i64 {
    const field = objectField(value, name) orelse return null;
    return switch (field) {
        .integer => |i| i,
        else => null,
    };
}

fn emptyArray(allocator: std.mem.Allocator) std.json.Value {
    return .{ .array = std.json.Array.init(allocator) };
}

fn emptyObject() std.json.Value {
    return .{ .object = std.json.ObjectMap.empty };
}

fn nowMs(clock: ?ports.ClockAndIds) i64 {
    const clock_port = clock orelse return 0;
    return (clock_port.now() catch return 0).unix_ms;
}

fn commandTermValue(allocator: std.mem.Allocator, term: ports.CommandTerm) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = term.name() });
    if (term.exitCode()) |code| try obj.put(allocator, "exit_code", .{ .integer = code }) else try obj.put(allocator, "exit_code", .null);
    return .{ .object = obj };
}

fn freeExpectedPreimages(allocator: std.mem.Allocator, expected: []const patch_sessions.ExpectedPreimage) void {
    if (expected.len == 0) return;
    for (expected) |item| {
        allocator.free(item.file);
        var identity = item.identity;
        identity.deinit(allocator);
    }
    allocator.free(expected);
}

fn dependencyFailure(allocator: std.mem.Allocator, tool_name: []const u8, code: []const u8, resolution: []const u8, dependency: []const u8) !Result {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "dependency_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "tool", .{ .string = tool_name });
    try obj.put(allocator, "code", .{ .string = code });
    try obj.put(allocator, "dependency", .{ .string = dependency });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return support.structuredError(allocator, .{ .object = obj });
}

fn dependencyError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, err: anyerror) !Result {
    return support.toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "dependency_lifecycle",
        .code = "dependency_lifecycle_failed",
        .category = "dependencies",
        .resolution = "Retry after confirming the manifest path, dependency name, apply flag, and expected preimage fields.",
    }, err);
}
