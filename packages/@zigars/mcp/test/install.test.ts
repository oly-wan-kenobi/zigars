import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { sha256 } from "../src/checksums";
import { assertContainedRegularFile, installZigars, isContainedWithin, verifiedCachedExecutable } from "../src/install";
import { resolveHostTarget } from "../src/targets";

const target = resolveHostTarget({ platform: "linux", arch: "x64" });

function response(body: string | Buffer, options: { ok?: boolean; status?: number } = {}) {
  const buffer = Buffer.isBuffer(body) ? body : Buffer.from(body);
  return {
    ok: options.ok ?? true,
    status: options.status ?? 200,
    async text() {
      return buffer.toString("utf8");
    },
    async arrayBuffer() {
      return buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
    },
  };
}

async function withTempDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
  const dir = await fs.promises.mkdtemp(path.join(os.tmpdir(), "zigars-mcp-test-"));
  try {
    return await fn(dir);
  } finally {
    await fs.promises.rm(dir, { recursive: true, force: true });
  }
}

test("reuses verified cached executable without downloading", async () => {
  await withTempDir(async (cacheRoot) => {
    const installDir = path.join(cacheRoot, "0.2.0", "linux-x64");
    await fs.promises.mkdir(installDir, { recursive: true });
    await fs.promises.writeFile(path.join(installDir, "zigars"), "binary");
    await fs.promises.writeFile(path.join(installDir, "install.json"), JSON.stringify({
      version: "0.2.0",
      archiveName: target.archiveName,
      executableName: target.executableName,
      sha256: sha256(Buffer.from("binary")),
    }));

    const executablePath = await installZigars(target, {
      version: "0.2.0",
      cacheRoot,
      fetch: async () => {
        throw new Error("fetch should not be called");
      },
    });

    assert.equal(executablePath, path.join(installDir, "zigars"));
  });
});

test("rejects cached executable when marker checksum is missing or mismatched", async () => {
  await withTempDir(async (cacheRoot) => {
    const installDir = path.join(cacheRoot, "0.2.0", "linux-x64");
    const executablePath = path.join(installDir, "zigars");
    await fs.promises.mkdir(installDir, { recursive: true });
    await fs.promises.writeFile(executablePath, "poisoned");
    await fs.promises.writeFile(path.join(installDir, "install.json"), JSON.stringify({
      version: "0.2.0",
      archiveName: target.archiveName,
      executableName: target.executableName,
      sha256: sha256(Buffer.from("expected")),
    }));

    assert.equal(await verifiedCachedExecutable(installDir, "0.2.0", target), null);

    await fs.promises.writeFile(path.join(installDir, "install.json"), JSON.stringify({
      version: "0.2.0",
      archiveName: target.archiveName,
      executableName: target.executableName,
    }));

    assert.equal(await verifiedCachedExecutable(installDir, "0.2.0", target), null);
  });
});

test("downloads, verifies, extracts, and caches executable", async () => {
  await withTempDir(async (cacheRoot) => {
    const archive = Buffer.from("archive bytes");
    const requestedUrls: string[] = [];
    const executablePath = await installZigars(target, {
      version: "0.2.0",
      cacheRoot,
      fetch: async (url) => {
        requestedUrls.push(url);
        if (url.endsWith("zigars-checksums.txt")) {
          return response(`${sha256(archive)}  ${target.archiveName}\n`);
        }
        return response(archive);
      },
      spawnSync: (command, args, options) => {
        assert.equal(command, "tar");
        assert.deepEqual(args.slice(0, 2), ["-xzf", args[1]]);
        assert.equal(options.shell, false);
        const destination = args[3];
        fs.mkdirSync(destination, { recursive: true });
        fs.writeFileSync(path.join(destination, "zigars"), "executable");
        return { status: 0, stderr: "" };
      },
    });

    assert.equal(executablePath, path.join(cacheRoot, "0.2.0", "linux-x64", "zigars"));
    assert.deepEqual(requestedUrls, [
      "https://github.com/oly-wan-kenobi/zigars/releases/download/v0.2.0/zigars-checksums.txt",
      "https://github.com/oly-wan-kenobi/zigars/releases/download/v0.2.0/zigars-x86_64-linux-musl.tar.gz",
    ]);
    assert.equal(await fs.promises.readFile(executablePath, "utf8"), "executable");
  });
});

test("rejects checksum mismatch before extraction", async () => {
  await withTempDir(async (cacheRoot) => {
    let extracted = false;
    await assert.rejects(
      () => installZigars(target, {
        version: "0.2.0",
        cacheRoot,
        fetch: async (url) => {
          if (url.endsWith("zigars-checksums.txt")) {
            return response(`${sha256(Buffer.from("expected"))}  ${target.archiveName}\n`);
          }
          return response(Buffer.from("actual"));
        },
        spawnSync: () => {
          extracted = true;
          return { status: 0, stderr: "" };
        },
      }),
      {
        name: "ChecksumError",
        code: "ERR_ZIGARS_CHECKSUM_MISMATCH",
      },
    );
    assert.equal(extracted, false);
  });
});

test("rejects a malicious archive that extracts the executable as a symlink and writes nothing into the cache", async () => {
  await withTempDir(async (cacheRoot) => {
    const archive = Buffer.from("archive bytes");
    const installDir = path.join(cacheRoot, "0.2.0", "linux-x64");
    await assert.rejects(
      () => installZigars(target, {
        version: "0.2.0",
        cacheRoot,
        fetch: async (url) => {
          if (url.endsWith("zigars-checksums.txt")) {
            return response(`${sha256(archive)}  ${target.archiveName}\n`);
          }
          return response(archive);
        },
        spawnSync: (command, args) => {
          // Simulate tar dropping a symlink named like the executable instead of a file.
          const destination = args[3];
          fs.mkdirSync(destination, { recursive: true });
          fs.symlinkSync("/etc/passwd", path.join(destination, "zigars"));
          return { status: 0, stderr: "" };
        },
      }),
      {
        name: "InstallError",
        code: "ERR_ZIGARS_ARCHIVE_CONTENTS",
      },
    );
    // The install dir must not exist: a rejected archive never produces a cached binary.
    assert.equal(fs.existsSync(installDir), false);
  });
});

test("rejects a malicious archive that writes outside the extraction directory", async () => {
  await withTempDir(async (cacheRoot) => {
    const archive = Buffer.from("archive bytes");
    const installDir = path.join(cacheRoot, "0.2.0", "linux-x64");
    let escapedPath: string | undefined;
    await assert.rejects(
      () => installZigars(target, {
        version: "0.2.0",
        cacheRoot,
        fetch: async (url) => {
          if (url.endsWith("zigars-checksums.txt")) {
            return response(`${sha256(archive)}  ${target.archiveName}\n`);
          }
          return response(archive);
        },
        spawnSync: (command, args) => {
          // Simulate a "../escape" tar member writing a sibling of extractedDir,
          // while never placing the real executable inside extractedDir.
          const destination = args[3];
          fs.mkdirSync(destination, { recursive: true });
          escapedPath = path.join(path.dirname(destination), "escaped");
          fs.writeFileSync(escapedPath, "escaped payload");
          return { status: 0, stderr: "" };
        },
      }),
      {
        name: "InstallError",
        code: "ERR_ZIGARS_ARCHIVE_CONTENTS",
      },
    );
    // The escape artifact lives only in the throwaway temp tree; it is never staged into installDir.
    assert.equal(fs.existsSync(installDir), false);
    assert.ok(escapedPath !== undefined);
  });
});

test("assertContainedRegularFile rejects symlinks and path escapes but accepts a contained regular file", async () => {
  await withTempDir(async (dir) => {
    const containerDir = path.join(dir, "extracted");
    await fs.promises.mkdir(containerDir, { recursive: true });

    // A symlink inside the container is rejected even though it resolves to a real file.
    const realTarget = path.join(dir, "outside-target");
    await fs.promises.writeFile(realTarget, "payload");
    const symlinkPath = path.join(containerDir, "zigars");
    await fs.promises.symlink(realTarget, symlinkPath);
    await assert.rejects(
      () => assertContainedRegularFile(symlinkPath, containerDir),
      { name: "InstallError", code: "ERR_ZIGARS_ARCHIVE_CONTENTS" },
    );

    // A path that escapes the container via ".." is rejected.
    await assert.rejects(
      () => assertContainedRegularFile(path.join(containerDir, "..", "outside-target"), containerDir),
      { name: "InstallError", code: "ERR_ZIGARS_ARCHIVE_CONTENTS" },
    );

    // The container directory itself is not a valid contained executable.
    assert.equal(isContainedWithin(containerDir, containerDir), false);

    // A genuine regular file inside the container is accepted.
    const goodPath = path.join(containerDir, "real-zigars");
    await fs.promises.writeFile(goodPath, "executable");
    await assert.doesNotReject(() => assertContainedRegularFile(goodPath, containerDir));
    assert.equal(isContainedWithin(goodPath, containerDir), true);
  });
});

test("re-downloads when a cached binary is byte-tampered despite a matching marker shape", async () => {
  await withTempDir(async (cacheRoot) => {
    const installDir = path.join(cacheRoot, "0.2.0", "linux-x64");
    await fs.promises.mkdir(installDir, { recursive: true });

    // Write a correct marker for the ORIGINAL bytes, then tamper the binary on disk.
    const originalBytes = Buffer.from("original binary");
    await fs.promises.writeFile(path.join(installDir, "install.json"), JSON.stringify({
      version: "0.2.0",
      archiveName: target.archiveName,
      executableName: target.executableName,
      sha256: sha256(originalBytes),
    }));
    await fs.promises.writeFile(path.join(installDir, "zigars"), "tampered binary");

    // The re-hash must reject the cache, so verifiedCachedExecutable returns null.
    assert.equal(await verifiedCachedExecutable(installDir, "0.2.0", target), null);

    // A full install must therefore re-download and re-extract a fresh, verified binary.
    const archive = Buffer.from("fresh archive bytes");
    let fetchedArchive = false;
    const executablePath = await installZigars(target, {
      version: "0.2.0",
      cacheRoot,
      fetch: async (url) => {
        if (url.endsWith("zigars-checksums.txt")) {
          return response(`${sha256(archive)}  ${target.archiveName}\n`);
        }
        fetchedArchive = true;
        return response(archive);
      },
      spawnSync: (command, args) => {
        const destination = args[3];
        fs.mkdirSync(destination, { recursive: true });
        fs.writeFileSync(path.join(destination, "zigars"), "fresh executable");
        return { status: 0, stderr: "" };
      },
    });

    assert.equal(fetchedArchive, true);
    assert.equal(executablePath, path.join(installDir, "zigars"));
    // The tampered bytes are gone; the cache now holds the freshly verified executable.
    assert.equal(await fs.promises.readFile(executablePath, "utf8"), "fresh executable");
  });
});
