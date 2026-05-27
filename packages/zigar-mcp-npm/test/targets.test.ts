import assert from "node:assert/strict";
import test from "node:test";
import { UnsupportedTargetError, resolveHostTarget } from "../src/targets";

const expectedTargets = [
  ["linux", "x64", "zigar-x86_64-linux-musl.tar.gz", "zigar"],
  ["linux", "arm64", "zigar-aarch64-linux-musl.tar.gz", "zigar"],
  ["darwin", "x64", "zigar-x86_64-macos.tar.gz", "zigar"],
  ["darwin", "arm64", "zigar-aarch64-macos.tar.gz", "zigar"],
  ["win32", "x64", "zigar-x86_64-windows.tar.gz", "zigar.exe"],
];

for (const [platform, arch, archiveName, executableName] of expectedTargets) {
  test(`maps ${platform}/${arch}`, () => {
    assert.deepEqual(resolveHostTarget({ platform, arch }), {
      platform,
      arch,
      archiveName,
      executableName,
    });
  });
}

test("throws a typed error for unsupported targets", () => {
  assert.throws(() => resolveHostTarget({ platform: "freebsd", arch: "x64" }), (error) => {
    const targetError = error as UnsupportedTargetError;
    assert.equal(targetError instanceof UnsupportedTargetError, true);
    assert.equal(targetError.code, "ERR_ZIGAR_UNSUPPORTED_TARGET");
    assert.equal(targetError.platform, "freebsd");
    assert.equal(targetError.arch, "x64");
    assert.match(targetError.message, /freebsd\/x64/);
    return true;
  });
});
