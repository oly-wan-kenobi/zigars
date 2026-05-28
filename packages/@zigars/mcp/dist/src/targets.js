"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.UnsupportedTargetError = exports.TARGETS = void 0;
exports.resolveHostTarget = resolveHostTarget;
exports.TARGETS = Object.freeze({
    // Linux host detection does not expose libc ABI consistently across Node and Bun.
    // Use the musl archives as the default portable runtime; GNU archives remain
    // published for direct downloads and CI jobs that explicitly need glibc ABI.
    "linux:x64": Object.freeze({
        platform: "linux",
        arch: "x64",
        archiveName: "zigars-x86_64-linux-musl.tar.gz",
        executableName: "zigars",
    }),
    "linux:arm64": Object.freeze({
        platform: "linux",
        arch: "arm64",
        archiveName: "zigars-aarch64-linux-musl.tar.gz",
        executableName: "zigars",
    }),
    "darwin:x64": Object.freeze({
        platform: "darwin",
        arch: "x64",
        archiveName: "zigars-x86_64-macos.tar.gz",
        executableName: "zigars",
    }),
    "darwin:arm64": Object.freeze({
        platform: "darwin",
        arch: "arm64",
        archiveName: "zigars-aarch64-macos.tar.gz",
        executableName: "zigars",
    }),
    "win32:x64": Object.freeze({
        platform: "win32",
        arch: "x64",
        archiveName: "zigars-x86_64-windows-gnu.tar.gz",
        executableName: "zigars.exe",
    }),
    "win32:arm64": Object.freeze({
        platform: "win32",
        arch: "arm64",
        archiveName: "zigars-aarch64-windows-gnu.tar.gz",
        executableName: "zigars.exe",
    }),
});
class UnsupportedTargetError extends Error {
    code;
    platform;
    arch;
    constructor(platform, arch) {
        super(`Unsupported zigars host target: ${platform}/${arch}`);
        this.name = "UnsupportedTargetError";
        this.code = "ERR_ZIGARS_UNSUPPORTED_TARGET";
        this.platform = platform;
        this.arch = arch;
    }
}
exports.UnsupportedTargetError = UnsupportedTargetError;
function resolveHostTarget(options = {}) {
    const platform = options.platform ?? process.platform;
    const arch = options.arch ?? process.arch;
    const target = exports.TARGETS[`${platform}:${arch}`];
    if (!target) {
        throw new UnsupportedTargetError(platform, arch);
    }
    return target;
}
