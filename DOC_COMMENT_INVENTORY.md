# DOC_COMMENT_INVENTORY

Current inventory after the doc-header pass over `tools/**/*.zig`.

## Summary

- Scope: 49 Zig files under `tools/`.
- Missing attachable declaration doc headers: 0.
- Methods/functions missing attachable doc headers: 0.
- Structs missing attachable doc headers: 0.
- Enums missing attachable doc headers: 0.

## Local Declaration Exception

One original inventory entry cannot receive a `///` doc header without changing code shape:

| File | Declaration | Reason |
| --- | --- | --- |
| `tools/fuzz_test_runner.zig` | `const global = struct` inside `fuzz` | Zig rejects `///` before function-local declarations because they are statements, not container-level declarations. It now has an ordinary `//` explanatory comment instead. |

## Notes

- Headers were added as attached `///` comments immediately before every method, struct, and enum declaration from the original inventory where Zig permits declaration docs.
- No source behavior, identifiers, signatures, string literals, control flow, or generated artifacts were intentionally changed.
