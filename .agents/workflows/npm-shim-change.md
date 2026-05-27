# npm Shim Change Workflow

Use this workflow for changes to `packages/zigar-mcp-npm/` or npm launcher
behavior documented from the root project.

## Roles

- npm Shim Maintainer
- Docs Maintainer when README or package docs change
- QA Release for validation scope
- Security Sandbox Reviewer when downloads, paths, extraction, cache, or process
  execution changes

## Steps

1. Identify whether the change affects CLI args, host detection, archive
   download, checksum verification, cache behavior, package contents, or docs.
2. Keep Bun and Node launcher paths compatible with documented usage.
3. Preserve explicit errors for unsupported platforms, missing release assets,
   download failures, and checksum mismatches.
4. Update TypeScript tests and expected compiled-package behavior.
5. Update package README and root README examples if invocation changes.
6. Confirm package file lists include required runtime files and exclude local
   development artifacts.

## Validation

```sh
cd packages/zigar-mcp-npm
npm run build
npm run test:node
bun run test:bun
```

Run root-level checks only when root docs, release tooling, or archive metadata
also changed.
