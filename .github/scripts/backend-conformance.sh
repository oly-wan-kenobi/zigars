#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

fail() {
  printf 'backend-conformance: %s\n' "$*" >&2
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

zigar_binary="${ZIGAR_BINARY:-zig-out/bin/zigar}"
if [[ "${ZIGAR_SKIP_BUILD:-0}" != "1" ]]; then
  zig build -Doptimize=ReleaseSafe
elif [[ ! -x "$zigar_binary" ]]; then
  zig build -Doptimize=ReleaseSafe
fi

zigar_binary="$(resolve_executable "$zigar_binary" zigar)"
zig_path="$(resolve_executable "${ZIGAR_ZIG_PATH:-zig}" zig)"
zls_path="$(resolve_executable "${ZIGAR_ZLS_PATH:-zls}" zls)"
zwanzig_path="$(resolve_executable "${ZIGAR_ZWANZIG_PATH:-zwanzig}" zwanzig)"
zflame_path="$(resolve_executable "${ZIGAR_ZFLAME_PATH:-zflame}" zflame)"
diff_folded_path="$(resolve_executable "${ZIGAR_DIFF_FOLDED_PATH:-diff-folded}" diff-folded)"

command -v python3 >/dev/null || fail "python3 is required for response validation"

report_dir="${ZIGAR_CONFORMANCE_REPORT_DIR:-.zigar-cache/backend-conformance}"
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd -P)"

workspace="$(mktemp -d "${TMPDIR:-/tmp}/zigar-backend-conformance.XXXXXX")"
cleanup() {
  if [[ "${ZIGAR_KEEP_CONFORMANCE_WORKSPACE:-0}" != "1" ]]; then
    rm -rf "$workspace"
  else
    printf 'backend-conformance: kept workspace %s\n' "$workspace" >&2
  fi
}
trap cleanup EXIT

mkdir -p "$workspace/src"
cat >"$workspace/src/main.zig" <<'ZIG'
const std = @import("std");

pub const PublicThing = struct {
    pub fn answer() u32 {
        return 42;
    }
};

pub fn main() void {
    const value = PublicThing.answer();
    std.debug.print("{d}\n", .{value});
}
ZIG

cat >"$workspace/build.zig" <<'ZIG'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "zigar-conformance-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        }),
    });
    b.installArtifact(exe);
}
ZIG

cat >"$workspace/stacks.folded" <<'EOF'
root;main;work 7
root;main;idle 2
EOF
cat >"$workspace/before.folded" <<'EOF'
root;main;old 3
EOF
cat >"$workspace/after.folded" <<'EOF'
root;main;new 5
EOF

stdout_path="$report_dir/stdout.jsonl"
stderr_path="$report_dir/stderr.log"
report_path="$report_dir/report.json"
summary_path="$report_dir/summary.md"

printf 'backend-conformance: workspace %s\n' "$workspace"
printf 'backend-conformance: report %s\n' "$report_path"
printf 'backend-conformance: zigar %s\n' "$zigar_binary"
printf 'backend-conformance: zig %s\n' "$zig_path"
printf 'backend-conformance: zls %s\n' "$zls_path"
printf 'backend-conformance: zwanzig %s\n' "$zwanzig_path"
printf 'backend-conformance: zflame %s\n' "$zflame_path"
printf 'backend-conformance: diff-folded %s\n' "$diff_folded_path"

ZIGAR_BINARY="$zigar_binary" \
ZIGAR_WORKSPACE="$workspace" \
ZIGAR_ZIG_PATH="$zig_path" \
ZIGAR_ZLS_PATH="$zls_path" \
ZIGAR_ZWANZIG_PATH="$zwanzig_path" \
ZIGAR_ZFLAME_PATH="$zflame_path" \
ZIGAR_DIFF_FOLDED_PATH="$diff_folded_path" \
ZIGAR_STDOUT_PATH="$stdout_path" \
ZIGAR_STDERR_PATH="$stderr_path" \
ZIGAR_REPORT_PATH="$report_path" \
ZIGAR_SUMMARY_PATH="$summary_path" \
ZIGAR_BACKEND_TIMEOUT_MS="${ZIGAR_BACKEND_TIMEOUT_MS:-20000}" \
ZIGAR_CONFORMANCE_TIMEOUT_SECONDS="${ZIGAR_CONFORMANCE_TIMEOUT_SECONDS:-90}" \
python3 <<'PY'
import hashlib
import json
import os
import platform
import pathlib
import selectors
import subprocess
import sys
import time


def fail(message):
    print(f"backend-conformance: {message}", file=sys.stderr)
    sys.exit(1)


workspace = pathlib.Path(os.environ["ZIGAR_WORKSPACE"])
stdout_path = pathlib.Path(os.environ["ZIGAR_STDOUT_PATH"])
stderr_path = pathlib.Path(os.environ["ZIGAR_STDERR_PATH"])
report_path = pathlib.Path(os.environ["ZIGAR_REPORT_PATH"])
summary_path = pathlib.Path(os.environ["ZIGAR_SUMMARY_PATH"])
backend_timeout_ms = int(os.environ["ZIGAR_BACKEND_TIMEOUT_MS"])
timeout_seconds = int(os.environ["ZIGAR_CONFORMANCE_TIMEOUT_SECONDS"])
claimed_backends = [
    item.strip()
    for item in os.environ.get("ZIGAR_CLAIMED_BACKENDS", "zls,zwanzig,zflame,diff_folded").split(",")
    if item.strip()
]

backend_specs = {
    "zigar": {
        "path": os.environ["ZIGAR_BINARY"],
        "version_argv": [os.environ["ZIGAR_BINARY"], "--version"],
    },
    "zig": {
        "path": os.environ["ZIGAR_ZIG_PATH"],
        "version_argv": [os.environ["ZIGAR_ZIG_PATH"], "version"],
    },
    "zls": {
        "path": os.environ["ZIGAR_ZLS_PATH"],
        "version_argv": [os.environ["ZIGAR_ZLS_PATH"], "--version"],
    },
    "zwanzig": {
        "path": os.environ["ZIGAR_ZWANZIG_PATH"],
        "version_argv": [os.environ["ZIGAR_ZWANZIG_PATH"], "--help"],
    },
    "zflame": {
        "path": os.environ["ZIGAR_ZFLAME_PATH"],
        "version_argv": [os.environ["ZIGAR_ZFLAME_PATH"], "--help"],
    },
    "diff_folded": {
        "path": os.environ["ZIGAR_DIFF_FOLDED_PATH"],
        "version_argv": [os.environ["ZIGAR_DIFF_FOLDED_PATH"], "--help"],
    },
}


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_probe(argv):
    try:
        result = subprocess.run(
            argv,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        return {
            "argv": argv,
            "returncode": result.returncode,
            "stdout": result.stdout.strip()[:4096],
            "stderr": result.stderr.strip()[:4096],
        }
    except Exception as exc:
        return {
            "argv": argv,
            "error": type(exc).__name__,
            "message": str(exc),
        }


backend_evidence = {}
for name, spec in backend_specs.items():
    path = pathlib.Path(spec["path"])
    entry = {
        "path": str(path),
        "sha256": sha256_file(path),
        "version_probe": run_probe(spec["version_argv"]),
    }
    backend_evidence[name] = entry

for backend in claimed_backends:
    if backend not in backend_evidence:
        fail(f"claimed backend is not part of the conformance report: {backend}")

try:
    source_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
except Exception:
    source_commit = os.environ.get("GITHUB_SHA", "unavailable")

requests = [
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "zigar-backend-conformance", "version": "0"},
        },
    },
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {
            "name": "zigar_doctor",
            "arguments": {"probe_backends": True, "timeout_ms": backend_timeout_ms},
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 4,
        "method": "tools/call",
        "params": {
            "name": "zig_document_symbols",
            "arguments": {"file": "src/main.zig"},
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 5,
        "method": "tools/call",
        "params": {"name": "zig_lint_rules", "arguments": {}},
    },
    {
        "jsonrpc": "2.0",
        "id": 6,
        "method": "tools/call",
        "params": {
            "name": "zig_flamegraph",
            "arguments": {
                "format": "recursive",
                "input": "stacks.folded",
                "output": "profile.svg",
                "title": "backend conformance",
            },
        },
    },
    {
        "jsonrpc": "2.0",
        "id": 7,
        "method": "tools/call",
        "params": {
            "name": "zig_flamegraph_diff",
            "arguments": {
                "before": "before.folded",
                "after": "after.folded",
                "output": "diff.svg",
                "title": "backend conformance diff",
            },
        },
    },
]

stdin = "\n".join(json.dumps(item, separators=(",", ":")) for item in requests) + "\n"
argv = [
    os.environ["ZIGAR_BINARY"],
    "--workspace",
    str(workspace),
    "--transport",
    "stdio",
    "--zig-path",
    os.environ["ZIGAR_ZIG_PATH"],
    "--zls-path",
    os.environ["ZIGAR_ZLS_PATH"],
    "--zwanzig-path",
    os.environ["ZIGAR_ZWANZIG_PATH"],
    "--zflame-path",
    os.environ["ZIGAR_ZFLAME_PATH"],
    "--diff-folded-path",
    os.environ["ZIGAR_DIFF_FOLDED_PATH"],
    "--timeout-ms",
    str(backend_timeout_ms),
    "--zls-timeout-ms",
    str(backend_timeout_ms),
]

responses = {}
stdout_lines = []
stderr_file = stderr_path.open("w")
proc = subprocess.Popen(
    argv,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=stderr_file,
    text=True,
    bufsize=1,
)
try:
    assert proc.stdin is not None
    proc.stdin.write(stdin)
    proc.stdin.close()
    proc.stdin = None

    selector = selectors.DefaultSelector()
    assert proc.stdout is not None
    selector.register(proc.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout_seconds
    expected_ids = set(range(1, 8))
    line_index = 0
    while not expected_ids.issubset(responses.keys()):
        if time.monotonic() > deadline:
            proc.kill()
            proc.wait(timeout=5)
            stdout_path.write_text("".join(stdout_lines))
            fail(f"zigar stdio run timed out after {timeout_seconds}s; stdout saved to {stdout_path}, stderr saved to {stderr_path}")
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
            line_index += 1
            raw = raw_line.strip()
            if not raw:
                continue
            try:
                message = json.loads(raw)
            except json.JSONDecodeError as exc:
                stdout_path.write_text("".join(stdout_lines))
                fail(f"stdout line {line_index} is not JSON: {exc}")
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

for index, raw in enumerate(stdout_lines, start=1):
    raw = raw.strip()
    if not raw:
        continue
    try:
        message = json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"stdout line {index} is not JSON: {exc}")
    response_id = message.get("id")
    if response_id is not None:
        responses[response_id] = message

for response_id in range(1, 8):
    if response_id not in responses:
        fail(f"missing JSON-RPC response id {response_id}; stdout saved to {stdout_path}")
    if "error" in responses[response_id]:
        fail(f"JSON-RPC response id {response_id} returned error: {responses[response_id]['error']}")

tools_result = responses[2]["result"]
tool_names = {tool.get("name") for tool in tools_result.get("tools", [])}
for tool in ("zigar_doctor", "zig_document_symbols", "zig_lint_rules", "zig_flamegraph", "zig_flamegraph_diff"):
    if tool not in tool_names:
        fail(f"tools/list did not include {tool}")


def tool_payload(response_id):
    result = responses[response_id]["result"]
    if result.get("isError"):
        fail(f"tool response id {response_id} returned isError=true: {json.dumps(result, separators=(',', ':'))}")
    if "structuredContent" in result:
        payload = result["structuredContent"]
        return payload, json.dumps(payload, separators=(",", ":"))
    texts = [
        item.get("text", "")
        for item in result.get("content", [])
        if isinstance(item, dict) and item.get("type") == "text"
    ]
    for text in texts:
        try:
            return json.loads(text), text
        except json.JSONDecodeError:
            pass
    return result, json.dumps(result, separators=(",", ":"))


doctor, _ = tool_payload(3)
if doctor.get("kind") != "zigar_doctor":
    fail("zigar_doctor returned an unexpected payload")
checks = {check.get("name"): check for check in doctor.get("checks", []) if isinstance(check, dict)}
for probe in ("zig_probe", "zls_probe", "zwanzig_probe", "zflame_probe", "diff_folded_probe"):
    check = checks.get(probe)
    if not check:
        fail(f"zigar_doctor did not report {probe}")
    if check.get("ok") is not True:
        fail(f"{probe} failed: {check.get('status')} - {check.get('resolution')}")

_, symbols_text = tool_payload(4)
if "textDocument/documentSymbol" not in symbols_text:
    fail("zig_document_symbols did not exercise the ZLS documentSymbol request")
if "PublicThing" not in symbols_text and "main" not in symbols_text:
    fail("zig_document_symbols returned no expected fixture symbol names")

_, lint_rules_text = tool_payload(5)
if "zwanzig" not in lint_rules_text:
    fail("zig_lint_rules did not include zwanzig backend metadata")
if '"ok":false' in lint_rules_text:
    fail("zig_lint_rules command reported ok=false")

flame, flame_text = tool_payload(6)
if flame.get("kind") != "zig_flamegraph":
    fail("zig_flamegraph returned an unexpected payload")
if "zflame" not in flame_text:
    fail("zig_flamegraph did not include zflame backend metadata")

diff, diff_text = tool_payload(7)
if diff.get("kind") != "zig_flamegraph_diff":
    fail("zig_flamegraph_diff returned an unexpected payload")
if "diff-folded" not in diff_text:
    fail("zig_flamegraph_diff did not include diff-folded backend metadata")

for rel in ("profile.svg", "diff.svg"):
    path = workspace / rel
    if not path.exists():
        fail(f"expected artifact was not written: {rel}")
    text = path.read_text(errors="replace").lstrip()
    if not (text.startswith("<svg") or (text.startswith("<?xml") and "<svg" in text[:1024])):
        fail(f"expected {rel} to be an SVG artifact")

artifacts = {}
for rel in ("profile.svg", "diff.svg"):
    path = workspace / rel
    artifacts[rel] = {
        "path": str(path),
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
    }

tool_evidence = {
    "zigar_doctor": {"response_id": 3, "probe_checks": checks},
    "zig_document_symbols": {
        "response_id": 4,
        "required_markers": ["textDocument/documentSymbol", "PublicThing or main"],
    },
    "zig_lint_rules": {"response_id": 5, "required_markers": ["zwanzig"]},
    "zig_flamegraph": {"response_id": 6, "artifact": "profile.svg"},
    "zig_flamegraph_diff": {"response_id": 7, "artifact": "diff.svg"},
}

compatibility_matrix = [
    {
        "backend": "zig",
        "claim": "required",
        "status": "passed",
        "evidence": "zigar_doctor zig_probe and command-backed fixture execution",
    },
    {
        "backend": "zls",
        "claim": "claimed" if "zls" in claimed_backends else "not_claimed",
        "status": "passed" if "zls" in claimed_backends else "observed",
        "evidence": "zigar_doctor zls_probe and zig_document_symbols textDocument/documentSymbol",
    },
    {
        "backend": "zwanzig",
        "claim": "claimed" if "zwanzig" in claimed_backends else "not_claimed",
        "status": "passed" if "zwanzig" in claimed_backends else "observed",
        "evidence": "zig_lint_rules metadata and successful zwanzig probe",
    },
    {
        "backend": "zflame",
        "claim": "claimed" if "zflame" in claimed_backends else "not_claimed",
        "status": "passed" if "zflame" in claimed_backends else "observed",
        "evidence": "zig_flamegraph SVG render and artifact hash",
    },
    {
        "backend": "diff_folded",
        "claim": "claimed" if "diff_folded" in claimed_backends else "not_claimed",
        "status": "passed" if "diff_folded" in claimed_backends else "observed",
        "evidence": "zig_flamegraph_diff diff-folded intermediate and SVG render",
    },
]

report = {
    "kind": "zigar_backend_conformance_report",
    "schema_version": 1,
    "generated_unix": int(time.time()),
    "source_commit": source_commit,
    "platform": {
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "python": platform.python_version(),
    },
    "workspace": str(workspace),
    "timeout_ms": backend_timeout_ms,
    "claimed_backends": claimed_backends,
    "stdio": {
        "stdout": str(stdout_path),
        "stderr": str(stderr_path),
        "response_count": len(responses),
    },
    "backends": backend_evidence,
    "compatibility_matrix": compatibility_matrix,
    "tool_evidence": tool_evidence,
    "artifacts": artifacts,
    "result": "passed",
}
report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

summary_lines = [
    "# Zigar Backend Conformance",
    "",
    "Result: passed",
    f"Source commit: `{source_commit}`",
    f"Platform: `{platform.system()} {platform.release()} {platform.machine()}`",
    f"Report: `{report_path}`",
    f"Workspace: `{workspace}`",
    "",
    "## Backends",
    "",
]
for name, entry in backend_evidence.items():
    probe = entry["version_probe"]
    output = probe.get("stdout") or probe.get("stderr") or probe.get("message", "")
    first_line = output.splitlines()[0] if output else ""
    summary_lines.append(f"- {name}: `{entry['path']}` sha256 `{entry['sha256']}` {first_line}")
summary_lines.extend([
    "",
    "## Compatibility Matrix",
    "",
    "| Backend | Claim | Status | Evidence |",
    "|---|---|---|---|",
])
for row in compatibility_matrix:
    summary_lines.append(f"| `{row['backend']}` | {row['claim']} | {row['status']} | {row['evidence']} |")
summary_lines.extend([
    "",
    "## Tool Evidence",
    "",
    "- `zigar_doctor` reported successful probes for zig, zls, zwanzig, zflame, and diff-folded.",
    "- `zig_document_symbols` exercised `textDocument/documentSymbol` and returned fixture symbols.",
    "- `zig_lint_rules` exercised zwanzig metadata.",
    "- `zig_flamegraph` and `zig_flamegraph_diff` wrote SVG artifacts.",
    "",
    "## Artifacts",
    "",
])
for name, entry in artifacts.items():
    summary_lines.append(f"- {name}: {entry['bytes']} bytes sha256 `{entry['sha256']}`")
summary_path.write_text("\n".join(summary_lines) + "\n")

print("backend-conformance: real backend probes and tool calls passed")
print(f"backend-conformance: stdout {stdout_path}")
print(f"backend-conformance: stderr {stderr_path}")
print(f"backend-conformance: report {report_path}")
print(f"backend-conformance: summary {summary_path}")
PY
