const std = @import("std");
const zigar = @import("zigar");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn checkNoPatchContract(allocator: Allocator, io: Io) !bool {
    var ok = true;
    for ([_][]const u8{ "build.zig", "build.zig.zon" }) |path| {
        ok = (try checkAbsent(allocator, io, "MCP no-patch contract", path, &.{ "third_party/mcp_zigar_patch", "mcp_upstream", "addMcpModule" })) and ok;
    }
    ok = (try checkPresent(allocator, io, "MCP no-patch contract", "src/mcp_server.zig", &.{ "First-party MCP server adapter", "pinned upstream MCP dependency", "ToolResultDeinit", "ResourceContentDeinit", "PromptMessagesDeinit", "deinit_result", "addResourceWithDeinit", "addPromptWithDeinit" })) and ok;
    return ok;
}

pub fn checkAdvertisedCapabilityContract(allocator: Allocator, io: Io) !bool {
    var ok = true;
    ok = (try checkAbsent(allocator, io, "MCP advertised-capability contract", "src/main.zig", &.{"enableTasks("})) and ok;
    ok = (try checkAbsent(allocator, io, "MCP advertised-capability contract", "src/mcp_server.zig", &.{ "capabilities.tasks", "handleTasks" })) and ok;
    ok = (try checkAbsent(allocator, io, "MCP advertised-capability contract", "docs/architecture.md", &.{"empty task-list"})) and ok;
    return ok;
}

pub fn checkPublicSurfaceContract(allocator: Allocator, io: Io) !bool {
    var ok = true;
    inline for (zigar.tool_manifest.entries) |entry| {
        ok = (try checkToolContract(allocator, io, entry)) and ok;
    }
    ok = (try checkPresent(allocator, io, "MCP tool discovery contract", "src/server.zig", &.{ "inline for (tool_metadata.specs)", "tool_registry.addTool" })) and ok;
    ok = (try checkPresent(allocator, io, "MCP resource/prompt contract fixture", "tests/fixtures/mcp-contracts.expect.json", &.{ "\"resources\"", "\"resource_templates\"", "\"prompts\"", "\"report_kinds\"" })) and ok;
    ok = (try checkPresent(allocator, io, "MCP resource/prompt contract", "src/server.zig", &.{ "zigar://workspace", "zigar://zls/status", "zigar://tools/capabilities", "zigar://tools/schema", "zigar://workspace/import-graph", "zigar://metrics", "zigar://file/{path}/symbols", "zigar://file/{path}/diagnostics", "zigar://file/{path}/imports", "zigar_profile_workflow" })) and ok;
    ok = (try checkPresent(allocator, io, "MCP resource/prompt routing contract", "src/mcp_server.zig", &.{ "resources/list", "resources/read", "resources/templates/list", "Resource not found", "prompts/list", "prompts/get", "Prompt not found", "createInvalidParams", "deinit_content", "deinit_messages" })) and ok;
    ok = (try checkPresent(allocator, io, "backend conformance report contract", ".github/scripts/backend-conformance.sh", &.{ "\"kind\": \"zigar_backend_conformance_report\"", "\"schema_version\": 2", "\"source_commit\"", "\"claimed_backends\"", "\"compatibility_matrix\"", "\"tool_evidence\"", "\"artifacts\"", "profile.svg", "diff.svg", "validate_svg_artifact", "ET.parse(path).getroot()" })) and ok;
    ok = (try checkPresent(allocator, io, "release-readiness report contract", ".github/scripts/release-readiness.sh", &.{ "\"kind\": \"zigar_release_readiness_report\"", "\"schema_version\": 2", "\"source_tree_clean\"", "\"backend_conformance\"", "\"zls_conformance\"", "\"subreport_commits\"", "\"compatibility_matrix\"" })) and ok;
    ok = (try checkPresent(allocator, io, "real-ZLS report contract", ".github/scripts/real-zls-conformance.sh", &.{ "\"kind\": \"zigar_real_zls_conformance_report\"", "\"schema_version\": 2", "\"source_commit\"", "\"backends\"", "\"scenarios\"", "\"response_count\"" })) and ok;
    return ok;
}

fn checkToolContract(allocator: Allocator, io: Io, comptime entry: zigar.tool_manifest.ToolEntry) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ok = true;
    const schema = try zigar.tooling.buildInputSchema(a, entry.meta.input_schema);
    if (schema.properties == null) ok = (try missingTool(io, entry.name, "schema properties object")) and ok;
    var required_count: usize = 0;
    for (entry.meta.input_schema.fields) |field| {
        if (schema.properties == null or schema.properties.?.object.get(field[0]) == null) ok = (try missingTool(io, entry.name, field[0])) and ok;
        if (field[2]) required_count += 1;
    }
    const actual_required = if (schema.required) |required| required.len else 0;
    if (actual_required != required_count) ok = (try missingTool(io, entry.name, "required-field schema count")) and ok;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "__zigar_contract_probe", .{ .bool = true });
    const invalid = (try zigar.tool_registry.validateToolArgs(a, entry.meta, .{ .object = obj })) orelse {
        return missingTool(io, entry.name, "structured invalid-input result");
    };
    if (!toolErrorHas(invalid, entry.name, "unknown_argument")) ok = (try missingTool(io, entry.name, "structured invalid-input fields")) and ok;
    if (entry.risk.writes_source and !hasField(entry, "apply")) ok = (try missingTool(io, entry.name, "apply gate for source writes")) and ok;
    if ((entry.risk.writes_artifacts or entry.risk.executes_backend) and std.mem.eql(u8, zigar.tool_manifest.planKind(entry.plan), "not_plannable")) ok = (try missingTool(io, entry.name, "success/unavailable or artifact plan")) and ok;
    return ok;
}

fn toolErrorHas(result: anytype, tool: []const u8, code: []const u8) bool {
    const sc = result.structuredContent orelse return false;
    if (!result.is_error or sc != .object) return false;
    const obj = sc.object;
    return stringField(obj, "kind", "argument_error") and stringField(obj, "tool", tool) and stringField(obj, "code", code);
}

fn stringField(obj: std.json.ObjectMap, name: []const u8, expected: []const u8) bool {
    const value = obj.get(name) orelse return false;
    return value == .string and std.mem.eql(u8, value.string, expected);
}

fn hasField(comptime entry: zigar.tool_manifest.ToolEntry, name: []const u8) bool {
    for (entry.meta.input_schema.fields) |field| {
        if (std.mem.eql(u8, field[0], name)) return true;
    }
    return false;
}

fn missingTool(io: Io, tool: []const u8, missing: []const u8) !bool {
    try stderrPrint(io, "MCP tool contract missing for {s}: {s}\n", .{ tool, missing });
    return false;
}

fn checkPresent(allocator: Allocator, io: Io, label: []const u8, path: []const u8, tokens: []const []const u8) !bool {
    const bytes = readFileAlloc(allocator, io, path, 4 * 1024 * 1024) catch |err| {
        try stderrPrint(io, "{s} could not read {s}: {s}\n", .{ label, path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    var ok = true;
    for (tokens) |token| {
        if (std.mem.indexOf(u8, bytes, token) == null) {
            try stderrPrint(io, "{s} missing `{s}` in {s}\n", .{ label, token, path });
            ok = false;
        }
    }
    return ok;
}

fn checkAbsent(allocator: Allocator, io: Io, label: []const u8, path: []const u8, tokens: []const []const u8) !bool {
    const bytes = readFileAlloc(allocator, io, path, 4 * 1024 * 1024) catch |err| {
        try stderrPrint(io, "{s} could not read {s}: {s}\n", .{ label, path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    var ok = true;
    for (tokens) |token| {
        if (std.mem.indexOf(u8, bytes, token) != null) {
            try stderrPrint(io, "{s} found forbidden `{s}` in {s}\n", .{ label, token, path });
            ok = false;
        }
    }
    return ok;
}

fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, limit: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}
