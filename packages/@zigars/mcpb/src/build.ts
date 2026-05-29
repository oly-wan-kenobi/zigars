#!/usr/bin/env node

import { spawnSync, type SpawnSyncOptionsWithStringEncoding, type SpawnSyncReturns } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const packageRoot = path.resolve(path.dirname(__filename), "..");
const repoRoot = path.resolve(packageRoot, "..", "..", "..");
const mcpbPackage = process.env.MCPB_CLI_PACKAGE ?? "@anthropic-ai/mcpb@2.1.2";
const processVersions = process.versions as NodeJS.ProcessVersions & { bun?: string };
const mcpbRunner = process.env.MCPB_CLI_RUNNER ?? (processVersions.bun ? "bun" : "npm");

type Platform = "darwin" | "linux" | "win32";
type TargetName = "darwin-universal" | "linux-x64" | "win32-x64";

interface ArchiveInput {
  name: string;
  exe: string;
}

interface TargetConfig {
  stageName: string;
  artifactName: string;
  platforms: Platform[];
  entryPoint: string;
  command: string;
  archives: ArchiveInput[];
  universal?: boolean;
}

interface BuildOptions {
  target: string;
  assetsDir: string;
  stageRoot: string;
  outDir: string;
  pack: boolean;
  info: boolean;
  sha256: boolean;
  signDev: boolean;
  stageOnly: boolean;
  validateOnly: boolean;
}

interface PackageJson {
  version?: string;
}

interface ChecksumEntry {
  hash: string;
  file: string;
}

const targets: Record<TargetName, TargetConfig> = {
  "darwin-universal": {
    stageName: "zigars-darwin-universal",
    artifactName: "zigars-darwin-universal.mcpb",
    platforms: ["darwin"],
    entryPoint: "server/zigars",
    command: "${__dirname}/server/zigars",
    archives: [
      { name: "zigars-x86_64-macos.tar.gz", exe: "zigars" },
      { name: "zigars-aarch64-macos.tar.gz", exe: "zigars" },
    ],
    universal: true,
  },
  "linux-x64": {
    stageName: "zigars-linux-x64",
    artifactName: "zigars-linux-x64.mcpb",
    platforms: ["linux"],
    entryPoint: "server/zigars",
    command: "${__dirname}/server/zigars",
    archives: [{ name: "zigars-x86_64-linux-musl.tar.gz", exe: "zigars" }],
  },
  "win32-x64": {
    stageName: "zigars-windows-x64",
    artifactName: "zigars-windows-x64.mcpb",
    platforms: ["win32"],
    entryPoint: "server/zigars.exe",
    command: "${__dirname}/server/zigars.exe",
    archives: [{ name: "zigars-x86_64-windows-gnu.tar.gz", exe: "zigars.exe" }],
  },
};

function requireValue(argv: string[], index: number, flag: string): string {
  const value = argv[index];
  if (!value) throw new Error(`Missing value for ${flag}`);
  return value;
}

function parseArgs(argv: string[]): BuildOptions {
  const options: BuildOptions = {
    target: "all",
    assetsDir: path.join(repoRoot, "dist", "assets"),
    stageRoot: path.join(repoRoot, "dist", "mcpb-stage"),
    outDir: path.join(repoRoot, "dist", "assets"),
    pack: false,
    info: false,
    sha256: false,
    signDev: false,
    stageOnly: false,
    validateOnly: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--target") {
      options.target = requireValue(argv, ++i, arg);
    } else if (arg === "--assets-dir") {
      options.assetsDir = path.resolve(requireValue(argv, ++i, arg));
    } else if (arg === "--stage-root") {
      options.stageRoot = path.resolve(requireValue(argv, ++i, arg));
    } else if (arg === "--out-dir") {
      options.outDir = path.resolve(requireValue(argv, ++i, arg));
    } else if (arg === "--pack") {
      options.pack = true;
    } else if (arg === "--info") {
      options.info = true;
    } else if (arg === "--sha256") {
      options.sha256 = true;
    } else if (arg === "--sign-dev") {
      options.signDev = true;
    } else if (arg === "--stage-only") {
      options.stageOnly = true;
    } else if (arg === "--validate-only") {
      options.validateOnly = true;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return options;
}

async function readJson<T>(filePath: string): Promise<T> {
  return JSON.parse(await fs.readFile(filePath, "utf8")) as T;
}

async function readZonVersion(): Promise<string> {
  const zon = await fs.readFile(path.join(repoRoot, "build.zig.zon"), "utf8");
  const match = zon.match(/\.version\s*=\s*"([^"]+)"/);
  if (!match) throw new Error("Could not read version from build.zig.zon");
  return match[1];
}

async function resolveVersion(): Promise<string> {
  const zonVersion = await readZonVersion();
  const npmPackage = await readJson<PackageJson>(path.join(repoRoot, "packages", "@zigars", "mcp", "package.json"));
  const mcpbPackageJson = await readJson<PackageJson>(path.join(packageRoot, "package.json"));
  if (npmPackage.version !== zonVersion) {
    throw new Error(`Version mismatch: build.zig.zon=${zonVersion}, @zigars/mcp=${npmPackage.version ?? "unknown"}`);
  }
  if (mcpbPackageJson.version !== zonVersion) {
    throw new Error(`Version mismatch: build.zig.zon=${zonVersion}, @zigars/mcpb=${mcpbPackageJson.version ?? "unknown"}`);
  }
  return zonVersion;
}

function selectedTargets(name: string): Array<[TargetName, TargetConfig]> {
  if (name === "all") return Object.entries(targets) as Array<[TargetName, TargetConfig]>;
  if (!Object.hasOwn(targets, name)) throw new Error(`Unknown target ${name}; expected all, ${Object.keys(targets).join(", ")}`);
  return [[name as TargetName, targets[name as TargetName]]];
}

function run(command: string, args: string[], options: Partial<SpawnSyncOptionsWithStringEncoding> = {}): SpawnSyncReturns<string> {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? repoRoot,
    stdio: options.stdio ?? "inherit",
    encoding: "utf8",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed with exit ${result.status ?? "unknown"}`);
  }
  return result;
}

function findTool(names: string[]): string | null {
  const pathEntries = (process.env.PATH ?? "").split(path.delimiter).filter((entry) => entry.length > 0);
  const pathExtensions = process.platform === "win32"
    ? (process.env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD").split(";").filter((ext) => ext.length > 0)
    : [""];
  for (const name of names) {
    // Absolute or relative paths are probed directly; bare names are resolved against PATH.
    const candidateDirs = path.basename(name) === name ? pathEntries : [path.dirname(name)];
    const baseName = path.basename(name);
    for (const dir of candidateDirs) {
      for (const ext of pathExtensions) {
        const candidate = path.join(dir, `${baseName}${ext}`);
        if (existsSync(candidate)) return candidate;
      }
    }
  }
  return null;
}

async function resetDir(dir: string): Promise<void> {
  await fs.rm(dir, { recursive: true, force: true });
  await fs.mkdir(dir, { recursive: true });
}

async function copyIfExists(from: string, to: string): Promise<void> {
  if (!existsSync(from)) return;
  await fs.mkdir(path.dirname(to), { recursive: true });
  await fs.copyFile(from, to);
}

async function walkFiles(root: string): Promise<string[]> {
  const entries = await fs.readdir(root, { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    const full = path.join(root, entry.name);
    if (entry.isDirectory()) {
      files.push(...await walkFiles(full));
    } else if (entry.isFile()) {
      files.push(full);
    }
  }
  return files;
}

async function extractArchive(assetsDir: string, archive: ArchiveInput, tempRoot: string): Promise<string> {
  const archivePath = path.join(assetsDir, archive.name);
  if (!existsSync(archivePath)) throw new Error(`Missing release archive: ${archivePath}`);
  const outDir = path.join(tempRoot, archive.name.replace(/\.tar\.gz$/, ""));
  await resetDir(outDir);
  run("tar", ["-xzf", archivePath, "-C", outDir]);
  const files = await walkFiles(outDir);
  const executable = files.find((file) => path.basename(file) === archive.exe);
  if (!executable) throw new Error(`Could not find ${archive.exe} inside ${archivePath}`);
  return executable;
}

async function stageBinary(target: TargetConfig, assetsDir: string, serverDir: string, tempRoot: string): Promise<void> {
  if (target.universal) {
    const inputs: string[] = [];
    for (const archive of target.archives) {
      inputs.push(await extractArchive(assetsDir, archive, tempRoot));
    }
    const lipo = findTool(["lipo", "llvm-lipo", "llvm-lipo-18", "llvm-lipo-17", "llvm-lipo-16", "llvm-lipo-15", "llvm-lipo-14"]);
    if (!lipo) {
      throw new Error("Building zigars-darwin-universal.mcpb requires lipo or llvm-lipo on PATH");
    }
    const output = path.join(serverDir, "zigars");
    run(lipo, ["-create", ...inputs, "-output", output]);
    await fs.chmod(output, 0o755);
    return;
  }

  const [archive] = target.archives;
  if (!archive) throw new Error(`Target ${target.stageName} has no release archive`);
  const executable = await extractArchive(assetsDir, archive, tempRoot);
  const output = path.join(serverDir, archive.exe);
  await fs.copyFile(executable, output);
  await fs.chmod(output, archive.exe.endsWith(".exe") ? 0o644 : 0o755);
}

function manifestFor(target: TargetConfig, version: string): Record<string, unknown> {
  return {
    manifest_version: "0.3",
    name: "zigars-mcp",
    display_name: "zigars MCP",
    version,
    description: "Deterministic local MCP server for Zig development.",
    long_description: "zigars runs as a local stdio MCP server for Zig workspaces. It exposes compiler commands, formatting, ZLS-backed code intelligence, local docs lookup, static analysis, release evidence helpers, and optional backend workflows. Source writes require apply=true.",
    author: {
      name: "oly-wan-kenobi",
      url: "https://github.com/oly-wan-kenobi",
    },
    repository: {
      type: "git",
      url: "https://github.com/oly-wan-kenobi/zigars.git",
    },
    homepage: "https://github.com/oly-wan-kenobi/zigars#readme",
    documentation: "https://github.com/oly-wan-kenobi/zigars/blob/main/README.md",
    support: "https://github.com/oly-wan-kenobi/zigars/issues",
    license: "MIT",
    keywords: ["zig", "mcp", "model-context-protocol", "claude-desktop", "zigars"],
    server: {
      type: "binary",
      entry_point: target.entryPoint,
      mcp_config: {
        command: target.command,
        args: ["--transport", "stdio", "--workspace", "${user_config.workspace}"],
        env: {},
      },
    },
    compatibility: {
      platforms: target.platforms,
    },
    user_config: {
      workspace: {
        type: "directory",
        title: "Zig workspace",
        description: "The Zig project directory that zigars is allowed to inspect and modify when apply=true is explicitly requested.",
        required: true,
        default: "${HOME}",
      },
    },
    tools: [
      { name: "zigars_schema", description: "Describe zigars tool groups, risk metadata, backend setup, and discovery hints." },
      { name: "zigars_workspace_info", description: "Report the configured workspace, cache directory, toolchain paths, and server settings." },
      { name: "zigars_doctor", description: "Check Zig, ZLS, optional backend, workspace, transport, and timeout health." },
      { name: "zig_build", description: "Run an explicit Zig build command in the configured workspace." },
      { name: "zig_test", description: "Run Zig tests in the configured workspace." },
      { name: "zig_format", description: "Preview or apply Zig formatting for workspace files." },
      { name: "zig_diagnostics", description: "Return ZLS-backed diagnostics for a workspace file when ZLS is configured." },
      { name: "zig_import_graph", description: "Summarize Zig imports from readable workspace source files." },
      { name: "zigars_client_config_generate", description: "Preview MCP client configuration artifacts for zigars." },
    ],
    tools_generated: true,
    prompts_generated: true,
  };
}

async function writeStageFiles(stageDir: string, target: TargetConfig, version: string): Promise<void> {
  await fs.writeFile(path.join(stageDir, "manifest.json"), `${JSON.stringify(manifestFor(target, version), null, 2)}\n`);
  await fs.writeFile(path.join(stageDir, ".mcpbignore"), [
    "# Exclude local build and verification junk from MCPB packages.",
    "*.log",
    "tmp/",
    "coverage/",
    "node_modules/",
    ".DS_Store",
    "",
  ].join("\n"));
  await fs.writeFile(path.join(stageDir, "README.md"), [
    "# zigars MCP",
    "",
    "This MCPB bundle installs zigars as a local stdio MCP server for Claude Desktop.",
    "During installation, choose the Zig workspace directory that zigars should serve.",
    "",
    "Zig 0.16.0 must be available on PATH. ZLS and other analysis/profiling backends are optional and can still be configured through direct binary or npm-shim installs when needed.",
    "",
  ].join("\n"));
  await copyIfExists(path.join(repoRoot, "LICENSE"), path.join(stageDir, "LICENSE"));
}

async function stageTarget(name: TargetName, target: TargetConfig, options: BuildOptions, version: string): Promise<string> {
  const stageDir = path.join(options.stageRoot, target.stageName);
  const serverDir = path.join(stageDir, "server");
  const tempRoot = path.join(options.stageRoot, ".tmp", target.stageName);
  await resetDir(stageDir);
  await fs.mkdir(serverDir, { recursive: true });
  await resetDir(tempRoot);
  await stageBinary(target, options.assetsDir, serverDir, tempRoot);
  await writeStageFiles(stageDir, target, version);
  console.log(`staged ${name}: ${path.relative(repoRoot, stageDir)}`);
  return stageDir;
}

function runMcpb(args: string[]): SpawnSyncReturns<string> {
  if (mcpbRunner === "bun") {
    return run("bunx", ["--bun", "--package", mcpbPackage, "mcpb", ...args]);
  }
  return run("npm", ["exec", "--yes", "--package", mcpbPackage, "--", "mcpb", ...args]);
}

async function sha256(filePath: string): Promise<string> {
  const bytes = await fs.readFile(filePath);
  return createHash("sha256").update(bytes).digest("hex");
}

async function writeChecksumFile(entries: ChecksumEntry[], outDir: string): Promise<void> {
  if (entries.length === 0) return;
  await fs.mkdir(outDir, { recursive: true });
  const lines: string[] = [];
  for (const entry of entries.sort((a, b) => a.file.localeCompare(b.file))) {
    lines.push(`${entry.hash}  ${entry.file}`);
  }
  await fs.writeFile(path.join(outDir, "zigars-mcpb-checksums.txt"), `${lines.join("\n")}\n`);
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));
  const version = await resolveVersion();
  const chosen = selectedTargets(options.target);
  await fs.mkdir(options.outDir, { recursive: true });
  await fs.mkdir(options.stageRoot, { recursive: true });

  const checksumEntries: ChecksumEntry[] = [];
  for (const [name, target] of chosen) {
    const stageDir = await stageTarget(name, target, options, version);
    runMcpb(["validate", stageDir]);
    if (options.validateOnly || options.stageOnly) continue;
    if (!options.pack && !options.info && !options.sha256 && !options.signDev) continue;

    const artifactPath = path.join(options.outDir, target.artifactName);
    await fs.rm(artifactPath, { force: true });
    runMcpb(["pack", stageDir, artifactPath]);
    if (options.signDev) runMcpb(["sign", artifactPath, "--self-signed"]);
    if (options.info) runMcpb(["info", artifactPath]);
    if (options.sha256 || options.signDev) {
      const hash = await sha256(artifactPath);
      checksumEntries.push({ hash, file: target.artifactName });
      console.log(`${hash}  ${target.artifactName}`);
    }
  }

  await writeChecksumFile(checksumEntries, options.outDir);
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
