export interface HostTarget {
  platform: NodeJS.Platform;
  arch: NodeJS.Architecture;
  archiveName: string;
  executableName: string;
}

export const TARGETS: Readonly<Record<string, Readonly<HostTarget>>> = Object.freeze({
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

export class UnsupportedTargetError extends Error {
  code: string;
  platform: NodeJS.Platform | string;
  arch: NodeJS.Architecture | string;

  constructor(platform: NodeJS.Platform | string, arch: NodeJS.Architecture | string) {
    super(`Unsupported zigar host target: ${platform}/${arch}`);
    this.name = "UnsupportedTargetError";
    this.code = "ERR_ZIGAR_UNSUPPORTED_TARGET";
    this.platform = platform;
    this.arch = arch;
  }
}

export interface ResolveHostTargetOptions {
  platform?: NodeJS.Platform | string;
  arch?: NodeJS.Architecture | string;
}

export function resolveHostTarget(options: ResolveHostTargetOptions = {}): Readonly<HostTarget> {
  const platform = options.platform ?? process.platform;
  const arch = options.arch ?? process.arch;
  const target = TARGETS[`${platform}:${arch}`];
  if (!target) {
    throw new UnsupportedTargetError(platform, arch);
  }
  return target;
}
