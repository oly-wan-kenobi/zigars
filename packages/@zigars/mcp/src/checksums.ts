import crypto from "node:crypto";

export interface ChecksumErrorOptions {
  code?: string;
  archiveName?: string;
}

export class ChecksumError extends Error {
  code: string;
  archiveName?: string;

  constructor(message: string, options: ChecksumErrorOptions = {}) {
    super(message);
    this.name = "ChecksumError";
    this.code = options.code ?? "ERR_ZIGARS_CHECKSUM";
    this.archiveName = options.archiveName;
  }
}

export function parseChecksums(text: string): Map<string, string> {
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

export function checksumForArchive(entries: Map<string, string>, archiveName: string): string {
  const checksum = entries.get(archiveName);
  if (!checksum) {
    throw new ChecksumError(`Missing checksum for ${archiveName}`, {
      code: "ERR_ZIGARS_CHECKSUM_MISSING",
      archiveName,
    });
  }
  return checksum;
}

export function sha256(buffer: crypto.BinaryLike): string {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

export function verifySha256(buffer: crypto.BinaryLike, expected: string, archiveName: string): string {
  const actual = sha256(buffer);
  if (actual !== expected.toLowerCase()) {
    throw new ChecksumError(
      `Checksum mismatch for ${archiveName}: expected ${expected.toLowerCase()}, got ${actual}`,
      {
        code: "ERR_ZIGARS_CHECKSUM_MISMATCH",
        archiveName,
      },
    );
  }
  return actual;
}
