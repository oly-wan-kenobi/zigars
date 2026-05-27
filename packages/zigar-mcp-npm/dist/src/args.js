"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.hasTransport = hasTransport;
exports.normalizeZigarArgs = normalizeZigarArgs;
function hasTransport(args) {
    return args.some((arg) => arg === "--transport" || arg.startsWith("--transport="));
}
function normalizeZigarArgs(args) {
    if (!Array.isArray(args)) {
        throw new TypeError("args must be an array");
    }
    for (const arg of args) {
        if (typeof arg !== "string") {
            throw new TypeError("args must contain only strings");
        }
    }
    if (hasTransport(args)) {
        return [...args];
    }
    return ["--transport", "stdio", ...args];
}
