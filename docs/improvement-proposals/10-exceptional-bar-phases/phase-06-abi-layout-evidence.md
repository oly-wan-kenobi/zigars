# Phase 6 - ABI And Layout Evidence Upgrade

Status: ready for implementation
Primary source sections:
[08 section 4.1](../08-exceptional-bar-action-plan.md#41-zig-distinctive-surface),
[09 section 7](../09-exceptional-bar-deep-research-findings.md#7-zig-specific-capability-research)

## Objective

Promote existing ABI and memory layout tools from advisory/probe-plan output to
optional compiler-backed target measurements, while keeping parser-backed
candidate discovery cheap and safe.

## Ordered Tasks

### P6-T1 Add Layout Probe Fixtures

Create a fixture set for compiler-backed layout behavior.

Required fixtures:

- extern and packed structs;
- unions and enums;
- sentinel pointers;
- explicit alignment;
- field padding;
- `@offsetOf` versus `@bitOffsetOf`;
- target expectations for `x86_64-linux`, `x86-linux`, `aarch64-linux`,
  `powerpc-linux`, and `wasm32-freestanding`;
- imported comptime side-effect fixture;
- `@embedFile` workspace-boundary fixture;
- `zig build --help` build-script execution sentinel.

Acceptance criteria:

- Fixtures do not depend on network access.
- Tests document which probes execute project comptime logic and which do not.
- Expected target measurements are versioned for Zig 0.16.0.

### P6-T2 Implement Standalone Compiler Probe Builder

Add a helper that generates standalone Zig probe programs and invokes direct
compiler commands such as `zig build-obj <probe>.zig -target ... -fno-emit-bin`.

Acceptance criteria:

- Standalone probes do not import project modules by default.
- Probes do not run `build.zig`.
- Probe files and cache paths stay inside allowed workspace/cache roots.
- Command argv, target, Zig version, cache dir, and output truncation are
  reported as evidence.
- Timeouts and command output limits are enforced.

Likely files:

- `src/app/usecases/static_analysis/developer_pain.zig`
- new focused helper under `src/app/usecases/static_analysis/` or
  `src/domain/zig/`
- command runner tests

### P6-T3 Upgrade `zig_memory_layout`

Keep parser-backed candidate discovery as the default, then add an optional
compiler-backed measurement mode.

Acceptance criteria:

- Default mode remains low-risk and does not execute project code.
- Compiler-backed mode reports size, alignment, offsets, bit offsets where
  applicable, target, toolchain, evidence basis, confidence, and limitations.
- If project modules are imported, the result explicitly marks
  `executes_project_code=true` and explains arbitrary comptime risk.
- Missing or incompatible Zig returns a structured error with resolution.

### P6-T4 Upgrade `zig_abi_layout_diff`

Add compiler-backed target comparison for ABI-relevant declarations.

Acceptance criteria:

- The tool can compare at least two target triples.
- It reports layout differences and unchanged layout evidence.
- It distinguishes parser-backed candidates from compiler-backed measurements.
- It returns a clear unsupported/needs-stronger-evidence response when it cannot
  safely measure a declaration.

### P6-T5 Add Target Metadata Support

Use `zig targets`, `zig env`, `zig version`, or `--show-builtin -target` where
appropriate to ground target metadata.

Acceptance criteria:

- Target facts are command-backed and do not execute project code.
- Results include Zig version and target triple.
- The metadata path is reusable by layout probes.

### P6-T6 Update Manifest, Risk Metadata, And Docs

If schemas, result fields, capability tiers, risk flags, or planning metadata
change, update the manifest and generated docs.

Acceptance criteria:

- Tool descriptions state evidence basis and project-code execution risk.
- Risk metadata distinguishes backend execution, project code execution, and
  build-script execution.
- [docs/tools.md](../../tools.md) and
  [docs/tool-index.generated.md](../../tool-index.generated.md) remain in sync.

## Out Of Scope

- Do not implement broad comptime value inspection.
- Do not execute target binaries.
- Do not run `zig build` silently to discover layout.
- Do not add new architecture-policy tools.

## Validation

```sh
zig fmt build.zig build.zig.zon src tools
zig build test
zig build tool-index
zig build docs-check json-check
```

Add targeted tests for path handling, command argv, fixture measurements,
project-comptime risk labeling, and generated contract drift.
