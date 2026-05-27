const backend_contracts = @import("backend_contracts.zig");

/// Zig release line this backend catalog is validated against.
pub const supported_zig_version = "0.16.0";

/// Backend installation and probe metadata exposed in setup catalogs.
pub const Backend = struct {
    name: []const u8,
    optional: bool,
    path_flag: []const u8,
    default_path: []const u8,
    purpose: []const u8,
    compatibility: []const u8,
    install_strategy: []const u8,
    tools: []const []const u8,
    probe_argv: []const []const u8,
    verify: []const []const u8,
};

/// Configured executable paths used when rendering backend setup metadata.
pub const Paths = struct {
    zig_path: []const u8 = "zig",
    zls_path: []const u8 = "zls",
    zlint_path: []const u8 = "zlint",
    zwanzig_path: []const u8 = "zwanzig",
    zflame_path: []const u8 = "zflame",
    diff_folded_path: []const u8 = "diff-folded",
};

/// Supported required and optional backends known to zigars.
pub const backends = [_]Backend{
    .{
        .name = "zig",
        .optional = false,
        .path_flag = backend_contracts.BackendId.zig.pathFlag(),
        .default_path = backend_contracts.BackendId.zig.defaultPath(),
        .purpose = "required Zig compiler and formatter backend",
        .compatibility = "must be Zig " ++ supported_zig_version,
        .install_strategy = "Install with a version manager or package manager that can pin Zig " ++ supported_zig_version ++ "; pass an absolute path in CI and MCP client config.",
        .tools = &.{ "zig_build", "zig_test", "zig_check", "zig_format", "zig_env", "zig_targets" },
        .probe_argv = backend_contracts.zig_probe_argv[0..],
        .verify = &.{ "zig version", "zig env", "zigars_doctor {\"probe_backends\":true}" },
    },
    .{
        .name = "zls",
        .optional = true,
        .path_flag = backend_contracts.BackendId.zls.pathFlag(),
        .default_path = backend_contracts.BackendId.zls.defaultPath(),
        .purpose = "language-server-backed diagnostics, symbols, hover, references, completion, rename, and code actions",
        .compatibility = "keep ZLS on the same Zig release line as Zig " ++ supported_zig_version,
        .install_strategy = "Install or build ZLS for Zig " ++ supported_zig_version ++ "; pin it in the project dev shell or CI image and pass --zls-path.",
        .tools = &.{ "zig_diagnostics", "zig_hover", "zig_definition", "zig_references", "zig_completion", "zig_rename", "zig_code_actions" },
        .probe_argv = backend_contracts.zls_probe_argv[0..],
        .verify = &.{ "zls --version", "zigars_doctor {\"probe_backends\":true}" },
    },
    .{
        .name = backend_contracts.BackendId.zlint.name(),
        .optional = true,
        .path_flag = backend_contracts.BackendId.zlint.pathFlag(),
        .default_path = backend_contracts.BackendId.zlint.defaultPath(),
        .purpose = "optional ZLint diagnostics, AST reference evidence, apply-gated fixes, rule catalog, and SARIF conversion backend",
        .compatibility = "ZLint CLI that accepts --format json for diagnostics; --print-ast and --fix enable richer references and source fixes, while --rules is treated as optional when absent",
        .install_strategy = "Pin a zlint executable in the project toolchain, dev shell, or CI image and pass --zlint-path; zigars does not install it automatically.",
        .tools = &.{ "zig_zlint", "zig_zlint_sarif", "zig_zlint_rules", "zig_zlint_fix" },
        .probe_argv = backend_contracts.zlint_probe_argv[0..],
        .verify = backend_contracts.zlint_verify[0..],
    },
    .{
        .name = backend_contracts.BackendId.zwanzig.name(),
        .optional = true,
        .path_flag = backend_contracts.BackendId.zwanzig.pathFlag(),
        .default_path = backend_contracts.BackendId.zwanzig.defaultPath(),
        .purpose = "optional lint, SARIF, rule listing, and analysis graph backend",
        .compatibility = "build with the same Zig release used by the workspace when source builds are required",
        .install_strategy = "Pin a zwanzig executable in the project toolchain, dev shell, or CI image; for zigars release validation, use tools/release/real_backend_pins.json and .github/scripts/setup-real-backends.sh.",
        .tools = &.{ "zig_lint", "zig_lint_sarif", "zig_lint_rules", "zig_analysis_graphs" },
        .probe_argv = backend_contracts.zwanzig_probe_argv[0..],
        .verify = backend_contracts.zwanzig_verify[0..],
    },
    .{
        .name = backend_contracts.BackendId.zflame.name(),
        .optional = true,
        .path_flag = backend_contracts.BackendId.zflame.pathFlag(),
        .default_path = backend_contracts.BackendId.zflame.defaultPath(),
        .purpose = "optional canonical flamegraph SVG renderer for externally captured profiler data",
        .compatibility = backend_contracts.zflame_compatibility_baseline,
        .install_strategy = "Pin a zflame executable in the project toolchain, dev shell, or CI image; for zigars release validation, build the repo-pinned source with .github/scripts/setup-real-backends.sh.",
        .tools = &.{ "zig_flamegraph", "zig_flamegraph_diff" },
        .probe_argv = backend_contracts.zflame_probe_argv[0..],
        .verify = backend_contracts.zflame_verify[0..],
    },
    .{
        .name = backend_contracts.BackendId.diff_folded.name(),
        .optional = true,
        .path_flag = backend_contracts.BackendId.diff_folded.pathFlag(),
        .default_path = backend_contracts.BackendId.diff_folded.defaultPath(),
        .purpose = "optional folded-stack differ used before zflame renders differential flamegraphs",
        .compatibility = backend_contracts.diff_folded_compatibility_baseline,
        .install_strategy = "Pin a diff-folded executable beside zflame when differential flamegraphs are part of the project workflow; the zigars release-validation pin is documented in tools/release/real_backend_pins.json.",
        .tools = &.{"zig_flamegraph_diff"},
        .probe_argv = backend_contracts.diff_folded_probe_argv[0..],
        .verify = backend_contracts.diff_folded_verify[0..],
    },
};
