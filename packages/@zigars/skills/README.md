# @zigars/skills

`@zigars/skills` ships client-consumable skills for zigars-aware development
workflows. It is separate from `@zigars/mcp`: the MCP package starts the local
zigars server, while this package distributes agent instructions that tell clients
how to use zigars effectively.

The package has no install side effects. It does not configure an MCP client,
copy files into a user profile, or claim that skills are part of the base MCP
protocol.

## Usage

List shipped skills:

```sh
npx -y @zigars/skills@0.2.0 list
```

Print the package skill directory:

```sh
npx -y @zigars/skills@0.2.0 path
```

Print the package root for clients that load plugin or extension directories:

```sh
npx -y @zigars/skills@0.2.0 root
```

Print one skill directory:

```sh
npx -y @zigars/skills@0.2.0 path zigars-evidence-contract
```

Clients that support filesystem skills can copy or reference the printed skill
directory according to that client's documentation.

## Client Support

The same `skills/<skill-name>/SKILL.md` directories are packaged for multiple
agent clients:

- Codex/OpenAI-compatible clients can consume the skill folders directly and read
  the optional `agents/openai.yaml` metadata.
- Claude Code can load the package root as a plugin. The package includes
  `.claude-plugin/plugin.json`, and Claude discovers the `skills/` directory from
  the plugin root.
- Gemini CLI can load the package root as an extension. The package includes
  `gemini-extension.json`, and Gemini discovers the `skills/` directory from the
  extension root.

For local testing after installing or checking out this package:

```sh
claude --plugin-dir "$(npx -y @zigars/skills@0.2.0 root)"
gemini extensions link "$(npx -y @zigars/skills@0.2.0 root)"
```

Those commands are examples for clients that support local plugin or extension
directories. They are not run by this package automatically.

## Shipped Skills

- `zigars-compile-error-triage`: route a failing Zig build to its primary error
  via structured diagnostics and confirm the fix with `zigars_validate_patch`.
- `zigars-comptime-diagnose`: localize the runtime-tainted operand behind a Zig
  comptime error and propose a compiler-verifiable fix.
- `zigars-zon-hash-sync`: repair a `build.zig.zon` hash mismatch in one
  preview-first edit, then rerun the failing build.
- `zigars-io-016-migration`: audit and migrate `std.io`, `std.posix`, `std.fs`,
  `std.net.Address`, and `std.time` call sites to Zig 0.16's `std.Io` interface.
- `zigars-incremental-validation`: pick the cheapest sufficient validation
  depth for a change and report what is left unproven.
- `zigars-toolchain-pin-and-doctor`: pin Zig, ZLS, and optional backends for
  reproducible builds on this machine.
- `zigars-handoff-resume`: capture or replay session context so work can resume
  across agents, clients, or sessions without redoing discovery.
- `zigars-evidence-contract`: audit zigars evidence before making final claims
  about safety, validation, release readiness, or backend support.
- `zigars-safe-refactor`: plan and validate risky Zig source changes with impact,
  edit-policy, patch-session, and test-selection discipline.
- `zigars-dependency-steward`: add, update, and audit Zig dependencies for
  provenance, license, SBOM, scanner evidence, and lock state (hash repair
  belongs to `zigars-zon-hash-sync`).
- `zigars-zig-version-migrator`: handle the non-IO parts of a Zig version bump
  (`build.zig` API, package metadata, non-IO stdlib re-paths, version-scoped
  docs) and route specialized concerns to their dedicated skills.
- `zigars-ci-forensics`: interpret CI logs, annotations, JUnit, SARIF, and matrix
  failures without replacing raw artifact authority.
- `zigars-release-claim-auditor`: keep release notes, semver decisions, backend
  support, and package artifact claims tied to citable evidence.
- `zigars-runtime-crash-forensics`: preserve and analyze Zig panic, sanitizer,
  core dump, LLDB, target-only, and crash-reproduction evidence.
- `zigars-performance-regression-investigator`: compare benchmark, coverage,
  profiler, flamegraph, Samply, Tracy, and performance-budget evidence.
- `zigars-ffi-abi-guardian`: review C interop, ABI layout, memory layout,
  alignment, unsafe operations, and cross-target binary assumptions.
- `zigars-memory-fuzz-forensics`: investigate allocator leaks, Valgrind or
  heaptrack output, fuzz crashes, corpus health, and minimization evidence.
- `zigars-cross-target-artifact-auditor`: inspect binary size, symbols, DWARF,
  QEMU, target runtime, and native-vs-cross-target artifact evidence.
- `zigars-docs-example-steward`: keep README commands, snippets, autodoc, local
  std/langref claims, examples, and docs drift evidence-based.

## Maintainer Notes

Keep skills under `skills/<skill-name>/`. Each skill should contain a concise
`SKILL.md`, optional `agents/openai.yaml`, and optional one-level references.
Keep `.claude-plugin/plugin.json` and `gemini-extension.json` in sync with
`package.json` when package metadata changes. Do not duplicate zigars' MCP tools
in skills; route agents to the connected MCP server and keep deterministic
behavior inside the server.

Validate before publishing:

```sh
npm test
npm run pack:dry
```

Also run the skill validator from the client skill tooling you use when it is
available.
