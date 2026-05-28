# Why zigars

Shell can run `zig build`. zigars exists for the work around that command: the
parts where an MCP client needs structured Zig evidence, bounded tool behavior,
and explicit next verification steps instead of inferring intent from shell
text alone.

## What zigars Adds

- Structured diagnostics: command-backed tools return machine-readable command
  metadata, bounded output, truncation state, and diagnostics that an agent can
  route back to files and follow-up checks.
- Evidence labels: results distinguish command-backed, parser-backed,
  LSP/ZLS-backed, source-scan-backed, heuristic/advisory, optional-backend, and
  release conformance evidence. See [evidence-tiers.md](evidence-tiers.md).
- Parser-backed facts: source inspection tools use `std.zig.Ast` for syntax
  facts such as imports, declarations, test names, and module surfaces without
  pretending to run compiler semantic analysis.
- ZLS-backed code intelligence: when ZLS is configured, zigars can expose
  language-server diagnostics, symbols, references, hovers, definitions,
  completions, and supported edit actions with structured degraded states when
  a capability is unavailable.
- Preview diffs and apply gates: formatting, patch, and refactor helpers return
  planned edits first and write source only when the call includes
  `apply=true`.
- Confidence and limitations: advisory workflows report confidence, skipped
  validation, limitations, and recommended cross-checks instead of turning weak
  evidence into a stronger claim.

## Where Shell Remains The Source Of Truth

The Zig compiler, Zig build system, project tests, CI, and selected external
backends still own the behavior they execute. zigars can run or plan many of
those commands and normalize the evidence, but it does not replace the raw
compiler/runtime result.

Use shell directly when you need an unwrapped command, an interactive workflow,
or behavior outside the registered zigars tool surface. Use zigars when the MCP
client benefits from structured outputs, workspace path policy, preview-first
edits, evidence labels, and a clear verification path.

## Boundary

zigars is not an AI code generator and does not run LLM calls inside server
tools. It does not claim semantic completeness for refactors. Refactor and edit
tools should be reviewed with their reported limitations and validated with the
compiler, tests, ZLS, or CI as appropriate.
