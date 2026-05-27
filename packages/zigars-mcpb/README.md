# zigars MCPB release package

This package stages and packs release-grade MCPB artifacts for Claude Desktop.
It consumes the ReleaseSafe archives produced by `zig build dist` and writes
`.mcpb` bundles under `dist/assets`.

The current MCPB CLI package on npm is `@anthropic-ai/mcpb`; `mcpb` and
`@modelcontextprotocol/mcpb` are not published package names at the time this
tooling was added. The TypeScript build script shells through npm or Bun to run
`@anthropic-ai/mcpb@2.1.2`, so maintainers do not need a global MCPB CLI
install.

## Artifact strategy

The release ships true binary MCPB bundles, not a Node dispatcher. MCPB platform
compatibility currently supports OS selectors (`darwin`, `win32`, `linux`) and
does not expose CPU architecture selectors, so the bundle filenames carry the
architecture policy:

| Artifact | Bundled server | Manifest platform |
|---|---|---|
| `zigars-darwin-universal.mcpb` | macOS universal `zigars` built from x86_64 and aarch64 release archives | `darwin` |
| `zigars-linux-x64.mcpb` | `zigars-x86_64-linux-musl` | `linux` |
| `zigars-windows-x64.mcpb` | `zigars-x86_64-windows-gnu` | `win32` |

Linux arm64 and Windows arm64 users should use the npm shim or the direct
release archive until MCPB consumers have an arch-selectable package flow or
those bundles are separately smoke-tested.

## Commands

From the repository root:

```sh
zig build dist
npm --prefix packages/zigars-mcpb ci
npm --prefix packages/zigars-mcpb run pack
```

The npm/Node path compiles `src/build.ts` to `dist/build.js` before running.
Bun can run the same TypeScript source directly:

```sh
bun --cwd packages/zigars-mcpb install
bun run --cwd packages/zigars-mcpb pack:bun
```

Useful variants:

```sh
npm --prefix packages/zigars-mcpb run stage
npm --prefix packages/zigars-mcpb run validate
npm --prefix packages/zigars-mcpb run build:darwin
npm --prefix packages/zigars-mcpb run build:linux
npm --prefix packages/zigars-mcpb run build:windows
npm --prefix packages/zigars-mcpb run sign:dev
bun run --cwd packages/zigars-mcpb validate:bun
bun run --cwd packages/zigars-mcpb build:darwin:bun
```

The scripts validate manifests with `mcpb validate`, pack with `mcpb pack`,
inspect with `mcpb info`, and write SHA-256 hashes to
`dist/assets/zigars-mcpb-checksums.txt`.

For registry metadata, use the hash of the final published `.mcpb` file. If a
bundle is signed after packing, recompute and publish the hash of the signed
file.
