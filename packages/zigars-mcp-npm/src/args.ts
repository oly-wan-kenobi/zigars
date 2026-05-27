export function hasTransport(args: string[]): boolean {
  return args.some((arg) => arg === "--transport" || arg.startsWith("--transport="));
}

export function normalizeZigarsArgs(args: unknown): string[] {
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
