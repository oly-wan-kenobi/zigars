# Release Readiness Workflow

Use this workflow before tagging, publishing archives, publishing the npm
package, or making public release-readiness claims.

## Roles

- QA Release
- Docs Maintainer
- npm Shim Maintainer when npm package behavior or versioning is involved
- Security Sandbox Reviewer for command, write, or backend execution changes

## Steps

1. Confirm the intended version across `build.zig.zon`, release docs, changelog,
   README examples, and npm package metadata.
2. Explain the tree state before release checks; release evidence should come
   from a clean tree unless generated artifacts are intentionally present.
3. Run generated docs and JSON checks.
4. Run unit, fuzz, smoke, fixture, coverage, artifact hygiene, architecture,
   public contract, and backend contract gates through `release-check`.
5. Verify release archive names, checksum generation, and npm shim lookup
   expectations.
6. Run npm shim validation if package contents are part of the release.
7. Record exact commands, backend versions, skipped checks, and limitations.

## Validation

```sh
zig build release-check
```

For npm package readiness:

```sh
cd packages/zigars-mcp-npm
npm run build
npm run test:node
bun run test:bun
```

Do not make clean A or real-backend coverage claims without evidence for the
exact commit being released.
