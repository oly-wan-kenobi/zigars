#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

fail() {
  printf 'real-zls-conformance: %s\n' "$*" >&2
  exit 1
}

resolve_executable() {
  local value="$1"
  local label="$2"
  if [[ "$value" == */* ]]; then
    [[ -x "$value" ]] || fail "$label is not executable: $value"
    local dir
    dir="$(cd "$(dirname "$value")" && pwd -P)"
    printf '%s/%s\n' "$dir" "$(basename "$value")"
    return
  fi
  command -v "$value" || fail "$label was not found on PATH: $value"
}

command -v python3 >/dev/null || fail "python3 is required for response validation"

zigars_binary="${ZIGARS_BINARY:-zig-out/bin/zigars}"
if [[ "${ZIGARS_SKIP_BUILD:-0}" != "1" ]]; then
  zig build -Doptimize=ReleaseSafe
elif [[ ! -x "$zigars_binary" ]]; then
  zig build -Doptimize=ReleaseSafe
fi

zigars_binary="$(resolve_executable "$zigars_binary" zigars)"
zig_path="$(resolve_executable "${ZIGARS_ZIG_PATH:-zig}" zig)"
zls_path="$(resolve_executable "${ZIGARS_ZLS_PATH:-zls}" zls)"

report_dir="${ZIGARS_ZLS_CONFORMANCE_REPORT_DIR:-.zigars-cache/zls-conformance}"
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd -P)"

workspace="$(mktemp -d "${TMPDIR:-/tmp}/zigars-zls-conformance.XXXXXX")"
cleanup() {
  if [[ "${ZIGARS_KEEP_CONFORMANCE_WORKSPACE:-0}" != "1" ]]; then
    rm -rf "$workspace"
  else
    printf 'real-zls-conformance: kept workspace %s\n' "$workspace" >&2
  fi
}
trap cleanup EXIT

mkdir -p "$workspace/src"
cat >"$workspace/src/main.zig" <<'ZIG'
const std = @import("std");

pub const PublicThing = struct {
    value: u32,

    pub fn answer(self: PublicThing) u32 {
        return self.value + 1;
    }
};

pub fn main() void {
    const thing = PublicThing{ .value = 41 };
    std.debug.print("{d}\n", .{thing.answer()});
}
ZIG

cat >"$workspace/build.zig" <<'ZIG'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "zigars-zls-conformance-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        }),
    });
    b.installArtifact(exe);
}
ZIG

stdout_path="$report_dir/stdout.jsonl"
stderr_path="$report_dir/stderr.log"
report_path="$report_dir/report.json"
summary_path="$report_dir/summary.md"

ZIGARS_BINARY="$zigars_binary" \
ZIGARS_WORKSPACE="$workspace" \
ZIGARS_ZIG_PATH="$zig_path" \
ZIGARS_ZLS_PATH="$zls_path" \
ZIGARS_STDOUT_PATH="$stdout_path" \
ZIGARS_STDERR_PATH="$stderr_path" \
ZIGARS_REPORT_PATH="$report_path" \
ZIGARS_SUMMARY_PATH="$summary_path" \
ZIGARS_BACKEND_TIMEOUT_MS="${ZIGARS_BACKEND_TIMEOUT_MS:-20000}" \
ZIGARS_CONFORMANCE_TIMEOUT_SECONDS="${ZIGARS_CONFORMANCE_TIMEOUT_SECONDS:-90}" \
python3 <<'PY'
import hashlib
import json
import os
import pathlib
import platform
import selectors
import subprocess
import sys
import time


def fail(message):
    print(f"real-zls-conformance: {message}", file=sys.stderr)
    sys.exit(1)


workspace = pathlib.Path(os.environ["ZIGARS_WORKSPACE"])
stdout_path = pathlib.Path(os.environ["ZIGARS_STDOUT_PATH"])
stderr_path = pathlib.Path(os.environ["ZIGARS_STDERR_PATH"])
report_path = pathlib.Path(os.environ["ZIGARS_REPORT_PATH"])
summary_path = pathlib.Path(os.environ["ZIGARS_SUMMARY_PATH"])
backend_timeout_ms = int(os.environ["ZIGARS_BACKEND_TIMEOUT_MS"])
timeout_seconds = int(os.environ["ZIGARS_CONFORMANCE_TIMEOUT_SECONDS"])


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def probe(argv):
    result = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    return {
        "argv": argv,
        "returncode": result.returncode,
        "stdout": result.stdout.strip()[:4096],
        "stderr": result.stderr.strip()[:4096],
    }


try:
    source_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
except Exception:
    source_commit = os.environ.get("GITHUB_SHA", "unavailable")

source_metadata = {
    "commit": source_commit,
    "source_commit": source_commit,
}

main_source = (workspace / "src/main.zig").read_text()
formatted_source = subprocess.check_output([os.environ["ZIGARS_ZIG_PATH"], "fmt", "--stdin"], input=main_source, text=True)

requests = [
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "zigars-real-zls-conformance", "version": "0"},
        },
    },
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {"name": "zig_document_open", "arguments": {"file": "src/main.zig", "content": main_source}},
    },
    {
        "jsonrpc": "2.0",
        "id": 4,
        "method": "tools/call",
        "params": {"name": "zig_document_symbols", "arguments": {"file": "src/main.zig", "content": main_source}},
    },
    {
        "jsonrpc": "2.0",
        "id": 5,
        "method": "tools/call",
        "params": {"name": "zig_hover", "arguments": {"file": "src/main.zig", "content": main_source, "line": 10, "character": 18}},
    },
    {
        "jsonrpc": "2.0",
        "id": 6,
        "method": "tools/call",
        "params": {"name": "zig_diagnostics", "arguments": {"file": "src/main.zig", "content": main_source}},
    },
    {
        "jsonrpc": "2.0",
        "id": 7,
        "method": "tools/call",
        "params": {"name": "zig_diagnostics_all", "arguments": {"file": "src/main.zig", "content": main_source}},
    },
    {
        "jsonrpc": "2.0",
        "id": 8,
        "method": "tools/call",
        "params": {"name": "zig_format", "arguments": {"file": "src/main.zig", "content": main_source, "apply": False}},
    },
    {
        "jsonrpc": "2.0",
        "id": 9,
        "method": "tools/call",
        "params": {"name": "zig_format", "arguments": {"file": "src/main.zig", "content": formatted_source, "apply": True}},
    },
    {
        "jsonrpc": "2.0",
        "id": 10,
        "method": "tools/call",
        "params": {"name": "zig_rename", "arguments": {"file": "src/main.zig", "content": formatted_source, "line": 2, "character": 10, "new_name": "RenamedThing", "apply": False}},
    },
    {
        "jsonrpc": "2.0",
        "id": 11,
        "method": "tools/call",
        "params": {"name": "zig_workspace_symbols", "arguments": {"query": "Public", "limit": 10}},
    },
]

stdin = "\n".join(json.dumps(item, separators=(",", ":")) for item in requests) + "\n"
argv = [
    os.environ["ZIGARS_BINARY"],
    "--workspace",
    str(workspace),
    "--transport",
    "stdio",
    "--zig-path",
    os.environ["ZIGARS_ZIG_PATH"],
    "--zls-path",
    os.environ["ZIGARS_ZLS_PATH"],
    "--timeout-ms",
    str(backend_timeout_ms),
    "--zls-timeout-ms",
    str(backend_timeout_ms),
]

responses = {}
stdout_lines = []
stderr_file = stderr_path.open("w")
proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr_file, text=True, bufsize=1)
try:
    assert proc.stdin is not None
    proc.stdin.write(stdin)
    proc.stdin.close()
    proc.stdin = None

    selector = selectors.DefaultSelector()
    assert proc.stdout is not None
    selector.register(proc.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout_seconds
    expected_ids = set(range(1, 12))
    while not expected_ids.issubset(responses.keys()):
        if time.monotonic() > deadline:
            proc.kill()
            proc.wait(timeout=5)
            stdout_path.write_text("".join(stdout_lines))
            fail(f"zigars stdio run timed out after {timeout_seconds}s; stdout saved to {stdout_path}, stderr saved to {stderr_path}")
        events = selector.select(timeout=0.2)
        if not events:
            if proc.poll() is not None:
                break
            continue
        for key, _ in events:
            raw_line = key.fileobj.readline()
            if raw_line == "":
                selector.unregister(key.fileobj)
                continue
            stdout_lines.append(raw_line)
            raw = raw_line.strip()
            if not raw:
                continue
            message = json.loads(raw)
            response_id = message.get("id")
            if response_id is not None:
                responses[response_id] = message
finally:
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    if proc.stdout is not None:
        stdout_lines.extend(proc.stdout.readlines())
    stderr_file.close()

stdout_path.write_text("".join(stdout_lines))

for response_id in range(1, 12):
    if response_id not in responses:
        fail(f"missing JSON-RPC response id {response_id}; stdout saved to {stdout_path}")
    if "error" in responses[response_id]:
        fail(f"JSON-RPC response id {response_id} returned error: {responses[response_id]['error']}")

tools = {tool.get("name") for tool in responses[2]["result"].get("tools", [])}
required_tools = {
    "zig_document_open",
    "zig_document_symbols",
    "zig_hover",
    "zig_diagnostics",
    "zig_diagnostics_all",
    "zig_format",
    "zig_rename",
    "zig_workspace_symbols",
}
missing = sorted(required_tools - tools)
if missing:
    fail(f"tools/list missed required ZLS tools: {missing}")


def payload(response_id):
    result = responses[response_id]["result"]
    if result.get("isError"):
        fail(f"tool response id {response_id} returned isError=true: {json.dumps(result, separators=(',', ':'))}")
    if "structuredContent" in result:
        body = result["structuredContent"]
        return body, json.dumps(body, separators=(",", ":"))
    texts = [
        item.get("text", "")
        for item in result.get("content", [])
        if isinstance(item, dict) and item.get("type") == "text"
    ]
    joined = "\n".join(texts)
    for text in texts:
        try:
            return json.loads(text), text
        except json.JSONDecodeError:
            pass
    return result, joined


scenario_results = []

for response_id, name, marker in [
    (3, "zig_document_open", "zig_document_open"),
    (4, "zig_document_symbols", "textDocument/documentSymbol"),
    (5, "zig_hover", "textDocument/hover"),
    (6, "zig_diagnostics", "diagnostics"),
    (7, "zig_diagnostics_all", "ast-check"),
    (8, "zig_format_preview", "textDocument/formatting"),
    (9, "zig_format_apply", "apply"),
    (10, "zig_rename_preview", "textDocument/rename"),
    (11, "zig_workspace_symbols", "workspace/symbol"),
]:
    body, text = payload(response_id)
    status = "passed"
    if response_id in (10, 11) and ("unsupported_capability" in text or "zls_unavailable" in text):
        status = "unsupported"
    elif marker not in text and response_id not in (3, 6, 9):
        fail(f"{name} did not include expected marker {marker!r}")
    scenario_results.append({
        "name": name,
        "backend": "zls",
        "backends": ["zls"],
        "tool": name.removesuffix("_preview").removesuffix("_apply"),
        "response_id": response_id,
        "status": status,
        "required_marker": marker,
        "evidence_paths": [str(stdout_path), str(stderr_path)],
        "payload_kind": body.get("kind") if isinstance(body, dict) else None,
    })

applied_source = (workspace / "src/main.zig").read_text()
if applied_source != formatted_source:
    fail("zig_format apply did not leave the fixture with the expected formatted content")

report = {
    "kind": "zigars_real_zls_conformance_report",
    "schema_version": 2,
    "result": "passed",
    "source_commit": source_commit,
    "source": source_metadata,
    "generated_unix": int(time.time()),
    "platform": {
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "python": platform.python_version(),
    },
    "workspace": str(workspace),
    "timeout_ms": backend_timeout_ms,
    "backends": {
        "zigars": {
            "path": os.environ["ZIGARS_BINARY"],
            "sha256": sha256_file(os.environ["ZIGARS_BINARY"]),
            "version_probe": probe([os.environ["ZIGARS_BINARY"], "--version"]),
        },
        "zig": {
            "path": os.environ["ZIGARS_ZIG_PATH"],
            "sha256": sha256_file(os.environ["ZIGARS_ZIG_PATH"]),
            "version_probe": probe([os.environ["ZIGARS_ZIG_PATH"], "version"]),
        },
        "zls": {
            "path": os.environ["ZIGARS_ZLS_PATH"],
            "sha256": sha256_file(os.environ["ZIGARS_ZLS_PATH"]),
            "version_probe": probe([os.environ["ZIGARS_ZLS_PATH"], "--version"]),
        },
    },
    "stdio": {
        "stdout": str(stdout_path),
        "stderr": str(stderr_path),
        "response_count": len(responses),
    },
    "scenarios": scenario_results,
}
report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

summary = [
    "# Zigars Real ZLS Conformance",
    "",
    "Result: passed",
    f"Source commit: `{source_commit}`",
    f"Platform: `{platform.system()} {platform.release()} {platform.machine()}`",
    f"Report: `{report_path}`",
    "",
    "## Backends",
    "",
]
for name, entry in report["backends"].items():
    probe_result = entry["version_probe"]
    output = probe_result.get("stdout") or probe_result.get("stderr") or ""
    first_line = output.splitlines()[0] if output else ""
    summary.append(f"- {name}: `{entry['path']}` sha256 `{entry['sha256']}` {first_line}")
summary.extend([
    "",
    "## Scenarios",
    "",
    "| Scenario | Status | Evidence |",
    "|---|---|---|",
])
for scenario in scenario_results:
    summary.append(f"| `{scenario['name']}` | {scenario['status']} | response id {scenario['response_id']}, marker `{scenario['required_marker']}` |")
summary_path.write_text("\n".join(summary) + "\n")

print("real-zls-conformance: real ZLS scenarios passed")
print(f"real-zls-conformance: report {report_path}")
print(f"real-zls-conformance: summary {summary_path}")
PY
