const std = @import("std");

const errors = @import("errors.zig");
const contracts = @import("result_contracts.zig");

test "result shape contract is typed data independent of renderer payloads" {
    const contract = contracts.describeResultShape(.{ .mode = .deep });

    try std.testing.expectEqualStrings("zigar_result_shape", contract.kind);
    try std.testing.expect(contract.ok);
    try std.testing.expectEqual(contracts.OutputMode.deep, contract.mode);
    try std.testing.expectEqual(contracts.OutputMode.standard, contract.default_mode);
    try std.testing.expectEqual(@as(usize, 3), contract.supported_modes.len);
    try std.testing.expectEqual(contracts.OutputMode.deep, contract.selected_mode_metadata.mode);
    try std.testing.expectEqualStrings("diagnostics", contract.result_shape.stable_machine_fields[9]);
    try std.testing.expectEqual(contracts.Confidence.high, contract.confidence);
    try std.testing.expect(!contract.ownsMemory());
}

test "output budget plan clamps typed request budgets" {
    const plan = contracts.planOutputBudget(.{
        .mode = .compact,
        .requested_token_budget = 12,
        .tool_name = "zig_check",
    });

    try std.testing.expectEqualStrings("zigar_output_budget_plan", plan.kind);
    try std.testing.expectEqual(contracts.OutputMode.compact, plan.mode);
    try std.testing.expectEqual(@as(i64, contracts.min_token_budget), plan.effective_token_budget);
    try std.testing.expect(plan.clamp_applied);
    try std.testing.expectEqualStrings("zig_check", plan.tool_name.?);
    try std.testing.expectEqual(@as(i64, 275), plan.allocation.machine_fields_tokens);
    try std.testing.expectEqualStrings("machine_fields", plan.allocation.priority_order[0]);
    try std.testing.expectEqual(contracts.Confidence.medium, plan.confidence);
    try std.testing.expect(!plan.ownsMemory());

    const standard = contracts.planOutputBudget(.{ .mode = .standard, .requested_token_budget = 4000 });
    try std.testing.expectEqualStrings("evidence", standard.allocation.priority_order[1]);
}

test "mode parsing returns a typed app error without raw argument payloads" {
    const parsed = contracts.parseOutputMode("verbose");
    try std.testing.expect(parsed.isErr());

    const err = parsed.err;
    try std.testing.expectEqual(errors.Category.argument, err.category);
    try std.testing.expectEqualStrings("mode", err.field.?);
    try std.testing.expectEqualStrings("compact, standard, or deep", err.expected.?);
    try std.testing.expectEqualStrings("verbose", err.actual.?);
}
