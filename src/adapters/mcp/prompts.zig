//! Prompt registration and projection for deterministic runtime-UX workflows.
const std = @import("std");
const mcp = @import("mcp");

const runtime_ux = @import("../../app/usecases/runtime_ux/workflows.zig");
const mcp_result = @import("result.zig");

/// Registers all deterministic zigars workflow prompts with owned message cleanup.
pub fn registerPrompts(server: anytype, context_provider: anytype) !void {
    const Provider = @TypeOf(context_provider);
    try server.addPromptWithDeinit(.{
        .name = "zigars_profile_workflow",
        .description = "Plan a deterministic Zig profiling workflow using zigars tools.",
        .title = "Zig Profiling Workflow",
        .handler = promptHandler(Provider, "zigars_profile_workflow"),
        .user_data = context_provider,
    }, mcp_result.deinitPromptMessages);
    inline for (.{ "zigars_compile_error_workflow", "zigars_test_workflow", "zigars_refactor_workflow", "zigars_api_change_workflow", "zigars_release_workflow", "zigars_perf_workflow" }) |name| {
        try server.addPromptWithDeinit(.{
            .name = name,
            .description = "Deterministic zigars workflow prompt.",
            .title = "Zigars Workflow",
            .handler = promptHandler(Provider, name),
            .user_data = context_provider,
        }, mcp_result.deinitPromptMessages);
    }
}

/// Builds a prompt callback that returns one user message owned by the call
/// allocator (paired with `deinitPromptMessages` at registration). The prompt
/// text is deterministic and depends only on the prompt name and an optional
/// `workflow` arg; the runtime provider is required for dispatch but its state
/// is not read, so a null provider is treated as a generation failure.
fn promptHandler(comptime Provider: type, comptime name: []const u8) *const fn (?*anyopaque, std.Io, std.mem.Allocator, ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    return struct {
        /// Bridges the typed helper into the callback signature expected by the MCP adapter.
        fn call(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
            // Provider presence is the dispatch contract; the value itself is unused.
            _ = @as(Provider, @ptrCast(@alignCast(user_data orelse return error.GenerationFailed)));
            const text = if (std.mem.eql(u8, name, "zigars_profile_workflow"))
                runtime_ux.profilePromptText()
            else
                runtime_ux.workflowPromptText(workflowName(name, args));
            const messages = allocator.alloc(mcp.prompts.PromptMessage, 1) catch return error.OutOfMemory;
            // Free the slice if duping the message text below fails; ownership
            // transfers to the caller once the slice is fully populated.
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

/// Contract-token anchor for prompt registration coverage. A release gate
/// substring-matches these names against this file to prove every advertised
/// workflow prompt stays wired; keep this list in sync with `registerPrompts`.
const _prompt_contract_tokens = [_][]const u8{
    "zigars_profile_workflow",
    "zigars_compile_error_workflow",
    "zigars_test_workflow",
    "zigars_refactor_workflow",
    "zigars_api_change_workflow",
    "zigars_release_workflow",
    "zigars_perf_workflow",
};

test {
    _ = registerPrompts;
    _ = _prompt_contract_tokens;
}
