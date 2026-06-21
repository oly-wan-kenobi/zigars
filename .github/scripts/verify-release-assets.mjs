#!/usr/bin/env node
// Verify that a published GitHub release contains every asset the @zigars/mcp
// shim will request for every supported host target, and that each archive
// matches its entry in zigars-checksums.txt. This gates `npm publish` so the
// package version never becomes installable before its download targets exist.
//
// Usage:
//   node .github/scripts/verify-release-assets.mjs <version>   # full network verify
//   node .github/scripts/verify-release-assets.mjs <version> --list   # print targets, no network
//
// <version> defaults to ${TAG} or ${GITHUB_REF_NAME} (a leading "v" is stripped).
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const distDir = path.resolve(here, "../../packages/@zigars/mcp/dist/src");
const require = createRequire(import.meta.url);
const { TARGETS } = require(path.join(distDir, "targets.js"));
const { releaseAssetUrl, checksumUrl, releaseTag } = require(path.join(distDir, "releases.js"));
const { parseChecksums, checksumForArchive, verifySha256 } = require(path.join(distDir, "checksums.js"));

function resolveVersion(argv) {
  const positional = argv.find((a) => !a.startsWith("--"));
  const raw = positional ?? process.env.TAG ?? process.env.GITHUB_REF_NAME ?? "";
  const version = raw.replace(/^v/, "").trim();
  if (!version) {
    throw new Error("no version provided (pass an argument or set TAG/GITHUB_REF_NAME)");
  }
  return version;
}

// The unique archive names the shim resolves across all supported host targets.
function expectedArchives() {
  return [...new Set(Object.values(TARGETS).map((t) => t.archiveName))].sort();
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Release-asset CDN propagation can briefly lag a fresh upload, so retry a few
// times with backoff before treating a 404/network error as a real failure.
async function fetchBuffer(url, { attempts = 5 } = {}) {
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const res = await fetch(url, { redirect: "follow" });
      if (!res.ok) {
        throw new Error(`GET ${url} -> HTTP ${res.status}`);
      }
      return Buffer.from(await res.arrayBuffer());
    } catch (err) {
      lastError = err;
      if (attempt < attempts) {
        await sleep(2000 * attempt);
      }
    }
  }
  throw lastError;
}

async function main() {
  const argv = process.argv.slice(2);
  const listOnly = argv.includes("--list");
  const version = resolveVersion(argv);
  const archives = expectedArchives();

  if (listOnly) {
    console.log(`release ${releaseTag(version)} expects ${archives.length} archives:`);
    console.log(`  ${checksumUrl(version)}`);
    for (const name of archives) {
      console.log(`  ${releaseAssetUrl(version, name)}`);
    }
    return;
  }

  console.log(`Verifying release ${releaseTag(version)} assets for ${archives.length} host targets...`);
  const checksumText = (await fetchBuffer(checksumUrl(version))).toString("utf8");
  const checksums = parseChecksums(checksumText);

  const failures = [];
  for (const name of archives) {
    try {
      const expected = checksumForArchive(checksums, name);
      const buffer = await fetchBuffer(releaseAssetUrl(version, name));
      verifySha256(buffer, expected, name);
      console.log(`  ok ${name} (${buffer.length} bytes, sha256 verified)`);
    } catch (err) {
      failures.push(`${name}: ${err.message}`);
      console.error(`  FAIL ${name}: ${err.message}`);
    }
  }

  if (failures.length > 0) {
    console.error(`::error::release ${releaseTag(version)} is missing or corrupt assets:`);
    for (const f of failures) {
      console.error(`::error::  ${f}`);
    }
    process.exit(1);
  }
  console.log(`All ${archives.length} release assets present and checksum-verified.`);
}

main().catch((err) => {
  console.error(`::error::release asset verification failed: ${err.message}`);
  process.exit(1);
});
