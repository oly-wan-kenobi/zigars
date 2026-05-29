const std = @import("std");
const cli_io = @import("../common/cli_io.zig");

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
    adapter_other_import_wall,
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
    unclassified_src_layer,
    import_cycle,
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
    testing,
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

/// Resolves bare module names (`@import("name")`) against the wiring declared
/// in `build.zig`. `addImport(name, b.path("…"))` pairs become a name→path map
/// so that named modules — the project's normal wiring idiom — are subject to
/// the same layering walls as relative `.zig` imports. A name that is wired to
/// a module outside `src/` (an external dependency, the generated build-options
/// module, a tests/ fixture) is recorded as `external`, distinct from a name
/// that was never wired at all.
const ModuleMap = struct {
    const Resolution = union(enum) {
        /// Wired to a `src/…` source file (already normalized, no `.zig` strip).
        src_path: []const u8,
        /// Wired to a module outside `src/` (external dependency, build options,
        /// tests fixture). Not subject to `src/` layering predicates.
        external,
    };

    const Entry = struct {
        name: []const u8,
        resolution: Resolution,
    };

    arena: std.heap.ArenaAllocator,
    entries: []Entry,

    fn empty(allocator: Allocator) ModuleMap {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .entries = &.{} };
    }

    fn deinit(self: *ModuleMap) void {
        self.arena.deinit();
    }

    fn lookup(self: *const ModuleMap, name: []const u8) ?Resolution {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.resolution;
        }
        return null;
    }

    /// Parse `build.zig`. Two passes: first resolve module-variable bindings
    /// (`const x = b.createModule(.{ .root_source_file = b.path("…") })` and
    /// `addZigarsModule(...)` which wires `src/root.zig`), then resolve every
    /// `addImport("name", …)` to a path — either an inline `b.path("…")` within
    /// the call argument, or a previously-bound module variable.
    fn parse(allocator: Allocator, build_src: []const u8) !ModuleMap {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var var_paths: std.ArrayList(Entry) = .empty;
        var entries: std.ArrayList(Entry) = .empty;

        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(allocator);
        var line_it = std.mem.splitScalar(u8, build_src, '\n');
        while (line_it.next()) |line| try lines.append(allocator, line);

        // Pass 1: module-variable bindings.
        for (lines.items, 0..) |line, idx| {
            if (constBindingName(line)) |var_name| {
                if (lineDefinesZigarsModule(line)) {
                    try var_paths.append(a, .{ .name = try a.dupe(u8, var_name), .resolution = .{ .src_path = "src/root.zig" } });
                    continue;
                }
                if (lineOpensCreateOrAddModule(line)) {
                    if (findRootSourcePath(lines.items, idx)) |raw_path| {
                        try appendResolved(a, &var_paths, var_name, raw_path);
                    }
                }
            }
        }

        // Pass 2: addImport("name", …) targets.
        for (lines.items, 0..) |line, idx| {
            const after = importCallArgs(line) orelse continue;
            const name = after.name;
            if (pathLiteralIn(after.rest)) |raw_path| {
                try appendResolved(a, &entries, name, raw_path);
                continue;
            }
            if (lineOpensCreateOrAddModuleAfter(after.rest)) {
                if (findRootSourcePath(lines.items, idx)) |raw_path| {
                    try appendResolved(a, &entries, name, raw_path);
                    continue;
                }
            }
            if (identifierToken(after.rest)) |ref| {
                if (lookupEntry(var_paths.items, ref)) |res| {
                    try entries.append(a, .{ .name = try a.dupe(u8, name), .resolution = try dupeResolution(a, res) });
                    continue;
                }
            }
            // Wired to something we could not resolve to a src path: external.
            try entries.append(a, .{ .name = try a.dupe(u8, name), .resolution = .external });
        }

        return .{ .arena = arena, .entries = try entries.toOwnedSlice(a) };
    }

    fn fromBuildFile(allocator: Allocator, io: Io) ModuleMap {
        const bytes = cli_io.readFileAlloc(allocator, io, "build.zig", 8 * 1024 * 1024) catch return ModuleMap.empty(allocator);
        defer allocator.free(bytes);
        return parse(allocator, bytes) catch ModuleMap.empty(allocator);
    }
};

fn dupeResolution(a: Allocator, res: ModuleMap.Resolution) !ModuleMap.Resolution {
    return switch (res) {
        .src_path => |p| .{ .src_path = try a.dupe(u8, p) },
        .external => .external,
    };
}

fn appendResolved(a: Allocator, list: *std.ArrayList(ModuleMap.Entry), name: []const u8, raw_path: []const u8) !void {
    const normalized = try normalizePath(a, raw_path);
    const resolution: ModuleMap.Resolution = if (std.mem.startsWith(u8, normalized, "src/"))
        .{ .src_path = normalized }
    else
        .external;
    try list.append(a, .{ .name = try a.dupe(u8, name), .resolution = resolution });
}

fn lookupEntry(entries: []const ModuleMap.Entry, name: []const u8) ?ModuleMap.Resolution {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.resolution;
    }
    return null;
}

/// `    const foo = ...` → "foo" (the bound identifier), else null.
fn constBindingName(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "const ")) return null;
    const rest = trimmed["const ".len..];
    const end = std.mem.indexOfAny(u8, rest, " \t=:") orelse return null;
    const name = rest[0..end];
    if (name.len == 0) return null;
    return name;
}

fn lineDefinesZigarsModule(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "addZigarsModule(") != null;
}

fn lineOpensCreateOrAddModule(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "b.createModule(") != null or
        std.mem.indexOf(u8, line, "b.addModule(") != null;
}

fn lineOpensCreateOrAddModuleAfter(rest: []const u8) bool {
    return std.mem.indexOf(u8, rest, "b.createModule(") != null or
        std.mem.indexOf(u8, rest, "b.addModule(") != null;
}

/// Extract the `"name"` and the trailing text of an `X.addImport("name", REST)`
/// call. Returns null when the line is not such a call.
fn importCallArgs(line: []const u8) ?struct { name: []const u8, rest: []const u8 } {
    const marker = ".addImport(\"";
    const hit = std.mem.indexOf(u8, line, marker) orelse return null;
    const name_start = hit + marker.len;
    const name_end = std.mem.indexOfScalarPos(u8, line, name_start, '"') orelse return null;
    const name = line[name_start..name_end];
    if (name.len == 0) return null;
    // Skip the `",` after the name to the remaining argument text.
    var rest_start = name_end + 1;
    if (rest_start < line.len and line[rest_start] == ',') rest_start += 1;
    const rest = if (rest_start <= line.len) line[rest_start..] else "";
    return .{ .name = name, .rest = rest };
}

/// First `b.path("…")` literal in `text`, else null.
fn pathLiteralIn(text: []const u8) ?[]const u8 {
    const marker = "b.path(\"";
    const hit = std.mem.indexOf(u8, text, marker) orelse return null;
    const start = hit + marker.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return null;
    return text[start..end];
}

/// First `.root_source_file = b.path("…")` at or after `start_idx`, scanning
/// until the createModule/addModule argument closes (a line whose trimmed end
/// is `});` or `})` at the same nesting). Bounded look-ahead keeps it simple
/// and matches `zig fmt` output.
fn findRootSourcePath(lines: []const []const u8, start_idx: usize) ?[]const u8 {
    var idx = start_idx;
    var scanned: usize = 0;
    while (idx < lines.len and scanned < 8) : ({
        idx += 1;
        scanned += 1;
    }) {
        const line = lines[idx];
        if (std.mem.indexOf(u8, line, ".root_source_file") != null) {
            if (pathLiteralIn(line)) |p| return p;
        }
        if (scanned > 0) {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (std.mem.eql(u8, trimmed, "});") or std.mem.eql(u8, trimmed, "})") or
                std.mem.endsWith(u8, trimmed, "}));"))
            {
                return null;
            }
        }
    }
    return null;
}

/// First bareword identifier token in `text` (used to resolve
/// `addImport("name", some_module_var)`), else null.
fn identifierToken(text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    var end = i;
    while (end < text.len) : (end += 1) {
        const c = text[end];
        if (!std.ascii.isAlphanumeric(c) and c != '_') break;
    }
    if (end == i) return null;
    const token = text[i..end];
    // A `b` here is the build object (start of `b.path`/`b.createModule`), not
    // a module variable.
    if (std.mem.eql(u8, token, "b")) return null;
    return token;
}

/// Accumulates the `src/`-internal import graph across the whole tree so a
/// dependency cycle (`A → B → … → A`) can be reported. The per-file/per-line
/// walls cannot see cycles; this is the only whole-graph check (MEDIUM-6).
const ImportGraph = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    index_of: std.StringHashMapUnmanaged(usize) = .empty,
    nodes: std.ArrayListUnmanaged([]const u8) = .empty,
    edges: std.ArrayListUnmanaged(std.ArrayListUnmanaged(usize)) = .empty,

    fn init(allocator: Allocator) ImportGraph {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    fn deinit(self: *ImportGraph) void {
        self.arena.deinit();
    }

    fn nodeIndex(self: *ImportGraph, path: []const u8) !usize {
        if (self.index_of.get(path)) |idx| return idx;
        const a = self.arena.allocator();
        const owned = try a.dupe(u8, path);
        const idx = self.nodes.items.len;
        try self.nodes.append(a, owned);
        try self.edges.append(a, .empty);
        try self.index_of.put(a, owned, idx);
        return idx;
    }

    fn addEdge(self: *ImportGraph, from: []const u8, to: []const u8) !void {
        if (std.mem.eql(u8, from, to)) return;
        const a = self.arena.allocator();
        const from_idx = try self.nodeIndex(from);
        const to_idx = try self.nodeIndex(to);
        for (self.edges.items[from_idx].items) |existing| {
            if (existing == to_idx) return;
        }
        try self.edges.items[from_idx].append(a, to_idx);
    }

    const DfsState = enum { unvisited, on_stack, done };

    /// DFS for a back edge; on the first cycle found, report the path and stop
    /// (one diagnostic is enough to fail CI and point at the loop).
    fn reportCycles(self: *ImportGraph, io: Io) !bool {
        const n = self.nodes.items.len;
        if (n == 0) return true;
        const a = self.arena.allocator();
        const state = try a.alloc(DfsState, n);
        @memset(state, .unvisited);
        var stack: std.ArrayListUnmanaged(usize) = .empty;

        for (0..n) |start| {
            if (state[start] != .unvisited) continue;
            if (try self.dfs(io, start, state, &stack, a)) return false;
        }
        return true;
    }

    fn dfs(
        self: *ImportGraph,
        io: Io,
        node: usize,
        state: []DfsState,
        stack: *std.ArrayListUnmanaged(usize),
        a: Allocator,
    ) !bool {
        state[node] = .on_stack;
        try stack.append(a, node);
        for (self.edges.items[node].items) |next| {
            if (state[next] == .on_stack) {
                try self.reportCycle(io, stack.items, next);
                return true;
            }
            if (state[next] == .unvisited) {
                if (try self.dfs(io, next, state, stack, a)) return true;
            }
        }
        _ = stack.pop();
        state[node] = .done;
        return false;
    }

    fn reportCycle(self: *ImportGraph, io: Io, stack: []const usize, loop_start: usize) !void {
        var begin: usize = 0;
        for (stack, 0..) |idx, i| {
            if (idx == loop_start) {
                begin = i;
                break;
            }
        }
        var buffer: [4096]u8 = undefined;
        var writer = Io.File.stderr().writer(io, &buffer);
        try writer.interface.print("architecture guard [{s}] dependency cycle: ", .{ruleName(.import_cycle)});
        for (stack[begin..]) |idx| {
            try writer.interface.print("{s} -> ", .{self.nodes.items[idx]});
        }
        try writer.interface.print("{s}. Break the cycle by depending on a shared lower layer or a port. Verification: run `zig build architecture-guard`.\n", .{self.nodes.items[loop_start]});
        try writer.interface.flush();
    }
};

pub fn run(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 0) return error.InvalidArguments;
    if (!(try check(allocator, io))) return error.ArchitectureGuardFailed;
    try cli_io.stdoutWrite(io, "architecture guard ok\n");
}

pub fn check(allocator: Allocator, io: Io) !bool {
    var module_map = ModuleMap.fromBuildFile(allocator, io);
    defer module_map.deinit();
    var ok = try checkAllowlistMetadata(io);
    ok = (try scanSrcTree(allocator, io, &module_map)) and ok;
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

fn scanSrcTree(allocator: Allocator, io: Io, module_map: *const ModuleMap) !bool {
    var dir = Io.Dir.cwd().openDir(io, "src", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var graph = ImportGraph.init(allocator);
    defer graph.deinit();

    var ok = true;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const source_path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(source_path);
        ok = (try checkFile(allocator, io, source_path, module_map, &graph)) and ok;
    }
    ok = (try graph.reportCycles(io)) and ok;
    return ok;
}

fn checkFile(allocator: Allocator, io: Io, source_path: []const u8, module_map: *const ModuleMap, graph: *ImportGraph) !bool {
    const bytes = cli_io.readFileAlloc(allocator, io, source_path, 8 * 1024 * 1024) catch |err| {
        try cli_io.stderrPrint(io, "architecture guard could not read {s}: {s}\n", .{ source_path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    return checkFileBytes(allocator, io, source_path, bytes, module_map, graph);
}

/// Runs every per-file wall (path classification, per-line, and whole-file)
/// against an in-memory source body. Factored out of `checkFile` so the source
/// need not exist on disk — the guard self-tests drive this with synthetic
/// fixtures, exercising the same code the CI gate runs.
fn checkFileBytes(allocator: Allocator, io: Io, source_path: []const u8, bytes: []const u8, module_map: *const ModuleMap, graph: *ImportGraph) !bool {
    var ok = try checkRootFilePath(io, source_path);
    ok = (try checkRetiredSourcePath(io, source_path)) and ok;
    ok = (try checkUnclassifiedLayer(io, source_path)) and ok;
    var scan = FileScan{
        .source_path = source_path,
        .layer = layerForPath(source_path),
        .is_test_file = isTestFile(source_path),
    };

    // Files that carry their own `test { … }` blocks legitimately declare
    // test-only imports (fakes, a bootstrap catalog, …) at module scope in the
    // trailing test region, because Zig requires the binding at container scope.
    // Such a declaration is test support, not a production dependency. A testing
    // import smuggled into the *leading* import block is not exempt and stays
    // guarded, and the exemption is per-declaration (never latches), so it
    // cannot unguard later production code (HIGH-2).
    const has_tests = fileHasTestBlock(bytes);
    const leading_end = leadingImportBlockEnd(bytes);
    // Once a production-path file has opened its first top-level `test { … }`
    // block, the remainder of the file is its trailing test region: the test
    // blocks, their helpers, and the test-support `const X = struct { … }`
    // doubles that those tests construct. A module-scope declaration there whose
    // *name* marks it as test support (a `*Test*`-named struct/fn) is test
    // scaffolding, so the effect/boundary walls do not apply inside its body.
    // Anchoring on the first test block — never on a heuristic import line —
    // and gating on a test-support *name* keeps this from latching real
    // production code that merely follows a tail testing import (HIGH-2): a
    // plain `pub fn` after such an import is not test-named and stays guarded.
    const trailing_region_start = firstTopLevelTestBlockLine(bytes);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    var test_depth: isize = 0;
    var depth: isize = 0;
    var test_support_depth: isize = 0;
    while (lines.next()) |raw_line| : (line_no += 1) {
        const line = withoutLineComment(raw_line);
        const enters_test_block = testBlockStarts(line);
        // A trailing test-support import declaration is exempt on its own line
        // only — it never latches later lines into test context.
        const test_support_decl = isTrailingTestSupportImport(line, line_no, leading_end, has_tests);
        // A `*Test*`-named module-scope declaration opened at depth 0 inside the
        // trailing test region opens a test-support body. The brace scope of
        // that one declaration is test context; it never latches sibling
        // declarations because it ends when its own braces close.
        const enters_test_support_decl = test_support_depth == 0 and test_depth == 0 and depth == 0 and
            inTrailingTestRegion(line_no, trailing_region_start) and
            isTestSupportNamedDeclStart(line);
        var line_scan = scan;
        // Test context is the whole-file `_tests.zig`/`src/testing/**` flag, a
        // real `test { … }` brace scope, a trailing test-support import, or the
        // body of a trailing-region test-support declaration.
        line_scan.is_test_file = scan.is_test_file or test_depth > 0 or enters_test_block or test_support_decl or
            test_support_depth > 0 or enters_test_support_decl;
        ok = (try checkRootPublicAliasInLine(io, line_scan, line, line_no)) and ok;
        ok = (try checkTransitionalSurfaceInLine(io, line_scan, line, line_no)) and ok;
        ok = (try checkImportsInLine(allocator, io, &line_scan, line, line_no, module_map, graph, !line_scan.is_test_file)) and ok;
        scan.imports_adapter = scan.imports_adapter or line_scan.imports_adapter;
        scan.imports_infra = scan.imports_infra or line_scan.imports_infra;
        ok = (try checkEffectTokensInLine(io, line_scan, line, line_no)) and ok;
        ok = (try checkMcpResultBoundaryInLine(io, line_scan, line, line_no)) and ok;
        if (enters_test_block or test_depth > 0) {
            test_depth += braceDelta(line);
            if (test_depth < 0) test_depth = 0;
        }
        if (enters_test_support_decl or test_support_depth > 0) {
            test_support_depth += braceDelta(line);
            if (test_support_depth < 0) test_support_depth = 0;
        }
        depth += braceDelta(line);
        if (depth < 0) depth = 0;
    }

    // Composition wiring is a production concern; test scaffolding legitimately
    // assembles adapters with infra to exercise the server.
    if (!scan.is_test_file and scan.imports_adapter and scan.imports_infra and !compositionAllowedPath(scan.source_path)) {
        ok = (try reportViolation(io, .bootstrap_only_composition, scan.source_path, 0, "adapter+infra imports", "Only src/bootstrap/**, src/main.zig, and the src/root.zig package aggregator may compose adapters with infra; move wiring to bootstrap.")) and ok;
    }
    return ok;
}

/// Fail closed on any `src/` file whose directory does not map to a known
/// layer, so a new top-level tree (e.g. `src/util/`) cannot silently escape
/// every wall. `src/main.zig` and `src/root.zig` are the only allowed roots
/// (already enforced by `root_file_allowlist`) and classify as `.other` by
/// directory; exempt them here.
fn checkUnclassifiedLayer(io: Io, source_path: []const u8) !bool {
    if (layerForPath(source_path) != .other) return true;
    if (isRootZigFile(source_path)) return true;
    return reportViolation(io, .unclassified_src_layer, source_path, 0, source_path, "src/ files must live under a known layer (domain, app, adapters, infra, bootstrap, manifest, testing); add the directory to a layer classifier before placing code here.");
}

fn checkRootFilePath(io: Io, source_path: []const u8) !bool {
    if (!isRootZigFile(source_path) or rootFileAllowed(source_path)) return true;
    return reportViolation(io, .root_file_allowlist, source_path, 0, "root Zig file", "src root may contain only src/main.zig and src/root.zig.");
}

fn checkRetiredSourcePath(io: Io, source_path: []const u8) !bool {
    if (!isRetiredSourcePath(source_path)) return true;
    return reportViolation(io, .retired_source_path, source_path, 0, "retired source path", "This retired source path must not gain production code; use the owning app/domain/adapter/infra package instead.");
}

fn checkImportsInLine(allocator: Allocator, io: Io, scan: *FileScan, line: []const u8, line_no: usize, module_map: *const ModuleMap, graph: *ImportGraph, record_in_graph: bool) !bool {
    if (isMultilineStringLiteralLine(line)) return true;
    var ok = true;
    var it = ImportScanner{ .line = line };
    while (it.next()) |found| {
        const raw_import = found.target;
        const suffix = found.suffix;
        const normalized = try normalizeImport(allocator, scan.source_path, raw_import, suffix, module_map);
        defer allocator.free(normalized);
        ok = (try checkZigarsRootMemberImport(io, scan.*, line_no, raw_import, suffix)) and ok;
        updateCompositionScan(scan, normalized);
        // Cycle detection tracks production edges only. Test files, `test { … }`
        // blocks, and test-support import declarations form legal back edges
        // (a test aggregator imports the module under test); excluding them
        // keeps the cycle check from flagging that idiom.
        if (record_in_graph and std.mem.startsWith(u8, normalized, "src/")) try graph.addEdge(scan.source_path, normalized);
        ok = (try checkImport(io, scan.*, line_no, raw_import, normalized)) and ok;
    }
    return ok;
}

/// String-literal-aware scan for genuine `@import("…")` expressions. A match
/// inside a string literal — e.g. `indexOf(src, "@import(")` in
/// static-analysis probe code — is NOT an import and is skipped. The scanner
/// only fires when the `@import(` token sits in code context and is immediately
/// followed by a string-literal argument.
const ImportScanner = struct {
    line: []const u8,
    pos: usize = 0,
    in_string: bool = false,
    escaped: bool = false,

    const Found = struct { target: []const u8, suffix: []const u8 };

    fn next(self: *ImportScanner) ?Found {
        const line = self.line;
        const token = "@import(";
        while (self.pos < line.len) {
            const c = line[self.pos];
            if (self.escaped) {
                self.escaped = false;
                self.pos += 1;
                continue;
            }
            if (self.in_string) {
                if (c == '\\') {
                    self.escaped = true;
                } else if (c == '"') {
                    self.in_string = false;
                }
                self.pos += 1;
                continue;
            }
            if (c == '"') {
                self.in_string = true;
                self.pos += 1;
                continue;
            }
            if (c == '@' and std.mem.startsWith(u8, line[self.pos..], token)) {
                const after_token = self.pos + token.len;
                if (after_token < line.len and line[after_token] == '"') {
                    const start = after_token + 1;
                    if (std.mem.indexOfScalarPos(u8, line, start, '"')) |end| {
                        const target = line[start..end];
                        const suffix = if (end + 1 <= line.len) line[end + 1 ..] else "";
                        self.pos = end + 1;
                        return .{ .target = target, .suffix = suffix };
                    }
                }
                self.pos = after_token;
                continue;
            }
            self.pos += 1;
        }
        return null;
    }
};

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
        .adapter_mcp => if (!scan.is_test_file and mcpAdapterForbiddenImport(normalized)) {
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
        .adapter_other => if (!scan.is_test_file and !isAdaptersAggregatorRoot(scan.source_path) and adapterOtherForbiddenImport(normalized)) {
            ok = (try reportImportViolation(io, .adapter_other_import_wall, scan.source_path, line_no, raw_import, normalized, "Non-MCP src/adapters/** must not import src/infra/**, src/bootstrap/**, the MCP adapter, MCP contracts, or concrete effect modules; depend on app use cases and domain types instead.")) and ok;
        },
        // Bootstrap is the composition root, `.testing` is test scaffolding,
        // and `.other` is fail-closed by `checkUnclassifiedLayer`; none carry an
        // import wall here.
        .bootstrap, .testing, .other => {},
    }

    if (isTargetLayer(scan.layer) and !scan.is_test_file and isRetiredCommonImport(normalized)) {
        ok = (try reportImportViolation(io, .no_target_imports_retired_common, scan.source_path, line_no, raw_import, normalized, "Target-layer production code must not import src/tools/common.zig or src/tools/shared_core.zig; move shared behavior behind app/domain/ports instead.")) and ok;
    }
    if (isTargetLayer(scan.layer) and !scan.is_test_file and isPublicHandlerImport(normalized)) {
        ok = (try reportImportViolation(io, .no_handler_to_handler, scan.source_path, line_no, raw_import, normalized, "Target-layer production code must not import public handler modules; share typed app/domain behavior instead of handler-to-handler calls.")) and ok;
    }
    return ok;
}

fn checkZigarsRootMemberImport(io: Io, scan: FileScan, line_no: usize, raw_import: []const u8, suffix: []const u8) !bool {
    if (!std.mem.eql(u8, raw_import, "zigars")) return true;
    const member = zigarsRootMemberName(suffix) orelse return true;
    if (rootPublicAliasAllowed(member)) return true;
    return reportViolation(io, .root_public_alias, scan.source_path, line_no, member, "Only package-owner roots may be imported through zigars.<name>.");
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

fn checkTransitionalSurfaceInLine(io: Io, scan: FileScan, line: []const u8, line_no: usize) !bool {
    if (scan.is_test_file or !isTargetLayer(scan.layer)) return true;
    // Multiline-string content (`\\…`) is prose/data, never a retired code
    // surface, and string-literal occurrences of a retired word describe live
    // features rather than retired terminology. Both are skipped so this check
    // gets the same string/comment awareness as the import and effect checks
    // (LOW-7): the caller already passes the comment-stripped `line`.
    if (isMultilineStringLiteralLine(line)) return true;
    var ok = true;
    for (retired_surface_tokens) |token| {
        if (!containsTokenInCode(line, token.token)) continue;
        ok = (try reportViolation(io, .no_retired_surface, scan.source_path, line_no, token.token, token.reason)) and ok;
    }
    return ok;
}

/// True when `token` appears in `line` outside any `"…"` string literal. A
/// match that lives entirely inside a string literal — e.g. the word `shim`
/// inside `"npm shim downloads release archives"` describing the live npm shim
/// — is data, not a retired code surface, and is not reported. If the token
/// occurs both in code and inside a string on the same line, the code
/// occurrence still reports. Mirrors the string state machine used by
/// `ImportScanner`/`withoutLineComment`.
fn containsTokenInCode(line: []const u8, token: []const u8) bool {
    if (token.len == 0) return false;
    var in_string = false;
    var escaped = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_string) {
            if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        // Code context: a token starting here is a genuine retired surface.
        if (std.mem.startsWith(u8, line[i..], token)) return true;
    }
    return false;
}

fn checkMcpResultBoundaryInLine(io: Io, scan: FileScan, line: []const u8, line_no: usize) !bool {
    if (isMultilineStringLiteralLine(line)) return true;
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
    if (isMultilineStringLiteralLine(line)) return true;
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

fn normalizeImport(allocator: Allocator, source_path: []const u8, raw_import: []const u8, suffix: []const u8, module_map: *const ModuleMap) ![]u8 {
    if (std.mem.eql(u8, raw_import, "zigars")) {
        return allocator.dupe(u8, zigarsMemberPath(suffix) orelse "src/root.zig");
    }
    if (!std.mem.endsWith(u8, raw_import, ".zig")) {
        // Bare named module. Resolve through the build.zig wiring so a named
        // module that points into `src/` is subject to the same layering walls
        // as a relative import (HIGH-1). `std`/`builtin` and modules wired to
        // targets outside `src/` resolve to themselves (the layer predicates
        // then treat them as non-src, e.g. `mcp` stays `mcp`).
        if (module_map.lookup(raw_import)) |resolution| switch (resolution) {
            .src_path => |path| return allocator.dupe(u8, path),
            .external => return allocator.dupe(u8, raw_import),
        };
        return allocator.dupe(u8, raw_import);
    }

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

fn zigarsMemberPath(suffix: []const u8) ?[]const u8 {
    const member = zigarsRootMemberName(suffix) orelse return null;
    if (std.mem.eql(u8, member, "adapters")) return "src/adapters/root.zig";
    if (std.mem.eql(u8, member, "app")) return "src/app/root.zig";
    if (std.mem.eql(u8, member, "bootstrap")) return "src/bootstrap/root.zig";
    if (std.mem.eql(u8, member, "domain")) return "src/domain/root.zig";
    if (std.mem.eql(u8, member, "infra")) return "src/infra/root.zig";
    if (std.mem.eql(u8, member, "manifest")) return "src/manifest/mod.zig";
    return null;
}

fn zigarsRootMemberName(suffix: []const u8) ?[]const u8 {
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
    if (std.mem.startsWith(u8, path, "src/testing/")) return .testing;
    return .other;
}

fn isTargetLayer(layer: Layer) bool {
    return switch (layer) {
        .domain, .app, .adapter_mcp, .adapter_other, .infra, .bootstrap, .manifest, .testing_fakes => true,
        // `.testing` is test scaffolding and `.other` is fail-closed elsewhere;
        // neither is a production target layer.
        .testing, .other => false,
    };
}

fn isTestFile(path: []const u8) bool {
    // `src/testing/**` (outside the effect-checked `fakes/` port doubles) is
    // test scaffolding: treat the whole subtree as test context so it is exempt
    // from production import/effect walls without relying on a `_tests.zig`
    // suffix.
    if (layerForPath(path) == .testing) return true;
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

/// Strip a trailing line comment, but only at a `//` that sits in code context.
/// A `//` inside a string literal (e.g. a URL or a path in a `"…"` argument) is
/// not a comment and must not truncate the line, or token/import checks would
/// see a misleading prefix (LOW-7).
fn withoutLineComment(line: []const u8) []const u8 {
    var in_string = false;
    var escaped = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_string) {
            if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') {
            return line[0..i];
        }
    }
    return line;
}

fn testBlockStarts(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "test ") or std.mem.startsWith(u8, trimmed, "test{") or std.mem.startsWith(u8, trimmed, "test {");
}

/// The last line (1-based) of a file's *leading* import block — the contiguous
/// run of module-scope `@import` declarations, blank lines, and comments at the
/// top of the file, before any production construct. Returns 0 when the very
/// first non-blank/comment line is already production.
///
/// This is the abuse boundary for test-support imports (HIGH-2): a
/// `@import("…/testing/…")` declared inside the leading block is treated as a
/// production dependency (a real smell / the accident of "moving a testing
/// import to the top"), while one declared *after* production code — in the
/// trailing test region, next to the file's `test { … }` blocks — is recognized
/// as test support. The leading block can never unguard production code that
/// follows it, because the exemption is per-declaration and never latches.
fn leadingImportBlockEnd(bytes: []const u8) usize {
    var depth: isize = 0;
    var end: usize = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = withoutLineComment(raw_line);
        if (depth == 0) {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0 or isModuleScopeImportDecl(trimmed)) {
                end = line_no;
            } else {
                // First production construct ends the leading block.
                return end;
            }
        }
        depth += braceDelta(line);
        if (depth < 0) depth = 0;
    }
    return end;
}

/// True when the source contains at least one depth-0 `test { … }` block.
fn fileHasTestBlock(bytes: []const u8) bool {
    var depth: isize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = withoutLineComment(raw_line);
        if (depth == 0 and testBlockStarts(line)) return true;
        depth += braceDelta(line);
        if (depth < 0) depth = 0;
    }
    return false;
}

/// 1-based line of the file's *first* top-level `test { … }` block, or 0 when
/// the file has none. Everything after this line is the trailing test region:
/// the test blocks, their helpers, and the test-support doubles they construct.
/// Anchoring the trailing-region exemption on a real test block (never on a
/// heuristic import line) keeps it from latching production code that merely
/// follows a tail testing import (HIGH-2).
fn firstTopLevelTestBlockLine(bytes: []const u8) usize {
    var depth: isize = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = withoutLineComment(raw_line);
        if (depth == 0 and testBlockStarts(line)) return line_no;
        depth += braceDelta(line);
        if (depth < 0) depth = 0;
    }
    return 0;
}

/// True when `line_no` sits strictly after the start of the trailing test
/// region (`region_start != 0`). The `test { … }` opener line itself is handled
/// by the existing `enters_test_block` path, so the region for *declarations*
/// begins on the following line.
fn inTrailingTestRegion(line_no: usize, region_start: usize) bool {
    return region_start != 0 and line_no > region_start;
}

/// True when `line` opens a module-scope declaration (`const`/`fn`, optionally
/// `pub`) whose declared identifier is marked as test support — its name
/// contains `Test`/`test`, e.g. `ResourceTestProvider` or `resourceTestContext`.
/// Used only inside the trailing test region and only at depth 0, so it
/// recognizes test-support doubles/builders while leaving production
/// declarations (`artifactResource`, a plain `sneaky`) guarded. Gating on the
/// declared *name* — not mere position — is what prevents a HIGH-2 latch.
fn isTestSupportNamedDeclStart(line: []const u8) bool {
    const name = moduleScopeDeclName(line) orelse return false;
    return identifierIsTestSupport(name);
}

/// The declared identifier of a module-scope `const`/`fn` declaration line
/// (`const Foo = …` → "Foo", `pub fn bar(` → "bar"), or null when the line is
/// not such a declaration. Only depth-0 declaration openers are passed in.
fn moduleScopeDeclName(line: []const u8) ?[]const u8 {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "pub ")) trimmed = std.mem.trimStart(u8, trimmed["pub ".len..], " \t");
    const keyword: []const u8 = if (std.mem.startsWith(u8, trimmed, "const "))
        "const "
    else if (std.mem.startsWith(u8, trimmed, "fn "))
        "fn "
    else
        return null;
    const rest = std.mem.trimStart(u8, trimmed[keyword.len..], " \t");
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        if (!std.ascii.isAlphanumeric(c) and c != '_') break;
    }
    if (end == 0) return null;
    return rest[0..end];
}

/// True when an identifier names test support — it contains the substring
/// `test` case-insensitively (covers `Test`, `test`, `TestProvider`,
/// `testContext`). Deliberately narrow: it keys on the conventional test
/// naming a production identifier would not carry.
fn identifierIsTestSupport(name: []const u8) bool {
    if (name.len < 4) return false;
    var i: usize = 0;
    while (i + 4 <= name.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(name[i .. i + 4], "test")) return true;
    }
    return false;
}

fn isModuleScopeImportDecl(trimmed: []const u8) bool {
    const is_const = std.mem.startsWith(u8, trimmed, "const ") or std.mem.startsWith(u8, trimmed, "pub const ");
    if (!is_const) return false;
    return std.mem.indexOf(u8, trimmed, import_prefix) != null;
}

/// A module-scope test-support import declaration: a `const … = @import("…")`
/// at depth 0, after the leading import block, in a file that has tests. These
/// sit in the trailing test region next to the `test { … }` blocks and are
/// consumed by them; importing them is test support, not a production
/// dependency. Position-gating on the leading block keeps a misplaced/abusive
/// top-of-file testing import out of this exemption (HIGH-2).
fn isTrailingTestSupportImport(line: []const u8, line_no: usize, leading_end: usize, has_tests: bool) bool {
    if (!has_tests) return false;
    if (line_no <= leading_end) return false;
    return isModuleScopeImportDecl(std.mem.trim(u8, line, " \t"));
}

fn isMultilineStringLiteralLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "\\\\");
}

fn braceDelta(line: []const u8) isize {
    // Multiline-string content (`\\…`) is not code; its braces never nest.
    if (isMultilineStringLiteralLine(line)) return 0;
    var delta: isize = 0;
    var in_string = false;
    var in_char = false;
    var escaped = false;
    for (line) |byte| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if ((in_string or in_char) and byte == '\\') {
            escaped = true;
            continue;
        }
        if (in_string) {
            if (byte == '"') in_string = false;
            continue;
        }
        if (in_char) {
            // Char literals (`'{'`, `'}'`, `'\''`) must not move brace depth.
            if (byte == '\'') in_char = false;
            continue;
        }
        if (byte == '"') {
            in_string = true;
            continue;
        }
        if (byte == '\'') {
            in_char = true;
            continue;
        }
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

fn isMcpAdapterPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/adapters/mcp/");
}

/// The adapters package aggregator re-exports each adapter sub-root (cli, mcp);
/// it is wiring, not a cross-adapter dependency, so the cross-adapter wall does
/// not apply to it (mirrors how `src/root.zig` aggregates the layer roots).
fn isAdaptersAggregatorRoot(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/adapters/root.zig");
}

/// Non-MCP adapters (e.g. a CLI adapter) must stay isolated from sibling
/// adapters and from infra/bootstrap/effect modules; they compose only app use
/// cases and domain types. Cross-adapter coupling and direct effect/transport
/// imports erode the hexagonal boundary just as they do for the MCP adapter.
fn adapterOtherForbiddenImport(path: []const u8) bool {
    return isMcpImport(path) or
        isMcpAdapterPath(path) or
        std.mem.startsWith(u8, path, "src/infra/") or
        std.mem.startsWith(u8, path, "src/bootstrap/") or
        isConcreteEffectImport(path) or
        isRetiredHandlerImport(path) or
        isRetiredManifestOrDispatchImport(path) or
        isRuntimeImport(path) or
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
        .adapter_other_import_wall => "adapter-other-import-wall",
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
        .unclassified_src_layer => "unclassified-src-layer",
        .import_cycle => "import-cycle",
    };
}

test "normalize relative import path" {
    var map = ModuleMap.empty(std.testing.allocator);
    defer map.deinit();
    const normalized = try normalizeImport(std.testing.allocator, "src/app/profiling/use_case.zig", "../../domain/profile.zig", "", &map);
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("src/domain/profile.zig", normalized);
}

test "normalize zigars member imports to package-owner roots only" {
    var map = ModuleMap.empty(std.testing.allocator);
    defer map.deinit();
    const app = try normalizeImport(std.testing.allocator, "src/app/use_case.zig", "zigars", ".app.usecases", &map);
    defer std.testing.allocator.free(app);
    try std.testing.expectEqualStrings("src/app/root.zig", app);

    const direct_alias = try normalizeImport(std.testing.allocator, "src/app/use_case.zig", "zigars", ".backend_catalog", &map);
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
    try std.testing.expect(mcpAdapterForbiddenImport("src/runtime.zig"));
    try std.testing.expect(mcpAdapterForbiddenImport("src/bootstrap/runtime_state.zig"));
    try std.testing.expect(infraMcpForbiddenImport("mcp"));
    try std.testing.expect(infraMcpForbiddenImport("src/adapters/mcp/profiling.zig"));
    try std.testing.expect(infraMcpForbiddenImport("src/json_result.zig"));
    try std.testing.expect(manifestForbiddenImport("src/runtime.zig"));
    try std.testing.expect(manifestForbiddenImport("src/tool_errors.zig"));
    try std.testing.expect(isRetiredCommonImport("src/tools/common.zig"));
    try std.testing.expect(isPublicHandlerImport("src/tools/profiling.zig"));
    try std.testing.expect(isRuntimeImport("src/bootstrap/runtime_state.zig"));
    try std.testing.expect(isRetiredManifestOrDispatchImport("src/tool_manifest.zig"));
    try std.testing.expect(isRetiredManifestOrDispatchImport("src/tool_manifest/definitions/core.zig"));
    try std.testing.expect(isRetiredManifestOrDispatchImport("src/tool_handlers.zig"));
    try std.testing.expect(isRetiredManifestOrDispatchImport("src/tool_registry.zig"));
    try std.testing.expect(isRetiredManifestOrDispatchImport("src/tool_metadata.zig"));
    try std.testing.expect(isRetiredManifestOrDispatchImport("src/server.zig"));
    try std.testing.expect(isRetiredManifestOrDispatchImport("src/mcp_server/server.zig"));
    try std.testing.expect(isPublicMcpResultRenderer("src/json_result.zig"));
    try std.testing.expect(isPublicMcpResultRenderer("src/tool_errors.zig"));
    try std.testing.expect(isPublicMcpResultRenderer("src/resource_errors.zig"));
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
    try std.testing.expectEqualStrings("backend_catalog", zigarsRootMemberName(".backend_catalog.find").?);
    try std.testing.expect(zigarsRootMemberName("") == null);
}

test "test-context helpers classify guard-only syntax without latching" {
    // Real `test { … }` blocks open test context.
    try std.testing.expect(testBlockStarts("test \"adapter\" {"));
    try std.testing.expect(testBlockStarts("    test {"));
    // A bare testing import is NOT a test-block opener; in a production file it
    // must stay subject to no-production-testing-import (HIGH-2).
    try std.testing.expect(!testBlockStarts("const fakes = @import(\"../../../testing/fakes/root.zig\");"));
    try std.testing.expect(!testBlockStarts("const std = @import(\"std\");"));
    // Whole-file test context comes from the path, not a heuristic import line.
    try std.testing.expect(isTestFile("src/app/usecases/dependencies/workflows_tests.zig"));
    try std.testing.expect(isTestFile("src/testing/mcp/server_internal.zig"));
    try std.testing.expect(!isTestFile("src/infra/process/command.zig"));
    try std.testing.expect(isMultilineStringLiteralLine("    \\\\    _ = @import(\"builtin\");"));
    try std.testing.expect(!isMultilineStringLiteralLine("const builtin = @import(\"builtin\");"));
}

test "architecture guard allowlist is empty and fail-closed" {
    try std.testing.expectEqual(@as(usize, 0), allowlist.len);
    try std.testing.expect(!isAllowlisted(.infra_no_runtime_dispatch, "src/infra/zls/gateway.zig", "src/bootstrap/runtime_state.zig"));
    try std.testing.expectEqualStrings("infra-no-runtime-dispatch", ruleName(.infra_no_runtime_dispatch));
}

// --- Soundness self-tests (S5) -------------------------------------------
//
// These pin the three soundness fixes. Each fixture is checked through the
// real per-file pipeline (`checkFileBytes`) so the assertions exercise the same
// code paths the CI gate does. The first two FAIL against the pre-fix guard
// (which returned bare names unchanged and latched the whole file into test
// mode); the third FAILS against the pre-fix guard's lack of string-awareness.

const test_io: Io = Io.Threaded.global_single_threaded.io();

/// Runs the per-file walls over in-memory `bytes` and returns whether the file
/// passed. Diagnostics for deliberately-failing fixtures go to the test
/// runner's captured stderr.
fn runGuardOnBytes(source_path: []const u8, bytes: []const u8, module_map: *const ModuleMap) !bool {
    var graph = ImportGraph.init(std.testing.allocator);
    defer graph.deinit();
    return checkFileBytes(std.testing.allocator, test_io, source_path, bytes, module_map, &graph);
}

test "S5 ModuleMap parses build.zig addImport wiring into name->path" {
    const build_src =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const mcp_mod = b.dependency("mcp", .{}).module("mcp");
        \\    const zigars_mod = addZigarsModule(b, "zigars", target, optimize, mcp_mod, build_options);
        \\    const tools_mod = b.createModule(.{ .root_source_file = b.path("tools/zigars_tools.zig") });
        \\    tools_mod.addImport("zigars", zigars_mod);
        \\    zigars_mod.addImport("mcp", mcp_mod);
        \\    zigars_mod.addImport("cancellation", b.createModule(.{
        \\        .root_source_file = b.path("src/domain/cancellation.zig"),
        \\        .target = target,
        \\    }));
        \\    infra_mod.addImport("render", b.createModule(.{
        \\        .root_source_file = b.path("src/adapters/mcp/server.zig"),
        \\    }));
        \\}
    ;
    var map = try ModuleMap.parse(std.testing.allocator, build_src);
    defer map.deinit();

    // A named module wired to a src/ file resolves to that path.
    try std.testing.expect(map.lookup("cancellation") != null);
    switch (map.lookup("cancellation").?) {
        .src_path => |p| try std.testing.expectEqualStrings("src/domain/cancellation.zig", p),
        .external => return error.TestUnexpectedResult,
    }
    // A module aliased to a forbidden path resolves to that path (HIGH-1).
    switch (map.lookup("render").?) {
        .src_path => |p| try std.testing.expectEqualStrings("src/adapters/mcp/server.zig", p),
        .external => return error.TestUnexpectedResult,
    }
    // The external dependency and the package root resolve as external / root.
    switch (map.lookup("mcp").?) {
        .external => {},
        .src_path => return error.TestUnexpectedResult,
    }
    switch (map.lookup("zigars").?) {
        .src_path => |p| try std.testing.expectEqualStrings("src/root.zig", p),
        .external => return error.TestUnexpectedResult,
    }
}

test "S5 HIGH-1 build.zig-aliased named module import is caught" {
    // build.zig wires the bare name `render` to a forbidden MCP-adapter path.
    const build_src =
        \\pub fn build(b: *std.Build) void {
        \\    infra_mod.addImport("render", b.createModule(.{
        \\        .root_source_file = b.path("src/adapters/mcp/server.zig"),
        \\    }));
        \\    zigars_mod.addImport("cancellation", b.createModule(.{
        \\        .root_source_file = b.path("src/domain/cancellation.zig"),
        \\    }));
        \\}
    ;
    var map = try ModuleMap.parse(std.testing.allocator, build_src);
    defer map.deinit();

    // An infra file importing the aliased name introduces an infra -> adapters/mcp
    // edge. With name resolution this is caught; the pre-fix guard left `render`
    // unchanged and let it pass.
    const infra_src =
        \\const std = @import("std");
        \\const render = @import("render");
        \\pub fn wire() void {
        \\    _ = render;
        \\}
    ;
    try std.testing.expect(!try runGuardOnBytes("src/infra/observability/state.zig", infra_src, &map));

    // Control: with an empty map (pre-fix behavior, name unresolved), the same
    // file is NOT caught — proving resolution is what closes the hole.
    var empty = ModuleMap.empty(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expect(try runGuardOnBytes("src/infra/observability/state.zig", infra_src, &empty));

    // A legitimately wired domain-internal alias still passes the domain wall.
    const domain_src =
        \\const std = @import("std");
        \\pub const cancellation = @import("cancellation");
    ;
    try std.testing.expect(try runGuardOnBytes("src/domain/root.zig", domain_src, &map));
}

test "S5 HIGH-2 a testing import does not latch later code test-exempt" {
    var map = ModuleMap.empty(std.testing.allocator);
    defer map.deinit();

    // Latch isolation: a *legitimately exempt* tail testing-fakes import is
    // followed by a production function that performs a forbidden effect, then
    // the test block. The pre-fix latch flipped everything after the testing
    // import to test-exempt, hiding `runWithOutputLimit`; the fix exempts only
    // the import declaration, so the effect on the later production line is
    // still caught. The testing import itself is allowed in the tail, so the
    // failure isolates the latch, not the import.
    const latched_src =
        \\const std = @import("std");
        \\pub fn realWork() void {}
        \\const fakes = @import("../../testing/fakes/root.zig");
        \\pub fn sneaky() void {
        \\    _ = runWithOutputLimit(.{});
        \\}
        \\test "smoke" {
        \\    _ = fakes;
        \\    realWork();
        \\}
    ;
    try std.testing.expect(!try runGuardOnBytes("src/app/usecases/policy.zig", latched_src, &map));

    // The same effect WITHOUT any preceding testing import is caught too,
    // confirming the assertion above turns on the effect, not the import.
    const plain_src =
        \\const std = @import("std");
        \\pub fn sneaky() void {
        \\    _ = runWithOutputLimit(.{});
        \\}
    ;
    try std.testing.expect(!try runGuardOnBytes("src/app/usecases/policy.zig", plain_src, &map));

    // Accident/abuse: a testing import smuggled into the *leading* import block
    // is itself flagged (no-production-testing-import) rather than silently
    // unguarding the file.
    const leading_src =
        \\const std = @import("std");
        \\const _t = @import("../../testing/fakes/root.zig");
        \\pub fn realWork() void {}
        \\test "smoke" {
        \\    _ = _t;
        \\}
    ;
    try std.testing.expect(!try runGuardOnBytes("src/app/usecases/policy.zig", leading_src, &map));

    // Sanity: the legitimate idiom (production, then a tail testing-fakes import
    // beside the tests, with NO later production effect) passes cleanly.
    const tail_ok_src =
        \\const std = @import("std");
        \\pub fn realWork() void {}
        \\const fakes = @import("../../testing/fakes/root.zig");
        \\test "smoke" {
        \\    _ = fakes;
        \\    realWork();
        \\}
    ;
    try std.testing.expect(try runGuardOnBytes("src/app/usecases/policy.zig", tail_ok_src, &map));
}

test "S5 HIGH-2 trailing test-support import is exempt, real test bodies stay scoped" {
    var map = ModuleMap.empty(std.testing.allocator);
    defer map.deinit();

    // The legitimate idiom: production code, then a trailing test-support import
    // next to the file's test blocks and helpers. The testing import and the
    // effect used inside the `test { … }` block are both fine.
    const idiom_src =
        \\const std = @import("std");
        \\const ports = @import("../../ports.zig");
        \\pub fn realWork(context: anytype) void {
        \\    _ = context;
        \\}
        \\const fakes = @import("../../../testing/fakes/root.zig");
        \\test "exercises real work with fakes" {
        \\    var store = fakes.WorkspaceStore{};
        \\    _ = store.writeFile("x");
        \\    realWork(.{});
        \\}
    ;
    try std.testing.expect(try runGuardOnBytes("src/app/usecases/diagnostics/workflows.zig", idiom_src, &map));
}

test "S5 LOW-7 inert multiline-string and comment doc lines are not flagged" {
    var map = ModuleMap.empty(std.testing.allocator);
    defer map.deinit();

    // A domain doc comment that quotes forbidden tokens inside a `\\` multiline
    // string and inside `//` comments must not produce a false violation. The
    // pre-fix guard flagged the multiline lines (effect/ToolResult checks) and
    // mis-stripped the `//`-in-string line.
    const doc_src =
        \\const std = @import("std");
        \\
        \\/// Domain notes:
        \\///   mcp.tools.ToolResult is projected by the adapter, not here.
        \\///   std.process. calls belong behind a port.
        \\pub const doc =
        \\    \\ Example: mcp.tools.ToolResult and std.process.exit live elsewhere.
        \\    \\ See https://example.com/path // not a comment, inside the string.
        \\;
        \\pub fn note() void {}
    ;
    try std.testing.expect(try runGuardOnBytes("src/domain/notes.zig", doc_src, &map));

    // And a guard against regressions: a *real* effect on a code line is still
    // caught in the same domain file.
    const real_effect_src =
        \\const std = @import("std");
        \\pub fn note() void {
        \\    std.process.exit(0);
        \\}
    ;
    try std.testing.expect(!try runGuardOnBytes("src/domain/notes.zig", real_effect_src, &map));
}

test "S5 LOW-7 withoutLineComment is string-literal aware" {
    // A `//` inside a string literal is not a comment and must not truncate
    // (the `//` in the URL stays; the real trailing comment after `"; ` is cut).
    try std.testing.expectEqualStrings(
        "    const url = \"https://example.com/x\"; ",
        withoutLineComment("    const url = \"https://example.com/x\"; // trailing"),
    );
    // A real trailing comment is still stripped.
    try std.testing.expectEqualStrings(
        "    const x = 1; ",
        withoutLineComment("    const x = 1; // set x"),
    );
    // No comment: returned unchanged.
    try std.testing.expectEqualStrings(
        "    const x = 1;",
        withoutLineComment("    const x = 1;"),
    );
}

test "S5 MEDIUM-6 adapter-other wall and unclassified-layer fail-closed" {
    var map = ModuleMap.empty(std.testing.allocator);
    defer map.deinit();

    // A non-MCP adapter (CLI) importing infra crosses the boundary.
    const cli_src =
        \\const std = @import("std");
        \\const audit = @import("../../infra/observability/audit.zig");
        \\pub fn run() void {
        \\    _ = audit;
        \\}
    ;
    try std.testing.expect(!try runGuardOnBytes("src/adapters/cli/run.zig", cli_src, &map));

    // A non-MCP adapter reaching into the MCP adapter is cross-adapter coupling.
    const cross_src =
        \\const std = @import("std");
        \\const server = @import("../mcp/server.zig");
        \\pub fn run() void {
        \\    _ = server;
        \\}
    ;
    try std.testing.expect(!try runGuardOnBytes("src/adapters/cli/run.zig", cross_src, &map));

    // The adapters aggregator root may re-export the MCP adapter sub-root.
    const aggregator_src =
        \\pub const cli = @import("cli/root.zig");
        \\pub const mcp = @import("mcp/root.zig");
    ;
    try std.testing.expect(try runGuardOnBytes("src/adapters/root.zig", aggregator_src, &map));

    // An unclassified src/ directory is fail-closed.
    const util_src =
        \\const std = @import("std");
        \\pub fn helper() void {}
    ;
    try std.testing.expect(!try runGuardOnBytes("src/util/helper.zig", util_src, &map));
}

test "S5 MEDIUM-6 production import cycle is detected, test-aggregation is not" {
    var map = ModuleMap.empty(std.testing.allocator);
    defer map.deinit();

    // Production back edge a.zig -> b.zig -> a.zig must be reported.
    {
        var graph = ImportGraph.init(std.testing.allocator);
        defer graph.deinit();
        const a_src =
            \\const b = @import("b.zig");
            \\pub const x = b;
        ;
        const b_src =
            \\const a = @import("a.zig");
            \\pub const y = a;
        ;
        _ = try checkFileBytes(std.testing.allocator, test_io, "src/domain/a.zig", a_src, &map, &graph);
        _ = try checkFileBytes(std.testing.allocator, test_io, "src/domain/b.zig", b_src, &map, &graph);
        try std.testing.expect(!try graph.reportCycles(test_io));
    }

    // The Zig test-aggregation idiom (a module's test block imports a test
    // aggregator that imports the module back) is NOT a production cycle.
    {
        var graph = ImportGraph.init(std.testing.allocator);
        defer graph.deinit();
        const mod_src =
            \\const types = @import("types.zig");
            \\pub const tooling = types;
            \\test {
            \\    _ = @import("all_tests.zig");
            \\}
        ;
        const all_tests_src =
            \\test {
            \\    _ = @import("invariants_tests.zig");
            \\}
        ;
        const invariants_src =
            \\const manifest = @import("mod.zig");
            \\test "x" {
            \\    _ = manifest;
            \\}
        ;
        _ = try checkFileBytes(std.testing.allocator, test_io, "src/manifest/mod.zig", mod_src, &map, &graph);
        _ = try checkFileBytes(std.testing.allocator, test_io, "src/manifest/all_tests.zig", all_tests_src, &map, &graph);
        _ = try checkFileBytes(std.testing.allocator, test_io, "src/manifest/invariants_tests.zig", invariants_src, &map, &graph);
        try std.testing.expect(try graph.reportCycles(test_io));
    }
}

// --- False-positive soundness self-tests (FP) ----------------------------
//
// These pin the two false-positive fixes against the real per-file pipeline.
// Each fixture FAILS on the pre-fix guard (which scanned `raw_line` with a
// naive `indexOf` for retired surfaces, and never recognized a trailing-region
// test-support struct) and PASSES after, while the matching control proves a
// genuine violation in the same family is still caught — so the fix removes the
// false positive without widening into a hole.

test "FP no-retired-surface skips a retired word inside a string literal but catches a code token" {
    var map = ModuleMap.empty(std.testing.allocator);
    defer map.deinit();

    // Mirrors src/app/usecases/environment/trust.zig:294,378: the retired word
    // `shim` appears only inside string-literal values that describe the LIVE
    // `@zigars/mcp` npm shim (a current feature). The pre-fix check scanned the
    // raw line with `std.mem.indexOf` and flagged it; the string-aware check
    // does not.
    const string_literal_src =
        \\const std = @import("std");
        \\pub fn manifest(obj: anytype) void {
        \\    obj.put("name", .{ .string = "npm_shim_downloads" });
        \\    obj.put("npm_shim", .{ .string = "The npm shim downloads zigars-checksums.txt and verifies the archive SHA-256." });
        \\}
    ;
    try std.testing.expect(try runGuardOnBytes("src/app/usecases/environment/trust.zig", string_literal_src, &map));

    // A `//` comment that mentions the retired word is likewise inert (the
    // caller passes the comment-stripped line).
    const comment_src =
        \\const std = @import("std");
        \\pub fn manifest() void {} // documents the npm shim download flow
    ;
    try std.testing.expect(try runGuardOnBytes("src/app/usecases/environment/trust.zig", comment_src, &map));

    // Control: the SAME retired word as a bare code token (an identifier) is
    // still a retired surface and is caught — the fix narrows to string/comment
    // context only, it does not stop flagging retired code.
    const code_token_src =
        \\const std = @import("std");
        \\pub fn shimBridge() void {}
    ;
    try std.testing.expect(!try runGuardOnBytes("src/app/usecases/environment/trust.zig", code_token_src, &map));
}

test "FP trailing-region test-support struct is exempt while a real production effect stays caught" {
    var map = ModuleMap.empty(std.testing.allocator);
    defer map.deinit();

    // Mirrors src/adapters/mcp/resources.zig: a top-level `test { … }` block and
    // a trailing test-support `@import`, then a module-scope `*TestProvider`
    // struct whose body touches the forbidden `context.workspace_store` effect.
    // The struct is test scaffolding declared in the trailing test region, so it
    // is exempt. The pre-fix guard (no trailing-region recognition) flagged the
    // struct line as an MCP-adapter business effect.
    const test_support_struct_src =
        \\const std = @import("std");
        \\const mcp = @import("mcp");
        \\const app_context = @import("../../app/context.zig");
        \\pub fn registerResources(server: anytype) !void {
        \\    _ = server;
        \\}
        \\test {
        \\    _ = registerResources;
        \\}
        \\const test_fakes = @import("../../testing/fakes/root.zig");
        \\const ResourceTestProvider = struct {
        \\    context: app_context.RuntimeUxContext,
        \\    fn artifactContext(self: *ResourceTestProvider) app_context.ArtifactContext {
        \\        return .{ .workspace_store = self.context.workspace_store };
        \\    }
        \\};
    ;
    try std.testing.expect(try runGuardOnBytes("src/adapters/mcp/resources.zig", test_support_struct_src, &map));

    // Control: the SAME effect inside a real production function declared BEFORE
    // any test block is a genuine MCP-adapter business effect and stays flagged
    // (resources.zig:289,299 in the live tree). This proves the trailing-region
    // exemption is scoped to the test-support declaration and never latches the
    // file, so production effects remain caught.
    const production_effect_src =
        \\const std = @import("std");
        \\const mcp = @import("mcp");
        \\pub fn artifactResource(context: anytype) !void {
        \\    const resolved = try context.workspace_store.resolve(.{});
        \\    _ = resolved;
        \\}
    ;
    try std.testing.expect(!try runGuardOnBytes("src/adapters/mcp/resources.zig", production_effect_src, &map));

    // No-latch guard: a production effect BEFORE the test block must still be
    // caught even though a trailing-region test-support struct follows it in the
    // same file — the exemption must not reach back over the production code.
    const production_then_struct_src =
        \\const std = @import("std");
        \\const app_context = @import("../../app/context.zig");
        \\pub fn artifactResource(context: anytype) !void {
        \\    const resolved = try context.workspace_store.resolve(.{});
        \\    _ = resolved;
        \\}
        \\test {
        \\    _ = artifactResource;
        \\}
        \\const ResourceTestProvider = struct {
        \\    context: app_context.RuntimeUxContext,
        \\    fn ctx(self: *ResourceTestProvider) void {
        \\        _ = self.context.workspace_store;
        \\    }
        \\};
    ;
    try std.testing.expect(!try runGuardOnBytes("src/adapters/mcp/resources.zig", production_then_struct_src, &map));
}

test "FP trailing-region helpers classify declarations precisely" {
    // The string-aware token scan: code occurrence reports, pure string
    // occurrence does not, and a code occurrence still wins when both appear.
    try std.testing.expect(containsTokenInCode("pub fn shimBridge() void {}", "shim"));
    try std.testing.expect(!containsTokenInCode("    .string = \"npm shim downloads\",", "shim"));
    try std.testing.expect(containsTokenInCode("shim_path = \"value with shim inside\";", "shim"));

    // Trailing region anchors only on a real top-level test block.
    const with_test =
        \\const std = @import("std");
        \\pub fn work() void {}
        \\test {
        \\    _ = work;
        \\}
        \\const HelperTestProvider = struct {};
    ;
    try std.testing.expectEqual(@as(usize, 3), firstTopLevelTestBlockLine(with_test));
    const no_test =
        \\const std = @import("std");
        \\pub fn work() void {}
    ;
    try std.testing.expectEqual(@as(usize, 0), firstTopLevelTestBlockLine(no_test));
    try std.testing.expect(inTrailingTestRegion(4, 3));
    try std.testing.expect(!inTrailingTestRegion(3, 3));
    try std.testing.expect(!inTrailingTestRegion(5, 0));

    // Test-support naming: a `*Test*` declaration is recognized, a plain
    // production declaration is not.
    try std.testing.expect(isTestSupportNamedDeclStart("const ResourceTestProvider = struct {"));
    try std.testing.expect(isTestSupportNamedDeclStart("fn resourceTestContext() void {"));
    try std.testing.expect(!isTestSupportNamedDeclStart("pub fn artifactResource(context: anytype) !void {"));
    try std.testing.expect(!isTestSupportNamedDeclStart("pub fn sneaky() void {"));
    try std.testing.expect(!isTestSupportNamedDeclStart("    .workspace_store = self.context.workspace_store,"));
    try std.testing.expectEqualStrings("ResourceTestProvider", moduleScopeDeclName("const ResourceTestProvider = struct {").?);
    try std.testing.expectEqualStrings("artifactResource", moduleScopeDeclName("pub fn artifactResource(context: anytype) !void {").?);
}
