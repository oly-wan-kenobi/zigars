# Bugfix Workflow

Use this workflow for focused defects where the desired behavior is already
clear from code, docs, fixtures, or issue context.

## Roles

- Role matching the affected area
- Security Sandbox Reviewer for path, write, command, or user-input defects
- QA Release for validation scope

## Steps

1. Reproduce the failure or identify the violated invariant.
2. Add the narrowest regression test first when practical.
3. Fix the defect in the lowest appropriate layer.
4. Avoid unrelated refactors and generated-file churn.
5. Run the focused test, then broaden validation based on blast radius.
6. Update docs or fixtures only when behavior or public contracts changed.

## Validation

Start with the affected test or build step. Common fallback:

```sh
zig build test
```

Add fuzz, smoke, docs, JSON, or release checks only when the fix touches those
contracts.

## Report

Include the bug, the fix location, the validation run, and any residual risk
from unavailable optional backends.
