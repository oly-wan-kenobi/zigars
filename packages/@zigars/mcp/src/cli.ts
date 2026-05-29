import * as childProcess from "node:child_process";
import os from "node:os";
import { normalizeZigarsArgs } from "./args";
import { installZigars, type InstallOptions } from "./install";
import { UnsupportedTargetError, resolveHostTarget } from "./targets";
import type { HostTarget } from "./targets";
import packageJson from "../package.json";

export function formatUsage(): string {
  return [
    "Usage: zigars-mcp [zigars arguments...]",
    "",
    "Example:",
    "  zigars-mcp --workspace /absolute/path/to/zig/project",
    "",
    "@zigars/mcp writes diagnostics to stderr only. stdout is reserved for MCP JSON-RPC.",
  ].join("\n");
}

function signalExitCode(signal: NodeJS.Signals | null): number {
  if (!signal) {
    return 1;
  }
  const signalNumber = os.constants.signals[signal];
  return typeof signalNumber === "number" ? 128 + signalNumber : 1;
}

function waitForChild(child: childProcess.ChildProcess): Promise<number> {
  return new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      resolve(code ?? signalExitCode(signal));
    });
  });
}

type Writable = Pick<NodeJS.WritableStream, "write">;
type SpawnImpl = (
  command: string,
  args: readonly string[],
  options: childProcess.SpawnOptions,
) => childProcess.ChildProcess;

export interface RunOptions extends InstallOptions {
  stderr?: Writable;
  arch?: NodeJS.Architecture | string;
  installZigars?: (target: Readonly<HostTarget>, options: InstallOptions) => Promise<string>;
  spawn?: SpawnImpl;
  stdio?: childProcess.SpawnOptions["stdio"];
}

export async function run(argv: unknown, options: RunOptions = {}): Promise<number> {
  const stderr = options.stderr ?? process.stderr;
  const args = Array.isArray(argv) ? argv : [];

  if (args.includes("--help") || args.includes("-h")) {
    stderr.write(`${formatUsage()}\n`);
    return 0;
  }

  if (args.includes("--version")) {
    stderr.write(`${packageJson.version}\n`);
    return 0;
  }

  try {
    const target = resolveHostTarget({
      platform: options.platform,
      arch: options.arch,
    });
    const zigarsArgs = normalizeZigarsArgs(args);
    const executablePath = await (options.installZigars ?? installZigars)(target, {
      version: packageJson.version,
      cacheRoot: options.cacheRoot,
      env: options.env,
      fetch: options.fetch,
      fsPromises: options.fsPromises,
      platform: options.platform,
      spawnSync: options.spawnSync,
    });
    const child = (options.spawn ?? childProcess.spawn)(executablePath, zigarsArgs, {
      shell: false,
      stdio: options.stdio ?? "inherit",
    });
    return await waitForChild(child);
  } catch (error) {
    if (error instanceof UnsupportedTargetError) {
      stderr.write(`${error.message}\n`);
      return 1;
    }
    stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    return 1;
  }
}

export function main(argv: string[], options?: RunOptions): void {
  run(argv, options).then((code) => {
    process.exitCode = code;
  }, (error) => {
    const stderr = options?.stderr ?? process.stderr;
    stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
