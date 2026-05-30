//! Backend identity contracts: enumerated backend IDs, normalized failure kinds,
//! artifact behaviors, capability contracts, probe argv constants, and format
//! vocabulary used by the zwanzig and zflame optional backends.
//!
//! All data is comptime-constant. No allocations occur in this module.
const std = @import("std");

/// Backend executable identities used in config, probes, and capability maps.
pub const BackendId = enum {
    zig,
    zls,
    zlint,
    zwanzig,
    zflame,
    diff_folded,

    /// Returns the executable/catalog name for this backend.
    pub fn name(self: BackendId) []const u8 {
        return switch (self) {
            .zig => "zig",
            .zls => "zls",
            .zlint => "zlint",
            .zwanzig => "zwanzig",
            .zflame => "zflame",
            .diff_folded => "diff-folded",
        };
    }

    /// Returns the default executable path for this backend.
    pub fn defaultPath(self: BackendId) []const u8 {
        return self.name();
    }

    /// Returns the CLI flag used to configure this backend path.
    pub fn pathFlag(self: BackendId) []const u8 {
        return switch (self) {
            .zig => "--zig-path",
            .zls => "--zls-path",
            .zlint => "--zlint-path",
            .zwanzig => "--zwanzig-path",
            .zflame => "--zflame-path",
            .diff_folded => "--diff-folded-path",
        };
    }
};

/// Normalized backend failure categories exposed in error payloads.
pub const BackendFailureKind = enum {
    missing_executable,
    permission_denied,
    probe_failed,
    unsupported_capability,
    backend_command_failed,
    backend_output_malformed,
    backend_timed_out,
    workspace_path_rejected,
    workspace_artifact_write_failed,
};

/// Workspace read/write behavior declared for backend-backed capabilities.
pub const ArtifactBehavior = enum {
    none,
    reads_workspace_input,
    writes_workspace_source,
    writes_workspace_directory,
    writes_workspace_svg,
    writes_workspace_folded_diff,
};

/// Contract connecting one tool to its backend command and artifact behavior.
pub const CapabilityContract = struct {
    tool: []const u8,
    backend: BackendId,
    argv_shape: []const u8,
    input_behavior: ArtifactBehavior,
    output_behavior: ArtifactBehavior,
};

/// Complete set of failure kinds clients may receive from backend tools.
pub const supported_failure_kinds = [_]BackendFailureKind{
    .missing_executable,
    .permission_denied,
    .probe_failed,
    .unsupported_capability,
    .backend_command_failed,
    .backend_output_malformed,
    .backend_timed_out,
    .workspace_path_rejected,
    .workspace_artifact_write_failed,
};

/// Cheap probe argv for the required Zig backend.
pub const zig_probe_argv = [_][]const u8{ "zig", "version" };
/// Cheap probe argv for the optional ZLS backend.
pub const zls_probe_argv = [_][]const u8{ "zls", "--version" };
/// Cheap probe argv for the optional ZLint backend.
pub const zlint_probe_argv = [_][]const u8{ "zlint", "--help" };
/// Cheap probe argv for the optional zwanzig backend.
pub const zwanzig_probe_argv = [_][]const u8{ "zwanzig", "--help" };
/// Cheap probe argv for the optional zflame backend.
pub const zflame_probe_argv = [_][]const u8{ "zflame", "--help" };
/// Cheap probe argv for the optional diff-folded backend.
pub const diff_folded_probe_argv = [_][]const u8{ "diff-folded", "--help" };

/// Manual verification commands for zwanzig-backed features.
pub const zwanzig_verify = [_][]const u8{
    "zwanzig --help",
    "zwanzig --format json src",
    "zwanzig --dump-cfg .zigars-cache/zwanzig-graphs src/main.zig",
};
/// Manual verification commands for ZLint-backed features.
pub const zlint_verify = [_][]const u8{
    "zlint --help",
    "zlint --format json src",
    "zlint --print-ast src/main.zig",
    "zig_zlint",
    "zig_zlint_sarif",
    "zig_zlint_fix apply=false",
};
/// Manual verification commands for zflame rendering.
pub const zflame_verify = [_][]const u8{
    "zflame --help",
    "zflame recursive folded.txt > flame.svg",
};
/// Manual verification commands for diff-folded flamegraph diffs.
pub const diff_folded_verify = [_][]const u8{
    "diff-folded --output=delta.folded before.folded after.folded",
    "zig_flamegraph_diff",
};

/// Minimum zflame CLI behavior zigars expects.
pub const zflame_compatibility_baseline = "zflame CLI with explicit format subcommand, --title=, --subtitle=, --colors=, --width=, --min-width=, --hash, and SVG on stdout";
/// Minimum diff-folded CLI behavior zigars expects.
pub const diff_folded_compatibility_baseline = "diff-folded CLI with --output=<path> before.folded after.folded and non-empty folded-stack output";

/// zflame input format subcommands supported by zigars.
pub const ZflameFormat = enum {
    perf,
    dtrace,
    sample,
    vtune,
    xctrace,
    recursive,

    /// Returns the zflame subcommand name.
    pub fn name(self: ZflameFormat) []const u8 {
        return @tagName(self);
    }
};

/// Stable ordered list used by schemas and human-facing help.
pub const zflame_format_names = [_][]const u8{
    "perf",
    "dtrace",
    "sample",
    "vtune",
    "xctrace",
    "recursive",
};

/// Parses a zflame format name exactly.
pub fn parseZflameFormat(raw: []const u8) ?ZflameFormat {
    inline for (std.meta.tags(ZflameFormat)) |tag| {
        if (std.mem.eql(u8, raw, @tagName(tag))) return tag;
    }
    return null;
}

/// Returns a concise comma-separated list for validation errors.
pub fn supportedZflameFormatsText() []const u8 {
    return "perf, dtrace, sample, vtune, xctrace, recursive";
}

/// Render options that map to zflame flag prefixes.
pub const ZflameOption = enum {
    title,
    subtitle,
    colors,
    width,
    min_width,

    /// Returns the manifest input field name for this option.
    pub fn fieldName(self: ZflameOption) []const u8 {
        return switch (self) {
            .title => "title",
            .subtitle => "subtitle",
            .colors => "colors",
            .width => "width",
            .min_width => "min_width",
        };
    }

    /// Returns the CLI flag prefix for argv construction.
    pub fn flagPrefix(self: ZflameOption) []const u8 {
        return switch (self) {
            .title => "--title=",
            .subtitle => "--subtitle=",
            .colors => "--colors=",
            .width => "--width=",
            .min_width => "--min-width=",
        };
    }
};

/// ZLint output formats understood by zigars.
pub const ZlintFormat = enum {
    json,
    sarif,

    /// Returns the CLI format token.
    pub fn name(self: ZlintFormat) []const u8 {
        return @tagName(self);
    }
};

/// zwanzig lint output formats understood by zigars.
pub const ZwanzigLintFormat = enum {
    json,
    sarif,

    /// Returns the CLI format token.
    pub fn name(self: ZwanzigLintFormat) []const u8 {
        return @tagName(self);
    }
};

/// zwanzig graph modes and their upstream flags.
pub const ZwanzigGraphMode = enum {
    cfg,
    exploded_graph,
    annotated_cfg,
    path_trace,

    /// Returns the manifest/API mode token.
    pub fn name(self: ZwanzigGraphMode) []const u8 {
        return switch (self) {
            .cfg => "cfg",
            .exploded_graph => "exploded_graph",
            .annotated_cfg => "annotated_cfg",
            .path_trace => "path_trace",
        };
    }

    /// Returns the zwanzig CLI flag for this graph mode.
    pub fn flag(self: ZwanzigGraphMode) []const u8 {
        return switch (self) {
            .cfg => "--dump-cfg",
            .exploded_graph => "--dump-exploded-graph",
            .annotated_cfg => "--dump-annotated-cfg",
            .path_trace => "--dump-path-trace",
        };
    }
};

/// Stable ordered list used by schemas and validation errors.
pub const zwanzig_graph_mode_names = [_][]const u8{
    "cfg",
    "exploded_graph",
    "annotated_cfg",
    "path_trace",
};

/// Parses a zwanzig graph mode exactly.
pub fn parseZwanzigGraphMode(raw: []const u8) ?ZwanzigGraphMode {
    inline for (std.meta.tags(ZwanzigGraphMode)) |tag| {
        if (std.mem.eql(u8, raw, tag.name())) return tag;
    }
    return null;
}

/// Returns a concise comma-separated list for validation errors.
pub fn supportedZwanzigGraphModesText() []const u8 {
    return "cfg, exploded_graph, annotated_cfg, path_trace";
}

/// Capability table for optional backend-backed tools.
pub const capabilities = [_]CapabilityContract{
    .{
        .tool = "zig_zlint",
        .backend = .zlint,
        .argv_shape = "zlint --format json [--config <path>] [--rules <rules>] <workspace-path> [args...]",
        .input_behavior = .reads_workspace_input,
        .output_behavior = .none,
    },
    .{
        .tool = "zig_zlint_sarif",
        .backend = .zlint,
        .argv_shape = "zlint --format json [--config <path>] [--rules <rules>] <workspace-path> [args...]; zigars converts normalized findings to SARIF",
        .input_behavior = .reads_workspace_input,
        .output_behavior = .none,
    },
    .{
        .tool = "zig_zlint_rules",
        .backend = .zlint,
        .argv_shape = "zlint --help; when supported, zlint --rules --format json",
        .input_behavior = .none,
        .output_behavior = .none,
    },
    .{
        .tool = "zig_zlint_fix",
        .backend = .zlint,
        .argv_shape = "zlint --format json (--fix|--fix-dangerously) [--config <path>] [--rules <rules>] <workspace-path> [args...]",
        .input_behavior = .reads_workspace_input,
        .output_behavior = .writes_workspace_source,
    },
    .{
        .tool = "zig_lint",
        .backend = .zwanzig,
        .argv_shape = "zwanzig --format json [--config <path>] [--do <rules>] [--skip <rules>] <workspace-path> [args...]",
        .input_behavior = .reads_workspace_input,
        .output_behavior = .none,
    },
    .{
        .tool = "zig_lint_sarif",
        .backend = .zwanzig,
        .argv_shape = "zwanzig --format sarif [--config <path>] [--do <rules>] [--skip <rules>] <workspace-path> [args...]",
        .input_behavior = .reads_workspace_input,
        .output_behavior = .none,
    },
    .{
        .tool = "zig_lint_rules",
        .backend = .zwanzig,
        .argv_shape = "zwanzig --help",
        .input_behavior = .none,
        .output_behavior = .none,
    },
    .{
        .tool = "zig_analysis_graphs",
        .backend = .zwanzig,
        .argv_shape = "zwanzig <graph-mode-flag> <workspace-output-dir> <workspace-source-path> [args...]",
        .input_behavior = .reads_workspace_input,
        .output_behavior = .writes_workspace_directory,
    },
    .{
        .tool = "zig_flamegraph",
        .backend = .zflame,
        .argv_shape = "zflame <format> [--title=<text>] [--subtitle=<text>] [--colors=<palette>] [--width=<px>] [--min-width=<px>] [--hash] <workspace-input>",
        .input_behavior = .reads_workspace_input,
        .output_behavior = .writes_workspace_svg,
    },
    .{
        .tool = "zig_flamegraph_diff",
        .backend = .diff_folded,
        .argv_shape = "diff-folded --output=<workspace-folded-diff> <before.folded> <after.folded>; then zflame recursive <workspace-folded-diff> with the zflame options from zig_flamegraph_diff",
        .input_behavior = .reads_workspace_input,
        .output_behavior = .writes_workspace_folded_diff,
    },
};

/// Returns the capability contract for `tool_name`, or null when not registered.
///
/// Callers should treat a null return as "no optional backend required" rather
/// than a hard error, so the server degrades gracefully when a new tool name is
/// dispatched before a matching contract entry is added.
pub fn capabilityFor(tool_name: []const u8) ?CapabilityContract {
    for (capabilities) |capability| {
        if (std.mem.eql(u8, capability.tool, tool_name)) return capability;
    }
    return null;
}

/// Returns the probe argv for a backend id.
pub fn probeArgv(id: BackendId) []const []const u8 {
    return switch (id) {
        .zig => zig_probe_argv[0..],
        .zls => zls_probe_argv[0..],
        .zlint => zlint_probe_argv[0..],
        .zwanzig => zwanzig_probe_argv[0..],
        .zflame => zflame_probe_argv[0..],
        .diff_folded => diff_folded_probe_argv[0..],
    };
}

/// Returns the configured executable path for `id` from a duck-typed config struct.
///
/// The caller's config type must expose fields named `zig_path`, `zls_path`,
/// `zlint_path`, `zwanzig_path`, `zflame_path`, and `diff_folded_path`.
/// Checked at comptime by the compiler via `anytype` field access.
pub fn configuredPath(id: BackendId, config: anytype) []const u8 {
    return switch (id) {
        .zig => config.zig_path,
        .zls => config.zls_path,
        .zlint => config.zlint_path,
        .zwanzig => config.zwanzig_path,
        .zflame => config.zflame_path,
        .diff_folded => config.diff_folded_path,
    };
}
