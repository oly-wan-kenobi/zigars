"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.formatUsage = formatUsage;
exports.run = run;
exports.main = main;
const childProcess = __importStar(require("node:child_process"));
const node_os_1 = __importDefault(require("node:os"));
const args_1 = require("./args");
const install_1 = require("./install");
const targets_1 = require("./targets");
const package_json_1 = __importDefault(require("../package.json"));
function formatUsage() {
    return [
        "Usage: zigar-mcp [zigar arguments...]",
        "",
        "Example:",
        "  zigar-mcp --workspace /absolute/path/to/zig/project",
        "",
        "This npm shim writes diagnostics to stderr only. stdout is reserved for MCP JSON-RPC.",
    ].join("\n");
}
function signalExitCode(signal) {
    if (!signal) {
        return 1;
    }
    const signalNumber = node_os_1.default.constants.signals[signal];
    return typeof signalNumber === "number" ? 128 + signalNumber : 1;
}
function waitForChild(child) {
    return new Promise((resolve, reject) => {
        child.once("error", reject);
        child.once("exit", (code, signal) => {
            resolve(code ?? signalExitCode(signal));
        });
    });
}
async function run(argv, options = {}) {
    const stderr = options.stderr ?? process.stderr;
    const args = Array.isArray(argv) ? argv : [];
    if (args.includes("--help") || args.includes("-h")) {
        stderr.write(`${formatUsage()}\n`);
        return 0;
    }
    if (args.includes("--version")) {
        stderr.write(`${package_json_1.default.version}\n`);
        return 0;
    }
    try {
        const target = (0, targets_1.resolveHostTarget)({
            platform: options.platform,
            arch: options.arch,
        });
        const zigarArgs = (0, args_1.normalizeZigarArgs)(args);
        const executablePath = await (options.installZigar ?? install_1.installZigar)(target, {
            version: package_json_1.default.version,
            cacheRoot: options.cacheRoot,
            env: options.env,
            fetch: options.fetch,
            fsPromises: options.fsPromises,
            platform: options.platform,
            spawnSync: options.spawnSync,
        });
        const child = (options.spawn ?? childProcess.spawn)(executablePath, zigarArgs, {
            shell: false,
            stdio: options.stdio ?? "inherit",
        });
        return await waitForChild(child);
    }
    catch (error) {
        if (error instanceof targets_1.UnsupportedTargetError) {
            stderr.write(`${error.message}\n`);
            return 1;
        }
        stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
        return 1;
    }
}
function main(argv, options) {
    run(argv, options).then((code) => {
        process.exitCode = code;
    }, (error) => {
        const stderr = options?.stderr ?? process.stderr;
        stderr.write(`${error.message}\n`);
        process.exitCode = 1;
    });
}
