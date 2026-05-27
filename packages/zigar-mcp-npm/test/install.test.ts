import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { sha256 } from "../src/checksums";
import { installZigar } from "../src/install";
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
  const dir = await fs.promises.mkdtemp(path.join(os.tmpdir(), "zigar-mcp-test-"));
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
    await fs.promises.writeFile(path.join(installDir, "zigar"), "binary");
    await fs.promises.writeFile(path.join(installDir, "install.json"), JSON.stringify({
      version: "0.2.0",
      archiveName: target.archiveName,
      executableName: target.executableName,
    }));

    const executablePath = await installZigar(target, {
      version: "0.2.0",
      cacheRoot,
      fetch: async () => {
        throw new Error("fetch should not be called");
      },
    });

    assert.equal(executablePath, path.join(installDir, "zigar"));
  });
});

test("downloads, verifies, extracts, and caches executable", async () => {
  await withTempDir(async (cacheRoot) => {
    const archive = Buffer.from("archive bytes");
    const requestedUrls: string[] = [];
    const executablePath = await installZigar(target, {
      version: "0.2.0",
      cacheRoot,
      fetch: async (url) => {
        requestedUrls.push(url);
        if (url.endsWith("zigar-checksums.txt")) {
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
        fs.writeFileSync(path.join(destination, "zigar"), "executable");
        return { status: 0, stderr: "" };
      },
    });

    assert.equal(executablePath, path.join(cacheRoot, "0.2.0", "linux-x64", "zigar"));
    assert.deepEqual(requestedUrls, [
      "https://github.com/oly-wan-kenobi/zigar/releases/download/v0.2.0/zigar-checksums.txt",
      "https://github.com/oly-wan-kenobi/zigar/releases/download/v0.2.0/zigar-x86_64-linux-musl.tar.gz",
    ]);
    assert.equal(await fs.promises.readFile(executablePath, "utf8"), "executable");
  });
});

test("rejects checksum mismatch before extraction", async () => {
  await withTempDir(async (cacheRoot) => {
    let extracted = false;
    await assert.rejects(
      () => installZigar(target, {
        version: "0.2.0",
        cacheRoot,
        fetch: async (url) => {
          if (url.endsWith("zigar-checksums.txt")) {
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
        code: "ERR_ZIGAR_CHECKSUM_MISMATCH",
      },
    );
    assert.equal(extracted, false);
  });
});
