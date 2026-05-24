const std = @import("std");
const app_context = @import("../../context.zig");
const support = @import("../usecase_support.zig");
const backend_catalog = @import("backend_catalog.zig");

const artifacts = support.artifacts;
pub const App = support.UsecaseApp(app_context.AdoptionContext);
pub const Result = support.Result;
const argBool = support.argBool;
const argInt = support.argInt;
const argString = support.argString;
const invalidArgumentResult = support.invalidArgumentResult;
const structured = support.structured;
const toolErrorFromError = support.toolErrorFromError;
const workspacePathErrorResult = support.workspacePathErrorResult;

const schema_version = 1;
const max_evidence_bytes = 16 * 1024 * 1024;
const default_config_output = ".zigar-cache/adoption/zigar-mcp.json";
const default_conformance_input = ".zigar-cache/backend-conformance/report.json";
const default_conformance_output = ".zigar-cache/adoption/conformance-report.json";

const SourceEvidence = struct {
    available: bool,
    source_kind: []const u8,
    source_path: ?[]const u8 = null,
    bytes: []const u8 = "",
    owned: ?[]u8 = null,

    fn deinit(self: SourceEvidence, allocator: std.mem.Allocator) void {
        if (self.owned) |bytes| allocator.free(bytes);
    }
};

const Claim = struct {
    backend: []const u8,
    status: []const u8,
    claim_allowed: bool,
    confidence: []const u8,
    evidence: []const u8,
};

pub fn zigarAdoptionPack(a: *App, result_allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const client = argString(args, "client") orelse "generic";
    const transport = argString(args, "transport") orelse transportName(a);
    const backend = argString(args, "backend") orelse "all";
    const mode = argString(args, "mode") orelse "standard";
    if (!validClient(client)) return invalidArgumentResult(result_allocator, "zigar_adoption_pack", "client", clientSet(), client, "Choose a supported client identity or omit client for generic.");
    if (!validTransport(transport)) return invalidArgumentResult(result_allocator, "zigar_adoption_pack", "transport", "stdio or http", transport, "Choose stdio or http.");
    if (!validBackend(backend)) return invalidArgumentResult(result_allocator, "zigar_adoption_pack", "backend", backendSet(), backend, "Choose all or a backend from zigar_backend_catalog.");
    if (!validMode(mode)) return invalidArgumentResult(result_allocator, "zigar_adoption_pack", "mode", "compact, standard, or deep", mode, "Choose compact, standard, or deep.");

    var arena = std.heap.ArenaAllocator.init(result_allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = try baseValue(scratch, a, "zigar_adoption_pack", "existing manifest, workspace configuration, backend catalog, and generated smoke/conformance plans", "medium");
    try obj.put(scratch, "adoption_identity", try identityValue(scratch, "adoption", &.{ a.workspace.root, client, transport, backend, mode }));
    try obj.put(scratch, "client_identity", try clientIdentityValue(scratch, a, client, transport));
    try obj.put(scratch, "catalog_snapshot", try catalogSnapshotValue(scratch, a, backend));
    try obj.put(scratch, "backend_setup_status", try backendSetupStatusValue(scratch, a, backend));
    try obj.put(scratch, "generated_config", try generatedConfigBasisValue(scratch, a, client, transport, defaultKindForClient(client), defaultOutputForKind(client, defaultKindForClient(client))));
    try obj.put(scratch, "smoke_plan", .{ .object = try smokePlanValue(scratch, a, client, transport, backend, "native", a.config.timeout_ms) });
    try obj.put(scratch, "conformance_report", try conformanceBasisValue(scratch, a, backend));
    try obj.put(scratch, "public_claim_evidence", try publicClaimsValue(scratch, backend, false));
    try obj.put(scratch, "verification_commands", try verificationCommandsValue(scratch));
    try obj.put(scratch, "skipped_validation", try stringArrayValue(scratch, &.{
        "backend probes are not run by zigar_adoption_pack",
        "client configuration is described but not written without zigar_client_config_generate apply=true",
        "public backend support claims require zigar_conformance_report evidence ingestion",
    }));
    try obj.put(scratch, "limitations", try stringArrayValue(scratch, &.{
        "The pack reports configured paths and shipped tool contracts; it does not install tools.",
        "Optional backend support is not claimed unless conformance evidence is supplied and parsed.",
    }));
    return structured(result_allocator, .{ .object = obj });
}

pub fn zigarClientConfigGenerate(a: *App, result_allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const client = argString(args, "client") orelse "generic";
    const transport = argString(args, "transport") orelse transportName(a);
    const kind = argString(args, "kind") orelse defaultKindForClient(client);
    const server_path = argString(args, "server_path") orelse "zigar";
    const output = argString(args, "output") orelse defaultOutputForKind(client, kind);
    const apply = argBool(args, "apply", false);
    if (!validClient(client)) return invalidArgumentResult(result_allocator, "zigar_client_config_generate", "client", clientSet(), client, "Choose a supported client identity or omit client for generic.");
    if (!validTransport(transport)) return invalidArgumentResult(result_allocator, "zigar_client_config_generate", "transport", "stdio or http", transport, "Choose stdio or http.");
    if (!validConfigKind(kind)) return invalidArgumentResult(result_allocator, "zigar_client_config_generate", "kind", "mcp-json, codex-toml, claude-json, gemini-json, or markdown", kind, "Choose a generated config kind that matches the target client.");

    const resolved = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, result_allocator, "zigar_client_config_generate", output, err);
    defer a.workspace.allocator.free(resolved);

    const content = configContent(result_allocator, a, client, transport, kind, server_path) catch |err| return toolErrorFromError(result_allocator, .{
        .tool = "zigar_client_config_generate",
        .operation = "generate_client_config",
        .phase = "serialize_config",
        .code = "config_serialization_failed",
        .category = "artifact",
        .resolution = "Retry with a supported config kind and plain string arguments.",
    }, err);
    defer result_allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(result_allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const preimage = preimageIdentityForPath(a, scratch, output) catch .null;
    const artifact_identity = artifactIdentityValue(scratch, output, resolved, content) catch .null;
    const argv = try generatedServerArgv(scratch, a, transport, server_path);
    if (apply) {
        writeAndRegisterArtifact(a, scratch, output, content, "zigar_client_config_generate", "client_config", argv, "zigar", "", "generated MCP client configuration") catch |err|
            return workspacePathErrorResult(a, result_allocator, "zigar_client_config_generate", output, err);
    }

    var obj = try baseValue(scratch, a, "zigar_client_config_generate", "deterministic generated client configuration", "high");
    try obj.put(scratch, "client_identity", try clientIdentityValue(scratch, a, client, transport));
    try obj.put(scratch, "generated_config", try generatedConfigBasisValue(scratch, a, client, transport, kind, output));
    try obj.put(scratch, "target_path", .{ .string = output });
    try obj.put(scratch, "abs_path", .{ .string = resolved });
    try obj.put(scratch, "content", .{ .string = content });
    try obj.put(scratch, "server_argv", try support.argvValue(scratch, argv));
    try obj.put(scratch, "preimage_identity", preimage);
    try obj.put(scratch, "artifact_identity", artifact_identity);
    try obj.put(scratch, "provenance", try provenanceValue(scratch, "zigar_client_config_generate", "client_config", argv, "generated MCP client configuration"));
    try obj.put(scratch, "applied", .{ .bool = apply });
    try obj.put(scratch, "requires_apply", .{ .bool = !apply });
    try obj.put(scratch, "skipped_validation", try stringArrayValue(scratch, &.{
        "client process was not launched",
        "backend probes were not run",
    }));
    try obj.put(scratch, "verification_commands", try stringArrayValue(scratch, &.{ "zig build smoke stdio-fixtures --summary all", "zigar_smoke_plan" }));
    return structured(result_allocator, .{ .object = obj });
}

pub fn zigarSmokePlan(a: *App, result_allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const client = argString(args, "client") orelse "generic";
    const transport = argString(args, "transport") orelse transportName(a);
    const backend = argString(args, "backend") orelse "all";
    const platform = argString(args, "platform") orelse "native";
    const timeout_ms = argInt(args, "timeout_ms", a.config.timeout_ms);
    if (!validClient(client)) return invalidArgumentResult(result_allocator, "zigar_smoke_plan", "client", clientSet(), client, "Choose a supported client identity or omit client for generic.");
    if (!validTransport(transport)) return invalidArgumentResult(result_allocator, "zigar_smoke_plan", "transport", "stdio or http", transport, "Choose stdio or http.");
    if (!validBackend(backend)) return invalidArgumentResult(result_allocator, "zigar_smoke_plan", "backend", backendSet(), backend, "Choose all or a backend from zigar_backend_catalog.");

    var arena = std.heap.ArenaAllocator.init(result_allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    if (timeout_ms <= 0) return invalidArgumentResult(result_allocator, "zigar_smoke_plan", "timeout_ms", "positive integer milliseconds", "non-positive", "Pass a positive timeout budget.");
    if (!supportedPlatform(platform)) {
        var unsupported = try baseValue(scratch, a, "zigar_smoke_plan", "static smoke planning", "low");
        try unsupported.put(scratch, "ok", .{ .bool = false });
        try unsupported.put(scratch, "status", .{ .string = "unsupported_platform" });
        try unsupported.put(scratch, "platform", .{ .string = platform });
        try unsupported.put(scratch, "resolution", .{ .string = "Choose native, current, linux, macos, windows, wasm, or cross-target." });
        return structured(result_allocator, .{ .object = unsupported });
    }
    if (timeout_ms < 500) {
        var timeout = try baseValue(scratch, a, "zigar_smoke_plan", "static smoke planning", "low");
        try timeout.put(scratch, "ok", .{ .bool = false });
        try timeout.put(scratch, "status", .{ .string = "timeout_budget_too_low" });
        try timeout.put(scratch, "timeout_ms", .{ .integer = timeout_ms });
        try timeout.put(scratch, "resolution", .{ .string = "Use at least 500 ms for smoke execution, or keep this as a planning-only result." });
        return structured(result_allocator, .{ .object = timeout });
    }
    const obj = try smokePlanValue(scratch, a, client, transport, backend, platform, timeout_ms);
    return structured(result_allocator, .{ .object = obj });
}

pub fn zigarConformanceReport(a: *App, result_allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const backend = argString(args, "backend") orelse "all";
    const output = argString(args, "output") orelse default_conformance_output;
    const apply = argBool(args, "apply", false);
    if (!validBackend(backend)) return invalidArgumentResult(result_allocator, "zigar_conformance_report", "backend", backendSet(), backend, "Choose all or a backend from zigar_backend_catalog.");
    if (argString(args, "input") != null and argString(args, "content") != null) return invalidArgumentResult(result_allocator, "zigar_conformance_report", "input", "input path or content, not both", "both input and content", "Pass either input or content so the evidence basis is unambiguous.");

    const evidence = readConformanceEvidence(a, result_allocator, args) catch |err| return evidenceReadError(a, result_allocator, args, err);
    defer evidence.deinit(result_allocator);

    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*p| p.deinit();
    if (evidence.available) {
        parsed = std.json.parseFromSlice(std.json.Value, result_allocator, evidence.bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return invalidArgumentResult(result_allocator, "zigar_conformance_report", if (argString(args, "content") != null) "content" else "input", "valid conformance JSON object", "invalid_json", "Provide a JSON object produced by zigar_backend_conformance, release readiness, or real backend conformance tooling."),
        };
        if (parsed.?.value != .object) return invalidArgumentResult(result_allocator, "zigar_conformance_report", if (argString(args, "content") != null) "content" else "input", "JSON object", "non-object JSON", "Provide a top-level JSON object so claim evidence can be mapped.");
    }

    var arena = std.heap.ArenaAllocator.init(result_allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const report = try conformanceReportValue(scratch, a, backend, evidence, if (parsed) |p| p.value else null);
    const report_bytes = stringifyAlloc(result_allocator, .{ .object = report }, .{ .whitespace = .indent_2 }) catch |err| return toolErrorFromError(result_allocator, .{
        .tool = "zigar_conformance_report",
        .operation = "serialize_report",
        .phase = "json_stringify",
        .code = "report_serialization_failed",
        .category = "artifact",
        .resolution = "Retry with a smaller evidence payload.",
    }, err);
    defer result_allocator.free(report_bytes);

    const resolved = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, result_allocator, "zigar_conformance_report", output, err);
    defer a.workspace.allocator.free(resolved);
    const preimage = preimageIdentityForPath(a, scratch, output) catch .null;
    const artifact_identity = artifactIdentityValue(scratch, output, resolved, report_bytes) catch .null;
    const argv = try stringArrayLiteral(scratch, &.{ "zigar_conformance_report", "--source", evidence.source_kind });
    if (apply) {
        writeAndRegisterArtifact(a, scratch, output, report_bytes, "zigar_conformance_report", "adoption_conformance_report", argv, "zigar", "", "public adoption conformance report") catch |err|
            return workspacePathErrorResult(a, result_allocator, "zigar_conformance_report", output, err);
    }
    var result = try baseValue(scratch, a, "zigar_conformance_report", "ingested zigar conformance evidence", if (evidence.available) "medium" else "low");
    try result.put(scratch, "report", .{ .object = report });
    try result.put(scratch, "content", .{ .string = report_bytes });
    try result.put(scratch, "target_path", .{ .string = output });
    try result.put(scratch, "abs_path", .{ .string = resolved });
    try result.put(scratch, "preimage_identity", preimage);
    try result.put(scratch, "artifact_identity", artifact_identity);
    try result.put(scratch, "provenance", try provenanceValue(scratch, "zigar_conformance_report", "adoption_conformance_report", argv, "public adoption conformance report"));
    try result.put(scratch, "applied", .{ .bool = apply });
    try result.put(scratch, "requires_apply", .{ .bool = !apply });
    return structured(result_allocator, .{ .object = result });
}

fn baseValue(allocator: std.mem.Allocator, a: *App, kind: []const u8, basis: []const u8, confidence: []const u8) !std.json.ObjectMap {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "evidence_basis", .{ .string = basis });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    return obj;
}

fn clientIdentityValue(allocator: std.mem.Allocator, a: *App, client: []const u8, transport: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "client", .{ .string = client });
    try obj.put(allocator, "transport", .{ .string = transport });
    try obj.put(allocator, "server", .{ .string = "zigar" });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    if (std.mem.eql(u8, transport, "http")) {
        try obj.put(allocator, "url", .{ .string = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ a.config.host, a.config.port }) });
    }
    return .{ .object = obj };
}

fn catalogSnapshotValue(allocator: std.mem.Allocator, a: *App, backend: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "toolchain", try toolchainValue(allocator, a));
    try obj.put(allocator, "backend_scope", .{ .string = backend });
    try obj.put(allocator, "backend_catalog", try backend_catalog.value(allocator, .{
        .zig_path = a.config.zig_path,
        .zls_path = a.config.zls_path,
        .zlint_path = a.config.zlint_path,
        .zwanzig_path = a.config.zwanzig_path,
        .zflame_path = a.config.zflame_path,
        .diff_folded_path = a.config.diff_folded_path,
    }, true));
    try obj.put(allocator, "platform", .{ .string = hostPlatformName(a) });
    try obj.put(allocator, "profile_v2", try profileStatusValue(allocator, a));
    return .{ .object = obj };
}

fn backendSetupStatusValue(allocator: std.mem.Allocator, a: *App, selected: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (backend_catalog.backends) |backend| {
        if (!backendSelected(selected, backend.name)) continue;
        var obj = std.json.ObjectMap.empty;
        const path = configuredBackendPath(a, backend.name);
        try obj.put(allocator, "backend", .{ .string = backend.name });
        try obj.put(allocator, "optional", .{ .bool = backend.optional });
        try obj.put(allocator, "configured_path", .{ .string = path });
        try obj.put(allocator, "status", .{ .string = if (std.mem.startsWith(u8, path, "/definitely/missing")) "missing_configured_path" else "not_probed" });
        try obj.put(allocator, "resolution", .{ .string = if (backend.optional) "Pin the executable in project setup or CI and pass the matching --*-path flag; zigar does not install optional backends." else "Install Zig 0.16.0 or pass --zig-path to a pinned executable." });
        try obj.put(allocator, "verify", try stringArrayValue(allocator, backend.verify));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn smokePlanValue(allocator: std.mem.Allocator, a: *App, client: []const u8, transport: []const u8, backend: []const u8, platform: []const u8, timeout_ms: i64) !std.json.ObjectMap {
    var obj = try baseValue(allocator, a, "zigar_smoke_plan", "static manifest, client identity, backend catalog, and workspace configuration", "medium");
    try obj.put(allocator, "client_identity", try clientIdentityValue(allocator, a, client, transport));
    try obj.put(allocator, "smoke_scenario_identity", try identityValue(allocator, "smoke", &.{ a.workspace.root, client, transport, backend, platform }));
    try obj.put(allocator, "platform", .{ .string = if (std.mem.eql(u8, platform, "current") or std.mem.eql(u8, platform, "native")) hostPlatformName(a) else platform });
    try obj.put(allocator, "backend", .{ .string = backend });
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "backend_setup_status", try backendSetupStatusValue(allocator, a, backend));
    try obj.put(allocator, "scenarios", try smokeScenariosValue(allocator, backend, transport));
    try obj.put(allocator, "verification_commands", try verificationCommandsValue(allocator));
    try obj.put(allocator, "skipped_validation", try stringArrayValue(allocator, &.{"plan only; no server, backend, or client command was launched"}));
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{"Smoke success must be observed by running the listed commands in the target environment."}));
    return obj;
}

fn smokeScenariosValue(allocator: std.mem.Allocator, backend: []const u8, transport: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    try array.append(try scenarioValue(allocator, "initialize", "Start the zigar MCP server and complete initialize/initialized.", transport, "server_identity"));
    try array.append(try scenarioValue(allocator, "tools_list", "Call tools/list and confirm the adoption tools and existing public tools are advertised.", transport, "manifest_contract"));
    try array.append(try scenarioValue(allocator, "schema", "Call zigar_schema for zigar_client_config_generate and zigar_conformance_report.", transport, "schema_contract"));
    try array.append(try scenarioValue(allocator, "workspace", "Call zigar_workspace_info and verify workspace roots remain bounded.", transport, "workspace_roots"));
    try array.append(try scenarioValue(allocator, "doctor", "Call zigar_doctor with probe_backends=false before optional backend probes.", transport, "environment_status"));
    try array.append(try scenarioValue(allocator, "client_config_preview", "Call zigar_client_config_generate with apply=false and verify no file changes.", transport, "apply_gate"));
    try array.append(try scenarioValue(allocator, "smoke_plan", "Call zigar_smoke_plan for the selected backend and platform.", transport, "planning_contract"));
    try array.append(try scenarioValue(allocator, "conformance_report_preview", "Call zigar_conformance_report with apply=false and supplied evidence.", transport, "public_claim_mapping"));
    if (!std.mem.eql(u8, backend, "zig")) {
        try array.append(try scenarioValue(allocator, "backend_verify", "Use zigar_backend_verify or zigar_backend_conformance before claiming optional backend support.", transport, "backend_evidence"));
    }
    return .{ .array = array };
}

fn scenarioValue(allocator: std.mem.Allocator, id: []const u8, description: []const u8, transport: []const u8, evidence: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "id", .{ .string = id });
    try obj.put(allocator, "description", .{ .string = description });
    try obj.put(allocator, "transport", .{ .string = transport });
    try obj.put(allocator, "evidence", .{ .string = evidence });
    try obj.put(allocator, "required", .{ .bool = true });
    return .{ .object = obj };
}

fn conformanceReportValue(allocator: std.mem.Allocator, a: *App, backend: []const u8, evidence: SourceEvidence, parsed: ?std.json.Value) !std.json.ObjectMap {
    var obj = try baseValue(allocator, a, "zigar_public_conformance_report", if (evidence.available) "ingested zigar evidence JSON" else "no conformance evidence available", if (evidence.available) "medium" else "low");
    try obj.put(allocator, "conformance_report_identity", try identityValue(allocator, "conformance", &.{ a.workspace.root, backend, evidence.bytes }));
    try obj.put(allocator, "source", try conformanceSourceValue(allocator, evidence, parsed));
    const claims = try claimArrayValue(allocator, backend, parsed);
    try obj.put(allocator, "backend_support_claims", claims);
    try obj.put(allocator, "public_claim_evidence", try publicClaimsValue(allocator, backend, evidence.available));
    try obj.put(allocator, "verification_commands", try verificationCommandsValue(allocator));
    try obj.put(allocator, "skipped_validation", try stringArrayValue(allocator, &.{"report generation does not probe backends or rerun smoke checks"}));
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{
        "Only observed passed conformance evidence is mapped to support claims.",
        "Availability, configured paths, and planning output are not treated as backend support proof.",
    }));
    if (!evidence.available) {
        try obj.put(allocator, "status", .{ .string = "missing_evidence" });
        try obj.put(allocator, "ok", .{ .bool = false });
        try obj.put(allocator, "resolution", .{ .string = "Run zigar_backend_conformance with apply=true or .github/scripts/backend-conformance.sh, then pass the generated report path or content." });
    }
    return obj;
}

fn conformanceSourceValue(allocator: std.mem.Allocator, evidence: SourceEvidence, parsed: ?std.json.Value) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "available", .{ .bool = evidence.available });
    try obj.put(allocator, "source_kind", .{ .string = evidence.source_kind });
    try obj.put(allocator, "path", if (evidence.source_path) |path| .{ .string = path } else .null);
    try obj.put(allocator, "bytes", .{ .integer = @intCast(evidence.bytes.len) });
    if (evidence.available) {
        const hash = try artifacts.sha256Hex(allocator, evidence.bytes);
        try obj.put(allocator, "sha256", .{ .string = hash });
        try obj.put(allocator, "report_kind", .{ .string = if (parsed) |value| reportKind(value) else "unknown" });
    } else {
        try obj.put(allocator, "sha256", .null);
        try obj.put(allocator, "report_kind", .{ .string = "missing" });
    }
    return .{ .object = obj };
}

fn claimArrayValue(allocator: std.mem.Allocator, selected: []const u8, parsed: ?std.json.Value) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (backend_catalog.backends) |backend| {
        if (!backendSelected(selected, backend.name)) continue;
        const claim = observedClaim(parsed, backend.name);
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "backend", .{ .string = backend.name });
        try obj.put(allocator, "status", .{ .string = claim.status });
        try obj.put(allocator, "claim_allowed", .{ .bool = claim.claim_allowed });
        try obj.put(allocator, "confidence", .{ .string = claim.confidence });
        try obj.put(allocator, "evidence", .{ .string = claim.evidence });
        try obj.put(allocator, "public_language", .{ .string = if (claim.claim_allowed) "observed passing conformance in supplied evidence" else "not observed in supplied evidence" });
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn observedClaim(parsed: ?std.json.Value, backend_name: []const u8) Claim {
    const root = parsed orelse return notObserved(backend_name);
    if (root != .object) return notObserved(backend_name);
    if (matchObjectClaim(root.object, backend_name)) |claim| return claim;
    if (root.object.get("compatibility_matrix")) |matrix| if (matrix == .array) {
        for (matrix.array.items) |item| {
            if (item != .object) continue;
            if (!objectNamesBackend(item.object, backend_name)) continue;
            return statusClaim(backend_name, statusFromObject(item.object) orelse "observed", "compatibility_matrix");
        }
    };
    if (root.object.get("backends")) |backends| {
        if (backends == .array) {
            for (backends.array.items) |item| {
                if (item != .object or !objectNamesBackend(item.object, backend_name)) continue;
                return statusClaim(backend_name, statusFromObject(item.object) orelse "observed", "backends");
            }
        } else if (backends == .object) {
            if (backends.object.get(backend_name)) |item| if (item == .object) return statusClaim(backend_name, statusFromObject(item.object) orelse "observed", "backends");
            const normalized = normalizeBackendName(backend_name);
            if (backends.object.get(normalized)) |item| if (item == .object) return statusClaim(backend_name, statusFromObject(item.object) orelse "observed", "backends");
        }
    }
    return notObserved(backend_name);
}

fn matchObjectClaim(obj: std.json.ObjectMap, backend_name: []const u8) ?Claim {
    if (!objectNamesBackend(obj, backend_name)) return null;
    return statusClaim(backend_name, statusFromObject(obj) orelse "observed", "top_level");
}

fn objectNamesBackend(obj: std.json.ObjectMap, backend_name: []const u8) bool {
    const name = stringField(obj, "backend") orelse stringField(obj, "name") orelse stringField(obj, "backend_name") orelse return false;
    return backendSelected(name, backend_name) or backendSelected(normalizeBackendName(name), backend_name);
}

fn statusFromObject(obj: std.json.ObjectMap) ?[]const u8 {
    if (obj.get("ok")) |value| if (value == .bool and value.bool) return "passed";
    if (obj.get("conformant")) |value| if (value == .bool and value.bool) return "passed";
    if (stringField(obj, "status")) |value| return value;
    if (stringField(obj, "result")) |value| return value;
    if (stringField(obj, "state")) |value| return value;
    return null;
}

fn statusClaim(backend_name: []const u8, status: []const u8, evidence: []const u8) Claim {
    const ok = statusAllowsClaim(status);
    return .{ .backend = backend_name, .status = status, .claim_allowed = ok, .confidence = if (ok) "medium" else "low", .evidence = evidence };
}

fn notObserved(backend_name: []const u8) Claim {
    return .{ .backend = backend_name, .status = "not_observed", .claim_allowed = false, .confidence = "low", .evidence = "no matching passed conformance record" };
}

fn statusAllowsClaim(status: []const u8) bool {
    return std.ascii.eqlIgnoreCase(status, "passed") or std.ascii.eqlIgnoreCase(status, "pass") or std.ascii.eqlIgnoreCase(status, "ok") or std.ascii.eqlIgnoreCase(status, "conformant");
}

fn readConformanceEvidence(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !SourceEvidence {
    _ = allocator;
    if (argString(args, "content")) |content| return .{ .available = true, .source_kind = "inline_content", .bytes = content };
    const path = argString(args, "input") orelse default_conformance_input;
    const bytes = a.workspace.readFileAlloc(a.io, path, max_evidence_bytes) catch |err| switch (err) {
        error.FileNotFound => return .{ .available = false, .source_kind = "workspace_file", .source_path = path },
        else => return err,
    };
    return .{ .available = true, .source_kind = "workspace_file", .source_path = path, .bytes = bytes, .owned = bytes };
}

fn evidenceReadError(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, err: anyerror) !Result {
    const path = argString(args, "input") orelse default_conformance_input;
    return workspacePathErrorResult(a, allocator, "zigar_conformance_report", path, err);
}

fn generatedConfigBasisValue(allocator: std.mem.Allocator, a: *App, client: []const u8, transport: []const u8, kind: []const u8, output: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "client", .{ .string = client });
    try obj.put(allocator, "transport", .{ .string = transport });
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "target_path", .{ .string = output });
    try obj.put(allocator, "workspace", .{ .string = a.workspace.root });
    try obj.put(allocator, "apply_gate", .{ .string = "preview by default; write only with apply=true" });
    return .{ .object = obj };
}

fn conformanceBasisValue(allocator: std.mem.Allocator, a: *App, backend: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "backend", .{ .string = backend });
    try obj.put(allocator, "default_input", .{ .string = default_conformance_input });
    try obj.put(allocator, "default_output", .{ .string = default_conformance_output });
    try obj.put(allocator, "default_input_exists", .{ .bool = workspacePathExists(a, default_conformance_input) });
    try obj.put(allocator, "tool", .{ .string = "zigar_conformance_report" });
    return .{ .object = obj };
}

fn publicClaimsValue(allocator: std.mem.Allocator, backend: []const u8, has_evidence: bool) !std.json.Value {
    var array = std.json.Array.init(allocator);
    try array.append(try claimMappingValue(allocator, "MCP tool contract is shipped", "tool manifest and zigar_schema", true, "high"));
    try array.append(try claimMappingValue(allocator, "Generated client config is preview/apply gated", "zigar_client_config_generate artifact identity and preimage", true, "high"));
    try array.append(try claimMappingValue(allocator, "Optional backend support is observed", if (has_evidence) "supplied conformance report" else "missing conformance report", has_evidence and !std.mem.eql(u8, backend, "all"), if (has_evidence) "medium" else "low"));
    return .{ .array = array };
}

fn claimMappingValue(allocator: std.mem.Allocator, claim: []const u8, evidence: []const u8, allowed: bool, confidence: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "claim", .{ .string = claim });
    try obj.put(allocator, "evidence", .{ .string = evidence });
    try obj.put(allocator, "claim_allowed", .{ .bool = allowed });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    return .{ .object = obj };
}

fn configContent(allocator: std.mem.Allocator, a: *App, client: []const u8, transport: []const u8, kind: []const u8, server_path: []const u8) ![]u8 {
    const argv = try generatedServerArgv(allocator, a, transport, server_path);
    if (std.mem.eql(u8, kind, "mcp-json") or std.mem.eql(u8, kind, "claude-json") or std.mem.eql(u8, kind, "gemini-json")) {
        var root = std.json.ObjectMap.empty;
        var servers = std.json.ObjectMap.empty;
        var server = std.json.ObjectMap.empty;
        try server.put(allocator, "command", .{ .string = server_path });
        try server.put(allocator, "args", try support.argvValue(allocator, argv[1..]));
        try server.put(allocator, "transport", .{ .string = transport });
        try server.put(allocator, "workspace", .{ .string = a.workspace.root });
        if (std.mem.eql(u8, transport, "http")) try server.put(allocator, "url", .{ .string = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ a.config.host, a.config.port }) });
        try servers.put(allocator, "zigar", .{ .object = server });
        try root.put(allocator, if (std.mem.eql(u8, kind, "gemini-json")) "mcpServers" else "mcpServers", .{ .object = servers });
        try root.put(allocator, "generated_for", .{ .string = client });
        try root.put(allocator, "notes", .{ .string = "Review paths before use; zigar does not install backend tools." });
        return stringifyAlloc(allocator, .{ .object = root }, .{ .whitespace = .indent_2 });
    }
    if (std.mem.eql(u8, kind, "codex-toml")) return codexTomlContent(allocator, a, transport, server_path);
    return markdownConfigContent(allocator, a, client, transport, server_path);
}

fn codexTomlContent(allocator: std.mem.Allocator, a: *App, transport: []const u8, server_path: []const u8) ![]u8 {
    const server = try jsonStringLiteral(allocator, server_path);
    defer allocator.free(server);
    const workspace = try jsonStringLiteral(allocator, a.workspace.root);
    defer allocator.free(workspace);
    const host = try jsonStringLiteral(allocator, a.config.host);
    defer allocator.free(host);
    if (std.mem.eql(u8, transport, "http")) return std.fmt.allocPrint(allocator,
        \\[mcp_servers.zigar]
        \\command = {s}
        \\args = ["--transport", "http", "--host", {s}, "--port", "{d}", "--workspace", {s}]
        \\
    , .{ server, host, a.config.port, workspace });
    return std.fmt.allocPrint(allocator,
        \\[mcp_servers.zigar]
        \\command = {s}
        \\args = ["--transport", "stdio", "--workspace", {s}]
        \\
    , .{ server, workspace });
}

fn markdownConfigContent(allocator: std.mem.Allocator, a: *App, client: []const u8, transport: []const u8, server_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\# zigar client configuration
        \\
        \\Client: {s}
        \\Transport: {s}
        \\Command: {s}
        \\Workspace: {s}
        \\
        \\Verification:
        \\- zigar_smoke_plan
        \\- zigar_conformance_report
        \\
    , .{ client, transport, server_path, a.workspace.root });
}

fn generatedServerArgv(allocator: std.mem.Allocator, a: *App, transport: []const u8, server_path: []const u8) ![]const []const u8 {
    if (std.mem.eql(u8, transport, "http")) return stringArrayLiteral(allocator, &.{ server_path, "--transport", "http", "--host", a.config.host, "--port", try std.fmt.allocPrint(allocator, "{d}", .{a.config.port}), "--workspace", a.workspace.root });
    return stringArrayLiteral(allocator, &.{ server_path, "--transport", "stdio", "--workspace", a.workspace.root });
}

fn verificationCommandsValue(allocator: std.mem.Allocator) !std.json.Value {
    return stringArrayValue(allocator, &.{
        "zig build smoke stdio-fixtures --summary all",
        "zig build release-check --summary all",
        "zigar_smoke_plan",
        "zigar_conformance_report",
    });
}

fn provenanceValue(allocator: std.mem.Allocator, producer: []const u8, artifact_kind: []const u8, argv: []const []const u8, notes: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "producer", .{ .string = producer });
    try obj.put(allocator, "artifact_kind", .{ .string = artifact_kind });
    try obj.put(allocator, "command_argv", try support.argvValue(allocator, argv));
    try obj.put(allocator, "backend_name", .{ .string = "zigar" });
    try obj.put(allocator, "notes", .{ .string = notes });
    return .{ .object = obj };
}

fn writeAndRegisterArtifact(a: *App, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, producer: []const u8, artifact_kind: []const u8, argv: []const []const u8, backend: []const u8, backend_version: []const u8, notes: []const u8) !void {
    try a.workspace.putFile(path, bytes);
    const resolved = try a.workspace.resolveOutput(path);
    defer a.workspace.allocator.free(resolved);
    const identity = try artifacts.identityFromBytes(allocator, path, resolved, bytes);
    defer allocator.free(identity.sha256);
    support.recordWrittenArtifact(a, allocator, .{
        .identity = identity,
        .provenance = .{
            .producer = producer,
            .artifact_kind = artifact_kind,
            .command_argv = argv,
            .backend_name = backend,
            .backend_version = backend_version,
            .notes = notes,
            .toolchain = .{ .zig_path = a.config.zig_path, .zls_path = a.config.zls_path, .zflame_path = a.config.zflame_path, .diff_folded_path = a.config.diff_folded_path },
        },
        .indexed_at_unix_ms = support.unixMs(a),
    }, bytes) catch {};
}

fn artifactIdentityValue(allocator: std.mem.Allocator, path: []const u8, abs_path: []const u8, bytes: []const u8) !std.json.Value {
    const identity = try artifacts.identityFromBytes(allocator, path, abs_path, bytes);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "abs_path", .{ .string = abs_path });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes.len) });
    try obj.put(allocator, "sha256", .{ .string = identity.sha256 });
    return .{ .object = obj };
}

fn preimageIdentityForPath(a: *App, allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    const bytes = a.workspace.readFileAlloc(a.io, path, max_evidence_bytes) catch |err| switch (err) {
        error.FileNotFound => return preimageValue(allocator, false, 0, ""),
        else => return err,
    };
    defer allocator.free(bytes);
    const hash = try artifacts.sha256Hex(allocator, bytes);
    return preimageValue(allocator, true, bytes.len, hash);
}

fn preimageValue(allocator: std.mem.Allocator, exists: bool, bytes: usize, sha256: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exists", .{ .bool = exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes) });
    try obj.put(allocator, "sha256", if (exists) .{ .string = sha256 } else .null);
    return .{ .object = obj };
}

fn toolchainValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "zig_path", .{ .string = a.config.zig_path });
    try obj.put(allocator, "zls_path", .{ .string = a.config.zls_path });
    try obj.put(allocator, "zlint_path", .{ .string = a.config.zlint_path });
    try obj.put(allocator, "zwanzig_path", .{ .string = a.config.zwanzig_path });
    try obj.put(allocator, "zflame_path", .{ .string = a.config.zflame_path });
    try obj.put(allocator, "diff_folded_path", .{ .string = a.config.diff_folded_path });
    return .{ .object = obj };
}

fn profileStatusValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    const exists = workspacePathExists(a, ".zigar/profile.json");
    try obj.put(allocator, "exists", .{ .bool = exists });
    try obj.put(allocator, "path", .{ .string = ".zigar/profile.json" });
    try obj.put(allocator, "resolution", .{ .string = if (exists) "profile v2 can be validated with zigar_profile_validate" else "run zigar_project_profile_v2 with apply=true after reviewing the preview" });
    return .{ .object = obj };
}

fn workspacePathExists(a: *App, path: []const u8) bool {
    return a.workspace.exists(a.allocator, path, false);
}

fn identityValue(allocator: std.mem.Allocator, prefix: []const u8, parts: []const []const u8) !std.json.Value {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(prefix);
    for (parts) |part| {
        hasher.update(&.{0});
        hasher.update(part);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const hash = try allocator.dupe(u8, &hex);
    return .{ .string = hash };
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: std.json.Value, options: std.json.Stringify.Options) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try std.json.Stringify.value(value, options, &aw.writer);
    return try aw.toOwnedSlice();
}

fn jsonStringLiteral(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return stringifyAlloc(allocator, .{ .string = value }, .{ .whitespace = .minified });
}

fn stringArrayLiteral(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const owned = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, i| owned[i] = value;
    return owned;
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = obj.get(field) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn reportKind(value: std.json.Value) []const u8 {
    if (value != .object) return "unknown";
    const kind = stringField(value.object, "kind") orelse return "unknown";
    if (std.mem.eql(u8, kind, "zigar_backend_conformance_report")) return kind;
    if (std.mem.eql(u8, kind, "zigar_release_readiness_report")) return kind;
    if (std.mem.eql(u8, kind, "zigar_real_zls_conformance_report")) return kind;
    return "unknown";
}

fn configuredBackendPath(a: *App, name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "zig")) return a.config.zig_path;
    if (std.mem.eql(u8, name, "zls")) return a.config.zls_path;
    if (std.mem.eql(u8, name, "zlint")) return a.config.zlint_path;
    if (std.mem.eql(u8, name, "zwanzig")) return a.config.zwanzig_path;
    if (std.mem.eql(u8, name, "zflame")) return a.config.zflame_path;
    return a.config.diff_folded_path;
}

fn normalizeBackendName(raw: []const u8) []const u8 {
    if (std.mem.eql(u8, raw, "diff_folded")) return "diff-folded";
    return raw;
}

fn backendSelected(selected: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, selected, "all")) return true;
    if (std.mem.eql(u8, selected, name)) return true;
    if (std.mem.eql(u8, selected, "diff_folded") and std.mem.eql(u8, name, "diff-folded")) return true;
    if (std.mem.eql(u8, selected, "diff-folded") and std.mem.eql(u8, name, "diff_folded")) return true;
    return false;
}

fn transportName(a: *App) []const u8 {
    return switch (a.config.transport) {
        .stdio => "stdio",
        .http => "http",
    };
}

fn hostPlatformName(a: *App) []const u8 {
    const os = a.context.platform.os;
    if (std.mem.eql(u8, os, "linux")) return "linux";
    if (std.mem.eql(u8, os, "macos")) return "macos";
    if (std.mem.eql(u8, os, "windows")) return "windows";
    return os;
}

fn defaultKindForClient(client: []const u8) []const u8 {
    if (std.mem.eql(u8, client, "codex")) return "codex-toml";
    if (std.mem.eql(u8, client, "claude")) return "claude-json";
    if (std.mem.eql(u8, client, "gemini")) return "gemini-json";
    if (std.mem.eql(u8, client, "hermes")) return "mcp-json";
    return "mcp-json";
}

fn defaultOutputForKind(client: []const u8, kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "codex-toml")) return ".zigar-cache/adoption/codex-mcp.toml";
    if (std.mem.eql(u8, kind, "claude-json")) return ".zigar-cache/adoption/claude-mcp.json";
    if (std.mem.eql(u8, kind, "gemini-json")) return ".zigar-cache/adoption/gemini-mcp.json";
    if (std.mem.eql(u8, kind, "markdown")) return ".zigar-cache/adoption/client-config.md";
    _ = client;
    return default_config_output;
}

fn validClient(value: []const u8) bool {
    return std.mem.eql(u8, value, "generic") or std.mem.eql(u8, value, "codex") or std.mem.eql(u8, value, "claude") or std.mem.eql(u8, value, "gemini") or std.mem.eql(u8, value, "hermes");
}

fn validTransport(value: []const u8) bool {
    return std.mem.eql(u8, value, "stdio") or std.mem.eql(u8, value, "http");
}

fn validConfigKind(value: []const u8) bool {
    return std.mem.eql(u8, value, "mcp-json") or std.mem.eql(u8, value, "codex-toml") or std.mem.eql(u8, value, "claude-json") or std.mem.eql(u8, value, "gemini-json") or std.mem.eql(u8, value, "markdown");
}

fn validBackend(value: []const u8) bool {
    return std.mem.eql(u8, value, "all") or std.mem.eql(u8, value, "zig") or std.mem.eql(u8, value, "zls") or std.mem.eql(u8, value, "zlint") or std.mem.eql(u8, value, "zwanzig") or std.mem.eql(u8, value, "zflame") or std.mem.eql(u8, value, "diff-folded") or std.mem.eql(u8, value, "diff_folded");
}

fn validMode(value: []const u8) bool {
    return std.mem.eql(u8, value, "compact") or std.mem.eql(u8, value, "standard") or std.mem.eql(u8, value, "deep");
}

fn supportedPlatform(value: []const u8) bool {
    return std.mem.eql(u8, value, "native") or std.mem.eql(u8, value, "current") or std.mem.eql(u8, value, "linux") or std.mem.eql(u8, value, "macos") or std.mem.eql(u8, value, "windows") or std.mem.eql(u8, value, "wasm") or std.mem.eql(u8, value, "cross-target");
}

fn clientSet() []const u8 {
    return "generic, codex, claude, gemini, or hermes";
}

fn backendSet() []const u8 {
    return "all, zig, zls, zlint, zwanzig, zflame, diff-folded, or diff_folded";
}
