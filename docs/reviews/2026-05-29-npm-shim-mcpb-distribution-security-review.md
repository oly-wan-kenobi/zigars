# Security Review — npm shim + MCPB distribution

- **Date:** 2026-05-29
- **Scope:** `packages/@zigars/mcp/` (download/verify/install/spawn), `packages/@zigars/mcpb/src/build.ts`, `packages/@zigars/skills/*`, and shipped `dist/` vs `src/` parity + manifests/lockfiles.
- **Method:** 4 parallel subagents with non-overlapping file scopes; every key claim independently re-verified against source (and, where decisive, empirically) before inclusion. Findings are marked **VERIFIED** (confirmed by reading source / running a test) or **INFERRED** (relied on subagent analysis not personally re-derived).
- **Invariants checked:** workspace sandbox; source-mutating tools require `apply=true`; stdout reserved for MCP JSON-RPC; structured MCP results; shipped tree is pure Zig (npm packages are JS/TS tooling).

## Headline

Both "known-open" issues from the review brief are **remediated** — confirmed in `src/` **and** in the shipped `dist/`. No Critical or High defects found in this surface. One subagent-reported **Medium was refuted** during re-verification (symlink-as-executable). Remaining items are Low / defense-in-depth plus test-coverage gaps.

### Brief's known issues — both now STALE / FIXED (VERIFIED in shipped artifact)

- **Non-constant-time checksum compare** (brief cited `checksums.ts:61`) → fixed. `checksums.ts:67` uses `crypto.timingSafeEqual` with a length guard; shipped at `dist/src/checksums.js:65`. Line 61 is now just `normalizeSha256Hex(expected)`. (Commit `0eb519c` "Use timing-safe checksum comparison".)
- **Cache-poisoning re-hash gap** (`verifyCachedExecutable` never re-hashed) → fixed and renamed. `install.ts:89-104` reads the executable bytes and re-hashes against `marker.sha256`; shipped at `dist/src/install.js:94`. The marker hash written at `install.ts:228` **is** read back at `:101`. (Commit `f4496cf` "Verify cached npm shim binaries".)

---

## Findings (ranked by severity)

### LOW-1 — Extraction trusts `tar`'s default protections; no in-process path/symlink validation, no negative test — VERIFIED

`packages/@zigars/mcp/src/install.ts:148-171` + `212-220`

```ts
const result = spawnSyncImpl("tar", ["-xzf", archivePath, "-C", destination], { shell: false, ... });
// ...later...
const extractedExecutable = await findExecutable(extractedDir, target.executableName, fsp);
await fsp.copyFile(extractedExecutable, stagedExecutable);
```

The classic tar write-through-symlink escape (member `d -> /abs`, then `d/x`) could write outside `extractedDir` *if* tar's defaults are bypassed (GNU tar blocks this; BSD tar on macOS also guards, but it is unverified here). **Heavily mitigated:** the archive SHA-256 is verified at `install.ts:199` **before** `mkdtemp`/extract at `:201`/`:210`, so an attacker must compromise the signed GitHub release (archive **and** checksum file) — at which point they could ship a malicious binary directly.

- **Impact:** marginal beyond "GitHub release compromised."
- **Fix:** after extraction, `lstat` the found executable and reject `isSymbolicLink()`, and assert `path.resolve(extractedExecutable).startsWith(path.resolve(extractedDir))`. Add a malicious-archive negative test.

### LOW-2 — Cache verify→exec TOCTOU (requires local cache-dir write access) — VERIFIED

`install.ts:101` hashes the bytes and returns a *path*; `cli.ts:82` later execs that path. A local attacker who can write the cache dir could swap the file in the window between hash and exec. Same trust boundary the re-hash already defends at rest; window is small.

- **Impact:** Low; requires local write access to the cache dir.
- **Fix (optional):** hash and exec via one fd, or document the cache-dir trust assumption. Limited value for a shim.

### LOW-3 — `releaseBaseUrl` interpolates `version`/`repository` unencoded (currently unreachable with untrusted input) — VERIFIED

`packages/@zigars/mcp/src/releases.ts:14-16`

```ts
const repository = options.repository ?? GITHUB_REPOSITORY;
return `https://github.com/${repository}/releases/download/${releaseTag(version)}`;
```

`assetName` is `encodeURIComponent`-escaped (`:23`), but `version` (→ tag) and `repository` are interpolated raw. Both are package-baked today (`version: packageJson.version` at `cli.ts:74`; `repository` never overridden by any caller). Host `https://github.com` is hard-pinned with no `http` fallback.

- **Impact:** defense-in-depth only; a future caller forwarding untrusted input could break out of the URL path.
- **Fix:** validate `version` against `/^[0-9A-Za-z.+-]+$/` in `releaseTag`; encode repository path segments.

### LOW-4 — `build.ts` `findTool` uses a shell string (static input only; build-time, private package) — VERIFIED

`packages/@zigars/mcpb/src/build.ts:181-187`

```ts
function findTool(names: string[]): string | null {
  for (const name of names) {
    const result = spawnSync("sh", ["-c", `command -v ${name}`], { encoding: "utf8" });
    if (result.status === 0) return result.stdout.trim();
```

`${name}` is interpolated into a shell command, but the only caller passes a static literal array (`build.ts:232`), and `@zigars/mcpb` is `private:true` and runs at release time. No runtime exposure.

- **Impact:** none today; a future refactor routing external data here becomes command injection.
- **Fix:** shell-free PATH probe (iterate `process.env.PATH` + `fs.existsSync`, or `spawnSync(name, ["--version"], { shell:false })`).

### INFO — dead `stdout` RunOptions field — VERIFIED

`packages/@zigars/mcp/src/cli.ts:46` declares `stdout?` but nothing ever writes to it; all diagnostics correctly go to `stderr` (`:58`, `:63`, `:89`, `:92`), keeping stdout clean for JSON-RPC. Cosmetic; remove the dead field. Keep the existing `stdout === ""` test assertion.

---

## Refuted during re-verification

The review brief required checking subagent claims against source.

**Subagent "F2: symlink-named-`zigars` copied by `copyFile` then chmod'd (Medium)" — REFUTED.** `findExecutable` gates on `entry.isFile()`, which is `lstat`-based for `readdir` Dirents. Confirmed empirically:

```
entry=realfile isFile=true  isSymlink=false isDir=false
entry=zigars   isFile=false isSymlink=true  isDir=false
findExecutable result: null
```

A symlink entry is skipped → `install.ts:213` throws `ERR_ZIGARS_ARCHIVE_CONTENTS` → `copyFile` at `:220` is never reached. The genuine residual is the narrower tar write-through escape (LOW-1), not this mechanism.

---

## Verified-safe areas (independently confirmed against source)

- **Constant-time compare** in shipped artifact — `checksums.ts:67` + `dist/src/checksums.js:65` (`timingSafeEqual` + length guard).
- **Cache re-hash fail-closed** — `verifiedCachedExecutable` returns `null` on any mismatch → full re-download (`install.ts:89-108`); present in `dist/src/install.js:80-96`.
- **Download checksum precedes extraction** — verify `:199` < mkdtemp `:201` < extract `:210`; dist order preserved (verify `:179` < mkdtemp `:180` < extract `:188`).
- **Checksum parsing anchored/fail-closed** — exact 64-hex regex (`checksums.ts:32`), exact-key lookup (`:45`); parse / missing / mismatch all throw (`ERR_ZIGARS_CHECKSUM_PARSE` / `_MISSING` / `_MISMATCH`).
- **Atomic install** — mkdtemp → stage → marker → `rename` (`install.ts:201-233`); `installDir` only ever holds a fully-verified binary + marker.
- **Single scoped chmod 0o755** on the one binary (`install.ts:221-222`); no recursive / 0o777. Temp cleanup in `finally` (`:235-236`).
- **Spawn** — `shell:false`, argv array, verified executable path (`cli.ts:82-85` + `dist/src/cli.js:100`); child inherits `process.env` (no override); `options.env` only reaches install for cache-dir relocation, which does **not** skip verification.
- **Unknown target fails closed** — frozen 6-entry table, no default branch (`targets.ts:72-75`).
- **HTTPS host-pinned, no http fallback** (`releases.ts:16`); asset name `encodeURIComponent` (`:23`).
- **No install lifecycle scripts** (postinstall/preinstall/prepare) in any `package.json`; `@zigars/mcpb` is `private:true`; devDeps pinned in lockfiles. *(INFERRED — relied on subagent lockfile diff.)*
- **skills bin** — name validated `^[a-z0-9-]+$` before `path.join` (`packages/@zigars/skills/bin/zigars-skills.js:55`); no network / shell.
- **dist/src parity** — security-critical logic of all 6 mcp modules present in shipped JS (spot-verified `checksums`, `install`, `cli`, `releases`, `targets`). Broader byte-faithful-emit claim is **INFERRED** from subagent analysis.

---

## Test-coverage gaps (negative tests)

**Present:** checksum mismatch / parse-error / missing-entry / invalid-hash (`test/checksums.test.ts:22-56`); checksum-mismatch-before-extraction and cache marker mismatch/missing (`test/install.test.ts`); unknown-platform throws (`test/targets.test.ts:30`, `test/cli.test.ts:63`); non-string args (`test/args.test.ts:26`); spawn argv + `shell:false` and empty-stdout (`test/cli.test.ts:53-60`).

**Missing (ranked by value):**

1. **Malicious tar entry** (symlink / `../` / absolute path) — none. Highest-value gap; directly covers LOW-1. Stub `spawnSync` to write a symlink or `../escape` into `extractedDir` and assert install rejects / does not write outside.
2. **Cache byte-tamper with a valid marker** — mutate the binary after writing a correct `marker.sha256`, assert the re-hash catches it → re-download.
3. **Unknown *arch* on a known platform** (e.g. `linux/riscv64`) — only unknown *platform* is tested.
4. **Non-HTTPS / host-injection URL hardening** — none (covers LOW-3).
5. **`sha256Equals` length-mismatch / constant-time path** — none.
6. **Duplicate filename in checksum file** (last-wins at `checksums.ts:39`) — none.
7. **Partial / interrupted rename** — none.

---

## Bottom line

This distribution surface is in good shape. The two vulnerabilities flagged in the brief are fixed in the published artifact; the download / cache / spawn paths fail closed; spawn is injection-safe; unknown targets fail closed. The highest-priority remaining work is a **malicious-archive negative test** (LOW-1) plus the small LOW hardening items above.
