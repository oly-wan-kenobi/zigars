# Workflow: Parallel Docs & Comments Campaign (`src/` + `tools/`)

Paste everything below the line into a **fresh Claude Code session at the repo
root** to run an orchestrator that fans doc/comment improvement out across many
subagents. The orchestrator plans, partitions, spawns subagents on disjoint file
sets, then verifies the whole tree once.

---

## Mission

Improve **doc comments (`//!`, `///`) and inline comments (`//`)** across every
Zig file in `src/` and `tools/`. This is a **comments-and-docs-only** campaign:
you add and sharpen comments, you do **not** change code, behavior, identifiers,
signatures, string literals, control flow, or `zig fmt` layout of code.

Scope is the **Zig source** under `src/` and `tools/` only. Markdown under
`docs/`, the README, and generated files (e.g. `docs/tool-index.generated.md`,
`src/manifest/tool_catalog.json`) are **out of scope** — they are owned by the
docs-maintainer workflow and the generators.

Target: ~433 files (384 in `src/`, 49 in `tools/`); ~313 currently lack a `//!`
module doc.

## Why the line budget will not fight you

The repo's line-count guard (`zig build artifact-hygiene`) was changed so it
counts **source lines of code only** — blank lines and whole-line comments
(`//`, `///`, `//!`) are excluded by `codeLineCount` in
`tools/release/release_checks.zig` (see the policy note atop
`tools/release/release_rules.zig`). So adding documentation **never** consumes a
file's line budget. That change may be sitting **uncommitted in the working
tree**; if so, commit it as the **first commit** on the campaign branch before
anything else, otherwise the campaign branch would validate against the old
metric.

## Orchestrator pre-flight (do this yourself, before spawning anyone)

1. Verify the tree state. Create and switch to a branch, e.g.
   `docs/comments-campaign`. If the `codeLineCount` guard change is uncommitted,
   commit it first (`refactor(release-gate): count code lines only, excluding comments/docs`).
2. Read `AGENTS.md`, `.agents/README.md`, and skim the role playbooks under
   `.agents/roles/` so subagent instructions carry the right lens per subsystem
   (e.g. `security-sandbox-reviewer` for `src/infra/workspace/`,
   `zig-domain-engineer` for `src/domain/`, `tool-engineer` for
   `src/manifest/` and `src/adapters/mcp/tools/`, `qa-release` for
   `tools/release/` and `tools/integration/`).
3. Enumerate the work: `find src tools -name '*.zig' | sort`.
4. Confirm the two cheap per-file validators work: `zig fmt <file>` and
   `zig ast-check <file>`.

## Partition (disjoint sets, by subsystem)

Assign **one subagent per batch**, with **non-overlapping file sets** — no two
subagents may touch the same file. Group by coherent subsystem so each subagent
builds real context. Keep batches to **~8–20 files**; split large subsystems
across several subagents and run in waves (≈8–12 concurrent subagents per wave).

Approximate sizes to plan around (run `find` to get exact lists):

| Batch source | Files | Suggested subagents |
|---|---|---|
| `src/app/usecases/**` | 89 | 4–6 (split by sub-area, e.g. static_analysis, performance, profiling, editing, diagnostics, …) |
| `src/manifest/definitions/**` | 41 | 2–3 |
| `src/adapters/mcp/**` | 41 | 2–3 (tools/, server/, top-level) |
| `src/infra/zls/**` | 25 | 1–2 |
| `src/testing/mcp/**` | 24 | 1–2 |
| `tools/integration/**` | 23 | 1–2 (http/, stdio/, common/) |
| `src/manifest/*` (top level) | 21 | 1–2 |
| `src/testing/fakes/**` | 16 | 1 |
| `tools/release/**` | 14 | 1 (⚠ token-gated files — see trap below) |
| `src/domain/**` | ~36 across subdirs | 2–3 |
| `src/infra/*` (observability, backends, workspace, process, runtime_ux, artifacts, release, clock, toolchain) | ~50 | 3–4 |
| `src/bootstrap/*`, `src/app/*` top level | 24 | 1–2 |
| `tools/coverage,quality,common` + `src/adapters/cli`, `src/root.zig`, `src/main.zig` | ~12 | 1 |

Spawn each subagent with the **subagent task template** below, filling in its
exact file list and role lens. Only the **orchestrator** runs git and full
builds; subagents only edit files and run the two per-file validators.

## Subagent task template (copy into each `Agent` call)

> **Task: improve doc & inline comments for these files (comments only — no code changes).**
>
> Files you own (edit ONLY these; do not touch any other file):
> `<explicit list>`
> Lens: `<role>` — read `.agents/roles/<role>.md` and `AGENTS.md` first.
>
> **What to add / improve, per file:**
> - **`//!` module doc** at the very top of every file that lacks one: 1–4 lines
>   stating the module's single responsibility and any key invariant or contract
>   (e.g. "stdout is reserved for JSON-RPC", "all paths resolved under the
>   workspace sandbox"). Match the terse house voice in existing `//!` headers.
> - **`///` doc comment** on every `pub` declaration (and important private
>   ones): say the intent, the meaning of non-obvious parameters, return/error
>   semantics, ownership/allocation contract (who frees what), units, and
>   invariants. Don't restate the signature.
> - **`//` inline comments** on non-obvious logic only: explain **why**, edge
>   cases, security/trust reasoning, protocol quirks, and surprising decisions.
> - **Fix** existing comments that are stale, wrong, or misleading (read the code
>   and correct them). **Sharpen** vague ones. Do **not** churn comments that are
>   already good.
>
> **Hard Zig rules (breaking these breaks the build):**
> - `///` MUST immediately precede a declaration. A `///` before a statement or
>   inside a function body is a **compile error** ("expected statement, found 'a
>   document comment'"). For commentary inside function bodies use `//`.
> - `//!` goes only at the very top of the file, before any declaration; one
>   block per file.
> - **Comments only.** Do not modify code, identifiers, signatures, string
>   literals, imports, or the formatting of code lines. Add comment lines (and
>   fix existing comment text) — nothing else.
>
> **House style:** terse, intent-focused, explain *why* not *what*, no marketing
> language, match neighboring files. Don't comment self-evident lines. Quality
> over coverage — a precise `//!` plus `///` on the public surface beats noise on
> every line.
>
> **Gated-file token trap (critical):** the release gates substring-match the
> **whole file, including comments**. Open `tools/release/release_rules.zig` and
> check whether any file you own appears in `forbidden_tokens`,
> `code_hygiene_tokens`, `ignored_error_hygiene_tokens`, or any
> `*_error_contract_*` table. If so, your comments must **not** contain those
> banned literal substrings (e.g. the std debug-print call, `errorText`,
> `return error.Invalid…`, `catch {};`, `mcp.tools.errorResult`,
> `return error.Unknown`, `try splitToolArgs(`). Describe the concept in prose
> instead of pasting the literal token.
>
> **Validate each file you touch (do NOT run `zig build` — it contends on the
> shared `.zig-cache`; the orchestrator builds once at the end):**
> - `zig fmt <file>` (must succeed and be idempotent)
> - `zig ast-check <file>` (must exit 0 — this catches unattached `///` per file,
>   without a full compile or cache lock)
>
> **Report back (structured):** files touched; count of `//!` / `///` / `//`
> added; files you intentionally left unchanged (already well-documented) and
> why; anything you were unsure about or that needs human judgment; and
> confirmation that `zig fmt` + `zig ast-check` pass for every file you touched.

## Orchestrator finalization (after each wave / at the end)

1. `zig fmt build.zig build.zig.zon src tools` — confirm idempotent/clean.
2. `zig build test` — full unit suite must stay green. (Note: several
   negative-path tests print diagnostics like "dist expected 8 release packages,
   got 7" and "failed command: …" to stderr — that output is expected; trust the
   process **exit code**, not the presence of those lines.)
3. `zig build artifact-hygiene` — line budgets (code-only now) + all token gates
   must pass. A token-gate failure here means a comment pasted a banned literal —
   fix the comment wording.
4. `zig build docs-check json-check` — cheap drift check.
5. `zig build release-check` — full local gate before declaring done.
6. Commit per subsystem or per wave with clear messages
   (`docs(comments): document src/infra/zls modules`, …). Summarize the
   validation you ran. **Do not push or open a PR unless the user asks.**

## Definition of done

- Every `src/`+`tools/` Zig file has a `//!` module doc; the public surface
  (`pub` decls) is documented; non-obvious logic has *why* comments.
- No code/behavior change anywhere (diff is comments-only).
- `zig build release-check` passes.

## Anti-goals

- No code edits, renames, refactors, or `zig fmt` reflows of code.
- No `///` floating outside a declaration.
- No banned token literals in comments of gated files.
- No parallel `zig build`/`zig build test` from subagents (cache contention).
- No two subagents editing the same file.
- No edits to generated files or to markdown docs (separate workflow).
