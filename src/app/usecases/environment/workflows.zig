const std = @import("std");
const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const support = @import("../usecase_support.zig");
const backend_catalog = @import("backend_catalog.zig");
const project_intelligence = @import("../validation/project_intelligence.zig");

/// Aliases the app context wrapper used by this workflow module.
pub const App = support.UsecaseApp(app_context.EnvironmentContext);
/// Aliases the structured result type returned by workflow entrypoints.
pub const Result = support.Result;
const artifacts = support.artifacts;
/// Aliases command execution helpers shared by workflow entrypoints.
const command = support.command;

const argBool = support.argBool;
const argInt = support.argInt;
const argString = support.argString;
const backendErrorResult = support.backendErrorResult;
/// Aliases the shared command-result serializer for structured payloads.
const commandResultValue = support.commandResultValue;
const invalidArgumentResult = support.invalidArgumentResult;
const missingArgumentResult = support.missingArgumentResult;
const ownedString = support.ownedString;
const structured = support.structured;
const toolErrorFromError = support.toolErrorFromError;
const toolTimeout = support.toolTimeout;
const workspacePathErrorResult = support.workspacePathErrorResult;

/// Default workspace path for profile data.
const profile_path = ".zigar/profile.json";
/// Default workspace path for toolchain pin data.
const toolchain_pin_path = ".zigar/toolchain.json";
/// Default workspace path for env pack data.
const env_pack_path = ".zigar-cache/env/pack.json";
/// Default workspace path for backend evidence data.
const backend_evidence_path = ".zigar-cache/backend-conformance/evidence-pack.json";
/// Default workspace path for backend report data.
const backend_report_path = ".zigar-cache/backend-conformance/report.json";

const guidance_elicitation_reason = "Advisory guidance tools do not issue MCP elicitation/create; questions are returned directly for deterministic clients.";

/// Executes the zigar setup guidance workflow and returns an allocator-owned structured result.
pub fn zigarSetupGuidance(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return guidanceResult(a, allocator, args, "zigar_setup_guidance", "setup");
}

/// Executes the zigar profile guidance workflow and returns an allocator-owned structured result.
pub fn zigarProfileGuidance(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return guidanceResult(a, allocator, args, "zigar_profile_guidance", "profile");
}

/// Executes the zigar backend guidance workflow and returns an allocator-owned structured result.
pub fn zigarBackendGuidance(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return guidanceResult(a, allocator, args, "zigar_backend_guidance", "backend");
}

/// Executes the zigar setup elicit compatibility workflow and returns an allocator-owned structured result.
pub fn zigarSetupElicit(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return guidanceResult(a, allocator, args, "zigar_setup_elicit", "setup");
}

/// Executes the zigar profile elicit compatibility workflow and returns an allocator-owned structured result.
pub fn zigarProfileElicit(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return guidanceResult(a, allocator, args, "zigar_profile_elicit", "profile");
}

/// Executes the zigar backend elicit compatibility workflow and returns an allocator-owned structured result.
pub fn zigarBackendElicit(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return guidanceResult(a, allocator, args, "zigar_backend_elicit", "backend");
}

/// Implements guidance result workflow logic using caller-owned inputs.
fn guidanceResult(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, default_topic: []const u8) !Result {
    const topic = argString(args, "topic") orelse default_topic;
    var questions = std.json.Array.init(allocator);
    var unknowns = std.json.Array.init(allocator);
    var detected = std.json.Array.init(allocator);

    try detected.append(try factValue(allocator, "workspace", a.workspace.root, "runtime_config", "high"));
    if (profileExists(a)) {
        try detected.append(try factValue(allocator, "profile", profile_path, "workspace_file", "high"));
    } else {
        try unknowns.append(try ownedString(allocator, "project profile has not been written"));
        try questions.append(try questionValue(allocator, "profile_policy", "Which source roots, test commands, target matrix, CI policy, and lint policy should be persisted in .zigar/profile.json?", "zigar_profile_bootstrap then zigar_profile_import apply=true"));
    }

    if (std.mem.eql(u8, default_topic, "backend") or std.mem.eql(u8, topic, "backend") or std.mem.eql(u8, default_topic, "setup")) {
        try questions.append(try questionValue(allocator, "optional_backends", "Which optional backends should be claimed as supported for this project: zls, zlint, zwanzig, zflame, diff-folded, or none?", "zigar_backend_verify and zigar_backend_conformance"));
        try questions.append(try questionValue(allocator, "backend_paths", "Are backend paths expected to come from PATH, a dev shell, CI image, or checked-in setup artifacts?", "zigar_backend_install_plan"));
    }
    if (std.mem.eql(u8, default_topic, "profile") or std.mem.eql(u8, topic, "toolchain") or std.mem.eql(u8, default_topic, "setup")) {
        try questions.append(try questionValue(allocator, "toolchain_pin", "Should Zig/ZLS versions be pinned from the currently active tools, explicit versions, or existing project files such as .zigversion and .tool-versions?", "zig_zls_match_check then zig_toolchain_pin"));
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "topic", .{ .string = topic });
    try obj.put(allocator, "detected_facts", .{ .array = detected });
    try obj.put(allocator, "questions", .{ .array = questions });
    try obj.put(allocator, "unknowns", .{ .array = unknowns });
    try obj.put(allocator, "blocks_noninteractive_flow", .{ .bool = false });
    try support.putElicitationUnavailable(allocator, &obj, guidance_elicitation_reason);
    try obj.put(allocator, "next_tools", try stringArrayValue(allocator, &.{ "zigar_profile_bootstrap", "zig_zls_match_check", "zigar_backend_verify", "zigar_env_pack" }));
    try obj.put(allocator, "workflow_contract", try project_intelligence.workflowContractValue(allocator, "workspace/profile/backend catalog inspection", "setup questions for unresolved policy only", "medium", "questions do not imply validation passed; skipped checks remain explicit", "run the named next_tools before release decisions", "stop when unknowns are answered or deterministic defaults are acceptable", &.{ "zigar_profile_bootstrap", "zigar_profile_import" }));
    return structured(allocator, .{ .object = obj });
}

/// Executes the zigar project profile 2 workflow and returns an allocator-owned structured result.
pub fn zigarProjectProfileV2(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const profile = if (argString(args, "content")) |content|
        parseJsonContent(allocator, "zigar_project_profile_v2", "content", content) catch |err| return parseContentError(allocator, "zigar_project_profile_v2", content, err)
    else
        try generatedProfileV2Value(allocator, a);
    return profileWriteResult(a, allocator, args, "zigar_project_profile_v2", profile);
}

/// Executes the zigar profile validate workflow and returns an allocator-owned structured result.
pub fn zigarProfileValidate(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const path = argString(args, "path") orelse profile_path;
    const loaded = if (argString(args, "content")) |content|
        loadContentValue(allocator, "zigar_profile_validate", content) catch |err| return parseContentError(allocator, "zigar_profile_validate", content, err)
    else
        loadWorkspaceJson(a, allocator, path) catch |err| switch (err) {
            error.FileNotFound => return missingProfileValidation(allocator, "zigar_profile_validate", path),
            else => |e| return jsonLoadErrorResult(a, allocator, "zigar_profile_validate", path, e),
        };
    defer loaded.deinit(allocator);
    const validation = try validateProfileValue(allocator, loaded.value);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_profile_validate" });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "validation", validation);
    return structured(allocator, .{ .object = obj });
}

/// Executes the zigar profile read workflow and returns an allocator-owned structured result.
pub fn zigarProfileRead(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const path = argString(args, "path") orelse profile_path;
    const bytes = a.workspace.readFileAlloc(a.io, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return missingProfileRead(allocator, path),
        else => return toolErrorFromError(allocator, .{
            .tool = "zigar_profile_read",
            .operation = "read_profile",
            .phase = "workspace_read",
            .code = "read_failed",
            .category = "filesystem",
            .resolution = "Confirm the profile path exists inside the workspace, then retry.",
            .details = &.{.{ .key = "path", .value = .{ .string = path } }},
        }, err),
    };
    defer allocator.free(bytes);
    const hash = artifacts.sha256Hex(allocator, bytes) catch return error.OutOfMemory;
    defer allocator.free(hash);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return parseContentError(allocator, "zigar_profile_read", bytes, error.InvalidJson);
    defer parsed.deinit();
    const validation = try validateProfileValue(allocator, parsed.value);

    var preimage = std.json.ObjectMap.empty;
    try preimage.put(allocator, "exists", .{ .bool = true });
    try preimage.put(allocator, "bytes", .{ .integer = @intCast(bytes.len) });
    try preimage.put(allocator, "sha256", .{ .string = hash });

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_profile_read" });
    try obj.put(allocator, "exists", .{ .bool = true });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "preimage_identity", .{ .object = preimage });
    try obj.put(allocator, "profile", support.cloneValue(allocator, parsed.value) catch return error.OutOfMemory);
    try obj.put(allocator, "validation", validation);
    return structured(allocator, .{ .object = obj });
}

/// Executes the zigar profile bootstrap workflow and returns an allocator-owned structured result.
pub fn zigarProfileBootstrap(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) !Result {
    const profile = try generatedProfileV2Value(allocator, a);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_profile_bootstrap" });
    try obj.put(allocator, "path", .{ .string = profile_path });
    try obj.put(allocator, "profile", profile);
    try obj.put(allocator, "detected_facts", try detectedFactsValue(allocator, a));
    try obj.put(allocator, "inferred_policy", try inferredPolicyValue(allocator));
    try obj.put(allocator, "unknowns", try profileUnknownsValue(allocator, a));
    try obj.put(allocator, "confidence", .{ .string = if (workspacePathExists(a, "build.zig")) "medium" else "low" });
    try obj.put(allocator, "next_action", .{ .string = "review unknowns, then call zigar_profile_import with apply=true to persist the profile" });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zigar profile import workflow and returns an allocator-owned structured result.
pub fn zigarProfileImport(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const content = argString(args, "content") orelse return missingArgumentResult(allocator, "zigar_profile_import", "content", "profile v2 JSON content");
    const profile = parseJsonContent(allocator, "zigar_profile_import", "content", content) catch |err| return parseContentError(allocator, "zigar_profile_import", content, err);
    return profileWriteResult(a, allocator, args, "zigar_profile_import", profile);
}

/// Executes the zigar profile diff workflow and returns an allocator-owned structured result.
pub fn zigarProfileDiff(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const path = argString(args, "path") orelse profile_path;
    const current = loadWorkspaceJson(a, allocator, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return jsonLoadErrorResult(a, allocator, "zigar_profile_diff", path, e),
    };
    defer if (current) |*loaded| loaded.deinit(allocator);
    var generated_arena = std.heap.ArenaAllocator.init(allocator);
    defer generated_arena.deinit();
    const candidate = if (argString(args, "content")) |content|
        loadContentValue(allocator, "zigar_profile_diff", content) catch |err| return parseContentError(allocator, "zigar_profile_diff", content, err)
    else
        LoadedJson{ .value = try generatedProfileV2Value(generated_arena.allocator(), a) };
    defer candidate.deinit(allocator);

    var changed = std.json.Array.init(allocator);
    const fields = [_][]const u8{ "schema_version", "toolchain", "source_sets", "generated_dirs", "targets", "tests", "ci", "lint", "backends" };
    for (fields) |field| {
        const before = if (current) |loaded| objectField(loaded.value, field) else null;
        const after = objectField(candidate.value, field);
        if (!jsonValuesEqual(before, after)) try changed.append(try ownedString(allocator, field));
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_profile_diff" });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "current_exists", .{ .bool = current != null });
    try obj.put(allocator, "changed_fields", .{ .array = changed });
    try obj.put(allocator, "changed_field_count", .{ .integer = @intCast(changed.items.len) });
    try obj.put(allocator, "comparison", .{ .string = "stable_top_level_profile_fields" });
    return structured(allocator, .{ .object = obj });
}

/// Implements profile write result workflow logic using caller-owned inputs.
fn profileWriteResult(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, profile: std.json.Value) !Result {
    const apply = argBool(args, "apply", false);
    const validation = try validateProfileValue(allocator, profile);
    const valid = validation.object.get("valid").?.bool;
    const preimage = try preimageIdentityForPath(a, allocator, profile_path);
    var serialized: std.ArrayList(u8) = .empty;
    defer serialized.deinit(allocator);
    try support.serializeValue(allocator, &serialized, profile);
    if (apply) {
        if (!valid) return invalidArgumentResult(allocator, tool_name, "content", "valid profile v2 JSON", "invalid_profile", "Fix validation.findings before applying the profile.");
        a.workspace.putFile(profile_path, serialized.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PathOutsideWorkspace, error.EmptyPath, error.AccessDenied, error.PermissionDenied => return workspacePathErrorResult(a, allocator, tool_name, profile_path, err),
            else => return toolErrorFromError(allocator, .{
                .tool = tool_name,
                .operation = "write_profile",
                .phase = "workspace_write",
                .code = "write_failed",
                .category = "filesystem",
                .resolution = "Confirm .zigar/profile.json can be created or overwritten inside the workspace, then retry with apply=true.",
                .details = &.{.{ .key = "path", .value = .{ .string = profile_path } }},
            }, err),
        };
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "schema_version", .{ .integer = 2 });
    try obj.put(allocator, "path", .{ .string = profile_path });
    try obj.put(allocator, "applied", .{ .bool = apply });
    try obj.put(allocator, "requires_apply", .{ .bool = !apply });
    try obj.put(allocator, "preimage_identity", preimage);
    try obj.put(allocator, "validation", validation);
    try obj.put(allocator, "profile", profile);
    try obj.put(allocator, "limitations", .{ .string = "Profile fields combine detected facts and conservative inferred policy; review unknowns before treating it as project governance." });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zigar env pack workflow and returns an allocator-owned structured result.
pub fn zigarEnvPack(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return structured(allocator, try envPackValue(allocator, a, args));
}

/// Executes the zigar env export workflow and returns an allocator-owned structured result.
pub fn zigarEnvExport(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const output = argString(args, "output") orelse env_pack_path;
    const apply = argBool(args, "apply", false);
    const pack = try envPackValue(allocator, a, args);
    var serialized: std.ArrayList(u8) = .empty;
    defer serialized.deinit(allocator);
    try support.serializeValue(allocator, &serialized, pack);
    const preimage = try preimageIdentityForPath(a, allocator, output);
    if (apply) {
        writeAndRegisterArtifact(a, allocator, output, serialized.items, "zigar_env_export", "environment_pack", "zigar_env_pack", "reproducible environment pack export") catch |err|
            return artifactWriteErrorResult(allocator, "zigar_env_export", output, err);
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_env_export" });
    try obj.put(allocator, "path", .{ .string = output });
    try obj.put(allocator, "applied", .{ .bool = apply });
    try obj.put(allocator, "requires_apply", .{ .bool = !apply });
    try obj.put(allocator, "preimage_identity", preimage);
    try obj.put(allocator, "artifact", try artifactPreviewIdentityValue(allocator, a, output, serialized.items));
    try obj.put(allocator, "pack", pack);
    return structured(allocator, .{ .object = obj });
}

/// Serializes env pack fields into an allocator-owned JSON value; allocation failures propagate.
fn envPackValue(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value) !std.json.Value {
    const probe_backends = argBool(args, "probe_backends", false);
    const include_hashes = argBool(args, "include_hashes", true);
    const timeout_ms = toolTimeout(a, args);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_env_pack" });
    try obj.put(allocator, "schema_version", .{ .integer = 1 });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "toolchain", try toolchainStateValue(allocator, a, probe_backends, include_hashes, timeout_ms));
    try obj.put(allocator, "pins", try toolchainPinsValue(allocator, a));
    try obj.put(allocator, "backends", try backendStatesValue(allocator, a, "all", probe_backends, include_hashes, timeout_ms));
    try obj.put(allocator, "compatibility", try compatibilityValue(allocator, a, probe_backends, timeout_ms));
    try obj.put(allocator, "setup_hints", try stringArrayValue(allocator, &.{ "use zigar_backend_install_plan for explicit setup commands", "use zig_toolchain_pin to persist expected versions", "use zigar_env_export apply=true to register this pack as evidence" }));
    try obj.put(allocator, "limitations", .{ .string = if (probe_backends) "Version probes are bounded command observations; they do not prove semantic compatibility." else "Backend versions are omitted unless probe_backends=true." });
    return .{ .object = obj };
}

/// Executes the zigar zvm probe workflow and returns an allocator-owned structured result.
pub fn zigarZvmProbe(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const zvm_path = argString(args, "zvm_path") orelse "zvm";
    const timeout_ms = @min(toolTimeout(a, args), 3000);
    var commands = std.json.Array.init(allocator);
    var available = false;
    const probes = [_]struct { name: []const u8, argv: []const []const u8 }{
        .{ .name = "version", .argv = &.{ zvm_path, "version" } },
        .{ .name = "current", .argv = &.{ zvm_path, "current" } },
        .{ .name = "list", .argv = &.{ zvm_path, "ls" } },
        .{ .name = "where", .argv = &.{ zvm_path, "where" } },
    };
    for (probes) |probe| {
        const result = support.runCommand(allocator, a, probe.argv, timeout_ms) catch |err| {
            try commands.append(try commandErrorProbeValue(allocator, probe.name, probe.argv, err));
            continue;
        };
        defer result.deinit(allocator);
        if (result.succeeded()) available = true;
        try commands.append(try commandResultProbeValue(allocator, probe.name, a, probe.argv, timeout_ms, result));
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_zvm_probe" });
    try obj.put(allocator, "zvm_path", .{ .string = zvm_path });
    try obj.put(allocator, "available", .{ .bool = available });
    try obj.put(allocator, "commands", .{ .array = commands });
    try obj.put(allocator, "mutates_environment", .{ .bool = false });
    try obj.put(allocator, "resolution", .{ .string = if (available) "Use zigar_zvm_install_plan or zigar_zvm_switch_plan for explicit next commands." else "Install ZVM separately or pass zvm_path to an executable ZVM binary; this tool never installs it." });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zigar zvm install plan workflow and returns an allocator-owned structured result.
pub fn zigarZvmInstallPlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const version = argString(args, "version") orelse return missingArgumentResult(allocator, "zigar_zvm_install_plan", "version", "Zig version to install");
    const zvm_path = argString(args, "zvm_path") orelse "zvm";
    return structured(allocator, try zvmPlanValue(allocator, "zigar_zvm_install_plan", zvm_path, version, &.{ zvm_path, "install", version }, "install requested Zig version"));
}

/// Executes the zigar zvm switch plan workflow and returns an allocator-owned structured result.
pub fn zigarZvmSwitchPlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const version = argString(args, "version") orelse return missingArgumentResult(allocator, "zigar_zvm_switch_plan", "version", "Zig version to select");
    const zvm_path = argString(args, "zvm_path") orelse "zvm";
    return structured(allocator, try zvmPlanValue(allocator, "zigar_zvm_switch_plan", zvm_path, version, &.{ zvm_path, "use", version }, "select requested Zig version"));
}

/// Executes the zig zls match check workflow and returns an allocator-owned structured result.
pub fn zigZlsMatchCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return structured(allocator, try compatibilityValueWithKind(allocator, a, args, "zig_zls_match_check"));
}

/// Executes the zig toolchain pin workflow and returns an allocator-owned structured result.
pub fn zigToolchainPin(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const output = argString(args, "output") orelse toolchain_pin_path;
    const apply = argBool(args, "apply", false);
    const pin = try explicitPinValue(allocator, a, args);
    var serialized: std.ArrayList(u8) = .empty;
    defer serialized.deinit(allocator);
    try support.serializeValue(allocator, &serialized, pin);
    const preimage = try preimageIdentityForPath(a, allocator, output);
    if (apply) {
        writeAndRegisterArtifact(a, allocator, output, serialized.items, "zig_toolchain_pin", "toolchain_pin", "zig_toolchain_pin", "project toolchain pin") catch |err|
            return artifactWriteErrorResult(allocator, "zig_toolchain_pin", output, err);
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_toolchain_pin" });
    try obj.put(allocator, "path", .{ .string = output });
    try obj.put(allocator, "applied", .{ .bool = apply });
    try obj.put(allocator, "requires_apply", .{ .bool = !apply });
    try obj.put(allocator, "preimage_identity", preimage);
    try obj.put(allocator, "pin", pin);
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig toolchain pin check workflow and returns an allocator-owned structured result.
pub fn zigToolchainPinCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const input = argString(args, "input") orelse toolchain_pin_path;
    const loaded = loadWorkspaceJson(a, allocator, input) catch |err| switch (err) {
        error.FileNotFound => return missingPinCheck(allocator, input),
        else => |e| return jsonLoadErrorResult(a, allocator, "zig_toolchain_pin_check", input, e),
    };
    defer loaded.deinit(allocator);
    const env = try envPackValue(allocator, a, args);
    var mismatches = std.json.Array.init(allocator);
    try comparePinField(allocator, &mismatches, loaded.value, env, "zig", "toolchain.zig.version");
    try comparePinField(allocator, &mismatches, loaded.value, env, "zls", "toolchain.zls.version");
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_toolchain_pin_check" });
    try obj.put(allocator, "input", .{ .string = input });
    try obj.put(allocator, "ok", .{ .bool = mismatches.items.len == 0 });
    try obj.put(allocator, "mismatches", .{ .array = mismatches });
    try obj.put(allocator, "pin", support.cloneValue(allocator, loaded.value) catch return error.OutOfMemory);
    try obj.put(allocator, "environment", env);
    return structured(allocator, .{ .object = obj });
}

/// Executes the zigar backend install plan workflow and returns an allocator-owned structured result.
pub fn zigarBackendInstallPlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const backend = normalizeBackendName(argString(args, "backend") orelse "all");
    const manager = argString(args, "manager") orelse "manual";
    var plans = std.json.Array.init(allocator);
    for (backend_catalog.backends) |entry| {
        if (!backendSelected(backend, entry.name)) continue;
        try plans.append(try backendInstallPlanValue(allocator, entry, manager));
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_backend_install_plan" });
    try obj.put(allocator, "backend", .{ .string = backend });
    try obj.put(allocator, "manager", .{ .string = manager });
    try obj.put(allocator, "plan_only", .{ .bool = true });
    try obj.put(allocator, "mutates_environment", .{ .bool = false });
    try obj.put(allocator, "plans", .{ .array = plans });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zigar backend verify workflow and returns an allocator-owned structured result.
pub fn zigarBackendVerify(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const backend = normalizeBackendName(argString(args, "backend") orelse "all");
    const timeout_ms = toolTimeout(a, args);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_backend_verify" });
    try obj.put(allocator, "backend", .{ .string = backend });
    try obj.put(allocator, "results", try backendStatesValue(allocator, a, backend, true, false, timeout_ms));
    try obj.put(allocator, "limitations", .{ .string = "Probe success only proves the executable answered the configured verification argv." });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zigar dev env generate workflow and returns an allocator-owned structured result.
pub fn zigarDevEnvGenerate(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const kind = argString(args, "kind") orelse "mise";
    const output = argString(args, "output") orelse defaultDevEnvOutput(kind);
    const apply = argBool(args, "apply", false);
    const content = try devEnvContent(allocator, a, kind);
    defer allocator.free(content);
    const preimage = try preimageIdentityForPath(a, allocator, output);
    if (apply) {
        writeAndRegisterArtifact(a, allocator, output, content, "zigar_dev_env_generate", "dev_environment", "zigar_dev_env_generate", "generated pinned development environment") catch |err|
            return artifactWriteErrorResult(allocator, "zigar_dev_env_generate", output, err);
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_dev_env_generate" });
    try obj.put(allocator, "artifact_kind", .{ .string = kind });
    try obj.put(allocator, "path", .{ .string = output });
    try obj.put(allocator, "applied", .{ .bool = apply });
    try obj.put(allocator, "requires_apply", .{ .bool = !apply });
    try obj.put(allocator, "preimage_identity", preimage);
    try obj.put(allocator, "content", .{ .string = content });
    try obj.put(allocator, "verification", .{ .string = "run zigar_backend_verify and zig_zls_match_check after applying the generated setup in a fresh shell" });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zigar backend conformance workflow and returns an allocator-owned structured result.
pub fn zigarBackendConformance(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const backend = normalizeBackendName(argString(args, "backend") orelse "all");
    const probe_backends = argBool(args, "probe_backends", false);
    const timeout_ms = toolTimeout(a, args);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_backend_conformance" });
    try obj.put(allocator, "backend", .{ .string = backend });
    try obj.put(allocator, "schema_version", .{ .integer = 1 });
    try obj.put(allocator, "run_state", .{ .string = if (probe_backends) "probe_matrix" else "plan_only" });
    try obj.put(allocator, "scenarios", try conformanceScenariosValue(allocator, backend));
    try obj.put(allocator, "verify_command", .{ .string = ".github/scripts/backend-conformance.sh" });
    try obj.put(allocator, "evidence_paths", try stringArrayValue(allocator, &.{ backend_report_path, ".zigar-cache/backend-conformance/summary.md", ".zigar-cache/backend-conformance/stdout.jsonl", ".zigar-cache/backend-conformance/stderr.log" }));
    if (probe_backends) try obj.put(allocator, "probe_results", try backendStatesValue(allocator, a, backend, true, false, timeout_ms));
    try obj.put(allocator, "limitations", .{ .string = "This MCP tool does not run the full conformance script; use the verify_command path for release-grade fake or real backend evidence." });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zigar backend evidence pack workflow and returns an allocator-owned structured result.
pub fn zigarBackendEvidencePack(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const input = argString(args, "input") orelse backend_report_path;
    const output = argString(args, "output") orelse backend_evidence_path;
    const apply = argBool(args, "apply", false);
    const evidence = try backendEvidencePackValue(a, allocator, input);
    var serialized: std.ArrayList(u8) = .empty;
    defer serialized.deinit(allocator);
    try support.serializeValue(allocator, &serialized, evidence);
    const preimage = try preimageIdentityForPath(a, allocator, output);
    if (apply) {
        writeAndRegisterArtifact(a, allocator, output, serialized.items, "zigar_backend_evidence_pack", "backend_evidence_pack", "zigar_backend_evidence_pack", "backend conformance evidence pack") catch |err|
            return artifactWriteErrorResult(allocator, "zigar_backend_evidence_pack", output, err);
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_backend_evidence_pack" });
    try obj.put(allocator, "input", .{ .string = input });
    try obj.put(allocator, "path", .{ .string = output });
    try obj.put(allocator, "applied", .{ .bool = apply });
    try obj.put(allocator, "requires_apply", .{ .bool = !apply });
    try obj.put(allocator, "preimage_identity", preimage);
    try obj.put(allocator, "evidence", evidence);
    return structured(allocator, .{ .object = obj });
}

/// Serializes generated profile 2 fields into an allocator-owned JSON value; allocation failures propagate.
fn generatedProfileV2Value(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = 2 });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "generated_by", .{ .string = "zigar_project_profile_v2" });
    try obj.put(allocator, "project_type", try projectTypeValue(allocator, a));
    try obj.put(allocator, "toolchain", try profileToolchainValue(allocator, a));
    try obj.put(allocator, "source_sets", try sourceSetsValue(allocator, a));
    try obj.put(allocator, "generated_dirs", try generatedDirsValue(allocator));
    try obj.put(allocator, "targets", try targetsValue(allocator));
    try obj.put(allocator, "tests", try testsValue(allocator, a));
    try obj.put(allocator, "benchmarks", try benchmarksValue(allocator));
    try obj.put(allocator, "public_api", try publicApiPolicyValue(allocator));
    try obj.put(allocator, "ci", try ciPolicyValue(allocator));
    try obj.put(allocator, "lint", try lintPolicyValue(allocator));
    try obj.put(allocator, "perf_budgets", try perfBudgetsValue(allocator));
    try obj.put(allocator, "backends", try profileBackendsValue(allocator, a));
    try obj.put(allocator, "unknowns", try profileUnknownsValue(allocator, a));
    try obj.put(allocator, "verification", try stringArrayValue(allocator, &.{ "zigar_profile_validate", "zig_zls_match_check", "zigar_backend_verify", "zigar_env_pack" }));
    return .{ .object = obj };
}

/// Serializes profile toolchain fields into an allocator-owned JSON value; allocation failures propagate.
fn profileToolchainValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig", .{ .string = a.config.zig_path });
    try obj.put(allocator, "zls", .{ .string = a.config.zls_path });
    try obj.put(allocator, "expected_zig_version", firstVersionHint(allocator, a) catch .null);
    try obj.put(allocator, "pin_file", .{ .string = toolchain_pin_path });
    try obj.put(allocator, "manager", .{ .string = "unknown" });
    try obj.put(allocator, "evidence", .{ .string = "runtime configuration plus workspace version hint scan" });
    return .{ .object = obj };
}

/// Serializes project type fields into an allocator-owned JSON value; allocation failures propagate.
fn projectTypeValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    const has_build = workspacePathExists(a, "build.zig");
    const has_src = workspacePathExists(a, "src");
    try obj.put(allocator, "kind", .{ .string = if (has_build)
        "build_script_project"
    else if (has_src)
        "source_tree"
    else
        "unknown" });
    try obj.put(allocator, "artifact_count", .{ .integer = 0 });
    try obj.put(allocator, "module_count", .{ .integer = if (has_src) 1 else 0 });
    try obj.put(allocator, "build_test_count", .{ .integer = 0 });
    try obj.put(allocator, "confidence", .{ .string = if (has_build or has_src) "medium" else "low" });
    return .{ .object = obj };
}

/// Serializes generated dirs fields into an allocator-owned JSON value; allocation failures propagate.
fn generatedDirsValue(allocator: std.mem.Allocator) !std.json.Value {
    var dirs = std.json.Array.init(allocator);
    for ([_][]const u8{ ".zig-cache", ".zigar-cache", "zig-out", "zig-pkg", "coverage" }) |dir| {
        try dirs.append(try ownedString(allocator, dir));
    }
    return .{ .array = dirs };
}

/// Serializes source sets fields into an allocator-owned JSON value; allocation failures propagate.
fn sourceSetsValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var sets = std.json.Array.init(allocator);
    const roots = [_][]const u8{ "src", "lib", "test", "tests" };
    for (roots) |root| {
        if (!workspacePathExists(a, root)) continue;
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "name", .{ .string = if (std.mem.eql(u8, root, "src")) "primary" else root });
        try obj.put(allocator, "path", .{ .string = root });
        try obj.put(allocator, "evidence", .{ .string = "workspace_directory_exists" });
        try obj.put(allocator, "confidence", .{ .string = if (std.mem.eql(u8, root, "src")) "high" else "medium" });
        try sets.append(.{ .object = obj });
    }
    if (sets.items.len == 0 and workspacePathExists(a, "build.zig")) {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "name", .{ .string = "build_script" });
        try obj.put(allocator, "path", .{ .string = "build.zig" });
        try obj.put(allocator, "evidence", .{ .string = "workspace_file_exists" });
        try obj.put(allocator, "confidence", .{ .string = "medium" });
        try sets.append(.{ .object = obj });
    }
    return .{ .array = sets };
}

/// Serializes tests fields into an allocator-owned JSON value; allocation failures propagate.
fn testsValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var commands = std.json.Array.init(allocator);
    if (workspacePathExists(a, "build.zig")) {
        try commands.append(try commandPolicyValue(allocator, "build_test", "zig build test", "build.zig exists", "high"));
    }
    try commands.append(try commandPolicyValue(allocator, "format_check", "zig fmt --check build.zig build.zig.zon src", "default zigar validation policy", "medium"));
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "commands", .{ .array = commands });
    try obj.put(allocator, "default_gate", .{ .string = "zigar_validate_patch" });
    return .{ .object = obj };
}

/// Serializes command policy fields into an allocator-owned JSON value; allocation failures propagate.
fn commandPolicyValue(allocator: std.mem.Allocator, name: []const u8, command_text: []const u8, evidence: []const u8, confidence: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "command", .{ .string = command_text });
    try obj.put(allocator, "evidence", .{ .string = evidence });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    return .{ .object = obj };
}

/// Serializes targets fields into an allocator-owned JSON value; allocation failures propagate.
fn targetsValue(allocator: std.mem.Allocator) !std.json.Value {
    return stringArrayValue(allocator, &.{"native"});
}

/// Serializes benchmarks fields into an allocator-owned JSON value; allocation failures propagate.
fn benchmarksValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "commands", try stringArrayValue(allocator, &.{}));
    try obj.put(allocator, "policy", .{ .string = "unconfigured" });
    return .{ .object = obj };
}

/// Serializes public api policy fields into an allocator-owned JSON value; allocation failures propagate.
fn publicApiPolicyValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "change_check", .{ .string = "zig_public_api_diff" });
    try obj.put(allocator, "confidence", .{ .string = "advisory" });
    return .{ .object = obj };
}

/// Serializes ci policy fields into an allocator-owned JSON value; allocation failures propagate.
fn ciPolicyValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "matrix", try stringArrayValue(allocator, &.{"native"}));
    try obj.put(allocator, "artifact_tools", try stringArrayValue(allocator, &.{ "zig_ci_annotations", "zig_junit", "zig_matrix_check" }));
    return .{ .object = obj };
}

/// Serializes lint policy fields into an allocator-owned JSON value; allocation failures propagate.
fn lintPolicyValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "formatter", .{ .string = "zig_format_check" });
    try obj.put(allocator, "optional_backend", .{ .string = "zlint or zwanzig" });
    try obj.put(allocator, "lint_tools", try stringArrayValue(allocator, &.{ "zig_zlint", "zig_zlint_fix", "zig_lint", "zig_lint_compare", "zig_lint_gate" }));
    try obj.put(allocator, "required", .{ .bool = false });
    return .{ .object = obj };
}

/// Serializes perf budgets fields into an allocator-owned JSON value; allocation failures propagate.
fn perfBudgetsValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "configured", .{ .bool = false });
    try obj.put(allocator, "evidence_tool", .{ .string = "zig_profile_plan" });
    return .{ .object = obj };
}

/// Serializes profile backends fields into an allocator-owned JSON value; allocation failures propagate.
fn profileBackendsValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig", try profileBackendValue(allocator, "zig", false, a.config.zig_path));
    try obj.put(allocator, "zls", try profileBackendValue(allocator, "zls", true, a.config.zls_path));
    try obj.put(allocator, "zlint", try profileBackendValue(allocator, "zlint", true, a.config.zlint_path));
    try obj.put(allocator, "zwanzig", try profileBackendValue(allocator, "zwanzig", true, a.config.zwanzig_path));
    try obj.put(allocator, "zflame", try profileBackendValue(allocator, "zflame", true, a.config.zflame_path));
    try obj.put(allocator, "diff_folded", try profileBackendValue(allocator, "diff-folded", true, a.config.diff_folded_path));
    return .{ .object = obj };
}

/// Serializes profile backend fields into an allocator-owned JSON value; allocation failures propagate.
fn profileBackendValue(allocator: std.mem.Allocator, name: []const u8, optional: bool, path: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "optional", .{ .bool = optional });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "required_for_release_claims", .{ .bool = !optional });
    return .{ .object = obj };
}

/// Serializes profile unknowns fields into an allocator-owned JSON value; allocation failures propagate.
fn profileUnknownsValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var unknowns = std.json.Array.init(allocator);
    if (!workspacePathExists(a, ".zigversion") and !workspacePathExists(a, ".tool-versions") and !workspacePathExists(a, "mise.toml")) {
        try unknowns.append(try unknownValue(allocator, "toolchain_pin", "no explicit Zig/ZLS pin file was detected", "zig_toolchain_pin"));
    }
    try unknowns.append(try unknownValue(allocator, "release_backend_claims", "optional backend support claims require project policy", "zigar_backend_conformance"));
    try unknowns.append(try unknownValue(allocator, "performance_budgets", "performance budgets are not inferred from source layout", "zig_profile_plan"));
    return .{ .array = unknowns };
}

/// Serializes unknown fields into an allocator-owned JSON value; allocation failures propagate.
fn unknownValue(allocator: std.mem.Allocator, key: []const u8, reason: []const u8, verification: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "key", .{ .string = key });
    try obj.put(allocator, "reason", .{ .string = reason });
    try obj.put(allocator, "verification", .{ .string = verification });
    return .{ .object = obj };
}

/// Serializes detected facts fields into an allocator-owned JSON value; allocation failures propagate.
fn detectedFactsValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var facts = std.json.Array.init(allocator);
    if (workspacePathExists(a, "build.zig")) try facts.append(try factValue(allocator, "build_file", "build.zig", "workspace_file", "high"));
    if (workspacePathExists(a, "build.zig.zon")) try facts.append(try factValue(allocator, "package_file", "build.zig.zon", "workspace_file", "high"));
    if (workspacePathExists(a, "src")) try facts.append(try factValue(allocator, "source_root", "src", "workspace_directory", "high"));
    return .{ .array = facts };
}

/// Serializes inferred policy fields into an allocator-owned JSON value; allocation failures propagate.
fn inferredPolicyValue(allocator: std.mem.Allocator) !std.json.Value {
    var policies = std.json.Array.init(allocator);
    try policies.append(try factValue(allocator, "default_validation", "zigar_validate_patch", "zigar_policy", "medium"));
    try policies.append(try factValue(allocator, "generated_dirs", ".zig-cache,.zigar-cache,zig-out,coverage", "zigar_policy", "high"));
    return .{ .array = policies };
}

/// Serializes validate profile fields into an allocator-owned JSON value; allocation failures propagate.
fn validateProfileValue(allocator: std.mem.Allocator, profile: std.json.Value) !std.json.Value {
    var findings = std.json.Array.init(allocator);
    var valid = true;
    if (profile != .object) {
        valid = false;
        try findings.append(try findingValue(allocator, "schema.root", "error", "profile must be a JSON object", "provide an object with schema_version=2"));
    } else {
        const obj = profile.object;
        const version = obj.get("schema_version") orelse .null;
        if (version != .integer or version.integer != 2) {
            valid = false;
            try findings.append(try findingValue(allocator, "schema.schema_version", "error", "profile schema_version must be integer 2", "regenerate with zigar_project_profile_v2"));
        }
        const required = [_][]const u8{ "toolchain", "source_sets", "generated_dirs", "targets", "tests", "backends", "verification" };
        for (required) |field| {
            if (obj.get(field) == null) {
                valid = false;
                const rule = try std.fmt.allocPrint(allocator, "schema.{s}", .{field});
                defer allocator.free(rule);
                const message = try std.fmt.allocPrint(allocator, "missing required profile field `{s}`", .{field});
                defer allocator.free(message);
                try findings.append(try findingValue(allocator, rule, "error", message, "regenerate or import a complete v2 profile"));
            }
        }
        if (obj.get("unknowns") == null) {
            try findings.append(try findingValue(allocator, "schema.unknowns", "warning", "profile does not expose unresolved ambiguity", "add an unknowns array, even when empty"));
        }
    }
    var out = std.json.ObjectMap.empty;
    errdefer out.deinit(allocator);
    try out.put(allocator, "valid", .{ .bool = valid });
    try out.put(allocator, "schema_version", .{ .integer = 2 });
    try out.put(allocator, "findings", .{ .array = findings });
    try out.put(allocator, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try out.put(allocator, "evidence_source", .{ .string = "profile_json_shape" });
    try out.put(allocator, "confidence", .{ .string = "high" });
    return .{ .object = out };
}

/// Serializes finding fields into an allocator-owned JSON value; allocation failures propagate.
fn findingValue(allocator: std.mem.Allocator, rule: []const u8, severity: []const u8, message: []const u8, recommendation: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "source", .{ .string = "zigar_profile_validate" });
    try obj.put(allocator, "rule", .{ .string = rule });
    try obj.put(allocator, "severity", .{ .string = severity });
    try obj.put(allocator, "message", .{ .string = message });
    try obj.put(allocator, "confidence", .{ .string = "high" });
    try obj.put(allocator, "recommended_cross_check", .{ .string = recommendation });
    return .{ .object = obj };
}

/// Serializes toolchain state fields into an allocator-owned JSON value; allocation failures propagate.
fn toolchainStateValue(allocator: std.mem.Allocator, a: *App, probe: bool, include_hashes: bool, timeout_ms: i64) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig", try executableStateValue(allocator, a, "zig", a.config.zig_path, &.{ a.config.zig_path, "version" }, probe, include_hashes, timeout_ms));
    try obj.put(allocator, "zls", try executableStateValue(allocator, a, "zls", a.config.zls_path, &.{ a.config.zls_path, "--version" }, probe, include_hashes, timeout_ms));
    return .{ .object = obj };
}

/// Serializes backend states fields into an allocator-owned JSON value; allocation failures propagate.
fn backendStatesValue(allocator: std.mem.Allocator, a: *App, selected: []const u8, probe: bool, include_hashes: bool, timeout_ms: i64) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (backend_catalog.backends) |entry| {
        if (!backendSelected(selected, entry.name)) continue;
        const path = configuredBackendPath(a, entry.name);
        const argv = if (std.mem.eql(u8, entry.name, "zig"))
            [2][]const u8{ path, "version" }
        else if (std.mem.eql(u8, entry.name, "zls"))
            [2][]const u8{ path, "--version" }
        else
            [2][]const u8{ path, "--help" };
        try array.append(try executableStateValue(allocator, a, entry.name, path, &argv, probe, include_hashes, timeout_ms));
    }
    return .{ .array = array };
}

/// Serializes executable state fields into an allocator-owned JSON value; allocation failures propagate.
fn executableStateValue(allocator: std.mem.Allocator, a: *App, name: []const u8, path: []const u8, argv: []const []const u8, probe: bool, include_hashes: bool, timeout_ms: i64) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "probe_argv", try support.argvValue(allocator, argv));
    if (include_hashes) {
        try obj.put(allocator, "sha256", try executableHashValue(allocator, a, path));
    } else {
        try obj.put(allocator, "sha256", .null);
    }
    if (probe) {
        const result = support.runCommand(allocator, a, argv, timeout_ms) catch |err| {
            try obj.put(allocator, "available", .{ .bool = false });
            try obj.put(allocator, "status", .{ .string = command.errorKind(err) });
            try obj.put(allocator, "version", .null);
            try obj.put(allocator, "probe_error", .{ .string = @errorName(err) });
            return .{ .object = obj };
        };
        defer result.deinit(allocator);
        try obj.put(allocator, "available", .{ .bool = result.succeeded() });
        try obj.put(allocator, "status", .{ .string = if (result.succeeded()) "available" else "probe_failed" });
        try obj.put(allocator, "version", try trimmedOutputValue(allocator, result));
        try obj.put(allocator, "probe", try commandResultValue(allocator, name, argv, a.workspace.root, timeout_ms, result));
    } else {
        try obj.put(allocator, "available", .null);
        try obj.put(allocator, "status", .{ .string = "not_probed" });
        try obj.put(allocator, "version", .null);
    }
    return .{ .object = obj };
}

/// Serializes the Zig/ZLS version match report data into an allocator-owned JSON value; allocation failures propagate.
fn compatibilityValue(allocator: std.mem.Allocator, a: *App, probe: bool, timeout_ms: i64) !std.json.Value {
    return compatibilityValueWithProbe(allocator, a, probe, timeout_ms, "zig_zls_compatibility");
}

/// Serializes a named Zig/ZLS version match report data into an allocator-owned JSON value; allocation failures propagate.
fn compatibilityValueWithKind(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value, kind: []const u8) !std.json.Value {
    return compatibilityValueWithProbe(allocator, a, argBool(args, "probe_backends", true), toolTimeout(a, args), kind);
}

/// Serializes a probed Zig/ZLS version match report data into an allocator-owned JSON value; allocation failures propagate.
fn compatibilityValueWithProbe(allocator: std.mem.Allocator, a: *App, probe: bool, timeout_ms: i64, kind: []const u8) !std.json.Value {
    const zig_version = if (probe) probeVersion(allocator, a, &.{ a.config.zig_path, "version" }, timeout_ms) catch null else null;
    defer if (zig_version) |value| allocator.free(value);
    const zls_version = if (probe) probeVersion(allocator, a, &.{ a.config.zls_path, "--version" }, timeout_ms) catch null else null;
    defer if (zls_version) |value| allocator.free(value);
    const status = compatibilityStatus(zig_version, zls_version);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "zig_path", .{ .string = a.config.zig_path });
    try obj.put(allocator, "zls_path", .{ .string = a.config.zls_path });
    try obj.put(allocator, "zig_version", if (zig_version) |value| .{ .string = value } else .null);
    try obj.put(allocator, "zls_version", if (zls_version) |value| .{ .string = value } else .null);
    try obj.put(allocator, "match", .{ .bool = std.mem.eql(u8, status, "match") });
    try obj.put(allocator, "status", .{ .string = status });
    try obj.put(allocator, "project_version_hints", try projectVersionHintsValue(allocator, a));
    try obj.put(allocator, "confidence", .{ .string = if (probe and zig_version != null and zls_version != null) "medium" else "low" });
    try obj.put(allocator, "limitations", .{ .string = "ZLS version strings are not standardized; this check compares parsed release prefixes and project hints only." });
    try obj.put(allocator, "resolution", .{ .string = "Install matching Zig/ZLS release lines or pin both in .zigar/toolchain.json and your dev environment." });
    return .{ .object = obj };
}

/// Serializes explicit pin fields into an allocator-owned JSON value; allocation failures propagate.
fn explicitPinValue(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = 1 });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "zig", try pinEntryValue(allocator, "zig", a.config.zig_path, argString(args, "zig_version")));
    try obj.put(allocator, "zls", try pinEntryValue(allocator, "zls", a.config.zls_path, argString(args, "zls_version")));
    try obj.put(allocator, "zlint", try pinEntryValue(allocator, "zlint", a.config.zlint_path, argString(args, "zlint_version")));
    try obj.put(allocator, "zwanzig", try pinEntryValue(allocator, "zwanzig", a.config.zwanzig_path, argString(args, "zwanzig_version")));
    try obj.put(allocator, "zflame", try pinEntryValue(allocator, "zflame", a.config.zflame_path, argString(args, "zflame_version")));
    try obj.put(allocator, "diff_folded", try pinEntryValue(allocator, "diff-folded", a.config.diff_folded_path, argString(args, "diff_folded_version")));
    try obj.put(allocator, "verification", try stringArrayValue(allocator, &.{ "zig_toolchain_pin_check", "zig_zls_match_check", "zigar_backend_verify" }));
    return .{ .object = obj };
}

/// Serializes pin entry fields into an allocator-owned JSON value; allocation failures propagate.
fn pinEntryValue(allocator: std.mem.Allocator, name: []const u8, path: []const u8, version: ?[]const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "path", .{ .string = path });
    if (version) |value| try obj.put(allocator, "version", .{ .string = value }) else try obj.put(allocator, "version", .null);
    try obj.put(allocator, "source", .{ .string = if (version != null) "explicit_argument" else "runtime_path_only" });
    return .{ .object = obj };
}

/// Serializes backend install plan fields into an allocator-owned JSON value; allocation failures propagate.
fn backendInstallPlanValue(allocator: std.mem.Allocator, entry: backend_catalog.Backend, manager: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "backend", .{ .string = entry.name });
    try obj.put(allocator, "optional", .{ .bool = entry.optional });
    try obj.put(allocator, "path_flag", .{ .string = entry.path_flag });
    try obj.put(allocator, "compatibility", .{ .string = entry.compatibility });
    try obj.put(allocator, "install_strategy", .{ .string = entry.install_strategy });
    try obj.put(allocator, "commands", try setupCommandsValue(allocator, entry.name, manager));
    try obj.put(allocator, "verify", try stringArrayValue(allocator, entry.verify));
    return .{ .object = obj };
}

/// Serializes setup commands fields into an allocator-owned JSON value; allocation failures propagate.
fn setupCommandsValue(allocator: std.mem.Allocator, backend: []const u8, manager: []const u8) !std.json.Value {
    var commands = std.json.Array.init(allocator);
    if (std.mem.eql(u8, backend, "zig")) {
        if (std.mem.eql(u8, manager, "zvm")) {
            try commands.append(try ownedString(allocator, "zvm install 0.16.0"));
            try commands.append(try ownedString(allocator, "zvm use 0.16.0"));
        } else if (std.mem.eql(u8, manager, "mise")) {
            try commands.append(try ownedString(allocator, "mise use zig@0.16.0"));
        } else {
            try commands.append(try ownedString(allocator, "install Zig 0.16.0 with your project-approved version manager"));
        }
    } else {
        const command_text = try std.fmt.allocPrint(allocator, "pin {s} in the project dev shell or CI image, then pass its absolute path to zigar", .{backend});
        try commands.append(.{ .string = command_text });
    }
    return .{ .array = commands };
}

/// Serializes conformance scenarios fields into an allocator-owned JSON value; allocation failures propagate.
fn conformanceScenariosValue(allocator: std.mem.Allocator, selected: []const u8) !std.json.Value {
    var scenarios = std.json.Array.init(allocator);
    const rows = [_]struct { backend: []const u8, scenario: []const u8, evidence: []const u8 }{
        .{ .backend = "zls", .scenario = "zls_document_symbols", .evidence = "MCP document symbol response and backend version/hash" },
        .{ .backend = "zlint", .scenario = "zlint_diagnostics_json", .evidence = "normalized ZLint diagnostics" },
        .{ .backend = "zlint", .scenario = "zlint_sarif_export", .evidence = "SARIF converted from normalized ZLint diagnostics" },
        .{ .backend = "zlint", .scenario = "zlint_rule_catalog", .evidence = "ZLint rule metadata" },
        .{ .backend = "zlint", .scenario = "zlint_fix_preview", .evidence = "apply-gated ZLint fix plan" },
        .{ .backend = "zwanzig", .scenario = "zwanzig_lint_json", .evidence = "JSON lint output" },
        .{ .backend = "zwanzig", .scenario = "zwanzig_lint_sarif", .evidence = "SARIF lint output" },
        .{ .backend = "zwanzig", .scenario = "zwanzig_analysis_graphs_cfg", .evidence = "DOT graph artifact" },
        .{ .backend = "zflame", .scenario = "zflame_recursive_folded_svg", .evidence = "SVG artifact with sha256" },
        .{ .backend = "diff_folded", .scenario = "diff_folded_recursive_svg_intermediate", .evidence = "folded diff and SVG artifacts" },
    };
    for (rows) |row| {
        if (!backendSelected(selected, row.backend)) continue;
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "backend", .{ .string = row.backend });
        try obj.put(allocator, "name", .{ .string = row.scenario });
        try obj.put(allocator, "evidence", .{ .string = row.evidence });
        try obj.put(allocator, "status", .{ .string = "planned" });
        try scenarios.append(.{ .object = obj });
    }
    return .{ .array = scenarios };
}

/// Serializes backend evidence pack fields into an allocator-owned JSON value; allocation failures propagate.
fn backendEvidencePackValue(a: *App, allocator: std.mem.Allocator, input: []const u8) !std.json.Value {
    const loaded = loadWorkspaceJson(a, allocator, input) catch |err| switch (err) {
        error.FileNotFound => return unavailableEvidencePackValue(allocator, input),
        else => return unavailableEvidencePackValue(allocator, input),
    };
    defer loaded.deinit(allocator);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_backend_evidence_pack" });
    try obj.put(allocator, "schema_version", .{ .integer = 1 });
    try obj.put(allocator, "input", .{ .string = input });
    try obj.put(allocator, "available", .{ .bool = true });
    try obj.put(allocator, "report_kind", jsonObjectString(loaded.value, "kind"));
    try obj.put(allocator, "result", jsonObjectString(loaded.value, "result"));
    try obj.put(allocator, "source_commit", jsonObjectString(loaded.value, "source_commit"));
    try obj.put(allocator, "report", support.cloneValue(allocator, loaded.value) catch return error.OutOfMemory);
    try obj.put(allocator, "limitations", .{ .string = "Evidence pack preserves the report; consumers must inspect scenario statuses before treating backend support as release evidence." });
    return .{ .object = obj };
}

/// Serializes unavailable evidence pack fields into an allocator-owned JSON value; allocation failures propagate.
fn unavailableEvidencePackValue(allocator: std.mem.Allocator, input: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigar_backend_evidence_pack" });
    try obj.put(allocator, "schema_version", .{ .integer = 1 });
    try obj.put(allocator, "input", .{ .string = input });
    try obj.put(allocator, "available", .{ .bool = false });
    try obj.put(allocator, "status", .{ .string = "missing_report" });
    try obj.put(allocator, "resolution", .{ .string = "Run .github/scripts/backend-conformance.sh or pass input to an existing conformance report, then rerun with apply=true to export evidence." });
    return .{ .object = obj };
}

/// Carries loaded json data across use case and port boundaries.
const LoadedJson = struct {
    value: std.json.Value,
    parsed: ?std.json.Parsed(std.json.Value) = null,
    owned: bool = false,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    fn deinit(self: LoadedJson, allocator: std.mem.Allocator) void {
        if (self.parsed) |parsed| {
            var mutable = parsed;
            mutable.deinit();
        } else if (self.owned) {
            support.deinitOwnedValue(allocator, self.value);
        }
    }
};

/// Serializes load content fields into an allocator-owned JSON value; allocation failures propagate.
fn loadContentValue(allocator: std.mem.Allocator, tool_name: []const u8, content: []const u8) !LoadedJson {
    _ = tool_name;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    errdefer parsed.deinit();
    return .{ .value = parsed.value, .parsed = parsed };
}

/// Parses json content input using caller-provided storage; malformed input and allocation failures propagate.
fn parseJsonContent(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, content: []const u8) !std.json.Value {
    _ = field;
    const loaded = try loadContentValue(allocator, tool_name, content);
    defer loaded.deinit(allocator);
    return support.cloneValue(allocator, loaded.value);
}

/// Reads workspace json data from the provided context without taking ownership of inputs.
fn loadWorkspaceJson(a: *App, allocator: std.mem.Allocator, path: []const u8) !LoadedJson {
    const bytes = a.workspace.readFileAlloc(a.io, path, 2 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidJson;
    errdefer parsed.deinit();
    return .{ .value = parsed.value, .parsed = parsed };
}

/// Extracts json load error result data from JSON input without taking ownership of borrowed values.
fn jsonLoadErrorResult(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8, err: anyerror) !Result {
    return switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => workspacePathErrorResult(a, allocator, tool_name, path, err),
        error.InvalidJson => invalidArgumentResult(allocator, tool_name, "path", "valid JSON file", "invalid_json", "Pass a valid JSON file path inside the workspace."),
        else => toolErrorFromError(allocator, .{
            .tool = tool_name,
            .operation = "read_json",
            .phase = "workspace_read",
            .code = "read_failed",
            .category = "filesystem",
            .resolution = "Confirm the JSON file exists inside the workspace and is below zigar's bounded read limit.",
            .details = &.{.{ .key = "path", .value = .{ .string = path } }},
        }, err),
    };
}

/// Implements artifact write error result workflow logic using caller-owned inputs.
fn artifactWriteErrorResult(allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8, err: anyerror) !Result {
    return toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = "write_artifact",
        .phase = "apply_artifact",
        .code = "artifact_write_failed",
        .category = "filesystem",
        .resolution = "Confirm the output path is inside the workspace and writable, then retry with apply=true.",
        .details = &.{.{ .key = "path", .value = .{ .string = path } }},
    }, err);
}

/// Parses content error input using caller-provided storage; malformed input and allocation failures propagate.
fn parseContentError(allocator: std.mem.Allocator, tool_name: []const u8, content: []const u8, err: anyerror) !Result {
    _ = content;
    return invalidArgumentResult(allocator, tool_name, "content", "valid JSON object", if (err == error.InvalidJson) "invalid_json" else @errorName(err), "Pass a JSON object produced by zigar_profile_bootstrap or zigar_project_profile_v2.");
}

/// Implements missing profile validation workflow logic using caller-owned inputs.
fn missingProfileValidation(allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8) !Result {
    var validation = std.json.ObjectMap.empty;
    try validation.put(allocator, "valid", .{ .bool = false });
    try validation.put(allocator, "findings", try singleFindingArray(allocator, "schema.profile_file", "error", "profile file is missing", "run zigar_profile_bootstrap then zigar_profile_import"));
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "validation", .{ .object = validation });
    return structured(allocator, .{ .object = obj });
}

/// Implements missing profile read workflow logic using caller-owned inputs.
fn missingProfileRead(allocator: std.mem.Allocator, path: []const u8) !Result {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigar_profile_read" });
    try obj.put(allocator, "exists", .{ .bool = false });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "profile", .null);
    try obj.put(allocator, "resolution", .{ .string = "Run zigar_profile_bootstrap, review unknowns, then zigar_profile_import with apply=true." });
    return structured(allocator, .{ .object = obj });
}

/// Implements single finding array workflow logic using caller-owned inputs.
fn singleFindingArray(allocator: std.mem.Allocator, rule: []const u8, severity: []const u8, message: []const u8, recommendation: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    try array.append(try findingValue(allocator, rule, severity, message, recommendation));
    return .{ .array = array };
}

/// Implements missing pin check workflow logic using caller-owned inputs.
fn missingPinCheck(allocator: std.mem.Allocator, input: []const u8) !Result {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_toolchain_pin_check" });
    try obj.put(allocator, "input", .{ .string = input });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "status", .{ .string = "pin_missing" });
    try obj.put(allocator, "resolution", .{ .string = "Run zig_toolchain_pin with apply=true after choosing explicit expected versions." });
    return structured(allocator, .{ .object = obj });
}

/// Builds preimage identity metadata for the requested workspace path.
fn preimageIdentityForPath(a: *App, allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    const bytes = a.workspace.readFileAlloc(a.io, path, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return preimageValue(allocator, false, 0, ""),
        else => return preimageValue(allocator, false, 0, ""),
    };
    defer allocator.free(bytes);
    const hash = artifacts.sha256Hex(allocator, bytes) catch return error.OutOfMemory;
    defer allocator.free(hash);
    return preimageValue(allocator, true, bytes.len, hash);
}

/// Serializes preimage fields into an allocator-owned JSON value; allocation failures propagate.
fn preimageValue(allocator: std.mem.Allocator, exists: bool, bytes: usize, sha256: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exists", .{ .bool = exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes) });
    if (exists) try obj.put(allocator, "sha256", .{ .string = sha256 }) else try obj.put(allocator, "sha256", .null);
    return .{ .object = obj };
}

/// Serializes artifact preview identity fields into an allocator-owned JSON value; allocation failures propagate.
fn artifactPreviewIdentityValue(allocator: std.mem.Allocator, a: *App, path: []const u8, bytes: []const u8) !std.json.Value {
    const resolved = a.workspace.resolveOutput(path) catch path;
    defer if (resolved.ptr != path.ptr) a.workspace.allocator.free(resolved);
    const identity = try artifacts.identityFromBytes(allocator, path, resolved, bytes);
    defer allocator.free(identity.sha256);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes.len) });
    try obj.put(allocator, "sha256", .{ .string = identity.sha256 });
    return .{ .object = obj };
}

/// Writes and register artifact fields to the provided JSON stream and propagates writer failures.
fn writeAndRegisterArtifact(a: *App, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, producer: []const u8, artifact_kind: []const u8, backend_name: []const u8, notes: []const u8) !void {
    a.workspace.putFile(path, bytes) catch return error.WriteFailed;
    const artifact_abs = try a.workspace.resolveOutput(path);
    defer a.workspace.allocator.free(artifact_abs);
    const identity = try artifacts.identityFromBytes(allocator, path, artifact_abs, bytes);
    defer allocator.free(identity.sha256);
    support.recordWrittenArtifact(a, allocator, .{
        .identity = identity,
        .provenance = .{
            .producer = producer,
            .artifact_kind = artifact_kind,
            .backend_name = backend_name,
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

/// Serializes command result probe fields into an allocator-owned JSON value; allocation failures propagate.
fn commandResultProbeValue(allocator: std.mem.Allocator, name: []const u8, a: *App, argv: []const []const u8, timeout_ms: i64, result: command.RunResult) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "ok", .{ .bool = result.succeeded() });
    try obj.put(allocator, "command", try commandResultValue(allocator, name, argv, a.workspace.root, timeout_ms, result));
    return .{ .object = obj };
}

/// Serializes command error probe fields into an allocator-owned JSON value; allocation failures propagate.
fn commandErrorProbeValue(allocator: std.mem.Allocator, name: []const u8, argv: []const []const u8, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "argv", try support.argvValue(allocator, argv));
    try obj.put(allocator, "error_kind", .{ .string = command.errorKind(err) });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    return .{ .object = obj };
}

/// Serializes zvm plan fields into an allocator-owned JSON value; allocation failures propagate.
fn zvmPlanValue(allocator: std.mem.Allocator, kind: []const u8, zvm_path: []const u8, version: []const u8, argv: []const []const u8, description: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "zvm_path", .{ .string = zvm_path });
    try obj.put(allocator, "version", .{ .string = version });
    try obj.put(allocator, "argv", try support.argvValue(allocator, argv));
    try obj.put(allocator, "description", .{ .string = description });
    try obj.put(allocator, "plan_only", .{ .bool = true });
    try obj.put(allocator, "mutates_environment", .{ .bool = false });
    try obj.put(allocator, "requires_user_execution", .{ .bool = true });
    try obj.put(allocator, "verification", try stringArrayValue(allocator, &.{ "zigar_zvm_probe", "zig_zls_match_check", "zig_toolchain_pin_check" }));
    return .{ .object = obj };
}

/// Implements default dev env output workflow logic using caller-owned inputs.
fn defaultDevEnvOutput(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "asdf")) return ".zigar-cache/dev-env/.tool-versions";
    if (std.mem.eql(u8, kind, "nix")) return ".zigar-cache/dev-env/flake.nix";
    if (std.mem.eql(u8, kind, "devcontainer")) return ".zigar-cache/dev-env/devcontainer.json";
    if (std.mem.eql(u8, kind, "github-actions")) return ".zigar-cache/dev-env/github-actions.yml";
    return ".zigar-cache/dev-env/mise.toml";
}

/// Implements dev env content workflow logic using caller-owned inputs.
fn devEnvContent(allocator: std.mem.Allocator, a: *App, kind: []const u8) ![]u8 {
    const version = versionFromHints(a) orelse backend_catalog.supported_zig_version;
    if (std.mem.eql(u8, kind, "asdf")) return std.fmt.allocPrint(allocator, "zig {s}\n", .{version});
    if (std.mem.eql(u8, kind, "nix")) return std.fmt.allocPrint(allocator,
        \\{{
        \\  description = "zigar pinned Zig environment";
        \\  outputs = {{ self, nixpkgs }}: {{}};
        \\}}
        \\
    , .{});
    if (std.mem.eql(u8, kind, "devcontainer")) return std.fmt.allocPrint(allocator,
        \\{{"name":"zigar","features":{{}},"customizations":{{"zigar":{{"zig_version":"{s}"}}}}}}
        \\
    , .{version});
    if (std.mem.eql(u8, kind, "github-actions")) return std.fmt.allocPrint(allocator,
        \\name: zigar
        \\on: [push, pull_request]
        \\jobs:
        \\  test:
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - uses: actions/checkout@v4
        \\      - run: zig build test
        \\        env:
        \\          ZIG_VERSION: "{s}"
        \\
    , .{version});
    return std.fmt.allocPrint(allocator, "[tools]\nzig = \"{s}\"\n", .{version});
}

/// Implements version from hints workflow logic using caller-owned inputs.
fn versionFromHints(a: *App) ?[]const u8 {
    _ = a;
    return null;
}

/// Implements first version hint workflow logic using caller-owned inputs.
fn firstVersionHint(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var hints = std.json.Array.init(allocator);
    tryAppendVersionHint(allocator, &hints, a, ".zigversion", "zig", ".zigversion");
    tryAppendToolVersionsHint(allocator, &hints, a);
    tryAppendMiseHint(allocator, &hints, a);
    tryAppendBuildZonMinimumHint(allocator, &hints, a);
    if (hints.items.len == 0) return .null;
    const first = hints.items[0].object.get("version") orelse return .null;
    return support.cloneValue(allocator, first);
}

/// Serializes project version hints fields into an allocator-owned JSON value; allocation failures propagate.
fn projectVersionHintsValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var hints = std.json.Array.init(allocator);
    tryAppendVersionHint(allocator, &hints, a, ".zigversion", "zig", ".zigversion");
    tryAppendToolVersionsHint(allocator, &hints, a);
    tryAppendMiseHint(allocator, &hints, a);
    tryAppendBuildZonMinimumHint(allocator, &hints, a);
    return .{ .array = hints };
}

/// Implements try append version hint workflow logic using caller-owned inputs.
fn tryAppendVersionHint(allocator: std.mem.Allocator, hints: *std.json.Array, a: *App, path: []const u8, tool: []const u8, source: []const u8) void {
    const bytes = a.workspace.readFileAlloc(a.io, path, 128 * 1024) catch return;
    defer allocator.free(bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n\"");
    if (trimmed.len == 0) return;
    var obj = std.json.ObjectMap.empty;
    obj.put(allocator, "tool", .{ .string = tool }) catch return;
    obj.put(allocator, "version", .{ .string = allocator.dupe(u8, trimmed) catch return }) catch return;
    obj.put(allocator, "source", .{ .string = source }) catch return;
    obj.put(allocator, "path", .{ .string = path }) catch return;
    hints.append(.{ .object = obj }) catch return;
}

/// Implements try append tool versions hint workflow logic using caller-owned inputs.
fn tryAppendToolVersionsHint(allocator: std.mem.Allocator, hints: *std.json.Array, a: *App) void {
    const bytes = a.workspace.readFileAlloc(a.io, ".tool-versions", 256 * 1024) catch return;
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const tool = parts.next() orelse continue;
        const version = parts.next() orelse continue;
        if (!std.mem.eql(u8, tool, "zig") and !std.mem.eql(u8, tool, "zls")) continue;
        var obj = std.json.ObjectMap.empty;
        obj.put(allocator, "tool", .{ .string = tool }) catch return;
        obj.put(allocator, "version", .{ .string = allocator.dupe(u8, version) catch return }) catch return;
        obj.put(allocator, "source", .{ .string = ".tool-versions" }) catch return;
        obj.put(allocator, "path", .{ .string = ".tool-versions" }) catch return;
        hints.append(.{ .object = obj }) catch return;
    }
}

/// Implements try append mise hint workflow logic using caller-owned inputs.
fn tryAppendMiseHint(allocator: std.mem.Allocator, hints: *std.json.Array, a: *App) void {
    const bytes = a.workspace.readFileAlloc(a.io, "mise.toml", 256 * 1024) catch return;
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "zig")) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t\r\n\"");
        if (value.len == 0) continue;
        var obj = std.json.ObjectMap.empty;
        obj.put(allocator, "tool", .{ .string = "zig" }) catch return;
        obj.put(allocator, "version", .{ .string = allocator.dupe(u8, value) catch return }) catch return;
        obj.put(allocator, "source", .{ .string = "mise.toml" }) catch return;
        obj.put(allocator, "path", .{ .string = "mise.toml" }) catch return;
        hints.append(.{ .object = obj }) catch return;
        return;
    }
}

/// Implements try append build zon minimum hint workflow logic using caller-owned inputs.
fn tryAppendBuildZonMinimumHint(allocator: std.mem.Allocator, hints: *std.json.Array, a: *App) void {
    const bytes = a.workspace.readFileAlloc(a.io, "build.zig.zon", 256 * 1024) catch return;
    defer allocator.free(bytes);
    if (std.mem.indexOf(u8, bytes, ".minimum_zig_version")) |index| {
        const tail = bytes[index..@min(bytes.len, index + 256)];
        const quote = std.mem.indexOfScalar(u8, tail, '"') orelse return;
        const rest = tail[quote + 1 ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return;
        const version = rest[0..end];
        if (version.len == 0) return;
        var obj = std.json.ObjectMap.empty;
        obj.put(allocator, "tool", .{ .string = "zig" }) catch return;
        obj.put(allocator, "version", .{ .string = allocator.dupe(u8, version) catch return }) catch return;
        obj.put(allocator, "source", .{ .string = "build.zig.zon minimum_zig_version" }) catch return;
        obj.put(allocator, "path", .{ .string = "build.zig.zon" }) catch return;
        hints.append(.{ .object = obj }) catch return;
    }
}

/// Parses version prefix input using caller-provided storage; malformed input and allocation failures propagate.
fn parseVersionPrefix(value: []const u8) ?[2]u32 {
    var major: u32 = 0;
    var minor: u32 = 0;
    var seen_digit = false;
    var index: usize = 0;
    while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {
        seen_digit = true;
        major = major * 10 + value[index] - '0';
    }
    if (!seen_digit or index >= value.len or value[index] != '.') return null;
    index += 1;
    seen_digit = false;
    while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {
        seen_digit = true;
        minor = minor * 10 + value[index] - '0';
    }
    if (!seen_digit) return null;
    return .{ major, minor };
}

/// Serializes toolchain pins fields into an allocator-owned JSON value; allocation failures propagate.
fn toolchainPinsValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    const loaded = loadWorkspaceJson(a, allocator, toolchain_pin_path) catch |err| switch (err) {
        error.FileNotFound => return .null,
        else => return .null,
    };
    defer loaded.deinit(allocator);
    return support.cloneValue(allocator, loaded.value);
}

/// Implements probe version workflow logic using caller-owned inputs.
fn probeVersion(allocator: std.mem.Allocator, a: *App, argv: []const []const u8, timeout_ms: i64) ![]u8 {
    const result = try support.runCommand(allocator, a, argv, timeout_ms);
    defer result.deinit(allocator);
    if (!result.succeeded()) return error.ProbeFailed;
    const raw = if (result.stdout.len > 0) result.stdout else result.stderr;
    return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}

/// Classifies the Zig and ZLS versions as a match, warning, or unknown status.
fn compatibilityStatus(zig_version: ?[]const u8, zls_version: ?[]const u8) []const u8 {
    const zig = zig_version orelse return "unknown";
    const zls = zls_version orelse return "unknown";
    const zig_prefix = parseVersionPrefix(zig) orelse return "unknown";
    const zls_prefix = parseVersionPrefix(zls) orelse return "unknown";
    if (zig_prefix[0] == zls_prefix[0] and zig_prefix[1] == zls_prefix[1]) return "match";
    return "mismatch";
}

/// Serializes executable hash fields into an allocator-owned JSON value; allocation failures propagate.
fn executableHashValue(allocator: std.mem.Allocator, a: *App, path: []const u8) !std.json.Value {
    if (!std.fs.path.isAbsolute(path)) return .null;
    const bytes = a.workspace.readFileAlloc(a.io, path, 64 * 1024 * 1024) catch return .null;
    defer allocator.free(bytes);
    const hash = try artifacts.sha256Hex(allocator, bytes);
    defer allocator.free(hash);
    return .{ .string = hash };
}

/// Serializes trimmed output fields into an allocator-owned JSON value; allocation failures propagate.
fn trimmedOutputValue(allocator: std.mem.Allocator, result: command.RunResult) !std.json.Value {
    const raw = if (result.stdout.len > 0) result.stdout else result.stderr;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .null;
    return .{ .string = try allocator.dupe(u8, trimmed) };
}

/// Implements configured backend path workflow logic using caller-owned inputs.
fn configuredBackendPath(a: *App, name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "zig")) return a.config.zig_path;
    if (std.mem.eql(u8, name, "zls")) return a.config.zls_path;
    if (std.mem.eql(u8, name, "zlint")) return a.config.zlint_path;
    if (std.mem.eql(u8, name, "zwanzig")) return a.config.zwanzig_path;
    if (std.mem.eql(u8, name, "zflame")) return a.config.zflame_path;
    return a.config.diff_folded_path;
}

/// Normalizes backend name data into the representation consumed by this workflow.
fn normalizeBackendName(raw: []const u8) []const u8 {
    if (std.mem.eql(u8, raw, "diff-folded")) return "diff_folded";
    return raw;
}

/// Implements backend selected workflow logic using caller-owned inputs.
fn backendSelected(selected: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, selected, "all")) return true;
    if (std.mem.eql(u8, selected, name)) return true;
    if (std.mem.eql(u8, selected, "diff_folded") and std.mem.eql(u8, name, "diff-folded")) return true;
    if (std.mem.eql(u8, selected, "diff_folded") and std.mem.eql(u8, name, "diff_folded")) return true;
    return false;
}

/// Implements compare pin field workflow logic using caller-owned inputs.
fn comparePinField(allocator: std.mem.Allocator, mismatches: *std.json.Array, pin: std.json.Value, env: std.json.Value, pin_field: []const u8, env_path: []const u8) !void {
    const expected = nestedString(pin, pin_field, "version") orelse return;
    const actual = dottedString(env, env_path) orelse return;
    if (std.mem.eql(u8, expected, actual)) return;
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tool", .{ .string = pin_field });
    try obj.put(allocator, "expected", .{ .string = expected });
    try obj.put(allocator, "actual", .{ .string = actual });
    try mismatches.append(.{ .object = obj });
}

/// Implements nested string workflow logic using caller-owned inputs.
fn nestedString(value: std.json.Value, object_name: []const u8, field: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const child = value.object.get(object_name) orelse return null;
    if (child != .object) return null;
    const field_value = child.object.get(field) orelse return null;
    if (field_value != .string) return null;
    return field_value.string;
}

/// Implements dotted string workflow logic using caller-owned inputs.
fn dottedString(value: std.json.Value, path: []const u8) ?[]const u8 {
    var current = value;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| {
        if (current != .object) return null;
        current = current.object.get(part) orelse return null;
    }
    if (current != .string) return null;
    return current.string;
}

/// Implements object field workflow logic using caller-owned inputs.
fn objectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(field);
}

/// Serializes json values equal data into an allocator-owned JSON value; allocation failures propagate.
fn jsonValuesEqual(left: ?std.json.Value, right: ?std.json.Value) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.meta.eql(left.?, right.?);
}

/// Extracts json object string data from JSON input without taking ownership of borrowed values.
fn jsonObjectString(value: std.json.Value, key: []const u8) std.json.Value {
    if (value != .object) return .null;
    const field = value.object.get(key) orelse return .null;
    if (field != .string) return .null;
    return .{ .string = field.string };
}

/// Implements profile exists workflow logic using caller-owned inputs.
fn profileExists(a: *App) bool {
    return workspacePathExists(a, profile_path);
}

/// Reports whether the requested workspace path exists.
fn workspacePathExists(a: *App, path: []const u8) bool {
    return a.workspace.exists(a.allocator, path, false);
}

/// Serializes fact fields into an allocator-owned JSON value; allocation failures propagate.
fn factValue(allocator: std.mem.Allocator, key: []const u8, value: []const u8, source: []const u8, confidence: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "key", .{ .string = key });
    try obj.put(allocator, "value", .{ .string = value });
    try obj.put(allocator, "source", .{ .string = source });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    return .{ .object = obj };
}

/// Serializes question fields into an allocator-owned JSON value; allocation failures propagate.
fn questionValue(allocator: std.mem.Allocator, id: []const u8, prompt: []const u8, next_tool: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "id", .{ .string = id });
    try obj.put(allocator, "prompt", .{ .string = prompt });
    try obj.put(allocator, "required_for_determinism", .{ .bool = false });
    try obj.put(allocator, "next_tool", .{ .string = next_tool });
    return .{ .object = obj };
}

/// Serializes string array fields into an allocator-owned JSON value; allocation failures propagate.
fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

test "environment profile validation reports complete and incomplete shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var profile = std.json.ObjectMap.empty;
    try profile.put(allocator, "schema_version", .{ .integer = 2 });
    try profile.put(allocator, "toolchain", .{ .object = std.json.ObjectMap.empty });
    try profile.put(allocator, "source_sets", .{ .array = std.json.Array.init(allocator) });
    try profile.put(allocator, "generated_dirs", .{ .array = std.json.Array.init(allocator) });
    try profile.put(allocator, "targets", .{ .array = std.json.Array.init(allocator) });
    try profile.put(allocator, "tests", .{ .array = std.json.Array.init(allocator) });
    try profile.put(allocator, "backends", .{ .object = std.json.ObjectMap.empty });
    try profile.put(allocator, "verification", .{ .array = std.json.Array.init(allocator) });
    try profile.put(allocator, "unknowns", .{ .array = std.json.Array.init(allocator) });

    const valid = try validateProfileValue(allocator, .{ .object = profile });
    try std.testing.expect(valid.object.get("valid").?.bool);
    try std.testing.expectEqual(@as(i64, 0), valid.object.get("finding_count").?.integer);
    try std.testing.expectEqualStrings("high", valid.object.get("confidence").?.string);

    var incomplete = std.json.ObjectMap.empty;
    try incomplete.put(allocator, "schema_version", .{ .integer = 1 });
    const invalid = try validateProfileValue(allocator, .{ .object = incomplete });
    try std.testing.expect(!invalid.object.get("valid").?.bool);
    try std.testing.expect(invalid.object.get("findings").?.array.items.len >= 8);
    try std.testing.expectEqualStrings("profile_json_shape", invalid.object.get("evidence_source").?.string);
}

test "environment backend setup plans and conformance scenarios stay inert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const zig_plan = try backendInstallPlanValue(allocator, backend_catalog.backends[0], "zvm");
    try std.testing.expectEqualStrings("zig", zig_plan.object.get("backend").?.string);
    try std.testing.expect(!zig_plan.object.get("optional").?.bool);
    try std.testing.expectEqualStrings("zvm install 0.16.0", zig_plan.object.get("commands").?.array.items[0].string);
    try std.testing.expectEqualStrings("zvm use 0.16.0", zig_plan.object.get("commands").?.array.items[1].string);

    const zflame_plan = try backendInstallPlanValue(allocator, backend_catalog.backends[4], "manual");
    try std.testing.expectEqualStrings("zflame", zflame_plan.object.get("backend").?.string);
    try std.testing.expect(std.mem.indexOf(u8, zflame_plan.object.get("commands").?.array.items[0].string, "pin zflame") != null);

    const diff_scenarios = try conformanceScenariosValue(allocator, "diff_folded");
    try std.testing.expectEqual(@as(usize, 1), diff_scenarios.array.items.len);
    try std.testing.expectEqualStrings("diff_folded", diff_scenarios.array.items[0].object.get("backend").?.string);
    try std.testing.expectEqualStrings("diff_folded_recursive_svg_intermediate", diff_scenarios.array.items[0].object.get("name").?.string);

    const all_scenarios = try conformanceScenariosValue(allocator, "all");
    try std.testing.expectEqual(@as(usize, 10), all_scenarios.array.items.len);
}

test "environment zvm and dev environment helpers expose deterministic plans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const plan = try zvmPlanValue(allocator, "zigar_zvm_install_plan", "zvm", "0.16.0", &.{ "zvm", "install", "0.16.0" }, "install Zig");
    try std.testing.expectEqualStrings("zigar_zvm_install_plan", plan.object.get("kind").?.string);
    try std.testing.expectEqualStrings("zvm", plan.object.get("argv").?.array.items[0].string);
    try std.testing.expect(plan.object.get("plan_only").?.bool);
    try std.testing.expect(!plan.object.get("mutates_environment").?.bool);
    try std.testing.expect(plan.object.get("requires_user_execution").?.bool);
    try std.testing.expectEqual(@as(usize, 3), plan.object.get("verification").?.array.items.len);

    try std.testing.expectEqualStrings(".zigar-cache/dev-env/.tool-versions", defaultDevEnvOutput("asdf"));
    try std.testing.expectEqualStrings(".zigar-cache/dev-env/flake.nix", defaultDevEnvOutput("nix"));
    try std.testing.expectEqualStrings(".zigar-cache/dev-env/devcontainer.json", defaultDevEnvOutput("devcontainer"));
    try std.testing.expectEqualStrings(".zigar-cache/dev-env/github-actions.yml", defaultDevEnvOutput("github-actions"));
    try std.testing.expectEqualStrings(".zigar-cache/dev-env/mise.toml", defaultDevEnvOutput("mise"));
}

test "environment version and compatibility helpers classify release lines" {
    const parsed = parseVersionPrefix("0.16.0-dev") orelse return error.MissingExpectedCall;
    try std.testing.expectEqual(@as(u32, 0), parsed[0]);
    try std.testing.expectEqual(@as(u32, 16), parsed[1]);
    try std.testing.expect(parseVersionPrefix("dev-0.16") == null);
    try std.testing.expect(parseVersionPrefix("0.x") == null);

    try std.testing.expectEqualStrings("match", compatibilityStatus("0.16.0-dev", "0.16.1"));
    try std.testing.expectEqualStrings("mismatch", compatibilityStatus("0.15.0", "0.16.0"));
    try std.testing.expectEqualStrings("unknown", compatibilityStatus(null, "0.16.0"));
    try std.testing.expectEqualStrings("unknown", compatibilityStatus("dev", "0.16.0"));
    try std.testing.expectEqualStrings("diff_folded", normalizeBackendName("diff-folded"));
    try std.testing.expectEqualStrings("zls", normalizeBackendName("zls"));
    try std.testing.expect(backendSelected("all", "zflame"));
    try std.testing.expect(backendSelected("diff_folded", "diff-folded"));
    try std.testing.expect(backendSelected("diff_folded", "diff_folded"));
    try std.testing.expect(!backendSelected("zls", "zflame"));
}

test "environment JSON comparison helpers find nested pin mismatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var pin_zig = std.json.ObjectMap.empty;
    try pin_zig.put(allocator, "version", .{ .string = "0.16.0" });
    var pin = std.json.ObjectMap.empty;
    try pin.put(allocator, "zig", .{ .object = pin_zig });

    var toolchain = std.json.ObjectMap.empty;
    try toolchain.put(allocator, "zig_version", .{ .string = "0.15.0" });
    var env = std.json.ObjectMap.empty;
    try env.put(allocator, "toolchain", .{ .object = toolchain });

    var mismatches = std.json.Array.init(allocator);
    try comparePinField(allocator, &mismatches, .{ .object = pin }, .{ .object = env }, "zig", "toolchain.zig_version");
    try std.testing.expectEqual(@as(usize, 1), mismatches.items.len);
    try std.testing.expectEqualStrings("zig", mismatches.items[0].object.get("tool").?.string);
    try std.testing.expectEqualStrings("0.16.0", mismatches.items[0].object.get("expected").?.string);
    try std.testing.expectEqualStrings("0.15.0", mismatches.items[0].object.get("actual").?.string);

    try std.testing.expectEqualStrings("0.16.0", nestedString(.{ .object = pin }, "zig", "version").?);
    try std.testing.expectEqualStrings("0.15.0", dottedString(.{ .object = env }, "toolchain.zig_version").?);
    try std.testing.expect(nestedString(.null, "zig", "version") == null);
    try std.testing.expect(dottedString(.{ .object = env }, "toolchain.missing") == null);
    try std.testing.expect(jsonValuesEqual(null, null));
    try std.testing.expect(!jsonValuesEqual(null, .{ .string = "0.16.0" }));
    try std.testing.expect(jsonValuesEqual(.{ .string = "same" }, .{ .string = "same" }));
    try std.testing.expect(!jsonValuesEqual(.{ .string = "same" }, .{ .string = "other" }));
    try std.testing.expectEqualStrings("0.15.0", jsonObjectString(.{ .object = toolchain }, "zig_version").string);
    try std.testing.expect(jsonObjectString(.{ .object = toolchain }, "missing") == .null);
}

/// Carries test environment runtime data across use case and port boundaries.
const TestEnvironmentRuntime = struct {
    writes: usize = 0,
    command_runs: usize = 0,
    profile_exists: bool = true,
    source_dirs_exist: bool = true,
    write_error: ?ports.PortError = null,

    /// Returns a typed context backed by this fixture or runtime state.
    fn context(self: *TestEnvironmentRuntime) app_context.EnvironmentContext {
        return .{
            .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache", .transport = "test" },
            .tool_paths = .{
                .zig = "/bin/zig",
                .zls = "/bin/zls",
                .zlint = "/bin/zlint",
                .zwanzig = "/bin/zwanzig",
                .zflame = "/bin/zflame",
                .diff_folded = "/bin/diff-folded",
            },
            .timeouts = .{ .command_ms = 1000, .zls_ms = 1000 },
            .command_runner = self.commandPort(),
            .workspace_store = self.workspacePort(),
            .workspace_scanner = self.scannerPort(),
        };
    }

    /// Returns the fixture port table used by this test context.
    fn commandPort(self: *TestEnvironmentRuntime) ports.CommandRunner {
        return .{ .ptr = self, .vtable = &.{ .run = commandRun } };
    }

    /// Returns the fixture port table used by this test context.
    fn workspacePort(self: *TestEnvironmentRuntime) ports.WorkspaceStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .resolve = workspaceResolve,
                .read = workspaceRead,
                .write = workspaceWrite,
                .exists = workspaceExists,
            },
        };
    }

    /// Returns the fixture port table used by this test context.
    fn scannerPort(self: *TestEnvironmentRuntime) ports.WorkspaceScanner {
        return .{ .ptr = self, .vtable = &.{ .scan_zig_files = scanZigFiles } };
    }

    /// Invokes command run with caller-owned inputs; command and allocation failures propagate.
    fn commandRun(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.CommandRequest) ports.PortError!ports.CommandResult {
        const self: *TestEnvironmentRuntime = @ptrCast(@alignCast(ptr));
        self.command_runs += 1;
        const exe = if (request.argv.len > 0) request.argv[0] else "";
        if (std.mem.indexOf(u8, exe, "missing") != null) return error.FileNotFound;
        const stdout = if (std.mem.indexOf(u8, exe, "zig") != null and request.argv.len > 1 and std.mem.eql(u8, request.argv[1], "version"))
            "0.16.0\n"
        else if (std.mem.indexOf(u8, exe, "zls") != null)
            "0.16.1\n"
        else if (std.mem.indexOf(u8, exe, "zvm") != null and request.argv.len > 1 and std.mem.eql(u8, request.argv[1], "current"))
            "0.16.0\n"
        else if (std.mem.indexOf(u8, exe, "zvm") != null and request.argv.len > 1 and std.mem.eql(u8, request.argv[1], "ls"))
            "0.15.0\n0.16.0\n"
        else if (std.mem.indexOf(u8, exe, "zvm") != null and request.argv.len > 1 and std.mem.eql(u8, request.argv[1], "where"))
            "/opt/zig/0.16.0\n"
        else if (std.mem.indexOf(u8, exe, "zvm") != null)
            "zvm 1.0.0\n"
        else
            "backend help\n";
        return .{
            .exit_code = 0,
            .term = .{ .exited = 0 },
            .stdout = try allocator.dupe(u8, stdout),
            .stderr = try allocator.dupe(u8, ""),
            .duration_ms = 5,
            .owns_stdout = true,
            .owns_stderr = true,
        };
    }

    /// Resolves a workspace-relative fixture path.
    fn workspaceResolve(_: *anyopaque, allocator: std.mem.Allocator, request: ports.WorkspaceResolveRequest) ports.PortError!ports.WorkspaceResolveResult {
        if (request.path.len == 0) return error.EmptyPath;
        if (std.mem.indexOf(u8, request.path, "..") != null) return error.PathOutsideWorkspace;
        if (std.fs.path.isAbsolute(request.path)) return .{ .path = try allocator.dupe(u8, request.path), .owns_path = true };
        return .{ .path = try std.fmt.allocPrint(allocator, "/repo/{s}", .{request.path}), .owns_path = true };
    }

    /// Reads workspace fixture bytes for the requested path.
    fn workspaceRead(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
        const self: *TestEnvironmentRuntime = @ptrCast(@alignCast(ptr));
        if (std.mem.indexOf(u8, request.path, "..") != null) return error.PathOutsideWorkspace;
        if (std.mem.eql(u8, request.path, ".zigar/denied.json")) return error.AccessDenied;
        if (!self.profile_exists and std.mem.eql(u8, request.path, ".zigar/profile.json")) return error.FileNotFound;
        const bytes =
            if (std.mem.eql(u8, request.path, "build.zig"))
                "const std = @import(\"std\"); pub fn build(_: *std.Build) void {}\n"
            else if (std.mem.eql(u8, request.path, "build.zig.zon"))
                ".{ .name = .fixture, .minimum_zig_version = \"0.16.0\" }\n"
            else if (std.mem.eql(u8, request.path, ".zigversion"))
                "0.16.0\n"
            else if (std.mem.eql(u8, request.path, ".tool-versions"))
                "zig 0.16.0\nzls 0.16.0\nnode 24\n"
            else if (std.mem.eql(u8, request.path, "mise.toml"))
                "zig = \"0.16.0\"\n"
            else if (std.mem.eql(u8, request.path, ".zigar/profile.json"))
                completeProfileJson()
            else if (std.mem.eql(u8, request.path, ".zigar/bad.json"))
                "{bad"
            else if (std.mem.eql(u8, request.path, ".zigar/toolchain.json"))
                "{\"schema_version\":1,\"zig\":{\"version\":\"0.16.0\"},\"zls\":{\"version\":\"0.16.0\"}}\n"
            else if (std.mem.eql(u8, request.path, ".zigar-cache/backend-conformance/report.json"))
                "{\"kind\":\"backend_conformance_report\",\"result\":\"pass\",\"source_commit\":\"abc123\"}\n"
            else if (std.mem.startsWith(u8, request.path, "/bin/"))
                "fake executable bytes"
            else
                return error.FileNotFound;
        return .{ .bytes = try allocator.dupe(u8, bytes), .owns_bytes = true };
    }

    /// Stores workspace fixture bytes for the requested path.
    fn workspaceWrite(ptr: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
        const self: *TestEnvironmentRuntime = @ptrCast(@alignCast(ptr));
        if (self.write_error) |err| return err;
        if (std.mem.indexOf(u8, request.path, "..") != null) return error.PathOutsideWorkspace;
        self.writes += 1;
        return .{ .bytes_written = request.bytes.len, .replaced_existing = false };
    }

    /// Reports whether the requested workspace path exists.
    fn workspaceExists(ptr: *anyopaque, _: std.mem.Allocator, request: ports.WorkspaceExistsRequest) ports.PortError!ports.WorkspaceExistsResult {
        const self: *TestEnvironmentRuntime = @ptrCast(@alignCast(ptr));
        const is_dir = self.source_dirs_exist and (std.mem.eql(u8, request.path, "src") or
            std.mem.eql(u8, request.path, "lib") or
            std.mem.eql(u8, request.path, "test") or
            std.mem.eql(u8, request.path, "tests"));
        const exists = is_dir or
            std.mem.eql(u8, request.path, "build.zig") or
            std.mem.eql(u8, request.path, "build.zig.zon") or
            std.mem.eql(u8, request.path, ".zigversion") or
            std.mem.eql(u8, request.path, ".tool-versions") or
            std.mem.eql(u8, request.path, "mise.toml") or
            (self.profile_exists and std.mem.eql(u8, request.path, ".zigar/profile.json"));
        return .{ .exists = exists, .kind = if (is_dir) .directory else .file };
    }

    /// Scans fixture workspace entries and returns matching paths.
    fn scanZigFiles(_: *anyopaque, allocator: std.mem.Allocator, _: ports.WorkspaceScanRequest) ports.PortError!ports.WorkspaceScanResult {
        const files = try allocator.alloc(ports.WorkspaceScanFile, 1);
        files[0] = .{ .path = try allocator.dupe(u8, "src/main.zig") };
        return .{ .files = files, .owns_memory = true };
    }
};

/// Implements complete profile json workflow logic using caller-owned inputs.
fn completeProfileJson() []const u8 {
    return
    \\{
    \\  "schema_version": 2,
    \\  "toolchain": {},
    \\  "source_sets": [],
    \\  "generated_dirs": [],
    \\  "targets": [],
    \\  "tests": {},
    \\  "backends": {},
    \\  "verification": [],
    \\  "unknowns": []
    \\}
    ;
}

/// Parses args input using caller-provided storage; malformed input and allocation failures propagate.
fn parseArgs(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, text, .{});
}

/// Implements sweep usecase allocation failures workflow logic using caller-owned inputs.
fn sweepUsecaseAllocationFailures(comptime call: anytype, args: ?std.json.Value) void {
    for (0..32) |fail_index| {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        var runtime = TestEnvironmentRuntime{};
        var app = App.init(runtime.context(), failing.allocator());
        _ = call(&app, failing.allocator(), args) catch {};
        backing.deinit();
    }
}

test "environment workflow use cases exercise profile lifecycle and elicitation through ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime = TestEnvironmentRuntime{};
    var app = App.init(runtime.context(), allocator);

    const setup = try zigarSetupElicit(&app, allocator, null);
    try std.testing.expectEqualStrings("zigar_setup_elicit", setup.value.object.get("kind").?.string);
    try std.testing.expect(setup.value.object.get("questions").?.array.items.len >= 2);

    const profile_elicit = try zigarProfileElicit(&app, allocator, null);
    try std.testing.expectEqualStrings("zigar_profile_elicit", profile_elicit.value.object.get("kind").?.string);

    var sparse_runtime = TestEnvironmentRuntime{ .profile_exists = false, .source_dirs_exist = false };
    var sparse_app = App.init(sparse_runtime.context(), allocator);
    const sparse_elicit = try zigarProfileElicit(&sparse_app, allocator, null);
    try std.testing.expect(sparse_elicit.value.object.get("unknowns").?.array.items.len > 0);
    const sparse_bootstrap = try zigarProfileBootstrap(&sparse_app, allocator, null);
    try std.testing.expectEqualStrings("build.zig", sparse_bootstrap.value.object.get("profile").?.object.get("source_sets").?.array.items[0].object.get("path").?.string);

    var backend_args = try parseArgs(allocator, "{\"topic\":\"backend\"}");
    defer backend_args.deinit();
    const backend = try zigarBackendElicit(&app, allocator, backend_args.value);
    try std.testing.expectEqualStrings("backend", backend.value.object.get("topic").?.string);

    const profile = try zigarProjectProfileV2(&app, allocator, null);
    try std.testing.expectEqual(@as(i64, 2), profile.value.object.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("0.16.0", profile.value.object.get("profile").?.object.get("toolchain").?.object.get("expected_zig_version").?.string);

    var invalid_profile_args = try parseArgs(allocator, "{\"content\":\"{bad\"}");
    defer invalid_profile_args.deinit();
    const invalid_profile = try zigarProjectProfileV2(&app, allocator, invalid_profile_args.value);
    try std.testing.expect(invalid_profile.is_error);

    var apply_args = try parseArgs(allocator, "{\"apply\":true}");
    defer apply_args.deinit();
    const generated = try generatedProfileV2Value(allocator, &app);
    const write = try profileWriteResult(&app, allocator, apply_args.value, "zigar_project_profile_v2", generated);
    try std.testing.expect(write.value.object.get("applied").?.bool);

    var valid_import_args = try parseArgs(allocator, "{\"content\":\"{\\\"schema_version\\\":2,\\\"toolchain\\\":{},\\\"source_sets\\\":[],\\\"generated_dirs\\\":[],\\\"targets\\\":[],\\\"tests\\\":{},\\\"backends\\\":{},\\\"verification\\\":[],\\\"unknowns\\\":[]}\"}");
    defer valid_import_args.deinit();
    const imported = try zigarProfileImport(&app, allocator, valid_import_args.value);
    try std.testing.expect(!imported.value.object.get("applied").?.bool);

    var missing_import_args = try parseArgs(allocator, "{}");
    defer missing_import_args.deinit();
    const missing_import = try zigarProfileImport(&app, allocator, missing_import_args.value);
    try std.testing.expect(missing_import.is_error);

    var array_content_args = try parseArgs(allocator, "{\"content\":\"[]\"}");
    defer array_content_args.deinit();
    const validate_array = try zigarProfileValidate(&app, allocator, array_content_args.value);
    try std.testing.expect(!validate_array.value.object.get("validation").?.object.get("valid").?.bool);

    const read_profile = try zigarProfileRead(&app, allocator, null);
    try std.testing.expect(read_profile.value.object.get("exists").?.bool);

    var bad_read_args = try parseArgs(allocator, "{\"path\":\".zigar/bad.json\"}");
    defer bad_read_args.deinit();
    const bad_validation = try zigarProfileValidate(&app, allocator, bad_read_args.value);
    try std.testing.expect(bad_validation.is_error);

    var missing_read_args = try parseArgs(allocator, "{\"path\":\".zigar/missing.json\"}");
    defer missing_read_args.deinit();
    const missing_validation = try zigarProfileValidate(&app, allocator, missing_read_args.value);
    try std.testing.expect(!missing_validation.value.object.get("validation").?.object.get("valid").?.bool);
    const missing_profile = try zigarProfileRead(&sparse_app, allocator, null);
    try std.testing.expect(!missing_profile.value.object.get("exists").?.bool);

    var outside_args = try parseArgs(allocator, "{\"path\":\"../profile.json\"}");
    defer outside_args.deinit();
    const outside_validation = try zigarProfileValidate(&app, allocator, outside_args.value);
    try std.testing.expect(outside_validation.is_error);
    var denied_args = try parseArgs(allocator, "{\"path\":\".zigar/denied.json\"}");
    defer denied_args.deinit();
    const denied_validation = try zigarProfileValidate(&app, allocator, denied_args.value);
    try std.testing.expect(denied_validation.is_error);

    var invalid_diff_args = try parseArgs(allocator, "{\"content\":\"{bad\"}");
    defer invalid_diff_args.deinit();
    const invalid_diff = try zigarProfileDiff(&app, allocator, invalid_diff_args.value);
    try std.testing.expect(invalid_diff.is_error);

    var failed_write_runtime = TestEnvironmentRuntime{ .write_error = error.AccessDenied };
    var failed_write_app = App.init(failed_write_runtime.context(), allocator);
    const failed_write_profile = try generatedProfileV2Value(allocator, &failed_write_app);
    const failed_write = try profileWriteResult(&failed_write_app, allocator, apply_args.value, "zigar_project_profile_v2", failed_write_profile);
    try std.testing.expect(failed_write.is_error);

    var oom_write_runtime = TestEnvironmentRuntime{ .write_error = error.OutOfMemory };
    var oom_write_app = App.init(oom_write_runtime.context(), allocator);
    const oom_write_profile = try generatedProfileV2Value(allocator, &oom_write_app);
    try std.testing.expectError(error.OutOfMemory, profileWriteResult(&oom_write_app, allocator, apply_args.value, "zigar_project_profile_v2", oom_write_profile));

    const bootstrap = try zigarProfileBootstrap(&app, allocator, null);
    try std.testing.expectEqualStrings("zigar_profile_bootstrap", bootstrap.value.object.get("kind").?.string);

    const diff = try zigarProfileDiff(&app, allocator, null);
    try std.testing.expect(diff.value.object.get("current_exists").?.bool);
}

test "environment workflow use cases exercise environment packs, pins, backends, and artifacts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime = TestEnvironmentRuntime{};
    var app = App.init(runtime.context(), allocator);

    var probe_args = try parseArgs(allocator, "{\"probe_backends\":true,\"include_hashes\":true,\"timeout_ms\":50}");
    defer probe_args.deinit();
    const pack = try zigarEnvPack(&app, allocator, probe_args.value);
    try std.testing.expectEqualStrings("zigar_env_pack", pack.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("available", pack.value.object.get("toolchain").?.object.get("zig").?.object.get("status").?.string);

    var export_args = try parseArgs(allocator, "{\"apply\":true,\"probe_backends\":false,\"include_hashes\":false}");
    defer export_args.deinit();
    const exported = try zigarEnvExport(&app, allocator, export_args.value);
    try std.testing.expect(exported.value.object.get("applied").?.bool);

    var zvm_args = try parseArgs(allocator, "{\"zvm_path\":\"/bin/zvm\",\"timeout_ms\":50}");
    defer zvm_args.deinit();
    const zvm = try zigarZvmProbe(&app, allocator, zvm_args.value);
    try std.testing.expect(zvm.value.object.get("available").?.bool);
    try std.testing.expectEqual(@as(usize, 4), zvm.value.object.get("commands").?.array.items.len);

    var zvm_install_args = try parseArgs(allocator, "{\"version\":\"0.16.0\",\"zvm_path\":\"zvm\"}");
    defer zvm_install_args.deinit();
    const install = try zigarZvmInstallPlan(&app, allocator, zvm_install_args.value);
    try std.testing.expect(install.value.object.get("plan_only").?.bool);
    const switch_plan = try zigarZvmSwitchPlan(&app, allocator, zvm_install_args.value);
    try std.testing.expectEqualStrings("select requested Zig version", switch_plan.value.object.get("description").?.string);

    const zls_match = try zigZlsMatchCheck(&app, allocator, probe_args.value);
    try std.testing.expect(zls_match.value.object.get("match").?.bool);

    var pin_args = try parseArgs(allocator, "{\"apply\":true,\"zig_version\":\"0.16.0\",\"zls_version\":\"0.16.0\"}");
    defer pin_args.deinit();
    const pin = try zigToolchainPin(&app, allocator, pin_args.value);
    try std.testing.expect(pin.value.object.get("applied").?.bool);

    const pin_check = try zigToolchainPinCheck(&app, allocator, null);
    try std.testing.expectEqualStrings("zig_toolchain_pin_check", pin_check.value.object.get("kind").?.string);

    var missing_pin_args = try parseArgs(allocator, "{\"input\":\".zigar/missing-toolchain.json\"}");
    defer missing_pin_args.deinit();
    const missing_pin = try zigToolchainPinCheck(&app, allocator, missing_pin_args.value);
    try std.testing.expect(!missing_pin.value.object.get("ok").?.bool);

    var backend_plan_args = try parseArgs(allocator, "{\"backend\":\"zig\",\"manager\":\"mise\"}");
    defer backend_plan_args.deinit();
    const backend_plan = try zigarBackendInstallPlan(&app, allocator, backend_plan_args.value);
    try std.testing.expectEqual(@as(usize, 1), backend_plan.value.object.get("plans").?.array.items.len);

    var backend_verify_args = try parseArgs(allocator, "{\"backend\":\"zls\",\"timeout_ms\":50}");
    defer backend_verify_args.deinit();
    const verify = try zigarBackendVerify(&app, allocator, backend_verify_args.value);
    try std.testing.expectEqualStrings("zls", verify.value.object.get("backend").?.string);

    var missing_backend_context = runtime.context();
    missing_backend_context.tool_paths.zlint = "/bin/missing-zlint";
    var missing_backend_app = App.init(missing_backend_context, allocator);
    var missing_backend_args = try parseArgs(allocator, "{\"backend\":\"zlint\",\"timeout_ms\":50}");
    defer missing_backend_args.deinit();
    const missing_backend = try zigarBackendVerify(&missing_backend_app, allocator, missing_backend_args.value);
    const missing_backend_result = missing_backend.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("not_found", missing_backend_result.get("status").?.string);

    const conformance = try zigarBackendConformance(&app, allocator, probe_args.value);
    try std.testing.expectEqualStrings("probe_matrix", conformance.value.object.get("run_state").?.string);

    var evidence_args = try parseArgs(allocator, "{\"apply\":true}");
    defer evidence_args.deinit();
    const evidence = try zigarBackendEvidencePack(&app, allocator, evidence_args.value);
    try std.testing.expect(evidence.value.object.get("applied").?.bool);

    var missing_evidence_args = try parseArgs(allocator, "{\"input\":\".zigar-cache/backend-conformance/missing.json\"}");
    defer missing_evidence_args.deinit();
    const missing_evidence = try zigarBackendEvidencePack(&app, allocator, missing_evidence_args.value);
    try std.testing.expect(!missing_evidence.value.object.get("evidence").?.object.get("available").?.bool);

    var bad_output_args = try parseArgs(allocator, "{\"apply\":true,\"output\":\"../bad.json\"}");
    defer bad_output_args.deinit();
    const bad_export = try zigarEnvExport(&app, allocator, bad_output_args.value);
    try std.testing.expect(bad_export.is_error);

    inline for (.{ "asdf", "nix", "devcontainer", "github-actions", "mise" }) |kind| {
        const args_text = try std.fmt.allocPrint(allocator, "{{\"kind\":\"{s}\",\"apply\":false}}", .{kind});
        var args = try parseArgs(allocator, args_text);
        defer args.deinit();
        const generated = try zigarDevEnvGenerate(&app, allocator, args.value);
        try std.testing.expectEqualStrings(kind, generated.value.object.get("artifact_kind").?.string);
    }

    const scan = try app.context.workspace_scanner.scanZigFiles(allocator, .{});
    defer scan.deinit(allocator);
    try std.testing.expectEqualStrings("src/main.zig", scan.files[0].path);

    try std.testing.expect(runtime.writes >= 3);
    try std.testing.expect(runtime.command_runs >= 8);
}

test "environment workflow values clean up partially allocated JSON on failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var zvm_args = try parseArgs(allocator, "{\"zvm_path\":\"/bin/zvm\",\"timeout_ms\":50}");
    defer zvm_args.deinit();
    var backend_args = try parseArgs(allocator, "{\"backend\":\"zls\",\"timeout_ms\":50}");
    defer backend_args.deinit();
    var dev_env_args = try parseArgs(allocator, "{\"kind\":\"github-actions\"}");
    defer dev_env_args.deinit();

    sweepUsecaseAllocationFailures(zigarSetupElicit, null);
    sweepUsecaseAllocationFailures(zigarProfileElicit, null);
    sweepUsecaseAllocationFailures(zigarProjectProfileV2, null);
    sweepUsecaseAllocationFailures(zigarProfileValidate, null);
    sweepUsecaseAllocationFailures(zigarProfileRead, null);
    sweepUsecaseAllocationFailures(zigarProfileBootstrap, null);
    sweepUsecaseAllocationFailures(zigarProfileDiff, null);
    sweepUsecaseAllocationFailures(zigarEnvPack, null);
    sweepUsecaseAllocationFailures(zigarEnvExport, null);
    sweepUsecaseAllocationFailures(zigarZvmProbe, zvm_args.value);
    sweepUsecaseAllocationFailures(zigZlsMatchCheck, backend_args.value);
    sweepUsecaseAllocationFailures(zigToolchainPin, null);
    sweepUsecaseAllocationFailures(zigToolchainPinCheck, null);
    sweepUsecaseAllocationFailures(zigarBackendInstallPlan, backend_args.value);
    sweepUsecaseAllocationFailures(zigarBackendVerify, backend_args.value);
    sweepUsecaseAllocationFailures(zigarDevEnvGenerate, dev_env_args.value);
    sweepUsecaseAllocationFailures(zigarBackendConformance, backend_args.value);
    sweepUsecaseAllocationFailures(zigarBackendEvidencePack, null);

    for (0..8) |fail_index| {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        _ = stringArrayValue(failing.allocator(), &.{ "a", "b" }) catch {};
        backing.deinit();
    }
}
