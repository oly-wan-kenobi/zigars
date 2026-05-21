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
zls_path="${ZIGAR_ZLS_PATH:-zls}"
zlint_path="${ZIGAR_ZLINT_PATH:-zlint}"
zwanzig_path="${ZIGAR_ZWANZIG_PATH:-zwanzig}"
zflame_path="${ZIGAR_ZFLAME_PATH:-zflame}"
diff_folded_path="${ZIGAR_DIFF_FOLDED_PATH:-diff-folded}"

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
printf 'backend-conformance: zlint %s\n' "$zlint_path"
printf 'backend-conformance: zwanzig %s\n' "$zwanzig_path"
printf 'backend-conformance: zflame %s\n' "$zflame_path"
printf 'backend-conformance: diff-folded %s\n' "$diff_folded_path"
printf 'backend-conformance: claimed backends %s\n' "${ZIGAR_CLAIMED_BACKENDS:-}"

ZIGAR_BINARY="$zigar_binary" \
ZIGAR_WORKSPACE="$workspace" \
ZIGAR_ZIG_PATH="$zig_path" \
ZIGAR_ZLS_PATH="$zls_path" \
ZIGAR_ZLINT_PATH="$zlint_path" \
ZIGAR_ZWANZIG_PATH="$zwanzig_path" \
ZIGAR_ZFLAME_PATH="$zflame_path" \
ZIGAR_DIFF_FOLDED_PATH="$diff_folded_path" \
ZIGAR_STDOUT_PATH="$stdout_path" \
ZIGAR_STDERR_PATH="$stderr_path" \
ZIGAR_REPORT_PATH="$report_path" \
ZIGAR_SUMMARY_PATH="$summary_path" \
ZIGAR_CLAIMED_BACKENDS="${ZIGAR_CLAIMED_BACKENDS:-}" \
ZIGAR_BACKEND_TIMEOUT_MS="${ZIGAR_BACKEND_TIMEOUT_MS:-20000}" \
ZIGAR_CONFORMANCE_TIMEOUT_SECONDS="${ZIGAR_CONFORMANCE_TIMEOUT_SECONDS:-90}" \
python3 <<'PY'
import hashlib
import json
import os
import platform
import pathlib
import selectors
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


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
valid_claimed_backends = {"zls", "zlint", "zwanzig", "zflame", "diff_folded"}
claimed_backends = [
    item.strip().replace("-", "_")
    for item in os.environ.get("ZIGAR_CLAIMED_BACKENDS", "").split(",")
    if item.strip()
]
unknown_claims = sorted(set(claimed_backends) - valid_claimed_backends)

backend_specs = {
    "zigar": {
        "path": os.environ["ZIGAR_BINARY"],
        "required": True,
        "version_args": ["--version"],
    },
    "zig": {
        "path": os.environ["ZIGAR_ZIG_PATH"],
        "required": True,
        "version_args": ["version"],
    },
    "zls": {
        "path": os.environ["ZIGAR_ZLS_PATH"],
        "required": False,
        "version_args": ["--version"],
    },
    "zlint": {
        "path": os.environ["ZIGAR_ZLINT_PATH"],
        "required": False,
        "version_args": ["--help"],
    },
    "zwanzig": {
        "path": os.environ["ZIGAR_ZWANZIG_PATH"],
        "required": False,
        "version_args": ["--help"],
    },
    "zflame": {
        "path": os.environ["ZIGAR_ZFLAME_PATH"],
        "required": False,
        "version_args": ["--help"],
    },
    "diff_folded": {
        "path": os.environ["ZIGAR_DIFF_FOLDED_PATH"],
        "required": False,
        "version_args": ["--help"],
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


def resolve_path(value):
    if "/" in value:
        path = pathlib.Path(value)
        if path.is_file() and os.access(path, os.X_OK):
            return str(path.resolve()), None
        return None, f"not executable: {value}"
    resolved = shutil.which(value)
    if resolved:
        return str(pathlib.Path(resolved).resolve()), None
    return None, f"not found on PATH: {value}"


backend_evidence = {}
for name, spec in backend_specs.items():
    raw_path = spec["path"]
    resolved_path, error = resolve_path(raw_path)
    if spec["required"] and resolved_path is None:
        fail(f"{name} backend is required and {error}")
    entry = {
        "path": raw_path,
        "resolved_path": resolved_path,
        "available": resolved_path is not None,
        "claim": "required" if spec["required"] else ("claimed" if name in claimed_backends else "not_claimed"),
        "required": spec["required"],
    }
    if resolved_path is None:
        entry["availability_error"] = error
        entry["version_probe"] = {"skipped": True, "reason": error}
    else:
        resolved = pathlib.Path(resolved_path)
        entry["sha256"] = sha256_file(resolved)
        entry["version_probe"] = run_probe([resolved_path, *spec["version_args"]])
    backend_evidence[name] = entry

try:
    source_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
except Exception:
    source_commit = os.environ.get("GITHUB_SHA", "unavailable")

source_metadata = {
    "commit": source_commit,
    "source_commit": source_commit,
}


def backend_arg(name):
    entry = backend_evidence[name]
    return entry["resolved_path"] or entry["path"]


artifacts = {}
evidence_artifact_dir = report_path.parent / "artifacts"
evidence_artifact_dir.mkdir(parents=True, exist_ok=True)


def evidence_artifact_key(path, key):
    if key is not None:
        return key
    try:
        return str(path.resolve().relative_to(workspace.resolve()))
    except ValueError:
        return path.name


def workspace_artifact(rel):
    return path_artifact(workspace / rel, rel)


def path_artifact(path, key=None):
    path = pathlib.Path(path)
    key = evidence_artifact_key(path, key)
    if not path.exists():
        raise AssertionError(f"expected artifact was not written: {path}")
    evidence_path = evidence_artifact_dir / key
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, evidence_path)
    artifacts[key] = {
        "path": str(evidence_path),
        "original_path": str(path),
        "bytes": evidence_path.stat().st_size,
        "sha256": sha256_file(evidence_path),
    }
    return artifacts[key]


def scan_dot_artifacts(root):
    root = pathlib.Path(root)
    if not root.exists():
        raise AssertionError(f"graph output directory was not written: {root}")
    dot_files = sorted(path for path in root.rglob("*.dot") if path.is_file())
    if not dot_files:
        raise AssertionError(f"graph output directory has no DOT files: {root}")
    evidence_paths = []
    for path in dot_files:
        text = path.read_text(errors="replace")
        if "digraph" not in text and "graph" not in text:
            raise AssertionError(f"DOT artifact does not look like a graph: {path}")
        evidence_paths.append(path_artifact(path)["path"])
    return evidence_paths


def validate_svg_artifact(rel):
    path = workspace / rel
    artifact = workspace_artifact(rel)
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        raise AssertionError(f"{rel} is not parseable XML/SVG: {exc}") from exc
    if root.tag != "{http://www.w3.org/2000/svg}svg":
        raise AssertionError(f"{rel} root is not an SVG element in the SVG namespace: {root.tag}")
    text = path.read_text(errors="replace").lstrip()
    return {"xml_prologue_present": text.startswith("<?xml"), "root": root.tag, "artifact_path": artifact["path"]}


scenario_results = []
planned_scenarios = {}


def scenario_status_for_success(coverage_required):
    return "passed" if coverage_required else "observed"


def add_scenario_record(record):
    record.setdefault("evidence_paths", [str(stdout_path), str(stderr_path)])
    scenario_results.append(record)
    return record


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
]

next_request_id = 4


def add_tool_scenario(name, backends, tool, arguments, validator, evidence_paths=None):
    global next_request_id
    coverage_required = backends[0] in claimed_backends
    missing = [backend for backend in backends if not backend_evidence[backend]["available"]]
    record = {
        "name": name,
        "backend": backends[0],
        "backends": backends,
        "tool": tool,
        "status": "planned",
        "claim": "claimed" if coverage_required else "not_claimed",
        "coverage_required": coverage_required,
        "evidence_paths": [str(stdout_path), str(stderr_path), *(evidence_paths or [])],
    }
    if missing:
        record["status"] = "unsupported" if coverage_required else "skipped"
        record["reason"] = "; ".join(
            f"{backend}: {backend_evidence[backend].get('availability_error', 'unavailable')}"
            for backend in missing
        )
        add_scenario_record(record)
        return
    request_id = next_request_id
    next_request_id += 1
    record["response_id"] = request_id
    planned_scenarios[request_id] = (record, validator)
    requests.append({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "tools/call",
        "params": {"name": tool, "arguments": arguments},
    })


def validate_zls_symbols(payload, text, scenario):
    if "textDocument/documentSymbol" not in text:
        raise AssertionError("zig_document_symbols did not exercise textDocument/documentSymbol")
    if "PublicThing" not in text and "main" not in text:
        raise AssertionError("zig_document_symbols returned no expected fixture symbol names")
    scenario["required_markers"] = ["textDocument/documentSymbol", "PublicThing or main"]


def command_payload_ok(payload, title):
    if payload.get("kind") != "command":
        raise AssertionError(f"{title} returned unexpected payload kind: {payload.get('kind')}")
    if payload.get("ok") is not True:
        raise AssertionError(f"{title} command reported ok=false")


def validate_zwanzig_json(payload, text, scenario):
    command_payload_ok(payload, "zig_lint")
    if payload.get("backend") != "zwanzig":
        raise AssertionError("zig_lint did not report zwanzig backend metadata")
    stdout = payload.get("stdout", "").strip()
    if not stdout:
        raise AssertionError("zig_lint produced empty JSON stdout")
    try:
        json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise AssertionError(f"zig_lint stdout is not JSON: {exc}") from exc
    scenario["required_markers"] = ["--format", "json", "zwanzig"]


def validate_zlint_json(payload, text, scenario):
    if payload.get("kind") != "zig_zlint":
        raise AssertionError(f"zig_zlint returned unexpected payload kind: {payload.get('kind')}")
    if payload.get("backend") != "zlint":
        raise AssertionError("zig_zlint did not report zlint backend metadata")
    if payload.get("ok") is not True:
        raise AssertionError("zig_zlint reported ok=false")
    if "findings" not in payload or "summary" not in payload:
        raise AssertionError("zig_zlint did not return normalized findings and summary")
    scenario["required_markers"] = ["--format", "json", "zlint"]


def validate_zlint_sarif(payload, text, scenario):
    if payload.get("kind") != "zig_zlint_sarif":
        raise AssertionError(f"zig_zlint_sarif returned unexpected payload kind: {payload.get('kind')}")
    if payload.get("backend") != "zlint":
        raise AssertionError("zig_zlint_sarif did not report zlint backend metadata")
    if payload.get("sarif", {}).get("version") != "2.1.0":
        raise AssertionError("zig_zlint_sarif did not return SARIF 2.1.0")
    scenario["required_markers"] = ["SARIF", "zlint"]


def validate_zlint_rules(payload, text, scenario):
    if payload.get("kind") != "zig_zlint_rules":
        raise AssertionError(f"zig_zlint_rules returned unexpected payload kind: {payload.get('kind')}")
    if payload.get("backend") != "zlint":
        raise AssertionError("zig_zlint_rules did not report zlint backend metadata")
    if "rules" not in payload:
        raise AssertionError("zig_zlint_rules did not return normalized rules")
    scenario["required_markers"] = ["rule metadata or capability fallback", "zlint"]


def validate_zlint_fix_preview(payload, text, scenario):
    if payload.get("kind") != "zig_zlint_fix":
        raise AssertionError(f"zig_zlint_fix returned unexpected payload kind: {payload.get('kind')}")
    if payload.get("backend") != "zlint":
        raise AssertionError("zig_zlint_fix did not report zlint backend metadata")
    if payload.get("apply") is not False or payload.get("requires_apply") is not True:
        raise AssertionError("zig_zlint_fix preview did not enforce apply gate")
    argv = payload.get("argv") or []
    if "--fix" not in argv:
        raise AssertionError("zig_zlint_fix preview did not include --fix argv")
    scenario["required_markers"] = ["--fix", "apply gate", "zlint"]


def validate_zwanzig_sarif(payload, text, scenario):
    command_payload_ok(payload, "zig_lint_sarif")
    if payload.get("backend") != "zwanzig":
        raise AssertionError("zig_lint_sarif did not report zwanzig backend metadata")
    stdout = payload.get("stdout", "").strip()
    if not stdout:
        raise AssertionError("zig_lint_sarif produced empty SARIF stdout")
    try:
        sarif = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise AssertionError(f"zig_lint_sarif stdout is not JSON: {exc}") from exc
    if sarif.get("version") != "2.1.0" and "runs" not in sarif:
        raise AssertionError("zig_lint_sarif stdout does not look like SARIF")
    scenario["required_markers"] = ["--format", "sarif", "zwanzig"]


def validate_zwanzig_rules(payload, text, scenario):
    command_payload_ok(payload, "zig_lint_rules")
    if payload.get("backend") != "zwanzig":
        raise AssertionError("zig_lint_rules did not report zwanzig backend metadata")
    if "--format" not in text and "Usage:" not in text and "fake zwanzig help" not in text:
        raise AssertionError("zig_lint_rules did not include zwanzig help/rule output")
    scenario["required_markers"] = ["zwanzig", "help/rules"]


def validate_zwanzig_graph(payload, text, scenario):
    if payload.get("kind") != "zig_analysis_graphs":
        raise AssertionError(f"zig_analysis_graphs returned unexpected payload kind: {payload.get('kind')}")
    if payload.get("backend") != "zwanzig":
        raise AssertionError("zig_analysis_graphs did not report zwanzig backend metadata")
    output_abs = payload.get("output_abs")
    if not output_abs:
        raise AssertionError("zig_analysis_graphs did not report output_abs")
    dot_files = scan_dot_artifacts(output_abs)
    scenario["artifacts"] = dot_files
    scenario["evidence_paths"].extend(dot_files)
    scenario["required_markers"] = ["zig_analysis_graphs", "DOT"]


def validate_flamegraph(payload, text, scenario):
    if payload.get("kind") != "zig_flamegraph":
        raise AssertionError(f"zig_flamegraph returned unexpected payload kind: {payload.get('kind')}")
    if payload.get("backend") != "zflame":
        raise AssertionError("zig_flamegraph did not report zflame backend metadata")
    if payload.get("input_format") != "recursive":
        raise AssertionError("zig_flamegraph did not report recursive input format")
    svg = validate_svg_artifact("profile.svg")
    scenario["svg_validation"] = svg
    scenario["artifacts"] = [svg["artifact_path"]]
    scenario["evidence_paths"].append(svg["artifact_path"])
    scenario["required_markers"] = ["zflame", "recursive", "structural SVG"]


def validate_diff_flamegraph(payload, text, scenario):
    if payload.get("kind") != "zig_flamegraph_diff":
        raise AssertionError(f"zig_flamegraph_diff returned unexpected payload kind: {payload.get('kind')}")
    if payload.get("diff_backend") != "diff-folded":
        raise AssertionError("zig_flamegraph_diff did not report diff-folded backend metadata")
    svg = validate_svg_artifact("diff.svg")
    intermediate = payload.get("intermediate")
    intermediate_abs = payload.get("intermediate_abs")
    metadata = payload.get("intermediate_folded", {})
    if intermediate != "diff.folded" or metadata.get("path") != "diff.folded":
        raise AssertionError("zig_flamegraph_diff did not preserve requested intermediate metadata")
    if not intermediate_abs:
        raise AssertionError("zig_flamegraph_diff did not report intermediate_abs")
    intermediate_artifact = path_artifact(intermediate_abs, "diff.folded")
    if metadata.get("bytes") != intermediate_artifact["bytes"]:
        raise AssertionError("diff-folded intermediate byte metadata does not match artifact")
    if metadata.get("backend") != "diff-folded":
        raise AssertionError("diff-folded intermediate metadata did not report backend")
    scenario["svg_validation"] = svg
    scenario["intermediate"] = intermediate_artifact
    scenario["artifacts"] = [svg["artifact_path"], intermediate_artifact["path"]]
    scenario["evidence_paths"].extend([svg["artifact_path"], intermediate_artifact["path"]])
    scenario["required_markers"] = ["diff-folded", "intermediate metadata", "structural SVG"]


add_tool_scenario(
    "zls_document_symbols",
    ["zls"],
    "zig_document_symbols",
    {"file": "src/main.zig"},
    validate_zls_symbols,
)
add_tool_scenario(
    "zwanzig_lint_json",
    ["zwanzig"],
    "zig_lint",
    {"path": "src/main.zig"},
    validate_zwanzig_json,
)
add_tool_scenario(
    "zwanzig_lint_sarif",
    ["zwanzig"],
    "zig_lint_sarif",
    {"path": "src/main.zig"},
    validate_zwanzig_sarif,
)
add_tool_scenario(
    "zwanzig_lint_rules",
    ["zwanzig"],
    "zig_lint_rules",
    {},
    validate_zwanzig_rules,
)
add_tool_scenario(
    "zwanzig_analysis_graphs_cfg",
    ["zwanzig"],
    "zig_analysis_graphs",
    {"mode": "cfg", "path": "src/main.zig", "output": "graphs/cfg"},
    validate_zwanzig_graph,
)
add_tool_scenario(
    "zlint_diagnostics_json",
    ["zlint"],
    "zig_zlint",
    {"path": "src/main.zig"},
    validate_zlint_json,
)
add_tool_scenario(
    "zlint_sarif",
    ["zlint"],
    "zig_zlint_sarif",
    {"path": "src/main.zig"},
    validate_zlint_sarif,
)
add_tool_scenario(
    "zlint_rules",
    ["zlint"],
    "zig_zlint_rules",
    {},
    validate_zlint_rules,
)
add_tool_scenario(
    "zlint_fix_preview",
    ["zlint"],
    "zig_zlint_fix",
    {"path": "src/main.zig", "apply": False},
    validate_zlint_fix_preview,
)
add_tool_scenario(
    "zflame_recursive_folded_svg",
    ["zflame"],
    "zig_flamegraph",
    {
        "format": "recursive",
        "input": "stacks.folded",
        "output": "profile.svg",
        "title": "backend conformance",
        "hash": True,
    },
    validate_flamegraph,
)
add_tool_scenario(
    "diff_folded_recursive_svg_intermediate",
    ["diff_folded", "zflame"],
    "zig_flamegraph_diff",
    {
        "before": "before.folded",
        "after": "after.folded",
        "output": "diff.svg",
        "intermediate": "diff.folded",
        "title": "backend conformance diff",
        "hash": True,
    },
    validate_diff_flamegraph,
)

stdin = "\n".join(json.dumps(item, separators=(",", ":")) for item in requests) + "\n"
expected_ids = {item["id"] for item in requests if "id" in item}
argv = [
    os.environ["ZIGAR_BINARY"],
    "--workspace",
    str(workspace),
    "--transport",
    "stdio",
    "--zig-path",
    os.environ["ZIGAR_ZIG_PATH"],
    "--zls-path",
    backend_arg("zls"),
    "--zlint-path",
    backend_arg("zlint"),
    "--zwanzig-path",
    backend_arg("zwanzig"),
    "--zflame-path",
    backend_arg("zflame"),
    "--diff-folded-path",
    backend_arg("diff_folded"),
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

for response_id in sorted(expected_ids):
    if response_id not in responses:
        fail(f"missing JSON-RPC response id {response_id}; stdout saved to {stdout_path}")
    if response_id in (1, 2, 3) and "error" in responses[response_id]:
        fail(f"JSON-RPC response id {response_id} returned error: {responses[response_id]['error']}")

tools_result = responses[2]["result"]
tool_names = {tool.get("name") for tool in tools_result.get("tools", [])}
for tool in (
    "zigar_doctor",
    "zig_document_symbols",
    "zig_zlint",
    "zig_zlint_sarif",
    "zig_zlint_rules",
    "zig_zlint_fix",
    "zig_lint",
    "zig_lint_sarif",
    "zig_lint_rules",
    "zig_analysis_graphs",
    "zig_flamegraph",
    "zig_flamegraph_diff",
):
    if tool not in tool_names:
        fail(f"tools/list did not include {tool}")


def tool_payload(response_id):
    if "error" in responses[response_id]:
        return None, json.dumps(responses[response_id]["error"], separators=(",", ":")), True
    result = responses[response_id]["result"]
    if "structuredContent" in result:
        payload = result["structuredContent"]
        return payload, json.dumps(payload, separators=(",", ":")), bool(result.get("isError"))
    texts = [
        item.get("text", "")
        for item in result.get("content", [])
        if isinstance(item, dict) and item.get("type") == "text"
    ]
    for text in texts:
        try:
            return json.loads(text), text, bool(result.get("isError"))
        except json.JSONDecodeError:
            pass
    return result, json.dumps(result, separators=(",", ":")), bool(result.get("isError"))


add_scenario_record({
    "name": "zigar_initialize",
    "backend": "zigar",
    "backends": ["zigar"],
    "tool": "initialize",
    "response_id": 1,
    "status": "passed",
    "claim": "required",
    "coverage_required": True,
    "evidence_paths": [str(stdout_path), str(stderr_path)],
})
add_scenario_record({
    "name": "zigar_tools_list",
    "backend": "zigar",
    "backends": ["zigar"],
    "tool": "tools/list",
    "response_id": 2,
    "status": "passed",
    "claim": "required",
    "coverage_required": True,
    "evidence_paths": [str(stdout_path), str(stderr_path)],
    "tool_count": len(tool_names),
})

doctor, _, doctor_error = tool_payload(3)
if doctor_error:
    fail("zigar_doctor returned an error response")
if doctor.get("kind") != "zigar_doctor":
    fail("zigar_doctor returned an unexpected payload")
checks = {check.get("name"): check for check in doctor.get("checks", []) if isinstance(check, dict)}
for backend, probe in (
    ("zig", "zig_probe"),
    ("zls", "zls_probe"),
    ("zlint", "zlint_probe"),
    ("zwanzig", "zwanzig_probe"),
    ("zflame", "zflame_probe"),
    ("diff_folded", "diff_folded_probe"),
):
    check = checks.get(probe)
    if not check:
        fail(f"zigar_doctor did not report {probe}")
    coverage_required = backend == "zig" or backend in claimed_backends
    if check.get("ok") is True:
        status = scenario_status_for_success(coverage_required)
    elif coverage_required:
        status = "unsupported"
    else:
        status = "skipped"
    add_scenario_record({
        "name": probe,
        "backend": backend,
        "backends": [backend],
        "tool": "zigar_doctor",
        "response_id": 3,
        "status": status,
        "claim": "required" if backend == "zig" else ("claimed" if backend in claimed_backends else "not_claimed"),
        "coverage_required": coverage_required,
        "evidence_paths": [str(stdout_path), str(stderr_path)],
        "doctor_check": check,
    })
    if backend == "zig" and check.get("ok") is not True:
        fail(f"{probe} failed: {check.get('status')} - {check.get('resolution')}")

for response_id, (scenario, validator) in planned_scenarios.items():
    payload, text, is_error = tool_payload(response_id)
    if is_error:
        scenario["status"] = "unsupported" if scenario["coverage_required"] else "unsupported"
        scenario["reason"] = text[:1024]
    else:
        try:
            validator(payload, text, scenario)
            scenario["status"] = scenario_status_for_success(scenario["coverage_required"])
        except AssertionError as exc:
            scenario["status"] = "failed"
            scenario["reason"] = str(exc)
    add_scenario_record(scenario)

tool_evidence = {
    scenario["name"]: {
        "backend": scenario["backend"],
        "backends": scenario["backends"],
        "tool": scenario["tool"],
        "status": scenario["status"],
        "response_id": scenario.get("response_id"),
        "evidence_paths": scenario.get("evidence_paths", []),
        "artifacts": scenario.get("artifacts", []),
        "required_markers": scenario.get("required_markers", []),
    }
    for scenario in scenario_results
}


def backend_matrix_row(backend):
    rows = [
        scenario
        for scenario in scenario_results
        if backend in scenario.get("backends", [])
    ]
    required = backend in ("zigar", "zig") or backend in claimed_backends
    if any(row["coverage_required"] and row["status"] != "passed" for row in rows):
        status = "failed"
    elif any(row["status"] == "passed" for row in rows):
        status = "passed"
    elif any(row["status"] == "observed" for row in rows):
        status = "observed"
    elif rows:
        status = "skipped"
    else:
        status = "missing"
    evidence_paths = []
    for row in rows:
        for path in row.get("evidence_paths", []):
            if path not in evidence_paths:
                evidence_paths.append(path)
    return {
        "backend": backend,
        "claim": "required" if backend in ("zigar", "zig") else ("claimed" if backend in claimed_backends else "not_claimed"),
        "status": status,
        "scenario_names": [row["name"] for row in rows],
        "scenario_statuses": {row["name"]: row["status"] for row in rows},
        "evidence_paths": evidence_paths,
        "coverage_required": required,
    }


compatibility_matrix = [
    backend_matrix_row(backend)
    for backend in ("zigar", "zig", "zls", "zlint", "zwanzig", "zflame", "diff_folded")
]

coverage_errors = []
if unknown_claims:
    coverage_errors.append(f"unknown claimed backend(s): {', '.join(unknown_claims)}")
for scenario in scenario_results:
    if scenario.get("coverage_required") and scenario.get("status") != "passed":
        coverage_errors.append(f"{scenario['name']}={scenario['status']}")

result = "failed" if coverage_errors else "passed"

report = {
    "kind": "zigar_backend_conformance_report",
    "schema_version": 2,
    "generated_unix": int(time.time()),
    "source_commit": source_commit,
    "source": source_metadata,
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
    "scenarios": scenario_results,
    "tool_evidence": tool_evidence,
    "artifacts": artifacts,
    "coverage_errors": coverage_errors,
    "result": result,
}
report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

summary_lines = [
    "# Zigar Backend Conformance",
    "",
    f"Result: {result}",
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
    sha = entry.get("sha256", "unavailable")
    summary_lines.append(f"- {name}: `{entry['path']}` sha256 `{sha}` {first_line}")
summary_lines.extend([
    "",
    "## Compatibility Matrix",
    "",
    "| Backend | Claim | Status | Scenarios |",
    "|---|---|---|---|",
])
for row in compatibility_matrix:
    summary_lines.append(f"| `{row['backend']}` | {row['claim']} | {row['status']} | {', '.join(row['scenario_names'])} |")
summary_lines.extend([
    "",
    "## Scenarios",
    "",
    "| Scenario | Backend | Tool | Status | Evidence |",
    "|---|---|---|---|---|",
])
for scenario in scenario_results:
    evidence = ", ".join(scenario.get("evidence_paths", [])[:4])
    summary_lines.append(f"| `{scenario['name']}` | `{scenario['backend']}` | `{scenario['tool']}` | {scenario['status']} | {evidence} |")
summary_lines.extend([
    "",
    "## Artifacts",
    "",
])
for name, entry in artifacts.items():
    summary_lines.append(f"- {name}: {entry['bytes']} bytes sha256 `{entry['sha256']}`")
if coverage_errors:
    summary_lines.extend(["", "## Coverage Errors", ""])
    for error in coverage_errors:
        summary_lines.append(f"- {error}")
summary_path.write_text("\n".join(summary_lines) + "\n")

if coverage_errors:
    fail(f"claimed backend scenario coverage failed: {', '.join(coverage_errors)}")

print("backend-conformance: backend probes and scenario tool calls passed")
print(f"backend-conformance: stdout {stdout_path}")
print(f"backend-conformance: stderr {stderr_path}")
print(f"backend-conformance: report {report_path}")
print(f"backend-conformance: summary {summary_path}")
PY
