# Evidence Tiers

zigars labels public results by the kind of evidence behind them. The labels
help agents decide when a result is enough for orientation and when a stronger
check, such as `zig build test` or a release gate, is still needed.

For the broader tool catalog, see [tools.md](tools.md). For the release-facing
trust boundary, see [trust.md](trust.md).

## Labels

- Command-backed: zigars invoked an explicit argv vector, usually a `zig`
  command, without a shell and returned captured command metadata. This proves
  what the command reported for that workspace, toolchain, arguments, timeout,
  and process environment. It does not prove behavior outside that command's
  scope, and commands can still run project code or build scripts.
- LSP/ZLS-backed: the configured ZLS session provided the result for that call.
  This proves the result came from ZLS with the observed document/session state.
  It does not prove compiler semantic completeness, and unsupported or missing
  ZLS capabilities are reported as structured degraded states.
- Parser-backed: zigars parsed Zig source with `std.zig.Ast`. This proves the
  result is based on Zig syntax accepted by that parser path. It is not type
  checking, comptime execution, build graph evaluation, or whole-program
  semantic analysis.
- Source-scan-backed: zigars scanned workspace or installed-source files and
  reports paths, provenance, skipped files, ranking, and limits. This proves
  the result came from the scanned text. It is not semantic analysis and is not
  exhaustive when files are skipped or output is bounded.
- Heuristic/advisory: the result is meant for orientation, triage, or
  prioritization. It can be useful for choosing a next action, but it is not
  release evidence by itself.
- External-backend-backed: an optional local backend such as ZLint, zwanzig,
  zflame, diff-folded, Samply, Tracy, LLDB, heaptrack, Valgrind, AFL++, LLVM
  binary tools, QEMU, flash tools, or a platform profiler owns the backend
  semantics. zigars reports argv, probes, backend identity when available, and
  artifact metadata. It does not bundle those tools or prove their behavior
  beyond the observed invocation.
- Curated fallback: zigars used bundled partial data because installed docs or
  source data were unavailable. This keeps common lookup paths useful, but it
  is not a complete or current Zig documentation browser.
- Real conformance artifact: a clean-tree evidence package observed a real
  optional backend for an exact source commit, host, toolchain, and backend
  version. This supports a scoped public compatibility claim. It does not imply
  all backend versions, hosts, or future releases behave the same way.

## How To Use The Labels

Prefer command-backed, parser-backed, ZLS-backed, external-backend-backed, or
real conformance evidence for release decisions. Treat heuristic/advisory and
source-scan-backed results as routing aids unless a stronger cross-check is
named and run.

When labels disagree, keep the evidence boundary visible. For example, a parser
result can identify declarations, while `zig build test` remains the stronger
source of truth for compilation and test behavior.
