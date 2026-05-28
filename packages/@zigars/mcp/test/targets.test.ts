import assert from "node:assert/strict";
import test from "node:test";
import { UnsupportedTargetError, resolveHostTarget } from "../src/targets";

const expectedTargets = [
  ["linux", "x64", "zigars-x86_64-linux-musl.tar.gz", "zigars"],
  ["linux", "arm64", "zigars-aarch64-linux-musl.tar.gz", "zigars"],
  ["darwin", "x64", "zigars-x86_64-macos.tar.gz", "zigars"],
  ["darwin", "arm64", "zigars-aarch64-macos.tar.gz", "zigars"],
  ["win32", "x64", "zigars-x86_64-windows-gnu.tar.gz", "zigars.exe"],
  ["win32", "arm64", "zigars-aarch64-windows-gnu.tar.gz", "zigars.exe"],
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

test("uses musl Linux archives as the host default when GNU archives also exist", () => {
  assert.equal(resolveHostTarget({ platform: "linux", arch: "x64" }).archiveName, "zigars-x86_64-linux-musl.tar.gz");
  assert.equal(resolveHostTarget({ platform: "linux", arch: "arm64" }).archiveName, "zigars-aarch64-linux-musl.tar.gz");
});

test("throws a typed error for unsupported targets", () => {
  assert.throws(() => resolveHostTarget({ platform: "freebsd", arch: "x64" }), (error) => {
    const targetError = error as UnsupportedTargetError;
    assert.equal(targetError instanceof UnsupportedTargetError, true);
    assert.equal(targetError.code, "ERR_ZIGARS_UNSUPPORTED_TARGET");
    assert.equal(targetError.platform, "freebsd");
    assert.equal(targetError.arch, "x64");
    assert.match(targetError.message, /freebsd\/x64/);
    return true;
  });
});
