const std = @import("std");
const app_context = @import("../../context.zig");
const support = @import("../usecase_support.zig");
const zig_analysis = @import("../../../domain/zig/analysis.zig");
const release_intelligence = @import("release_intelligence.zig");
const project_values = @import("../static_analysis/project_values.zig");
const ci = @import("ci_evidence.zig");

pub const App = support.UsecaseApp(app_context.ReleaseWorkflowContext);
pub const Result = support.Result;

const schema_version = 1;
const default_api_baseline_path = ".zigar-cache/api/baseline.json";
const default_sbom_path = ".zigar-cache/security/sbom.cdx.json";

const EvidenceInput = struct {
    bytes: []const u8,
    source_kind: []const u8,
    path: ?[]const u8 = null,
    owned: ?[]u8 = null,

    fn deinit(self: EvidenceInput, allocator: std.mem.Allocator) void {
        if (self.owned) |bytes| allocator.free(bytes);
    }
};

pub fn zigCiIngest(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_ci_ingest", true) catch |err| return evidenceInputError(a, allocator, "zig_ci_ingest", args, err);
    defer input.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = ciIngestValue(arena.allocator(), input, support.argString(args, "format") orelse "auto", @intCast(@max(1, support.argInt(args, "limit", 100)))) catch return error.OutOfMemory;
    return support.structured(allocator, value);
}

pub fn zigCiReproPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_ci_repro_plan", true) catch |err| return evidenceInputError(a, allocator, "zig_ci_repro_plan", args, err);
    defer input.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const ingest = ciIngestValue(scratch, input, support.argString(args, "format") orelse "auto", @intCast(@max(1, support.argInt(args, "limit", 100)))) catch return error.OutOfMemory;
    const ingest_obj = objectValue(ingest) orelse std.json.ObjectMap.empty;
    var commands = std.json.Array.init(scratch);
    var steps = std.json.Array.init(scratch);
    try appendCiReproCommands(scratch, &commands, ingest_obj.get("failures") orelse .null);
    try appendChangedFileCommands(scratch, &commands, support.argString(args, "changed_files"));
    try appendUniqueStringJson(scratch, &commands, "zig build test");
    try steps.append(try stepValue(scratch, "ingest", "Inspect parser confidence and raw_reference before trusting CI-derived failures."));
    try steps.append(try stepValue(scratch, "reproduce", "Run the focused command first, then run the project-level fallback if it passes."));
    try steps.append(try stepValue(scratch, "validate", "Treat unparsed CI lines and skipped checks as unknown until local validation runs."));
    var skipped = std.json.Array.init(scratch);
    try skipped.append(try skippedValue(scratch, "local_execution", "This tool plans commands only; it does not run build, test, fetch, or scanner commands."));

    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, "zig_ci_repro_plan", "CI evidence parser plus file/test command heuristics", "medium", &.{
        "Commands are local repro candidates, not proof that CI and local environments match.",
        "Matrix environment, secrets, services, and runner images remain outside this local plan.",
    });
    try obj.put(scratch, "ingest", ingest);
    try obj.put(scratch, "commands", .{ .array = commands });
    try obj.put(scratch, "steps", .{ .array = steps });
    try obj.put(scratch, "skipped_validation", .{ .array = skipped });
    try obj.put(scratch, "stop_condition", .{ .string = "Stop only after the focused repro and the project release gate both pass or the CI-only gap is explicitly accepted." });
    return support.structured(allocator, .{ .object = obj });
}

pub fn zigCiFailureMap(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_ci_failure_map", true) catch |err| return evidenceInputError(a, allocator, "zig_ci_failure_map", args, err);
    defer input.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const ingest = ciIngestValue(scratch, input, support.argString(args, "format") orelse "auto", @intCast(@max(1, support.argInt(args, "limit", 100)))) catch return error.OutOfMemory;
    const ingest_obj = objectValue(ingest) orelse std.json.ObjectMap.empty;
    const failures = ingest_obj.get("failures") orelse .null;
    var by_file = std.json.Array.init(scratch);
    var by_kind = std.json.Array.init(scratch);
    try groupFailures(scratch, failures, "path", &by_file);
    try groupFailures(scratch, failures, "failure_kind", &by_kind);
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, "zig_ci_failure_map", "Grouped CI evidence from parsed failure records", "medium", &.{
        "Groups reflect parsed evidence only; raw CI artifacts remain the audit source.",
    });
    try obj.put(scratch, "failure_count", .{ .integer = integerField(ingest_obj, "failure_count") orelse 0 });
    try obj.put(scratch, "parser_confidence", copyField(ingest_obj, "parser_confidence", .{ .string = "low" }));
    try obj.put(scratch, "by_file", .{ .array = by_file });
    try obj.put(scratch, "by_kind", .{ .array = by_kind });
    try obj.put(scratch, "ingest", ingest);
    return support.structured(allocator, .{ .object = obj });
}

pub fn zigReleasePlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var plan = release_intelligence.plan(scratch, .{
        .validation = support.argString(args, "validation"),
        .ci = support.argString(args, "ci"),
        .api = support.argString(args, "api"),
        .docs = support.argString(args, "docs"),
        .dependencies = support.argString(args, "dependencies"),
        .security = support.argString(args, "security"),
        .changelog = support.argString(args, "changelog"),
    }) catch return error.OutOfMemory;
    defer plan.deinit(scratch);
    var checks = std.json.Array.init(scratch);
    for (plan.checks.items) |check| try checks.append(try releaseEvidenceCheckValue(scratch, check));
    var commands = std.json.Array.init(scratch);
    for ([_][]const u8{
        "zig build test --summary all",
        "zig build tool-index docs-check json-check --summary all",
        "zig build smoke stdio-fixtures --summary all",
        "zig build release-check --summary all",
    }) |cmd| try commands.append(.{ .string = cmd });
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, "zig_release_plan", "Observed evidence plus deterministic local release gates", "medium", &.{
        "Unprovided evidence is reported as missing or unknown, never as passed.",
        "Release readiness still depends on the named verification commands and human review of release notes.",
    });
    try obj.put(scratch, "goal", if (support.argString(args, "goal")) |goal| try support.ownedString(scratch, goal) else .null);
    try obj.put(scratch, "checks", .{ .array = checks });
    try obj.put(scratch, "verification_commands", .{ .array = commands });
    try obj.put(scratch, "release_blocked", .{ .bool = plan.release_blocked });
    try obj.put(scratch, "stop_condition", .{ .string = "Do not release until every required evidence item is present and release-check passes on the target commit." });
    return support.structured(allocator, .{ .object = obj });
}

pub fn zigSemverSuggest(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const suggestion = release_intelligence.suggestSemver(.{
        .api_diff = support.argString(args, "api_diff") orelse "",
        .changelog = support.argString(args, "changelog") orelse "",
        .release_notes = support.argString(args, "release_notes") orelse "",
    });
    var reasons = std.json.Array.init(scratch);
    try reasons.append(.{ .string = suggestion.reason });
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, "zig_semver_suggest", "Textual API/release evidence classifier", "medium", &.{
        "Semver suggestion is conservative advice over supplied evidence, not a release decision.",
        "Generated APIs, behavior changes, and ecosystem commitments require maintainer review.",
    });
    try obj.put(scratch, "current_version", if (support.argString(args, "current_version")) |version| try support.ownedString(scratch, version) else .null);
    try obj.put(scratch, "suggested_bump", .{ .string = suggestion.bump.text() });
    try obj.put(scratch, "reasons", .{ .array = reasons });
    try obj.put(scratch, "verify_with", try stringArrayValue(scratch, &.{ "zig_api_check", "release notes review", "project semver policy" }));
    return support.structured(allocator, .{ .object = obj });
}

pub fn zigReleaseNotesDraft(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var draft = release_intelligence.draftNotes(scratch, .{
        .version = support.argString(args, "version"),
        .changes = support.argString(args, "changes"),
        .api_diff = support.argString(args, "api_diff"),
        .validation = support.argString(args, "validation"),
        .ci = support.argString(args, "ci"),
        .dependencies = support.argString(args, "dependencies"),
        .security = support.argString(args, "security"),
    }) catch return error.OutOfMemory;
    defer draft.deinit(scratch);
    var sections = std.json.Array.init(scratch);
    for (draft.sections.items) |section| try sections.append(try releaseNoteSectionValue(scratch, section));
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, "zig_release_notes_draft", "Structured release evidence projected into editable notes", "medium", &.{
        "Draft notes preserve supplied evidence but still require maintainer editing.",
        "Absence of a section means no evidence was supplied, not that there were no changes.",
    });
    try obj.put(scratch, "version", if (support.argString(args, "version")) |version| try support.ownedString(scratch, version) else .null);
    try obj.put(scratch, "sections", .{ .array = sections });
    try obj.put(scratch, "markdown", .{ .string = draft.markdown });
    try obj.put(scratch, "requires_review", .{ .bool = draft.requires_review });
    return support.structured(allocator, .{ .object = obj });
}

pub fn zigReleaseEvidencePack(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var pack = release_intelligence.evidencePack(scratch, .{
        .validation = support.argString(args, "validation"),
        .ci = support.argString(args, "ci"),
        .api = support.argString(args, "api"),
        .docs = support.argString(args, "docs"),
        .dependencies = support.argString(args, "dependencies"),
        .security = support.argString(args, "security"),
        .artifacts = support.argString(args, "artifacts"),
    }) catch return error.OutOfMemory;
    defer pack.deinit(scratch);
    var evidence = std.json.Array.init(scratch);
    for (pack.evidence.items) |pointer| try evidence.append(try releaseEvidencePointerValue(scratch, pointer));
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, "zig_release_evidence_pack", "Release evidence packaging from caller-supplied report fragments", "medium", &.{
        "Evidence pack stores pointers and supplied fragments; it does not execute release gates.",
    });
    try obj.put(scratch, "evidence", .{ .array = evidence });
    try obj.put(scratch, "evidence_count", .{ .integer = @intCast(evidence.items.len) });
    try obj.put(scratch, "ready_for_release_review", .{ .bool = pack.ready_for_release_review });
    try obj.put(scratch, "verification_commands", try stringArrayValue(scratch, &.{ "zig build release-check --summary all", "git diff --check" }));
    return support.structured(allocator, .{ .object = obj });
}

pub fn zigApiBaselineInit(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var scratch_app = support.scratchApp(a, scratch);
    const baseline = apiBaselineValue(scratch, &scratch_app, args, "zig_api_baseline") catch |err| return apiToolError(allocator, "zig_api_baseline_init", "build_baseline", err);
    const output = support.argString(args, "output") orelse default_api_baseline_path;
    const apply = support.argBool(args, "apply", false);
    var bytes: std.ArrayList(u8) = .empty;
    try support.serializeValue(scratch, &bytes, baseline);
    const identity = artifactPreviewIdentityValue(scratch, a, output, bytes.items) catch |err| return apiToolError(allocator, "zig_api_baseline_init", "preview_identity", err);
    const preimage = preimageIdentityForPath(a, scratch, output) catch .null;
    if (apply) {
        writeAndRegisterArtifact(a, scratch, output, bytes.items, "zig_api_baseline_init", "api_baseline", "public API baseline artifact") catch |err| return support.workspacePathErrorResult(a, allocator, "zig_api_baseline_init", output, err);
    }
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, "zig_api_baseline_init", "Public declaration snapshot from source text", "medium", &.{
        "Baseline is a heuristic public declaration snapshot; it is not an ABI or behavior contract.",
        "Writes are preview-first and require apply=true.",
    });
    try obj.put(scratch, "baseline", baseline);
    try obj.put(scratch, "output", try support.ownedString(scratch, output));
    try obj.put(scratch, "artifact_identity", identity);
    try obj.put(scratch, "preimage_identity", preimage);
    try obj.put(scratch, "applied", .{ .bool = apply });
    try obj.put(scratch, "requires_apply", .{ .bool = !apply });
    return support.structured(allocator, .{ .object = obj });
}

pub fn zigApiCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return apiDiffTool(a, allocator, args, "zig_api_check");
}

pub fn zigApiDiffBaseline(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return apiDiffTool(a, allocator, args, "zig_api_diff_baseline");
}

pub fn zigApiDocsDiff(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var scratch_app = support.scratchApp(a, scratch);
    const current = apiBaselineValue(scratch, &scratch_app, args, "zig_api_docs_current") catch |err| return apiToolError(allocator, "zig_api_docs_diff", "build_api_snapshot", err);
    const docs_text = readOptionalTextArg(a, scratch, args, "docs_content", "docs_path", "zig_api_docs_diff") catch |err| return evidenceInputError(a, allocator, "zig_api_docs_diff", args, err);
    const decls = current.object.get("declarations") orelse std.json.Value{ .array = std.json.Array.init(scratch) };
    var undocumented = std.json.Array.init(scratch);
    var documented = std.json.Array.init(scratch);
    if (decls == .array) {
        for (decls.array.items) |decl| {
            const name = declNameField(decl) orelse continue;
            if (docs_text.bytes.len > 0 and std.mem.indexOf(u8, docs_text.bytes, name) != null) {
                try documented.append(decl);
            } else {
                try undocumented.append(decl);
            }
        }
    }
    docs_text.deinit(scratch);
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, "zig_api_docs_diff", "Public declaration names compared against project documentation text", "medium", &.{
        "Name matching is textual and does not prove docs are complete, correct, or current.",
    });
    try obj.put(scratch, "api", current);
    try obj.put(scratch, "documented", .{ .array = documented });
    try obj.put(scratch, "undocumented", .{ .array = undocumented });
    try obj.put(scratch, "undocumented_count", .{ .integer = @intCast(undocumented.items.len) });
    try obj.put(scratch, "verify_with", try stringArrayValue(scratch, &.{ "zig_docs_query", "manual API docs review" }));
    return support.structured(allocator, .{ .object = obj });
}

pub fn zigDependencyUpdatePlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const deps = dependencyInspectionFromArgs(a, arena.allocator(), args) catch |err| return dependencyToolError(allocator, "zig_dependency_update_plan", "read_manifest", err);
    const value = dependencyUpdatePlanValue(arena.allocator(), deps, support.argString(args, "dependency"), support.argString(args, "target_version")) catch return error.OutOfMemory;
    return support.structured(allocator, value);
}

pub fn zigDependencyFetchCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const deps = dependencyInspectionFromArgs(a, arena.allocator(), args) catch |err| return dependencyToolError(allocator, "zig_dependency_fetch_check", "read_manifest", err);
    const value = dependencyFetchCheckValue(arena.allocator(), deps) catch return error.OutOfMemory;
    return support.structured(allocator, value);
}

pub fn zigDependencyLockAudit(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const deps = dependencyInspectionFromArgs(a, scratch, args) catch |err| return dependencyToolError(allocator, "zig_dependency_lock_audit", "read_manifest", err);
    const lock_text = readOptionalTextArg(a, scratch, args, "lockfile", null, "zig_dependency_lock_audit") catch EvidenceInput{ .bytes = "", .source_kind = "missing" };
    defer lock_text.deinit(scratch);
    const value = dependencyLockAuditValue(scratch, deps, lock_text.bytes) catch return error.OutOfMemory;
    return support.structured(allocator, value);
}

pub fn zigDependencyImpact(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var scratch_app = support.scratchApp(a, arena.allocator());
    const value = dependencyImpactValue(arena.allocator(), &scratch_app, args) catch |err| return dependencyToolError(allocator, "zig_dependency_impact", "impact", err);
    return support.structured(allocator, value);
}

pub fn zigSbom(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const deps = dependencyInspectionFromArgs(a, scratch, args) catch |err| return dependencyToolError(allocator, "zig_sbom", "read_manifest", err);
    const sbom = sbomValue(scratch, deps) catch return error.OutOfMemory;
    var bytes: std.ArrayList(u8) = .empty;
    try support.serializeValue(scratch, &bytes, sbom);
    const output = support.argString(args, "output") orelse default_sbom_path;
    const apply = support.argBool(args, "apply", false);
    const identity = artifactPreviewIdentityValue(scratch, a, output, bytes.items) catch |err| return dependencyToolError(allocator, "zig_sbom", "preview_identity", err);
    const preimage = preimageIdentityForPath(a, scratch, output) catch .null;
    if (apply) {
        writeAndRegisterArtifact(a, scratch, output, bytes.items, "zig_sbom", "cyclonedx_sbom", "dependency SBOM generated from build.zig.zon") catch |err| return support.workspacePathErrorResult(a, allocator, "zig_sbom", output, err);
    }
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, "zig_sbom", "CycloneDX-style dependency component inventory from build.zig.zon", "medium", &.{
        "SBOM contains manifest-observed dependencies only; transitive packages and resolved package metadata require `zig build --fetch` and external validation.",
    });
    try obj.put(scratch, "sbom", sbom);
    try obj.put(scratch, "output", try support.ownedString(scratch, output));
    try obj.put(scratch, "artifact_identity", identity);
    try obj.put(scratch, "preimage_identity", preimage);
    try obj.put(scratch, "applied", .{ .bool = apply });
    try obj.put(scratch, "requires_apply", .{ .bool = !apply });
    return support.structured(allocator, .{ .object = obj });
}

pub fn zigZatScan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return scannerIngestTool(a, allocator, args, "zig_zat_scan", "zat");
}

pub fn zigOsvScan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return scannerIngestTool(a, allocator, args, "zig_osv_scan", "osv");
}

pub fn zigDependencySecurityReport(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const deps = dependencyInspectionFromArgs(a, scratch, args) catch |err| return dependencyToolError(allocator, "zig_dependency_security_report", "read_manifest", err);
    const value = dependencySecurityReportValue(scratch, deps, support.argString(args, "sbom"), support.argString(args, "zat"), support.argString(args, "osv")) catch return error.OutOfMemory;
    return support.structured(allocator, value);
}

pub fn zigDependencyProvenance(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const deps = dependencyInspectionFromArgs(a, arena.allocator(), args) catch |err| return dependencyToolError(allocator, "zig_dependency_provenance", "read_manifest", err);
    const value = dependencyProvenanceValue(arena.allocator(), deps) catch return error.OutOfMemory;
    return support.structured(allocator, value);
}

pub fn zigDependencyLicenseSummary(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const deps = dependencyInspectionFromArgs(a, scratch, args) catch |err| return dependencyToolError(allocator, "zig_dependency_license_summary", "read_manifest", err);
    const license_text = support.argString(args, "license_text") orelse readRootLicense(a, scratch) catch "";
    const value = dependencyLicenseSummaryValue(scratch, deps, license_text) catch return error.OutOfMemory;
    return support.structured(allocator, value);
}

pub fn zigGithubDependencySubmitPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const deps = dependencyInspectionFromArgs(a, arena.allocator(), args) catch |err| return dependencyToolError(allocator, "zig_github_dependency_submit_plan", "read_manifest", err);
    const value = githubDependencySubmitPlanValue(arena.allocator(), deps, support.argString(args, "job"), support.argString(args, "ref"), support.argString(args, "sha")) catch return error.OutOfMemory;
    return support.structured(allocator, value);
}

fn readEvidenceInput(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, require: bool) !EvidenceInput {
    _ = allocator;
    if (support.argString(args, "content")) |content| return .{ .bytes = content, .source_kind = "inline_content" };
    if (support.argString(args, "path")) |path| {
        const bytes = a.workspace.readFileAlloc(a.io, path, 8 * 1024 * 1024) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PathOutsideWorkspace, error.EmptyPath => return err,
            else => return err,
        };
        return .{ .bytes = bytes, .source_kind = "workspace_path", .path = path, .owned = bytes };
    }
    if (require) return error.MissingEvidence;
    _ = tool_name;
    return .{ .bytes = "", .source_kind = "empty" };
}

fn readEvidenceInputDefaultPath(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, default_path: []const u8) !EvidenceInput {
    if (support.argString(args, "content") != null or support.argString(args, "path") != null) return readEvidenceInput(a, allocator, args, tool_name, true);
    const bytes = a.workspace.readFileAlloc(a.io, default_path, 8 * 1024 * 1024) catch |err| return err;
    return .{ .bytes = bytes, .source_kind = "workspace_path", .path = default_path, .owned = bytes };
}

fn readOptionalTextArg(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, content_field: []const u8, path_field: ?[]const u8, tool_name: []const u8) !EvidenceInput {
    _ = allocator;
    if (support.argString(args, content_field)) |content| return .{ .bytes = content, .source_kind = "inline_content" };
    if (path_field) |field| {
        if (support.argString(args, field)) |path| {
            const bytes = a.workspace.readFileAlloc(a.io, path, 8 * 1024 * 1024) catch |err| return err;
            return .{ .bytes = bytes, .source_kind = "workspace_path", .path = path, .owned = bytes };
        }
    }
    _ = tool_name;
    return .{ .bytes = "", .source_kind = "missing" };
}

fn evidenceInputError(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value, err: anyerror) !Result {
    return switch (err) {
        error.MissingEvidence => support.missingArgumentResult(allocator, tool_name, "content", "inline content or workspace path"),
        error.PathOutsideWorkspace, error.EmptyPath => if (support.argString(args, "path")) |path| support.workspacePathErrorResult(a, allocator, tool_name, path, err) else support.missingArgumentResult(allocator, tool_name, "path", "workspace-relative path"),
        error.OutOfMemory => error.OutOfMemory,
        else => support.toolErrorFromError(allocator, .{
            .tool = tool_name,
            .operation = "read_evidence",
            .phase = "workspace_read",
            .code = "evidence_read_failed",
            .category = "filesystem",
            .resolution = "Pass inline content or a readable workspace-relative path, then retry.",
        }, err),
    };
}

fn ciIngestValue(allocator: std.mem.Allocator, input: EvidenceInput, requested_format: []const u8, limit: usize) !std.json.Value {
    const detected = detectCiFormat(requested_format, input.bytes);
    var failures = std.json.Array.init(allocator);
    var annotations = std.json.Array.init(allocator);
    var parser_confidence: []const u8 = "low";
    var parse_summary: std.json.Value = .null;
    if (std.mem.eql(u8, detected, "junit")) {
        try parseJunitFailures(allocator, input.bytes, &failures, limit);
        parser_confidence = if (failures.items.len > 0) "medium" else "low";
    } else if (std.mem.eql(u8, detected, "sarif")) {
        try parseSarifFailures(allocator, input.bytes, &failures, limit);
        parser_confidence = if (failures.items.len > 0) "medium" else "low";
    } else {
        const summary = ci.tryParseAnnotations(allocator, &annotations, input.path orelse "ci.log", input.bytes) catch return error.OutOfMemory;
        parse_summary = annotationSummaryValue(allocator, summary) catch return error.OutOfMemory;
        parser_confidence = summary.confidence();
        for (annotations.items) |annotation| {
            if (failures.items.len >= limit) break;
            try failures.append(try failureFromAnnotation(allocator, annotation));
        }
    }
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, "zig_ci_ingest", "CI artifact parser for logs, annotations, JUnit, and SARIF", parser_confidence, &.{
        "CI ingestion packages observed failure evidence and parser confidence; raw artifacts remain authoritative.",
        "Runner environment, matrix metadata, secrets, and external services are not reproduced by this parser.",
    });
    try obj.put(allocator, "ok", .{ .bool = failures.items.len == 0 });
    try obj.put(allocator, "requested_format", try support.ownedString(allocator, requested_format));
    try obj.put(allocator, "format", .{ .string = detected });
    try obj.put(allocator, "parser_confidence", .{ .string = parser_confidence });
    try obj.put(allocator, "failure_count", .{ .integer = @intCast(failures.items.len) });
    try obj.put(allocator, "failures", .{ .array = failures });
    try obj.put(allocator, "annotations", .{ .array = annotations });
    try obj.put(allocator, "parse_summary", parse_summary);
    try obj.put(allocator, "raw_reference", try rawReferenceValue(allocator, input));
    try obj.put(allocator, "next_actions", try stringArrayValue(allocator, &.{ "zig_ci_repro_plan", "zig_ci_failure_map", "zigar_validation_run" }));
    return .{ .object = obj };
}

fn detectCiFormat(requested: []const u8, bytes: []const u8) []const u8 {
    if (!std.mem.eql(u8, requested, "auto")) return requested;
    if (std.mem.indexOf(u8, bytes, "<testsuite") != null or std.mem.indexOf(u8, bytes, "<testcase") != null) return "junit";
    if (std.mem.indexOf(u8, bytes, "\"runs\"") != null and std.mem.indexOf(u8, bytes, "\"results\"") != null) return "sarif";
    return "log";
}

fn failureFromAnnotation(allocator: std.mem.Allocator, annotation: std.json.Value) !std.json.Value {
    const src = objectValue(annotation) orelse std.json.ObjectMap.empty;
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "failure_kind", .{ .string = "compiler_diagnostic" });
    try obj.put(allocator, "path", copyField(src, "path", .null));
    try obj.put(allocator, "line", copyField(src, "start_line", .null));
    try obj.put(allocator, "severity", copyField(src, "severity", .null));
    try obj.put(allocator, "message", copyField(src, "message", .null));
    try obj.put(allocator, "parser_confidence", copyField(src, "parser_confidence", .{ .string = "low" }));
    try obj.put(allocator, "raw", copyField(src, "raw", .null));
    return .{ .object = obj };
}

fn parseJunitFailures(allocator: std.mem.Allocator, bytes: []const u8, failures: *std.json.Array, limit: usize) !void {
    var pos: usize = 0;
    while (failures.items.len < limit) {
        const hit = std.mem.indexOfPos(u8, bytes, pos, "<failure") orelse break;
        const end = std.mem.indexOfPos(u8, bytes, hit, "</failure>") orelse @min(bytes.len, hit + 240);
        const snippet = bytes[hit..@min(bytes.len, end + "</failure>".len)];
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "failure_kind", .{ .string = "junit_failure" });
        try obj.put(allocator, "path", .null);
        try obj.put(allocator, "line", .null);
        try obj.put(allocator, "severity", .{ .string = "failure" });
        try obj.put(allocator, "message", .{ .string = try shortString(allocator, stripXml(snippet), 240) });
        try obj.put(allocator, "parser_confidence", .{ .string = "medium" });
        try failures.append(.{ .object = obj });
        pos = end + 1;
    }
}

fn parseSarifFailures(allocator: std.mem.Allocator, bytes: []const u8, failures: *std.json.Array, limit: usize) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return;
    const root = objectValue(parsed.value) orelse return;
    const runs = arrayValue(root.get("runs") orelse .null) orelse return;
    for (runs.items) |run| {
        const run_obj = objectValue(run) orelse continue;
        const results = arrayValue(run_obj.get("results") orelse .null) orelse continue;
        for (results.items) |result| {
            if (failures.items.len >= limit) return;
            const result_obj = objectValue(result) orelse continue;
            var obj = std.json.ObjectMap.empty;
            try obj.put(allocator, "failure_kind", .{ .string = "sarif_result" });
            try obj.put(allocator, "path", sarifPathValue(result_obj));
            try obj.put(allocator, "line", sarifLineValue(result_obj));
            try obj.put(allocator, "severity", copyField(result_obj, "level", .{ .string = "warning" }));
            try obj.put(allocator, "message", .{ .string = try allocator.dupe(u8, sarifMessage(result_obj)) });
            try obj.put(allocator, "parser_confidence", .{ .string = "medium" });
            try failures.append(.{ .object = obj });
        }
    }
}

fn sarifMessage(result_obj: std.json.ObjectMap) []const u8 {
    const msg = objectValue(result_obj.get("message") orelse .null) orelse return "";
    return stringField(msg, "text") orelse stringField(msg, "markdown") orelse "";
}

fn sarifPathValue(result_obj: std.json.ObjectMap) std.json.Value {
    const locations = arrayValue(result_obj.get("locations") orelse .null) orelse return .null;
    if (locations.items.len == 0) return .null;
    const loc = objectValue(locations.items[0]) orelse return .null;
    const physical = objectValue(loc.get("physicalLocation") orelse .null) orelse return .null;
    const artifact = objectValue(physical.get("artifactLocation") orelse .null) orelse return .null;
    if (stringField(artifact, "uri")) |uri| return .{ .string = uri };
    return .null;
}

fn sarifLineValue(result_obj: std.json.ObjectMap) std.json.Value {
    const locations = arrayValue(result_obj.get("locations") orelse .null) orelse return .null;
    if (locations.items.len == 0) return .null;
    const loc = objectValue(locations.items[0]) orelse return .null;
    const physical = objectValue(loc.get("physicalLocation") orelse .null) orelse return .null;
    const region = objectValue(physical.get("region") orelse .null) orelse return .null;
    if (integerField(region, "startLine")) |line| return .{ .integer = line };
    return .null;
}

fn annotationSummaryValue(allocator: std.mem.Allocator, summary: ci.AnnotationParseSummary) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "input_lines", .{ .integer = summary.input_lines });
    try obj.put(allocator, "annotation_count", .{ .integer = summary.annotation_count });
    try obj.put(allocator, "located_diagnostics", .{ .integer = summary.located_diagnostics });
    try obj.put(allocator, "unlocated_diagnostics", .{ .integer = summary.unlocated_diagnostics });
    try obj.put(allocator, "detail_lines", .{ .integer = summary.detail_lines });
    try obj.put(allocator, "parser_confidence", .{ .string = summary.confidence() });
    return .{ .object = obj };
}

fn appendCiReproCommands(allocator: std.mem.Allocator, commands: *std.json.Array, failures: std.json.Value) !void {
    const array = arrayValue(failures) orelse return;
    for (array.items) |failure| {
        const obj = objectValue(failure) orelse continue;
        if (stringField(obj, "path")) |path| {
            if (std.mem.endsWith(u8, path, ".zig")) {
                try appendUniqueStringJson(allocator, commands, try std.fmt.allocPrint(allocator, "zig ast-check {s}", .{path}));
                try appendUniqueStringJson(allocator, commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{path}));
            }
        }
    }
}

fn appendChangedFileCommands(allocator: std.mem.Allocator, commands: *std.json.Array, changed_files: ?[]const u8) !void {
    const text = changed_files orelse return;
    var tokens = std.mem.tokenizeAny(u8, text, ", \t\r\n");
    while (tokens.next()) |path| {
        if (!std.mem.endsWith(u8, path, ".zig")) continue;
        try appendUniqueStringJson(allocator, commands, try std.fmt.allocPrint(allocator, "zig ast-check {s}", .{path}));
        try appendUniqueStringJson(allocator, commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{path}));
    }
}

fn groupFailures(allocator: std.mem.Allocator, failures: std.json.Value, field: []const u8, groups: *std.json.Array) !void {
    const array = arrayValue(failures) orelse return;
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(allocator);
    for (array.items) |failure| {
        const obj = objectValue(failure) orelse continue;
        const key = stringField(obj, field) orelse "unknown";
        var found: ?usize = null;
        for (names.items, 0..) |name, index| {
            if (std.mem.eql(u8, name, key)) {
                found = index;
                break;
            }
        }
        if (found) |index| {
            const group = &groups.items[index].object;
            const old_count = integerField(group.*, "count") orelse 0;
            try group.put(allocator, "count", .{ .integer = old_count + 1 });
        } else {
            try names.append(allocator, try allocator.dupe(u8, key));
            var group = std.json.ObjectMap.empty;
            try group.put(allocator, "key", try support.ownedString(allocator, key));
            try group.put(allocator, "count", .{ .integer = 1 });
            try groups.append(.{ .object = group });
        }
    }
}

fn releaseEvidenceCheckValue(allocator: std.mem.Allocator, check: release_intelligence.EvidenceCheck) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = check.name });
    try obj.put(allocator, "status", .{ .string = check.status });
    try obj.put(allocator, "observed", .{ .bool = check.observed });
    try obj.put(allocator, "verify_with", .{ .string = check.verify_with });
    try obj.put(allocator, "summary", if (check.summary) |summary| .{ .string = summary } else .null);
    return .{ .object = obj };
}

fn releaseNoteSectionValue(allocator: std.mem.Allocator, section: release_intelligence.ReleaseNoteSection) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "title", .{ .string = section.title });
    try obj.put(allocator, "body", .{ .string = section.body });
    return .{ .object = obj };
}

fn releaseEvidencePointerValue(allocator: std.mem.Allocator, pointer: release_intelligence.EvidencePointer) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = pointer.name });
    try obj.put(allocator, "provided", .{ .bool = pointer.provided });
    try obj.put(allocator, "summary", if (pointer.summary) |summary| .{ .string = summary } else .null);
    return .{ .object = obj };
}

fn apiDiffTool(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var scratch_app = support.scratchApp(a, scratch);
    const current = apiBaselineValue(scratch, &scratch_app, args, tool_name) catch |err| return apiToolError(allocator, tool_name, "build_current_api", err);
    const baseline = apiBaselineFromArgs(a, scratch, args) catch |err| return apiToolError(allocator, tool_name, "read_baseline", err);
    const current_decls = current.object.get("declarations") orelse std.json.Value{ .array = std.json.Array.init(scratch) };
    const baseline_decls = baseline.object.get("declarations") orelse std.json.Value{ .array = std.json.Array.init(scratch) };
    var added = std.json.Array.init(scratch);
    var removed = std.json.Array.init(scratch);
    var changed = std.json.Array.init(scratch);
    if (current_decls == .array and baseline_decls == .array) {
        try comparePublicDecls(scratch, baseline_decls.array, current_decls.array, &added, &removed, &changed);
    }
    const breaking = removed.items.len > 0 or changed.items.len > 0;
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, tool_name, "Public declaration baseline comparison", "medium", &.{
        "Compares public declaration lines by name and signature text.",
        "Does not prove ABI, behavior, generated exports, or re-export compatibility.",
    });
    try obj.put(scratch, "ok", .{ .bool = !breaking });
    try obj.put(scratch, "baseline", baseline);
    try obj.put(scratch, "current", current);
    try obj.put(scratch, "added", .{ .array = added });
    try obj.put(scratch, "removed", .{ .array = removed });
    try obj.put(scratch, "changed", .{ .array = changed });
    try obj.put(scratch, "breaking_change_risk", .{ .bool = breaking });
    try obj.put(scratch, "verify_with", try stringArrayValue(scratch, &.{ "zig build test", "release review", "zig_api_docs_diff" }));
    return support.structured(allocator, .{ .object = obj });
}

fn apiBaselineValue(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value, kind: []const u8) !std.json.Value {
    var declarations = std.json.Array.init(allocator);
    if (support.argString(args, "content")) |content| {
        const file = support.argString(args, "file");
        const snapshot = try publicDeclSnapshotValue(allocator, file, content);
        try declarations.appendSlice(snapshot.array.items);
    } else if (support.argString(args, "file")) |file| {
        const bytes = try a.workspace.readFileAlloc(a.io, file, support.source_read_limit);
        const snapshot = try publicDeclSnapshotValue(allocator, file, bytes);
        try declarations.appendSlice(snapshot.array.items);
    } else {
        try collectWorkspacePublicDecls(allocator, a, &declarations, @intCast(@max(1, support.argInt(args, "limit", 500))));
    }
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, kind, "Heuristic public declaration snapshot", "medium", &.{
        "Captures public declaration lines only; semantic API compatibility requires release review and compiler-backed validation.",
    });
    try obj.put(allocator, "declarations", .{ .array = declarations });
    try obj.put(allocator, "declaration_count", .{ .integer = @intCast(declarations.items.len) });
    try obj.put(allocator, "snapshot_format", .{ .string = "zigar.public_api_baseline.v1" });
    return .{ .object = obj };
}

fn collectWorkspacePublicDecls(allocator: std.mem.Allocator, a: *App, declarations: *std.json.Array, limit: usize) !void {
    const scan = try a.context.workspace_scanner.scanZigFiles(allocator, .{
        .path_prefix = "",
        .max_files = limit,
        .provenance = "release.collect_public_decls",
    });
    defer scan.deinit(allocator);
    for (scan.files) |entry| {
        if (!std.mem.endsWith(u8, entry.path, ".zig") or zig_analysis.skipWorkspacePath(entry.path)) continue;
        const bytes = a.workspace.readFileAlloc(a.io, entry.path, support.source_read_limit) catch continue;
        defer allocator.free(bytes);
        const snapshot = try publicDeclSnapshotValue(allocator, entry.path, bytes);
        try declarations.appendSlice(snapshot.array.items);
    }
}

fn apiBaselineFromArgs(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !std.json.Value {
    if (support.argString(args, "baseline")) |text| return parseBaselineText(allocator, text);
    const path = support.argString(args, "baseline_path") orelse default_api_baseline_path;
    const bytes = try a.workspace.readFileAlloc(a.io, path, 8 * 1024 * 1024);
    return parseBaselineText(allocator, bytes);
}

fn publicDeclSnapshotValue(allocator: std.mem.Allocator, file: ?[]const u8, contents: []const u8) !std.json.Value {
    var decls = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "pub ")) continue;
        const kind = zig_analysis.declKind(trimmed) orelse continue;
        var obj = std.json.ObjectMap.empty;
        if (file) |path| try obj.put(allocator, "file", try support.ownedString(allocator, path)) else try obj.put(allocator, "file", .null);
        try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
        try obj.put(allocator, "kind", .{ .string = kind });
        try obj.put(allocator, "name", if (declName(trimmed, kind)) |name| try support.ownedString(allocator, name) else .null);
        try obj.put(allocator, "signature", try support.ownedString(allocator, trimmed));
        try decls.append(.{ .object = obj });
    }
    return .{ .array = decls };
}

fn comparePublicDecls(allocator: std.mem.Allocator, before: std.json.Array, after: std.json.Array, added: *std.json.Array, removed: *std.json.Array, changed: *std.json.Array) !void {
    for (after.items) |after_decl| {
        const key = declKey(after_decl) orelse continue;
        const match = findDeclByKey(before, key);
        if (match) |before_decl| {
            if (!std.mem.eql(u8, declSignature(before_decl) orelse "", declSignature(after_decl) orelse "")) {
                var item = std.json.ObjectMap.empty;
                try item.put(allocator, "before", before_decl);
                try item.put(allocator, "after", after_decl);
                try changed.append(.{ .object = item });
            }
        } else {
            try added.append(after_decl);
        }
    }
    for (before.items) |before_decl| {
        const key = declKey(before_decl) orelse continue;
        if (findDeclByKey(after, key) == null) try removed.append(before_decl);
    }
}

fn declName(line: []const u8, kind: []const u8) ?[]const u8 {
    const marker = if (std.mem.eql(u8, kind, "fn") or std.mem.eql(u8, kind, "function"))
        "fn "
    else if (std.mem.eql(u8, kind, "const") or std.mem.eql(u8, kind, "type"))
        "const "
    else if (std.mem.eql(u8, kind, "var"))
        "var "
    else if (std.mem.eql(u8, kind, "extern"))
        "extern "
    else if (std.mem.eql(u8, kind, "export"))
        "export "
    else
        return null;
    const start = (std.mem.indexOf(u8, line, marker) orelse return null) + marker.len;
    var end = start;
    while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) : (end += 1) {}
    if (end == start) return null;
    return line[start..end];
}

fn declKey(value: std.json.Value) ?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get("name") orelse .null) {
        .string => |s| s,
        else => null,
    };
}

fn declSignature(value: std.json.Value) ?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get("signature") orelse .null) {
        .string => |s| s,
        else => null,
    };
}

fn findDeclByKey(array: std.json.Array, key: []const u8) ?std.json.Value {
    for (array.items) |item| {
        if (declKey(item)) |candidate| {
            if (std.mem.eql(u8, candidate, key)) return item;
        }
    }
    return null;
}

fn parseBaselineText(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    if (parsed.value == .array) {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "kind", .{ .string = "zig_api_baseline" });
        try obj.put(allocator, "declarations", parsed.value);
        try obj.put(allocator, "declaration_count", .{ .integer = @intCast(parsed.value.array.items.len) });
        return .{ .object = obj };
    }
    return parsed.value;
}

fn sourceTextMatchValue(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, hit: usize, source: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", try support.ownedString(allocator, path));
    try obj.put(allocator, "source_family", .{ .string = source });
    try obj.put(allocator, "line", .{ .integer = @intCast(lineNumber(bytes, hit)) });
    try obj.put(allocator, "snippet", .{ .string = try allocator.dupe(u8, lineAt(bytes, hit)) });
    try obj.put(allocator, "confidence", .{ .string = "medium" });
    return .{ .object = obj };
}

fn dependencyInspectionFromArgs(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !std.json.Value {
    var scratch_app = support.scratchApp(a, allocator);
    const bytes = if (support.argString(args, "manifest")) |manifest|
        manifest
    else
        try scratch_app.workspace.readFileAlloc(a.io, "build.zig.zon", 1024 * 1024);
    return project_values.dependencyInspectionValue(allocator, a.context.staticAnalysis(), bytes);
}

fn dependencyUpdatePlanValue(allocator: std.mem.Allocator, deps: std.json.Value, filter: ?[]const u8, target_version: ?[]const u8) !std.json.Value {
    var plans = std.json.Array.init(allocator);
    const dependencies = deps.object.get("dependencies") orelse std.json.Value{ .array = std.json.Array.init(allocator) };
    if (dependencies == .array) {
        for (dependencies.array.items) |dep| {
            const obj = objectValue(dep) orelse continue;
            const name = stringField(obj, "name") orelse continue;
            if (filter) |needle| if (!std.mem.eql(u8, name, needle)) continue;
            var item = std.json.ObjectMap.empty;
            try item.put(allocator, "name", try support.ownedString(allocator, name));
            try item.put(allocator, "current_url", copyField(obj, "url", .null));
            try item.put(allocator, "current_hash", copyField(obj, "hash", .null));
            try item.put(allocator, "target_version", if (target_version) |version| try support.ownedString(allocator, version) else .null);
            try item.put(allocator, "steps", try stringArrayValue(allocator, &.{ "edit build.zig.zon dependency url/hash", "run zig build --fetch", "run zig build test", "review SBOM/security report" }));
            try plans.append(.{ .object = item });
        }
    }
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, "zig_dependency_update_plan", "build.zig.zon dependency update planning", "medium", &.{
        "Plans changes only; it does not fetch packages, rewrite the manifest, or verify upstream versions.",
    });
    try obj.put(allocator, "plans", .{ .array = plans });
    try obj.put(allocator, "plan_count", .{ .integer = @intCast(plans.items.len) });
    try obj.put(allocator, "verification_commands", try stringArrayValue(allocator, &.{ "zig build --fetch", "zig build test" }));
    return .{ .object = obj };
}

fn dependencyFetchCheckValue(allocator: std.mem.Allocator, deps: std.json.Value) !std.json.Value {
    const dependencies = deps.object.get("dependencies") orelse std.json.Value{ .array = std.json.Array.init(allocator) };
    var checks = std.json.Array.init(allocator);
    var missing_hashes: usize = 0;
    if (dependencies == .array) {
        for (dependencies.array.items) |dep| {
            const obj = objectValue(dep) orelse continue;
            const has_url = obj.get("url") != null and obj.get("url").? != .null;
            const has_hash = obj.get("hash") != null and obj.get("hash").? != .null;
            if (has_url and !has_hash) missing_hashes += 1;
            var item = std.json.ObjectMap.empty;
            try item.put(allocator, "name", copyField(obj, "name", .null));
            try item.put(allocator, "fetch_metadata_complete", .{ .bool = !has_url or has_hash });
            try item.put(allocator, "status", .{ .string = if (!has_url) "local_or_path_dependency" else if (has_hash) "ready_for_fetch_verification" else "missing_hash" });
            try checks.append(.{ .object = item });
        }
    }
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, "zig_dependency_fetch_check", "Dependency fetch readiness from manifest metadata", "medium", &.{
        "Does not run network fetches; `zig build --fetch` is the verification path.",
    });
    try obj.put(allocator, "checks", .{ .array = checks });
    try obj.put(allocator, "missing_hash_count", .{ .integer = @intCast(missing_hashes) });
    try obj.put(allocator, "ok", .{ .bool = missing_hashes == 0 });
    try obj.put(allocator, "verification_command", .{ .string = "zig build --fetch" });
    return .{ .object = obj };
}

fn dependencyLockAuditValue(allocator: std.mem.Allocator, deps: std.json.Value, lock_text: []const u8) !std.json.Value {
    var issues = std.json.Array.init(allocator);
    if (deps.object.get("issues")) |value| if (value == .array) try issues.appendSlice(value.array.items);
    const has_lock = lock_text.len > 0;
    if (!has_lock) try issues.append(.{ .string = "No lockfile evidence was supplied or discovered; Zig package reproducibility relies on build.zig.zon hashes and fetch verification." });
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, "zig_dependency_lock_audit", "Dependency manifest/lock evidence audit", "medium", &.{
        "Zig projects may not use a separate lockfile; report treats missing lock evidence as an explicit unknown, not a failure by itself.",
    });
    try obj.put(allocator, "manifest", deps);
    try obj.put(allocator, "lockfile_present", .{ .bool = has_lock });
    try obj.put(allocator, "issues", .{ .array = issues });
    try obj.put(allocator, "issue_count", .{ .integer = @intCast(issues.items.len) });
    try obj.put(allocator, "verification_commands", try stringArrayValue(allocator, &.{ "zig build --fetch", "zig build test" }));
    return .{ .object = obj };
}

fn dependencyImpactValue(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value) !std.json.Value {
    var impacted = std.json.Array.init(allocator);
    const dependency = support.argString(args, "dependency");
    if (dependency) |dep| try collectDependencyImportMatches(allocator, a, dep, &impacted, @intCast(@max(1, support.argInt(args, "limit", 200))));
    var commands = std.json.Array.init(allocator);
    try commands.append(.{ .string = "zig build --fetch" });
    try commands.append(.{ .string = "zig build test" });
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, "zig_dependency_impact", "Dependency name/import text impact scan plus validation fallback", "low", &.{
        "Impact is based on dependency names and source import text; build.zig can hide dynamic dependency wiring.",
    });
    try obj.put(allocator, "dependency", if (dependency) |dep| try support.ownedString(allocator, dep) else .null);
    try obj.put(allocator, "impacted_files", .{ .array = impacted });
    try obj.put(allocator, "changed_files", if (support.argString(args, "changed_files")) |files| try support.ownedString(allocator, files) else .null);
    try obj.put(allocator, "recommended_checks", .{ .array = commands });
    return .{ .object = obj };
}

fn collectDependencyImportMatches(allocator: std.mem.Allocator, a: *App, dependency: []const u8, impacted: *std.json.Array, limit: usize) !void {
    const scan = try a.context.workspace_scanner.scanZigFiles(allocator, .{
        .path_prefix = "",
        .max_files = limit,
        .provenance = "release.dependency_import_matches",
    });
    defer scan.deinit(allocator);
    for (scan.files) |entry| {
        if (impacted.items.len >= limit) break;
        if (!std.mem.endsWith(u8, entry.path, ".zig") or zig_analysis.skipWorkspacePath(entry.path)) continue;
        const bytes = a.workspace.readFileAlloc(a.io, entry.path, 512 * 1024) catch continue;
        defer allocator.free(bytes);
        const hit = std.mem.indexOf(u8, bytes, dependency) orelse continue;
        try impacted.append(try sourceTextMatchValue(allocator, entry.path, bytes, hit, "source_import_text"));
    }
}

fn sbomValue(allocator: std.mem.Allocator, deps: std.json.Value) !std.json.Value {
    const dependencies = deps.object.get("dependencies") orelse std.json.Value{ .array = std.json.Array.init(allocator) };
    var components = std.json.Array.init(allocator);
    if (dependencies == .array) {
        for (dependencies.array.items) |dep| {
            const obj = objectValue(dep) orelse continue;
            var component = std.json.ObjectMap.empty;
            try component.put(allocator, "type", .{ .string = "library" });
            try component.put(allocator, "name", copyField(obj, "name", .{ .string = "unknown" }));
            try component.put(allocator, "version", copyField(obj, "hash", .null));
            try component.put(allocator, "purl", try dependencyPurlValue(allocator, obj));
            try component.put(allocator, "externalReferences", try dependencyExternalRefsValue(allocator, obj));
            try components.append(.{ .object = component });
        }
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "bomFormat", .{ .string = "CycloneDX" });
    try obj.put(allocator, "specVersion", .{ .string = "1.5" });
    try obj.put(allocator, "serialNumber", .{ .string = "urn:uuid:zigar-preview" });
    try obj.put(allocator, "version", .{ .integer = 1 });
    try obj.put(allocator, "metadata", try sbomMetadataValue(allocator));
    try obj.put(allocator, "components", .{ .array = components });
    return .{ .object = obj };
}

fn sbomMetadataValue(allocator: std.mem.Allocator) !std.json.Value {
    var tools = std.json.Array.init(allocator);
    var tool = std.json.ObjectMap.empty;
    try tool.put(allocator, "vendor", .{ .string = "zigar" });
    try tool.put(allocator, "name", .{ .string = "zig_sbom" });
    try tools.append(.{ .object = tool });
    var metadata = std.json.ObjectMap.empty;
    try metadata.put(allocator, "tools", .{ .array = tools });
    try metadata.put(allocator, "component", .{ .object = std.json.ObjectMap.empty });
    return .{ .object = metadata };
}

fn dependencyPurlValue(allocator: std.mem.Allocator, dep: std.json.ObjectMap) !std.json.Value {
    const name = stringField(dep, "name") orelse return .null;
    const hash = stringField(dep, "hash") orelse "";
    return .{ .string = try std.fmt.allocPrint(allocator, "pkg:generic/zig/{s}@{s}", .{ name, hash }) };
}

fn dependencyExternalRefsValue(allocator: std.mem.Allocator, dep: std.json.ObjectMap) !std.json.Value {
    var refs = std.json.Array.init(allocator);
    if (stringField(dep, "url")) |url| {
        var ref = std.json.ObjectMap.empty;
        try ref.put(allocator, "type", .{ .string = "distribution" });
        try ref.put(allocator, "url", try support.ownedString(allocator, url));
        try refs.append(.{ .object = ref });
    }
    return .{ .array = refs };
}

fn scannerIngestTool(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, backend: []const u8) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const input = readEvidenceInput(a, allocator, args, tool_name, false) catch |err| return evidenceInputError(a, allocator, tool_name, args, err);
    defer input.deinit(allocator);
    const value = if (input.bytes.len == 0)
        try scannerUnavailableValue(scratch, tool_name, backend)
    else
        try scannerReportValue(scratch, tool_name, backend, input);
    return support.structured(allocator, value);
}

fn scannerUnavailableValue(allocator: std.mem.Allocator, tool_name: []const u8, backend: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, tool_name, "Optional external security scanner report ingestion", "low", &.{
        "No scanner report was supplied and zigar does not contact external services from this tool.",
    });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "status", .{ .string = "unavailable" });
    try obj.put(allocator, "backend", .{ .string = backend });
    try obj.put(allocator, "code", .{ .string = "scanner_report_unavailable" });
    try obj.put(allocator, "resolution", .{ .string = "Run the scanner externally, then pass its JSON/text report through content or path for ingestion." });
    return .{ .object = obj };
}

fn scannerReportValue(allocator: std.mem.Allocator, tool_name: []const u8, backend: []const u8, input: EvidenceInput) !std.json.Value {
    const lower = try asciiLowerAlloc(allocator, input.bytes);
    defer allocator.free(lower);
    const vulnerabilities = countOccurrences(lower, "vulnerab") + countOccurrences(lower, "cve-") + countOccurrences(lower, "\"id\"");
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, tool_name, "Caller-supplied scanner report ingestion", "medium", &.{
        "Scanner result shape and vulnerability semantics belong to the external scanner; zigar records observed text/JSON evidence only.",
    });
    try obj.put(allocator, "ok", .{ .bool = vulnerabilities == 0 });
    try obj.put(allocator, "status", .{ .string = "ingested" });
    try obj.put(allocator, "backend", .{ .string = backend });
    try obj.put(allocator, "finding_count", .{ .integer = @intCast(vulnerabilities) });
    try obj.put(allocator, "raw_reference", try rawReferenceValue(allocator, input));
    return .{ .object = obj };
}

fn dependencySecurityReportValue(allocator: std.mem.Allocator, deps: std.json.Value, sbom: ?[]const u8, zat: ?[]const u8, osv: ?[]const u8) !std.json.Value {
    var inputs = std.json.Array.init(allocator);
    try appendSecurityInput(allocator, &inputs, "sbom", sbom);
    try appendSecurityInput(allocator, &inputs, "zat", zat);
    try appendSecurityInput(allocator, &inputs, "osv", osv);
    const issues = deps.object.get("issues") orelse std.json.Value{ .array = std.json.Array.init(allocator) };
    const scanner_findings = countMaybeVulnerabilities(sbom) + countMaybeVulnerabilities(zat) + countMaybeVulnerabilities(osv);
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, "zig_dependency_security_report", "Dependency manifest plus supplied scanner evidence", "medium", &.{
        "Security report summarizes observed inputs; absence of scanner evidence is an unknown, not a clean bill of health.",
    });
    try obj.put(allocator, "manifest", deps);
    try obj.put(allocator, "scanner_inputs", .{ .array = inputs });
    try obj.put(allocator, "manifest_issue_count", .{ .integer = if (issues == .array) @intCast(issues.array.items.len) else 0 });
    try obj.put(allocator, "scanner_finding_count", .{ .integer = @intCast(scanner_findings) });
    try obj.put(allocator, "risk", .{ .string = if (scanner_findings > 0) "review_required" else "unknown_without_scanner_evidence" });
    try obj.put(allocator, "verification_commands", try stringArrayValue(allocator, &.{ "zig_sbom", "zig_osv_scan with supplied report", "zig_zat_scan with supplied report", "zig build --fetch" }));
    return .{ .object = obj };
}

fn appendSecurityInput(allocator: std.mem.Allocator, inputs: *std.json.Array, name: []const u8, text: ?[]const u8) !void {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "provided", .{ .bool = text != null and text.?.len > 0 });
    try obj.put(allocator, "finding_hint_count", .{ .integer = @intCast(countMaybeVulnerabilities(text)) });
    try inputs.append(.{ .object = obj });
}

fn countMaybeVulnerabilities(text: ?[]const u8) usize {
    const value = text orelse return 0;
    return countOccurrences(value, "vulnerab") + countOccurrences(value, "CVE-") + countOccurrences(value, "GHSA-");
}

fn dependencyProvenanceValue(allocator: std.mem.Allocator, deps: std.json.Value) !std.json.Value {
    const dependencies = deps.object.get("dependencies") orelse std.json.Value{ .array = std.json.Array.init(allocator) };
    var provenance = std.json.Array.init(allocator);
    if (dependencies == .array) {
        for (dependencies.array.items) |dep| {
            const obj = objectValue(dep) orelse continue;
            var item = std.json.ObjectMap.empty;
            try item.put(allocator, "name", copyField(obj, "name", .null));
            try item.put(allocator, "origin", if (obj.get("url") != null and obj.get("url").? != .null) copyField(obj, "url", .null) else copyField(obj, "path", .null));
            try item.put(allocator, "origin_kind", .{ .string = if (obj.get("url") != null and obj.get("url").? != .null) "url" else if (obj.get("path") != null and obj.get("path").? != .null) "path" else "unknown" });
            try item.put(allocator, "checksum", copyField(obj, "hash", .null));
            try item.put(allocator, "checksum_status", .{ .string = if (obj.get("hash") != null and obj.get("hash").? != .null) "declared" else "missing" });
            try item.put(allocator, "confidence", .{ .string = "medium" });
            try provenance.append(.{ .object = item });
        }
    }
    var out = std.json.ObjectMap.empty;
    try putBase(allocator, &out, "zig_dependency_provenance", "Dependency origin and checksum extraction from build.zig.zon", "medium", &.{
        "Origin and checksum evidence is manifest-declared; upstream identity and license metadata require external verification.",
    });
    try out.put(allocator, "dependencies", .{ .array = provenance });
    try out.put(allocator, "dependency_count", .{ .integer = @intCast(provenance.items.len) });
    return .{ .object = out };
}

fn dependencyLicenseSummaryValue(allocator: std.mem.Allocator, deps: std.json.Value, license_text: []const u8) !std.json.Value {
    var licenses = std.json.Array.init(allocator);
    const root_license = detectLicenseName(license_text);
    if (root_license) |name| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "scope", .{ .string = "workspace" });
        try item.put(allocator, "license", .{ .string = name });
        try item.put(allocator, "confidence", .{ .string = "medium" });
        try licenses.append(.{ .object = item });
    }
    const dependencies = deps.object.get("dependencies") orelse std.json.Value{ .array = std.json.Array.init(allocator) };
    var unknown_count: usize = 0;
    if (dependencies == .array) unknown_count = dependencies.array.items.len;
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, "zig_dependency_license_summary", "Local license text and dependency manifest summary", "low", &.{
        "Dependency licenses are not fetched or inferred from upstream packages; unknowns require external package/license review.",
    });
    try obj.put(allocator, "licenses", .{ .array = licenses });
    try obj.put(allocator, "dependency_license_unknown_count", .{ .integer = @intCast(unknown_count) });
    try obj.put(allocator, "verification", .{ .string = "Fetch dependency sources and inspect upstream LICENSE metadata before compliance decisions." });
    return .{ .object = obj };
}

fn githubDependencySubmitPlanValue(allocator: std.mem.Allocator, deps: std.json.Value, job: ?[]const u8, ref: ?[]const u8, sha: ?[]const u8) !std.json.Value {
    const dependencies = deps.object.get("dependencies") orelse std.json.Value{ .array = std.json.Array.init(allocator) };
    var snapshot_deps = std.json.Array.init(allocator);
    if (dependencies == .array) {
        for (dependencies.array.items) |dep| {
            const obj = objectValue(dep) orelse continue;
            var item = std.json.ObjectMap.empty;
            try item.put(allocator, "package_url", try dependencyPurlValue(allocator, obj));
            try item.put(allocator, "relationship", .{ .string = "direct" });
            try item.put(allocator, "scope", .{ .string = "runtime" });
            try item.put(allocator, "metadata", dep);
            try snapshot_deps.append(.{ .object = item });
        }
    }
    var payload = std.json.ObjectMap.empty;
    try payload.put(allocator, "version", .{ .integer = 0 });
    try payload.put(allocator, "job", .{ .string = job orelse "zigar-dependency-submit" });
    try payload.put(allocator, "sha", if (sha) |value| try support.ownedString(allocator, value) else .null);
    try payload.put(allocator, "ref", if (ref) |value| try support.ownedString(allocator, value) else .null);
    try payload.put(allocator, "detector", .{ .object = try detectorObject(allocator) });
    try payload.put(allocator, "dependencies", .{ .array = snapshot_deps });
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, "zig_github_dependency_submit_plan", "GitHub dependency submission payload planning without network submission", "medium", &.{
        "Plan does not submit data or validate GitHub credentials.",
        "Package URLs are best-effort generic Zig dependency identifiers from build.zig.zon.",
    });
    try obj.put(allocator, "payload", .{ .object = payload });
    try obj.put(allocator, "submit", .{ .bool = false });
    try obj.put(allocator, "next_actions", try stringArrayValue(allocator, &.{ "review payload", "submit through GitHub dependency submission API in CI with credentials" }));
    return .{ .object = obj };
}

fn detectorObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    var detector = std.json.ObjectMap.empty;
    try detector.put(allocator, "name", .{ .string = "zigar" });
    try detector.put(allocator, "url", .{ .string = "https://github.com/oly-wan-kenobi/zigar" });
    try detector.put(allocator, "version", .{ .string = "workspace" });
    return detector;
}

fn readRootLicense(a: *App, allocator: std.mem.Allocator) ![]const u8 {
    _ = allocator;
    inline for (.{ "LICENSE", "LICENSE.md", "COPYING" }) |path| {
        if (a.workspace.readFileAlloc(a.io, path, 1024 * 1024)) |bytes| return bytes else |_| {}
    }
    return "";
}

fn detectLicenseName(text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;
    if (std.mem.indexOf(u8, text, "MIT License") != null) return "MIT";
    if (std.mem.indexOf(u8, text, "Apache License") != null) return "Apache";
    if (std.mem.indexOf(u8, text, "GNU GENERAL PUBLIC LICENSE") != null) return "GPL";
    if (std.mem.indexOf(u8, text, "BSD") != null) return "BSD";
    return "unknown";
}

fn apiToolError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, err: anyerror) !Result {
    return support.toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "api_lifecycle",
        .code = "api_lifecycle_failed",
        .category = "analysis",
        .resolution = "Provide a readable source file, inline content, or a valid baseline JSON artifact, then retry.",
    }, err);
}

fn dependencyToolError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, err: anyerror) !Result {
    return support.toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "dependency_security",
        .code = "dependency_evidence_failed",
        .category = "analysis",
        .resolution = "Provide manifest content or create a readable build.zig.zon in the workspace, then retry.",
    }, err);
}

fn writeAndRegisterArtifact(a: *App, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, producer: []const u8, artifact_kind: []const u8, notes: []const u8) !void {
    try a.workspace.putFile(path, bytes);
    const artifact_abs = try a.workspace.resolveOutput(path);
    defer a.workspace.allocator.free(artifact_abs);
    const identity = try support.artifacts.identityFromBytes(allocator, path, artifact_abs, bytes);
    defer allocator.free(identity.sha256);
    support.recordWrittenArtifact(a, allocator, .{
        .identity = identity,
        .provenance = .{
            .producer = producer,
            .artifact_kind = artifact_kind,
            .notes = notes,
            .toolchain = .{
                .zig_path = a.config.zig_path,
                .zls_path = a.config.zls_path,
                .zflame_path = a.config.zflame_path,
                .diff_folded_path = a.config.diff_folded_path,
            },
        },
        .indexed_at_unix_ms = support.unixMs(a),
    }, bytes) catch {};
}

fn artifactPreviewIdentityValue(allocator: std.mem.Allocator, a: *App, path: []const u8, bytes: []const u8) !std.json.Value {
    const resolved = try a.workspace.resolveOutput(path);
    defer a.workspace.allocator.free(resolved);
    const identity = try support.artifacts.identityFromBytes(allocator, path, resolved, bytes);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes.len) });
    try obj.put(allocator, "sha256", .{ .string = identity.sha256 });
    return .{ .object = obj };
}

fn preimageIdentityForPath(a: *App, allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    const bytes = a.workspace.readFileAlloc(a.io, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return preimageValue(allocator, false, 0, ""),
        else => return err,
    };
    defer allocator.free(bytes);
    const hash = try support.artifacts.sha256Hex(allocator, bytes);
    return preimageValue(allocator, true, bytes.len, hash);
}

fn preimageValue(allocator: std.mem.Allocator, exists: bool, bytes: usize, sha256: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exists", .{ .bool = exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes) });
    try obj.put(allocator, "sha256", if (exists) .{ .string = sha256 } else .null);
    return .{ .object = obj };
}

fn putBase(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, kind: []const u8, evidence_basis: []const u8, confidence: []const u8, limitations: []const []const u8) !void {
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "evidence_basis", .{ .string = evidence_basis });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, limitations));
}

fn rawReferenceValue(allocator: std.mem.Allocator, input: EvidenceInput) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "source_kind", .{ .string = input.source_kind });
    try obj.put(allocator, "path", if (input.path) |path| try support.ownedString(allocator, path) else .null);
    try obj.put(allocator, "bytes", .{ .integer = @intCast(input.bytes.len) });
    try obj.put(allocator, "sha256", .{ .string = try support.artifacts.sha256Hex(allocator, input.bytes) });
    return .{ .object = obj };
}

fn stepValue(allocator: std.mem.Allocator, id: []const u8, description: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "id", .{ .string = id });
    try obj.put(allocator, "description", .{ .string = description });
    return .{ .object = obj };
}

fn skippedValue(allocator: std.mem.Allocator, id: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "id", .{ .string = id });
    try obj.put(allocator, "reason", .{ .string = reason });
    return .{ .object = obj };
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = try allocator.dupe(u8, value) });
    return .{ .array = array };
}

fn appendUniqueStringJson(allocator: std.mem.Allocator, array: *std.json.Array, value: []const u8) !void {
    for (array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, value)) return;
    }
    try array.append(.{ .string = try allocator.dupe(u8, value) });
}

fn declNameField(value: std.json.Value) ?[]const u8 {
    const obj = objectValue(value) orelse return null;
    return stringField(obj, "name");
}

fn objectValue(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

fn arrayValue(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return switch (obj.get(field) orelse .null) {
        .string => |value| value,
        else => null,
    };
}

fn integerField(obj: std.json.ObjectMap, field: []const u8) ?i64 {
    return switch (obj.get(field) orelse .null) {
        .integer => |value| value,
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, field: []const u8, fallback: bool) bool {
    return switch (obj.get(field) orelse .null) {
        .bool => |value| value,
        else => fallback,
    };
}

fn copyField(obj: std.json.ObjectMap, field: []const u8, fallback: std.json.Value) std.json.Value {
    return obj.get(field) orelse fallback;
}

fn asciiLowerAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, index| out[index] = std.ascii.toLower(c);
    return out;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |hit| {
        count += 1;
        pos = hit + needle.len;
    }
    return count;
}

fn lineNumber(text: []const u8, index: usize) usize {
    var line: usize = 1;
    for (text[0..@min(index, text.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

fn lineAt(text: []const u8, index: usize) []const u8 {
    var start = @min(index, text.len);
    while (start > 0 and text[start - 1] != '\n') start -= 1;
    var end = @min(index, text.len);
    while (end < text.len and text[end] != '\n') end += 1;
    return std.mem.trim(u8, text[start..end], " \t\r\n");
}

fn shortString(allocator: std.mem.Allocator, input: []const u8, limit: usize) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len <= limit) return allocator.dupe(u8, trimmed);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, trimmed[0..limit]);
    try out.appendSlice(allocator, "...");
    return out.toOwnedSlice(allocator);
}

fn stripXml(input: []const u8) []const u8 {
    return input;
}
