# S15 — npm shim defense-in-depth + negative tests (Wave 3)

> **Cold-start session.** This is the `@zigars/mcp` npm shim (download/verify/install/spawn of the
> prebuilt server binary) + the private `@zigars/mcpb` build tool — **TypeScript/Node/Bun**, not Zig.
> The two real vulnerabilities from the brief (cache-poisoning re-hash, non-constant-time compare) are
> **already fixed in `src/` and shipped `dist/`**; what remains is defense-in-depth + the highest-value
> missing negative test. Keep `stdout` clean (JSON-RPC); diagnostics → `stderr`.
> **Rules:** verify first · stay within *Files in scope* · add the negative tests · branch
> `git switch -c fix/npm-shim-hardening` · validate and report.

**Review:** `docs/reviews/2026-05-29-npm-shim-mcpb-distribution-security-review.md` —
LOW-1, LOW-2, LOW-3, LOW-4, INFO. (LOW-3/LOW-4 were codex-disputed and adjudicated **defense-in-depth,
not current defects** — implement as hardening, low priority.)

## Files in scope (only these)

- `packages/@zigars/mcp/src/{install.ts,releases.ts,cli.ts}`
- `packages/@zigars/mcpb/src/build.ts`
- `packages/@zigars/mcp/test/**`

## Findings

1. **[LOW-1 — highest value] Extraction trusts `tar` defaults; no in-process validation, no negative
   test** (`install.ts` ~148-171, ~212-220). The SHA-256 is verified *before* extract, so an attacker
   must compromise the signed GitHub release — marginal. But add the cheap belt: after extraction,
   `lstat` the found executable and reject `isSymbolicLink()`, and assert
   `path.resolve(extractedExecutable).startsWith(path.resolve(extractedDir))`. **Add the
   malicious-archive negative test** (stub `spawnSync` to drop a symlink / `../escape` into
   `extractedDir`; assert install rejects and writes nothing outside) — this is the #1 missing test.

2. **[LOW-2] Cache verify→exec TOCTOU** (`install.ts` ~101 hashes bytes and returns a path;
   `cli.ts` ~82 execs it later). Requires local cache-dir write access; window is small and the
   at-rest re-hash already defends. **Fix (optional):** hash+exec via one fd, or document the
   cache-dir trust assumption. Also add a **cache byte-tamper test** (mutate the binary after writing
   a correct `marker.sha256`, assert the re-hash forces re-download).

3. **[LOW-3 — defense-in-depth] `releaseBaseUrl` interpolates `version`/`repository` unencoded**
   (`releases.ts` ~14-16). Both are package-baked today (no untrusted override), host is hard-pinned
   `https://github.com`. **Fix:** validate `version` against `/^[0-9A-Za-z.+-]+$/` in `releaseTag`
   and encode repository path segments — so a future caller forwarding untrusted input can't break out
   of the URL path.

4. **[LOW-4 — defense-in-depth] `build.ts findTool` uses a shell string** (`@zigars/mcpb`
   `build.ts` ~181-187: `spawnSync("sh", ["-c", \`command -v ${name}\`])`). Static literal input,
   `private:true`, release-time only — no runtime exposure. **Fix:** shell-free PATH probe (iterate
   `process.env.PATH` + `fs.existsSync`, or `spawnSync(name, ["--version"], { shell:false })`).

5. **[INFO] Dead `stdout?` field in `RunOptions`** (`cli.ts` ~46) — declared, never written; all
   diagnostics correctly go to `stderr`. **Fix:** remove the dead field; keep the existing
   `stdout === ""` test assertion.

## Acceptance

- New negative tests: malicious tar entry (symlink / `../` / absolute) rejected; cache byte-tamper
  caught → re-download; (optional) unknown *arch* on a known platform, non-HTTPS/host-injection URL
  hardening.
- From `packages/@zigars/mcp`: `npm run build` · `npm run test:node` · `bun run test:bun` green.
  For `@zigars/mcpb`: `npm --prefix packages/@zigars/mcpb ci && npm --prefix packages/@zigars/mcpb run pack`.
  Rebuild `dist/` if you changed shipped logic and the repo tracks it. Report commands run.
