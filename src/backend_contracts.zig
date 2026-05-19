const std = @import("std");

pub const BackendId = enum {
    zig,
    zls,
    zwanzig,
    zflame,
    diff_folded,

    pub fn name(self: BackendId) []const u8 {
        return switch (self) {
            .zig => "zig",
            .zls => "zls",
            .zwanzig => "zwanzig",
            .zflame => "zflame",
            .diff_folded => "diff-folded",
        };
    }

    pub fn defaultPath(self: BackendId) []const u8 {
        return self.name();
    }

    pub fn pathFlag(self: BackendId) []const u8 {
        return switch (self) {
            .zig => "--zig-path",
            .zls => "--zls-path",
            .zwanzig => "--zwanzig-path",
            .zflame => "--zflame-path",
            .diff_folded => "--diff-folded-path",
        };
    }
};

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

pub const ArtifactBehavior = enum {
    none,
    reads_workspace_input,
    writes_workspace_directory,
    writes_workspace_svg,
    writes_workspace_folded_diff,
};

pub const CapabilityContract = struct {
    tool: []const u8,
    backend: BackendId,
    argv_shape: []const u8,
    input_behavior: ArtifactBehavior,
    output_behavior: ArtifactBehavior,
};

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

pub const zig_probe_argv = [_][]const u8{ "zig", "version" };
pub const zls_probe_argv = [_][]const u8{ "zls", "--version" };
pub const zwanzig_probe_argv = [_][]const u8{ "zwanzig", "--help" };
pub const zflame_probe_argv = [_][]const u8{ "zflame", "--help" };
pub const diff_folded_probe_argv = [_][]const u8{ "diff-folded", "--help" };

pub const zwanzig_verify = [_][]const u8{
    "zwanzig --help",
    "zwanzig --format json src",
    "zwanzig --dump-cfg .zigar-cache/zwanzig-graphs src/main.zig",
};
pub const zflame_verify = [_][]const u8{
    "zflame --help",
    "zflame recursive folded.txt > flame.svg",
};
pub const diff_folded_verify = [_][]const u8{
    "diff-folded --output=delta.folded before.folded after.folded",
    "zig_flamegraph_diff",
};

pub const ZflameFormat = enum {
    perf,
    dtrace,
    sample,
    vtune,
    xctrace,
    recursive,

    pub fn name(self: ZflameFormat) []const u8 {
        return @tagName(self);
    }
};

pub const zflame_format_names = [_][]const u8{
    "perf",
    "dtrace",
    "sample",
    "vtune",
    "xctrace",
    "recursive",
};

pub fn parseZflameFormat(raw: []const u8) ?ZflameFormat {
    inline for (std.meta.tags(ZflameFormat)) |tag| {
        if (std.mem.eql(u8, raw, @tagName(tag))) return tag;
    }
    return null;
}

pub fn supportedZflameFormatsText() []const u8 {
    return "perf, dtrace, sample, vtune, xctrace, recursive";
}

pub const ZflameOption = enum {
    title,
    subtitle,
    colors,
    width,
    min_width,

    pub fn fieldName(self: ZflameOption) []const u8 {
        return switch (self) {
            .title => "title",
            .subtitle => "subtitle",
            .colors => "colors",
            .width => "width",
            .min_width => "min_width",
        };
    }

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

pub const ZwanzigLintFormat = enum {
    json,
    sarif,

    pub fn name(self: ZwanzigLintFormat) []const u8 {
        return @tagName(self);
    }
};

pub const ZwanzigGraphMode = enum {
    cfg,
    exploded_graph,
    annotated_cfg,
    path_trace,

    pub fn name(self: ZwanzigGraphMode) []const u8 {
        return switch (self) {
            .cfg => "cfg",
            .exploded_graph => "exploded_graph",
            .annotated_cfg => "annotated_cfg",
            .path_trace => "path_trace",
        };
    }

    pub fn flag(self: ZwanzigGraphMode) []const u8 {
        return switch (self) {
            .cfg => "--dump-cfg",
            .exploded_graph => "--dump-exploded-graph",
            .annotated_cfg => "--dump-annotated-cfg",
            .path_trace => "--dump-path-trace",
        };
    }
};

pub const zwanzig_graph_mode_names = [_][]const u8{
    "cfg",
    "exploded_graph",
    "annotated_cfg",
    "path_trace",
};

pub fn parseZwanzigGraphMode(raw: []const u8) ?ZwanzigGraphMode {
    inline for (std.meta.tags(ZwanzigGraphMode)) |tag| {
        if (std.mem.eql(u8, raw, tag.name())) return tag;
    }
    return null;
}

pub fn supportedZwanzigGraphModesText() []const u8 {
    return "cfg, exploded_graph, annotated_cfg, path_trace";
}

pub const capabilities = [_]CapabilityContract{
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
        .argv_shape = "diff-folded --output=<workspace-folded-diff> <before.folded> <after.folded>; then zflame recursive <workspace-folded-diff>",
        .input_behavior = .reads_workspace_input,
        .output_behavior = .writes_workspace_folded_diff,
    },
};

pub fn capabilityFor(tool_name: []const u8) ?CapabilityContract {
    for (capabilities) |capability| {
        if (std.mem.eql(u8, capability.tool, tool_name)) return capability;
    }
    return null;
}

pub fn probeArgv(id: BackendId) []const []const u8 {
    return switch (id) {
        .zig => zig_probe_argv[0..],
        .zls => zls_probe_argv[0..],
        .zwanzig => zwanzig_probe_argv[0..],
        .zflame => zflame_probe_argv[0..],
        .diff_folded => diff_folded_probe_argv[0..],
    };
}

pub fn configuredPath(id: BackendId, config: anytype) []const u8 {
    return switch (id) {
        .zig => config.zig_path,
        .zls => config.zls_path,
        .zwanzig => config.zwanzig_path,
        .zflame => config.zflame_path,
        .diff_folded => config.diff_folded_path,
    };
}

test "optional backend identities expose stable path flags and probes" {
    try std.testing.expectEqualStrings("zwanzig", BackendId.zwanzig.name());
    try std.testing.expectEqualStrings("--diff-folded-path", BackendId.diff_folded.pathFlag());
    try std.testing.expectEqualStrings("--help", probeArgv(.zflame)[1]);
}

test "zflame contract requires explicit supported formats" {
    for (zflame_format_names) |name| try std.testing.expect(parseZflameFormat(name) != null);
    try std.testing.expect(parseZflameFormat("guess") == null);
}

test "zwanzig graph modes map to upstream dump flags" {
    try std.testing.expectEqualStrings("--dump-cfg", ZwanzigGraphMode.cfg.flag());
    try std.testing.expectEqualStrings("--dump-exploded-graph", ZwanzigGraphMode.exploded_graph.flag());
    try std.testing.expectEqualStrings("--dump-annotated-cfg", ZwanzigGraphMode.annotated_cfg.flag());
    try std.testing.expectEqualStrings("--dump-path-trace", ZwanzigGraphMode.path_trace.flag());
    try std.testing.expect(parseZwanzigGraphMode("--dot") == null);
}

test "capability contracts cover optional backend handlers" {
    const expected = [_][]const u8{ "zig_lint", "zig_lint_sarif", "zig_lint_rules", "zig_analysis_graphs", "zig_flamegraph", "zig_flamegraph_diff" };
    for (expected) |tool_name| {
        const contract = capabilityFor(tool_name) orelse return error.MissingContract;
        try std.testing.expect(contract.argv_shape.len > 0);
    }
}
