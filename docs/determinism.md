# Determinism Contract

zigars is deterministic in the product sense that server tools do not call an
LLM, do not synthesize code through a model, and expose bounded tool contracts
for Zig development work. It is not a promise that every byte of every result is
identical across machines, timestamps, backend versions, or workspace states.

## Contract

- No LLM calls run inside zigars server tools.
- Tool outputs depend on the tool arguments, workspace state, configured Zig
  toolchain, optional backend versions, process environment, host platform, and
  documented external command behavior.
- Command-backed tools execute argv vectors directly, without a shell, and
  report command metadata such as argv, cwd, exit status, timeout, truncation,
  and captured output where the tool exposes it.
- Source-mutating tools are preview-first. They do not write source files unless
  the call includes `apply=true`; preview calls return the planned change,
  diff, preimage, or limitation fields supported by that tool.

## Stable Fields

The stable public contract is the tool surface: tool names, schemas, required
fields, defaults, enums, evidence labels, risk metadata, apply gates, structured
error categories, and documented result fields. These are compatibility
sensitive and are generated or checked through the manifest workflow described
in [tools.md](tools.md).

Within one unchanged workspace and toolchain, normalized parser-backed fields,
planned argv values, evidence labels, workspace-relative paths, and explicit
limitations should remain stable unless the underlying source or configuration
changes.

## Runtime-Specific Fields

Some fields are intentionally runtime-specific:

- timings, durations, counters, and timestamps;
- external backend output, stderr/stdout text, and diagnostic ordering owned by
  Zig, ZLS, optional linters, debuggers, profilers, or host tools;
- absolute paths, cache paths, artifact paths, and host-specific executable
  paths;
- clean-tree state, backend availability, backend versions, and environment
  probes;
- hashes, which are stable for the exact bytes they identify but change when
  those bytes change.

Use these fields as observed evidence, not as byte-for-byte replay guarantees.

## Non-Contracts

zigars is not an OS sandbox. `zig build`, `zig test`, build scripts, project
executables, profilers, debuggers, and optional backends run with the local
user's privileges inside the configured workspace boundary. See
[trust.md](trust.md) for the safety boundary.

Parser-backed and ZLS-backed tools do not claim semantic completeness for every
refactor or analysis result. When correctness matters, use the named
cross-checks, compiler-backed commands, CI, or release gates.
