# zigars Skills

`@zigars/skills` ships client-consumable agent skills that teach MCP clients how
to use zigars effectively. The package has no install side effects: it does not
start the MCP server, configure a client, or copy files into a user profile. It
distributes workflow guidance that clients reference as skill directories.

```sh
npx -y @zigars/skills@0.2.0 list          # list shipped skills
npx -y @zigars/skills@0.2.0 path <skill>  # print one skill directory
npx -y @zigars/skills@0.2.0 root          # print the package root
```

Each skill carries portable metadata so the same directory works with Codex
(OpenAI), Claude Code (plugin), and Gemini CLI (extension). See
[docs/agent-clients.md](agent-clients.md) for per-client wiring.

## Shipped skills

The package ships 19 domain-specific skills. Each is advisory workflow guidance;
release decisions still need parser-backed, command-backed, ZLS, optional
backend, or CI evidence as described in [docs/evidence-tiers.md](evidence-tiers.md).

### Build and compile triage

| Skill | Use when |
| --- | --- |
| `zigars-compile-error-triage` | A `zig build`/`zig test`/zigars command fails with compile errors and diagnostics need routing to source. |
| `zigars-comptime-diagnose` | The compiler reports "unable to evaluate comptime expression", runtime-tainted operands, or backwards-branch limits. |
| `zigars-incremental-validation` | Choosing what to validate after edits and ordering risk-ranked checks (format → ast-check → focused tests → broad build/test). |

### Runtime and memory forensics

| Skill | Use when |
| --- | --- |
| `zigars-runtime-crash-forensics` | A program compiles but crashes, panics, emits sanitizer output, or needs an LLDB backtrace and a stable repro plan. |
| `zigars-memory-fuzz-forensics` | Investigating allocator leaks, GPA output, Valgrind/heaptrack findings, fuzz crashes, or corpus health. |

### Performance and artifacts

| Skill | Use when |
| --- | --- |
| `zigars-performance-regression-investigator` | Investigating benchmark slowdowns, coverage budget drops, profiler captures, or flamegraph comparisons. |
| `zigars-cross-target-artifact-auditor` | Inspecting binary size changes, symbols, DWARF/debug info, objdump summaries, or native-vs-cross-target differences. |

### Refactoring and interop

| Skill | Use when |
| --- | --- |
| `zigars-safe-refactor` | Planning, reviewing, or applying nontrivial Zig source changes, declaration moves, import updates, or public API edits. |
| `zigars-ffi-abi-guardian` | Authoring or reviewing C interop, extern/packed structs, ABI/memory layout, alignment, or translate-c output. |

### Dependencies and toolchain

| Skill | Use when |
| --- | --- |
| `zigars-dependency-steward` | Adding, removing, upgrading, or auditing dependencies for provenance, license, SBOM, OSV/ZAT, lock state, or cache health. |
| `zigars-zon-hash-sync` | `build.zig.zon` emits a hash mismatch or you are stuck in the "bogus hash, build, copy hash, rerun" loop. |
| `zigars-toolchain-pin-and-doctor` | Pinning Zig/ZLS versions, repairing `.zigars/profile.json`, or conforming optional backends. |
| `zigars-zig-version-migrator` | Bumping a project across toolchain versions for non-`std.Io` changes (build.zig, re-paths, langref drift). |
| `zigars-io-016-migration` | Migrating 0.15 → 0.16 `std.Io`/`std.net`/`std.time`/`std.fs`/`std.posix` call sites. |

### CI, docs, and release

| Skill | Use when |
| --- | --- |
| `zigars-ci-forensics` | Triaging CI failures, GitHub Actions logs, annotations, JUnit/SARIF, matrix or platform-only failures, or local repro plans. |
| `zigars-docs-example-steward` | Writing or reviewing docs, README commands, fenced Zig snippets, examples, or docs/release-claim drift. |
| `zigars-release-claim-auditor` | Preparing or reviewing release readiness, semver/support/backend claims, changelog entries, or publish/tag decisions. |
| `zigars-evidence-contract` | Auditing final claims ("done", "safe", "validated", "release-ready") against the strongest available zigars evidence. |

### Session continuity

| Skill | Use when |
| --- | --- |
| `zigars-handoff-resume` | Wrapping a session, switching clients/agents mid-task, or resuming a long-running refactor or release. |

## Keeping skills in sync

Skills reference zigars tool ids. When tool ids change, update the affected
skill directories so the guidance keeps pointing at live tools. The skill
drift check in `zig build artifact-hygiene` (part of `zig build release-check`)
fails the build when a skill references a backtick-quoted `zig_*`/`zigars_*`
tool id that is not registered in the compiled tool manifest.
