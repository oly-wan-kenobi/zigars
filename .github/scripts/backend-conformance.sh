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
if [[ ! -x "$zigar_binary" ]]; then
  zig build -Doptimize=ReleaseSafe
fi

zigar_binary="$(resolve_executable "$zigar_binary" zigar)"
zig_path="$(resolve_executable "${ZIGAR_ZIG_PATH:-zig}" zig)"
zls_path="$(resolve_executable "${ZIGAR_ZLS_PATH:-zls}" zls)"
zwanzig_path="$(resolve_executable "${ZIGAR_ZWANZIG_PATH:-zwanzig}" zwanzig)"
zflame_path="$(resolve_executable "${ZIGAR_ZFLAME_PATH:-zflame}" zflame)"
diff_folded_path="$(resolve_executable "${ZIGAR_DIFF_FOLDED_PATH:-diff-folded}" diff-folded)"

command -v python3 >/dev/null || fail "python3 is required for response validation"

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

stdout_path="$workspace/stdout.jsonl"
stderr_path="$workspace/stderr.log"

printf 'backend-conformance: workspace %s\n' "$workspace"
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
ZIGAR_BACKEND_TIMEOUT_MS="${ZIGAR_BACKEND_TIMEOUT_MS:-20000}" \
ZIGAR_CONFORMANCE_TIMEOUT_SECONDS="${ZIGAR_CONFORMANCE_TIMEOUT_SECONDS:-90}" \
python3 <<'PY'
import json
import os
import pathlib
import subprocess
import sys


def fail(message):
    print(f"backend-conformance: {message}", file=sys.stderr)
    sys.exit(1)


workspace = pathlib.Path(os.environ["ZIGAR_WORKSPACE"])
stdout_path = pathlib.Path(os.environ["ZIGAR_STDOUT_PATH"])
stderr_path = pathlib.Path(os.environ["ZIGAR_STDERR_PATH"])
backend_timeout_ms = int(os.environ["ZIGAR_BACKEND_TIMEOUT_MS"])
timeout_seconds = int(os.environ["ZIGAR_CONFORMANCE_TIMEOUT_SECONDS"])

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

try:
    proc = subprocess.run(
        argv,
        input=stdin,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout_seconds,
    )
except subprocess.TimeoutExpired as exc:
    stdout_path.write_text(exc.stdout or "")
    stderr_path.write_text(exc.stderr or "")
    fail(f"zigar stdio run timed out after {timeout_seconds}s")

stdout_path.write_text(proc.stdout)
stderr_path.write_text(proc.stderr)
if proc.returncode != 0:
    fail(f"zigar exited with status {proc.returncode}; stderr saved to {stderr_path}")

responses = {}
for index, raw in enumerate(proc.stdout.splitlines(), start=1):
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
    prefix = path.read_text(errors="replace")[:32].lstrip()
    if not prefix.startswith("<svg"):
        fail(f"expected {rel} to start with <svg")

print("backend-conformance: real backend probes and tool calls passed")
print(f"backend-conformance: stdout {stdout_path}")
print(f"backend-conformance: stderr {stderr_path}")
PY
