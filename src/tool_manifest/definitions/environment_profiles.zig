const types = @import("../types.zig");

const schema = types.schema;
const schemaWithHints = types.schemaWithHints;
const tool = types.tool;
const handler = types.handler;
const fieldHint = types.fieldHint;

const mode_hint = fieldHint("mode", .{ .description = "Result shape depth or setup workflow mode.", .default_string = "standard", .enum_values = &.{ "compact", "standard", "deep" } });
const backend_hint = fieldHint("backend", .{ .description = "Backend selector.", .default_string = "all", .enum_values = &.{ "all", "zig", "zls", "zwanzig", "zflame", "diff-folded", "diff_folded" } });
const dev_env_kind_hint = fieldHint("kind", .{ .description = "Generated development-environment artifact kind.", .default_string = "mise", .enum_values = &.{ "mise", "asdf", "nix", "devcontainer", "github-actions" } });

pub const zigar_setup_elicit = tool(.{
    .description = "Return client-mediated setup questions for unresolved toolchain, profile, and backend ambiguity without mutating the workspace.",
    .input_schema = schemaWithHints(&.{ .{ "topic", "string", false }, .{ "mode", "string", false } }, &.{mode_hint}),
    .read_only = true,
    .group = .environment_profiles,
    .handler = handler(.environment_profiles, "zigarSetupElicit"),
    .plan = .{ .pure_analysis = "Workspace/profile inspection only; returns questions, detected facts, unknowns, and next tool suggestions." },
});

pub const zigar_profile_elicit = tool(.{
    .description = "Return project-profile questions for missing or ambiguous source, test, target, CI, lint, and toolchain policy.",
    .input_schema = schemaWithHints(&.{ .{ "content", "string", false }, .{ "mode", "string", false } }, &.{mode_hint}),
    .read_only = true,
    .group = .environment_profiles,
    .handler = handler(.environment_profiles, "zigarProfileElicit"),
    .plan = .{ .pure_analysis = "Profile validation and workspace inspection only; does not write profile files." },
});

pub const zigar_backend_elicit = tool(.{
    .description = "Return backend setup questions for missing optional backend paths, claims, and verification choices.",
    .input_schema = schemaWithHints(&.{ .{ "backend", "string", false }, .{ "mode", "string", false } }, &.{ backend_hint, mode_hint }),
    .read_only = true,
    .group = .environment_profiles,
    .handler = handler(.environment_profiles, "zigarBackendElicit"),
    .plan = .{ .pure_analysis = "Backend catalog/profile inspection only; does not probe or install backends." },
});

pub const zigar_project_profile_v2 = tool(.{
    .description = "Generate or explicitly write a deterministic project profile v2 at .zigar/profile.json.",
    .input_schema = schema(&.{ .{ "apply", "boolean", false }, .{ "content", "string", false } }),
    .read_only = false,
    .group = .environment_profiles,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
    .handler = handler(.environment_profiles, "zigarProjectProfileV2"),
    .plan = .{ .apply_gated_mutation = "Preview-first workspace artifact mutation; writes .zigar/profile.json only when apply=true." },
});

pub const zigar_profile_validate = tool(.{
    .description = "Validate a project profile v2 from content or .zigar/profile.json and return evidence-labeled findings.",
    .input_schema = schema(&.{ .{ "content", "string", false }, .{ "path", "string", false } }),
    .read_only = true,
    .group = .environment_profiles,
    .handler = handler(.environment_profiles, "zigarProfileValidate"),
    .plan = .{ .pure_analysis = "Parses profile JSON and reports deterministic schema findings without writing files." },
});

pub const zigar_profile_read = tool(.{
    .description = "Read .zigar/profile.json as a bounded workspace file with validation and preimage identity.",
    .input_schema = schema(&.{.{ "path", "string", false }}),
    .read_only = true,
    .group = .environment_profiles,
    .handler = handler(.environment_profiles, "zigarProfileRead"),
    .plan = .{ .pure_analysis = "Reads one workspace-bound profile path and validates its public contract." },
});

pub const zigar_profile_bootstrap = tool(.{
    .description = "Inspect the workspace and propose a profile v2 with detected facts, inferences, unknowns, and confidence.",
    .input_schema = schemaWithHints(&.{.{ "mode", "string", false }}, &.{mode_hint}),
    .read_only = true,
    .group = .environment_profiles,
    .handler = handler(.environment_profiles, "zigarProfileBootstrap"),
    .plan = .{ .pure_analysis = "Workspace inspection only; generates a proposed profile without writing it." },
});

pub const zigar_profile_import = tool(.{
    .description = "Preview or apply importing a profile v2 into .zigar/profile.json with validation and preimage identity.",
    .input_schema = schema(&.{ .{ "content", "string", true }, .{ "apply", "boolean", false } }),
    .read_only = false,
    .group = .environment_profiles,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
    .handler = handler(.environment_profiles, "zigarProfileImport"),
    .plan = .{ .apply_gated_mutation = "Preview-first workspace artifact mutation; writes .zigar/profile.json only when apply=true." },
});

pub const zigar_profile_diff = tool(.{
    .description = "Compare the current profile with supplied content or the generated bootstrap profile.",
    .input_schema = schema(&.{ .{ "content", "string", false }, .{ "path", "string", false } }),
    .read_only = true,
    .group = .environment_profiles,
    .handler = handler(.environment_profiles, "zigarProfileDiff"),
    .plan = .{ .pure_analysis = "Reads the current profile and compares stable top-level fields without writing files." },
});

pub const zigar_env_pack = tool(.{
    .description = "Return a reproducible environment pack with Zig, ZLS, backend paths, versions, pins, checksums, and compatibility state.",
    .input_schema = schema(&.{ .{ "probe_backends", "boolean", false }, .{ "include_hashes", "boolean", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .environment_profiles,
    .risk = .{ .executes_backend = true },
    .handler = handler(.environment_profiles, "zigarEnvPack"),
    .plan = .{ .dynamic_command = "Optionally probes configured backends for versions and hashes; does not mutate tools or workspace files." },
});

pub const zigar_env_export = tool(.{
    .description = "Preview or apply exporting the reproducible environment pack as a registered workspace artifact.",
    .input_schema = schema(&.{ .{ "output", "string", false }, .{ "apply", "boolean", false }, .{ "probe_backends", "boolean", false }, .{ "include_hashes", "boolean", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = false,
    .group = .environment_profiles,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true, .executes_backend = true },
    .handler = handler(.environment_profiles, "zigarEnvExport"),
    .plan = .{ .apply_gated_mutation = "Preview-first artifact write under the configured workspace; also registers provenance when apply=true." },
});

pub const zigar_zvm_probe = tool(.{
    .description = "Probe ZVM availability, active Zig version, installed versions, and version-manager location without installing or switching.",
    .input_schema = schema(&.{ .{ "zvm_path", "string", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .environment_profiles,
    .risk = .{ .executes_backend = true },
    .handler = handler(.environment_profiles, "zigarZvmProbe"),
    .plan = .{ .dynamic_command = "Runs bounded ZVM read-only commands such as version/current/list when the executable is available." },
});

pub const zigar_zvm_install_plan = tool(.{
    .description = "Return exact ZVM commands to install the requested Zig version without executing them.",
    .input_schema = schema(&.{ .{ "version", "string", true }, .{ "zvm_path", "string", false } }),
    .read_only = true,
    .group = .environment_profiles,
    .handler = handler(.environment_profiles, "zigarZvmInstallPlan"),
    .plan = .{ .pure_analysis = "Command plan only; does not install Zig or mutate the developer environment." },
});

pub const zigar_zvm_switch_plan = tool(.{
    .description = "Return exact ZVM commands to select the requested Zig version without executing them.",
    .input_schema = schema(&.{ .{ "version", "string", true }, .{ "zvm_path", "string", false } }),
    .read_only = true,
    .group = .environment_profiles,
    .handler = handler(.environment_profiles, "zigarZvmSwitchPlan"),
    .plan = .{ .pure_analysis = "Command plan only; does not switch Zig or mutate the developer environment." },
});

pub const zig_zls_match_check = tool(.{
    .description = "Check configured Zig and ZLS versions against project hints and each other with explicit compatibility evidence.",
    .input_schema = schema(&.{ .{ "probe_backends", "boolean", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .environment_profiles,
    .risk = .{ .executes_backend = true },
    .handler = handler(.environment_profiles, "zigZlsMatchCheck"),
    .plan = .{ .dynamic_command = "Runs bounded Zig/ZLS version probes and compares the observed release prefixes." },
});

pub const zig_toolchain_pin = tool(.{
    .description = "Preview or apply a deterministic .zigar/toolchain.json pin file for Zig, ZLS, and optional backend versions.",
    .input_schema = schema(&.{ .{ "apply", "boolean", false }, .{ "output", "string", false }, .{ "zig_version", "string", false }, .{ "zls_version", "string", false }, .{ "zwanzig_version", "string", false }, .{ "zflame_version", "string", false }, .{ "diff_folded_version", "string", false } }),
    .read_only = false,
    .group = .environment_profiles,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true, .executes_backend = true },
    .handler = handler(.environment_profiles, "zigToolchainPin"),
    .plan = .{ .apply_gated_mutation = "Preview-first workspace artifact mutation; writes a pin file only when apply=true." },
});

pub const zig_toolchain_pin_check = tool(.{
    .description = "Compare configured Zig, ZLS, and backend state against a deterministic .zigar/toolchain.json pin file.",
    .input_schema = schema(&.{ .{ "input", "string", false }, .{ "probe_backends", "boolean", false }, .{ "timeout_ms", "integer", false } }),
    .read_only = true,
    .group = .environment_profiles,
    .risk = .{ .executes_backend = true },
    .handler = handler(.environment_profiles, "zigToolchainPinCheck"),
    .plan = .{ .dynamic_command = "Reads the workspace pin file and optionally probes configured backends; does not mutate tools or files." },
});

pub const zigar_backend_install_plan = tool(.{
    .description = "Return explicit setup commands and verification steps for optional backends without installing anything.",
    .input_schema = schemaWithHints(&.{ .{ "backend", "string", false }, .{ "manager", "string", false } }, &.{backend_hint}),
    .read_only = true,
    .group = .environment_profiles,
    .handler = handler(.environment_profiles, "zigarBackendInstallPlan"),
    .plan = .{ .pure_analysis = "Backend setup plan only; commands are suggestions and are never executed by this tool." },
});

pub const zigar_backend_verify = tool(.{
    .description = "Verify configured backend availability with bounded probes and structured unavailable or unsupported states.",
    .input_schema = schemaWithHints(&.{ .{ "backend", "string", false }, .{ "timeout_ms", "integer", false } }, &.{backend_hint}),
    .read_only = true,
    .group = .environment_profiles,
    .risk = .{ .executes_backend = true },
    .handler = handler(.environment_profiles, "zigarBackendVerify"),
    .plan = .{ .dynamic_command = "Runs bounded backend probe commands for selected configured executables." },
});

pub const zigar_dev_env_generate = tool(.{
    .description = "Preview or apply pinned mise, asdf, Nix, devcontainer, or GitHub Actions setup artifacts.",
    .input_schema = schemaWithHints(&.{ .{ "kind", "string", false }, .{ "output", "string", false }, .{ "apply", "boolean", false } }, &.{dev_env_kind_hint}),
    .read_only = false,
    .group = .environment_profiles,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
    .handler = handler(.environment_profiles, "zigarDevEnvGenerate"),
    .plan = .{ .apply_gated_mutation = "Preview-first workspace artifact mutation; writes generated setup files only when apply=true." },
});

pub const zigar_backend_conformance = tool(.{
    .description = "Return backend conformance plan and optional probe matrix for fake or real backend evidence paths.",
    .input_schema = schemaWithHints(&.{ .{ "backend", "string", false }, .{ "probe_backends", "boolean", false }, .{ "timeout_ms", "integer", false } }, &.{backend_hint}),
    .read_only = true,
    .group = .environment_profiles,
    .risk = .{ .executes_backend = true },
    .handler = handler(.environment_profiles, "zigarBackendConformance"),
    .plan = .{ .dynamic_command = "Produces conformance scenarios and optionally runs bounded backend probes; full release conformance remains a script-backed verification path." },
});

pub const zigar_backend_evidence_pack = tool(.{
    .description = "Preview or apply a compact backend evidence pack from the latest conformance report or deterministic unavailable evidence.",
    .input_schema = schema(&.{ .{ "input", "string", false }, .{ "output", "string", false }, .{ "apply", "boolean", false } }),
    .read_only = false,
    .group = .environment_profiles,
    .risk = .{ .writes_artifacts = true, .writes_require_apply = true, .preview_by_default = true },
    .handler = handler(.environment_profiles, "zigarBackendEvidencePack"),
    .plan = .{ .apply_gated_mutation = "Preview-first workspace artifact write; reads existing conformance evidence and writes a compact pack only when apply=true." },
});
