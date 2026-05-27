# Backend Integration Workflow

Use this workflow when changing ZLS, ZLint, zwanzig, zflame, diff-folded,
profiler, debugger, emulator, fuzz, memory, binary, or other optional backend
behavior.

## Roles

- Zig Domain Engineer
- Tool Engineer when MCP output or schemas change
- Security Sandbox Reviewer when backend paths or commands are accepted
- Docs Maintainer for setup and limitation updates
- QA Release for fake and real backend evidence

## Steps

1. Confirm whether the backend is optional or required for the changed tool.
2. Keep missing-backend errors explicit and actionable.
3. Keep command execution apply-gated when the backend runs user code or captures
   evidence.
4. Normalize backend output into structured domain results before MCP projection.
5. Preserve confidence, limitations, verification, artifact hashes, and source
   metadata where the surrounding contract expects them.
6. Update backend catalog, docs, and fixtures when setup or output changes.
7. Separate fake-backend contract evidence from real-backend release claims.

## Validation

```sh
zig build test
zig build backend-contract-scenarios
```

Add representative real-backend smoke checks when the backend is locally
available. For release-facing claims, use the release readiness evidence path.
