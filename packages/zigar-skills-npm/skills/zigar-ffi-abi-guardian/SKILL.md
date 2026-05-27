---
name: zigar-ffi-abi-guardian
description: Use when authoring or reviewing Zig C interop, extern or packed structs, ABI layout, memory layout, alignment, translate-c output, pointer/lifetime boundaries, serialization layouts, or cross-target binary compatibility assumptions.
---

# Zigar FFI ABI Guardian

## Purpose

Use this skill when Zig code crosses an ABI, FFI, serialization, or target layout
boundary. The goal is to collect layout evidence and avoid source-only ABI
assumptions.

## Workflow

1. Identify the boundary: C ABI, `extern`, `packed`, `callconv`, pointer
   ownership, allocator ownership, serialization format, target-specific layout,
   or translated C declarations.
2. Inspect the relevant declarations with `zig_public_api`, `zig_module_surface`,
   `zig_symbol_dossier`, `zig_memory_layout`, `zig_abi_layout_diff`, and
   `zig_unsafe_operations_audit` when available.
3. Check ownership and lifetime interactions with allocation, leak, and safety
   tools when pointers or buffers cross the boundary.
4. Compare targets with `zig_target_matrix_plan`, `zig_cross_smoke`,
   `zig_binary_size`, `zig_objdump_summary`, `zig_dwarfdump_check`, or
   `zig_symbolize` when binary evidence is needed.
5. Validate with compiler/test evidence on the relevant target and, when
   possible, a small boundary test that exercises the ABI contract.
6. Keep generated or translated files under generated/vendor policy; route edits
   through source inputs or regeneration commands.

## Claim Boundary

- Source text does not prove ABI compatibility.
- Native target evidence does not prove cross-target layout.
- `extern` or `packed` presence is not enough; report size, alignment, fields,
  target, and toolchain evidence.

## Finish

Report boundary type, layout evidence, target matrix, unsafe or ownership risks,
tests run, and remaining ABI uncertainty.
