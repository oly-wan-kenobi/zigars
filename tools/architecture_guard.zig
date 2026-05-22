const std = @import("std");
const cli_io = @import("cli_io.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const import_prefix = "@import(\"";

const RuleId = enum {
    domain_import_wall,
    domain_no_effects,
    app_import_wall,
    app_ports_only_effects,
    mcp_adapter_import_wall,
    mcp_adapter_no_business_effects,
    infra_no_mcp,
    infra_port_wrapper_only,
    manifest_no_runtime_handler,
    testing_fakes_no_effects,
    no_target_imports_legacy_common,
    no_handler_to_handler,
    bootstrap_only_composition,
    allowlist_has_owner,
};

const Layer = enum {
    other,
    domain,
    app,
    adapter_mcp,
    adapter_other,
    infra,
    bootstrap,
    manifest,
    testing_fakes,
};

const AllowlistEntry = struct {
    rule_id: RuleId,
    source_path: []const u8,
    pattern: []const u8,
    owner_task: []const u8,
    reason: []const u8,
    retirement_condition: []const u8,
    verification_command: []const u8,
};

const EffectToken = struct {
    token: []const u8,
    reason: []const u8,
};

const FileScan = struct {
    source_path: []const u8,
    layer: Layer,
    is_test_file: bool,
    imports_adapter: bool = false,
    imports_infra: bool = false,
};

const allowlist = [_]AllowlistEntry{};

const direct_effect_tokens = [_]EffectToken{
    .{ .token = "std.process.", .reason = "process execution must go through an app port and infra implementation" },
    .{ .token = "std.Io.Dir.cwd()", .reason = "workspace IO must go through a workspace port" },
    .{ .token = "Io.Dir.cwd()", .reason = "workspace IO must go through a workspace port" },
    .{ .token = ".writeFile(", .reason = "filesystem writes must go through a workspace or artifact port" },
    .{ .token = ".deleteTree(", .reason = "filesystem mutation must go through an effect port" },
    .{ .token = ".makePath(", .reason = "filesystem mutation must go through an effect port" },
    .{ .token = ".createFile(", .reason = "filesystem mutation must go through an effect port" },
    .{ .token = "command.run", .reason = "command execution must go through a command runner port" },
    .{ .token = "runWithOutputLimit(", .reason = "command execution must go through a command runner port" },
    .{ .token = "writeRegistry(", .reason = "artifact writes must go through an artifact store port" },
    .{ .token = "loadRegistry(", .reason = "artifact persistence must go through an artifact store port" },
    .{ .token = "LspClient", .reason = "ZLS/LSP calls must go through a ZLS gateway port" },
    .{ .token = "sendRequest", .reason = "ZLS/LSP calls must go through a ZLS gateway port" },
    .{ .token = "zls_session.", .reason = "ZLS runtime state must go through a ZLS gateway port" },
    .{ .token = "probeBackend", .reason = "backend probing must go through a backend probe port" },
    .{ .token = "backendProbe", .reason = "backend probing must go through a backend probe port" },
    .{ .token = "recordCommand", .reason = "observability mutation must go through an observability port" },
    .{ .token = "recordTool", .reason = "observability mutation must go through an observability port" },
    .{ .token = "observability.", .reason = "observability mutation must go through an observability port" },
};

pub fn run(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 0) return error.InvalidArguments;
    if (!(try check(allocator, io))) return error.ArchitectureGuardFailed;
    try cli_io.stdoutWrite(io, "architecture guard ok\n");
}

pub fn check(allocator: Allocator, io: Io) !bool {
    var ok = try checkAllowlistMetadata(io);
    ok = (try scanSrcTree(allocator, io)) and ok;
    return ok;
}

fn checkAllowlistMetadata(io: Io) !bool {
    var ok = true;
    for (allowlist, 0..) |entry, index| {
        if (entry.source_path.len == 0 or
            entry.pattern.len == 0 or
            entry.owner_task.len == 0 or
            entry.reason.len == 0 or
            entry.retirement_condition.len == 0 or
            entry.verification_command.len == 0)
        {
            try reportAllowlistViolation(io, index, "missing owner task, exact path/pattern, reason, retirement condition, or verification command");
            ok = false;
        }
        if (!std.mem.startsWith(u8, entry.source_path, "src/")) {
            try reportAllowlistViolation(io, index, "source_path must be an exact src/ path");
            ok = false;
        }
    }
    return ok;
}

fn scanSrcTree(allocator: Allocator, io: Io) !bool {
    var dir = Io.Dir.cwd().openDir(io, "src", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var ok = true;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const source_path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(source_path);
        ok = (try checkFile(allocator, io, source_path)) and ok;
    }
    return ok;
}

fn checkFile(allocator: Allocator, io: Io, source_path: []const u8) !bool {
    const bytes = cli_io.readFileAlloc(allocator, io, source_path, 8 * 1024 * 1024) catch |err| {
        try cli_io.stderrPrint(io, "architecture guard could not read {s}: {s}\n", .{ source_path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);

    var scan = FileScan{
        .source_path = source_path,
        .layer = layerForPath(source_path),
        .is_test_file = isTestFile(source_path),
    };

    var ok = true;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |raw_line| : (line_no += 1) {
        const line = withoutLineComment(raw_line);
        ok = (try checkImportsInLine(allocator, io, &scan, line, line_no)) and ok;
        ok = (try checkEffectTokensInLine(io, scan, line, line_no)) and ok;
    }

    if (scan.imports_adapter and scan.imports_infra and !compositionAllowedPath(scan.source_path)) {
        ok = (try reportViolation(io, .bootstrap_only_composition, scan.source_path, 0, "adapter+infra imports", "Only src/bootstrap/**, src/main.zig, and the src/root.zig package aggregator may compose adapters with infra; move wiring to bootstrap or add a narrow legacy-facade allowlist entry with owner and retirement command.")) and ok;
    }
    return ok;
}

fn checkImportsInLine(allocator: Allocator, io: Io, scan: *FileScan, line: []const u8, line_no: usize) !bool {
    var ok = true;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, pos, import_prefix)) |hit| {
        const start = hit + import_prefix.len;
        const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse break;
        const raw_import = line[start..end];
        const suffix = if (end + 1 <= line.len) line[end + 1 ..] else "";
        const normalized = try normalizeImport(allocator, scan.source_path, raw_import, suffix);
        defer allocator.free(normalized);
        updateCompositionScan(scan, normalized);
        ok = (try checkImport(io, scan.*, line_no, raw_import, normalized)) and ok;
        pos = end + 1;
    }
    return ok;
}

fn checkImport(io: Io, scan: FileScan, line_no: usize, raw_import: []const u8, normalized: []const u8) !bool {
    var ok = true;

    switch (scan.layer) {
        .domain => if (!isStdImport(normalized) and !isDomainImport(normalized)) {
            ok = (try reportImportViolation(io, .domain_import_wall, scan.source_path, line_no, raw_import, normalized, "src/domain/** may import only std and other src/domain/** modules.")) and ok;
        },
        .app => if (!isStdImport(normalized) and !isDomainImport(normalized) and !isAppImport(normalized) and !(scan.is_test_file and isTestingFakesImport(normalized))) {
            ok = (try reportImportViolation(io, .app_import_wall, scan.source_path, line_no, raw_import, normalized, "src/app/** may import only std, src/domain/**, and src/app/** production modules; app tests may also import src/testing/fakes/**.")) and ok;
        },
        .adapter_mcp => if (mcpAdapterForbiddenImport(normalized)) {
            ok = (try reportImportViolation(io, .mcp_adapter_import_wall, scan.source_path, line_no, raw_import, normalized, "src/adapters/mcp/** may depend on MCP, app/domain, target manifest metadata, and adapter-local mapping only; concrete effects and legacy handler bridges need an explicit allowlist entry.")) and ok;
        },
        .infra => {
            if (infraMcpForbiddenImport(normalized)) {
                ok = (try reportImportViolation(io, .infra_no_mcp, scan.source_path, line_no, raw_import, normalized, "src/infra/** must not import MCP contracts, MCP adapters, manifest dispatch, server/registry dispatch, or public MCP result renderers.")) and ok;
            }
            if (isLegacyHandlerImport(normalized)) {
                ok = (try reportImportViolation(io, .infra_port_wrapper_only, scan.source_path, line_no, raw_import, normalized, "src/infra/** may wrap concrete effect modules, but legacy handler/facade imports need a named effect-port migration allowlist entry.")) and ok;
            }
        },
        .manifest => if (manifestForbiddenImport(normalized)) {
            ok = (try reportImportViolation(io, .manifest_no_runtime_handler, scan.source_path, line_no, raw_import, normalized, "src/manifest/** must stay metadata-only and must not import runtime App, handlers, adapters, infra, bootstrap, legacy dispatch, or MCP ToolResult types.")) and ok;
        },
        .testing_fakes => if (!isStdImport(normalized) and !isAppImport(normalized) and !isDomainImport(normalized) and !isTestingFakesImport(normalized)) {
            ok = (try reportImportViolation(io, .testing_fakes_no_effects, scan.source_path, line_no, raw_import, normalized, "src/testing/fakes/** may import only std, app port contracts, domain types, and fake-local modules.")) and ok;
        },
        else => {},
    }

    if (isTargetLayer(scan.layer) and !scan.is_test_file and isLegacyCommonImport(normalized)) {
        ok = (try reportImportViolation(io, .no_target_imports_legacy_common, scan.source_path, line_no, raw_import, normalized, "Target-layer production code must not import src/tools/common.zig or src/tools/shared_core.zig; move shared behavior behind app/domain/ports instead.")) and ok;
    }
    if (isTargetLayer(scan.layer) and !scan.is_test_file and isPublicHandlerImport(normalized)) {
        ok = (try reportImportViolation(io, .no_handler_to_handler, scan.source_path, line_no, raw_import, normalized, "Target-layer production code must not import public handler modules; share typed app/domain behavior instead of handler-to-handler calls.")) and ok;
    }
    return ok;
}

fn checkEffectTokensInLine(io: Io, scan: FileScan, line: []const u8, line_no: usize) !bool {
    const rule_id = switch (scan.layer) {
        .domain => RuleId.domain_no_effects,
        .app => RuleId.app_ports_only_effects,
        .adapter_mcp => RuleId.mcp_adapter_no_business_effects,
        .testing_fakes => RuleId.testing_fakes_no_effects,
        else => return true,
    };

    var ok = true;
    for (direct_effect_tokens) |effect| {
        if (std.mem.indexOf(u8, line, effect.token) == null) continue;
        ok = (try reportViolation(io, rule_id, scan.source_path, line_no, effect.token, effect.reason)) and ok;
    }
    return ok;
}

fn reportImportViolation(io: Io, rule_id: RuleId, source_path: []const u8, line_no: usize, raw_import: []const u8, normalized: []const u8, reason: []const u8) !bool {
    if (isAllowlisted(rule_id, source_path, normalized)) return true;
    try cli_io.stderrPrint(
        io,
        "architecture guard [{s}] {s}:{d}: forbidden import `{s}` normalized to `{s}`. {s} Verification: run `zig build architecture-guard`.\n",
        .{ ruleName(rule_id), source_path, line_no, raw_import, normalized, reason },
    );
    return false;
}

fn reportViolation(io: Io, rule_id: RuleId, source_path: []const u8, line_no: usize, pattern: []const u8, reason: []const u8) !bool {
    if (isAllowlisted(rule_id, source_path, pattern)) return true;
    if (line_no == 0) {
        try cli_io.stderrPrint(
            io,
            "architecture guard [{s}] {s}: forbidden pattern `{s}`. {s} Verification: run `zig build architecture-guard`.\n",
            .{ ruleName(rule_id), source_path, pattern, reason },
        );
    } else {
        try cli_io.stderrPrint(
            io,
            "architecture guard [{s}] {s}:{d}: forbidden pattern `{s}`. {s} Verification: run `zig build architecture-guard`.\n",
            .{ ruleName(rule_id), source_path, line_no, pattern, reason },
        );
    }
    return false;
}

fn reportAllowlistViolation(io: Io, index: usize, reason: []const u8) !void {
    try cli_io.stderrPrint(
        io,
        "architecture guard [allowlist-has-owner] allowlist entry {d}: {s}. Required fields: rule_id, source_path, exact pattern, owner_task, reason, retirement_condition, verification_command.\n",
        .{ index, reason },
    );
}

fn isAllowlisted(rule_id: RuleId, source_path: []const u8, pattern: []const u8) bool {
    for (allowlist) |entry| {
        if (entry.rule_id != rule_id) continue;
        if (!std.mem.eql(u8, entry.source_path, source_path)) continue;
        if (!std.mem.eql(u8, entry.pattern, pattern)) continue;
        return true;
    }
    return false;
}

fn normalizeImport(allocator: Allocator, source_path: []const u8, raw_import: []const u8, suffix: []const u8) ![]u8 {
    if (std.mem.eql(u8, raw_import, "zigar")) {
        return allocator.dupe(u8, zigarMemberPath(suffix) orelse "src/root.zig");
    }
    if (!std.mem.endsWith(u8, raw_import, ".zig")) return allocator.dupe(u8, raw_import);

    const base_dir = std.fs.path.dirname(source_path) orelse ".";
    const joined = try std.fs.path.join(allocator, &.{ base_dir, raw_import });
    defer allocator.free(joined);
    return normalizePath(allocator, joined);
}

fn normalizePath(allocator: Allocator, path: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(allocator, part);
    }
    return std.mem.join(allocator, "/", parts.items);
}

fn zigarMemberPath(suffix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, suffix, ".runtime")) return "src/runtime.zig";
    if (std.mem.startsWith(u8, suffix, ".command")) return "src/command.zig";
    if (std.mem.startsWith(u8, suffix, ".workspace")) return "src/workspace.zig";
    if (std.mem.startsWith(u8, suffix, ".artifacts")) return "src/artifacts.zig";
    if (std.mem.startsWith(u8, suffix, ".doctor")) return "src/doctor.zig";
    if (std.mem.startsWith(u8, suffix, ".observability")) return "src/observability.zig";
    if (std.mem.startsWith(u8, suffix, ".tool_manifest")) return "src/tool_manifest.zig";
    if (std.mem.startsWith(u8, suffix, ".tool_metadata")) return "src/tool_metadata.zig";
    if (std.mem.startsWith(u8, suffix, ".tool_registry")) return "src/tool_registry.zig";
    if (std.mem.startsWith(u8, suffix, ".mcp_server")) return "src/mcp_server.zig";
    if (std.mem.startsWith(u8, suffix, ".lsp_")) return "src/lsp";
    if (std.mem.startsWith(u8, suffix, ".zls_")) return "src/zls";
    if (std.mem.startsWith(u8, suffix, ".document_state")) return "src/state/documents.zig";
    return null;
}

fn updateCompositionScan(scan: *FileScan, normalized: []const u8) void {
    if (std.mem.startsWith(u8, normalized, "src/adapters/")) scan.imports_adapter = true;
    if (std.mem.startsWith(u8, normalized, "src/infra/")) scan.imports_infra = true;
}

fn layerForPath(path: []const u8) Layer {
    if (std.mem.startsWith(u8, path, "src/domain/")) return .domain;
    if (std.mem.startsWith(u8, path, "src/app/")) return .app;
    if (std.mem.startsWith(u8, path, "src/adapters/mcp/")) return .adapter_mcp;
    if (std.mem.startsWith(u8, path, "src/adapters/")) return .adapter_other;
    if (std.mem.startsWith(u8, path, "src/infra/")) return .infra;
    if (std.mem.startsWith(u8, path, "src/bootstrap/")) return .bootstrap;
    if (std.mem.startsWith(u8, path, "src/manifest/")) return .manifest;
    if (std.mem.startsWith(u8, path, "src/testing/fakes/")) return .testing_fakes;
    return .other;
}

fn isTargetLayer(layer: Layer) bool {
    return switch (layer) {
        .domain, .app, .adapter_mcp, .adapter_other, .infra, .bootstrap, .manifest, .testing_fakes => true,
        .other => false,
    };
}

fn isTestFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "_tests.zig") or std.mem.endsWith(u8, path, "_test.zig");
}

fn withoutLineComment(line: []const u8) []const u8 {
    const comment = std.mem.indexOf(u8, line, "//") orelse return line;
    return line[0..comment];
}

fn isStdImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "std");
}

fn isDomainImport(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/domain/");
}

fn isAppImport(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/app/");
}

fn isTestingFakesImport(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/testing/fakes/");
}

fn isMcpImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "mcp");
}

fn isRuntimeImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/runtime.zig");
}

fn isLegacyCommonImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/tools/common.zig") or std.mem.eql(u8, path, "src/tools/shared_core.zig");
}

fn isLegacyHandlerImport(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/tools/");
}

fn isPublicHandlerImport(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "src/tools/")) return false;
    if (isLegacyCommonImport(path)) return false;
    if (std.mem.endsWith(u8, path, "_tests.zig")) return false;
    return true;
}

fn isLegacyManifestOrDispatchImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/tool_manifest.zig") or
        std.mem.startsWith(u8, path, "src/tool_manifest/") or
        std.mem.eql(u8, path, "src/tool_handlers.zig") or
        std.mem.eql(u8, path, "src/tool_registry.zig") or
        std.mem.eql(u8, path, "src/tool_metadata.zig") or
        std.mem.eql(u8, path, "src/server.zig") or
        std.mem.startsWith(u8, path, "src/mcp_server");
}

fn isConcreteEffectImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/command.zig") or
        std.mem.eql(u8, path, "src/workspace.zig") or
        std.mem.eql(u8, path, "src/artifacts.zig") or
        std.mem.eql(u8, path, "src/doctor.zig") or
        std.mem.eql(u8, path, "src/observability.zig") or
        std.mem.eql(u8, path, "src/backend_catalog.zig") or
        std.mem.startsWith(u8, path, "src/zls") or
        std.mem.startsWith(u8, path, "src/lsp") or
        std.mem.startsWith(u8, path, "src/state/");
}

fn isPublicMcpResultRenderer(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/json_result.zig") or
        std.mem.eql(u8, path, "src/tool_errors.zig") or
        std.mem.eql(u8, path, "src/resource_errors.zig");
}

fn mcpAdapterForbiddenImport(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/infra/") or
        std.mem.startsWith(u8, path, "src/bootstrap/") or
        isConcreteEffectImport(path) or
        isLegacyHandlerImport(path) or
        isRuntimeImport(path);
}

fn infraMcpForbiddenImport(path: []const u8) bool {
    return isMcpImport(path) or
        std.mem.startsWith(u8, path, "src/adapters/") or
        std.mem.startsWith(u8, path, "src/bootstrap/") or
        isLegacyManifestOrDispatchImport(path) or
        isPublicMcpResultRenderer(path);
}

fn manifestForbiddenImport(path: []const u8) bool {
    return isMcpImport(path) or
        isRuntimeImport(path) or
        isLegacyHandlerImport(path) or
        isLegacyManifestOrDispatchImport(path) or
        std.mem.startsWith(u8, path, "src/app/") or
        std.mem.startsWith(u8, path, "src/adapters/") or
        std.mem.startsWith(u8, path, "src/infra/") or
        std.mem.startsWith(u8, path, "src/bootstrap/") or
        isPublicMcpResultRenderer(path);
}

fn compositionAllowedPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/bootstrap/") or
        std.mem.eql(u8, path, "src/main.zig") or
        std.mem.eql(u8, path, "src/root.zig");
}

fn ruleName(rule_id: RuleId) []const u8 {
    return switch (rule_id) {
        .domain_import_wall => "domain-import-wall",
        .domain_no_effects => "domain-no-effects",
        .app_import_wall => "app-import-wall",
        .app_ports_only_effects => "app-ports-only-effects",
        .mcp_adapter_import_wall => "mcp-adapter-import-wall",
        .mcp_adapter_no_business_effects => "mcp-adapter-no-business-effects",
        .infra_no_mcp => "infra-no-mcp",
        .infra_port_wrapper_only => "infra-port-wrapper-only",
        .manifest_no_runtime_handler => "manifest-no-runtime-handler",
        .testing_fakes_no_effects => "testing-fakes-no-effects",
        .no_target_imports_legacy_common => "no-target-imports-legacy-common",
        .no_handler_to_handler => "no-handler-to-handler",
        .bootstrap_only_composition => "bootstrap-only-composition",
        .allowlist_has_owner => "allowlist-has-owner",
    };
}

test "normalize relative import path" {
    const normalized = try normalizeImport(std.testing.allocator, "src/app/profiling/use_case.zig", "../../domain/profile.zig", "");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("src/domain/profile.zig", normalized);
}

test "normalize zigar member imports named in the ADR" {
    const runtime = try normalizeImport(std.testing.allocator, "src/app/use_case.zig", "zigar", ".runtime");
    defer std.testing.allocator.free(runtime);
    try std.testing.expectEqualStrings("src/runtime.zig", runtime);

    const command = try normalizeImport(std.testing.allocator, "src/app/use_case.zig", "zigar", ".command");
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("src/command.zig", command);
}

test "classify target layers" {
    try std.testing.expectEqual(Layer.domain, layerForPath("src/domain/model.zig"));
    try std.testing.expectEqual(Layer.app, layerForPath("src/app/profiling/run.zig"));
    try std.testing.expectEqual(Layer.adapter_mcp, layerForPath("src/adapters/mcp/profiling.zig"));
    try std.testing.expectEqual(Layer.infra, layerForPath("src/infra/process.zig"));
    try std.testing.expectEqual(Layer.manifest, layerForPath("src/manifest/tools.zig"));
    try std.testing.expectEqual(Layer.testing_fakes, layerForPath("src/testing/fakes/command_runner.zig"));
}

test "allow root package aggregation without treating it as composition" {
    try std.testing.expect(compositionAllowedPath("src/root.zig"));
    try std.testing.expect(compositionAllowedPath("src/bootstrap/runtime_ports.zig"));
    try std.testing.expect(!compositionAllowedPath("src/tools/profiling.zig"));
}

test "forbidden import classifiers cover transitional guard families" {
    try std.testing.expect(mcpAdapterForbiddenImport("src/command.zig"));
    try std.testing.expect(mcpAdapterForbiddenImport("src/tools/profiling.zig"));
    try std.testing.expect(infraMcpForbiddenImport("mcp"));
    try std.testing.expect(infraMcpForbiddenImport("src/adapters/mcp/profiling.zig"));
    try std.testing.expect(manifestForbiddenImport("src/runtime.zig"));
    try std.testing.expect(isLegacyCommonImport("src/tools/common.zig"));
    try std.testing.expect(isPublicHandlerImport("src/tools/profiling.zig"));
}
