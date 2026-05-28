export const GITHUB_REPOSITORY = "oly-wan-kenobi/zigars";

export interface ReleaseUrlOptions {
  repository?: string;
}

export function releaseTag(version: string): string {
  if (typeof version !== "string" || version.length === 0) {
    throw new TypeError("version must be a non-empty string");
  }
  return `v${version}`;
}

export function releaseBaseUrl(version: string, options: ReleaseUrlOptions = {}): string {
  const repository = options.repository ?? GITHUB_REPOSITORY;
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
