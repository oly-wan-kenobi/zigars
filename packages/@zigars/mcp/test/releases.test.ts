import assert from "node:assert/strict";
import test from "node:test";
import { checksumUrl, releaseAssetUrl, releaseBaseUrl, releaseTag } from "../src/releases";

test("builds release tag from npm package version", () => {
  assert.equal(releaseTag("0.2.0"), "v0.2.0");
});

test("builds GitHub release URLs", () => {
  assert.equal(
    releaseBaseUrl("0.2.0"),
    "https://github.com/oly-wan-kenobi/zigars/releases/download/v0.2.0",
  );
  assert.equal(
    releaseAssetUrl("0.2.0", "zigars-x86_64-linux-musl.tar.gz"),
    "https://github.com/oly-wan-kenobi/zigars/releases/download/v0.2.0/zigars-x86_64-linux-musl.tar.gz",
  );
  assert.equal(
    checksumUrl("0.2.0"),
    "https://github.com/oly-wan-kenobi/zigars/releases/download/v0.2.0/zigars-checksums.txt",
  );
});

test("rejects versions that contain URL-significant characters", () => {
  for (const bad of ["1.0.0/../../evil", "1.0 0", "1.0.0?", "1.0.0#frag", "1.0.0@host", "../etc", ""]) {
    assert.throws(() => releaseTag(bad), { name: "TypeError" });
    assert.throws(() => releaseAssetUrl(bad, "zigars-checksums.txt"), { name: "TypeError" });
  }
});

test("accepts conventional semver-ish versions, including pre-release and build metadata", () => {
  assert.equal(releaseTag("1.2.3-rc.1+build.5"), "v1.2.3-rc.1+build.5");
});

test("encodes repository path segments and keeps the host pinned to github.com", () => {
  // The scheme+host prefix is a fixed literal, so a repository override can never
  // change the authority; it can only ever land under https://github.com/.
  const traversal = releaseAssetUrl("0.2.0", "zigars-checksums.txt", {
    repository: "owner/../../evil.com/repo",
  });
  assert.ok(traversal.startsWith("https://github.com/"), `expected github.com host, got ${traversal}`);

  // Authority/query/fragment-injecting characters are percent-encoded per segment so a
  // future caller forwarding untrusted input cannot smuggle in a new host, query, or fragment.
  assert.equal(
    releaseBaseUrl("0.2.0", { repository: "evil@host/x?y#z" }),
    "https://github.com/evil%40host/x%3Fy%23z/releases/download/v0.2.0",
  );
  assert.equal(
    releaseBaseUrl("0.2.0", { repository: "a b/c-d" }),
    "https://github.com/a%20b/c-d/releases/download/v0.2.0",
  );
});

test("rejects an empty repository override", () => {
  assert.throws(() => releaseBaseUrl("0.2.0", { repository: "" }), { name: "TypeError" });
});
