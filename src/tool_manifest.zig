const std = @import("std");
const mcp = @import("mcp");

const runtime_mod = @import("runtime.zig");
const tooling = @import("tooling.zig");

pub const ToolHandler = *const fn (*runtime_mod.App, std.mem.Allocator, ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult;

pub const ToolGroup = enum {
    discovery,
    agent_workflows,
    core_zig,
    formatting_and_edits,
    zls,
    docs,
    static_analysis,
    ci_artifacts,
    zwanzig,
    profiling,
};

pub const HandlerModule = enum {
    discovery,
    agent,
    core,
    edit_zls,
    docs,
    static_analysis,
    ci,
    zwanzig,
    profiling,
};

pub const HandlerRef = struct {
    module: HandlerModule,
    name: []const u8,
};

pub const ToolRisk = struct {
    writes_source: bool = false,
    writes_artifacts: bool = false,
    writes_require_apply: bool = false,
    preview_by_default: bool = false,
    mutates_lsp_state: bool = false,
    executes_project_code: bool = false,
    executes_user_command: bool = false,
    executes_backend: bool = false,
};

pub const FileCommandPlan = struct {
    file_args: []const []const u8,
    fallback_args: []const []const u8,
};

pub const CommandPlan = union(enum) {
    argv: []const []const u8,
    optional_file: FileCommandPlan,
    required_file: []const []const u8,
    required_path: []const []const u8,
};

pub const ZlsPlan = struct {
    method: []const u8,
    requires_document_sync: bool = false,
    mutates_document_state: bool = false,
    required_capability: ?[]const u8 = null,
};

pub const PlanPolicy = union(enum) {
    exact_command: CommandPlan,
    dynamic_command: []const u8,
    zls_request: ZlsPlan,
    apply_gated_mutation: []const u8,
    workspace_artifact: []const u8,
    pure_analysis: []const u8,
    not_plannable: []const u8,
};

pub const ToolDefinition = struct {
    description: []const u8,
    input_schema: tooling.SchemaSpec = schema(&.{}),
    read_only: bool = true,
    group: ToolGroup,
    risk: ToolRisk = .{},
    handler: HandlerRef,
    plan: PlanPolicy,
};

pub const ToolMeta = struct {
    id: ToolId,
    name: []const u8,
    description: []const u8,
    input_schema: tooling.SchemaSpec,
    read_only: bool,
};

pub const ToolEntry = struct {
    id: ToolId,
    name: []const u8,
    meta: ToolMeta,
    group: ToolGroup,
    risk: ToolRisk,
    handler: HandlerRef,
    plan: PlanPolicy,
};

pub const GroupSpec = struct {
    group: ToolGroup,
    keywords: []const []const u8,
};

fn schema(comptime fields: []const tooling.SchemaField) tooling.SchemaSpec {
    return tooling.schema(fields);
}

fn tool(definition: ToolDefinition) ToolDefinition {
    return definition;
}

fn handler(module: HandlerModule, name: []const u8) HandlerRef {
    return .{ .module = module, .name = name };
}

pub const definitions = struct {
    pub const zigar_capabilities = tool(.{
        .description = "Return a compact zigar tool/capability index with search keywords, including fmt, formatter, formatting, and zig fmt.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .discovery,
        .handler = handler(.discovery, "zigarCapabilities"),
        .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
    });
    pub const zigar_tool_index = tool(.{
        .description = "Return a compact searchable zigar tool index with aliases for fmt, formatter, formatting, zig fmt, docs, ZLS, lint, and profiling.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .discovery,
        .handler = handler(.discovery, "zigarCapabilities"),
        .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
    });
    pub const zigar_schema = tool(.{
        .description = "Return zigar's compact tool catalog and schema-discovery hints.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .discovery,
        .handler = handler(.discovery, "zigarSchema"),
        .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
    });
    pub const zigar_doctor = tool(.{
        .description = "Diagnose common zigar MCP configuration, workspace, backend, and transport problems.",
        .input_schema = schema(&.{ .{ "probe_backends", "boolean", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .discovery,
        .risk = .{ .executes_backend = true },
        .handler = handler(.discovery, "zigarDoctor"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zigar_workspace_info = tool(.{
        .description = "Return workspace and configured backend paths.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .discovery,
        .handler = handler(.discovery, "workspaceInfo"),
        .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
    });
    pub const zigar_metrics = tool(.{
        .description = "Return zigar process counters and backend health.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .discovery,
        .handler = handler(.discovery, "zigarMetrics"),
        .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
    });
    pub const zigar_http_status = tool(.{
        .description = "Report HTTP transport support and configured endpoint.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .discovery,
        .handler = handler(.discovery, "zigarHttpStatus"),
        .plan = .{ .pure_analysis = "Manifest/catalog lookup; does not execute backends or mutate workspace state." },
    });
    pub const zigar_context_pack = tool(.{
        .description = "Return a compact deterministic Zig project context pack for agent orientation.",
        .input_schema = schema(&.{ .{ "mode", "string", false }, .{ "token_budget", "integer", false }, .{ "include", "string", false } }),
        .read_only = true,
        .group = .agent_workflows,
        .handler = handler(.agent, "zigarContextPack"),
        .plan = .{ .pure_analysis = "Agent-orientation snapshot; reads workspace files and manifest metadata without executing tools." },
    });
    pub const zigar_next_action = tool(.{
        .description = "Route a Zig development goal to the next deterministic zigar tool calls.",
        .input_schema = schema(&.{ .{ "goal", "string", true }, .{ "changed_files", "string", false }, .{ "last_error", "string", false } }),
        .read_only = true,
        .group = .agent_workflows,
        .handler = handler(.agent, "zigarNextAction"),
        .plan = .{ .pure_analysis = "Goal router; returns deterministic next tool suggestions without executing tools." },
    });
    pub const zigar_agent_guide = tool(.{
        .description = "Return compact Codex/Claude/generic instructions for using zigar efficiently.",
        .input_schema = schema(&.{ .{ "client", "string", false }, .{ "task", "string", false } }),
        .read_only = true,
        .group = .agent_workflows,
        .handler = handler(.agent, "zigarAgentGuide"),
        .plan = .{ .pure_analysis = "Client guidance lookup; returns deterministic instructions without executing tools." },
    });
    pub const zigar_validate_patch = tool(.{
        .description = "Run an agent-friendly changed-file validation loop and return structured blockers.",
        .input_schema = schema(&.{ .{ "mode", "string", false }, .{ "changed_files", "string", false }, .{ "stop_on_failure", "boolean", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .agent_workflows,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
        .handler = handler(.agent, "zigarValidatePatch"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zigar_failure_fusion = tool(.{
        .description = "Fuse compiler/test output, primary failure data, impact hints, and suggested zigar tools.",
        .input_schema = schema(&.{ .{ "text", "string", false }, .{ "command", "string", false }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .agent_workflows,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
        .handler = handler(.agent, "zigarFailureFusion"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zigar_impact = tool(.{
        .description = "Analyze affected imports, tests, public API, and validation commands for files or symbols.",
        .input_schema = schema(&.{ .{ "files", "string", false }, .{ "symbols", "string", false }, .{ "limit", "integer", false } }),
        .read_only = true,
        .group = .agent_workflows,
        .handler = handler(.agent, "zigarImpact"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zigar_project_profile = tool(.{
        .description = "Read or explicitly write a workspace-local deterministic zigar project profile.",
        .input_schema = schema(&.{ .{ "apply", "boolean", false }, .{ "content", "string", false } }),
        .read_only = false,
        .group = .agent_workflows,
        .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
        .handler = handler(.agent, "zigarProjectProfile"),
        .plan = .{ .apply_gated_mutation = "Preview-first workspace mutation; writes only when apply=true and reports risk metadata before changes." },
    });
    pub const zigar_patch_guard = tool(.{
        .description = "Validate proposed patch/file paths against zigar workspace and generated-path safety rules.",
        .input_schema = schema(&.{ .{ "files", "string", false }, .{ "patch", "string", false } }),
        .read_only = true,
        .group = .agent_workflows,
        .handler = handler(.agent, "zigarPatchGuard"),
        .plan = .{ .pure_analysis = "Workspace safety check; validates paths and patch text without applying changes." },
    });
    pub const zig_command_plan = tool(.{
        .description = "Preview the exact argv/cwd/timeout for a deterministic zigar command workflow; use zig_tool_plan for non-command-backed tools.",
        .input_schema = schema(&.{ .{ "tool", "string", true }, .{ "file", "string", false }, .{ "path", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .discovery,
        .handler = handler(.discovery, "zigCommandPlan"),
        .plan = .{ .pure_analysis = "Returns exact argv plans only for command-backed tools; reports known non-command tools as unsupported instead of executing." },
    });
    pub const zig_tool_plan = tool(.{
        .description = "Return manifest-derived planning support for any registered zigar tool, including exact commands, dynamic backends, ZLS requests, and pure analysis tools.",
        .input_schema = schema(&.{ .{ "tool", "string", true }, .{ "file", "string", false }, .{ "path", "string", false }, .{ "input", "string", false }, .{ "output", "string", false }, .{ "command", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .discovery,
        .handler = handler(.discovery, "zigToolPlan"),
        .plan = .{ .pure_analysis = "Returns manifest-derived planning metadata; does not execute commands or mutate workspace state." },
    });
    pub const zig_toolchain_resolve = tool(.{
        .description = "Detect active Zig/ZLS versions, project version hints, and installed Zig version managers.",
        .input_schema = schema(&.{ .{ "probe_managers", "boolean", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .discovery,
        .risk = .{ .executes_backend = true },
        .handler = handler(.discovery, "zigToolchainResolve"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_version = tool(.{
        .description = "Return Zig and ZLS version information.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .core_zig,
        .risk = .{ .executes_backend = true },
        .handler = handler(.core, "zigVersion"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_env = tool(.{
        .description = "Run `zig env`.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .core_zig,
        .risk = .{ .executes_backend = true },
        .handler = handler(.core, "zigEnv"),
        .plan = .{ .exact_command = .{ .argv = &.{"env"} } },
    });
    pub const zig_targets = tool(.{
        .description = "Run `zig targets`.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .core_zig,
        .risk = .{ .executes_backend = true },
        .handler = handler(.core, "zigTargets"),
        .plan = .{ .exact_command = .{ .argv = &.{"targets"} } },
    });
    pub const zig_build = tool(.{
        .description = "Run `zig build` in the workspace.",
        .input_schema = schema(&.{ .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .core_zig,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
        .handler = handler(.core, "zigBuild"),
        .plan = .{ .exact_command = .{ .argv = &.{"build"} } },
    });
    pub const zig_test = tool(.{
        .description = "Run Zig tests. Uses `zig test <file>` when file is provided, otherwise `zig build test`.",
        .input_schema = schema(&.{ .{ "file", "string", false }, .{ "filter", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .core_zig,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
        .handler = handler(.core, "zigTest"),
        .plan = .{ .exact_command = .{ .optional_file = .{ .file_args = &.{"test"}, .fallback_args = &.{ "build", "test" } } } },
    });
    pub const zig_check = tool(.{
        .description = "Run `zig ast-check` on a workspace Zig file.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .core_zig,
        .risk = .{ .executes_backend = true },
        .handler = handler(.core, "zigCheck"),
        .plan = .{ .exact_command = .{ .required_file = &.{"ast-check"} } },
    });
    pub const zig_compile_error_index = tool(.{
        .description = "Parse compiler output or run a focused Zig command and return grouped compile diagnostics.",
        .input_schema = schema(&.{ .{ "text", "string", false }, .{ "command", "string", false }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .core_zig,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
        .handler = handler(.core, "zigCompileErrorIndex"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_explain_errors = tool(.{
        .description = "Run a focused Zig command and return parsed compiler findings plus deterministic next actions.",
        .input_schema = schema(&.{ .{ "command", "string", false }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .core_zig,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
        .handler = handler(.core, "zigExplainErrors"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_translate_c = tool(.{
        .description = "Run `zig translate-c` on a workspace C header/source file.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .core_zig,
        .risk = .{ .executes_backend = true },
        .handler = handler(.core, "zigTranslateC"),
        .plan = .{ .exact_command = .{ .required_file = &.{"translate-c"} } },
    });
    pub const zig_format = tool(.{
        .description = "Format a Zig file. Returns preview by default; writes only with apply=true.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "apply", "boolean", false }, .{ "content", "string", false } }),
        .read_only = false,
        .group = .formatting_and_edits,
        .risk = .{ .writes_source = true, .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true, .executes_backend = true },
        .handler = handler(.edit_zls, "zigFormat"),
        .plan = .{ .apply_gated_mutation = "Preview-first workspace mutation; writes only when apply=true and reports risk metadata before changes." },
    });
    pub const zig_format_check = tool(.{
        .description = "Run `zig fmt --check` on a workspace file or directory.",
        .input_schema = schema(&.{ .{ "path", "string", true }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .formatting_and_edits,
        .risk = .{ .executes_backend = true },
        .handler = handler(.edit_zls, "zigFormatCheck"),
        .plan = .{ .exact_command = .{ .required_path = &.{ "fmt", "--check" } } },
    });
    pub const zig_patch_preview = tool(.{
        .description = "Preview a replacement-content patch with hashes and unified diff; writes only with apply=true.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", true }, .{ "apply", "boolean", false } }),
        .read_only = false,
        .group = .formatting_and_edits,
        .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true },
        .handler = handler(.edit_zls, "zigPatchPreview"),
        .plan = .{ .apply_gated_mutation = "Preview-first workspace mutation; writes only when apply=true and reports risk metadata before changes." },
    });
    pub const zig_rename = tool(.{
        .description = "Request a ZLS workspace edit for a symbol rename. Returns preview by default; writes only with apply=true.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true }, .{ "new_name", "string", true }, .{ "apply", "boolean", false } }),
        .read_only = false,
        .group = .formatting_and_edits,
        .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true, .executes_backend = true },
        .handler = handler(.edit_zls, "zigRename"),
        .plan = .{ .apply_gated_mutation = "Preview-first workspace mutation; writes only when apply=true and reports risk metadata before changes." },
    });
    pub const zig_code_actions = tool(.{
        .description = "Get ZLS code actions for a range.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "start_line", "integer", true }, .{ "start_char", "integer", true }, .{ "end_line", "integer", true }, .{ "end_char", "integer", true } }),
        .read_only = true,
        .group = .formatting_and_edits,
        .handler = handler(.edit_zls, "zigCodeActions"),
        .plan = .{ .zls_request = .{ .method = "textDocument/codeAction", .requires_document_sync = true, .required_capability = "codeActionProvider" } },
    });
    pub const zig_code_action_apply = tool(.{
        .description = "Preview or apply one ZLS code action by index. Writes only with apply=true.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "start_line", "integer", true }, .{ "start_char", "integer", true }, .{ "end_line", "integer", true }, .{ "end_char", "integer", true }, .{ "action_index", "integer", true }, .{ "apply", "boolean", false } }),
        .read_only = false,
        .group = .formatting_and_edits,
        .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true, .executes_backend = true },
        .handler = handler(.edit_zls, "zigCodeActionApply"),
        .plan = .{ .apply_gated_mutation = "Preview-first workspace mutation; writes only when apply=true and reports risk metadata before changes." },
    });
    pub const zig_document_open = tool(.{
        .description = "Open or replace an in-memory Zig document in the ZLS session.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", true } }),
        .read_only = false,
        .group = .zls,
        .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
        .handler = handler(.edit_zls, "zigDocumentOpen"),
        .plan = .{ .zls_request = .{ .method = "textDocument/didOpen", .requires_document_sync = true, .mutates_document_state = true } },
    });
    pub const zig_document_change = tool(.{
        .description = "Replace an already-open in-memory Zig document in the ZLS session.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", true } }),
        .read_only = false,
        .group = .zls,
        .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
        .handler = handler(.edit_zls, "zigDocumentOpen"),
        .plan = .{ .zls_request = .{ .method = "textDocument/didChange", .requires_document_sync = true, .mutates_document_state = true } },
    });
    pub const zig_document_close = tool(.{
        .description = "Close a Zig document in the ZLS session.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = false,
        .group = .zls,
        .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
        .handler = handler(.edit_zls, "zigDocumentClose"),
        .plan = .{ .zls_request = .{ .method = "textDocument/didClose", .mutates_document_state = true } },
    });
    pub const zig_document_status = tool(.{
        .description = "Return tracked ZLS document version/hash/dirty metadata.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .zls,
        .handler = handler(.edit_zls, "zigDocumentStatus"),
        .plan = .{ .pure_analysis = "Reads process-local ZLS document state without sending backend requests." },
    });
    pub const zig_diagnostics = tool(.{
        .description = "Open a Zig file in ZLS and return the latest publishDiagnostics notification when available, with ast-check fallback.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "wait_ms", "integer", false } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .executes_backend = true },
        .handler = handler(.edit_zls, "zigDiagnostics"),
        .plan = .{ .zls_request = .{ .method = "textDocument/publishDiagnostics with ast-check fallback", .requires_document_sync = true } },
    });
    pub const zig_diagnostics_all = tool(.{
        .description = "Aggregate diagnostics from ZLS publish/pull diagnostics and `zig ast-check`.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "wait_ms", "integer", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .executes_backend = true },
        .handler = handler(.edit_zls, "zigDiagnosticsAll"),
        .plan = .{ .zls_request = .{ .method = "textDocument/diagnostic plus ast-check fallback", .requires_document_sync = true } },
    });
    pub const zig_diagnostics_workspace = tool(.{
        .description = "Return cached workspace diagnostics grouped by file and severity.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .zls,
        .handler = handler(.edit_zls, "zigDiagnosticsWorkspace"),
        .plan = .{ .pure_analysis = "Reads cached workspace diagnostics collected from the active ZLS session." },
    });
    pub const zig_hover = tool(.{
        .description = "Get ZLS hover information for a Zig symbol.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .executes_backend = true },
        .handler = handler(.edit_zls, "zigHover"),
        .plan = .{ .zls_request = .{ .method = "textDocument/hover", .requires_document_sync = true, .required_capability = "hoverProvider" } },
    });
    pub const zig_definition = tool(.{
        .description = "Get ZLS definition location for a Zig symbol.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .executes_backend = true },
        .handler = handler(.edit_zls, "zigDefinition"),
        .plan = .{ .zls_request = .{ .method = "textDocument/definition", .requires_document_sync = true, .required_capability = "definitionProvider" } },
    });
    pub const zig_references = tool(.{
        .description = "Find ZLS references for a Zig symbol.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true }, .{ "include_declaration", "boolean", false } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .executes_backend = true },
        .handler = handler(.edit_zls, "zigReferences"),
        .plan = .{ .zls_request = .{ .method = "textDocument/references", .requires_document_sync = true, .required_capability = "referencesProvider" } },
    });
    pub const zig_completion = tool(.{
        .description = "Get ZLS completions at a Zig source position.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .executes_backend = true },
        .handler = handler(.edit_zls, "zigCompletion"),
        .plan = .{ .zls_request = .{ .method = "textDocument/completion", .requires_document_sync = true, .required_capability = "completionProvider" } },
    });
    pub const zig_signature_help = tool(.{
        .description = "Get ZLS signature help at a Zig source position.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .executes_backend = true },
        .handler = handler(.edit_zls, "zigSignatureHelp"),
        .plan = .{ .zls_request = .{ .method = "textDocument/signatureHelp", .requires_document_sync = true, .required_capability = "signatureHelpProvider" } },
    });
    pub const zig_document_symbols = tool(.{
        .description = "List ZLS document symbols for a Zig source file.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .executes_backend = true },
        .handler = handler(.edit_zls, "zigDocumentSymbols"),
        .plan = .{ .zls_request = .{ .method = "textDocument/documentSymbol", .requires_document_sync = true, .required_capability = "documentSymbolProvider" } },
    });
    pub const zig_workspace_symbols = tool(.{
        .description = "Search ZLS workspace symbols matching a query.",
        .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .executes_backend = true },
        .handler = handler(.edit_zls, "zigWorkspaceSymbols"),
        .plan = .{ .zls_request = .{ .method = "workspace/symbol", .required_capability = "workspaceSymbolProvider" } },
    });
    pub const zig_builtin_list = tool(.{
        .description = "List curated Zig builtin docs bundled with zigar.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .docs,
        .handler = handler(.docs, "zigBuiltinList"),
        .plan = .{ .pure_analysis = "Documentation lookup; reads bundled or local Zig documentation without mutating workspace state." },
    });
    pub const zig_builtin_list_json = tool(.{
        .description = "Return curated Zig builtin docs as JSON-native records.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .docs,
        .handler = handler(.docs, "zigBuiltinListJson"),
        .plan = .{ .pure_analysis = "Documentation lookup; reads bundled or local Zig documentation without mutating workspace state." },
    });
    pub const zig_builtin_doc = tool(.{
        .description = "Search curated Zig builtin docs.",
        .input_schema = schema(&.{.{ "query", "string", true }}),
        .read_only = true,
        .group = .docs,
        .handler = handler(.docs, "zigBuiltinDoc"),
        .plan = .{ .pure_analysis = "Documentation lookup; reads bundled or local Zig documentation without mutating workspace state." },
    });
    pub const zig_std_search = tool(.{
        .description = "Search local Zig standard library source for a query.",
        .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }),
        .read_only = true,
        .group = .docs,
        .handler = handler(.docs, "zigStdSearch"),
        .plan = .{ .pure_analysis = "Documentation lookup; reads bundled or local Zig documentation without mutating workspace state." },
    });
    pub const zig_std_search_json = tool(.{
        .description = "Search local Zig standard library source and return JSON-native records.",
        .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }),
        .read_only = true,
        .group = .docs,
        .handler = handler(.docs, "zigStdSearchJson"),
        .plan = .{ .pure_analysis = "Documentation lookup; reads bundled or local Zig documentation without mutating workspace state." },
    });
    pub const zig_std_item = tool(.{
        .description = "Search local Zig standard library source for a fully qualified item string.",
        .input_schema = schema(&.{ .{ "name", "string", true }, .{ "limit", "integer", false } }),
        .read_only = true,
        .group = .docs,
        .handler = handler(.docs, "zigStdItem"),
        .plan = .{ .pure_analysis = "Documentation lookup; reads bundled or local Zig documentation without mutating workspace state." },
    });
    pub const zig_lang_ref_search = tool(.{
        .description = "Search Zig's installed documentation sources.",
        .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }),
        .read_only = true,
        .group = .docs,
        .handler = handler(.docs, "zigLangRefSearch"),
        .plan = .{ .pure_analysis = "Documentation lookup; reads bundled or local Zig documentation without mutating workspace state." },
    });
    pub const zig_import_graph = tool(.{
        .description = "Build a heuristic import graph from workspace Zig files.",
        .input_schema = schema(&.{.{ "limit", "integer", false }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigImportGraph"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_import_graph_json = tool(.{
        .description = "Build a JSON-native heuristic import graph from workspace Zig files.",
        .input_schema = schema(&.{.{ "limit", "integer", false }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigImportGraphJson"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_decl_summary = tool(.{
        .description = "Summarize declarations in a Zig file.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigDeclSummary"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_decl_summary_json = tool(.{
        .description = "Return JSON-native declaration summary for a Zig file.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigDeclSummaryJson"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_allocations = tool(.{
        .description = "Find allocation-related call sites in a Zig file.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigAllocations"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_error_sets = tool(.{
        .description = "Find error-related sites in a Zig file.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigErrorSets"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_public_api = tool(.{
        .description = "Find public API declarations in a Zig file.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigPublicApi"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_dead_decl_candidates = tool(.{
        .description = "List private declaration candidates that need reference checks before deletion.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigDeadDeclCandidates"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_build_graph = tool(.{
        .description = "Parse build.zig/build.zig.zon heuristically into modules, dependencies, build steps, and artifacts.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigBuildGraph"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_build_targets = tool(.{
        .description = "Return build steps, artifacts, modules, and suggested zig build commands.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigBuildTargets"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_build_options = tool(.{
        .description = "Discover available `zig build -D...` options from build.zig and standard Zig build knobs.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigBuildOptions"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_file_owner = tool(.{
        .description = "Map a workspace Zig file to likely build module/artifact/test commands.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigFileOwner"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_import_resolve = tool(.{
        .description = "Resolve a Zig @import string against workspace modules, packages, stdlib, or a source file.",
        .input_schema = schema(&.{ .{ "import", "string", true }, .{ "from", "string", false } }),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigImportResolve"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_test_discover = tool(.{
        .description = "Discover Zig test declarations and runnable test commands.",
        .input_schema = schema(&.{.{ "limit", "integer", false }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigTestDiscover"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_changed_files_plan = tool(.{
        .description = "Inspect git changes and recommend the smallest useful Zig validation commands.",
        .input_schema = schema(&.{.{ "timeout_ms", "integer", false }}),
        .read_only = true,
        .group = .static_analysis,
        .risk = .{ .executes_backend = true },
        .handler = handler(.static_analysis, "zigChangedFilesPlan"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_dependency_inspect = tool(.{
        .description = "Inspect build.zig.zon dependencies, hashes, local package/cache state, and dependency wiring risks.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigDependencyInspect"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_target_matrix_plan = tool(.{
        .description = "Plan cross-target Zig build/test matrix commands without running them.",
        .input_schema = schema(&.{ .{ "targets", "string", false }, .{ "steps", "string", false } }),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigTargetMatrixPlan"),
        .plan = .{ .pure_analysis = "Command matrix planner; returns candidate build/test commands without running them." },
    });
    pub const zig_test_failure_triage = tool(.{
        .description = "Parse Zig test output or run tests and return failing tests, panic clues, and rerun commands.",
        .input_schema = schema(&.{ .{ "text", "string", false }, .{ "file", "string", false }, .{ "filter", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .static_analysis,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
        .handler = handler(.static_analysis, "zigTestFailureTriage"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_workspace_symbol_cache = tool(.{
        .description = "Build or inspect a cached heuristic workspace symbol/import index for repeated MCP calls.",
        .input_schema = schema(&.{ .{ "refresh", "boolean", false }, .{ "query", "string", false }, .{ "limit", "integer", false } }),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigWorkspaceSymbolCache"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_package_cache_doctor = tool(.{
        .description = "Diagnose Zig package/cache directories, git-tracked generated artifacts, and package hash risks.",
        .input_schema = schema(&.{.{ "timeout_ms", "integer", false }}),
        .read_only = true,
        .group = .static_analysis,
        .risk = .{ .executes_backend = true },
        .handler = handler(.static_analysis, "zigPackageCacheDoctor"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_test_map = tool(.{
        .description = "Build a deterministic map of Zig test declarations, files, likely symbols, and test commands.",
        .input_schema = schema(&.{.{ "limit", "integer", false }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigTestMap"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_test_select = tool(.{
        .description = "Select focused Zig test commands for changed files or symbols.",
        .input_schema = schema(&.{ .{ "files", "string", false }, .{ "symbols", "string", false }, .{ "limit", "integer", false } }),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigTestSelect"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
    });
    pub const zig_public_api_diff = tool(.{
        .description = "Compare public Zig declarations from git baseline/text/current file and report likely breaking changes.",
        .input_schema = schema(&.{ .{ "file", "string", false }, .{ "before", "string", false }, .{ "after", "string", false }, .{ "baseline_ref", "string", false } }),
        .read_only = true,
        .group = .static_analysis,
        .risk = .{ .executes_backend = true },
        .handler = handler(.static_analysis, "zigPublicApiDiff"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_ci_annotations = tool(.{
        .description = "Convert diagnostics/check output into CI annotation records.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .ci_artifacts,
        .risk = .{ .executes_backend = true },
        .handler = handler(.ci, "zigCiAnnotations"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_junit = tool(.{
        .description = "Run Zig tests and return a minimal JUnit XML artifact.",
        .input_schema = schema(&.{ .{ "file", "string", false }, .{ "filter", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .ci_artifacts,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
        .handler = handler(.ci, "zigJunit"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_matrix_check = tool(.{
        .description = "Run build/test checks across configured Zig binaries.",
        .input_schema = schema(&.{ .{ "zig_paths", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .ci_artifacts,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_user_command = true, .executes_backend = true },
        .handler = handler(.ci, "zigMatrixCheck"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_lint = tool(.{
        .description = "Run zwanzig as optional Zig static-analysis backend with JSON output by default.",
        .input_schema = schema(&.{ .{ "path", "string", false }, .{ "rules_do", "string", false }, .{ "rules_skip", "string", false }, .{ "config", "string", false }, .{ "args", "string", false } }),
        .read_only = true,
        .group = .zwanzig,
        .risk = .{ .executes_backend = true },
        .handler = handler(.zwanzig, "zigLint"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_lint_sarif = tool(.{
        .description = "Run zwanzig with SARIF output.",
        .input_schema = schema(&.{ .{ "path", "string", false }, .{ "rules_do", "string", false }, .{ "rules_skip", "string", false }, .{ "config", "string", false }, .{ "args", "string", false } }),
        .read_only = true,
        .group = .zwanzig,
        .risk = .{ .executes_backend = true },
        .handler = handler(.zwanzig, "zigLintSarif"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_lint_rules = tool(.{
        .description = "List zwanzig rules when the backend is installed.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .zwanzig,
        .risk = .{ .executes_backend = true },
        .handler = handler(.zwanzig, "zigLintRules"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_analysis_graphs = tool(.{
        .description = "Run zwanzig graph/visualization options, writing only to an explicit workspace output path.",
        .input_schema = schema(&.{ .{ "path", "string", true }, .{ "output", "string", true }, .{ "args", "string", false } }),
        .read_only = false,
        .group = .zwanzig,
        .risk = .{ .writes_artifacts = true, .executes_backend = true },
        .handler = handler(.zwanzig, "zigAnalysisGraphs"),
        .plan = .{ .workspace_artifact = "Writes an explicit workspace-local artifact path and may use a configured backend; never writes source by default." },
    });
    pub const zig_profile_plan = tool(.{
        .description = "Return platform-specific profiling capture suggestions for the workspace.",
        .input_schema = schema(&.{.{ "binary", "string", false }}),
        .read_only = true,
        .group = .profiling,
        .handler = handler(.profiling, "zigProfilePlan"),
        .plan = .{ .pure_analysis = "Profiling command planner; returns platform-specific capture suggestions without running profilers." },
    });
    pub const zig_profile_run = tool(.{
        .description = "Run a user-specified profiler command in the workspace.",
        .input_schema = schema(&.{ .{ "command", "string", true }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .profiling,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_user_command = true },
        .handler = handler(.profiling, "zigProfileRun"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_flamegraph = tool(.{
        .description = "Convert profiler output to SVG through zflame.",
        .input_schema = schema(&.{ .{ "format", "string", false }, .{ "input", "string", true }, .{ "output", "string", true }, .{ "title", "string", false }, .{ "palette", "string", false }, .{ "min_width", "string", false }, .{ "hash", "boolean", false } }),
        .read_only = false,
        .group = .profiling,
        .risk = .{ .writes_artifacts = true, .executes_backend = true },
        .handler = handler(.profiling, "zigFlamegraph"),
        .plan = .{ .workspace_artifact = "Writes an explicit workspace-local artifact path and may use a configured backend; never writes source by default." },
    });
    pub const zig_flamegraph_diff = tool(.{
        .description = "Create a differential folded stack file through diff-folded, then render it through zflame.",
        .input_schema = schema(&.{ .{ "before", "string", true }, .{ "after", "string", true }, .{ "output", "string", true }, .{ "title", "string", false } }),
        .read_only = false,
        .group = .profiling,
        .risk = .{ .writes_artifacts = true, .executes_backend = true },
        .handler = handler(.profiling, "zigFlamegraphDiff"),
        .plan = .{ .workspace_artifact = "Writes an explicit workspace-local artifact path and may use a configured backend; never writes source by default." },
    });
};

pub const ToolId = std.meta.DeclEnum(definitions);
const definition_decls = std.meta.declarations(definitions);

pub const entries = buildEntries();
pub const specs = buildSpecs();

pub const group_specs = [_]GroupSpec{
    .{ .group = .discovery, .keywords = &.{ "capabilities", "tool index", "schema", "doctor", "health", "workspace", "context pack", "agent guide", "next action", "toolchain", "version manager", "mise", "asdf", "zvm", "zigup", "fmt", "formatter", "formatting", "zig fmt" } },
    .{ .group = .agent_workflows, .keywords = &.{ "agent", "codex", "claude", "context pack", "next action", "validate patch", "failure fusion", "impact analysis", "project profile", "patch guard", "done check", "readiness" } },
    .{ .group = .core_zig, .keywords = &.{ "zig", "build", "test", "check", "ast-check", "compiler diagnostics", "compile error index", "translate-c" } },
    .{ .group = .formatting_and_edits, .keywords = &.{ "fmt", "formatter", "formatting", "zig fmt", "patch preview", "unified diff", "rename", "code action", "apply=true" } },
    .{ .group = .zls, .keywords = &.{ "zls", "lsp", "diagnostics", "hover", "definition", "references", "completion", "symbols", "unsaved document" } },
    .{ .group = .docs, .keywords = &.{ "docs", "stdlib", "builtin", "langref", "language reference" } },
    .{ .group = .static_analysis, .keywords = &.{ "heuristic", "confidence", "imports", "declarations", "allocation", "error set", "public api", "api diff", "breaking change", "build graph", "build options", "test discovery", "test map", "test select", "changed files", "dependency inspector", "target matrix", "test failure triage", "symbol cache", "package cache doctor" } },
    .{ .group = .ci_artifacts, .keywords = &.{ "ci", "annotations", "junit", "matrix", "multiple zig versions", "test report" } },
    .{ .group = .zwanzig, .keywords = &.{ "zwanzig", "lint", "linter", "static analysis", "sarif", "rules", "dot graph" } },
    .{ .group = .profiling, .keywords = &.{ "profile", "profiling", "perf", "dtrace", "sample", "xctrace", "vtune", "zflame", "flamegraph", "diff flamegraph" } },
};

fn buildEntries() [definition_decls.len]ToolEntry {
    var result: [definition_decls.len]ToolEntry = undefined;
    inline for (definition_decls, 0..) |decl, index| {
        const id = @field(ToolId, decl.name);
        const definition = @field(definitions, decl.name);
        const meta = ToolMeta{
            .id = id,
            .name = decl.name,
            .description = definition.description,
            .input_schema = definition.input_schema,
            .read_only = definition.read_only,
        };
        result[index] = .{
            .id = id,
            .name = decl.name,
            .meta = meta,
            .group = definition.group,
            .risk = definition.risk,
            .handler = definition.handler,
            .plan = definition.plan,
        };
    }
    return result;
}

fn buildSpecs() [definition_decls.len]ToolMeta {
    var result: [definition_decls.len]ToolMeta = undefined;
    inline for (entries, 0..) |entry, index| result[index] = entry.meta;
    return result;
}

pub fn entryFor(id: ToolId) ToolEntry {
    return entries[@intFromEnum(id)];
}

pub fn find(name: []const u8) ?ToolMeta {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.meta;
    }
    return null;
}

pub fn findEntry(name: []const u8) ?ToolEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub fn groupFor(id: ToolId) ToolGroup {
    return entryFor(id).group;
}

pub fn groupName(group: ToolGroup) []const u8 {
    return @tagName(group);
}

pub fn groupKeywords(group: ToolGroup) []const []const u8 {
    inline for (group_specs) |spec| {
        if (spec.group == group) return spec.keywords;
    }
    unreachable;
}

pub fn riskFor(id: ToolId) ToolRisk {
    return entryFor(id).risk;
}

pub fn planFor(id: ToolId) PlanPolicy {
    return entryFor(id).plan;
}

pub fn commandPlanFor(id: ToolId) ?CommandPlan {
    return switch (planFor(id)) {
        .exact_command => |plan| plan,
        else => null,
    };
}

pub fn planKind(plan: PlanPolicy) []const u8 {
    return switch (plan) {
        .exact_command => "exact_command",
        .dynamic_command => "dynamic_command",
        .zls_request => "zls_request",
        .apply_gated_mutation => "apply_gated_mutation",
        .workspace_artifact => "workspace_artifact",
        .pure_analysis => "pure_analysis",
        .not_plannable => "not_plannable",
    };
}

pub fn riskLevel(risk: ToolRisk) []const u8 {
    if (risk.writes_source or risk.executes_user_command) return "high";
    if (risk.executes_project_code or risk.writes_artifacts) return "medium";
    if (risk.mutates_lsp_state or risk.executes_backend) return "low";
    return "none";
}

pub fn riskValue(allocator: std.mem.Allocator, spec: ToolMeta) !std.json.Value {
    const risk_value = riskFor(spec.id);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "level", .{ .string = riskLevel(risk_value) });
    try obj.put(allocator, "mcp_read_only_hint", .{ .bool = readOnlyHintFor(spec) });
    try obj.put(allocator, "writes_source", .{ .bool = risk_value.writes_source });
    try obj.put(allocator, "writes_artifacts", .{ .bool = risk_value.writes_artifacts });
    try obj.put(allocator, "writes_require_apply", .{ .bool = risk_value.writes_require_apply });
    try obj.put(allocator, "preview_by_default", .{ .bool = risk_value.preview_by_default });
    try obj.put(allocator, "mutates_lsp_state", .{ .bool = risk_value.mutates_lsp_state });
    try obj.put(allocator, "executes_project_code", .{ .bool = risk_value.executes_project_code });
    try obj.put(allocator, "executes_user_command", .{ .bool = risk_value.executes_user_command });
    try obj.put(allocator, "executes_backend", .{ .bool = risk_value.executes_backend });
    return .{ .object = obj };
}

pub fn readOnlyHintFor(spec: ToolMeta) bool {
    const risk_value = riskFor(spec.id);
    return spec.read_only and
        !risk_value.writes_source and
        !risk_value.writes_artifacts and
        !risk_value.mutates_lsp_state and
        !risk_value.executes_project_code and
        !risk_value.executes_user_command;
}

pub fn idempotentHintFor(spec: ToolMeta) bool {
    const risk_value = riskFor(spec.id);
    return readOnlyHintFor(spec) and
        !risk_value.writes_source and
        !risk_value.writes_artifacts and
        !risk_value.mutates_lsp_state and
        !risk_value.executes_project_code and
        !risk_value.executes_user_command;
}

pub fn destructiveHintFor(spec: ToolMeta) bool {
    const risk_value = riskFor(spec.id);
    if (risk_value.writes_require_apply and risk_value.preview_by_default) return false;
    return !spec.read_only;
}

test "manifest declares one entry for each tool id" {
    try std.testing.expectEqual(@typeInfo(ToolId).@"enum".fields.len, entries.len);
    try std.testing.expectEqual(entries.len, specs.len);
}

test "tool names are unique" {
    for (specs, 0..) |left, left_index| {
        for (specs[left_index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, left.name, right.name));
        }
    }
}

test "tool schemas use validator-supported JSON field types" {
    for (specs) |spec| {
        for (spec.input_schema.fields) |field| {
            try std.testing.expect(std.mem.eql(u8, field[1], "string") or
                std.mem.eql(u8, field[1], "boolean") or
                std.mem.eql(u8, field[1], "integer"));
        }
    }
}

test "tool planning policies expose exact command plans only for exact commands" {
    for (entries) |entry| {
        try std.testing.expect(planKind(entry.plan).len > 0);
        switch (entry.plan) {
            .exact_command => try std.testing.expect(commandPlanFor(entry.id) != null),
            else => try std.testing.expect(commandPlanFor(entry.id) == null),
        }
    }
}

test "risk metadata distinguishes read-only annotations from code execution" {
    try std.testing.expect(find("zig_profile_run").?.read_only);
    const profile_risk = riskFor(.zig_profile_run);
    try std.testing.expect(profile_risk.executes_user_command);
    try std.testing.expectEqualStrings("high", riskLevel(profile_risk));
    try std.testing.expect(!readOnlyHintFor(find("zig_profile_run").?));
    try std.testing.expect(!idempotentHintFor(find("zig_profile_run").?));

    const build_risk = riskFor(.zig_build);
    try std.testing.expect(build_risk.executes_project_code);
    try std.testing.expectEqualStrings("medium", riskLevel(build_risk));
    try std.testing.expect(!readOnlyHintFor(find("zig_build").?));
    try std.testing.expect(!idempotentHintFor(find("zig_build").?));

    const validation_risk = riskFor(.zigar_validate_patch);
    try std.testing.expect(validation_risk.executes_project_code);
    try std.testing.expect(validation_risk.writes_artifacts);

    const triage_risk = riskFor(.zig_test_failure_triage);
    try std.testing.expect(triage_risk.executes_project_code);

    const fmt = find("zig_format").?;
    try std.testing.expect(riskFor(.zig_format).writes_require_apply);
    try std.testing.expect(riskFor(.zig_format).writes_artifacts);
    try std.testing.expect(!destructiveHintFor(fmt));
    try std.testing.expect(!readOnlyHintFor(fmt));

    const matrix_risk = riskFor(.zig_matrix_check);
    try std.testing.expect(matrix_risk.executes_user_command);
    try std.testing.expectEqualStrings("high", riskLevel(matrix_risk));
    try std.testing.expect(!readOnlyHintFor(find("zig_matrix_check").?));

    try std.testing.expect(readOnlyHintFor(find("zig_version").?));
    try std.testing.expect(idempotentHintFor(find("zig_version").?));
}
