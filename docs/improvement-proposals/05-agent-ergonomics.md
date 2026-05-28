# 05 — Agent Ergonomics Primitives

**Author:** Claude Opus 4.7 (1M context)
**Date:** 2026-05-27
**Status:** Proposal — read-only analysis, no code or doc changes made.
**Scope:** Net-new structural-query primitives that let an Orchestrator,
Planner, Test Author, Test Reviewer, or Implementer agent reason about a Zig
codebase without falling back to `rg` + multi-file reads. Excludes anything
already shipping (see [tool-index.generated.md](../tool-index.generated.md))
and anything already on the prior private Claude analysis note's P0-P4 list or in
[01-internal-gaps.md](01-internal-gaps.md), [03-zig-dev-pain.md](03-zig-dev-pain.md),
or [04-compound-workflows.md](04-compound-workflows.md).

---

## 1. Method

Existing zigars tools were grouped by the **agent reasoning question** they
answer (e.g. "what calls X?", "what tests exercise X?", "where should X
live?"). Each candidate primitive was checked against four filters:

1. **Role-grounded.** Does at least one named role in the SluiceDB-style
   workflow (Orchestrator / Planner / Test Author / Test Reviewer /
   Implementer) need exactly this answer to make its next decision?
2. **Net-new structural answer.** Today the agent has no zigars tool that
   returns this fact directly — it must grep, read 3+ files, or compose 4+
   tool calls.
3. **Grep-inadequate.** A regex over source can return *candidates* but not
   the structured answer (e.g. "which tests transitively reference this
   symbol" is not a regex answer; the regex finds string matches, not
   reachability).
4. **Not already proposed.** Specifically excludes `zig_call_hierarchy`,
   `zig_type_hierarchy`, `zig_typedef_jump`, `zig_inlay_hints`,
   `zig_workspace_file_rename`, `zig_build_script_inspect`,
   `zig_memory_layout`, `zig_unsafe_operations_audit`,
   `zig_safety_site_catalog` (all from 01), and `zig_build_bisect`,
   `zig_dependency_migrate`, `zig_crash_capture_session`,
   `zig_c_header_port`, `zig_workspace_rename`, `zig_bench_regression_gate`,
   `zig_target_matrix_run`, `zig_allocator_audit` (all from 04).

Proposals are ordered by expected agent leverage and grouped by primary
consumer role.

---

## 2. Proposals

Zigars' internal hexagonal architecture guard is intentionally not projected as
a public `zig_*` tool in this proposal. Public tools below should expose
architecture-neutral structural facts unless a future project explicitly opts
into a configured architecture profile.

### 2.1 `zig_test_for_symbol` — reverse test-coverage map

**Primary role:** Test Reviewer (validates Test Author's coverage before
Implementer starts). Also: Orchestrator (post-implementation gate).

**Question it answers.** "For symbol `S` (a function, type, or public
constant), which tests in the workspace transitively reference it?"
Inverse of `zig_test_select_semantic`, which goes from changed files to
candidate tests. The Reviewer needs the opposite: given a backlog item's
**intended** symbol, return the tests claiming coverage — and flag when the
count is zero.

**Input/output sketch.**
```jsonc
// input
{
  "symbol": "src/domain/zig/analysis.zig:Declaration",  // or just "Declaration"
  "depth": 2,                                            // call-graph depth
  "include_indirect": true,                              // via imports/re-exports
  "limit": 50
}
// output
{
  "symbol": { "qualified_name": "...", "kind": "type", "file": "...", "line": 19 },
  "direct_tests":    [ { "file": "...", "test_name": "...", "line": 42, "distance": 1 } ],
  "indirect_tests":  [ { "file": "...", "test_name": "...", "via": [ "fn_a", "fn_b" ], "distance": 3 } ],
  "uncovered_arms":  [ { "kind": "error_arm", "name": "error.OutOfMemory" } ],
  "evidence_basis": "semantic_index",
  "limitations":    [ "reflection-based dispatch not modelled" ],
  "confidence":     "medium"
}
```

**Why grep is inadequate.** `rg Declaration tests/` matches the *string* but
not the *symbol* — same name, different module, shadowed identifier. It
also misses tests that reach `Declaration` through a re-export
(`zig_analysis = @import("...analysis.zig")` → `zig_analysis.Declaration`).
A Reviewer who trusts grep here will sign off on tests that exercise an
unrelated `Declaration`.

**Why read-many-files is inadequate.** Today the chain is
`zig_semantic_decl(S)` → `zig_semantic_callers(S)` → for each caller, check
`zig_ast_tests(file)` → repeat. That is 1 + N + N reads for depth 1; depth
2 is N²-ish. Plus the agent has to dedupe and decide reachability.

**Effort:** **M.** Composes existing `zig_semantic_index`, `zig_semantic_callers`,
and `zig_ast_tests`. The bounded reverse-closure walk is the only new piece.
The `uncovered_arms` hint (error arms / enum tags not asserted) is the
optional stretch — useful for Reviewers but reasonable to land in a v2.

### 2.3 `zig_module_surface` — directory-level public API aggregate

**Primary role:** Planner (identifying clean extension points), Reviewer
(scoping a refactor's blast radius).

**Question it answers.** "For module `M` (a directory like `src/domain/zig/`),
what is the consolidated public surface that the rest of the workspace
consumes, and who consumes it?" `zig_public_api` answers this per file;
`zig_import_graph` shows the wiring; neither aggregates to a module-level
contract.

**Input/output sketch.**
```jsonc
// input
{
  "module": "src/domain/zig/",        // a directory; or a root.zig file
  "include_re_exports": true,         // follow root.zig re-export chains
  "consumer_depth": 2,
  "limit": 100
}
// output
{
  "module": { "path": "...", "root_file": "src/domain/zig/root.zig" },
  "public_exports": [
    { "name": "Declaration", "kind": "type", "origin_file": "...analysis.zig",
      "re_exported_via": [ "src/domain/zig/root.zig", "src/root.zig" ],
      "consumer_count": 7 }
  ],
  "consumers": [
    { "file": "src/app/usecases/.../foo.zig", "uses": [ "Declaration", "skipWorkspacePath" ] }
  ],
  "unused_exports": [ { "name": "...", "origin_file": "..." } ],
  "evidence_basis": "parser_backed"
}
```

**Why grep is inadequate.** A grep for `pub` in a directory misses
re-exports through `root.zig` and conflates same-name symbols from sibling
modules. The "who consumes what" half needs cross-file resolution.

**Why read-many-files is inadequate.** Today an agent runs `zig_public_api`
per file (N calls), then `zig_semantic_refs` on each export (M calls), then
manually aggregates. The information is structured; the aggregation is the
tool.

**Effort:** **M.** Aggregates existing per-file `zig_public_api` over the
directory walker and uses `zig_semantic_refs` for consumers. The
`unused_exports` flag is a 5-line filter (export with `consumer_count == 0`)
that gives a real signal for module-boundary cleanup.

---

### 2.4 `zig_insertion_sites` — "where should this feature live?"

**Primary role:** Planner. This is the canonical first question for a
backlog item: "implement feature X" — *where*?

**Question it answers.** Given a short backlog description and the
workspace, rank existing files/modules by **fit**: topic similarity, module
purpose, sibling-pattern evidence (e.g. "features like X live in
`src/app/usecases/`"), import-neighborhood shape, and project-local naming
conventions.

**Input/output sketch.**
```jsonc
// input
{
  "description": "Add a tool that reports allocator-flow per function.",
  "kind": "new_tool",                  // optional: new_tool|new_use_case|new_domain_helper
  "exclude_paths": [ "tests/" ],
  "limit": 10
}
// output
{
  "candidates": [
    { "path": "src/app/usecases/static_analysis/", "score": 0.82,
      "reasons": [ "sibling: zig_allocations lives here",
                   "module purpose matches 'analysis aggregation'",
                   "nearby files expose the same kind of tool-facing use case" ],
      "siblings_for_pattern": [
        { "file": "...allocations.zig", "pattern": "single-file analysis use-case" }
      ] },
    { "path": "src/domain/zig/analysis.zig", "score": 0.41,
      "reasons": [ "topic match on 'allocator'" ],
      "warnings": [ "similar files are parser-only; tool projection appears to live elsewhere" ] }
  ],
  "anti_candidates": [
    { "path": "src/infra/zls/", "reason": "nearby files are backend wrappers, not analysis aggregators" }
  ],
  "limitations": [ "no NLP backend; ranking is symbol/path/comment heuristic" ]
}
```

**Why grep is inadequate.** Grepping for the words in the description finds
**string** matches, not **structural** ones. The word "allocator" appears
in 40+ files; the right insertion site is the one or two with matching
sibling patterns.

**Why read-many-files is inadequate.** The Planner today scans
`docs/architecture.md`, walks the tree, then picks a site by feel. This is
the single most "agent-by-vibes" step in the SluiceDB workflow and is
exactly the kind of judgment where a structured score with **named reasons**
prevents mis-planning.

**Effort:** **M.** Uses the existing semantic index for symbol/comment
similarity, import graph neighborhoods, sibling-file patterns, and a small
heuristic over the manifest's `tool_catalog.json` for "where do tools of kind
X live now?". No new backend dependency.

---

### 2.5 `zig_test_fixture_inventory` — test-helper & fixture catalog

**Primary role:** Test Author (avoiding redundant fixture code), Test
Reviewer (spotting "should have used existing helper").

**Question it answers.** "What test helpers, fixture builders, and harness
utilities already exist in the workspace? Which tests use each one?"

**Input/output sketch.**
```jsonc
// input
{
  "scope": "tests/",                    // or "src/" or workspace-wide
  "kinds": [ "helper", "fixture", "mock" ],
  "limit": 100
}
// output
{
  "helpers": [
    { "file": "tests/...", "name": "buildFakeWorkspace", "kind": "fixture",
      "signature": "fn (allocator) !FakeWorkspace",
      "uses": 14, "last_used_in": [ "...test_a.zig", "...test_b.zig" ],
      "doc_comment": "Returns a temp-dir workspace with a sample build.zig.zon" }
  ],
  "patterns": [
    { "pattern_name": "arena_per_test",
      "files": [ "..." ],
      "note": "Most workspace tests follow an arena-per-test allocator pattern" }
  ],
  "limitations": [ "classification is heuristic (name suffix + return-type pattern)" ]
}
```

**Why grep is inadequate.** Test helpers don't follow a single naming
convention (`buildFoo`, `makeBar`, `withTempDir`, `fakeX`). A Test Author
either knows the codebase or grep-flails through a dozen patterns.

**Why read-many-files is inadequate.** Reading every test file to find
"helpers I could reuse" is exactly the cold-start problem this primitive
solves. Today the Test Author writes a duplicate fixture because they
didn't find the existing one.

**Effort:** **S–M.** Reuses the AST walker (declarations in test files that
**aren't** `test "..."` blocks). The "uses" count comes from
`zig_semantic_refs` filtered to test-block call sites. Patterns are
heuristic over allocator/setup/teardown shape.

---

### 2.6 `zig_error_propagation` — workspace error-flow graph

**Primary role:** Reviewer (especially Safety / API reviewers).
Implementer asking "if I add `error.OutOfMemory` here, where does it
surface?"

**Question it answers.** "For error `E` (or a fileset's error sets), trace
the propagation flow: where does it originate (first `return error.X`),
through which functions does it propagate via `try`, and where is it
**sunk** (handled with `catch`, swallowed with `catch unreachable`, or
exposed to public API)?"

**Input/output sketch.**
```jsonc
// input
{
  "error": "OutOfMemory",                  // or "scope": "src/app/"
  "include_inferred_sets": true,
  "limit": 200
}
// output
{
  "error": "OutOfMemory",
  "origins": [
    { "file": "...", "line": 42, "function": "allocBuffer",
      "kind": "explicit_return" }
  ],
  "propagation": [
    { "function": "doWork", "file": "...", "kind": "try_propagates",
      "callers": [ "publicEntry" ] }
  ],
  "sinks": [
    { "file": "...", "line": 99, "kind": "catch_handled", "handler": "..." },
    { "file": "...", "line": 117, "kind": "catch_unreachable",
      "concern": "swallows error without diagnostic" }
  ],
  "public_api_exposure": [
    { "function": "pub fn ingest", "in_set": true, "documented": false }
  ],
  "evidence_basis": "parser_backed_flow",
  "limitations": [ "inferred error sets resolved syntactically, not via compiler" ]
}
```

**Why grep is inadequate.** `rg "error.OutOfMemory"` finds string matches
but doesn't distinguish origin from propagation from sink. It also can't
follow `try foo()` where `foo` *inferred* the error set.

**Why read-many-files is inadequate.** The existing `zig_error_sets` is
per-file and reports declared/inferred sets without flow. The Reviewer's
question is **flow-sensitive** and demands closure across the call graph.
`zig_static_fusion` aggregates findings but doesn't trace propagation.

**Effort:** **M–L.** Parser-backed flow over the existing AST walker plus
the semantic call graph. The `catch_unreachable` sink classification is
high-value at low cost; the inferred-set resolution is the harder half and
can be deferred behind a `cross_check_with_compiler` flag. Distinct from
the proposed `zig_safety_site_catalog` (01 #9), which is a static *site*
list, not a *flow* trace.

---

### 2.7 `zig_symbol_dossier` — per-symbol composite for review

**Primary role:** Test Reviewer, Implementer reviewing a peer's symbol.

**Question it answers.** "For symbol `S`, give me everything I'd open six
tabs to read: decl + signature + doc comment, callers, tests, current
diagnostics, lint findings, module role hints, recent git history."

**Input/output sketch.**
```jsonc
// input
{
  "symbol": "src/app/usecases/foo.zig:doWork",
  "include": [ "decl", "callers", "tests", "diagnostics", "lint",
               "module", "history", "public_api_membership" ],
  "history_limit": 5
}
// output
{
  "symbol":   { "qualified_name": "...", "kind": "fn", "signature": "...",
                "doc_comment": "...", "file": "...", "line": 42, "public": true },
  "module":   { "path": "src/app/usecases/foo", "role_hint": "usecase" },
  "callers":  [ /* from zig_semantic_callers, depth-bounded */ ],
  "tests":    [ /* from proposed zig_test_for_symbol (#2.1) */ ],
  "diagnostics": [ /* from zig_diagnostics filtered to file:line */ ],
  "lint_findings": [ /* from zig_zlint filtered */ ],
  "public_api_membership": { "exposed_via": [ "src/root.zig" ] },
  "history":  [ { "ref": "abc1234", "subject": "...", "date": "..." } ],
  "evidence_basis": "composite",
  "omitted_sections": [ ]
}
```

**Why grep is inadequate.** None of these pieces is grep-derivable
individually; the dossier is the orchestration.

**Why read-many-files is inadequate.** This is the canonical "agent opens
six files plus runs three commands" pattern. The dossier compresses it to
one call with stable structure suitable for a Reviewer prompt template.
Similar in spirit to `zigars_context_pack` but **symbol-scoped** rather
than session-scoped.

**Effort:** **S–M.** Pure composition over existing tools plus #2.1.
The git-history slice needs the read-only git surface already used by
`zig_public_api_diff`'s `baseline_ref`. Token budget should follow the
`mode=compact|standard|deep` contract already standard in zigars.

---

### 2.8 `zig_change_risk_audit` — risk-ranked diff summary

**Primary role:** Orchestrator (deciding which files in a Planner's
proposed change-set need the heaviest Reviewer attention), QA gate.

**Question it answers.** "Given this diff (or change-set of files), rank
each file by **blast radius** — importer count × graph centrality × test
coverage delta × public-API delta — so a Reviewer or CI can focus on the
high-risk files first."

**Input/output sketch.**
```jsonc
// input
{
  "diff": "...unified diff...",           // or "changed_files": [ ... ]
  "baseline_ref": "main",
  "weights": { "importers": 1.0, "graph_centrality": 0.7,
               "test_coverage": 1.2, "public_api": 1.5 }   // optional
}
// output
{
  "ranked_files": [
    { "file": "src/domain/zig/analysis.zig", "risk_score": 0.87,
      "risk_class": "high",
      "factors": {
        "importer_count": 14,
        "graph_centrality": 0.73,
        "tests_covering": 6,
        "tests_covering_delta": -2,
        "public_api_delta": { "added": 1, "removed": 0, "changed_sig": 1 }
      },
      "recommended_checks": [ "zig_public_api_diff",
                              "zig_test_select_semantic",
                              "review with zig_symbol_dossier" ]
    }
  ],
  "summary": { "high": 1, "medium": 3, "low": 8 },
  "limitations": [ "test coverage delta is heuristic without coverage run" ]
}
```

**Why grep is inadequate.** Risk is a function of dependency edges, graph
centrality, and test coverage — none of which a grep can compute.

**Why read-many-files is inadequate.** Today the Orchestrator runs
`zigars_impact` (→ importers), `zig_test_select_semantic` (→ tests),
`zig_public_api_diff` (→ API delta) separately and merges. The merge logic
is the value-add — and it's what an Orchestrator should not re-implement
per workflow.

**Effort:** **M.** Composes `zigars_impact`, `zig_test_select_semantic`,
`zig_public_api_diff`, and import-graph centrality. Scoring weights stay
caller-overridable to avoid hard-coding a policy. Distinct from
`zigars_validation_plan` (which plans **commands** to run); this scores
**files** for human/agent attention.

---

### 2.9 `zig_import_cycles` — SCC and topological layering

**Primary role:** Architect / Reviewer; useful as a release-gate signal.

**Question it answers.** "Does the workspace import graph contain cycles?
Which strongly-connected components exist? What is the topological layer
of each module (depth from leaves)?" The graph already exists via
`zig_import_graph` / `zig_import_graph_json`, but the structural questions
above require post-processing the graph in code an agent shouldn't have to
write.

**Input/output sketch.**
```jsonc
// input
{
  "scope": "src/",                  // optional sub-tree
  "include_external": false,        // exclude std + deps
  "limit": 50
}
// output
{
  "cycles": [
    { "scc_id": 1, "size": 3,
      "members": [ "src/a.zig", "src/b.zig", "src/c.zig" ],
      "edges": [ { "from": "a", "to": "b" },
                 { "from": "b", "to": "c" },
                 { "from": "c", "to": "a" } ],
      "severity": "warn",
      "cycle_scope": "local" }
  ],
  "topological_layers": [
    { "depth": 0, "files": [ "src/util/leaf.zig" ] },
    { "depth": 5, "files": [ "src/bootstrap/root.zig" ] }
  ],
  "long_edges": [
    { "from": "src/feature/a.zig", "to": "src/runtime/bootstrap.zig",
      "distance_hint": "crosses 5 path segments" }
  ]
}
```

**Why grep is inadequate.** Cycles are a global property of the graph;
grep cannot find them.

**Why read-many-files is inadequate.** `zig_import_graph_json` returns the
graph; the agent then has to implement Tarjan/Kosaraju in its head and
keep state across N tool calls. SCC detection is a 30-line algorithm
shipped once at the tool boundary, or an `O(N²)`-mistake repeated by every
caller.

**Effort:** **S.** Pure post-processing of the existing
`zig_import_graph_json` output. Severity can come from SCC size, importer
count, public API exposure, and optional project-configured policy hints.

---

### 2.10 `zig_comptime_inspect` — comptime value introspection

**Primary role:** Reviewer (reading dense generic code), Implementer
debugging "why does this comptime branch fire?".

**Question it answers.** "For the comptime expression at `file:line`, what
does it evaluate to in the current toolchain? What is its type? Which other
comptime sites depend on it?"

**Input/output sketch.**
```jsonc
// input
{
  "file": "src/manifest/definitions/core.zig",
  "line": 88,                          // a comptime decl or comptime { ... } block
  "include_dependents": true,
  "timeout_ms": 5000
}
// output
{
  "expression": { "text": "comptime computeFoo(@import(\"...\"))", "kind": "comptime_decl" },
  "evaluated": {
    "type": "[]const Foo",
    "value_preview": "[ {...}, {...}, {...} ]",
    "summary_size": 12,
    "byte_size": 384
  },
  "dependents": [
    { "file": "...", "line": 14, "kind": "comptime_branch", "depends_on": "computeFoo" }
  ],
  "evaluation_basis": "compiler_eval",
  "backend_status": "ok | unavailable | timeout",
  "limitations": [
    "value_preview truncated; use deep mode for full",
    "side-effecting comptime is not supported"
  ]
}
```

**Why grep is inadequate.** Comptime values are computed, not written;
grep cannot evaluate `computeFoo()`.

**Why read-many-files is inadequate.** Today the only way to inspect a
comptime value is `@compileLog(...)` injected into source plus a `zig
build` run. That's a write + build + read cycle for every value. A
parser-or-compiler-backed primitive replaces that loop with one call.

**Effort:** **L.** This is the largest proposal: needs either (a) a sandbox
`zig build` invocation with a generated probe file (`@compileLog`) and
output parsing, or (b) integration with a future `zls`/`zig` introspection
endpoint. Recommend shipping as `evaluation_basis: heuristic_ast_only`
first (returns the AST text, type if inferable, and dependents — but no
**value**) and adding `evaluation_basis: compiler_eval` later when the
sandbox path is wired. Cross-checks with proposal 03 #3 ("unable to
evaluate comptime expression — but why?").

---

## 3. Role coverage map

The matrix below confirms each SluiceDB-style role gains at least one new
high-leverage primitive from the proposals above:

| Role            | New primitives                                                               |
|-----------------|------------------------------------------------------------------------------|
| Orchestrator    | `zig_change_risk_audit` (#2.8), `zig_test_for_symbol` (#2.1, gate)           |
| Planner         | `zig_insertion_sites` (#2.4), `zig_module_surface` (#2.3)                   |
| Test Author     | `zig_test_fixture_inventory` (#2.5), `zig_test_for_symbol` (#2.1)            |
| Test Reviewer   | `zig_test_for_symbol` (#2.1), `zig_symbol_dossier` (#2.7), `zig_error_propagation` (#2.6) |
| Implementer     | `zig_symbol_dossier` (#2.7), `zig_comptime_inspect` (#2.10)                 |
| Architect / QA  | `zig_import_cycles` (#2.9), `zig_change_risk_audit` (#2.8), `zig_module_surface` (#2.3) |

---

## 4. Suggested sequencing

If implemented incrementally, the ordering below maximizes downstream
leverage (each tier reuses scaffolding from the previous):

1. **Tier A (foundations, S–M):**
   - `zig_import_cycles` (#2.9) — pure post-processing of existing graph; smallest delta.

2. **Tier B (per-symbol primitives, M):**
   - `zig_test_for_symbol` (#2.1) — reverse closure that the existing semantic index makes cheap.
   - `zig_test_fixture_inventory` (#2.5) — single AST pass.
   - `zig_module_surface` (#2.3) — directory aggregate over per-file calls.

3. **Tier C (composites, M):**
   - `zig_symbol_dossier` (#2.7) — pure composition once Tier B exists.
   - `zig_change_risk_audit` (#2.8) — multi-file composite over import graph, impact, tests, and public API signals.
   - `zig_insertion_sites` (#2.4) — uses semantic index, import neighborhoods, and sibling patterns.

4. **Tier D (deeper analysis, M–L):**
   - `zig_error_propagation` (#2.6) — parser-backed flow over call graph.
   - `zig_comptime_inspect` (#2.10) — ship heuristic mode first, compiler-eval mode later.

---

## 5. Cross-cutting notes

**Why these cluster as "agent ergonomics" rather than "static analysis".**
Each primitive is named for an *agent reasoning question*, not a Zig
language feature. `zig_unsafe_operations_audit` (proposed in 01) is a Zig
catalog. `zig_change_risk_audit` (proposed here) is a Reviewer's triage
order. The boundary is who phrases the question — Zig (existing static
analysis) or an agent role (these proposals).

**Why composites belong as MCP tools, not playbooks.** The two composite
proposals (#2.7 and #2.8) could be playbooks. They are not, because their
*output schema* is what makes them useful: a Reviewer prompt template needs
stable field names. A playbook that says "call A, then B, then merge as
follows" defers the merge to each caller — which means each caller invents
a different schema and downstream tools (Orchestrator workflow templates)
can't depend on the shape. Tools enforce the merge once.

**Read-only and apply-gate posture.** Every proposal here is read-only and
should be tagged `pure_analysis` in `src/manifest/`. None mutates files;
none writes artifacts unless explicitly opted in via a future `output`
parameter. This keeps them safe defaults in any Orchestrator's tool list.

**Confidence framing.** Each tool should report `evidence_basis`,
`confidence`, and `limitations` — the existing zigars contract. Where the
answer is heuristic (e.g. `zig_insertion_sites` ranking), the limitations
should name **what would make the answer stronger** (e.g. "could use
embeddings backend" or "could use compiler-eval"). This keeps the proposals
honest and gives Reviewers a clear cross-check path.

**Out of scope here and dropped.** Considered and intentionally not
proposed: a generic "ask the codebase X in natural language" primitive
(too vague to schema-bound); a per-PR "review summary" generator (this is
agent-side prompting, not a tool); a "symbol fuzz harness generator"
(overlaps with the existing fuzz tooling and crosses into code generation,
which AGENTS.md explicitly excludes from the server).
