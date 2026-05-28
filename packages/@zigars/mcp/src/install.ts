import * as childProcess from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { checksumForArchive, parseChecksums, sha256, sha256Equals, verifySha256 } from "./checksums";
import { checksumUrl, releaseAssetUrl } from "./releases";
import type { HostTarget } from "./targets";

export interface InstallErrorOptions {
  code?: string;
  cause?: unknown;
}

export class InstallError extends Error {
  code: string;

  constructor(message: string, options: InstallErrorOptions = {}) {
    super(message);
    this.name = "InstallError";
    this.code = options.code ?? "ERR_ZIGARS_INSTALL";
    if (options.cause !== undefined) {
      this.cause = options.cause;
    }
  }
}

type FsPromises = typeof fs.promises;

interface FetchResponse {
  ok: boolean;
  status: number;
  text(): Promise<string>;
  arrayBuffer(): Promise<ArrayBufferLike>;
}

type FetchImpl = (url: string) => Promise<FetchResponse>;

interface SpawnSyncResult {
  error?: Error;
  status: number | null;
  stderr?: string | Buffer | null;
}

type SpawnSyncImpl = (
  command: string,
  args: string[],
  options: childProcess.SpawnSyncOptionsWithStringEncoding,
) => SpawnSyncResult;

export interface InstallOptions {
  version?: string;
  cacheRoot?: string;
  env?: NodeJS.ProcessEnv;
  fetch?: FetchImpl;
  fsPromises?: FsPromises;
  platform?: NodeJS.Platform | string;
  spawnSync?: SpawnSyncImpl;
}

export function userCacheRoot(env: NodeJS.ProcessEnv = process.env, platform: NodeJS.Platform | string = process.platform): string {
  if (env.ZIGARS_MCP_CACHE_DIR) {
    return env.ZIGARS_MCP_CACHE_DIR;
  }
  if (platform === "win32") {
    return path.join(env.LOCALAPPDATA ?? env.APPDATA ?? path.join(os.homedir(), "AppData", "Local"), "zigars-mcp");
  }
  if (platform === "darwin") {
    return path.join(os.homedir(), "Library", "Caches", "zigars-mcp");
  }
  return path.join(env.XDG_CACHE_HOME ?? path.join(os.homedir(), ".cache"), "zigars-mcp");
}

export function installDirFor(cacheRoot: string, version: string, target: Readonly<HostTarget>): string {
  return path.join(cacheRoot, version, `${target.platform}-${target.arch}`);
}

function markerPath(installDir: string): string {
  return path.join(installDir, "install.json");
}

export async function verifiedCachedExecutable(
  installDir: string,
  version: string,
  target: Readonly<HostTarget>,
  fsp: FsPromises = fs.promises,
): Promise<string | null> {
  const executablePath = path.join(installDir, target.executableName);
  try {
    const [markerText, executableStat, executableBytes] = await Promise.all([
      fsp.readFile(markerPath(installDir), "utf8"),
      fsp.stat(executablePath),
      fsp.readFile(executablePath),
    ]);
    const marker = JSON.parse(markerText);
    if (
      executableStat.isFile()
      && marker.version === version
      && marker.archiveName === target.archiveName
      && marker.executableName === target.executableName
      && typeof marker.sha256 === "string"
      && sha256Equals(sha256(executableBytes), marker.sha256)
    ) {
      return executablePath;
    }
  } catch {
    return null;
  }
  return null;
}

async function fetchText(url: string, fetchImpl: FetchImpl): Promise<string> {
  const response = await fetchImpl(url);
  if (!response.ok) {
    throw new InstallError(`Failed to download ${url}: HTTP ${response.status}`, {
      code: "ERR_ZIGARS_DOWNLOAD",
    });
  }
  return response.text();
}

async function fetchBuffer(url: string, fetchImpl: FetchImpl): Promise<Buffer> {
  const response = await fetchImpl(url);
  if (!response.ok) {
    throw new InstallError(`Failed to download ${url}: HTTP ${response.status}`, {
      code: "ERR_ZIGARS_DOWNLOAD",
    });
  }
  return Buffer.from(await response.arrayBuffer());
}

async function findExecutable(root: string, executableName: string, fsp: FsPromises = fs.promises): Promise<string | null> {
  const entries = await fsp.readdir(root, { withFileTypes: true });
  for (const entry of entries) {
    const entryPath = path.join(root, entry.name);
    if (entry.isFile() && entry.name === executableName) {
      return entryPath;
    }
    if (entry.isDirectory()) {
      const found = await findExecutable(entryPath, executableName, fsp);
      if (found) {
        return found;
      }
    }
  }
  return null;
}

function extractArchive(
  archivePath: string,
  destination: string,
  spawnSyncImpl: SpawnSyncImpl = childProcess.spawnSync,
): void {
  const result = spawnSyncImpl("tar", ["-xzf", archivePath, "-C", destination], {
    shell: false,
    stdio: "pipe",
    encoding: "utf8",
  });
  if (result.error) {
    throw new InstallError(`Failed to extract zigars archive: ${result.error.message}`, {
      code: "ERR_ZIGARS_EXTRACT",
      cause: result.error,
    });
  }
  if (result.status !== 0) {
    const stderr = result.stderr?.toString();
    const detail = stderr ? `: ${stderr.trim()}` : "";
    throw new InstallError(`Failed to extract zigars archive${detail}`, {
      code: "ERR_ZIGARS_EXTRACT",
    });
  }
}

export async function installZigars(target: Readonly<HostTarget>, options: InstallOptions = {}): Promise<string> {
  const version = options.version;
  if (typeof version !== "string" || version.length === 0) {
    throw new TypeError("version must be a non-empty string");
  }

  const fsp = options.fsPromises ?? fs.promises;
  if (!options.fetch && typeof globalThis.fetch !== "function") {
    throw new InstallError("This Node.js runtime does not provide fetch", {
      code: "ERR_ZIGARS_FETCH_UNAVAILABLE",
    });
  }
  const fetchImpl: FetchImpl = options.fetch ?? ((url: string) => globalThis.fetch(url));

  const cacheRoot = options.cacheRoot ?? userCacheRoot(options.env ?? process.env, options.platform ?? process.platform);
  const installDir = installDirFor(cacheRoot, version, target);
  const cached = await verifiedCachedExecutable(installDir, version, target, fsp);
  if (cached) {
    return cached;
  }

  await fsp.mkdir(cacheRoot, { recursive: true });

  const checksumsText = await fetchText(checksumUrl(version), fetchImpl);
  const expectedChecksum = checksumForArchive(parseChecksums(checksumsText), target.archiveName);
  const archiveBuffer = await fetchBuffer(releaseAssetUrl(version, target.archiveName), fetchImpl);
  const actualChecksum = verifySha256(archiveBuffer, expectedChecksum, target.archiveName);

  const tempRoot = await fsp.mkdtemp(path.join(cacheRoot, ".install-"));
  const extractedDir = path.join(tempRoot, "extracted");
  const stagedDir = path.join(tempRoot, "staged");
  const archivePath = path.join(tempRoot, target.archiveName);

  try {
    await fsp.mkdir(extractedDir);
    await fsp.mkdir(stagedDir);
    await fsp.writeFile(archivePath, archiveBuffer);
    extractArchive(archivePath, extractedDir, options.spawnSync ?? childProcess.spawnSync);

    const extractedExecutable = await findExecutable(extractedDir, target.executableName, fsp);
    if (!extractedExecutable) {
      throw new InstallError(`Archive did not contain ${target.executableName}`, {
        code: "ERR_ZIGARS_ARCHIVE_CONTENTS",
      });
    }

    const stagedExecutable = path.join(stagedDir, target.executableName);
    await fsp.copyFile(extractedExecutable, stagedExecutable);
    if (target.platform !== "win32") {
      await fsp.chmod(stagedExecutable, 0o755);
    }
    await fsp.writeFile(markerPath(stagedDir), `${JSON.stringify({
      version,
      archiveName: target.archiveName,
      executableName: target.executableName,
      sha256: actualChecksum,
    }, null, 2)}\n`);

    await fsp.mkdir(path.dirname(installDir), { recursive: true });
    await fsp.rm(installDir, { recursive: true, force: true });
    await fsp.rename(stagedDir, installDir);
    return path.join(installDir, target.executableName);
  } finally {
    await fsp.rm(tempRoot, { recursive: true, force: true });
  }
}
