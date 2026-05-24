const types = @import("types.zig");

const GroupSpec = types.GroupSpec;

pub const group_specs = [_]GroupSpec{
    .{ .group = .discovery, .keywords = &.{ "capabilities", "tool index", "schema", "doctor", "health", "workspace", "backend setup", "backend catalog", "optional backends", "context pack", "agent guide", "next action", "toolchain", "version manager", "mise", "asdf", "zvm", "zigup", "fmt", "formatter", "formatting", "zig fmt" } },
    .{ .group = .agent_workflows, .keywords = &.{ "agent", "agent client", "mcp client", "codex", "claude", "gemini", "hermes", "context pack", "next action", "validate patch", "patch session", "transactional editing", "validation plan", "validation run", "build events", "test events", "validation history", "flake history", "failure history", "handoff", "project memory", "capability match", "tool sequence", "failure fusion", "impact analysis", "project profile", "patch guard", "done check", "readiness" } },
    .{ .group = .core_zig, .keywords = &.{ "zig", "build", "test", "check", "ast-check", "compiler diagnostics", "compile error index", "translate-c" } },
    .{ .group = .formatting_and_edits, .keywords = &.{ "fmt", "formatter", "formatting", "zig fmt", "patch preview", "patch session", "transactional edit", "rollback", "unified diff", "rename", "refactor", "move declaration", "extract declaration", "imports", "code action", "apply=true", "zlint fix" } },
    .{ .group = .zls, .keywords = &.{ "zls", "lsp", "diagnostics", "hover", "definition", "references", "completion", "symbols", "unsaved document" } },
    .{ .group = .docs, .keywords = &.{ "docs", "stdlib", "builtin", "langref", "language reference", "autodoc", "snippet", "readme examples" } },
    .{ .group = .static_analysis, .keywords = &.{ "heuristic", "parser backed", "capability tier", "confidence", "evidence source", "semantic index", "semantic query", "references", "callers", "code index", "scip", "imports", "declarations", "allocation", "error set", "public api", "api diff", "breaking change", "build graph", "build options", "test discovery", "test map", "test select", "changed files", "dependency inspector", "target matrix", "test failure triage", "symbol cache", "package cache doctor", "zlint", "zlint fix", "lint compare", "lint gate", "lint baseline", "suppressions", "trend" } },
    .{ .group = .ci_artifacts, .keywords = &.{ "ci", "annotations", "junit", "matrix", "multiple zig versions", "test report" } },
    .{ .group = .zwanzig, .keywords = &.{ "zwanzig", "lint", "linter", "static analysis", "sarif", "rules", "dot graph" } },
    .{ .group = .profiling, .keywords = &.{ "profile", "profiling", "profile plan", "external capture", "perf", "dtrace", "sample", "xctrace", "vtune", "zflame", "flamegraph", "diff flamegraph" } },
    .{ .group = .artifact_registry, .keywords = &.{ "artifact", "registry", "provenance", "sha256", "evidence", "generated files", "profile", "coverage", "release artifact" } },
    .{ .group = .observability, .keywords = &.{ "metrics", "observability", "latency", "backend health", "zls timeline", "tool errors", "runtime counters" } },
    .{ .group = .trust_safety, .keywords = &.{ "trust", "safety", "risk", "clean tree", "command provenance", "apply gate", "path policy", "generated files", "vendor", "regeneration route", "backend identity" } },
    .{ .group = .result_contracts, .keywords = &.{ "result shape", "compact", "standard", "deep", "output budget", "omitted sections", "token budget" } },
    .{ .group = .release_drift, .keywords = &.{ "docs drift", "release claims", "tool index", "generated docs", "public claims", "release-check" } },
    .{ .group = .environment_profiles, .keywords = &.{ "profile v2", "project profile", "bootstrap", "environment pack", "toolchain pin", "zvm", "zls compatibility", "dev environment", "backend conformance", "setup elicitation" } },
    .{ .group = .runtime_ux, .keywords = &.{ "job", "task", "run stream", "events", "cancellation", "resource query", "subscription", "completion", "roots", "workspace map", "prompt pack", "client guide" } },
    .{ .group = .release_intelligence, .keywords = &.{ "release", "semver", "release notes", "evidence pack", "release readiness", "changelog", "ci evidence", "docs evidence" } },
    .{ .group = .api_lifecycle, .keywords = &.{ "api lifecycle", "api baseline", "api check", "api docs diff", "breaking change", "public api review" } },
    .{ .group = .dependency_security, .keywords = &.{ "dependency update", "dependency fetch", "lock audit", "sbom", "cyclonedx", "security scan", "osv", "zat", "license", "dependency submission", "provenance" } },
    .{ .group = .performance_workflows, .keywords = &.{ "coverage", "coverage baseline", "coverage budget", "benchmark", "bench baseline", "performance budget", "profile regression", "samply", "tracy", "profile artifact", "performance evidence" } },
    .{ .group = .runtime_diagnostics, .keywords = &.{ "debug", "lldb", "core dump", "sanitizer", "panic trace", "crash repro", "heaptrack", "valgrind", "callgrind", "fuzz", "afl", "libfuzzer", "binary size", "objdump", "dwarf", "symbolize", "qemu", "cross target", "embedded", "microzig", "board", "flash" } },
    .{ .group = .public_rollout, .keywords = &.{ "adoption", "client config", "mcp config", "codex", "claude", "gemini", "smoke plan", "conformance report", "public claims", "evidence basis", "rollout" } },
};
