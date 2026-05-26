const std = @import("std");
const mcp = @import("mcp");

const result_contracts = @import("../../../app/result_contracts.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

pub fn zigarResultShape(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode = parseModeArg(args) catch {
        const actual = argString(args, "mode") orelse "";
        return mcp_errors.invalidArgument(
            allocator,
            "zigar_result_shape",
            "mode",
            result_contracts.supportedModesText(),
            actual,
            "Choose compact for routing, standard for normal agent use, or deep for expanded evidence.",
        );
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try resultShapeContractValue(
        arena.allocator(),
        result_contracts.describeResultShape(.{ .mode = mode }),
    );
    return mcp_result.structured(allocator, value);
}

pub fn zigarOutputBudgetPlan(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode = parseModeArg(args) catch {
        const actual = argString(args, "mode") orelse "";
        return mcp_errors.invalidArgument(
            allocator,
            "zigar_output_budget_plan",
            "mode",
            result_contracts.supportedModesText(),
            actual,
            "Choose compact, standard, or deep before asking for an output budget plan.",
        );
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try outputBudgetPlanValue(
        arena.allocator(),
        result_contracts.planOutputBudget(.{
            .mode = mode,
            .requested_token_budget = optionalIntegerArg(args, "token_budget"),
            .tool_name = argString(args, "tool"),
        }),
    );
    return mcp_result.structured(allocator, value);
}

fn parseModeArg(args: ?std.json.Value) error{InvalidMode}!result_contracts.OutputMode {
    const raw = argString(args, "mode") orelse result_contracts.OutputMode.standard.name();
    return switch (result_contracts.parseOutputMode(raw)) {
        .ok => |mode| mode,
        .err => error.InvalidMode,
    };
}

fn resultShapeContractValue(allocator: std.mem.Allocator, contract: result_contracts.ResultShapeContract) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = contract.kind });
    try obj.put(allocator, "schema_version", .{ .integer = contract.schema_version });
    try obj.put(allocator, "ok", .{ .bool = contract.ok });
    try obj.put(allocator, "mode", .{ .string = contract.mode.name() });
    try obj.put(allocator, "default_mode", .{ .string = contract.default_mode.name() });
    try obj.put(allocator, "selected_mode", .{ .string = contract.selected_mode.name() });
    try obj.put(allocator, "supported_modes", try supportedModesValue(allocator, contract.supported_modes));
    try obj.put(allocator, "selected_mode_metadata", try modeMetadataValue(allocator, contract.selected_mode_metadata));
    try obj.put(allocator, "result_shape", try modeMetadataValue(allocator, contract.result_shape));
    try obj.put(allocator, "omitted_sections", try omittedSectionsValue(allocator, contract.omitted_sections));
    try obj.put(allocator, "evidence_source", .{ .string = contract.evidence_source });
    try obj.put(allocator, "confidence", .{ .string = contract.confidence.name() });
    try obj.put(allocator, "required_top_level_fields", try stringArrayValue(allocator, contract.required_top_level_fields));
    try obj.put(allocator, "limitations", .{ .string = contract.limitations });
    try obj.put(allocator, "resolution", .{ .string = contract.resolution });
    obj_owned = false;
    return .{ .object = obj };
}

fn outputBudgetPlanValue(allocator: std.mem.Allocator, plan: result_contracts.OutputBudgetPlan) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = plan.kind });
    try obj.put(allocator, "schema_version", .{ .integer = plan.schema_version });
    try obj.put(allocator, "tool", if (plan.tool_name) |tool_name| .{ .string = tool_name } else .null);
    try obj.put(allocator, "mode", .{ .string = plan.mode.name() });
    try obj.put(allocator, "requested_token_budget", if (plan.requested_token_budget) |budget| .{ .integer = budget } else .null);
    try obj.put(allocator, "default_token_budget", .{ .integer = plan.default_token_budget });
    try obj.put(allocator, "effective_token_budget", .{ .integer = plan.effective_token_budget });
    try obj.put(allocator, "min_token_budget", .{ .integer = plan.min_token_budget });
    try obj.put(allocator, "max_token_budget", .{ .integer = plan.max_token_budget });
    try obj.put(allocator, "clamp_applied", .{ .bool = plan.clamp_applied });
    try obj.put(allocator, "allocation", try allocationValue(allocator, plan.allocation));
    try obj.put(allocator, "omission_policy", .{ .string = plan.omission_policy });
    try obj.put(allocator, "evidence_source", .{ .string = plan.evidence_source });
    try obj.put(allocator, "confidence", .{ .string = plan.confidence.name() });
    try obj.put(allocator, "limitations", .{ .string = plan.limitations });
    try obj.put(allocator, "resolution", .{ .string = plan.resolution });
    try obj.put(allocator, "result_shape", try modeMetadataValue(allocator, plan.result_shape));
    obj_owned = false;
    return .{ .object = obj };
}

fn supportedModesValue(allocator: std.mem.Allocator, modes: []const result_contracts.OutputMode) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (modes) |mode| try array.append(try modeMetadataValue(allocator, result_contracts.modeMetadata(mode)));
    array_owned = false;
    return .{ .array = array };
}

fn modeMetadataValue(allocator: std.mem.Allocator, metadata: result_contracts.ModeMetadata) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = metadata.schema_version });
    try obj.put(allocator, "mode", .{ .string = metadata.mode.name() });
    try obj.put(allocator, "description", .{ .string = metadata.description });
    try obj.put(allocator, "default_token_budget", .{ .integer = metadata.default_token_budget });
    try obj.put(allocator, "stable_machine_fields", try stringArrayValue(allocator, metadata.stable_machine_fields));
    try obj.put(allocator, "included_sections", try stringArrayValue(allocator, metadata.included_sections));
    try obj.put(allocator, "omitted_by_default", try stringArrayValue(allocator, metadata.omitted_by_default));
    try obj.put(allocator, "omission_contract", .{ .string = metadata.omission_contract });
    obj_owned = false;
    return .{ .object = obj };
}

fn omittedSectionsValue(allocator: std.mem.Allocator, omitted: []const result_contracts.OmittedSection) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (omitted) |item| {
        var obj = std.json.ObjectMap.empty;
        var obj_owned = true;
        defer if (obj_owned) obj.deinit(allocator);
        try obj.put(allocator, "section", .{ .string = item.section });
        try obj.put(allocator, "reason", .{ .string = item.reason });
        try obj.put(allocator, "recovery", .{ .string = item.recovery });
        try array.append(.{ .object = obj });
        obj_owned = false;
    }
    array_owned = false;
    return .{ .array = array };
}

fn allocationValue(allocator: std.mem.Allocator, allocation: result_contracts.BudgetAllocation) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "machine_fields_tokens", .{ .integer = allocation.machine_fields_tokens });
    try obj.put(allocator, "evidence_tokens", .{ .integer = allocation.evidence_tokens });
    try obj.put(allocator, "human_summary_tokens", .{ .integer = allocation.human_summary_tokens });
    try obj.put(allocator, "priority_order", try stringArrayValue(allocator, allocation.priority_order));
    obj_owned = false;
    return .{ .object = obj };
}

fn stringArrayValue(allocator: std.mem.Allocator, items: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    var array_owned = true;
    defer if (array_owned) array.deinit();
    for (items) |item| try array.append(.{ .string = item });
    array_owned = false;
    return .{ .array = array };
}

fn argString(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    const value = args orelse return null;
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

fn optionalIntegerArg(args: ?std.json.Value, name: []const u8) ?i64 {
    const value = args orelse return null;
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return switch (field) {
        .integer => |integer| integer,
        else => null,
    };
}

test "result shape adapter renders selected mode contract" {
    const allocator = std.testing.allocator;
    var args = std.json.ObjectMap.empty;
    defer args.deinit(allocator);
    try args.put(allocator, "mode", .{ .string = "deep" });

    const result = try zigarResultShape(allocator, .{ .object = args });
    defer mcp_result.deinitToolResult(allocator, result);

    try std.testing.expect(!result.is_error);
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zigar_result_shape", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("deep", obj.get("selected_mode").?.string);
    try std.testing.expectEqual(@as(usize, 3), obj.get("supported_modes").?.array.items.len);

    var omitted_arena = std.heap.ArenaAllocator.init(allocator);
    defer omitted_arena.deinit();
    const omitted = [_]result_contracts.OmittedSection{.{
        .section = "raw_backend_output",
        .reason = "too large for compact mode",
        .recovery = "retry with mode=deep",
    }};
    const omitted_value = try omittedSectionsValue(omitted_arena.allocator(), omitted[0..]);
    try std.testing.expectEqual(@as(usize, 1), omitted_value.array.items.len);
}

test "output budget adapter preserves public field names" {
    const allocator = std.testing.allocator;
    var args = std.json.ObjectMap.empty;
    defer args.deinit(allocator);
    try args.put(allocator, "mode", .{ .string = "compact" });
    try args.put(allocator, "token_budget", .{ .integer = 100 });
    try args.put(allocator, "tool", .{ .string = "zig_check" });

    const result = try zigarOutputBudgetPlan(allocator, .{ .object = args });
    defer mcp_result.deinitToolResult(allocator, result);

    try std.testing.expect(!result.is_error);
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zigar_output_budget_plan", obj.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, result_contracts.min_token_budget), obj.get("effective_token_budget").?.integer);
    try std.testing.expectEqualStrings("zig_check", obj.get("tool").?.string);
}

test "result shape adapters reject invalid modes with structured errors" {
    const allocator = std.testing.allocator;
    var args = std.json.ObjectMap.empty;
    defer args.deinit(allocator);
    try args.put(allocator, "mode", .{ .string = "verbose" });

    const shape = try zigarResultShape(allocator, .{ .object = args });
    defer mcp_result.deinitToolResult(allocator, shape);
    try std.testing.expect(shape.is_error);
    try std.testing.expectEqualStrings("invalid_argument", shape.structuredContent.?.object.get("code").?.string);

    const budget = try zigarOutputBudgetPlan(allocator, .{ .object = args });
    defer mcp_result.deinitToolResult(allocator, budget);
    try std.testing.expect(budget.is_error);
    try std.testing.expectEqualStrings("invalid_argument", budget.structuredContent.?.object.get("code").?.string);
}
