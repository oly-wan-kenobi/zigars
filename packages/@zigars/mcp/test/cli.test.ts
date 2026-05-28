import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import type * as childProcess from "node:child_process";
import { EventEmitter } from "node:events";
import path from "node:path";
import test from "node:test";
import packageJson from "../package.json";
import { run, type RunOptions } from "../src/cli";

async function captureRun(argv: string[], options: RunOptions = {}) {
  let stdout = "";
  let stderr = "";
  const code = await run(argv, {
    platform: "linux",
    arch: "x64",
    ...options,
    stdout: { write: (chunk: string | Uint8Array) => { stdout += chunk.toString(); return true; } },
    stderr: { write: (chunk: string | Uint8Array) => { stderr += chunk.toString(); return true; } },
  });

  return { code, stdout, stderr };
}

function createChild({ code = 0, signal = null }: { code?: number | null; signal?: NodeJS.Signals | null } = {}) {
  const child = new EventEmitter();
  process.nextTick(() => {
    child.emit("exit", code, signal);
  });
  return child as childProcess.ChildProcess;
}

test("spawns installed zigars with normalized args and keeps stdout reserved", async () => {
  let spawnCall: {
    executable: string;
    args: readonly string[];
    spawnOptions: childProcess.SpawnOptions;
  } | undefined;
  const result = await captureRun(["--workspace", "/tmp/example"], {
    installZigars: async (target) => {
      assert.equal(target.archiveName, "zigars-x86_64-linux-musl.tar.gz");
      return "/cache/zigars";
    },
    spawn: (executable, args, spawnOptions) => {
      spawnCall = { executable, args, spawnOptions };
      return createChild({ code: 7 });
    },
    stdio: "pipe",
  });

  assert.equal(result.code, 7);
  assert.equal(result.stdout, "");
  assert.equal(result.stderr, "");
  assert.deepEqual(spawnCall, {
    executable: "/cache/zigars",
    args: ["--transport", "stdio", "--workspace", "/tmp/example"],
    spawnOptions: {
      shell: false,
      stdio: "pipe",
    },
  });
});

test("reports unsupported targets on stderr only", async () => {
  const result = await captureRun(["--workspace", "/tmp/example"], {
    platform: "sunos",
    arch: "x64",
  });

  assert.equal(result.code, 1);
  assert.equal(result.stdout, "");
  assert.match(result.stderr, /Unsupported zigars host target: sunos\/x64/);
});

test("prints help to stderr only", async () => {
  const result = await captureRun(["--help"]);

  assert.equal(result.code, 0);
  assert.equal(result.stdout, "");
  assert.match(result.stderr, /Usage: zigars-mcp/);
});

test("prints version to stderr only", async () => {
  const result = await captureRun(["--version"]);

  assert.equal(result.code, 0);
  assert.equal(result.stdout, "");
  assert.equal(result.stderr, `${packageJson.version}\n`);
});

test("bin entrypoint runs the CLI wrapper", () => {
  const result = spawnSync(process.execPath, [
    path.join(process.cwd(), "bin", "zigars-mcp.js"),
    "--help",
  ], {
    encoding: "utf8",
  });

  assert.equal(result.status, 0);
  assert.equal(result.stdout, "");
  assert.match(result.stderr, /Usage: zigars-mcp/);
});
