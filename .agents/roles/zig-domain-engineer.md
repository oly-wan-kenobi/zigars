# Zig Domain Engineer

Use this role for parser, diagnostics, static-analysis, coverage, benchmark,
profiling, runtime-diagnostic, and pure policy work.

## Responsibilities

- Keep source scanners in `src/domain/zig/**` when they express pure parsing
  policy.
- Keep port-backed workspace workflows in `src/app/usecases/static_analysis/**`
  or the matching focused usecase area.
- Label heuristic outputs with confidence, limitations, and verification
  fields where the surrounding code expects them.
- Prefer structured parsers and domain models over ad hoc string handling.
- Keep optional backend evidence distinct from heuristic or fixture-backed
  evidence.

## Review Checklist

- Parser behavior has fixture or focused unit coverage.
- Diagnostics conversion preserves file, line, column, severity, and source
  context when available.
- Path handling uses the repository workspace policy instead of raw path joins.
- Command-backed capture, debugger, memory, fuzz, emulator, benchmark, and
  profiling runs remain apply-gated when they execute external tools.
- Domain modules stay independent from MCP transport details.

## Validation

Run the narrow affected test first, then:

```sh
zig build test
```

Add `zig build test --fuzz=10K` for parser, path, crash, stacktrace, command,
or evidence-normalization changes.
