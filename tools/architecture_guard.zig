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
    infra_no_runtime_dispatch,
    infra_port_wrapper_only,
    manifest_no_runtime_handler,
    testing_fakes_no_effects,
    no_production_testing_import,
    no_target_imports_retired_common,
    no_handler_to_handler,
    bootstrap_only_composition,
    root_file_allowlist,
    root_public_alias,
    retired_source_path,
    no_retired_surface,
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

const retired_static_analysis_filename = "leg" ++ "acy" ++ "_analysis.zig";

const allowed_root_zig_files = [_][]const u8{
    "src/main.zig",
    "src/root.zig",
};

const allowed_root_public_aliases = [_][]const u8{
    "adapters",
    "app",
    "bootstrap",
    "domain",
    "infra",
    "manifest",
};

const retired_source_paths = [_][]const u8{
    "src/analysis.zig",
    "src/analysis_contract.zig",
    "src/app/usecases/static_analysis/" ++ retired_static_analysis_filename,
    "src/artifacts.zig",
    "src/backend_contracts.zig",
    "src/backend_catalog.zig",
    "src/catalog.zig",
    "src/command.zig",
    "src/command_output.zig",
    "src/config.zig",
    "src/docs.zig",
    "src/doctor.zig",
    "src/evidence.zig",
    "src/json_result.zig",
    "src/logging.zig",
    "src/mcp_server.zig",
    "src/observability.zig",
    "src/resource_errors.zig",
    "src/result_shape.zig",
    "src/runtime.zig",
    "src/runtime_ux.zig",
    "src/server.zig",
    "src/sync.zig",
    "src/tool_errors.zig",
    "src/tool_handlers.zig",
    "src/tool_manifest.zig",
    "src/tool_metadata.zig",
    "src/tool_registry.zig",
    "src/tooling.zig",
    "src/trust.zig",
    "src/version.zig",
    "src/workspace.zig",
};

const retired_source_prefixes = [_][]const u8{
    "src/backend_catalog/",
    "src/docs/",
    "src/lsp/",
    "src/mcp_server/",
    "src/state/",
    "src/tool_manifest/",
    "src/tools/",
    "src/types/",
    "src/zls/",
};

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

const adapter_effect_port_tokens = [_]EffectToken{
    .{ .token = "context.workspace_store", .reason = "MCP adapters must call app use cases instead of workspace ports directly" },
    .{ .token = "context.command_runner", .reason = "MCP adapters must call app use cases instead of command ports directly" },
    .{ .token = "context.workspace_scanner", .reason = "MCP adapters must call app use cases instead of scanner ports directly" },
    .{ .token = "context.backend_probe", .reason = "MCP adapters must call app use cases instead of backend probe ports directly" },
    .{ .token = "context.artifact_store", .reason = "MCP adapters must call app use cases instead of artifact ports directly" },
    .{ .token = "context.zls_gateway", .reason = "MCP adapters must call app use cases instead of ZLS gateway ports directly" },
    .{ .token = "runner.run", .reason = "MCP adapters must not execute command runners directly" },
};

const retired_surface_tokens = [_]EffectToken{
    .{ .token = "Leg" ++ "acy", .reason = "production code must not expose retired compatibility naming" },
    .{ .token = "leg" ++ "acy", .reason = "production code must not expose retired compatibility naming" },
    .{ .token = "sh" ++ "im", .reason = "production code must not keep retired bridge terminology" },
    .{ .token = "compat_", .reason = "production code must not expose shorthand compatibility helpers" },
    .{ .token = "compatibility " ++ "fac" ++ "ade", .reason = "production code must not describe retired compatibility surfaces" },
    .{ .token = "compatibility " ++ "layer", .reason = "production code must not describe retired compatibility surfaces" },
    .{ .token = "compatibility " ++ "sh" ++ "im", .reason = "production code must not describe retired compatibility surfaces" },
    .{ .token = "backward compat", .reason = "production code must not keep backward-compatibility terminology" },
    .{ .token = "trans" ++ "itional", .reason = "production code must not carry migration-state terminology" },
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
    if (allowlist.len != 0) {
        try cli_io.stderrPrint(io, "architecture guard [allowlist-has-owner]: allowlist must remain empty; encode the boundary in ports or bootstrap wiring instead.\n", .{});
        ok = false;
    }
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
    var ok = try checkRootFilePath(io, source_path);
    ok = (try checkRetiredSourcePath(io, source_path)) and ok;
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

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    var test_depth: isize = 0;
    while (lines.next()) |raw_line| : (line_no += 1) {
        const line = withoutLineComment(raw_line);
        const enters_test_block = testBlockStarts(line);
        var line_scan = scan;
        line_scan.is_test_file = scan.is_test_file or test_depth > 0 or enters_test_block;
        ok = (try checkRootPublicAliasInLine(io, line_scan, line, line_no)) and ok;
        ok = (try checkTransitionalSurfaceInLine(io, line_scan, raw_line, line_no)) and ok;
        ok = (try checkImportsInLine(allocator, io, &line_scan, line, line_no)) and ok;
        scan.imports_adapter = scan.imports_adapter or line_scan.imports_adapter;
        scan.imports_infra = scan.imports_infra or line_scan.imports_infra;
        ok = (try checkEffectTokensInLine(io, line_scan, line, line_no)) and ok;
        ok = (try checkMcpResultBoundaryInLine(io, line_scan, line, line_no)) and ok;
        if (enters_test_block or test_depth > 0) {
            test_depth += braceDelta(line);
            if (test_depth < 0) test_depth = 0;
        }
    }

    if (scan.imports_adapter and scan.imports_infra and !compositionAllowedPath(scan.source_path)) {
        ok = (try reportViolation(io, .bootstrap_only_composition, scan.source_path, 0, "adapter+infra imports", "Only src/bootstrap/**, src/main.zig, and the src/root.zig package aggregator may compose adapters with infra; move wiring to bootstrap.")) and ok;
    }
    return ok;
}

fn checkRootFilePath(io: Io, source_path: []const u8) !bool {
    if (!isRootZigFile(source_path) or rootFileAllowed(source_path)) return true;
    return reportViolation(io, .root_file_allowlist, source_path, 0, "root Zig file", "src root may contain only src/main.zig and src/root.zig.");
}

fn checkRetiredSourcePath(io: Io, source_path: []const u8) !bool {
    if (!isRetiredSourcePath(source_path)) return true;
    return reportViolation(io, .retired_source_path, source_path, 0, "retired source path", "This retired source path must not gain production code; use the owning app/domain/adapter/infra package instead.");
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
        ok = (try checkZigarRootMemberImport(io, scan.*, line_no, raw_import, suffix)) and ok;
        updateCompositionScan(scan, normalized);
        ok = (try checkImport(io, scan.*, line_no, raw_import, normalized)) and ok;
        pos = end + 1;
    }
    return ok;
}

fn checkImport(io: Io, scan: FileScan, line_no: usize, raw_import: []const u8, normalized: []const u8) !bool {
    var ok = true;

    if (isTargetLayer(scan.layer) and !isTestingPath(scan.source_path) and !scan.is_test_file and isTestingImport(normalized)) {
        ok = (try reportImportViolation(io, .no_production_testing_import, scan.source_path, line_no, raw_import, normalized, "Production modules must not import src/testing/**; move tests to src/testing/** or *_tests.zig files.")) and ok;
    }

    switch (scan.layer) {
        .domain => if (!isStdImport(normalized) and !isDomainImport(normalized)) {
            ok = (try reportImportViolation(io, .domain_import_wall, scan.source_path, line_no, raw_import, normalized, "src/domain/** may import only std and other src/domain/** modules.")) and ok;
        },
        .app => if (!isStdImport(normalized) and !isDomainImport(normalized) and !isAppImport(normalized) and !(scan.is_test_file and isTestingFakesImport(normalized))) {
            ok = (try reportImportViolation(io, .app_import_wall, scan.source_path, line_no, raw_import, normalized, "src/app/** may import only std, src/domain/**, and src/app/** production modules; app tests may also import src/testing/fakes/**.")) and ok;
        },
        .adapter_mcp => if (mcpAdapterForbiddenImport(normalized)) {
            ok = (try reportImportViolation(io, .mcp_adapter_import_wall, scan.source_path, line_no, raw_import, normalized, "src/adapters/mcp/** may depend on MCP, app/domain, target manifest metadata, and adapter-local mapping only; concrete effects and retired handler bridges need an explicit allowlist entry.")) and ok;
        },
        .infra => {
            if (infraMcpForbiddenImport(normalized)) {
                ok = (try reportImportViolation(io, .infra_no_mcp, scan.source_path, line_no, raw_import, normalized, "src/infra/** must not import MCP contracts, MCP adapters, manifest dispatch, server/registry dispatch, or public MCP result renderers.")) and ok;
            }
            if (isRuntimeImport(normalized)) {
                ok = (try reportImportViolation(io, .infra_no_runtime_dispatch, scan.source_path, line_no, raw_import, normalized, "src/infra/** must not import broad runtime App except for exact ledger-backed runtime wrapper bridges; move runtime field access behind a typed port or bootstrap assembly.")) and ok;
            }
            if (isRetiredHandlerImport(normalized)) {
                ok = (try reportImportViolation(io, .infra_port_wrapper_only, scan.source_path, line_no, raw_import, normalized, "src/infra/** may wrap concrete effect modules, but retired handler imports must stay absent.")) and ok;
            }
            if (isAppImport(normalized) and !isAppPortsImport(normalized)) {
                ok = (try reportImportViolation(io, .infra_port_wrapper_only, scan.source_path, line_no, raw_import, normalized, "src/infra/** may import only src/app/ports.zig from the app layer; move usecase logic to app or depend on a port.")) and ok;
            }
        },
        .manifest => if (manifestForbiddenImport(normalized)) {
            ok = (try reportImportViolation(io, .manifest_no_runtime_handler, scan.source_path, line_no, raw_import, normalized, "src/manifest/** must stay metadata-only and must not import runtime App, handlers, adapters, infra, bootstrap, retired dispatch, or MCP ToolResult types.")) and ok;
        },
        .testing_fakes => if (!isStdImport(normalized) and !isAppImport(normalized) and !isDomainImport(normalized) and !isTestingFakesImport(normalized)) {
            ok = (try reportImportViolation(io, .testing_fakes_no_effects, scan.source_path, line_no, raw_import, normalized, "src/testing/fakes/** may import only std, app port contracts, domain types, and fake-local modules.")) and ok;
        },
        else => {},
    }

    if (isTargetLayer(scan.layer) and !scan.is_test_file and isRetiredCommonImport(normalized)) {
        ok = (try reportImportViolation(io, .no_target_imports_retired_common, scan.source_path, line_no, raw_import, normalized, "Target-layer production code must not import src/tools/common.zig or src/tools/shared_core.zig; move shared behavior behind app/domain/ports instead.")) and ok;
    }
    if (isTargetLayer(scan.layer) and !scan.is_test_file and isPublicHandlerImport(normalized)) {
        ok = (try reportImportViolation(io, .no_handler_to_handler, scan.source_path, line_no, raw_import, normalized, "Target-layer production code must not import public handler modules; share typed app/domain behavior instead of handler-to-handler calls.")) and ok;
    }
    return ok;
}

fn checkZigarRootMemberImport(io: Io, scan: FileScan, line_no: usize, raw_import: []const u8, suffix: []const u8) !bool {
    if (!std.mem.eql(u8, raw_import, "zigar")) return true;
    const member = zigarRootMemberName(suffix) orelse return true;
    if (rootPublicAliasAllowed(member)) return true;
    return reportViolation(io, .root_public_alias, scan.source_path, line_no, member, "Only package-owner roots may be imported through zigar.<name>.");
}

fn checkRootPublicAliasInLine(io: Io, scan: FileScan, line: []const u8, line_no: usize) !bool {
    if (!std.mem.eql(u8, scan.source_path, "src/root.zig")) return true;
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "pub const ")) return true;
    const rest = trimmed["pub const ".len..];
    const end = std.mem.indexOfAny(u8, rest, " \t=") orelse return true;
    const name = rest[0..end];
    if (rootPublicAliasAllowed(name)) return true;
    return reportViolation(io, .root_public_alias, scan.source_path, line_no, name, "src/root.zig may expose only package-owner roots.");
}

fn checkTransitionalSurfaceInLine(io: Io, scan: FileScan, raw_line: []const u8, line_no: usize) !bool {
    if (scan.is_test_file or !isTargetLayer(scan.layer)) return true;
    var ok = true;
    for (retired_surface_tokens) |token| {
        if (std.mem.indexOf(u8, raw_line, token.token) == null) continue;
        ok = (try reportViolation(io, .no_retired_surface, scan.source_path, line_no, token.token, token.reason)) and ok;
    }
    return ok;
}

fn checkMcpResultBoundaryInLine(io: Io, scan: FileScan, line: []const u8, line_no: usize) !bool {
    if (std.mem.indexOf(u8, line, "mcp.tools.ToolResult") == null) return true;
    return switch (scan.layer) {
        .domain => reportViolation(io, .domain_import_wall, scan.source_path, line_no, "mcp.tools.ToolResult", "Domain code must not depend on MCP result shapes."),
        .app => reportViolation(io, .app_import_wall, scan.source_path, line_no, "mcp.tools.ToolResult", "App use cases must expose typed results and leave MCP ToolResult projection to adapters."),
        .infra => reportViolation(io, .infra_no_mcp, scan.source_path, line_no, "mcp.tools.ToolResult", "Infra implements ports and must not construct public MCP ToolResult values."),
        .manifest => reportViolation(io, .manifest_no_runtime_handler, scan.source_path, line_no, "mcp.tools.ToolResult", "Manifest metadata must stay handler-free and MCP ToolResult-free."),
        .testing_fakes => reportViolation(io, .testing_fakes_no_effects, scan.source_path, line_no, "mcp.tools.ToolResult", "Testing fakes model app ports and must not depend on MCP ToolResult values."),
        else => true,
    };
}

fn checkEffectTokensInLine(io: Io, scan: FileScan, line: []const u8, line_no: usize) !bool {
    if (scan.is_test_file) return true;
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
    if (scan.layer == .adapter_mcp) {
        for (adapter_effect_port_tokens) |effect| {
            if (std.mem.indexOf(u8, line, effect.token) == null) continue;
            ok = (try reportViolation(io, rule_id, scan.source_path, line_no, effect.token, effect.reason)) and ok;
        }
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
    const member = zigarRootMemberName(suffix) orelse return null;
    if (std.mem.eql(u8, member, "adapters")) return "src/adapters/root.zig";
    if (std.mem.eql(u8, member, "app")) return "src/app/root.zig";
    if (std.mem.eql(u8, member, "bootstrap")) return "src/bootstrap/root.zig";
    if (std.mem.eql(u8, member, "domain")) return "src/domain/root.zig";
    if (std.mem.eql(u8, member, "infra")) return "src/infra/root.zig";
    if (std.mem.eql(u8, member, "manifest")) return "src/manifest/mod.zig";
    return null;
}

fn zigarRootMemberName(suffix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, suffix, ".")) return null;
    var end: usize = 1;
    while (end < suffix.len) : (end += 1) {
        const byte = suffix[end];
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') break;
    }
    if (end == 1) return null;
    return suffix[1..end];
}

fn rootPublicAliasAllowed(name: []const u8) bool {
    return containsPath(&allowed_root_public_aliases, name);
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

fn isRootZigFile(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "src/")) return false;
    const rest = path["src/".len..];
    return std.mem.endsWith(u8, rest, ".zig") and std.mem.indexOfScalar(u8, rest, '/') == null;
}

fn rootFileAllowed(path: []const u8) bool {
    return containsPath(&allowed_root_zig_files, path);
}

fn isRetiredSourcePath(path: []const u8) bool {
    for (retired_source_paths) |retired_path| {
        if (std.mem.eql(u8, path, retired_path)) return true;
    }
    for (retired_source_prefixes) |retired_prefix| {
        if (std.mem.startsWith(u8, path, retired_prefix)) return true;
    }
    return false;
}

fn withoutLineComment(line: []const u8) []const u8 {
    const comment = std.mem.indexOf(u8, line, "//") orelse return line;
    return line[0..comment];
}

fn testBlockStarts(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "test ") or std.mem.startsWith(u8, trimmed, "test{") or std.mem.startsWith(u8, trimmed, "test {");
}

fn braceDelta(line: []const u8) isize {
    var delta: isize = 0;
    var in_string = false;
    var escaped = false;
    for (line) |byte| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\' and in_string) {
            escaped = true;
            continue;
        }
        if (byte == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;
        if (byte == '{') delta += 1;
        if (byte == '}') delta -= 1;
    }
    return delta;
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

fn isTestingImport(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/testing/");
}

fn isTestingPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/testing/");
}

fn isAppPortsImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/app/ports.zig");
}

fn isMcpImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "mcp");
}

fn isRuntimeImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/runtime.zig") or
        std.mem.eql(u8, path, "src/bootstrap/runtime_state.zig");
}

fn isRetiredCommonImport(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/tools/common.zig") or std.mem.eql(u8, path, "src/tools/shared_core.zig");
}

fn isRetiredHandlerImport(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/tools/");
}

fn isPublicHandlerImport(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "src/tools/")) return false;
    if (isRetiredCommonImport(path)) return false;
    if (std.mem.endsWith(u8, path, "_tests.zig")) return false;
    return true;
}

fn isRetiredManifestOrDispatchImport(path: []const u8) bool {
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
        std.mem.startsWith(u8, path, "src/infra/zls/");
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
        isRetiredHandlerImport(path) or
        isRuntimeImport(path);
}

fn infraMcpForbiddenImport(path: []const u8) bool {
    return isMcpImport(path) or
        std.mem.startsWith(u8, path, "src/adapters/") or
        (std.mem.startsWith(u8, path, "src/bootstrap/") and !isRuntimeImport(path)) or
        isRetiredManifestOrDispatchImport(path) or
        isPublicMcpResultRenderer(path);
}

fn manifestForbiddenImport(path: []const u8) bool {
    return isMcpImport(path) or
        isRuntimeImport(path) or
        isRetiredHandlerImport(path) or
        isRetiredManifestOrDispatchImport(path) or
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

fn containsPath(comptime paths: []const []const u8, path: []const u8) bool {
    for (paths) |candidate| {
        if (std.mem.eql(u8, candidate, path)) return true;
    }
    return false;
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
        .infra_no_runtime_dispatch => "infra-no-runtime-dispatch",
        .infra_port_wrapper_only => "infra-port-wrapper-only",
        .manifest_no_runtime_handler => "manifest-no-runtime-handler",
        .testing_fakes_no_effects => "testing-fakes-no-effects",
        .no_production_testing_import => "no-production-testing-import",
        .no_target_imports_retired_common => "no-target-imports-retired-common",
        .no_handler_to_handler => "no-handler-to-handler",
        .bootstrap_only_composition => "bootstrap-only-composition",
        .root_file_allowlist => "root-file-allowlist",
        .root_public_alias => "root-public-alias",
        .retired_source_path => "retired-source-path",
        .no_retired_surface => "no-retired-surface",
        .allowlist_has_owner => "allowlist-has-owner",
    };
}

test "normalize relative import path" {
    const normalized = try normalizeImport(std.testing.allocator, "src/app/profiling/use_case.zig", "../../domain/profile.zig", "");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("src/domain/profile.zig", normalized);
}

test "normalize zigar member imports to package-owner roots only" {
    const app = try normalizeImport(std.testing.allocator, "src/app/use_case.zig", "zigar", ".app.usecases");
    defer std.testing.allocator.free(app);
    try std.testing.expectEqualStrings("src/app/root.zig", app);

    const direct_alias = try normalizeImport(std.testing.allocator, "src/app/use_case.zig", "zigar", ".backend_catalog");
    defer std.testing.allocator.free(direct_alias);
    try std.testing.expectEqualStrings("src/root.zig", direct_alias);
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

test "forbidden import classifiers cover boundary guard families" {
    try std.testing.expect(mcpAdapterForbiddenImport("src/command.zig"));
    try std.testing.expect(mcpAdapterForbiddenImport("src/tools/profiling.zig"));
    try std.testing.expect(infraMcpForbiddenImport("mcp"));
    try std.testing.expect(infraMcpForbiddenImport("src/adapters/mcp/profiling.zig"));
    try std.testing.expect(manifestForbiddenImport("src/runtime.zig"));
    try std.testing.expect(isRetiredCommonImport("src/tools/common.zig"));
    try std.testing.expect(isPublicHandlerImport("src/tools/profiling.zig"));
    try std.testing.expect(isTestingImport("src/testing/fakes/root.zig"));
    try std.testing.expect(isAppPortsImport("src/app/ports.zig"));
    try std.testing.expect(!isAppPortsImport("src/app/usecases/core.zig"));
}

test "ARCH-114 retired source paths are fail closed" {
    try std.testing.expect(isRetiredSourcePath("src/tools/artifacts.zig"));
    try std.testing.expect(isRetiredSourcePath("src/tools/discovery.zig"));
    try std.testing.expect(isRetiredSourcePath("src/tools/observability.zig"));
    try std.testing.expect(isRetiredSourcePath("src/tools/core.zig"));
    try std.testing.expect(isRetiredSourcePath("src/app/usecases/static_analysis/" ++ retired_static_analysis_filename));
    try std.testing.expect(isRetiredSourcePath("src/lsp/client.zig"));
    try std.testing.expect(isRetiredSourcePath("src/lsp/future_client.zig"));
    try std.testing.expect(isRetiredSourcePath("src/tool_manifest/definitions/core.zig"));
    try std.testing.expect(!isRetiredSourcePath("src/manifest/definitions/core.zig"));
}

test "root files and root public aliases are fail closed" {
    try std.testing.expect(rootFileAllowed("src/main.zig"));
    try std.testing.expect(rootFileAllowed("src/root.zig"));
    try std.testing.expect(!rootFileAllowed("src/backend_catalog.zig"));
    try std.testing.expect(rootPublicAliasAllowed("manifest"));
    try std.testing.expect(!rootPublicAliasAllowed("backend_catalog"));
}

test "adapter effect-port tokens cover static-analysis orchestration regressions" {
    try std.testing.expect(std.mem.indexOf(u8, "context.workspace_store.readFile(...)", adapter_effect_port_tokens[0].token) != null);
    try std.testing.expect(std.mem.indexOf(u8, "try runner.run(allocator, request)", adapter_effect_port_tokens[6].token) != null);
    try std.testing.expectEqualStrings("backend_catalog", zigarRootMemberName(".backend_catalog.find").?);
    try std.testing.expect(zigarRootMemberName("") == null);
}

test "architecture guard allowlist is empty and fail-closed" {
    try std.testing.expectEqual(@as(usize, 0), allowlist.len);
    try std.testing.expect(!isAllowlisted(.infra_no_runtime_dispatch, "src/infra/zls/gateway.zig", "src/bootstrap/runtime_state.zig"));
    try std.testing.expectEqualStrings("infra-no-runtime-dispatch", ruleName(.infra_no_runtime_dispatch));
}
