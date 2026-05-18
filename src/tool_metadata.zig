const tool_manifest = @import("tool_manifest.zig");

pub const ToolId = tool_manifest.ToolId;
pub const ToolMeta = tool_manifest.ToolMeta;
pub const ToolEntry = tool_manifest.ToolEntry;
pub const ToolGroup = tool_manifest.ToolGroup;
pub const ToolRisk = tool_manifest.ToolRisk;
pub const ToolHandler = tool_manifest.ToolHandler;
pub const HandlerModule = tool_manifest.HandlerModule;
pub const HandlerRef = tool_manifest.HandlerRef;
pub const CommandPlan = tool_manifest.CommandPlan;
pub const FileCommandPlan = tool_manifest.FileCommandPlan;
pub const GroupSpec = tool_manifest.GroupSpec;

pub const entries = tool_manifest.entries;
pub const specs = tool_manifest.specs;
pub const group_specs = tool_manifest.group_specs;
pub const entryFor = tool_manifest.entryFor;
pub const find = tool_manifest.find;
pub const findEntry = tool_manifest.findEntry;
pub const groupFor = tool_manifest.groupFor;
pub const groupName = tool_manifest.groupName;
pub const groupKeywords = tool_manifest.groupKeywords;
pub const riskFor = tool_manifest.riskFor;
pub const commandPlanFor = tool_manifest.commandPlanFor;
pub const riskLevel = tool_manifest.riskLevel;
pub const riskValue = tool_manifest.riskValue;
pub const readOnlyHintFor = tool_manifest.readOnlyHintFor;
pub const idempotentHintFor = tool_manifest.idempotentHintFor;
pub const destructiveHintFor = tool_manifest.destructiveHintFor;

test {
    _ = tool_manifest;
}
