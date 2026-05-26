const std = @import("std");
const architecture_guard = @import("architecture_guard.zig");
const cli_io = @import("cli_io.zig");
const coverage = @import("coverage.zig");
const dist = @import("dist.zig");
const backend_docs = @import("backend_docs.zig");
const backend_contract_scenarios = @import("backend_contract_scenarios.zig");
const fake_backends = @import("fake_backends.zig");
const http_adoption_smoke = @import("http_adoption_smoke.zig");
const http_performance_smoke = @import("http_performance_smoke.zig");
const http_phase6_smoke = @import("http_phase6_smoke.zig");
const http_runtime_ux_smoke = @import("http_runtime_ux_smoke.zig");
const http_smoke = @import("http_smoke.zig");
const http_diagnostics_smoke = @import("http_diagnostics_smoke.zig");
const http_transactional_editing_smoke = @import("http_transactional_editing_smoke.zig");
const http_validation_workflow_smoke = @import("http_validation_workflow_smoke.zig");
const hex_arch_inventory = @import("hex_arch_inventory.zig");
const json_query = @import("json_query.zig");
const json_util = @import("json_util.zig");
const mcp_contracts = @import("mcp_contracts.zig");
const public_claims = @import("public_claims.zig");
const public_contracts = @import("public_contracts.zig");
const release_docs = @import("release_docs.zig");
const release_checks = @import("release_checks.zig");
const release_rules = @import("release_rules.zig");
const release_targets = @import("release_targets.zig");
const smoke_support = @import("smoke_support.zig");
const stdio_adoption_fixtures = @import("stdio_adoption_fixtures.zig");
const stdio_environment_fixtures = @import("stdio_environment_fixtures.zig");
const stdio_fixtures = @import("stdio_fixtures.zig");
const stdio_runtime_ux_fixtures = @import("stdio_runtime_ux_fixtures.zig");
const stdio_transactional_editing_fixtures = @import("stdio_transactional_editing_fixtures.zig");
const stdio_validation_workflow_fixtures = @import("stdio_validation_workflow_fixtures.zig");
const tool_index = @import("tool_index.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const executableName = cli_io.executableName;
const failUsage = cli_io.failUsage;
const parseJsonFile = cli_io.parseJsonFile;
const reportInvalidArguments = cli_io.reportInvalidArguments;
const stderrPrint = cli_io.stderrPrint;

test {
    _ = architecture_guard;
    _ = backend_docs;
    _ = backend_contract_scenarios;
    _ = coverage;
    _ = cli_io;
    _ = dist;
    _ = fake_backends;
    _ = http_adoption_smoke;
    _ = http_smoke;
    _ = http_diagnostics_smoke;
    _ = http_performance_smoke;
    _ = http_phase6_smoke;
    _ = http_runtime_ux_smoke;
    _ = http_transactional_editing_smoke;
    _ = http_validation_workflow_smoke;
    _ = hex_arch_inventory;
    _ = json_query;
    _ = json_util;
    _ = mcp_contracts;
    _ = public_claims;
    _ = public_contracts;
    _ = release_docs;
    _ = release_checks;
    _ = release_rules;
    _ = release_targets;
    _ = smoke_support;
    _ = stdio_adoption_fixtures;
    _ = stdio_environment_fixtures;
    _ = stdio_fixtures;
    _ = stdio_runtime_ux_fixtures;
    _ = stdio_transactional_editing_fixtures;
    _ = stdio_validation_workflow_fixtures;
    _ = tool_index;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_arena_state = std.heap.ArenaAllocator.init(allocator);
    defer args_arena_state.deinit();
    const args_arena = args_arena_state.allocator();
    const args = try init.minimal.args.toSlice(args_arena);

    if (args.len > 0) {
        const invoked = executableName(args[0]);
        if (std.mem.startsWith(u8, invoked, "fake-zwanzig")) return release_checks.fakeZwanzig(io, args[1..]);
        if (std.mem.startsWith(u8, invoked, "fake-zlint")) return release_checks.fakeZlint(io, args[1..]);
        if (std.mem.startsWith(u8, invoked, "fake-zflame")) return release_checks.fakeZflame(io, args[1..]);
        if (std.mem.startsWith(u8, invoked, "fake-diff-folded")) return release_checks.fakeDiffFolded(io, args[1..]);
    }
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "fake-zwanzig")) return release_checks.fakeZwanzig(io, args[2..]);
        if (std.mem.eql(u8, args[1], "fake-zlint")) return release_checks.fakeZlint(io, args[2..]);
        if (std.mem.eql(u8, args[1], "fake-zflame")) return release_checks.fakeZflame(io, args[2..]);
        if (std.mem.eql(u8, args[1], "fake-diff-folded")) return release_checks.fakeDiffFolded(io, args[2..]);
    }

    if (args.len < 2) {
        try usage(io);
        return failUsage(io, "zigar-tools", "", "missing command", .{});
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "version")) {
        try dist.printVersion(io);
    } else if (std.mem.eql(u8, cmd, "generate-tool-index")) {
        tool_index.generate(allocator, io, args[2..]) catch |err| {
            return reportInvalidArguments(io, cmd, "generate-tool-index [--check]", err);
        };
    } else if (std.mem.eql(u8, cmd, "check-json")) {
        try checkJson(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, cmd, "http-smoke")) {
        try http_smoke.run(allocator, io, args[2..]);
    } else if (std.mem.eql(u8, cmd, "stdio-fixtures")) {
        try stdio_fixtures.run(allocator, io, args[0], args[2..]);
    } else if (std.mem.eql(u8, cmd, "coverage")) {
        coverage.run(allocator, io, args[0], args[2..]) catch |err| {
            return reportInvalidArguments(io, cmd, "coverage [--out-dir <path>] [--zig <path>] [--integration-binary <path>] [--min-tests <count>] [--no-build] [--require-kcov] [--allow-kcov-failure]", err);
        };
    } else if (std.mem.eql(u8, cmd, "dist")) {
        dist.buildArchives(allocator, io, args[2..]) catch |err| {
            return reportInvalidArguments(io, cmd, "dist --package <name> --exe <name> --binary <path>...", err);
        };
    } else if (std.mem.eql(u8, cmd, "dist-smoke")) {
        dist.smoke(allocator, io, args[2..]) catch |err| {
            return reportInvalidArguments(io, cmd, "dist-smoke [--assets-dir <path>] [--version <version>]", err);
        };
    } else if (std.mem.eql(u8, cmd, "artifact-hygiene")) {
        release_checks.artifactHygiene(allocator, io, args[2..]) catch |err| {
            return reportInvalidArguments(io, cmd, "artifact-hygiene", err);
        };
    } else if (std.mem.eql(u8, cmd, "public-contracts")) {
        public_contracts.run(allocator, io, args[2..]) catch |err| {
            return reportInvalidArguments(io, cmd, "public-contracts", err);
        };
    } else if (std.mem.eql(u8, cmd, "backend-contract-scenarios")) {
        backend_contract_scenarios.run(allocator, io, args[2..]) catch |err| {
            return reportInvalidArguments(io, cmd, "backend-contract-scenarios", err);
        };
    } else if (std.mem.eql(u8, cmd, "architecture-guard")) {
        architecture_guard.run(allocator, io, args[2..]) catch |err| {
            return reportInvalidArguments(io, cmd, "architecture-guard", err);
        };
    } else if (std.mem.eql(u8, cmd, "hex-architecture-inventory")) {
        hex_arch_inventory.run(allocator, io, args[2..]) catch |err| {
            return reportInvalidArguments(io, cmd, "hex-architecture-inventory [--strict-root-files]", err);
        };
    } else {
        try usage(io);
        return failUsage(io, "zigar-tools", "", "unknown command `{s}`", .{cmd});
    }
}

fn usage(io: Io) !void {
    try stderrPrint(io,
        \\usage: zigar-tools <command> [options]
        \\
        \\commands:
        \\  version
        \\  generate-tool-index [--check]
        \\  check-json <path>...
        \\  http-smoke [--binary <path>] [--workspace <path>] [--expect <path>]
        \\  stdio-fixtures [--binary <path>] [--zig-path <path>]
        \\  coverage [--out-dir <path>] [--zig <path>] [--integration-binary <path>] [--min-tests <count>] [--no-build] [--require-kcov] [--allow-kcov-failure]
        \\  dist --package <name> --exe <name> --binary <path>...
        \\  dist-smoke [--assets-dir <path>] [--version <version>]
        \\  artifact-hygiene
        \\  public-contracts
        \\  backend-contract-scenarios
        \\  architecture-guard
        \\  hex-architecture-inventory [--strict-root-files]
        \\
    , .{});
}

fn checkJson(allocator: Allocator, io: Io, args: []const []const u8) !void {
    if (args.len == 0) return failUsage(io, "check-json", "check-json <path>...", "expected at least one JSON path", .{});
    for (args) |path| {
        const parsed = try parseJsonFile(allocator, io, path);
        parsed.deinit();
    }
}

test "json util escapes JSON control characters" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try json_util.writeString(&out.writer, "a\"b\\c\n\t\x1b");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\t\\u001b\"", out.written());
}
