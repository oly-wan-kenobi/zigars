const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const common = @import("common.zig");
const discovery = @import("discovery.zig");
const agent_values = @import("agent_values.zig");
const static_analysis = @import("static_analysis.zig");

const App = common.App;
const artifacts = zigar.artifacts;
const backend_catalog = zigar.backend_catalog;
const backend_contracts = zigar.backend_contracts;
const command = zigar.command;
const json_result = zigar.json_result;

const argBool = common.argBool;
const argInt = common.argInt;
const argString = common.argString;
const backendErrorResult = common.backendErrorResult;
const commandResultValue = common.commandResultValue;
const invalidArgumentResult = common.invalidArgumentResult;
const missingArgumentResult = common.missingArgumentResult;
const ownedString = common.ownedString;
const structured = common.structured;
const toolErrorFromError = common.toolErrorFromError;
const toolTimeout = common.toolTimeout;
const workspacePathErrorResult = common.workspacePathErrorResult;

const profile_path = ".zigar/profile.json";
const toolchain_pin_path = ".zigar/toolchain.json";
const env_pack_path = ".zigar-cache/env/pack.json";
const backend_evidence_path = ".zigar-cache/backend-conformance/evidence-pack.json";
const backend_report_path = ".zigar-cache/backend-conformance/report.json";

pub fn zigarSetupElicit(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return elicitationResult(a, allocator, args, "zigar_setup_elicit", "setup");
}

pub fn zigarProfileElicit(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return elicitationResult(a, allocator, args, "zigar_profile_elicit", "profile");
}

pub fn zigarBackendElicit(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return elicitationResult(a, allocator, args, "zigar_backend_elicit", "backend");
}

fn elicitationResult(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, default_topic: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
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
        try questions.append(try questionValue(allocator, "optional_backends", "Which optional backends should be claimed as supported for this project: zls, zwanzig, zflame, diff-folded, or none?", "zigar_backend_verify and zigar_backend_conformance"));
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
    try obj.put(allocator, "next_tools", try stringArrayValue(allocator, &.{ "zigar_profile_bootstrap", "zig_zls_match_check", "zigar_backend_verify", "zigar_env_pack" }));
    try obj.put(allocator, "workflow_contract", try agent_values.workflowContractValue(allocator, "workspace/profile/backend catalog inspection", "setup questions for unresolved policy only", "medium", "questions do not imply validation passed; skipped checks remain explicit", "run the named next_tools before release decisions", "stop when unknowns are answered or deterministic defaults are acceptable", &.{ "zigar_profile_bootstrap", "zigar_profile_import" }));
    return structured(allocator, .{ .object = obj });
}

pub fn zigarProjectProfileV2(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const profile = if (argString(args, "content")) |content|
        parseJsonContent(allocator, "zigar_project_profile_v2", "content", content) catch |err| return parseContentError(allocator, "zigar_project_profile_v2", content, err)
    else
        try generatedProfileV2Value(allocator, a);
    return profileWriteResult(a, allocator, args, "zigar_project_profile_v2", profile);
}

pub fn zigarProfileValidate(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
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

pub fn zigarProfileRead(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = argString(args, "path") orelse profile_path;
    const resolved = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zigar_profile_read", path, err);
    defer a.workspace.allocator.free(resolved);
    const bytes = std.Io.Dir.cwd().readFileAlloc(a.io, resolved, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
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
    try obj.put(allocator, "profile", json_result.cloneValue(allocator, parsed.value) catch return error.OutOfMemory);
    try obj.put(allocator, "validation", validation);
    return structured(allocator, .{ .object = obj });
}

pub fn zigarProfileBootstrap(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
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

pub fn zigarProfileImport(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const content = argString(args, "content") orelse return missingArgumentResult(allocator, "zigar_profile_import", "content", "profile v2 JSON content");
    const profile = parseJsonContent(allocator, "zigar_profile_import", "content", content) catch |err| return parseContentError(allocator, "zigar_profile_import", content, err);
    return profileWriteResult(a, allocator, args, "zigar_profile_import", profile);
}

pub fn zigarProfileDiff(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = argString(args, "path") orelse profile_path;
    const current = loadWorkspaceJson(a, allocator, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return jsonLoadErrorResult(a, allocator, "zigar_profile_diff", path, e),
    };
    defer if (current) |*loaded| loaded.deinit(allocator);
    const candidate = if (argString(args, "content")) |content|
        loadContentValue(allocator, "zigar_profile_diff", content) catch |err| return parseContentError(allocator, "zigar_profile_diff", content, err)
    else
        LoadedJson{ .value = try generatedProfileV2Value(allocator, a), .owned = true };
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

fn profileWriteResult(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, profile: std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const apply = argBool(args, "apply", false);
    const validation = try validateProfileValue(allocator, profile);
    const valid = validation.object.get("valid").?.bool;
    const preimage = try preimageIdentityForPath(a, allocator, profile_path);
    var serialized: std.ArrayList(u8) = .empty;
    defer serialized.deinit(allocator);
    try json_result.serializeValue(allocator, &serialized, profile);
    if (apply) {
        if (!valid) return invalidArgumentResult(allocator, tool_name, "content", "valid profile v2 JSON", "invalid_profile", "Fix validation.findings before applying the profile.");
        a.workspace.writeFile(a.io, profile_path, serialized.items) catch |err| switch (err) {
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

pub fn zigarEnvPack(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, try envPackValue(allocator, a, args));
}

pub fn zigarEnvExport(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const output = argString(args, "output") orelse env_pack_path;
    const apply = argBool(args, "apply", false);
    const pack = try envPackValue(allocator, a, args);
    var serialized: std.ArrayList(u8) = .empty;
    defer serialized.deinit(allocator);
    try json_result.serializeValue(allocator, &serialized, pack);
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

pub fn zigarZvmProbe(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
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
        const result = command.run(allocator, a.io, a.workspace.root, probe.argv, timeout_ms) catch |err| {
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

pub fn zigarZvmInstallPlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const version = argString(args, "version") orelse return missingArgumentResult(allocator, "zigar_zvm_install_plan", "version", "Zig version to install");
    const zvm_path = argString(args, "zvm_path") orelse "zvm";
    return structured(allocator, try zvmPlanValue(allocator, "zigar_zvm_install_plan", zvm_path, version, &.{ zvm_path, "install", version }, "install requested Zig version"));
}

pub fn zigarZvmSwitchPlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const version = argString(args, "version") orelse return missingArgumentResult(allocator, "zigar_zvm_switch_plan", "version", "Zig version to select");
    const zvm_path = argString(args, "zvm_path") orelse "zvm";
    return structured(allocator, try zvmPlanValue(allocator, "zigar_zvm_switch_plan", zvm_path, version, &.{ zvm_path, "use", version }, "select requested Zig version"));
}

pub fn zigZlsMatchCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, try compatibilityValueWithKind(allocator, a, args, "zig_zls_match_check"));
}

pub fn zigToolchainPin(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const output = argString(args, "output") orelse toolchain_pin_path;
    const apply = argBool(args, "apply", false);
    const pin = try explicitPinValue(allocator, a, args);
    var serialized: std.ArrayList(u8) = .empty;
    defer serialized.deinit(allocator);
    try json_result.serializeValue(allocator, &serialized, pin);
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

pub fn zigToolchainPinCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
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
    try obj.put(allocator, "pin", json_result.cloneValue(allocator, loaded.value) catch return error.OutOfMemory);
    try obj.put(allocator, "environment", env);
    return structured(allocator, .{ .object = obj });
}

pub fn zigarBackendInstallPlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
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

pub fn zigarBackendVerify(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
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

pub fn zigarDevEnvGenerate(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
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

pub fn zigarBackendConformance(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
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

pub fn zigarBackendEvidencePack(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const input = argString(args, "input") orelse backend_report_path;
    const output = argString(args, "output") orelse backend_evidence_path;
    const apply = argBool(args, "apply", false);
    const evidence = try backendEvidencePackValue(a, allocator, input);
    var serialized: std.ArrayList(u8) = .empty;
    defer serialized.deinit(allocator);
    try json_result.serializeValue(allocator, &serialized, evidence);
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

fn generatedProfileV2Value(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = 2 });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "generated_by", .{ .string = "zigar_project_profile_v2" });
    try obj.put(allocator, "project_type", try agent_values.projectTypeValue(allocator, a));
    try obj.put(allocator, "toolchain", try profileToolchainValue(allocator, a));
    try obj.put(allocator, "source_sets", try sourceSetsValue(allocator, a));
    try obj.put(allocator, "generated_dirs", try agent_values.generatedDirsValue(allocator));
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

fn commandPolicyValue(allocator: std.mem.Allocator, name: []const u8, command_text: []const u8, evidence: []const u8, confidence: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "command", .{ .string = command_text });
    try obj.put(allocator, "evidence", .{ .string = evidence });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    return .{ .object = obj };
}

fn targetsValue(allocator: std.mem.Allocator) !std.json.Value {
    return stringArrayValue(allocator, &.{"native"});
}

fn benchmarksValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "commands", try stringArrayValue(allocator, &.{}));
    try obj.put(allocator, "policy", .{ .string = "unconfigured" });
    return .{ .object = obj };
}

fn publicApiPolicyValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "change_check", .{ .string = "zig_public_api_diff" });
    try obj.put(allocator, "confidence", .{ .string = "advisory" });
    return .{ .object = obj };
}

fn ciPolicyValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "matrix", try stringArrayValue(allocator, &.{"native"}));
    try obj.put(allocator, "artifact_tools", try stringArrayValue(allocator, &.{ "zig_ci_annotations", "zig_junit", "zig_matrix_check" }));
    return .{ .object = obj };
}

fn lintPolicyValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "formatter", .{ .string = "zig_format_check" });
    try obj.put(allocator, "optional_backend", .{ .string = "zwanzig" });
    try obj.put(allocator, "required", .{ .bool = false });
    return .{ .object = obj };
}

fn perfBudgetsValue(allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "configured", .{ .bool = false });
    try obj.put(allocator, "evidence_tool", .{ .string = "zig_profile_plan" });
    return .{ .object = obj };
}

fn profileBackendsValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig", try profileBackendValue(allocator, "zig", false, a.config.zig_path));
    try obj.put(allocator, "zls", try profileBackendValue(allocator, "zls", true, a.config.zls_path));
    try obj.put(allocator, "zwanzig", try profileBackendValue(allocator, "zwanzig", true, a.config.zwanzig_path));
    try obj.put(allocator, "zflame", try profileBackendValue(allocator, "zflame", true, a.config.zflame_path));
    try obj.put(allocator, "diff_folded", try profileBackendValue(allocator, "diff-folded", true, a.config.diff_folded_path));
    return .{ .object = obj };
}

fn profileBackendValue(allocator: std.mem.Allocator, name: []const u8, optional: bool, path: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "optional", .{ .bool = optional });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "required_for_release_claims", .{ .bool = !optional });
    return .{ .object = obj };
}

fn profileUnknownsValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var unknowns = std.json.Array.init(allocator);
    if (!workspacePathExists(a, ".zigversion") and !workspacePathExists(a, ".tool-versions") and !workspacePathExists(a, "mise.toml")) {
        try unknowns.append(try unknownValue(allocator, "toolchain_pin", "no explicit Zig/ZLS pin file was detected", "zig_toolchain_pin"));
    }
    try unknowns.append(try unknownValue(allocator, "release_backend_claims", "optional backend support claims require project policy", "zigar_backend_conformance"));
    try unknowns.append(try unknownValue(allocator, "performance_budgets", "performance budgets are not inferred from source layout", "zig_profile_plan"));
    return .{ .array = unknowns };
}

fn unknownValue(allocator: std.mem.Allocator, key: []const u8, reason: []const u8, verification: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "key", .{ .string = key });
    try obj.put(allocator, "reason", .{ .string = reason });
    try obj.put(allocator, "verification", .{ .string = verification });
    return .{ .object = obj };
}

fn detectedFactsValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var facts = std.json.Array.init(allocator);
    if (workspacePathExists(a, "build.zig")) try facts.append(try factValue(allocator, "build_file", "build.zig", "workspace_file", "high"));
    if (workspacePathExists(a, "build.zig.zon")) try facts.append(try factValue(allocator, "package_file", "build.zig.zon", "workspace_file", "high"));
    if (workspacePathExists(a, "src")) try facts.append(try factValue(allocator, "source_root", "src", "workspace_directory", "high"));
    return .{ .array = facts };
}

fn inferredPolicyValue(allocator: std.mem.Allocator) !std.json.Value {
    var policies = std.json.Array.init(allocator);
    try policies.append(try factValue(allocator, "default_validation", "zigar_validate_patch", "zigar_policy", "medium"));
    try policies.append(try factValue(allocator, "generated_dirs", ".zig-cache,.zigar-cache,zig-out,coverage", "zigar_policy", "high"));
    return .{ .array = policies };
}

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

fn toolchainStateValue(allocator: std.mem.Allocator, a: *App, probe: bool, include_hashes: bool, timeout_ms: i64) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig", try executableStateValue(allocator, a, "zig", a.config.zig_path, &.{ a.config.zig_path, "version" }, probe, include_hashes, timeout_ms));
    try obj.put(allocator, "zls", try executableStateValue(allocator, a, "zls", a.config.zls_path, &.{ a.config.zls_path, "--version" }, probe, include_hashes, timeout_ms));
    return .{ .object = obj };
}

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

fn executableStateValue(allocator: std.mem.Allocator, a: *App, name: []const u8, path: []const u8, argv: []const []const u8, probe: bool, include_hashes: bool, timeout_ms: i64) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "probe_argv", try common.argvValue(allocator, argv));
    if (include_hashes) {
        try obj.put(allocator, "sha256", try executableHashValue(allocator, a, path));
    } else {
        try obj.put(allocator, "sha256", .null);
    }
    if (probe) {
        const result = command.run(allocator, a.io, a.workspace.root, argv, timeout_ms) catch |err| {
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

fn compatibilityValue(allocator: std.mem.Allocator, a: *App, probe: bool, timeout_ms: i64) !std.json.Value {
    return compatibilityValueWithProbe(allocator, a, probe, timeout_ms, "zig_zls_compatibility");
}

fn compatibilityValueWithKind(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value, kind: []const u8) !std.json.Value {
    return compatibilityValueWithProbe(allocator, a, argBool(args, "probe_backends", true), toolTimeout(a, args), kind);
}

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

fn explicitPinValue(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = 1 });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "zig", try pinEntryValue(allocator, "zig", a.config.zig_path, argString(args, "zig_version")));
    try obj.put(allocator, "zls", try pinEntryValue(allocator, "zls", a.config.zls_path, argString(args, "zls_version")));
    try obj.put(allocator, "zwanzig", try pinEntryValue(allocator, "zwanzig", a.config.zwanzig_path, argString(args, "zwanzig_version")));
    try obj.put(allocator, "zflame", try pinEntryValue(allocator, "zflame", a.config.zflame_path, argString(args, "zflame_version")));
    try obj.put(allocator, "diff_folded", try pinEntryValue(allocator, "diff-folded", a.config.diff_folded_path, argString(args, "diff_folded_version")));
    try obj.put(allocator, "verification", try stringArrayValue(allocator, &.{ "zig_toolchain_pin_check", "zig_zls_match_check", "zigar_backend_verify" }));
    return .{ .object = obj };
}

fn pinEntryValue(allocator: std.mem.Allocator, name: []const u8, path: []const u8, version: ?[]const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "path", .{ .string = path });
    if (version) |value| try obj.put(allocator, "version", .{ .string = value }) else try obj.put(allocator, "version", .null);
    try obj.put(allocator, "source", .{ .string = if (version != null) "explicit_argument" else "runtime_path_only" });
    return .{ .object = obj };
}

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

fn conformanceScenariosValue(allocator: std.mem.Allocator, selected: []const u8) !std.json.Value {
    var scenarios = std.json.Array.init(allocator);
    const rows = [_]struct { backend: []const u8, scenario: []const u8, evidence: []const u8 }{
        .{ .backend = "zls", .scenario = "zls_document_symbols", .evidence = "MCP document symbol response and backend version/hash" },
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
    try obj.put(allocator, "report", json_result.cloneValue(allocator, loaded.value) catch return error.OutOfMemory);
    try obj.put(allocator, "limitations", .{ .string = "Evidence pack preserves the report; consumers must inspect scenario statuses before treating backend support as release evidence." });
    return .{ .object = obj };
}

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

const LoadedJson = struct {
    value: std.json.Value,
    parsed: ?std.json.Parsed(std.json.Value) = null,
    owned: bool = false,

    fn deinit(self: LoadedJson, allocator: std.mem.Allocator) void {
        if (self.parsed) |parsed| {
            var mutable = parsed;
            mutable.deinit();
        } else if (self.owned) {
            json_result.deinitOwnedValue(allocator, self.value);
        }
    }
};

fn loadContentValue(allocator: std.mem.Allocator, tool_name: []const u8, content: []const u8) !LoadedJson {
    _ = tool_name;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    errdefer parsed.deinit();
    return .{ .value = parsed.value, .parsed = parsed };
}

fn parseJsonContent(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, content: []const u8) !std.json.Value {
    _ = field;
    const loaded = try loadContentValue(allocator, tool_name, content);
    defer loaded.deinit(allocator);
    return json_result.cloneValue(allocator, loaded.value);
}

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

fn jsonLoadErrorResult(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
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

fn artifactWriteErrorResult(allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
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

fn parseContentError(allocator: std.mem.Allocator, tool_name: []const u8, content: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = content;
    return invalidArgumentResult(allocator, tool_name, "content", "valid JSON object", if (err == error.InvalidJson) "invalid_json" else @errorName(err), "Pass a JSON object produced by zigar_profile_bootstrap or zigar_project_profile_v2.");
}

fn missingProfileValidation(allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var validation = std.json.ObjectMap.empty;
    try validation.put(allocator, "valid", .{ .bool = false });
    try validation.put(allocator, "findings", try singleFindingArray(allocator, "schema.profile_file", "error", "profile file is missing", "run zigar_profile_bootstrap then zigar_profile_import"));
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "validation", .{ .object = validation });
    return structured(allocator, .{ .object = obj });
}

fn missingProfileRead(allocator: std.mem.Allocator, path: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zigar_profile_read" });
    try obj.put(allocator, "exists", .{ .bool = false });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "profile", .null);
    try obj.put(allocator, "resolution", .{ .string = "Run zigar_profile_bootstrap, review unknowns, then zigar_profile_import with apply=true." });
    return structured(allocator, .{ .object = obj });
}

fn singleFindingArray(allocator: std.mem.Allocator, rule: []const u8, severity: []const u8, message: []const u8, recommendation: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    try array.append(try findingValue(allocator, rule, severity, message, recommendation));
    return .{ .array = array };
}

fn missingPinCheck(allocator: std.mem.Allocator, input: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "zig_toolchain_pin_check" });
    try obj.put(allocator, "input", .{ .string = input });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "status", .{ .string = "pin_missing" });
    try obj.put(allocator, "resolution", .{ .string = "Run zig_toolchain_pin with apply=true after choosing explicit expected versions." });
    return structured(allocator, .{ .object = obj });
}

fn preimageIdentityForPath(a: *App, allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    const resolved = a.workspace.resolveOutput(path) catch return preimageValue(allocator, false, 0, "");
    defer a.workspace.allocator.free(resolved);
    const bytes = std.Io.Dir.cwd().readFileAlloc(a.io, resolved, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return preimageValue(allocator, false, 0, ""),
        else => return preimageValue(allocator, false, 0, ""),
    };
    defer allocator.free(bytes);
    const hash = artifacts.sha256Hex(allocator, bytes) catch return error.OutOfMemory;
    defer allocator.free(hash);
    return preimageValue(allocator, true, bytes.len, hash);
}

fn preimageValue(allocator: std.mem.Allocator, exists: bool, bytes: usize, sha256: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exists", .{ .bool = exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes) });
    if (exists) try obj.put(allocator, "sha256", .{ .string = sha256 }) else try obj.put(allocator, "sha256", .null);
    return .{ .object = obj };
}

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

fn writeAndRegisterArtifact(a: *App, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, producer: []const u8, artifact_kind: []const u8, backend_name: []const u8, notes: []const u8) !void {
    a.workspace.writeFile(a.io, path, bytes) catch return error.WriteFailed;
    const artifact_abs = try a.workspace.resolveOutput(path);
    defer a.workspace.allocator.free(artifact_abs);
    const identity = try artifacts.identityFromBytes(allocator, path, artifact_abs, bytes);
    defer allocator.free(identity.sha256);
    const registry_abs = try a.workspace.resolveOutput(artifacts.default_registry_path);
    defer a.workspace.allocator.free(registry_abs);
    var registry = try artifacts.loadRegistry(allocator, a.io, registry_abs);
    defer registry.deinit(allocator);
    try artifacts.upsert(&registry, allocator, .{
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
        .indexed_at_unix_ms = @intCast(@divTrunc(std.Io.Clock.now(.real, a.io).nanoseconds, std.time.ns_per_ms)),
    });
    try artifacts.writeRegistry(allocator, a.io, registry_abs, registry);
}

fn commandResultProbeValue(allocator: std.mem.Allocator, name: []const u8, a: *App, argv: []const []const u8, timeout_ms: i64, result: command.RunResult) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "ok", .{ .bool = result.succeeded() });
    try obj.put(allocator, "command", try commandResultValue(allocator, name, argv, a.workspace.root, timeout_ms, result));
    return .{ .object = obj };
}

fn commandErrorProbeValue(allocator: std.mem.Allocator, name: []const u8, argv: []const []const u8, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "argv", try common.argvValue(allocator, argv));
    try obj.put(allocator, "error_kind", .{ .string = command.errorKind(err) });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    return .{ .object = obj };
}

fn zvmPlanValue(allocator: std.mem.Allocator, kind: []const u8, zvm_path: []const u8, version: []const u8, argv: []const []const u8, description: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "zvm_path", .{ .string = zvm_path });
    try obj.put(allocator, "version", .{ .string = version });
    try obj.put(allocator, "argv", try common.argvValue(allocator, argv));
    try obj.put(allocator, "description", .{ .string = description });
    try obj.put(allocator, "plan_only", .{ .bool = true });
    try obj.put(allocator, "mutates_environment", .{ .bool = false });
    try obj.put(allocator, "requires_user_execution", .{ .bool = true });
    try obj.put(allocator, "verification", try stringArrayValue(allocator, &.{ "zigar_zvm_probe", "zig_zls_match_check", "zig_toolchain_pin_check" }));
    return .{ .object = obj };
}

fn defaultDevEnvOutput(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "asdf")) return ".zigar-cache/dev-env/.tool-versions";
    if (std.mem.eql(u8, kind, "nix")) return ".zigar-cache/dev-env/flake.nix";
    if (std.mem.eql(u8, kind, "devcontainer")) return ".zigar-cache/dev-env/devcontainer.json";
    if (std.mem.eql(u8, kind, "github-actions")) return ".zigar-cache/dev-env/github-actions.yml";
    return ".zigar-cache/dev-env/mise.toml";
}

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

fn versionFromHints(a: *App) ?[]const u8 {
    _ = a;
    return null;
}

fn firstVersionHint(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var hints = std.json.Array.init(allocator);
    discovery.tryAppendVersionHint(allocator, &hints, a, ".zigversion", "zig", ".zigversion");
    discovery.tryAppendToolVersionsHint(allocator, &hints, a);
    discovery.tryAppendMiseHint(allocator, &hints, a);
    discovery.tryAppendBuildZonMinimumHint(allocator, &hints, a);
    if (hints.items.len == 0) return .null;
    const first = hints.items[0].object.get("version") orelse return .null;
    return json_result.cloneValue(allocator, first);
}

fn projectVersionHintsValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var hints = std.json.Array.init(allocator);
    discovery.tryAppendVersionHint(allocator, &hints, a, ".zigversion", "zig", ".zigversion");
    discovery.tryAppendToolVersionsHint(allocator, &hints, a);
    discovery.tryAppendMiseHint(allocator, &hints, a);
    discovery.tryAppendBuildZonMinimumHint(allocator, &hints, a);
    return .{ .array = hints };
}

fn toolchainPinsValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    const loaded = loadWorkspaceJson(a, allocator, toolchain_pin_path) catch |err| switch (err) {
        error.FileNotFound => return .null,
        else => return .null,
    };
    defer loaded.deinit(allocator);
    return json_result.cloneValue(allocator, loaded.value);
}

fn probeVersion(allocator: std.mem.Allocator, a: *App, argv: []const []const u8, timeout_ms: i64) ![]u8 {
    const result = try command.run(allocator, a.io, a.workspace.root, argv, timeout_ms);
    defer result.deinit(allocator);
    if (!result.succeeded()) return error.ProbeFailed;
    const raw = if (result.stdout.len > 0) result.stdout else result.stderr;
    return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}

fn compatibilityStatus(zig_version: ?[]const u8, zls_version: ?[]const u8) []const u8 {
    const zig = zig_version orelse return "unknown";
    const zls = zls_version orelse return "unknown";
    const zig_prefix = discovery.parseVersionPrefix(zig) orelse return "unknown";
    const zls_prefix = discovery.parseVersionPrefix(zls) orelse return "unknown";
    if (zig_prefix[0] == zls_prefix[0] and zig_prefix[1] == zls_prefix[1]) return "match";
    return "mismatch";
}

fn executableHashValue(allocator: std.mem.Allocator, a: *App, path: []const u8) !std.json.Value {
    if (!std.fs.path.isAbsolute(path)) return .null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(a.io, path, allocator, .limited(64 * 1024 * 1024)) catch return .null;
    defer allocator.free(bytes);
    const hash = try artifacts.sha256Hex(allocator, bytes);
    defer allocator.free(hash);
    return .{ .string = hash };
}

fn trimmedOutputValue(allocator: std.mem.Allocator, result: command.RunResult) !std.json.Value {
    const raw = if (result.stdout.len > 0) result.stdout else result.stderr;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .null;
    return .{ .string = try allocator.dupe(u8, trimmed) };
}

fn configuredBackendPath(a: *App, name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "zig")) return a.config.zig_path;
    if (std.mem.eql(u8, name, "zls")) return a.config.zls_path;
    if (std.mem.eql(u8, name, "zwanzig")) return a.config.zwanzig_path;
    if (std.mem.eql(u8, name, "zflame")) return a.config.zflame_path;
    return a.config.diff_folded_path;
}

fn normalizeBackendName(raw: []const u8) []const u8 {
    if (std.mem.eql(u8, raw, "diff-folded")) return "diff_folded";
    return raw;
}

fn backendSelected(selected: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, selected, "all")) return true;
    if (std.mem.eql(u8, selected, name)) return true;
    if (std.mem.eql(u8, selected, "diff_folded") and std.mem.eql(u8, name, "diff-folded")) return true;
    if (std.mem.eql(u8, selected, "diff_folded") and std.mem.eql(u8, name, "diff_folded")) return true;
    return false;
}

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

fn nestedString(value: std.json.Value, object_name: []const u8, field: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const child = value.object.get(object_name) orelse return null;
    if (child != .object) return null;
    const field_value = child.object.get(field) orelse return null;
    if (field_value != .string) return null;
    return field_value.string;
}

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

fn objectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(field);
}

fn jsonValuesEqual(left: ?std.json.Value, right: ?std.json.Value) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.meta.eql(left.?, right.?);
}

fn jsonObjectString(value: std.json.Value, key: []const u8) std.json.Value {
    if (value != .object) return .null;
    const field = value.object.get(key) orelse return .null;
    if (field != .string) return .null;
    return .{ .string = field.string };
}

fn profileExists(a: *App) bool {
    return workspacePathExists(a, profile_path);
}

fn workspacePathExists(a: *App, path: []const u8) bool {
    return static_analysis.workspacePathExists(a.allocator, a, path);
}

fn factValue(allocator: std.mem.Allocator, key: []const u8, value: []const u8, source: []const u8, confidence: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "key", .{ .string = key });
    try obj.put(allocator, "value", .{ .string = value });
    try obj.put(allocator, "source", .{ .string = source });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    return .{ .object = obj };
}

fn questionValue(allocator: std.mem.Allocator, id: []const u8, prompt: []const u8, next_tool: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "id", .{ .string = id });
    try obj.put(allocator, "prompt", .{ .string = prompt });
    try obj.put(allocator, "required_for_determinism", .{ .bool = false });
    try obj.put(allocator, "next_tool", .{ .string = next_tool });
    return .{ .object = obj };
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}
