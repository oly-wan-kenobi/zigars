const std = @import("std");

const static_analysis_contracts = @import("static_analysis_contracts.zig");

test "static analysis metadata exposes structured evidence and cross-checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (static_analysis_contracts.contracts) |contract| {
        var obj = std.json.ObjectMap.empty;
        try static_analysis_contracts.putMetadata(allocator, &obj, contract.tool);
        const evidence = obj.get("evidence_basis").?.object;
        const cross_check = obj.get("cross_check").?.object;
        try std.testing.expectEqualStrings(contract.analysis_kind, evidence.get("analysis_kind").?.string);
        try std.testing.expectEqualStrings(static_analysis_contracts.capabilityTierName(contract.tier), evidence.get("capability_tier").?.string);
        try std.testing.expectEqualStrings(static_analysis_contracts.confidenceName(contract.confidence), evidence.get("confidence").?.string);
        try std.testing.expectEqualStrings(static_analysis_contracts.classificationName(contract.classification), evidence.get("confidence_class").?.string);
        try std.testing.expect(evidence.get("limitations").?.array.items.len > 0);
        try std.testing.expect(cross_check.get("verify_with").?.array.items.len > 0);
        try std.testing.expectEqual(contract.classification == .release_gating_candidate, cross_check.get("required_for_release_gate").?.bool);
        try std.testing.expectEqualStrings(contract.verify_with[0], cross_check.get("primary").?.string);
        try std.testing.expectEqualStrings(contract.verify_with[0], obj.get("recommended_cross_check").?.string);
    }
}
