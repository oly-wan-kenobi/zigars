//! Release gate orchestrator: artifact hygiene, source hygiene, and contract checks.
//! Policy tables (budgets, forbidden tokens, error-contract paths) live in
//! release_rules.zig; domain-specific checks delegate to mcp_contracts.zig,
//! release_docs.zig, backend_docs.zig, and public_claims.zig.  This module
//! stays execution-focused and references policy by name rather than inlining it.
const std = @import("std");
const zigars = @import("zigars");
const release_docs = @import("release_docs.zig");
const mcp_contracts = @import("mcp_contracts.zig");
const public_claims = @import("public_claims.zig");
const backend_docs = @import("backend_docs.zig");
const fake_backends = @import("fake_backends.zig");
const release_rules = @import("release_rules.zig");
const skill_checks = @import("skill_checks.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const HygieneToken = release_rules.HygieneToken;
const ToolErrorContractToken = release_rules.ToolErrorContractToken;

const line_budgets = release_rules.line_budgets;
const forbidden_tokens = release_rules.forbidden_tokens;
const code_hygiene_tokens = release_rules.code_hygiene_tokens;
const ignored_error_hygiene_tokens = release_rules.ignored_error_hygiene_tokens;
const tool_error_contract_paths = release_rules.tool_error_contract_paths;
const tool_error_contract_tokens = release_rules.tool_error_contract_tokens;
const resource_error_contract_paths = release_rules.resource_error_contract_paths;
const resource_error_contract_tokens = release_rules.resource_error_contract_tokens;
const cli_error_contract_paths = release_rules.cli_error_contract_paths;
const cli_error_contract_tokens = release_rules.cli_error_contract_tokens;
const workflow_permission_rules = release_rules.workflow_permission_rules;
const pure_zig_roots = release_rules.pure_zig_roots;

/// Fake zwanzig executable entrypoint used by backend conformance smoke tests.
pub const fakeZwanzig = fake_backends.fakeZwanzig;
/// Fake ZLint executable entrypoint used by backend conformance smoke tests.
pub const fakeZlint = fake_backends.fakeZlint;
/// Fake zflame executable entrypoint used by backend conformance smoke tests.
pub const fakeZflame = fake_backends.fakeZflame;
/// Fake diff-folded executable entrypoint used by backend conformance smoke tests.
pub const fakeDiffFolded = fake_backends.fakeDiffFolded;

/// Runs all artifact, source hygiene, release-doc, and MCP contract gates.
pub fn artifactHygiene(allocator: Allocator, io: Io, args: []const []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (args.len != 0) return error.InvalidArguments;
    const generated = [_][]const u8{ "zig-out", ".zig-cache", "zig-pkg", ".zigars-cache", "coverage", "dist" };
    var ok = true;
    for (generated) |path| {
        const tracked = isGitTracked(io, path) catch |err| blk: {
            try stderrPrint(io, "generated artifact check could not query git tracking for {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            break :blk false;
        };
        if (tracked) {
            try stderrPrint(io, "generated artifact path is tracked: {s}\n", .{path});
            ok = false;
        }
        const exists = pathExists(io, path) catch |err| blk: {
            try stderrPrint(io, "generated artifact check could not inspect {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            break :blk false;
        };
        const ignored = isGitIgnored(io, path) catch |err| blk: {
            try stderrPrint(io, "generated artifact check could not query git ignore status for {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            break :blk false;
        };
        if (exists and !ignored) {
            try stderrPrint(io, "generated artifact path exists but is not ignored: {s}\n", .{path});
            ok = false;
        }
    }
    ok = (try checkLineBudgets(allocator, io)) and ok;
    ok = (try checkForbiddenTokens(allocator, io)) and ok;
    ok = (try checkToolErrorContract(allocator, io)) and ok;
    ok = (try checkResourceErrorContract(allocator, io)) and ok;
    ok = (try checkCliErrorContract(allocator, io)) and ok;
    ok = (try checkPureZigTrees(allocator, io)) and ok;
    ok = (try checkStaticAnalysisContracts(io)) and ok;
    ok = (try checkCatalogCommonIntentPreferences(allocator, io)) and ok;
    ok = (try skill_checks.checkSkillToolReferences(allocator, io)) and ok;
    ok = (try checkWorkflowPermissions(allocator, io)) and ok;
    ok = (try release_docs.checkStaticAnalysisDocs(allocator, io)) and ok;
    ok = (try backend_docs.checkOptionalBackendContracts(allocator, io)) and ok;
    ok = (try release_docs.checkCommandRunningToolDocs(allocator, io)) and ok;
    ok = (try public_claims.checkPublicClaimDocs(allocator, io)) and ok;
    ok = (try release_docs.checkAgentWorkflowDocs(allocator, io)) and ok;
    ok = (try release_docs.checkCiArtifactDocs(allocator, io)) and ok;
    ok = (try release_docs.checkDocsLookupDocs(allocator, io)) and ok;
    ok = (try release_docs.checkReleaseEvidenceDocs(allocator, io)) and ok;
    ok = (try release_docs.checkMaturityDocs(allocator, io)) and ok;
    ok = (try release_docs.checkTrustDocs(allocator, io)) and ok;
    ok = (try release_docs.checkFoundationContractDocs(allocator, io)) and ok;
    ok = (try release_docs.checkPublicAdoptionDocs(allocator, io)) and ok;
    ok = (try checkSecurityPolicy(allocator, io)) and ok;
    ok = (try mcp_contracts.checkNoPatchContract(allocator, io)) and ok;
    ok = (try mcp_contracts.checkAdvertisedCapabilityContract(allocator, io)) and ok;
    ok = (try mcp_contracts.checkPublicSurfaceContract(allocator, io)) and ok;
    ok = (try checkCodeHygiene(allocator, io)) and ok;
    if (!ok) return error.ArtifactHygieneFailed;
}

/// Reports whether git tracks `path`.
fn isGitTracked(io: Io, path: []const u8) !bool {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "git", "ls-files", "--error-unmatch", path },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Reports whether git ignore rules cover `path`.
fn isGitIgnored(io: Io, path: []const u8) !bool {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "git", "check-ignore", "-q", "--", path },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Reports whether `path` exists as an openable directory.
fn pathExists(io: Io, path: []const u8) !bool {
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    dir.close(io);
    return true;
}

/// Verifies required permissions blocks in release-related workflows.
fn checkWorkflowPermissions(allocator: Allocator, io: Io) !bool {
    // Fail fast on the first mismatch to keep diagnostics deterministic.
    var ok = true;
    for (workflow_permission_rules) |rule| {
        const bytes = readFileAlloc(allocator, io, rule.path, 1024 * 1024) catch |err| {
            try stderrPrint(io, "workflow-permissions check could not read {s}: {s}\n", .{ rule.path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        for (rule.required) |needle| {
            if (std.mem.indexOf(u8, bytes, needle) == null) {
                try stderrPrint(io, "workflow-permissions check missing `{s}` in {s}\n", .{ needle, rule.path });
                ok = false;
            }
        }
    }
    return ok;
}

/// Checks every file in `line_budgets` against its code-line limit and minimum
/// headroom.  Both an exceeded limit and insufficient headroom are failures so
/// files must be split before they approach the cap, not after.
fn checkLineBudgets(allocator: Allocator, io: Io) !bool {
    // Fail fast on the first mismatch to keep diagnostics deterministic.
    var ok = true;
    for (line_budgets) |budget| {
        const bytes = readFileAlloc(allocator, io, budget.path, 4 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "line-budget check could not read {s}: {s}\n", .{ budget.path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        const lines = codeLineCount(bytes);
        if (lines > budget.max_lines) {
            try stderrPrint(io, "line budget exceeded: {s} has {d} code lines, max {d} ({s})\n", .{ budget.path, lines, budget.max_lines, budget.reason });
            ok = false;
            continue;
        }
        const headroom = budget.max_lines - lines;
        const required_headroom = minLineBudgetHeadroom(budget.max_lines);
        if (headroom < required_headroom) {
            try stderrPrint(io, "line budget headroom too small: {s} has {d} code lines, max {d}, headroom {d}, required {d} ({s})\n", .{ budget.path, lines, budget.max_lines, headroom, required_headroom, budget.reason });
            ok = false;
        }
    }
    return ok;
}

/// Required headroom is 10 % of max_lines, clamped to [10, 50].
/// Small files need at least 10 free lines; large files cap at 50 so the
/// rule stays proportional without demanding huge buffers on very large files.
fn minLineBudgetHeadroom(max_lines: usize) usize {
    return @min(@as(usize, 50), @max(@as(usize, 10), max_lines / 10));
}

/// Checks repository files for high-risk forbidden text fragments.
fn checkForbiddenTokens(allocator: Allocator, io: Io) !bool {
    // Fail fast on the first mismatch to keep diagnostics deterministic.
    var ok = true;
    for (forbidden_tokens) |rule| {
        const bytes = readFileAlloc(allocator, io, rule.path, 8 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "forbidden-token check could not read {s}: {s}\n", .{ rule.path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, rule.token) != null) {
            try stderrPrint(io, "forbidden token in {s}: `{s}` ({s})\n", .{ rule.path, rule.token, rule.reason });
            ok = false;
        }
    }
    return ok;
}

/// Runs stale-code and ignored-error hygiene token checks.
fn checkCodeHygiene(allocator: Allocator, io: Io) !bool {
    var ok = true;
    ok = (try checkHygieneTokensAbsent(allocator, io, "stale-code", &code_hygiene_tokens)) and ok;
    ok = (try checkHygieneTokensAbsent(allocator, io, "ignored-error", &ignored_error_hygiene_tokens)) and ok;
    return ok;
}

/// Checks a named hygiene token table against its configured files.
fn checkHygieneTokensAbsent(allocator: Allocator, io: Io, check_name: []const u8, rules: []const HygieneToken) !bool {
    // Fail fast on the first mismatch to keep diagnostics deterministic.
    var ok = true;
    for (rules) |rule| {
        const bytes = readFileAlloc(allocator, io, rule.path, 8 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "{s} hygiene check could not read {s}: {s}\n", .{ check_name, rule.path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, rule.token) != null) {
            try stderrPrint(io, "{s} hygiene violation in {s}: `{s}` ({s})\n", .{ check_name, rule.path, rule.token, rule.reason });
            ok = false;
        }
    }
    return ok;
}

/// Verifies source files do not bypass structured tool-error construction.
fn checkToolErrorContract(allocator: Allocator, io: Io) !bool {
    // Fail fast on the first mismatch to keep diagnostics deterministic.
    var ok = true;
    for (tool_error_contract_paths) |path| {
        const bytes = readFileAlloc(allocator, io, path, 8 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "tool-error-contract check could not read {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        for (tool_error_contract_tokens) |rule| {
            if (std.mem.indexOf(u8, bytes, rule.token) != null) {
                try stderrPrint(io, "tool-error-contract violation in {s}: `{s}` ({s})\n", .{ path, rule.token, rule.reason });
                ok = false;
            }
        }
    }
    return ok;
}

/// Verifies resource handlers use structured resource-error construction.
fn checkResourceErrorContract(allocator: Allocator, io: Io) !bool {
    // Fail fast on the first mismatch to keep diagnostics deterministic.
    var ok = true;
    for (resource_error_contract_paths) |path| {
        const bytes = readFileAlloc(allocator, io, path, 8 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "resource-error-contract check could not read {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        for (resource_error_contract_tokens) |rule| {
            if (std.mem.indexOf(u8, bytes, rule.token) != null) {
                try stderrPrint(io, "resource-error-contract violation in {s}: `{s}` ({s})\n", .{ path, rule.token, rule.reason });
                ok = false;
            }
        }
    }
    return ok;
}

/// Verifies CLI-facing paths use centralized error reporting helpers.
fn checkCliErrorContract(allocator: Allocator, io: Io) !bool {
    // Fail fast on the first mismatch to keep diagnostics deterministic.
    var ok = true;
    for (cli_error_contract_paths) |path| {
        const bytes = readFileAlloc(allocator, io, path, 8 * 1024 * 1024) catch |err| {
            try stderrPrint(io, "cli-error-contract check could not read {s}: {s}\n", .{ path, @errorName(err) });
            ok = false;
            continue;
        };
        defer allocator.free(bytes);
        for (cli_error_contract_tokens) |rule| {
            if (std.mem.indexOf(u8, bytes, rule.token) != null) {
                try stderrPrint(io, "cli-error-contract violation in {s}: `{s}` ({s})\n", .{ path, rule.token, rule.reason });
                ok = false;
            }
        }
    }
    return ok;
}

/// Enforces the no-standalone-Python policy in pure Zig roots.
fn checkPureZigTrees(allocator: Allocator, io: Io) !bool {
    var ok = true;
    for (pure_zig_roots) |root| {
        ok = (try checkNoExtensionInTree(allocator, io, root, ".py")) and ok;
    }
    return ok;
}

/// Verifies that every static-analysis and zwanzig manifest entry has a
/// matching domain contract entry with consistent capability tier, non-empty
/// analysis fields, and appropriate confidence/classification constraints.
/// Advisory-tier tools must not claim high confidence or release-gating status;
/// parser-backed tools must expose parse-status fields; release-gating tools
/// must be compiler-, ZLint-, or zwanzig-backed.
fn checkStaticAnalysisContracts(io: Io) !bool {
    // Fail fast on the first mismatch to keep diagnostics deterministic.
    var ok = true;
    for (zigars.manifest.entries) |entry| {
        if (entry.group != .static_analysis and entry.group != .zwanzig) continue;
        const tier = entry.static_analysis_tier orelse {
            try stderrPrint(io, "static-analysis capability tier missing for tool: {s}\n", .{entry.name});
            ok = false;
            continue;
        };
        const contract = zigars.domain.zig.static_analysis_contracts.forTool(entry.name) orelse {
            try stderrPrint(io, "static-analysis contract missing for tool: {s}\n", .{entry.name});
            ok = false;
            continue;
        };
        const tier_name = @tagName(tier);
        if (!std.mem.eql(u8, tier_name, zigars.domain.zig.static_analysis_contracts.capabilityTierName(contract.tier))) {
            try stderrPrint(io, "static-analysis manifest tier disagrees with contract for tool: {s}\n", .{entry.name});
            ok = false;
        }
        if (contract.analysis_kind.len == 0 or contract.source_coverage.len == 0 or contract.limitations.len == 0 or contract.verify_with.len == 0) {
            try stderrPrint(io, "static-analysis contract incomplete for tool: {s}\n", .{entry.name});
            ok = false;
        }
        if (std.mem.eql(u8, tier_name, "advisory_orientation") and (contract.confidence == .high or contract.classification == .release_gating_candidate)) {
            try stderrPrint(io, "advisory static-analysis tool overclaims confidence or release-gating status: {s}\n", .{entry.name});
            ok = false;
        }
        if (std.mem.eql(u8, tier_name, "parser_backed") and
            (std.mem.indexOf(u8, contract.source_coverage, "parse_status") == null or
                std.mem.indexOf(u8, contract.source_coverage, "partial_result") == null or
                std.mem.indexOf(u8, contract.source_coverage, "parse_error_count") == null))
        {
            try stderrPrint(io, "parser-backed static-analysis contract must expose parse status and partial-result fields: {s}\n", .{entry.name});
            ok = false;
        }
        if (contract.classification == .release_gating_candidate and
            !std.mem.eql(u8, tier_name, "compiler_backed") and
            !std.mem.eql(u8, tier_name, "zlint_backed") and
            !std.mem.eql(u8, tier_name, "zwanzig_backed"))
        {
            try stderrPrint(io, "release-gating static-analysis tool must be compiler-backed, ZLint-backed, or zwanzig-backed: {s}\n", .{entry.name});
            ok = false;
        }
        if (entry.group == .zwanzig and !std.mem.eql(u8, tier_name, "zwanzig_backed")) {
            try stderrPrint(io, "zwanzig tool must use zwanzig_backed capability tier: {s}\n", .{entry.name});
            ok = false;
        }
        if (entry.group == .static_analysis and (!entry.meta.read_only or entry.risk.writes_source)) {
            if (!(entry.risk.writes_source and entry.risk.writes_require_apply and entry.risk.preview_by_default and !entry.meta.read_only)) {
                try stderrPrint(io, "static-analysis source writes must be explicit apply-gated previews: {s}\n", .{entry.name});
                ok = false;
            }
        }
    }
    return ok;
}

/// Verifies that every `common_intents` entry in the tool catalog has a
/// non-empty `prefer` string listing only known tool ids.  Unknown ids indicate
/// the catalog and the manifest have drifted.
fn checkCatalogCommonIntentPreferences(allocator: Allocator, io: Io) !bool {
    // Fail fast on the first mismatch to keep diagnostics deterministic.
    var catalog = zigars.manifest.tool_catalog_render.parsed(allocator) catch |err| {
        try stderrPrint(io, "tool catalog common-intent check could not parse catalog: {s}\n", .{@errorName(err)});
        return false;
    };
    defer catalog.deinit();

    const intents_value = catalog.value.object.get("common_intents") orelse {
        try stderrPrint(io, "tool catalog common-intent check missing common_intents\n", .{});
        return false;
    };
    if (intents_value != .array) {
        try stderrPrint(io, "tool catalog common-intent check expected common_intents array\n", .{});
        return false;
    }

    var ok = true;
    for (intents_value.array.items) |intent_value| {
        if (intent_value != .object) {
            try stderrPrint(io, "tool catalog common-intent entry is not an object\n", .{});
            ok = false;
            continue;
        }
        const intent = intent_value.object.get("intent").?.string;
        const prefer_value = intent_value.object.get("prefer") orelse {
            try stderrPrint(io, "tool catalog common-intent `{s}` is missing prefer\n", .{intent});
            ok = false;
            continue;
        };
        if (prefer_value != .string) {
            try stderrPrint(io, "tool catalog common-intent `{s}` has non-string prefer\n", .{intent});
            ok = false;
            continue;
        }
        var parts = std.mem.splitScalar(u8, prefer_value.string, ',');
        while (parts.next()) |raw_name| {
            const name = std.mem.trim(u8, raw_name, " \t\r\n");
            if (name.len == 0) {
                try stderrPrint(io, "tool catalog common-intent `{s}` contains an empty preferred tool id\n", .{intent});
                ok = false;
                continue;
            }
            if (zigars.manifest.find(name) == null) {
                try stderrPrint(io, "tool catalog common-intent `{s}` references unknown preferred tool id `{s}`\n", .{ intent, name });
                ok = false;
            }
        }
    }
    return ok;
}

/// Verifies SECURITY.md contains required disclosure and response terms.
fn checkSecurityPolicy(allocator: Allocator, io: Io) !bool {
    const path = "SECURITY.md";
    const bytes = readFileAlloc(allocator, io, path, 1024 * 1024) catch |err| {
        try stderrPrint(io, "security-policy check could not read {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer allocator.free(bytes);
    var ok = true;
    const required = [_][]const u8{
        "https://github.com/oly-wan-kenobi/zigars/security/advisories/new",
        "oliver.guenthardt@digitecgalaxus.ch",
        "acknowledge a private vulnerability report within 7 days",
        "initial triage assessment within 14 days",
    };
    for (required) |needle| {
        if (std.mem.indexOf(u8, bytes, needle) == null) {
            try stderrPrint(io, "security-policy check missing `{s}` in {s}\n", .{ needle, path });
            ok = false;
        }
    }
    return ok;
}

/// Recursively rejects tracked pure-Zig roots that contain files with `extension`.
pub fn checkNoExtensionInTree(allocator: Allocator, io: Io, root: []const u8, extension: []const u8) !bool {
    // Fail fast on the first mismatch to keep diagnostics deterministic.
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var ok = true;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, extension)) continue;
        try stderrPrint(io, "pure Zig hygiene rejected {s}/{s}: Python files do not belong in the pure-Zig project roots (.github, docs, examples, scripts, src, tests, tools); the npm packages/ tree is JS/TS by design and is intentionally out of scope\n", .{ root, entry.path });
        ok = false;
    }
    return ok;
}

/// Reads a repository-relative file with a byte limit.
fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8, limit: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

/// Counts source lines of code, excluding blank lines and whole-line comments
/// (`//`, `///`, and `//!`).  Line budgets bound how much code a reviewer must
/// audit, so documentation and comments must never count against a budget:
/// adding explanatory docs should improve auditability, not incur a penalty.
/// A code line with a trailing comment still counts as code.  Zig has only
/// line comments, so a trimmed line starting with `//` is wholly a comment,
/// while multi-line string content (`\\`-prefixed) is code and is counted.
fn codeLineCount(bytes: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        count += 1;
    }
    return count;
}

/// Writes a formatted diagnostic to stderr.
fn stderrPrint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writer(io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

test "codeLineCount ignores blank lines and whole-line comments" {
    // Pure code matches a naive newline count for these baseline cases.
    try std.testing.expectEqual(@as(usize, 0), codeLineCount(""));
    try std.testing.expectEqual(@as(usize, 1), codeLineCount("one"));
    try std.testing.expectEqual(@as(usize, 1), codeLineCount("one\n"));
    try std.testing.expectEqual(@as(usize, 2), codeLineCount("one\ntwo"));
    try std.testing.expectEqual(@as(usize, 2), codeLineCount("one\ntwo\n"));
    // Blank and whitespace-only lines never count.
    try std.testing.expectEqual(@as(usize, 2), codeLineCount("one\n\n  \t\ntwo\n"));
    // Whole-line comments never count, including /// and //! doc comments.
    try std.testing.expectEqual(@as(usize, 0), codeLineCount("// a\n/// b\n//! c\n"));
    try std.testing.expectEqual(@as(usize, 1), codeLineCount("    // indented\n    return;\n"));
    // Code followed by a trailing comment is still one code line.
    try std.testing.expectEqual(@as(usize, 1), codeLineCount("const x = 1; // set x\n"));
    // Multi-line string content (\\-prefixed) is code even when it embeds `//`.
    try std.testing.expectEqual(@as(usize, 2), codeLineCount("const s =\n    \\\\ http://x\n"));
}

test "line budget headroom scales for small and large files" {
    // Pull in the split-out pure-Zig-gate tests so they run with this suite.
    _ = @import("release_checks_tests.zig");
    try std.testing.expectEqual(@as(usize, 10), minLineBudgetHeadroom(80));
    try std.testing.expectEqual(@as(usize, 18), minLineBudgetHeadroom(180));
    try std.testing.expectEqual(@as(usize, 50), minLineBudgetHeadroom(800));
}
