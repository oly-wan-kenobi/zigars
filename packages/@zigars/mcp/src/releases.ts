export const GITHUB_REPOSITORY = "oly-wan-kenobi/zigars";

export interface ReleaseUrlOptions {
  repository?: string;
}

const VERSION_PATTERN = /^[0-9A-Za-z.+-]+$/;

export function releaseTag(version: string): string {
  if (typeof version !== "string" || version.length === 0) {
    throw new TypeError("version must be a non-empty string");
  }
  if (!VERSION_PATTERN.test(version)) {
    throw new TypeError("version must match /^[0-9A-Za-z.+-]+$/");
  }
  return `v${version}`;
}

function encodeRepository(repository: string): string {
  if (typeof repository !== "string" || repository.length === 0) {
    throw new TypeError("repository must be a non-empty string");
  }
  return repository
    .split("/")
    .map((segment) => encodeURIComponent(segment))
    .join("/");
}

export function releaseBaseUrl(version: string, options: ReleaseUrlOptions = {}): string {
  const repository = encodeRepository(options.repository ?? GITHUB_REPOSITORY);
  return `https://github.com/${repository}/releases/download/${releaseTag(version)}`;
}

export function releaseAssetUrl(version: string, assetName: string, options: ReleaseUrlOptions = {}): string {
  if (typeof assetName !== "string" || assetName.length === 0) {
    throw new TypeError("assetName must be a non-empty string");
  }
  return `${releaseBaseUrl(version, options)}/${encodeURIComponent(assetName)}`;
}

export function checksumUrl(version: string, options: ReleaseUrlOptions = {}): string {
  return releaseAssetUrl(version, "zigars-checksums.txt", options);
}
