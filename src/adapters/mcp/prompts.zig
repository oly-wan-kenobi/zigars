//! Prompt registration and projection for deterministic runtime-UX workflows.
const std = @import("std");
const mcp = @import("mcp");

const runtime_ux = @import("../../app/usecases/runtime_ux/workflows.zig");
const mcp_result = @import("result.zig");

/// Registers all deterministic zigar workflow prompts with owned message cleanup.
pub fn registerPrompts(server: anytype, context_provider: anytype) !void {
    const Provider = @TypeOf(context_provider);
    try server.addPromptWithDeinit(.{
        .name = "zigar_profile_workflow",
        .description = "Plan a deterministic Zig profiling workflow using zigar tools.",
        .title = "Zig Profiling Workflow",
        .handler = promptHandler(Provider, "zigar_profile_workflow"),
        .user_data = context_provider,
    }, mcp_result.deinitPromptMessages);
    inline for (.{ "zigar_compile_error_workflow", "zigar_test_workflow", "zigar_refactor_workflow", "zigar_api_change_workflow", "zigar_release_workflow", "zigar_perf_workflow" }) |name| {
        try server.addPromptWithDeinit(.{
            .name = name,
            .description = "Deterministic zigar workflow prompt.",
            .title = "Zigar Workflow",
            .handler = promptHandler(Provider, name),
            .user_data = context_provider,
        }, mcp_result.deinitPromptMessages);
    }
}

/// Builds a prompt callback that returns one allocator-owned user message.
fn promptHandler(comptime Provider: type, comptime name: []const u8) *const fn (?*anyopaque, std.Io, std.mem.Allocator, ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    return struct {
        fn call(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
            _ = @as(Provider, @ptrCast(@alignCast(user_data orelse return error.GenerationFailed)));
            const text = if (std.mem.eql(u8, name, "zigar_profile_workflow"))
                runtime_ux.profilePromptText()
            else
                runtime_ux.workflowPromptText(workflowName(name, args));
            const messages = allocator.alloc(mcp.prompts.PromptMessage, 1) catch return error.OutOfMemory;
            var messages_owned = true;
            defer if (messages_owned) allocator.free(messages);
            messages[0] = mcp.prompts.userMessage(allocator.dupe(u8, text) catch return error.OutOfMemory);
            messages_owned = false;
            return messages;
        }
    }.call;
}

/// Allows prompt arguments to override the workflow token used in the text.
fn workflowName(default_name: []const u8, args: ?std.json.Value) []const u8 {
    return switch (args orelse .null) {
        .object => |obj| switch (obj.get("workflow") orelse .null) {
            .string => |s| s,
            else => default_name,
        },
        else => default_name,
    };
}

/// Contract-token anchor for prompt registration coverage.
const _prompt_contract_tokens = [_][]const u8{
    "zigar_profile_workflow",
    "zigar_compile_error_workflow",
    "zigar_test_workflow",
    "zigar_refactor_workflow",
    "zigar_api_change_workflow",
    "zigar_release_workflow",
    "zigar_perf_workflow",
};

test {
    _ = registerPrompts;
    _ = _prompt_contract_tokens;
}
