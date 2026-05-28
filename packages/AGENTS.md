# Agent Instructions

These instructions apply to `packages/` and child directories.

## Scope

Package workspaces publish or package zigars distribution surfaces. They should
not change core server behavior except through the root Zig project and release
artifacts they consume.

## Local Rules

- Keep package metadata, README examples, release archive names, checksums, and
  `docs/distribution.md` aligned when distribution behavior changes.
- Keep Node.js 18+ compatibility unless the package contract explicitly
  changes.
- For `packages/@zigars/mcp/`, preserve npm, npx, Bun, Yarn dlx, and pnpm
  dlx launcher behavior; consult `.agents/roles/npm-shim-maintainer.md`.
- For `packages/@zigars/mcpb/`, treat ReleaseSafe archives as the packaged
  binary inputs and keep generated MCPB metadata consistent with package docs.
- For `packages/@zigars/skills/`, avoid install side effects and do not
  imply the skills package installs or configures the MCP server.
- Do not commit `node_modules/`, local package caches, generated release
  archives, or unpacked package artifacts unless explicitly tracked.

## Validation

Use the package-local scripts from the relevant `package.json`. For npm shim
changes, run:

```sh
cd packages/@zigars/mcp
npm run build
npm run test:node
bun run test:bun
```

For MCPB or skills-package changes, run the relevant package validation scripts
with `npm --prefix packages/<name> run ...` and report exactly which checks ran.
