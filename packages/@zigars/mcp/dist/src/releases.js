"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.GITHUB_REPOSITORY = void 0;
exports.releaseTag = releaseTag;
exports.releaseBaseUrl = releaseBaseUrl;
exports.releaseAssetUrl = releaseAssetUrl;
exports.checksumUrl = checksumUrl;
exports.GITHUB_REPOSITORY = "oly-wan-kenobi/zigars";
const VERSION_PATTERN = /^[0-9A-Za-z.+-]+$/;
function releaseTag(version) {
    if (typeof version !== "string" || version.length === 0) {
        throw new TypeError("version must be a non-empty string");
    }
    if (!VERSION_PATTERN.test(version)) {
        throw new TypeError("version must match /^[0-9A-Za-z.+-]+$/");
    }
    return `v${version}`;
}
function encodeRepository(repository) {
    if (typeof repository !== "string" || repository.length === 0) {
        throw new TypeError("repository must be a non-empty string");
    }
    return repository
        .split("/")
        .map((segment) => encodeURIComponent(segment))
        .join("/");
}
function releaseBaseUrl(version, options = {}) {
    const repository = encodeRepository(options.repository ?? exports.GITHUB_REPOSITORY);
    return `https://github.com/${repository}/releases/download/${releaseTag(version)}`;
}
function releaseAssetUrl(version, assetName, options = {}) {
    if (typeof assetName !== "string" || assetName.length === 0) {
        throw new TypeError("assetName must be a non-empty string");
    }
    return `${releaseBaseUrl(version, options)}/${encodeURIComponent(assetName)}`;
}
function checksumUrl(version, options = {}) {
    return releaseAssetUrl(version, "zigars-checksums.txt", options);
}
