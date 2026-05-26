const std = @import("std");
const cli_io = @import("../common/cli_io.zig");
const scenario_manifest = @import("backend_contract_scenarios_manifest");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const contract_script_path = ".github/scripts/backend-conformance.sh";
const smoke_script_path = ".github/scripts/backend-conformance-contract-smoke.sh";
const docs_path = "tests/integration/backend-contract/SCENARIOS.md";
const scenario_call_token = "add_tool_scenario(\n    \"";

pub fn run(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len != 0) return error.InvalidArguments;
    if (!(try check(allocator, io))) return error.BackendContractScenarioDrift;
    try cli_io.stdoutWrite(io, "backend contract scenarios ok\n");
}

pub fn check(allocator: Allocator, io: Io) !bool {
    const contract_script = (try readContractFile(allocator, io, contract_script_path)) orelse return false;
    defer allocator.free(contract_script);
    const smoke_script = (try readContractFile(allocator, io, smoke_script_path)) orelse return false;
    defer allocator.free(smoke_script);
    const docs = (try readContractFile(allocator, io, docs_path)) orelse return false;
    defer allocator.free(docs);

    var ok = true;
    ok = (try checkScenarioDefinitions(io, contract_script)) and ok;
    ok = (try checkSmokeRequiredTuple(io, smoke_script)) and ok;
    ok = (try checkScenarioDocs(io, docs)) and ok;
    return ok;
}

fn readContractFile(allocator: Allocator, io: Io, path: []const u8) !?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| {
        try cli_io.stderrPrint(io, "backend contract scenario check could not read {s}: {s}\n", .{ path, @errorName(err) });
        return null;
    };
}

fn checkScenarioDefinitions(io: Io, script: []const u8) !bool {
    var ok = try checkScenarioTokens(io, "backend contract scenario definition", contract_script_path, script);
    const count = countOccurrences(script, scenario_call_token);
    if (count != scenario_manifest.all.len) {
        try cli_io.stderrPrint(io, "backend contract scenario definition count mismatch: expected {d}, got {d}\n", .{ scenario_manifest.all.len, count });
        ok = false;
    }
    return ok;
}

fn checkSmokeRequiredTuple(io: Io, script: []const u8) !bool {
    const tuple = requiredScenarioTuple(script) orelse {
        try cli_io.stderrPrint(io, "backend contract smoke script is missing required_scenarios tuple\n", .{});
        return false;
    };
    var ok = try checkScenarioTokens(io, "backend contract smoke required scenario", smoke_script_path, tuple);
    const count = countQuotedLines(tuple);
    if (count != scenario_manifest.all.len) {
        try cli_io.stderrPrint(io, "backend contract smoke required_scenarios count mismatch: expected {d}, got {d}\n", .{ scenario_manifest.all.len, count });
        ok = false;
    }
    return ok;
}

fn checkScenarioDocs(io: Io, docs: []const u8) !bool {
    return checkScenarioTokens(io, "backend contract scenario docs", docs_path, docs);
}

fn checkScenarioTokens(io: Io, label: []const u8, path: []const u8, haystack: []const u8) !bool {
    var ok = true;
    for (scenario_manifest.all) |scenario| {
        if (std.mem.indexOf(u8, haystack, scenario.name) == null) {
            try cli_io.stderrPrint(io, "{s} missing `{s}` in {s}\n", .{ label, scenario.name, path });
            ok = false;
        }
    }
    return ok;
}

fn requiredScenarioTuple(script: []const u8) ?[]const u8 {
    const start_token = "required_scenarios = (\n";
    const start = (std.mem.indexOf(u8, script, start_token) orelse return null) + start_token.len;
    const end = std.mem.indexOfPos(u8, script, start, "\n)") orelse return null;
    return script[start..end];
}

fn countOccurrences(text: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, needle)) |index| {
        count += 1;
        start = index + needle.len;
    }
    return count;
}

fn countQuotedLines(text: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r,");
        if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') count += 1;
    }
    return count;
}

test "backend contract scenario drift check passes against repository files" {
    try std.testing.expect(try check(std.testing.allocator, std.testing.io));
}

test "backend contract scenario helpers detect drift" {
    try std.testing.expectEqual(@as(usize, 2), countOccurrences("add_tool_scenario(\n    \"a\"\nadd_tool_scenario(\n    \"b\"", scenario_call_token));
    try std.testing.expectEqual(@as(usize, 2), countQuotedLines("    \"a\",\n    \"b\",\nnot a scenario"));
    try std.testing.expectEqualStrings("    \"zls_document_symbols\",", requiredScenarioTuple("required_scenarios = (\n    \"zls_document_symbols\",\n)\n").?);
    try std.testing.expect(requiredScenarioTuple("no tuple here") == null);
    try std.testing.expect(!try checkScenarioDefinitions(std.testing.io, "add_tool_scenario(\n    \"zls_document_symbols\""));
    try std.testing.expect(!try checkSmokeRequiredTuple(std.testing.io, "required_scenarios = (\n    \"zls_document_symbols\",\n)\n"));
    try std.testing.expect(!try checkSmokeRequiredTuple(std.testing.io, "missing tuple"));
    try std.testing.expect(!try checkScenarioDocs(std.testing.io, "zls_document_symbols"));
    const missing = try readContractFile(std.testing.allocator, std.testing.io, "tests/integration/backend-contract/not-a-file");
    try std.testing.expect(missing == null);
}
