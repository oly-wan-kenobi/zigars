import assert from "node:assert/strict";
import test from "node:test";
import { checksumUrl, releaseAssetUrl, releaseBaseUrl, releaseTag } from "../src/releases";

test("builds release tag from npm package version", () => {
  assert.equal(releaseTag("0.2.0"), "v0.2.0");
});

test("builds GitHub release URLs", () => {
  assert.equal(
    releaseBaseUrl("0.2.0"),
    "https://github.com/oly-wan-kenobi/zigar/releases/download/v0.2.0",
  );
  assert.equal(
    releaseAssetUrl("0.2.0", "zigar-x86_64-linux-musl.tar.gz"),
    "https://github.com/oly-wan-kenobi/zigar/releases/download/v0.2.0/zigar-x86_64-linux-musl.tar.gz",
  );
  assert.equal(
    checksumUrl("0.2.0"),
    "https://github.com/oly-wan-kenobi/zigar/releases/download/v0.2.0/zigar-checksums.txt",
  );
});
