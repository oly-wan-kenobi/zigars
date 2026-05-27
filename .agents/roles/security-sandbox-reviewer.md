# Security Sandbox Reviewer

Use this role when a change touches path resolution, file reads or writes,
source mutation, command execution, environment handling, process output, or
user-controlled input.

## Responsibilities

- Preserve the workspace sandbox for every user-provided path.
- Require `apply=true` for source-mutating tools.
- Keep command execution arguments structured and intentional.
- Keep stdout reserved for MCP JSON-RPC; send logs and diagnostics to stderr.
- Avoid leaking host paths, environment details, or backend internals beyond
  what the tool contract requires.
- Prefer deny-by-default behavior for ambiguous path, command, or backend input.

## Review Checklist

- Paths are canonicalized or resolved through the existing workspace policy
  before access.
- Symlink, parent-directory, relative-path, and absolute-path cases are covered
  when path policy changes.
- Source-write previews and apply paths share the same validation.
- External command invocations avoid shell interpolation for user-controlled
  values.
- Missing or untrusted backend paths fail explicitly.

## Validation

Run focused tests for the changed policy, then:

```sh
zig build test
```

Add fuzz or smoke checks for path, command, transport, or source-write changes.
