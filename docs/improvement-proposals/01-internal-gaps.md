# Improvement Proposals — 01: Internal Gap Analysis

**Author:** Claude Opus 4.7 (1M context)
**Date:** 2026-05-27
**Scope:** Read-only audit of `src/manifest/definitions/*.zig`, `src/adapters/`,
`src/infra/`, and `src/domain/` against the public tool catalog in
[tool-index.generated.md](../tool-index.generated.md).
**Goal:** Identify net-new tool capabilities (or workflow compressions) whose
backend/infra is already wired but unexposed.

Out of scope: anything already on the P0-P4 list in the prior private Claude
analysis note
(release upload, npm publish, skills decision, coverage gate, shim smoke,
README routing, ADRs, error catalog, perf thresholds, backend variants as
build targets, GPG signing, LLM-judge tests, mcpb pin doc).

## Method

The ZLS infra audit found that [src/infra/zls/client.zig:94-114](../../src/infra/zls/client.zig) exposes a
generic `sendRequest(method, params)` that can invoke any LSP method, but only
~10 are explicitly recognized in [src/app/usecases/zls/code_intel.zig:167-176](../../src/app/usecases/zls/code_intel.zig)
and projected as tools. The domain audit found that
[src/domain/zig/analysis.zig](../../src/domain/zig/analysis.zig) has an AST walker that already extracts
declarations, imports, and tests — but ignores ABI/safety-relevant Zig
constructs (packed/extern layout, function attributes, comptime, atomics,
@panic, @ptrCast, asm, etc.) that are syntactically obvious in the AST.

Each proposal below names exactly one wired-but-unexposed surface area and
the workflow it would compress.

---

## Proposals

### 1. `zig_call_hierarchy`

**Description.** Incoming/outgoing call hierarchy for a Zig symbol via ZLS's
LSP call-hierarchy methods (`textDocument/prepareCallHierarchy`,
`callHierarchy/incomingCalls`, `callHierarchy/outgoingCalls`).

**Manifest group:** `zls`.

**Builds on:** Generic ZLS transport at [src/infra/zls/client.zig:94](../../src/infra/zls/client.zig); same
session/lifecycle that already powers `zig_references` and `zig_definition`.
Needs a `CallHierarchyItem` struct added to [src/infra/zls/types.zig](../../src/infra/zls/types.zig).

**User story.** An agent prepping a refactor needs to know "what calls this
function, transitively, up to depth N." Today it must call `zig_references` to
get callers, then `zig_definition` on each caller, then `zig_references`
again, recursing manually. One call-hierarchy invocation replaces that loop
and gives bounded results with parent/child edges.

**Why substantial.** Net-new ZLS capability and a workflow compression of an
otherwise N-round-trip recursion. Pairs with `zig_semantic_callers` for
backend cross-check.

**Effort:** M.

---

### 2. `zig_type_hierarchy`

**Description.** Supertype/subtype navigation for a Zig type via ZLS's
`textDocument/prepareTypeHierarchy`, `typeHierarchy/supertypes`, and
`typeHierarchy/subtypes`.

**Manifest group:** `zls`.

**Builds on:** Same ZLS transport and session machinery as #1; needs a
`TypeHierarchyItem` struct in [src/infra/zls/types.zig](../../src/infra/zls/types.zig).

**User story.** An agent looking at a tag union or an interface-style
struct (with embedded `vtable` fields, the common Zig idiom) needs the set of
concrete types that participate. Today it has to grep for `usingnamespace`,
`*const T`, or function pointer fields and reconstruct the relationship by
hand.

**Why substantial.** Net-new navigation primitive. Zig has no `class
extends`, so type relationships are scattered — having ZLS report them
structurally is a real capability lift.

**Effort:** M.

---

### 3. `zig_typedef_jump`

**Description.** Single-call resolution of `textDocument/typeDefinition`,
`textDocument/implementation`, and `textDocument/declaration` for a given
position, returning all three answers (and their differences) in one
response.

**Manifest group:** `zls`.

**Builds on:** ZLS LSP transport; reuses the position/document plumbing of
the existing `zig_definition` handler in [src/app/usecases/zls/code_intel.zig](../../src/app/usecases/zls/code_intel.zig).

**User story.** Given `var foo: MyType = bar()`, agents currently can only
ask `zig_definition` (which lands on `bar`). They have no way to jump to
`MyType` (typeDefinition) or to the implementation behind a function-pointer
field (implementation). All three are first-class LSP methods that ZLS
already serves and zigars already has wiring to call.

**Why substantial.** Currently zero ways to get typeDefinition or
implementation from zigars; surfacing them as one grouped call avoids three
separate tool round-trips when an agent doesn't know which one it needs.

**Effort:** S–M.

---

### 4. `zig_inlay_hints`

**Description.** Inline type and parameter-name hints for a file or range
via `textDocument/inlayHint`.

**Manifest group:** `zls`.

**Builds on:** ZLS LSP transport; needs an `InlayHint` struct in
[src/infra/zls/types.zig](../../src/infra/zls/types.zig). ZLS computes these natively for `:=` inferred types
and call-site parameter names.

**User story.** An agent reading `const r = computeStuff(42, true, .{ .x = 1 });`
needs to know that `r: ComputedResult` and that the booleans are
`force_recompute` and `dry_run`. Today the agent must hover each
sub-expression separately or chase the function signature. Inlay hints give
the same context an IDE user sees.

**Why substantial.** Materially improves agent comprehension of inferred
types — a Zig-specific pain point. Closes parity with what ZLS already
serves human users.

**Effort:** M.

---

### 5. `zig_workspace_file_rename`

**Description.** Rename or move a workspace `.zig` file and atomically
rewrite every `@import("old-path")` in the workspace, returning the diff for
preview and applying only with `apply=true`.

**Manifest group:** `formatting_and_edits`.

**Builds on:** ZLS `workspace/willRenameFiles` for the workspace edit
proposal; existing `zig_update_imports` handler in
[src/app/usecases/editing/](../../src/app/usecases/editing/) for the rewrite mechanics; existing
`zigars_patch_session_*` for transactional apply/rollback; workspace
filesystem store at [src/infra/workspace/filesystem.zig](../../src/infra/workspace/filesystem.zig) for the move.

**User story.** Agent renames `src/foo/old_name.zig` → `src/foo/new_name.zig`.
Today this takes: shell `mv` (out of workspace policy), then grep for every
`@import("foo/old_name.zig")`, then `zig_update_imports` per match, then
manual ast-check. A single `zig_workspace_file_rename` call returns a
patch-session-style preview of the move + every import update, then applies
them as one transaction.

**Why substantial.** No existing tool composes file move + import rewrite +
transactional apply. This is one of the highest-value missing refactors for
multi-file Zig work and currently is impossible to do safely as one
operation.

**Effort:** L.

---

### 6. `zig_build_script_inspect`

**Description.** Parser-backed structural analysis of `build.zig` returning
typed records for `addExecutable`, `addStaticLibrary`, `addModule`,
`addTest`, `dependency`, `addImport`, `installArtifact`, `step.dependOn`,
and named build options.

**Manifest group:** `static_analysis` (or new home in `core_zig`).

**Builds on:** [src/domain/zig/analysis.zig](../../src/domain/zig/analysis.zig)'s existing AST walker — extend
`appendAstDecls` to recognize the `std.Build` API call sites. Pairs with
`zig env` for resolved paths.

**User story.** An agent needs to know "what targets does this project
build, what modules does it expose, what dependencies does it pull from
`build.zig.zon`?" Today three heuristic tools (`zig_build_graph`,
`zig_build_targets`, `zig_build_options`, all
`advisory_orientation`/`medium`-confidence) approximate this by scanning
text. A parser-backed pass returns the same answers with `parser_backed`
confidence and stable structured fields.

**Why substantial.** Promotes three advisory tools to parser-backed in a
single call. Build-script comprehension is foundational for every other
build/test workflow; raising it from heuristic to parser-backed is a real
quality lift.

**Effort:** L.

---

### 7. `zig_memory_layout`

**Description.** Parser-backed catalog of `packed struct`, `extern struct`,
`extern union`, `align(N)`, `pub const X = enum(uN)`, and `comptime`-sized
arrays — returning per-type field positions, declared alignment, and
size-affecting annotations.

**Manifest group:** `static_analysis`.

**Builds on:** [src/domain/zig/analysis.zig](../../src/domain/zig/analysis.zig)'s AST walker. The node kinds
needed (`container_decl`, `align_expr`, `int_lit`) are already touched by
`appendAstDecls` but the layout-relevant attributes are dropped on the
floor.

**User story.** An agent writing FFI bindings or working on an embedded
target needs the layout of every C-ABI struct in the project — alignment,
packing, integer-backed enum width, padding rules. Today the only path is
hand-reading source and cross-referencing the Zig language reference.

**Why substantial.** Net-new domain capability tightly aligned with two
audiences zigars already targets (FFI and embedded — `zig_embedded_detect`
and `zig_microzig_plan` exist). One call replaces a per-file manual review.

**Effort:** M.

---

### 8. `zig_unsafe_operations_audit`

**Description.** Parser-backed catalog of `@ptrCast`, `@intCast`, `@bitCast`,
`@alignCast`, `@truncate`, `@ptrFromInt`, `@intFromPtr`, `volatile`
load/store, `@atomicLoad`/`@atomicStore`/`@atomicRmw`/`@cmpxchg*`, inline
`asm` blocks, and `@memcpy`/`@memset` sites — with per-site file/line and a
classification ("type-erasing", "endian-sensitive", "memory-ordering",
"concurrency", "ABI", "ASM").

**Manifest group:** `static_analysis`.

**Builds on:** [src/domain/zig/analysis.zig](../../src/domain/zig/analysis.zig) AST walker (builtin call site
detection is straightforward in `std.zig.Ast`). Classification can reuse the
existing `domain/diagnostics/crash.zig:43-51` `FailureKind` taxonomy.

**User story.** An agent doing a security review or porting a project to a
new target needs every "unsafe-ish" operation surfaced once. Today this
requires `rg` for each builtin name and manual triage. A single tool returns
a structured audit with stable fingerprints suitable for baselines/diffs.

**Why substantial.** No existing tool covers this set. `zig_allocations`
exists but is heuristic and scoped to allocator usage. This is a distinct,
high-value safety surface.

**Effort:** M.

---

### 9. `zig_safety_site_catalog`

**Description.** Parser-backed catalog of every `@panic(...)`,
`@compileError(...)`, `unreachable`, `std.debug.assert(...)`,
`std.debug.panic(...)`, and explicit `return error.X` site, grouped by file
and kind, with stable fingerprints.

**Manifest group:** `static_analysis`.

**Builds on:** [src/domain/zig/analysis.zig](../../src/domain/zig/analysis.zig) AST walker (these are all
identifiable from `builtin_call`, `unreachable_literal`, and
`field_access` nodes). The pre-existing
`tools/quality/`-style hygiene counters already enumerate `@panic` and
`unreachable` in CI but the count never reaches the MCP surface.

**User story.** An agent reviewing a safety-critical Zig codebase wants
"every site where the program intentionally terminates, refuses to compile,
or hands an error back." Today this is `rg` plus manual classification per
match.

**Why substantial.** Zig's safety story is built on these exact builtins;
having them in a structured catalog is the foundation for release-gate
checks, baseline diffs, and "did this PR add a new @panic?" workflows. Pairs
naturally with `zig_lint_baseline`/`zig_lint_trend`.

**Effort:** S–M.

---

## Cross-cutting notes

**Why ZLS-backed proposals (#1–#4) cluster together.** The infra audit
confirms [src/infra/zls/client.zig:94](../../src/infra/zls/client.zig) already supports any LSP method via
generic `sendRequest`. The only missing pieces are (a) request/response
struct definitions in [src/infra/zls/types.zig](../../src/infra/zls/types.zig) and (b) a use-case wrapper
plus tool registration. Adding one of these is essentially a fixed cost; the
incremental cost of adding the next one is small. A staged plan would land
#3 first (lowest cost, uses existing position/location types) and use that
to validate the pattern before #1/#2/#4.

**Why parser-backed proposals (#6–#9) cluster together.** All four extend
the same AST walker in [src/domain/zig/analysis.zig:277-311](../../src/domain/zig/analysis.zig). Each
adds a focused visitor for a different node-kind subset, reuses the existing
declaration/file-bounded scaffolding, and slots into the
`parser_backed`/`confidence: high` capability tier already advertised for
`zig_ast_*`. Bundling #6–#9 into one PR sequence would amortize the
walker-extension work.

**#5 sits alone** because file-rename refactor needs both ZLS workspace
edits AND the patch-session/workspace-filesystem machinery; it should be
scoped as its own work item.
