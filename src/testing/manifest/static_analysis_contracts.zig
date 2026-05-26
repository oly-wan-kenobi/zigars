const std = @import("std");

const contracts = @import("../../domain/zig/static_analysis_contracts.zig");
const tool_manifest = @import("../../manifest/mod.zig");

fn isStaticAnalysisProductGroup(group: tool_manifest.ToolGroup) bool {
    return group == .static_analysis or group == .zwanzig;
}

test "every static analysis product manifest entry has tier and confidence contract" {
    for (tool_manifest.entries) |entry| {
        if (!isStaticAnalysisProductGroup(entry.group)) continue;
        const tier = entry.static_analysis_tier orelse return error.MissingStaticAnalysisTier;
        const contract = contracts.forTool(entry.name) orelse return error.MissingStaticAnalysisContract;
        try std.testing.expectEqualStrings(@tagName(tier), contracts.capabilityTierName(contract.tier));
        try std.testing.expect(contract.analysis_kind.len > 0);
        try std.testing.expect(contract.source_coverage.len > 0);
        try std.testing.expect(contract.limitations.len > 0);
        try std.testing.expect(contract.verify_with.len > 0);
    }
}

test "static analysis source writes are explicit apply-gated exceptions" {
    for (tool_manifest.entries) |entry| {
        if (entry.group != .static_analysis) continue;
        if (!entry.risk.writes_source) {
            try std.testing.expect(entry.meta.read_only);
            continue;
        }
        try std.testing.expect(!entry.meta.read_only);
        try std.testing.expect(entry.risk.writes_require_apply);
        try std.testing.expect(entry.risk.preview_by_default);
    }
}

test "static analysis contracts do not overstate evidence maturity" {
    for (contracts.contracts) |contract| try expectContractEvidenceBounded(contract);
}

fn expectContractEvidenceBounded(contract: contracts.Contract) !void {
    switch (contract.tier) {
        .advisory_orientation => {
            try std.testing.expect(contract.confidence != .high);
            try std.testing.expect(contract.classification != .release_gating_candidate);
            const entry = tool_manifest.findEntry(contract.tool).?;
            try std.testing.expect(!contains(entry.meta.description, "release-gating"));
            try std.testing.expect(!contains(entry.meta.description, "release gating"));
            try std.testing.expect(!contains(entry.meta.description, "high confidence"));
        },
        .parser_backed => {
            try std.testing.expectEqual(contracts.Confidence.high, contract.confidence);
            try std.testing.expectEqual(contracts.Classification.advisory, contract.classification);
            try std.testing.expect(contains(contract.analysis_kind, "parser_backed"));
            try std.testing.expect(contains(contract.source_coverage, "std.zig.Ast"));
            try std.testing.expect(contains(contract.source_coverage, "parse_status"));
            try std.testing.expect(contains(contract.source_coverage, "partial_result"));
            try std.testing.expect(contains(contract.source_coverage, "parse_error_count"));
            try std.testing.expect(anyContains(contract.limitations, "Parse errors"));
            try std.testing.expect(contract.verify_with.len > 0);
            try std.testing.expect(contains(contract.verify_with[0], "zig ast-check"));
        },
        .compiler_backed => {
            try std.testing.expect(contains(contract.source_coverage, "Compiler") or contains(contract.source_coverage, "compiler"));
            try std.testing.expect(anyContains(contract.limitations, "compiler") or anyContains(contract.limitations, "test output"));
        },
        .zls_backed => {
            try std.testing.expect(contains(contract.source_coverage, "ZLS") or anyContains(contract.verify_with, "ZLS"));
        },
        .zlint_backed => {
            try std.testing.expect(contains(contract.source_coverage, "ZLint"));
            try std.testing.expect(anyContains(contract.limitations, "optional configured ZLint"));
            try std.testing.expect(contract.verify_with.len > 0);
            try std.testing.expect(contains(contract.verify_with[0], "configured ZLint"));
        },
        .zwanzig_backed => {
            try std.testing.expect(contains(contract.source_coverage, "zwanzig"));
            try std.testing.expect(anyContains(contract.limitations, "optional configured zwanzig"));
            try std.testing.expect(contract.verify_with.len > 0);
            try std.testing.expect(contains(contract.verify_with[0], "configured zwanzig"));
        },
    }
}

test "release-gating static analysis claims require executable-backed evidence" {
    for (contracts.contracts) |contract| {
        if (contract.classification != .release_gating_candidate) continue;
        try std.testing.expect(releaseGateTierAllowed(contract.tier));
        const entry = tool_manifest.findEntry(contract.tool).?;
        try std.testing.expect(entry.risk.executes_backend or entry.risk.executes_project_code);
        try std.testing.expectEqual(contracts.Confidence.high, contract.confidence);
        try std.testing.expect(contract.verify_with.len > 0);
        try std.testing.expect(contains(contract.source_coverage, "output") or contains(contract.source_coverage, "Compiler") or contains(contract.source_coverage, "ZLint") or contains(contract.source_coverage, "zwanzig"));
    }
}

fn releaseGateTierAllowed(tier: contracts.CapabilityTier) bool {
    return switch (tier) {
        .compiler_backed, .zlint_backed, .zwanzig_backed => true,
        else => false,
    };
}

test "static analysis contract checks cover unsupported helper branches" {
    try expectContractEvidenceBounded(.{
        .tool = "zig_hover",
        .analysis_kind = "zls",
        .tier = .zls_backed,
        .confidence = .medium,
        .classification = .advisory,
        .source_coverage = "ZLS response",
        .limitations = &.{"requires ZLS"},
        .verify_with = &.{},
    });
    try std.testing.expect(!releaseGateTierAllowed(.advisory_orientation));
    try std.testing.expect(!anyContains(&.{"parser"}, "ZLS"));
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn anyContains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (contains(value, needle)) return true;
    }
    return false;
}
