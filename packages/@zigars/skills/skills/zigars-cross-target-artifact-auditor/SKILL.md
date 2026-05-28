---
name: zigars-cross-target-artifact-auditor
description: Use when inspecting Zig binary artifacts, binary size changes, symbols, DWARF/debug info, objdump summaries, address symbolization, QEMU smoke tests, target runtime plans, or native-vs-cross-target behavior differences.
---

# Zigars Cross Target Artifact Auditor

## Purpose

Use this skill when the final artifact matters: binary size, symbols, debug info,
target behavior, QEMU smoke evidence, or release artifact identity.

## Workflow

1. Record artifact identity: path, size, hash, target triple, optimize mode,
   toolchain, build command, baseline artifact, and intended runtime environment.
2. Inspect static artifact evidence with `zig_binary_size` and
   `zig_binary_size_diff`.
3. Preview backend-backed artifact inspection with `zig_objdump_summary`,
   `zig_dwarfdump_check`, and `zig_symbolize`. Execute only through zigars'
   apply-gated backend path when required.
4. For runtime target behavior, plan with `zig_target_runtime_plan` and
   `zig_cross_smoke`; use `zig_qemu_test` only as preview-first or apply-gated
   execution.
5. For embedded or hardware-facing targets, hand off to a dedicated embedded
   workflow before any flash or board assumption.
6. Link binary evidence back to release or performance claims only when the
   artifact identity and producing command are known.

## Claim Boundary

- Native runtime success does not prove cross-target runtime success.
- QEMU evidence is not hardware evidence.
- Static binary inspection does not prove behavior; it supports artifact claims.

## Finish

Report artifact identity, baseline comparison, target evidence, backend status,
runtime smoke result, and claims still unsupported.
