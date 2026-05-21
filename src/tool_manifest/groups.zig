const types = @import("types.zig");

const GroupSpec = types.GroupSpec;

pub const group_specs = [_]GroupSpec{
    .{ .group = .discovery, .keywords = &.{ "capabilities", "tool index", "schema", "doctor", "health", "workspace", "backend setup", "backend catalog", "optional backends", "context pack", "agent guide", "next action", "toolchain", "version manager", "mise", "asdf", "zvm", "zigup", "fmt", "formatter", "formatting", "zig fmt" } },
    .{ .group = .agent_workflows, .keywords = &.{ "agent", "agent client", "mcp client", "codex", "claude", "gemini", "hermes", "context pack", "next action", "validate patch", "failure fusion", "impact analysis", "project profile", "patch guard", "done check", "readiness" } },
    .{ .group = .core_zig, .keywords = &.{ "zig", "build", "test", "check", "ast-check", "compiler diagnostics", "compile error index", "translate-c" } },
    .{ .group = .formatting_and_edits, .keywords = &.{ "fmt", "formatter", "formatting", "zig fmt", "patch preview", "unified diff", "rename", "code action", "apply=true" } },
    .{ .group = .zls, .keywords = &.{ "zls", "lsp", "diagnostics", "hover", "definition", "references", "completion", "symbols", "unsaved document" } },
    .{ .group = .docs, .keywords = &.{ "docs", "stdlib", "builtin", "langref", "language reference" } },
    .{ .group = .static_analysis, .keywords = &.{ "heuristic", "parser backed", "capability tier", "confidence", "imports", "declarations", "allocation", "error set", "public api", "api diff", "breaking change", "build graph", "build options", "test discovery", "test map", "test select", "changed files", "dependency inspector", "target matrix", "test failure triage", "symbol cache", "package cache doctor" } },
    .{ .group = .ci_artifacts, .keywords = &.{ "ci", "annotations", "junit", "matrix", "multiple zig versions", "test report" } },
    .{ .group = .zwanzig, .keywords = &.{ "zwanzig", "lint", "linter", "static analysis", "sarif", "rules", "dot graph" } },
    .{ .group = .profiling, .keywords = &.{ "profile", "profiling", "profile plan", "external capture", "perf", "dtrace", "sample", "xctrace", "vtune", "zflame", "flamegraph", "diff flamegraph" } },
    .{ .group = .artifact_registry, .keywords = &.{ "artifact", "registry", "provenance", "sha256", "evidence", "generated files", "profile", "coverage", "release artifact" } },
    .{ .group = .observability, .keywords = &.{ "metrics", "observability", "latency", "backend health", "zls timeline", "tool errors", "runtime counters" } },
    .{ .group = .trust_safety, .keywords = &.{ "trust", "safety", "risk", "clean tree", "command provenance", "apply gate", "path policy", "backend identity" } },
    .{ .group = .result_contracts, .keywords = &.{ "result shape", "compact", "standard", "deep", "output budget", "omitted sections", "token budget" } },
    .{ .group = .release_drift, .keywords = &.{ "docs drift", "release claims", "tool index", "generated docs", "public claims", "release-check" } },
    .{ .group = .environment_profiles, .keywords = &.{ "profile v2", "project profile", "bootstrap", "environment pack", "toolchain pin", "zvm", "zls compatibility", "dev environment", "backend conformance", "setup elicitation" } },
};
