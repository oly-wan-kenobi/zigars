"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.UnsupportedTargetError = exports.TARGETS = void 0;
exports.resolveHostTarget = resolveHostTarget;
exports.TARGETS = Object.freeze({
    "linux:x64": Object.freeze({
        platform: "linux",
        arch: "x64",
        archiveName: "zigar-x86_64-linux-musl.tar.gz",
        executableName: "zigar",
    }),
    "linux:arm64": Object.freeze({
        platform: "linux",
        arch: "arm64",
        archiveName: "zigar-aarch64-linux-musl.tar.gz",
        executableName: "zigar",
    }),
    "darwin:x64": Object.freeze({
        platform: "darwin",
        arch: "x64",
        archiveName: "zigar-x86_64-macos.tar.gz",
        executableName: "zigar",
    }),
    "darwin:arm64": Object.freeze({
        platform: "darwin",
        arch: "arm64",
        archiveName: "zigar-aarch64-macos.tar.gz",
        executableName: "zigar",
    }),
    "win32:x64": Object.freeze({
        platform: "win32",
        arch: "x64",
        archiveName: "zigar-x86_64-windows.tar.gz",
        executableName: "zigar.exe",
    }),
});
class UnsupportedTargetError extends Error {
    code;
    platform;
    arch;
    constructor(platform, arch) {
        super(`Unsupported zigar host target: ${platform}/${arch}`);
        this.name = "UnsupportedTargetError";
        this.code = "ERR_ZIGAR_UNSUPPORTED_TARGET";
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
