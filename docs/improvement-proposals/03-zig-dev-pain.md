# Improvement Proposals — 03: Zig Developer Pain Audit

**Author:** Claude Opus 4.7 (1M context)
**Date:** 2026-05-27
**Scope:** Community-driven research into recurring friction Zig developers
report in 2025–2026 on ziggit.dev, the ziglang/zig issue tracker, Andrew
Kelley and Loris Cro's blogs, the Zig 0.16 release cycle, and popular Zig
project migration logs.
**Goal:** Identify recurring manual workflows that an AI agent driving zigar
could compress into a single tool call, or net-new capabilities that no
existing zigar tool provides.

This is the complement to [01-internal-gaps.md](01-internal-gaps.md):
proposal 01 asks "what infra is wired but unexposed?"; this proposal asks
"what do Zig developers actually struggle with day-to-day, and what would
turn a multi-step manual loop into one tool call?".

Out of scope: every entry on the P0–P4 list in
[../../CLAUDE_ANALYSIS.md](../../CLAUDE_ANALYSIS.md) (release upload, npm
publish, skills decision, coverage gate, shim smoke, README routing, ADRs,
error catalog, perf thresholds, backend variants as build targets, GPG
signing, LLM-judge tests, MCPB pin doc) and every tool already in
[../tool-index.generated.md](../tool-index.generated.md). Each proposal
below was cross-checked against that index; none refine an existing tool.

## Method

For each candidate friction area I:

1. Found at least one primary source from the community (issue, forum
   thread, blog post, official release note) showing the friction exists and
   is not idiosyncratic.
2. Reduced the manual workflow to its bare steps.
3. Sketched a zigar tool that compresses or eliminates those steps,
   constrained to zigar's deterministic, no-AI-generation contract from
   [../../AGENTS.md](../../AGENTS.md).
4. Assigned a verdict — clear-win, needs-validation, or probably-not — and
   noted any backend integration zigar does not already have.

Backends already wired in zigar (per [../backends.md](../backends.md)):
`zig` itself, ZLS, ZLint, zwanzig, zflame, diff-folded, Samply, Tracy,
LLDB, heaptrack, Valgrind, AFL++, LLVM binary tools, QEMU, flash tools,
and `std.zig.Ast` parser-backed analysis. Anything beyond this counts as a
new integration and is flagged at the bottom.

---

## Top 10 Friction Areas

### 1. The `build.zig.zon` hash-mismatch dance

**Friction.** When a developer adds, bumps, or relocates a dependency,
the canonical workaround is: set the hash to a bogus value, run `zig
build`, copy the real hash out of the error message, paste it back into
`build.zig.zon`, rerun. The community has wanted this fixed since 2023
([ziglang/zig#16972](https://github.com/ziglang/zig/issues/16972),
[ziglang/zig#25973](https://github.com/ziglang/zig/issues/25973)) and the
underlying URL/hash-mismatch footgun
([ziglang/zig#16998](https://github.com/ziglang/zig/issues/16998)) keeps
catching maintainers — including 2025 reports of stale hashes that drift
even when nothing changed locally
([ziglang/zig#14602](https://github.com/ziglang/zig/issues/14602)).

**Proposed tool:** `zig_zon_dep_sync`.

- Manifest group: `formatting_and_edits` (apply-gated source mutation).
- Inputs: optional `dependency` (name or alias), optional `url`, optional
  `path`, `apply: boolean` (preview-first, defaults false).
- Outputs: structured per-dep status (`current_url`, `current_hash`,
  `fetched_hash`, `match`, `replacement_zon_fragment`,
  `preimage_identity`), `unified_diff`, list of unresolved deps, exact
  `zig fetch` argv used.
- Backend: `zig fetch --save=false <url>` driven by zigar's existing
  command runner; preview/apply gate inherits the `zig_format` /
  `zigar_patch_session_apply` pattern.

**Why net-new.** Existing `zig_dependency_update_plan` is plan-only and
`zig_dependency_fetch_check` only verifies the current manifest — neither
reaches into `build.zig.zon` to rewrite hashes. This compresses the
"bogus-hash → build → copy → rerun" loop into one preview/apply call.

**Verdict:** clear-win. **Effort:** M.

---

### 2. Migrating to Zig 0.16's `std.Io` interface

**Friction.** 0.16 is "extremely breaking" against everything that
touches I/O. `std.io.Reader`/`Writer` are deprecated for `std.Io.Reader`
/`Writer`; `std.net.Address` is gone; `std.time.Instant`, `Timer`, and
`timestamp` moved under `std.Io.Timestamp`; `std.fs` is migrating into
`std.Io.Dir`/`File`; `std.posix` is nearly removed
([0.16 release notes](https://ziglang.org/download/0.16.0/release-notes.html),
[devclass coverage](https://devclass.com/2025/07/07/zig-lead-makes-extremely-breaking-change-to-std-io-ahead-of-async-and-awaits-return/),
[Andrew Kelley's writeup](https://andrewkelley.me/post/zig-new-async-io-text-version.html)).
Public reaction ranges from confusion
([openmymind: "I'm too dumb for Zig's new IO interface"](https://www.openmymind.net/Im-Too-Dumb-For-Zigs-New-IO-Interface/),
[discussion on Ziggit](https://ziggit.dev/t/im-too-dumb-for-zigs-new-io-interface/11645))
to in-flight project migrations
([Ghostty's 0.16 migration meta-issue](https://github.com/ghostty-org/ghostty/issues/12228),
[ziggit: porting Reactor to 0.16.x](https://ziggit.dev/t/porting-reactor-to-0-16-x-std-io-move-to-proactor/14132),
[ziggit: trying to get back into zig with 0.16.x](https://ziggit.dev/t/trying-to-get-back-into-zig-with-0-16-x/13976)).
There is no tool that audits a tree and tells the developer which call
sites need touching.

**Proposed tool:** `zig_io_migration_scan`.

- Manifest group: `static_analysis` (parser-backed, advisory).
- Inputs: optional `paths` (default: workspace), `from_version` /
  `to_version` (default `0.15`/`0.16`), `limit`.
- Outputs: structured `findings[]` with `file`, `line`, `pattern`
  (`std.fs.openFile`, `file.reader()`, `std.net.Address.parseIp`,
  `std.time.Instant.now`, `std.posix.read`, …), `recommended_replacement`
  (textual, from a curated 0.15→0.16 mapping table), `mapping_confidence`
  (`exact` | `likely` | `manual_review`), and a per-file rollup of
  unmigrated call counts. Companion `_json` variant for agents.
- Backend: zigar's existing `std.zig.Ast` walker (already used by
  `zig_ast_imports` / `zig_ast_decl_summary`) plus a static mapping table
  shipped in `src/manifest/definitions/`.

**Why net-new.** Existing `zig_ast_imports` lists imports but does not
flag deprecated APIs; `zig_explain_errors` reacts to compile failures
rather than auditing ahead of them.

**Verdict:** clear-win. **Effort:** M (most cost is curating the mapping
table; the AST plumbing exists).

---

### 3. "unable to evaluate comptime expression" — but why?

**Friction.** This is the single most-cited unhelpful Zig diagnostic.
[ziglang/zig#11221](https://github.com/ziglang/zig/issues/11221) is
explicitly titled "`unable to evaluate constant expression` should
explain why the value has to be comptime known" and has been open since
2022. Related cases:
[ziglang/zig#19867](https://github.com/ziglang/zig/issues/19867)
("operation is runtime due to this operand. However, it is entirely
compile time"),
[ziglang/zig#22580](https://github.com/ziglang/zig/issues/22580)
(regression in comptime values inside `inline for`), and the recurring
[ziggit thread on the same compile errors](https://ziggit.dev/t/dealing-with-getting-the-same-compiler-errors-over-and-over-again/5202).
Today the developer must read the surrounding code and guess which
operand the compiler is unhappy about.

**Proposed tool:** `zig_comptime_diagnose`.

- Manifest group: `static_analysis` (parser-backed, advisory).
- Inputs: `file`, `line`, `character` (the diagnostic location), optional
  `content` for unsaved buffers, optional `error_text` so the tool can use
  the compiler's existing note positions when present.
- Outputs: `enclosing_context` (e.g. "argument to `@call` modifier
  `.compile_time`", "type position", "array length"), `runtime_operands[]`
  with `name`, `source_location`, `inferred_reason` (e.g. "function
  parameter without `comptime` keyword", "value of type `[]const u8`
  loaded from runtime slice", "depends on runtime-known function call"),
  `likely_fixes[]` (e.g. "add `comptime` qualifier on parameter N",
  "promote value to a top-level `const`"), `confidence`, `cross_check`
  (`zig ast-check <file>`), `limitations`.
- Backend: AST walk from the cursor outward identifying the comptime
  position (`@TypeOf`, struct field types, switch prong values, array
  lengths, etc.), then a backwards data-flow walk on each operand
  expression. Pure `std.zig.Ast`.

**Why net-new.** `zig_explain_errors` and `zig_compile_error_index` parse
compiler output but do not analyze the AST around the offending
expression. This is a localized parser-backed diagnostic, not a generic
error explainer.

**Verdict:** clear-win. **Effort:** L (the AST analysis is fiddly, but
the scope is bounded to comptime-position rules).

---

### 4. ABI mismatches in `packed`/`extern` structs and C interop

**Friction.** Packed and extern structs are an active source of long-
standing compiler bugs and ABI footguns. Examples:
[ziglang/zig#16633](https://github.com/ziglang/zig/issues/16633)
("incorrect layout in `extern struct`"),
[ziglang/zig#24714](https://github.com/ziglang/zig/issues/24714) (enum/
packed types in extern positions without explicit backing — 0.16 makes
this an error but doesn't help you find existing offenders),
[ziglang/zig#6700](https://github.com/ziglang/zig/issues/6700) (`extern`
semantics revisit). In practice, FFI bugs surface as silent corruption
or runtime crashes that are very hard to bisect.

**Proposed tool:** `zig_abi_layout_diff`.

- Manifest group: `static_analysis` (parser-backed for the Zig side;
  command-backed for the optional layout probe).
- Inputs: `zig_file`, `zig_type` (qualified name), `target` (Zig target
  triple, so layout for the right ABI), optional `c_header` and
  `c_type` (or supplied `expected_layout_json`).
- Outputs: `zig_layout` (`size`, `alignment`, `fields[]` with
  `name`, `type`, `bit_offset`, `byte_offset`, `bit_size`),
  `expected_layout` (when a C header or JSON is supplied), `mismatches[]`
  (per-field offset/size/alignment deltas, `severity`,
  `likely_cause` such as "missing `extern`", "packed without explicit
  backing type", "alignment differs across libc choice"), `confidence`,
  `limitations`, `verify_with` (e.g. "build a tiny `@offsetOf`/`@sizeOf`
  probe with `-target <triple>`").
- Backend: zigar's AST walker for Zig-side declarations, optional
  command-backed `zig build-obj` step that compiles a probe like
  `comptime { assert(@offsetOf(T, "x") == N); }` for verification.
  Existing `zig_translate_c` provides the C side. No new backend
  dependency.

**Why net-new.** `zig_public_api` / `zig_api_check` snapshot
public-declaration *names* but not *layout*. zigar has nothing that
inspects struct geometry today.

**Verdict:** clear-win. **Effort:** L (correct layout computation across
targets is non-trivial; mitigated by deferring to a generated
`@offsetOf` probe build).

---

### 5. Picking the right cross-compile target string

**Friction.** Zig's cross-compilation story is one of the language's
biggest selling points
([Andrew Kelley on `zig cc`](https://andrewkelley.me/post/zig-cc-powerful-drop-in-replacement-gcc-clang.html)),
but choosing the right triple plus libc version is consistently confusing
for newcomers. The
[2026 ProteanOS cross-compilation guide](https://proteanos.com/doc/cross-compilation-toolchain-triplet-clib-2026/)
explicitly calls out musl-vs-glibc decisions as a regular source of
"binaries that segfault on startup or, worse, appear to work but exhibit
subtle floating-point corruption." `ZIG_TARGET` detection falls back to
opinionated defaults
([TopicTrick: cross-compilation target guide](https://topictrick.com/blog/zig-cross-compilation-targets)),
and GLIBC version pinning (e.g. `x86_64-linux-gnu.2.28`) is undocumented
folklore.

**Proposed tool:** `zig_target_chooser`.

- Manifest group: `core_zig` (deterministic intent→target translation,
  read-only).
- Inputs: structured `intent` — `os` (`linux`/`macos`/`windows`/`wasi`/
  `freestanding`), `arch`, optional `libc_strategy` (`static_musl`,
  `glibc_min_version`, `system`, `none`), optional `min_os_version`,
  optional `runtime` (`native`, `qemu`, `wasmtime`, `browser`).
- Outputs: `target_triple` (full string with glibc version suffix when
  needed), `zig_build_flags[]`, `runtime_argv[]` (e.g. `qemu-aarch64`
  invocation if cross-running), `notes[]` (e.g. "musl-built binary will
  run on any glibc≥2.17 host; switch to `-fno-pie` if linking with
  ancient toolchains"), `unsupported_combinations[]`, `cross_check`
  (suggested `zig_qemu_test` or `zig_cross_smoke` call).
- Backend: zigar's existing `zig env` and `zig targets --json` outputs
  plus a curated mapping. No new backend.

**Why net-new.** `zig_targets` lists every triple Zig knows; this is
intent→answer instead of catalog-dump. It complements but doesn't
duplicate `zig_target_matrix_plan` (CI-matrix orientation) or
`zig_target_runtime_plan` (advisory).

**Verdict:** clear-win. **Effort:** M.

---

### 6. Triaging `GeneralPurposeAllocator` leak output

**Friction.** GPA leak reports are noisy and platform-dependent. On
Windows there's no stack trace at all
([ziglang/zig#6687](https://github.com/ziglang/zig/issues/6687)), so the
developer gets "Memory leak detected" and nothing else. On POSIX you get
return traces but multiple leaks at the same site are not grouped, and
there's no normalized way for an agent to act on the output. Community
guides
([ITNEXT: Detecting Memory Leaks in Zig](https://itnext.io/detecting-memory-leaks-in-zig-using-the-general-purpose-allocator-b63be2cbd1f5),
[tgmatos.dev: Defeating Memory Leaks With Zig Allocators](https://tgmatos.dev/defeating-memory-leaks-with-zig-allocators/))
describe the same manual triage workflow over and over.

**Proposed tool:** `zig_leak_triage`.

- Manifest group: `runtime_diagnostics`.
- Inputs: `text` (captured stderr) or `path` (log file) or `command` (run
  the binary, preview-first, apply-gated). Optional `target`,
  `binary_path` (for symbol resolution), `symbolizer_path` (LLVM).
- Outputs: `leaks[]` with `size`, `count`, `allocation_site`,
  `return_trace[]` (symbolized when possible), `grouped_by_site` rollup,
  `total_bytes_leaked`, `platform_limitations` (e.g. "no return trace on
  Windows; rerun under Linux/macOS for full symbolic context"),
  `next_actions` (e.g. "inspect `Allocator.alloc` callers at <file:line>"
  with cross-checks via `zig_valgrind_memcheck` or `zig_heaptrack_run`).
- Backend: log parser + zigar's existing `llvm-symbolizer` integration
  for return-trace resolution. No new backend.

**Why net-new.** `zig_heaptrack_run` and `zig_valgrind_memcheck` invoke
external tools; nothing parses or de-duplicates GPA's own output.
`zig_sanitizer_fusion` is sanitizer-focused.

**Verdict:** clear-win. **Effort:** S (parsing) + M (Windows guidance).

---

### 7. Translating fuzzy test names into `--test-filter` argv

**Friction.** Zig's `--test-filter` matches on fully-qualified names
generated from file path plus the `test "Description"` string (see
[ziggit thread on filter usage](https://ziggit.dev/t/how-to-filter-test-using-test-filter-test-name-in-conjunction-with-build-zig/5609)
and the
[upstream test_runner.zig](https://github.com/ziglang/zig/blob/master/lib/compiler/test_runner.zig)).
Unnamed tests get auto-names like `test_0`, which agents and humans
both fail to predict. The recurring workaround is to run the whole suite,
grep for the matching name, then re-run with that exact filter.

**Proposed tool:** `zig_test_name_resolve`.

- Manifest group: `static_analysis` (parser-backed) with a runtime cross-
  check.
- Inputs: `query` (substring, glob, or regex), optional `paths`,
  `match_strategy` (`substring` | `glob` | `regex`), `limit`.
- Outputs: `matches[]` with `file`, `fully_qualified_name`,
  `is_unnamed` (true for `test_NN` blocks), `line`, `recommended_argv`
  (the exact `--test-filter` value the test runner expects), and a
  consolidated `zig_test_argv` ready for the existing `zig_test` tool.
- Backend: zigar's `std.zig.Ast` walker (already used by `zig_ast_tests`)
  with name-resolution rules matching `test_runner.zig`'s naming policy.
  No new backend.

**Why net-new.** `zig_test_select` is impact-based, `zig_test_discover`
lists tests, `zig_test_map` is structural — none translate a fuzzy
human/agent name into the exact filter string the runner expects.

**Verdict:** clear-win. **Effort:** S.

---

### 8. Decoding linker errors after `zig build`

**Friction.** Undefined-symbol errors are a familiar wall for newcomers.
ARM Cortex-M0+ debug builds notoriously fail with
[`undefined symbol: __clzsi2`](https://github.com/ziglang/zig/issues/13465);
shared-library link errors are reported via unhelpful messages
([ziglang/zig#18890](https://github.com/ziglang/zig/issues/18890));
[ziglang/zig#25921](https://github.com/ziglang/zig/issues/25921) shows
even "simple system library" linking confuses people. The fix is
mechanical (add `linkLibC()`, `linkSystemLibrary("…")`, or pull in
`compiler_rt`), but the developer must know the mapping by heart.

**Proposed tool:** `zig_linker_error_decode`.

- Manifest group: `core_zig` (advisory diagnostic; parser-backed for
  source proposals).
- Inputs: `text` (captured build output) or `command` to run, optional
  `build_zig_path`.
- Outputs: `errors[]` with `raw_message`, `missing_symbol`,
  `classification` (`compiler_rt_intrinsic`, `libc_symbol`,
  `system_library`, `cpp_runtime`, `unknown`), `likely_fix`
  (e.g. "add `target.os.tag != .freestanding or compiler_rt_strategy =
  .static`"), `proposed_build_zig_change` (a unified diff snippet, no
  apply gate at this stage — it's a hint, not a write), `confidence`,
  `cross_check` (e.g. "`zig build -freference-trace`").
- Backend: curated lookup tables shipped in `src/manifest/definitions/`
  for known symbols (compiler-rt set, common libc symbols, frequently
  needed system libraries per platform). No new backend.

**Why net-new.** `zig_explain_errors` is a generic explainer.
`zig_compile_error_index` groups errors by file. Neither knows that
`__clzsi2` is a compiler-rt intrinsic that gets pulled in when
optimizing-for-debug ARM targets.

**Verdict:** needs-validation. The catalog of symbol→fix mappings is
finite but maintenance-heavy across Zig releases.
**Effort:** M (initial catalog) + ongoing curation.

---

### 9. Recovering when `@cImport` fails on a macro

**Friction.** `translate-c` chokes on a long-standing list of macro
patterns: struct-literal macros
([ziglang/zig#8949](https://github.com/ziglang/zig/issues/8949)), token
concatenation
([ziglang/zig#18974](https://github.com/ziglang/zig/issues/18974)),
macros that expand to extern function calls
([ziglang/zig#17862](https://github.com/ziglang/zig/issues/17862)),
macros accessing extern variables
([translate-c#207](https://github.com/ziglang/translate-c/issues/207)),
and many more
([ziglang/zig#1085](https://github.com/ziglang/zig/issues/1085) is the
umbrella). The community workaround is consistent: write a tiny `def.h`
wrapper that re-exposes the problem identifier in a translate-c-friendly
form, then `@cInclude` that. This is mechanical but tedious.

**Proposed tool:** `zig_cimport_macro_wrap`.

- Manifest group: `core_zig` (apply-gated workspace artifact).
- Inputs: `c_header` (path of the offending header), optional
  `error_text` (the `@compileError` payload produced by translate-c) or
  optional `failing_identifiers[]`, `apply: boolean`.
- Outputs: `wrappers[]` with `original_identifier`, `wrapper_name`,
  `wrapper_kind` (`inline_fn`, `static_const`, `type_alias`),
  `generated_header_path` (under `.zigar-cache/cimport-wrappers/`),
  `generated_header_content`, `recommended_zig_usage`,
  `preimage_identity`, `limitations`.
- Backend: classify the macro syntactically (the failing identifiers and
  the original C tokens are known), then template a wrapper. Uses
  zigar's existing artifact-registry path; no new backend.

**Why net-new.** `zig_translate_c` only runs translate-c; nothing
generates the recovery wrapper.

**Verdict:** needs-validation. The macro→wrapper templating only handles
the well-known failure modes; pathological macros still need a human.
**Effort:** M.

---

### 10. Finding what's eating the comptime evaluation budget

**Friction.** `error: evaluation exceeded N backwards branches` is the
sign that the developer needs `@setEvalBranchQuota`, but it never tells
them which loop/recursion is the culprit. Compounding the problem,
deeply recursive comptime can simply stack-overflow with no error
([ziglang/zig#13724](https://github.com/ziglang/zig/issues/13724)), and
quota-tuning is by trial and error. There is no tooling today that says
"this `inline for` consumed 90% of your budget."

**Proposed tool:** `zig_comptime_quota_probe`.

- Manifest group: `static_analysis` with command-backed verification.
- Inputs: `command` (the `zig build` invocation that fails), optional
  `max_quota` (defaults to a bounded ceiling), optional
  `binary_search: boolean` (default true).
- Outputs: `passing_quota` (smallest quota that compiles), `failed_at[]`
  (per-call-site evidence collected during the search), `top_consumers[]`
  with `file`, `line`, `expression_kind` (e.g. `inline for`, `comptime
  fn`, `@Type`), `recommended_setEvalBranchQuota_value`, `limitations`
  ("budget attribution is heuristic; this is a search, not a profiler"),
  `cross_check`.
- Backend: zigar's existing command runner with the apply gate already
  used by `zig_bench_baseline`. Each probe is a fresh `zig build`
  invocation with an injected `@setEvalBranchQuota`. No new backend.

**Why net-new.** No existing zigar tool probes the comptime budget;
`zig_explain_errors` only echoes the failure message.

**Verdict:** needs-validation. Binary-search adds wall-clock cost, and
budget attribution by call-site is approximate — it should be marketed
as "find a quota that works, identify likely culprits" rather than
"profile comptime." Useful when stuck; not for routine builds.
**Effort:** M.

---

## Backend Integrations Required

Each proposal above was scoped to reuse zigar's existing backend
catalog. Summary:

| Proposal | Backend used | New integration? |
| --- | --- | --- |
| 1. `zig_zon_dep_sync` | `zig fetch` (command-backed) | No |
| 2. `zig_io_migration_scan` | `std.zig.Ast` | No |
| 3. `zig_comptime_diagnose` | `std.zig.Ast` | No |
| 4. `zig_abi_layout_diff` | `std.zig.Ast` + `zig build-obj` probe + optional `zig translate-c` | No |
| 5. `zig_target_chooser` | `zig env`, `zig targets --json` | No |
| 6. `zig_leak_triage` | log parser + `llvm-symbolizer` | No (already covered by runtime diagnostics tier) |
| 7. `zig_test_name_resolve` | `std.zig.Ast` | No |
| 8. `zig_linker_error_decode` | curated catalog, no execution | No |
| 9. `zig_cimport_macro_wrap` | template generator + workspace artifact registry | No |
| 10. `zig_comptime_quota_probe` | `zig build` command runner | No |

**None of the ten proposals require a backend integration that zigar
does not already ship.** That keeps the marginal cost of adding any
single tool low — most of the work is in the manifest schema, the use-
case module, the apply-gate plumbing, and the curated mapping tables
for the catalog-driven proposals (#5, #8, #9).

The highest-leverage proposals are #1 (`zon_dep_sync`), #2
(`io_migration_scan`), and #3 (`comptime_diagnose`) — each compresses a
workflow that essentially every Zig developer hits this year, and each
maps cleanly onto an existing zigar tier (apply-gated source edit,
parser-backed audit, parser-backed diagnostic). The remaining proposals
are individually smaller wins but collectively close most of the gap
between zigar's current capability set and the friction Zig developers
describe today.
