//! Release drift reporting workflow that summarizes repo and artifact divergence by depth.
const std = @import("std");
const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const support = @import("../usecase_support.zig");

/// Aliases the app context wrapper used by this workflow module.
pub const App = support.UsecaseApp(app_context.ReleaseWorkflowContext);
/// Aliases the structured result type returned by workflow entrypoints.
pub const Result = support.Result;
const argString = support.argString;
const invalidArgumentResult = support.invalidArgumentResult;
const structured = support.structured;
const toolErrorFromError = support.toolErrorFromError;

/// Defines the allowed mode variants accepted by this workflow.
const Mode = enum {
    compact,
    standard,
    deep,

    /// Returns the stable wire name for this enum variant.
    fn name(self: Mode) []const u8 {
        return @tagName(self);
    }
};

const doc_paths = [_][]const u8{
    "README.md",
    "docs/tools.md",
    "docs/tool-index.generated.md",
    "docs/trust.md",
    "docs/release.md",
};

const overclaim_tokens = [_][]const u8{
    "top notch",
    "production-grade",
    "fully supports",
    "complete Zig docs",
    "semantic proof",
};

/// Executes the zigar docs drift check workflow and returns an allocator-owned structured result.
pub fn zigarDocsDriftCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const mode = parseModeArg(allocator, "zigar_docs_drift_check", args) catch |err| return modeError(allocator, "zigar_docs_drift_check", args, err);
    var checks = std.json.Array.init(allocator);
    var checks_owned = true;
    defer if (checks_owned) checks.deinit();
    var ok = true;
    for (doc_paths) |path| {
        const bytes = readWorkspaceFile(a, allocator, path) catch |err| {
            ok = false;
            try checks.append(try fileCheckErrorValue(allocator, path, err));
            continue;
        };
        defer allocator.free(bytes);
        try checks.append(try docNeedleCheckValue(a, allocator, path, bytes));
    }
    ok = ok and allChecksOk(checks);
    const value = try driftResultValue(allocator, .{
        .kind = "zigar_docs_drift_check",
        .mode = mode,
        .ok = ok,
        .checks = checks,
        .evidence_source = "bounded_workspace_doc_reads",
        .limitations = "This tool checks public contract markers and generated-index presence; it does not replace the full release-check target.",
        .resolution = if (ok) "documentation drift markers are present" else "update docs or run zig build tool-index, then verify with zig build docs-check and release-check",
    });
    const result = try structured(allocator, value);
    checks_owned = false;
    return result;
}

/// Executes the zigar release claim check workflow and returns an allocator-owned structured result.
pub fn zigarReleaseClaimCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const mode = parseModeArg(allocator, "zigar_release_claim_check", args) catch |err| return modeError(allocator, "zigar_release_claim_check", args, err);
    var checks = std.json.Array.init(allocator);
    var checks_owned = true;
    defer if (checks_owned) checks.deinit();
    var ok = true;
    for ([_][]const u8{ "README.md", "docs/tools.md", "docs/maturity.md", "docs/backends.md" }) |path| {
        const bytes = readWorkspaceFile(a, allocator, path) catch |err| {
            ok = false;
            try checks.append(try fileCheckErrorValue(allocator, path, err));
            continue;
        };
        defer allocator.free(bytes);
        const value = try claimCheckValue(allocator, path, bytes);
        if (!value.object.get("ok").?.bool) ok = false;
        try checks.append(value);
    }
    const value = try driftResultValue(allocator, .{
        .kind = "zigar_release_claim_check",
        .mode = mode,
        .ok = ok,
        .checks = checks,
        .evidence_source = "public_docs_claim_token_scan",
        .limitations = "Claim checks are conservative token scans; release evidence still comes from release-check, release-readiness, and real-backend conformance artifacts.",
        .resolution = if (ok) "public claim guard tokens passed" else "replace overclaims with evidence-labeled wording and cite verification paths",
    });
    const result = try structured(allocator, value);
    checks_owned = false;
    return result;
}

/// Executes the zigar tool index check workflow and returns an allocator-owned structured result.
pub fn zigarToolIndexCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const mode = parseModeArg(allocator, "zigar_tool_index_check", args) catch |err| return modeError(allocator, "zigar_tool_index_check", args, err);
    const path = "docs/tool-index.generated.md";
    const bytes = readWorkspaceFile(a, allocator, path) catch |err| return toolErrorFromError(allocator, .{
        .tool = "zigar_tool_index_check",
        .operation = "read_tool_index",
        .phase = "docs_drift",
        .code = "read_failed",
        .category = "filesystem",
        .resolution = "Run zig build tool-index to generate docs/tool-index.generated.md, then retry.",
    }, err);
    defer allocator.free(bytes);

    var missing = std.json.Array.init(allocator);
    var missing_owned = true;
    defer if (missing_owned) missing.deinit();
    var index: usize = 0;
    while (index < a.context.tool_manifest.count()) : (index += 1) {
        const entry = a.context.tool_manifest.entryAt(index) orelse continue;
        const needle = std.fmt.allocPrint(allocator, "`{s}`", .{entry.name}) catch return error.OutOfMemory;
        defer allocator.free(needle);
        if (std.mem.indexOf(u8, bytes, needle) == null) try missing.append(.{ .string = entry.name });
    }
    const ok = missing.items.len == 0 and std.mem.indexOf(u8, bytes, "Generated by zigar-tools generate-tool-index") != null;
    var checks = std.json.Array.init(allocator);
    var checks_owned = true;
    defer if (checks_owned) checks.deinit();
    var item = std.json.ObjectMap.empty;
    var item_owned = true;
    defer if (item_owned) item.deinit(allocator);
    try item.put(allocator, "path", .{ .string = path });
    try item.put(allocator, "ok", .{ .bool = ok });
    try item.put(allocator, "registered_tool_count", .{ .integer = @intCast(a.context.tool_manifest.count()) });
    try item.put(allocator, "missing_tool_count", .{ .integer = @intCast(missing.items.len) });
    try item.put(allocator, "missing_tools", .{ .array = missing });
    missing_owned = false;
    try checks.append(.{ .object = item });
    item_owned = false;

    const value = try driftResultValue(allocator, .{
        .kind = "zigar_tool_index_check",
        .mode = mode,
        .ok = ok,
        .checks = checks,
        .evidence_source = "manifest_registered_tools_vs_generated_tool_index",
        .limitations = "This check validates tool mentions in the generated index; run zig build docs-check for byte-for-byte regeneration drift.",
        .resolution = if (ok) "generated tool index mentions every registered tool" else "run zig build tool-index and commit the regenerated docs/tool-index.generated.md",
    });
    const result = try structured(allocator, value);
    checks_owned = false;
    return result;
}

/// Carries drift result data across use case and port boundaries.
const DriftResult = struct {
    kind: []const u8,
    mode: Mode,
    ok: bool,
    checks: std.json.Array,
    evidence_source: []const u8,
    limitations: []const u8,
    resolution: []const u8,
};

/// Serializes drift result fields into an allocator-owned JSON value; allocation failures propagate.
fn driftResultValue(allocator: std.mem.Allocator, input: DriftResult) !std.json.Value {
    var omitted = std.json.Array.init(allocator);
    var omitted_owned = true;
    defer if (omitted_owned) omitted.deinit();
    if (input.mode == .compact) {
        try omitted.append(try omissionValue(allocator, "full_release_check_output", "compact drift result reports structured markers only", "run zig build release-check --summary all"));
    }
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = input.kind });
    try obj.put(allocator, "ok", .{ .bool = input.ok });
    try attachMetadata(allocator, &obj, input.mode, omitted);
    omitted_owned = false;
    try obj.put(allocator, "checks", .{ .array = input.checks });
    try obj.put(allocator, "evidence_source", .{ .string = input.evidence_source });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    try obj.put(allocator, "limitations", .{ .string = input.limitations });
    try obj.put(allocator, "resolution", .{ .string = input.resolution });
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes doc needle check fields into an allocator-owned JSON value; allocation failures propagate.
fn docNeedleCheckValue(a: *App, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !std.json.Value {
    var missing = std.json.Array.init(allocator);
    var missing_owned = true;
    defer if (missing_owned) missing.deinit();
    if (std.mem.eql(u8, path, "docs/tool-index.generated.md")) {
        var index: usize = 0;
        while (index < a.context.tool_manifest.count()) : (index += 1) {
            const entry = a.context.tool_manifest.entryAt(index) orelse continue;
            const needle = try std.fmt.allocPrint(allocator, "`{s}`", .{entry.name});
            defer allocator.free(needle);
            if (std.mem.indexOf(u8, bytes, needle) == null) try missing.append(.{ .string = entry.name });
        }
    } else {
        for (docNeedles(path)) |needle| {
            if (std.mem.indexOf(u8, bytes, needle) == null) try missing.append(.{ .string = needle });
        }
    }
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "ok", .{ .bool = missing.items.len == 0 });
    try obj.put(allocator, "missing_count", .{ .integer = @intCast(missing.items.len) });
    try obj.put(allocator, "missing", .{ .array = missing });
    missing_owned = false;
    obj_owned = false;
    return .{ .object = obj };
}

/// Implements doc needles workflow logic using caller-owned inputs.
fn docNeedles(path: []const u8) []const []const u8 {
    if (std.mem.eql(u8, path, "README.md")) return &.{
        "Public feature claims use evidence labels",
        "command-backed tools",
    };
    if (std.mem.eql(u8, path, "docs/tools.md")) return &.{
        "## Evidence Labels",
        "Real conformance artifact",
    };
    if (std.mem.eql(u8, path, "docs/trust.md")) return &.{
        "release-check",
        "validation evidence block",
    };
    if (std.mem.eql(u8, path, "docs/release.md")) return &.{
        "source_tree_clean: true",
        "Release Readiness",
    };
    return &.{};
}

/// Serializes claim check fields into an allocator-owned JSON value; allocation failures propagate.
fn claimCheckValue(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !std.json.Value {
    var found = std.json.Array.init(allocator);
    var found_owned = true;
    defer if (found_owned) found.deinit();
    for (overclaim_tokens) |needle| {
        if (std.mem.indexOf(u8, bytes, needle) != null) try found.append(.{ .string = needle });
    }
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "ok", .{ .bool = found.items.len == 0 });
    try obj.put(allocator, "overclaim_count", .{ .integer = @intCast(found.items.len) });
    try obj.put(allocator, "overclaims", .{ .array = found });
    found_owned = false;
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes file check error fields into an allocator-owned JSON value; allocation failures propagate.
fn fileCheckErrorValue(allocator: std.mem.Allocator, path: []const u8, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = support.command.errorKind(err) });
    obj_owned = false;
    return .{ .object = obj };
}

/// Implements all checks ok workflow logic using caller-owned inputs.
fn allChecksOk(checks: std.json.Array) bool {
    for (checks.items) |item| {
        if (!item.object.get("ok").?.bool) return false;
    }
    return true;
}

/// Reads workspace file data from the provided context without taking ownership of inputs.
fn readWorkspaceFile(a: *App, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    _ = allocator;
    return a.workspace.readFileAlloc(a.io, path, 8 * 1024 * 1024);
}

/// Parses mode arg input using caller-provided storage; malformed input and allocation failures propagate.
fn parseModeArg(allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value) !Mode {
    _ = allocator;
    _ = tool_name;
    const raw = argString(args, "mode") orelse Mode.standard.name();
    inline for (std.meta.fields(Mode)) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return error.InvalidMode;
}

/// Implements mode error workflow logic using caller-owned inputs.
fn modeError(allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value, err: anyerror) !Result {
    return switch (err) {
        error.InvalidMode => invalidArgumentResult(allocator, tool_name, "mode", supportedModesText(), argString(args, "mode") orelse "", "Choose compact, standard, or deep."),
        else => error.OutOfMemory,
    };
}

/// Implements attach metadata workflow logic using caller-owned inputs.
fn attachMetadata(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, mode: Mode, omitted: std.json.Array) !void {
    try obj.put(allocator, "mode", .{ .string = mode.name() });
    try obj.put(allocator, "result_shape", try resultShapeValue(allocator, mode));
    try obj.put(allocator, "omitted_sections", .{ .array = omitted });
}

/// Serializes result shape fields into an allocator-owned JSON value; allocation failures propagate.
fn resultShapeValue(allocator: std.mem.Allocator, mode: Mode) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "mode", .{ .string = mode.name() });
    try obj.put(allocator, "schema_version", .{ .integer = 1 });
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes omission fields into an allocator-owned JSON value; allocation failures propagate.
fn omissionValue(allocator: std.mem.Allocator, section: []const u8, reason: []const u8, restore_with: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "section", .{ .string = section });
    try obj.put(allocator, "reason", .{ .string = reason });
    try obj.put(allocator, "restore_with", .{ .string = restore_with });
    obj_owned = false;
    return .{ .object = obj };
}

/// Implements supported modes text workflow logic using caller-owned inputs.
fn supportedModesText() []const u8 {
    return "compact, standard, or deep";
}

const fakes = @import("../../../testing/fakes/root.zig");

test "claim check flags public overclaim tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try claimCheckValue(arena.allocator(), "README.md", "production-grade semantic proof");
    try std.testing.expect(!value.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 2), value.object.get("overclaim_count").?.integer);
}

/// Carries test manifest data across use case and port boundaries.
const TestManifest = struct {
    entries: []const ports.ToolManifestEntry,

    /// Returns the fixture port table used by this test context.
    fn port(self: *TestManifest) ports.ToolManifestCatalog {
        return .{
            .ptr = self,
            .vtable = &.{ .count = count, .entry_at = entryAt, .find = find },
        };
    }

    /// Returns the number of entries exposed by this fixture.
    fn count(ptr: *anyopaque) usize {
        const self: *TestManifest = @ptrCast(@alignCast(ptr));
        return self.entries.len;
    }

    /// Returns the fixture entry at the requested index, or null when out of range.
    fn entryAt(ptr: *anyopaque, index: usize) ?ports.ToolManifestEntry {
        const self: *TestManifest = @ptrCast(@alignCast(ptr));
        if (index >= self.entries.len) return null;
        return self.entries[index];
    }

    /// Finds find data in the provided collection without taking ownership.
    fn find(ptr: *anyopaque, name: []const u8) ?ports.ToolManifestEntry {
        const self: *TestManifest = @ptrCast(@alignCast(ptr));
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

/// Carries drift harness data across use case and port boundaries.
const DriftHarness = struct {
    command_runner: fakes.FakeCommandRunner,
    workspace: fakes.FakeWorkspaceStore,
    scanner: fakes.FakeWorkspaceScanner,
    manifest: TestManifest,

    /// Initializes the fixture with caller-provided state.
    fn init(allocator: std.mem.Allocator, entries: []const ports.ToolManifestEntry) DriftHarness {
        return .{
            .command_runner = fakes.FakeCommandRunner.init(allocator),
            .workspace = fakes.FakeWorkspaceStore.init(allocator),
            .scanner = fakes.FakeWorkspaceScanner.init(allocator),
            .manifest = .{ .entries = entries },
        };
    }

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    fn deinit(self: *DriftHarness) void {
        self.command_runner.deinit();
        self.workspace.deinit();
        self.scanner.deinit();
    }

    /// Builds a test app fixture with the ports needed by this workflow.
    fn app(self: *DriftHarness, allocator: std.mem.Allocator) App {
        return App.init(.{
            .workspace = .{ .root = "/work", .cache_root = "/work/.zigar-cache", .transport = "stdio" },
            .tool_paths = .{},
            .timeouts = .{},
            .command_runner = self.command_runner.port(),
            .workspace_store = self.workspace.port(),
            .workspace_scanner = self.scanner.port(),
            .tool_manifest = self.manifest.port(),
        }, allocator);
    }

    /// Implements verify workflow logic using caller-owned inputs.
    fn verify(self: *DriftHarness) !void {
        try self.command_runner.verify();
        try self.workspace.verify();
        try self.scanner.verify();
    }
};

/// Reads the args with mode argument from JSON input without taking ownership of borrowed strings.
fn argsWithMode(allocator: std.mem.Allocator, mode: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "mode", .{ .string = mode });
    return .{ .object = obj };
}

/// Implements expect drift read workflow logic using caller-owned inputs.
fn expectDriftRead(store: *fakes.FakeWorkspaceStore, path: []const u8, bytes: []const u8) !void {
    try store.expectRead(.{ .path = path, .max_bytes = 8 * 1024 * 1024, .provenance = "arch110-workflow-read" }, bytes);
}

/// Implements expect drift read error workflow logic using caller-owned inputs.
fn expectDriftReadError(store: *fakes.FakeWorkspaceStore, path: []const u8, err: ports.PortError) !void {
    try store.expectReadError(.{ .path = path, .max_bytes = 8 * 1024 * 1024, .provenance = "arch110-workflow-read" }, err);
}

test "docs drift check reports compact metadata missing docs and manifest tool needles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const entries = [_]ports.ToolManifestEntry{
        .{ .name = "zig_build" },
        .{ .name = "zig_test" },
    };
    var harness = DriftHarness.init(std.testing.allocator, entries[0..]);
    defer harness.deinit();

    try expectDriftRead(&harness.workspace, "README.md", "Public feature claims use evidence labels\ncommand-backed tools\n");
    try expectDriftRead(&harness.workspace, "docs/tools.md", "## Evidence Labels\nReal conformance artifact\n");
    try expectDriftRead(&harness.workspace, "docs/tool-index.generated.md",
        \\Generated by zigar-tools generate-tool-index
        \\`zig_build`
    );
    try expectDriftReadError(&harness.workspace, "docs/trust.md", error.FileNotFound);
    try expectDriftRead(&harness.workspace, "docs/release.md", "source_tree_clean: true\nRelease Readiness\n");

    var app = harness.app(arena.allocator());
    const result = try zigarDocsDriftCheck(&app, arena.allocator(), try argsWithMode(arena.allocator(), "compact"));
    try std.testing.expect(!result.is_error);
    const value = result.value.object;
    try std.testing.expect(!value.get("ok").?.bool);
    try std.testing.expectEqualStrings("compact", value.get("mode").?.string);
    try std.testing.expectEqual(@as(usize, 1), value.get("omitted_sections").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 5), value.get("checks").?.array.items.len);
    try std.testing.expectEqualStrings("not_found", value.get("checks").?.array.items[3].object.get("error_kind").?.string);
    try harness.verify();
}

test "release claim and tool index checks cover invalid modes read failures and missing tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const entries = [_]ports.ToolManifestEntry{
        .{ .name = "zig_build" },
        .{ .name = "zig_test" },
    };
    var harness = DriftHarness.init(std.testing.allocator, entries[0..]);
    defer harness.deinit();

    var app = harness.app(arena.allocator());
    const invalid = try zigarReleaseClaimCheck(&app, arena.allocator(), try argsWithMode(arena.allocator(), "wide"));
    try std.testing.expect(invalid.is_error);
    try std.testing.expectEqualStrings("invalid_argument", invalid.value.object.get("code").?.string);

    try expectDriftRead(&harness.workspace, "README.md", "production-grade claims are blocked");
    try expectDriftRead(&harness.workspace, "docs/tools.md", "ordinary text");
    try expectDriftReadError(&harness.workspace, "docs/maturity.md", error.AccessDenied);
    try expectDriftRead(&harness.workspace, "docs/backends.md", "fully supports every backend");
    const claims = try zigarReleaseClaimCheck(&app, arena.allocator(), null);
    try std.testing.expect(!claims.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("standard", claims.value.object.get("mode").?.string);
    try std.testing.expectEqual(@as(usize, 4), claims.value.object.get("checks").?.array.items.len);

    try expectDriftRead(&harness.workspace, "docs/tool-index.generated.md",
        \\Generated by zigar-tools generate-tool-index
        \\`zig_build`
    );
    const index = try zigarToolIndexCheck(&app, arena.allocator(), try argsWithMode(arena.allocator(), "deep"));
    try std.testing.expect(!index.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("deep", index.value.object.get("mode").?.string);
    const check = index.value.object.get("checks").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 2), check.get("registered_tool_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), check.get("missing_tool_count").?.integer);

    try expectDriftReadError(&harness.workspace, "docs/tool-index.generated.md", error.PathOutsideWorkspace);
    const failed_index = try zigarToolIndexCheck(&app, arena.allocator(), null);
    try std.testing.expect(failed_index.is_error);
    try harness.verify();
}

test "drift private helpers cover success branches and allocation cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]ports.ToolManifestEntry{.{ .name = "zig_build" }};
    var harness = DriftHarness.init(std.testing.allocator, entries[0..]);
    defer harness.deinit();
    var app = harness.app(allocator);
    const manifest_port = harness.manifest.port();
    try std.testing.expect(manifest_port.find("zig_build") != null);
    try std.testing.expect(manifest_port.find("missing") == null);

    const args = try argsWithMode(allocator, "deep");
    try std.testing.expectEqual(Mode.deep, try parseModeArg(allocator, "tool", args));
    try std.testing.expectEqual(Mode.standard, try parseModeArg(allocator, "tool", null));
    try std.testing.expectEqualStrings("compact, standard, or deep", supportedModesText());
    try std.testing.expectError(error.OutOfMemory, modeError(allocator, "tool", null, error.UnexpectedCall));

    try std.testing.expectEqual(@as(usize, 2), docNeedles("README.md").len);
    try std.testing.expectEqual(@as(usize, 2), docNeedles("docs/tools.md").len);
    try std.testing.expectEqual(@as(usize, 2), docNeedles("docs/trust.md").len);
    try std.testing.expectEqual(@as(usize, 2), docNeedles("docs/release.md").len);
    try std.testing.expectEqual(@as(usize, 0), docNeedles("docs/other.md").len);

    const doc_ok = try docNeedleCheckValue(&app, allocator, "README.md", "Public feature claims use evidence labels\ncommand-backed tools\n");
    try std.testing.expect(doc_ok.object.get("ok").?.bool);
    const doc_missing = try docNeedleCheckValue(&app, allocator, "docs/tool-index.generated.md", "`zig_other`");
    try std.testing.expect(!doc_missing.object.get("ok").?.bool);

    var checks_ok = std.json.Array.init(allocator);
    try checks_ok.append(try claimCheckValue(allocator, "README.md", "plain evidence labels"));
    try std.testing.expect(allChecksOk(checks_ok));
    var checks_bad = std.json.Array.init(allocator);
    try checks_bad.append(try fileCheckErrorValue(allocator, "README.md", error.AccessDenied));
    try std.testing.expect(!allChecksOk(checks_bad));

    const claim_ok = try claimCheckValue(allocator, "README.md", "bounded evidence");
    try std.testing.expect(claim_ok.object.get("ok").?.bool);
    const compact = try driftResultValue(allocator, .{
        .kind = "drift_test",
        .mode = .compact,
        .ok = true,
        .checks = checks_ok,
        .evidence_source = "unit",
        .limitations = "none",
        .resolution = "ok",
    });
    try std.testing.expectEqual(@as(usize, 1), compact.object.get("omitted_sections").?.array.items.len);

    var buffer: [16]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    try std.testing.expectError(error.OutOfMemory, omissionValue(fixed.allocator(), "section", "reason", "restore"));
}
