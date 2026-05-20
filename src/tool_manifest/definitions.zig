const types = @import("types.zig");
const backend_contracts = @import("../backend_contracts.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const handler = types.handler;
const fieldHint = types.fieldHint;
const docs_plan = "Offline docs lookup; no network, ZLS, or optional backend.";

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
    pub const zigar_backend_catalog = tool(.{
        .description = "Return packaged setup metadata for Zig, ZLS, zwanzig, zflame, and diff-folded backends.",
        .input_schema = schema(&.{
            .{ "include_configured_paths", "boolean", false },
        }),
        .read_only = true,
        .group = .discovery,
        .handler = handler(.discovery, "zigarBackendCatalog"),
        .plan = .{ .pure_analysis = "Backend setup catalog lookup; does not execute tools or mutate workspace state." },
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
        .input_schema = schemaWithHints(&.{ .{ "mode", "string", false }, .{ "token_budget", "integer", false }, .{ "include", "string", false } }, &.{
            fieldHint("mode", .{ .description = "Context-pack depth.", .default_string = "standard", .enum_values = &.{ "tiny", "standard", "deep" } }),
        }),
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
        .description = "Return compact Codex/Claude/Gemini/Hermes/generic instructions for using zigar efficiently.",
        .input_schema = schemaWithHints(&.{ .{ "client", "string", false }, .{ "task", "string", false } }, &.{
            fieldHint("client", .{ .description = "Agent/client profile.", .default_string = "generic", .enum_values = &.{ "codex", "claude", "gemini", "hermes", "generic" } }),
        }),
        .read_only = true,
        .group = .agent_workflows,
        .handler = handler(.agent, "zigarAgentGuide"),
        .plan = .{ .pure_analysis = "Client guidance lookup; returns deterministic instructions without executing tools." },
    });
    pub const zigar_validate_patch = tool(.{
        .description = "Run an agent-friendly changed-file validation loop and return structured blockers.",
        .input_schema = schemaWithHints(&.{ .{ "mode", "string", false }, .{ "changed_files", "string", false }, .{ "stop_on_failure", "boolean", false }, .{ "timeout_ms", "integer", false } }, &.{
            fieldHint("mode", .{ .description = "Validation depth.", .default_string = "standard", .enum_values = &.{ "quick", "standard", "full" } }),
        }),
        .read_only = true,
        .group = .agent_workflows,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
        .handler = handler(.agent, "zigarValidatePatch"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zigar_failure_fusion = tool(.{
        .description = "Fuse compiler/test output, primary failure data, impact hints, and suggested zigar tools.",
        .input_schema = schemaWithHints(&.{ .{ "text", "string", false }, .{ "command", "string", false }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }, &.{
            fieldHint("command", .{ .description = "Focused Zig command mode.", .enum_values = &.{ "check", "test", "build", "build-test", "fmt-check" } }),
        }),
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
        .input_schema = schemaWithHints(&.{ .{ "text", "string", false }, .{ "command", "string", false }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }, &.{
            fieldHint("command", .{ .description = "Focused Zig command mode.", .enum_values = &.{ "check", "test", "build", "build-test", "fmt-check" } }),
        }),
        .read_only = true,
        .group = .core_zig,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
        .handler = handler(.core, "zigCompileErrorIndex"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_explain_errors = tool(.{
        .description = "Run a focused Zig command and return parsed compiler findings plus deterministic next actions.",
        .input_schema = schemaWithHints(&.{ .{ "command", "string", false }, .{ "file", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }, &.{
            fieldHint("command", .{ .description = "Focused Zig command mode.", .enum_values = &.{ "check", "test", "build", "build-test", "fmt-check" } }),
        }),
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
        .risk = .{ .writes_source = true, .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true, .mutates_lsp_state = true, .executes_backend = true },
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
        .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true, .mutates_lsp_state = true, .executes_backend = true },
        .handler = handler(.edit_zls, "zigRename"),
        .plan = .{ .apply_gated_mutation = "Preview-first workspace mutation; writes only when apply=true and reports risk metadata before changes." },
    });
    pub const zig_code_actions = tool(.{
        .description = "Get ZLS code actions for a range.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "start_line", "integer", true }, .{ "start_char", "integer", true }, .{ "end_line", "integer", true }, .{ "end_char", "integer", true } }),
        .read_only = true,
        .group = .formatting_and_edits,
        .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
        .handler = handler(.edit_zls, "zigCodeActions"),
        .plan = .{ .zls_request = .{ .method = "textDocument/codeAction", .requires_document_sync = true, .required_capability = "codeActionProvider" } },
    });
    pub const zig_code_action_apply = tool(.{
        .description = "Preview or apply one ZLS code action by index. Writes only with apply=true.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "start_line", "integer", true }, .{ "start_char", "integer", true }, .{ "end_line", "integer", true }, .{ "end_char", "integer", true }, .{ "action_index", "integer", true }, .{ "apply", "boolean", false } }),
        .read_only = false,
        .group = .formatting_and_edits,
        .risk = .{ .writes_source = true, .writes_require_apply = true, .preview_by_default = true, .mutates_lsp_state = true, .executes_backend = true },
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
        .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
        .handler = handler(.edit_zls, "zigDiagnostics"),
        .plan = .{ .zls_request = .{ .method = "textDocument/publishDiagnostics with ast-check fallback", .requires_document_sync = true } },
    });
    pub const zig_diagnostics_all = tool(.{
        .description = "Aggregate diagnostics from ZLS publish/pull diagnostics and `zig ast-check`.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "wait_ms", "integer", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
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
        .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
        .handler = handler(.edit_zls, "zigHover"),
        .plan = .{ .zls_request = .{ .method = "textDocument/hover", .requires_document_sync = true, .required_capability = "hoverProvider" } },
    });
    pub const zig_definition = tool(.{
        .description = "Get ZLS definition location for a Zig symbol.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
        .handler = handler(.edit_zls, "zigDefinition"),
        .plan = .{ .zls_request = .{ .method = "textDocument/definition", .requires_document_sync = true, .required_capability = "definitionProvider" } },
    });
    pub const zig_references = tool(.{
        .description = "Find ZLS references for a Zig symbol.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true }, .{ "include_declaration", "boolean", false } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
        .handler = handler(.edit_zls, "zigReferences"),
        .plan = .{ .zls_request = .{ .method = "textDocument/references", .requires_document_sync = true, .required_capability = "referencesProvider" } },
    });
    pub const zig_completion = tool(.{
        .description = "Get ZLS completions at a Zig source position.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
        .handler = handler(.edit_zls, "zigCompletion"),
        .plan = .{ .zls_request = .{ .method = "textDocument/completion", .requires_document_sync = true, .required_capability = "completionProvider" } },
    });
    pub const zig_signature_help = tool(.{
        .description = "Get ZLS signature help at a Zig source position.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false }, .{ "line", "integer", true }, .{ "character", "integer", true } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
        .handler = handler(.edit_zls, "zigSignatureHelp"),
        .plan = .{ .zls_request = .{ .method = "textDocument/signatureHelp", .requires_document_sync = true, .required_capability = "signatureHelpProvider" } },
    });
    pub const zig_document_symbols = tool(.{
        .description = "List ZLS document symbols for a Zig source file.",
        .input_schema = schema(&.{ .{ "file", "string", true }, .{ "content", "string", false } }),
        .read_only = true,
        .group = .zls,
        .risk = .{ .mutates_lsp_state = true, .executes_backend = true },
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
    pub const zig_builtin_list = tool(.{ .description = "List bundled curated Zig builtin docs; source is partial curated zigar data.", .input_schema = schema(&.{}), .read_only = true, .group = .docs, .handler = handler(.docs, "zigBuiltinList"), .plan = .{ .pure_analysis = docs_plan } });
    pub const zig_builtin_list_json = tool(.{ .description = "Return bundled curated Zig builtin docs with source, completeness, count, and ranking metadata.", .input_schema = schema(&.{}), .read_only = true, .group = .docs, .handler = handler(.docs, "zigBuiltinListJson"), .plan = .{ .pure_analysis = docs_plan } });
    pub const zig_builtin_doc = tool(.{ .description = "Search bundled curated Zig builtin docs; text output includes partial-curated source metadata.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .handler = handler(.docs, "zigBuiltinDoc"), .plan = .{ .pure_analysis = docs_plan } });
    pub const zig_builtin_doc_json = tool(.{ .description = "Search bundled curated Zig builtin docs with source, completeness, query, limit, result-count, no-result, and ranking metadata.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .handler = handler(.docs, "zigBuiltinDocJson"), .plan = .{ .pure_analysis = docs_plan } });
    pub const zig_std_search = tool(.{ .description = "Search local Zig stdlib .zig source files; this is source scanning, not rendered stdlib documentation.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .handler = handler(.docs, "zigStdSearch"), .plan = .{ .pure_analysis = docs_plan } });
    pub const zig_std_search_json = tool(.{ .description = "Search local Zig stdlib .zig source files with source-scan provenance, query, limit, result-count, no-result, and ranking metadata.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .handler = handler(.docs, "zigStdSearchJson"), .plan = .{ .pure_analysis = docs_plan } });
    pub const zig_std_item = tool(.{ .description = "Look up exact Zig stdlib declaration-name matches in local .zig source; not rendered stdlib documentation.", .input_schema = schema(&.{ .{ "name", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .handler = handler(.docs, "zigStdItem"), .plan = .{ .pure_analysis = docs_plan } });
    pub const zig_std_item_json = tool(.{ .description = "Look up exact Zig stdlib declaration-name matches with source-scan provenance, query, limit, result-count, no-result, and ranking metadata.", .input_schema = schema(&.{ .{ "name", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .handler = handler(.docs, "zigStdItemJson"), .plan = .{ .pure_analysis = docs_plan } });
    pub const zig_lang_ref_search = tool(.{ .description = "Search installed langref HTML or bundled partial langref fallback; text includes source/completeness metadata.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .handler = handler(.docs, "zigLangRefSearch"), .plan = .{ .pure_analysis = docs_plan } });
    pub const zig_lang_ref_search_json = tool(.{ .description = "Search installed langref HTML or bundled partial langref fallback with source, completeness, query, limit, result-count, no-result, and ranking metadata.", .input_schema = schema(&.{ .{ "query", "string", true }, .{ "limit", "integer", false } }), .read_only = true, .group = .docs, .handler = handler(.docs, "zigLangRefSearchJson"), .plan = .{ .pure_analysis = docs_plan } });
    pub const zig_import_graph = tool(.{
        .description = "Build a heuristic import graph from workspace Zig files.",
        .input_schema = schema(&.{.{ "limit", "integer", false }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigImportGraph"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_import_graph_json = tool(.{
        .description = "Build a JSON-native heuristic import graph from workspace Zig files.",
        .input_schema = schema(&.{.{ "limit", "integer", false }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigImportGraphJson"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_ast_imports = tool(.{ .description = "Return parser-backed @import calls for a Zig file using std.zig.Ast tokens.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true, .group = .static_analysis, .handler = handler(.static_analysis, "zigAstImports"), .plan = .{ .pure_analysis = "Parser-backed source analysis; parses one Zig file with std.zig.Ast without executing compiler semantic analysis." }, .static_analysis_tier = .parser_backed });
    pub const zig_decl_summary = tool(.{
        .description = "Heuristically summarize declarations in a Zig file.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigDeclSummary"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_decl_summary_json = tool(.{
        .description = "Return a JSON-native heuristic declaration summary for a Zig file.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigDeclSummaryJson"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_ast_decl_summary = tool(.{ .description = "Return a parser-backed declaration summary for a Zig file using std.zig.Ast.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true, .group = .static_analysis, .handler = handler(.static_analysis, "zigAstDeclSummary"), .plan = .{ .pure_analysis = "Parser-backed source analysis; parses one Zig file with std.zig.Ast without executing compiler semantic analysis." }, .static_analysis_tier = .parser_backed });
    pub const zig_allocations = tool(.{
        .description = "Find likely allocation-related call sites in a Zig file.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigAllocations"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_error_sets = tool(.{
        .description = "Find likely error-related sites in a Zig file.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigErrorSets"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_public_api = tool(.{
        .description = "Find likely public API declarations in a Zig file.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigPublicApi"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_dead_decl_candidates = tool(.{
        .description = "List private declaration candidates that need reference checks before deletion.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigDeadDeclCandidates"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_build_graph = tool(.{
        .description = "Parse build.zig/build.zig.zon heuristically into modules, dependencies, build steps, and artifacts.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigBuildGraph"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_build_targets = tool(.{
        .description = "Return likely build steps, artifacts, modules, and suggested zig build commands.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigBuildTargets"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_build_options = tool(.{
        .description = "Heuristically discover available `zig build -D...` options from build.zig and standard Zig build knobs.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigBuildOptions"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_file_owner = tool(.{
        .description = "Map a workspace Zig file to likely build module/artifact/test commands.",
        .input_schema = schema(&.{.{ "file", "string", true }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigFileOwner"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_import_resolve = tool(.{
        .description = "Heuristically resolve a Zig @import string against workspace modules, packages, stdlib, or a source file.",
        .input_schema = schema(&.{ .{ "import", "string", true }, .{ "from", "string", false } }),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigImportResolve"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_test_discover = tool(.{
        .description = "Heuristically discover Zig test declarations and runnable test commands.",
        .input_schema = schema(&.{.{ "limit", "integer", false }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigTestDiscover"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_ast_tests = tool(.{ .description = "Return parser-backed Zig test declarations for a Zig file using std.zig.Ast.", .input_schema = schema(&.{.{ "file", "string", true }}), .read_only = true, .group = .static_analysis, .handler = handler(.static_analysis, "zigAstTests"), .plan = .{ .pure_analysis = "Parser-backed source analysis; parses one Zig file with std.zig.Ast without executing compiler semantic analysis." }, .static_analysis_tier = .parser_backed });
    pub const zig_changed_files_plan = tool(.{
        .description = "Inspect git changes and recommend the smallest useful Zig validation commands.",
        .input_schema = schema(&.{.{ "timeout_ms", "integer", false }}),
        .read_only = true,
        .group = .static_analysis,
        .risk = .{ .executes_backend = true },
        .handler = handler(.static_analysis, "zigChangedFilesPlan"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_dependency_inspect = tool(.{
        .description = "Inspect build.zig.zon dependencies, hashes, local package/cache state, and dependency wiring risks.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigDependencyInspect"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_target_matrix_plan = tool(.{
        .description = "Plan cross-target Zig build/test matrix commands without running them.",
        .input_schema = schema(&.{ .{ "targets", "string", false }, .{ "steps", "string", false } }),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigTargetMatrixPlan"),
        .plan = .{ .pure_analysis = "Command matrix planner; returns candidate build/test commands without running them." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_test_failure_triage = tool(.{
        .description = "Parse Zig test output or run tests and return failing tests, panic clues, and rerun commands.",
        .input_schema = schema(&.{ .{ "text", "string", false }, .{ "file", "string", false }, .{ "filter", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .static_analysis,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
        .handler = handler(.static_analysis, "zigTestFailureTriage"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
        .static_analysis_tier = .compiler_backed,
    });
    pub const zig_workspace_symbol_cache = tool(.{
        .description = "Build or inspect a cached heuristic workspace symbol/import index for repeated MCP calls.",
        .input_schema = schema(&.{ .{ "refresh", "boolean", false }, .{ "query", "string", false }, .{ "limit", "integer", false } }),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigWorkspaceSymbolCache"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_package_cache_doctor = tool(.{
        .description = "Diagnose Zig package/cache directories, git-tracked generated artifacts, and package hash risks.",
        .input_schema = schema(&.{.{ "timeout_ms", "integer", false }}),
        .read_only = true,
        .group = .static_analysis,
        .risk = .{ .executes_backend = true },
        .handler = handler(.static_analysis, "zigPackageCacheDoctor"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_test_map = tool(.{
        .description = "Build a deterministic map of Zig test declarations, files, likely symbols, and test commands.",
        .input_schema = schema(&.{.{ "limit", "integer", false }}),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigTestMap"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_test_select = tool(.{
        .description = "Recommend focused Zig test commands for changed files or symbols.",
        .input_schema = schema(&.{ .{ "files", "string", false }, .{ "symbols", "string", false }, .{ "limit", "integer", false } }),
        .read_only = true,
        .group = .static_analysis,
        .handler = handler(.static_analysis, "zigTestSelect"),
        .plan = .{ .pure_analysis = "Static workspace analysis; reads project files and returns deterministic guidance without executing backends." },
        .static_analysis_tier = .advisory_orientation,
    });
    pub const zig_public_api_diff = tool(.{
        .description = "Compare heuristic public Zig declaration snapshots and report likely breaking changes.",
        .input_schema = schemaWithHints(&.{ .{ "file", "string", false }, .{ "before", "string", false }, .{ "after", "string", false }, .{ "baseline_ref", "string", false } }, &.{
            .{ .field_name = "before", .hint = .{ .description = "Baseline public API source text. Omit this and pass file/baseline_ref to read from git." } },
            .{ .field_name = "after", .hint = .{ .description = "Current public API source text. Omit this and pass file to read from the workspace." } },
        }),
        .read_only = true,
        .group = .static_analysis,
        .risk = .{ .executes_backend = true },
        .handler = handler(.static_analysis, "zigPublicApiDiff"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
        .static_analysis_tier = .advisory_orientation,
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
        .description = "Run Zig tests and return a command-level JUnit XML artifact with raw output metadata.",
        .input_schema = schema(&.{ .{ "file", "string", false }, .{ "filter", "string", false }, .{ "args", "string", false }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .ci_artifacts,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_backend = true },
        .handler = handler(.ci, "zigJunit"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_matrix_check = tool(.{
        .description = "Run build/test checks across configured Zig binaries with direct per-entry status fields.",
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
        .static_analysis_tier = .zwanzig_backed,
    });
    pub const zig_lint_sarif = tool(.{
        .description = "Run optional zwanzig-backed static analysis with SARIF output.",
        .input_schema = schema(&.{ .{ "path", "string", false }, .{ "rules_do", "string", false }, .{ "rules_skip", "string", false }, .{ "config", "string", false }, .{ "args", "string", false } }),
        .read_only = true,
        .group = .zwanzig,
        .risk = .{ .executes_backend = true },
        .handler = handler(.zwanzig, "zigLintSarif"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
        .static_analysis_tier = .zwanzig_backed,
    });
    pub const zig_lint_rules = tool(.{
        .description = "List optional zwanzig-backed lint/static-analysis rules when the backend is installed.",
        .input_schema = schema(&.{}),
        .read_only = true,
        .group = .zwanzig,
        .risk = .{ .executes_backend = true },
        .handler = handler(.zwanzig, "zigLintRules"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
        .static_analysis_tier = .zwanzig_backed,
    });
    pub const zig_analysis_graphs = tool(.{
        .description = "Run an optional zwanzig-backed graph dump mode, writing DOT files under an explicit workspace output directory.",
        .input_schema = schemaWithHints(&.{ .{ "mode", "string", true }, .{ "path", "string", true }, .{ "output", "string", true }, .{ "args", "string", false } }, &.{
            fieldHint("mode", .{ .description = "zwanzig graph dump mode.", .enum_values = backend_contracts.zwanzig_graph_mode_names[0..] }),
            fieldHint("output", .{ .description = "Workspace-relative graph output directory.", .path_kind = "output_path" }),
        }),
        .read_only = false,
        .group = .zwanzig,
        .risk = .{ .writes_artifacts = true, .executes_backend = true },
        .handler = handler(.zwanzig, "zigAnalysisGraphs"),
        .plan = .{ .workspace_artifact = "Writes an explicit workspace-local artifact path and may use a configured backend; never writes source by default." },
        .static_analysis_tier = .zwanzig_backed,
    });
    pub const zig_profile_plan = tool(.{
        .description = "Return structured external-capture plans and zflame rendering next steps without running profilers.",
        .input_schema = schemaWithHints(&.{ .{ "binary", "string", false }, .{ "platform", "string", false }, .{ "output_prefix", "string", false } }, &.{
            fieldHint("platform", .{ .description = "Requested platform override; omitted means use zigar's detected host platform." }),
            fieldHint("output_prefix", .{ .description = "Workspace-relative prefix used in suggested capture/render artifact paths.", .path_kind = "output_path" }),
        }),
        .read_only = true,
        .group = .profiling,
        .handler = handler(.profiling, "zigProfilePlan"),
        .plan = .{ .pure_analysis = "Profiling workflow planner; returns structured external capture suggestions and rendering next steps without running profilers." },
    });
    pub const zig_profile_run = tool(.{
        .description = "Run an explicit user-provided profiler command in the workspace after splitting argv without a shell.",
        .input_schema = schema(&.{ .{ "command", "string", true }, .{ "timeout_ms", "integer", false } }),
        .read_only = true,
        .group = .profiling,
        .risk = .{ .writes_artifacts = true, .executes_project_code = true, .executes_user_command = true },
        .handler = handler(.profiling, "zigProfileRun"),
        .plan = .{ .dynamic_command = "Backend-backed workflow whose exact argv depends on runtime arguments, workspace state, or configured helper paths." },
    });
    pub const zig_flamegraph = tool(.{
        .description = "Render captured profiler output to SVG through zflame with explicit format and auditable artifact metadata.",
        .input_schema = schemaWithHints(&.{ .{ "format", "string", true }, .{ "input", "string", true }, .{ "output", "string", true }, .{ "title", "string", false }, .{ "subtitle", "string", false }, .{ "colors", "string", false }, .{ "width", "integer", false }, .{ "min_width", "integer", false }, .{ "hash", "boolean", false } }, &.{
            fieldHint("format", .{ .description = "Explicit profiler input format passed to zflame.", .enum_values = backend_contracts.zflame_format_names[0..] }),
            fieldHint("colors", .{ .description = "zflame color palette passed as --colors=<palette>." }),
            fieldHint("width", .{ .description = "SVG width passed as --width=<pixels>.", .minimum = 1 }),
            fieldHint("min_width", .{ .description = "Minimum frame width passed as --min-width=<pixels>.", .minimum = 1 }),
        }),
        .read_only = false,
        .group = .profiling,
        .risk = .{ .writes_artifacts = true, .executes_backend = true },
        .handler = handler(.profiling, "zigFlamegraph"),
        .plan = .{ .workspace_artifact = "Writes an explicit workspace-local artifact path and may use a configured backend; never writes source by default." },
    });
    pub const zig_flamegraph_diff = tool(.{
        .description = "Create an auditable differential folded stack through diff-folded, then render it through zflame recursive.",
        .input_schema = schemaWithHints(&.{ .{ "before", "string", true }, .{ "after", "string", true }, .{ "output", "string", true }, .{ "intermediate", "string", false }, .{ "title", "string", false }, .{ "subtitle", "string", false }, .{ "colors", "string", false }, .{ "width", "integer", false }, .{ "min_width", "integer", false }, .{ "hash", "boolean", false } }, &.{
            fieldHint("intermediate", .{ .description = "Optional workspace-relative folded diff output path; defaults to .zigar-cache/profile/diff-<n>.folded.", .path_kind = "output_path" }),
            fieldHint("colors", .{ .description = "zflame color palette passed as --colors=<palette>." }),
            fieldHint("width", .{ .description = "SVG width passed as --width=<pixels>.", .minimum = 1 }),
            fieldHint("min_width", .{ .description = "Minimum frame width passed as --min-width=<pixels>.", .minimum = 1 }),
        }),
        .read_only = false,
        .group = .profiling,
        .risk = .{ .writes_artifacts = true, .executes_backend = true },
        .handler = handler(.profiling, "zigFlamegraphDiff"),
        .plan = .{ .workspace_artifact = "Writes an explicit workspace-local artifact path and may use a configured backend; never writes source by default." },
    });
};
