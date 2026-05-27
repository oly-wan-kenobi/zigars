import assert from "node:assert/strict";
import test from "node:test";
import { hasTransport, normalizeZigarArgs } from "../src/args";

test("adds stdio transport when caller does not provide one", () => {
  assert.deepEqual(
    normalizeZigarArgs(["--workspace", "/tmp/example"]),
    ["--transport", "stdio", "--workspace", "/tmp/example"],
  );
});

test("preserves explicit transport flag and forwards args unchanged", () => {
  const args = ["--workspace", "/tmp/example", "--transport", "stdio", "--zig", "/opt/zig"];

  assert.equal(hasTransport(args), true);
  assert.deepEqual(normalizeZigarArgs(args), args);
});

test("preserves explicit transport assignment", () => {
  const args = ["--transport=stdio", "--workspace", "/tmp/example"];

  assert.equal(hasTransport(args), true);
  assert.deepEqual(normalizeZigarArgs(args), args);
});

test("rejects non-string argv values", () => {
  assert.throws(() => normalizeZigarArgs(["--workspace", 123]), {
    name: "TypeError",
  });
});
