"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.InstallError = void 0;
exports.userCacheRoot = userCacheRoot;
exports.installDirFor = installDirFor;
exports.verifiedCachedExecutable = verifiedCachedExecutable;
exports.isContainedWithin = isContainedWithin;
exports.assertContainedRegularFile = assertContainedRegularFile;
exports.installZigars = installZigars;
const childProcess = __importStar(require("node:child_process"));
const node_fs_1 = __importDefault(require("node:fs"));
const node_os_1 = __importDefault(require("node:os"));
const node_path_1 = __importDefault(require("node:path"));
const checksums_1 = require("./checksums");
const releases_1 = require("./releases");
class InstallError extends Error {
    code;
    constructor(message, options = {}) {
        super(message);
        this.name = "InstallError";
        this.code = options.code ?? "ERR_ZIGARS_INSTALL";
        if (options.cause !== undefined) {
            this.cause = options.cause;
        }
    }
}
exports.InstallError = InstallError;
function userCacheRoot(env = process.env, platform = process.platform) {
    if (env.ZIGARS_MCP_CACHE_DIR) {
        return env.ZIGARS_MCP_CACHE_DIR;
    }
    if (platform === "win32") {
        return node_path_1.default.join(env.LOCALAPPDATA ?? env.APPDATA ?? node_path_1.default.join(node_os_1.default.homedir(), "AppData", "Local"), "zigars-mcp");
    }
    if (platform === "darwin") {
        return node_path_1.default.join(node_os_1.default.homedir(), "Library", "Caches", "zigars-mcp");
    }
    return node_path_1.default.join(env.XDG_CACHE_HOME ?? node_path_1.default.join(node_os_1.default.homedir(), ".cache"), "zigars-mcp");
}
function installDirFor(cacheRoot, version, target) {
    return node_path_1.default.join(cacheRoot, version, `${target.platform}-${target.arch}`);
}
function markerPath(installDir) {
    return node_path_1.default.join(installDir, "install.json");
}
// Re-hashes the cached binary at rest against its install marker before reuse, so a
// poisoned cache forces a fresh, checksum-verified download. A residual verify->exec
// window remains: a local attacker with write access to the cache dir could swap the
// file between this check and the spawn in cli.ts. The cache dir is therefore a trust
// boundary equivalent to any local binary on PATH; defending it further is out of scope
// for a shim that ultimately execs a file from disk.
async function verifiedCachedExecutable(installDir, version, target, fsp = node_fs_1.default.promises) {
    const executablePath = node_path_1.default.join(installDir, target.executableName);
    try {
        const [markerText, executableStat, executableBytes] = await Promise.all([
            fsp.readFile(markerPath(installDir), "utf8"),
            fsp.stat(executablePath),
            fsp.readFile(executablePath),
        ]);
        const marker = JSON.parse(markerText);
        if (executableStat.isFile()
            && marker.version === version
            && marker.archiveName === target.archiveName
            && marker.executableName === target.executableName
            && typeof marker.sha256 === "string"
            && (0, checksums_1.sha256Equals)((0, checksums_1.sha256)(executableBytes), marker.sha256)) {
            return executablePath;
        }
    }
    catch {
        return null;
    }
    return null;
}
async function fetchText(url, fetchImpl) {
    const response = await fetchImpl(url);
    if (!response.ok) {
        throw new InstallError(`Failed to download ${url}: HTTP ${response.status}`, {
            code: "ERR_ZIGARS_DOWNLOAD",
        });
    }
    return response.text();
}
async function fetchBuffer(url, fetchImpl) {
    const response = await fetchImpl(url);
    if (!response.ok) {
        throw new InstallError(`Failed to download ${url}: HTTP ${response.status}`, {
            code: "ERR_ZIGARS_DOWNLOAD",
        });
    }
    return Buffer.from(await response.arrayBuffer());
}
async function findExecutable(root, executableName, fsp = node_fs_1.default.promises) {
    const entries = await fsp.readdir(root, { withFileTypes: true });
    for (const entry of entries) {
        const entryPath = node_path_1.default.join(root, entry.name);
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
function isContainedWithin(child, parent) {
    const resolvedParent = node_path_1.default.resolve(parent);
    const resolvedChild = node_path_1.default.resolve(child);
    if (resolvedChild === resolvedParent) {
        return false;
    }
    const relative = node_path_1.default.relative(resolvedParent, resolvedChild);
    return relative.length > 0 && !relative.startsWith("..") && !node_path_1.default.isAbsolute(relative);
}
async function assertContainedRegularFile(candidate, containerDir, fsp = node_fs_1.default.promises) {
    if (!isContainedWithin(candidate, containerDir)) {
        throw new InstallError(`Archive contents escaped the extraction directory`, {
            code: "ERR_ZIGARS_ARCHIVE_CONTENTS",
        });
    }
    const stat = await fsp.lstat(candidate);
    if (stat.isSymbolicLink() || !stat.isFile()) {
        throw new InstallError(`Archive executable ${node_path_1.default.basename(candidate)} is not a regular file`, {
            code: "ERR_ZIGARS_ARCHIVE_CONTENTS",
        });
    }
}
function extractArchive(archivePath, destination, spawnSyncImpl = childProcess.spawnSync) {
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
async function installZigars(target, options = {}) {
    const version = options.version;
    if (typeof version !== "string" || version.length === 0) {
        throw new TypeError("version must be a non-empty string");
    }
    const fsp = options.fsPromises ?? node_fs_1.default.promises;
    if (!options.fetch && typeof globalThis.fetch !== "function") {
        throw new InstallError("This Node.js runtime does not provide fetch", {
            code: "ERR_ZIGARS_FETCH_UNAVAILABLE",
        });
    }
    const fetchImpl = options.fetch ?? ((url) => globalThis.fetch(url));
    const cacheRoot = options.cacheRoot ?? userCacheRoot(options.env ?? process.env, options.platform ?? process.platform);
    const installDir = installDirFor(cacheRoot, version, target);
    const cached = await verifiedCachedExecutable(installDir, version, target, fsp);
    if (cached) {
        return cached;
    }
    await fsp.mkdir(cacheRoot, { recursive: true });
    const checksumsText = await fetchText((0, releases_1.checksumUrl)(version), fetchImpl);
    const expectedChecksum = (0, checksums_1.checksumForArchive)((0, checksums_1.parseChecksums)(checksumsText), target.archiveName);
    const archiveBuffer = await fetchBuffer((0, releases_1.releaseAssetUrl)(version, target.archiveName), fetchImpl);
    const actualChecksum = (0, checksums_1.verifySha256)(archiveBuffer, expectedChecksum, target.archiveName);
    const tempRoot = await fsp.mkdtemp(node_path_1.default.join(cacheRoot, ".install-"));
    const extractedDir = node_path_1.default.join(tempRoot, "extracted");
    const stagedDir = node_path_1.default.join(tempRoot, "staged");
    const archivePath = node_path_1.default.join(tempRoot, target.archiveName);
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
        await assertContainedRegularFile(extractedExecutable, extractedDir, fsp);
        const stagedExecutable = node_path_1.default.join(stagedDir, target.executableName);
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
        await fsp.mkdir(node_path_1.default.dirname(installDir), { recursive: true });
        await fsp.rm(installDir, { recursive: true, force: true });
        await fsp.rename(stagedDir, installDir);
        return node_path_1.default.join(installDir, target.executableName);
    }
    finally {
        await fsp.rm(tempRoot, { recursive: true, force: true });
    }
}
