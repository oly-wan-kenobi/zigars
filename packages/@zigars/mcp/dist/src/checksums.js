"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.ChecksumError = void 0;
exports.parseChecksums = parseChecksums;
exports.checksumForArchive = checksumForArchive;
exports.sha256 = sha256;
exports.sha256Equals = sha256Equals;
exports.verifySha256 = verifySha256;
const node_crypto_1 = __importDefault(require("node:crypto"));
class ChecksumError extends Error {
    code;
    archiveName;
    constructor(message, options = {}) {
        super(message);
        this.name = "ChecksumError";
        this.code = options.code ?? "ERR_ZIGARS_CHECKSUM";
        this.archiveName = options.archiveName;
    }
}
exports.ChecksumError = ChecksumError;
function parseChecksums(text) {
    if (typeof text !== "string") {
        throw new TypeError("checksum text must be a string");
    }
    const entries = new Map();
    for (const [index, rawLine] of text.split(/\r?\n/).entries()) {
        const line = rawLine.trim();
        if (line.length === 0 || line.startsWith("#")) {
            continue;
        }
        const match = /^([a-fA-F0-9]{64})\s+\*?(.+)$/.exec(line);
        if (!match) {
            throw new ChecksumError(`Invalid checksum line ${index + 1}`, {
                code: "ERR_ZIGARS_CHECKSUM_PARSE",
            });
        }
        entries.set(match[2].trim(), match[1].toLowerCase());
    }
    return entries;
}
function checksumForArchive(entries, archiveName) {
    const checksum = entries.get(archiveName);
    if (!checksum) {
        throw new ChecksumError(`Missing checksum for ${archiveName}`, {
            code: "ERR_ZIGARS_CHECKSUM_MISSING",
            archiveName,
        });
    }
    return checksum;
}
function sha256(buffer) {
    return node_crypto_1.default.createHash("sha256").update(buffer).digest("hex");
}
function sha256Equals(actual, expected) {
    const actualNormalized = normalizeSha256Hex(actual);
    const expectedNormalized = normalizeSha256Hex(expected);
    if (!actualNormalized || !expectedNormalized) {
        return false;
    }
    const actualBytes = Buffer.from(actualNormalized, "hex");
    const expectedBytes = Buffer.from(expectedNormalized, "hex");
    return actualBytes.length === expectedBytes.length && node_crypto_1.default.timingSafeEqual(actualBytes, expectedBytes);
}
function verifySha256(buffer, expected, archiveName) {
    const actual = sha256(buffer);
    const expectedNormalized = expected.toLowerCase();
    if (!sha256Equals(actual, expected)) {
        throw new ChecksumError(`Checksum mismatch for ${archiveName}: expected ${expectedNormalized}, got ${actual}`, {
            code: "ERR_ZIGARS_CHECKSUM_MISMATCH",
            archiveName,
        });
    }
    return actual;
}
function normalizeSha256Hex(value) {
    const normalized = value.toLowerCase();
    return /^[a-f0-9]{64}$/.test(normalized) ? normalized : null;
}
