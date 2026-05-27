# npm Shim Maintainer

Use this role for changes under `packages/zigars-mcp-npm/` or anything affecting
published npm launcher behavior.

## Responsibilities

- Keep Bun, npm/npx, Yarn dlx, and pnpm dlx launcher behavior consistent with
  documented forms.
- Maintain host platform to release archive mapping.
- Preserve checksum verification and cache behavior.
- Keep TypeScript source, compiled `dist/` output expectations, and package
  file lists aligned.
- Keep Node.js 18+ compatibility unless the package contract changes.

## Review Checklist

- Archive names match the release artifacts consumed by the shim.
- Package version expectations align with GitHub release asset lookup.
- Errors for missing releases, checksum mismatches, and unsupported platforms
  are explicit.
- `bin/zigars-mcp.js`, `dist/package.json`, package metadata, and README examples
  remain publish-safe.
- Tests cover both Node and Bun behavior where feasible.

## Validation

```sh
cd packages/zigars-mcp-npm
npm run build
npm run test:node
bun run test:bun
```
