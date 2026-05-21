const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const common = @import("common.zig");
const result_shape = zigar.result_shape;

const App = common.App;
const argString = common.argString;
const invalidArgumentResult = common.invalidArgumentResult;
const structured = common.structured;

pub fn zigarResultShape(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode = parseModeArg(args) catch |err| switch (err) {
        error.InvalidMode => {
            const actual = argString(args, "mode") orelse "";
            return invalidArgumentResult(
                allocator,
                "zigar_result_shape",
                "mode",
                result_shape.supportedModesText(),
                actual,
                "Choose compact for routing, standard for normal agent use, or deep for expanded evidence.",
            );
        },
    };
    return structured(allocator, result_shape.contractValue(allocator, mode) catch return error.OutOfMemory);
}

pub fn zigarOutputBudgetPlan(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const mode = parseModeArg(args) catch |err| switch (err) {
        error.InvalidMode => {
            const actual = argString(args, "mode") orelse "";
            return invalidArgumentResult(
                allocator,
                "zigar_output_budget_plan",
                "mode",
                result_shape.supportedModesText(),
                actual,
                "Choose compact, standard, or deep before asking for an output budget plan.",
            );
        },
    };
    const requested_token_budget = optionalIntegerArg(args, "token_budget");
    const tool_name = argString(args, "tool");
    return structured(allocator, result_shape.budgetPlanValue(allocator, .{
        .mode = mode,
        .requested_token_budget = requested_token_budget,
        .tool_name = tool_name,
    }) catch return error.OutOfMemory);
}

fn parseModeArg(args: ?std.json.Value) error{InvalidMode}!result_shape.ResultShapeMode {
    const raw = argString(args, "mode") orelse result_shape.ResultShapeMode.standard.name();
    return result_shape.parseMode(raw) orelse error.InvalidMode;
}

fn optionalIntegerArg(args: ?std.json.Value, name: []const u8) ?i64 {
    const value = args orelse return null;
    const obj = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const field = obj.get(name) orelse return null;
    return switch (field) {
        .integer => |integer| integer,
        else => null,
    };
}
