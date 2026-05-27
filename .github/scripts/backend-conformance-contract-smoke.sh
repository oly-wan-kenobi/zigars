#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

binary="${ZIGARS_BINARY:-zig-out/bin/zigars}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      binary="$2"
      shift 2
      ;;
    *)
      printf 'backend-conformance-contract-smoke: unexpected argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/zigars-conformance-contract.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

cat >"$tmpdir/zls" <<'PY'
#!/usr/bin/env python3
import json
import sys

if len(sys.argv) > 1 and sys.argv[1] == "--version":
    print("fake zls 0.16.0")
    sys.exit(0)


def read_message():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        name, value = line.decode("ascii").split(":", 1)
        headers[name.lower()] = value.strip()
    length = int(headers.get("content-length", "0"))
    if length <= 0:
        return None
    return json.loads(sys.stdin.buffer.read(length).decode("utf-8"))


def send_message(message):
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


symbol_range = {
    "start": {"line": 0, "character": 0},
    "end": {"line": 10, "character": 0},
}

while True:
    message = read_message()
    if message is None:
        break
    if "id" not in message:
        continue
    method = message.get("method")
    if method == "initialize":
        result = {"capabilities": {"documentSymbolProvider": True}}
    elif method == "textDocument/documentSymbol":
        result = [
            {
                "name": "PublicThing",
                "kind": 23,
                "range": symbol_range,
                "selectionRange": symbol_range,
            },
            {
                "name": "main",
                "kind": 12,
                "range": symbol_range,
                "selectionRange": symbol_range,
            },
        ]
    else:
        result = None
    send_message({"jsonrpc": "2.0", "id": message["id"], "result": result})
PY

cat >"$tmpdir/zwanzig" <<'SH'
#!/bin/sh
if [ "$1" = "--help" ]; then
  cat <<'EOF'
fake zwanzig help
--format json|sarif
--dump-cfg <dir> <file>
--dump-exploded-graph <dir> <file>
--dump-annotated-cfg <dir> <file>
--dump-path-trace <dir> <file>
EOF
  exit 0
fi
case "$1" in
  --dump-cfg|--dump-exploded-graph|--dump-annotated-cfg|--dump-path-trace)
    out="$2"
    mkdir -p "$out"
    printf 'digraph fake { start -> end }\n' > "$out/fake-cfg.dot"
    exit 0
    ;;
esac
if [ "$1" != "--format" ]; then
  echo "fake zwanzig expected --format" >&2
  exit 2
fi
case "$2" in
  json)
    echo '{"diagnostics":[]}'
    ;;
  sarif)
    echo '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"fake-zwanzig"}}}]}'
    ;;
  *)
    echo "fake zwanzig unsupported format" >&2
    exit 2
    ;;
esac
SH

cat >"$tmpdir/zlint" <<'SH'
#!/bin/sh
if [ "$1" = "--help" ]; then echo "fake zlint help --format json --rules --print-ast --fix"; exit 0; fi
if [ "$1" = "--print-ast" ]; then
  echo '{"symbols":[{"name":"main","references":[{"flags":["call"]}]}]}'
  exit 0
fi
if [ "$1" = "--rules" ] && [ "$2" = "--format" ] && [ "$3" = "json" ]; then
  echo '{"rules":[{"id":"fake.zlint.rule","severity":"warning","description":"fake rule"}]}'
  exit 0
fi
if [ "$1" = "--format" ] && [ "$2" = "json" ]; then
  for arg in "$@"; do
    if [ "$arg" = "--fix" ] || [ "$arg" = "--fix-dangerously" ]; then
      echo '{"findings":[]}'
      exit 0
    fi
  done
  echo '{"findings":[{"rule":"fake.zlint.rule","severity":"warning","path":"src/main.zig","line":1,"column":15,"message":"fake ZLint finding"}]}'
  exit 0
fi
echo "fake zlint expected --format json or --rules --format json" >&2
exit 2
SH

cat >"$tmpdir/zflame" <<'SH'
#!/bin/sh
if [ "$1" = "--help" ]; then echo "fake zflame help"; exit 0; fi
printf '%s\n%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<svg xmlns="http://www.w3.org/2000/svg"><title>fake flamegraph</title></svg>'
SH

cat >"$tmpdir/diff-folded" <<'SH'
#!/bin/sh
if [ "$1" = "--help" ]; then echo "fake diff-folded help"; exit 0; fi
case "$1" in
  --output=*) out="${1#--output=}" ;;
  *) exit 2 ;;
esac
case "$out" in
  */*) mkdir -p "${out%/*}" ;;
esac
printf 'root;diff 1\n' > "$out"
SH

chmod +x "$tmpdir/zls" "$tmpdir/zlint" "$tmpdir/zwanzig" "$tmpdir/zflame" "$tmpdir/diff-folded"

report_dir="$tmpdir/report"
ZIGARS_BINARY="$binary" \
ZIGARS_ZLS_PATH="$tmpdir/zls" \
ZIGARS_ZLINT_PATH="$tmpdir/zlint" \
ZIGARS_ZWANZIG_PATH="$tmpdir/zwanzig" \
ZIGARS_ZFLAME_PATH="$tmpdir/zflame" \
ZIGARS_DIFF_FOLDED_PATH="$tmpdir/diff-folded" \
ZIGARS_CONFORMANCE_REPORT_DIR="$report_dir" \
ZIGARS_CLAIMED_BACKENDS="zls,zlint,zwanzig,zflame,diff_folded" \
ZIGARS_CONFORMANCE_TIMEOUT_SECONDS=20 \
bash .github/scripts/backend-conformance.sh >/dev/null

REPORT_DIR="$report_dir" python3 <<'PY'
import json
import os
import pathlib
import sys

report_dir = pathlib.Path(os.environ["REPORT_DIR"])
report = json.loads((report_dir / "report.json").read_text())
if report.get("kind") != "zigars_backend_conformance_report":
    sys.exit("unexpected report kind")
if report.get("schema_version") != 2:
    sys.exit("unexpected report schema version")
if report.get("result") != "passed":
    sys.exit("conformance report did not pass")
if not report.get("source_commit") or report.get("source", {}).get("commit") != report.get("source_commit"):
    sys.exit("missing source commit metadata")
for backend in ("zigars", "zig", "zls", "zlint", "zwanzig", "zflame", "diff_folded"):
    entry = report["backends"][backend]
    if len(entry.get("sha256", "")) != 64:
        sys.exit(f"missing sha256 for {backend}")
matrix = {row["backend"]: row for row in report["compatibility_matrix"]}
for backend in ("zls", "zlint", "zwanzig", "zflame", "diff_folded"):
    if matrix[backend]["claim"] != "claimed" or matrix[backend]["status"] != "passed":
        sys.exit(f"claimed backend did not pass matrix coverage: {backend}")
scenarios = {scenario["name"]: scenario for scenario in report["scenarios"]}
required_scenarios = (
    "zls_document_symbols",
    "zlint_diagnostics_json",
    "zlint_sarif",
    "zlint_rules",
    "zlint_fix_preview",
    "zwanzig_lint_json",
    "zwanzig_lint_sarif",
    "zwanzig_lint_rules",
    "zwanzig_analysis_graphs_cfg",
    "zflame_recursive_folded_svg",
    "diff_folded_recursive_svg_intermediate",
)
for name in required_scenarios:
    scenario = scenarios.get(name)
    if not scenario or scenario.get("status") != "passed":
        sys.exit(f"scenario did not pass: {name}")
    if not scenario.get("evidence_paths"):
        sys.exit(f"scenario missing evidence paths: {name}")
if scenarios["zflame_recursive_folded_svg"].get("svg_validation", {}).get("xml_prologue_present") is not True:
    sys.exit("XML-prologue SVG acceptance was not exercised")
for artifact in ("profile.svg", "diff.svg", "diff.folded", "graphs/cfg/fake-cfg.dot"):
    entry = report["artifacts"][artifact]
    if len(entry.get("sha256", "")) != 64 or entry.get("bytes", 0) <= 0:
        sys.exit(f"invalid artifact evidence for {artifact}")
for required in ("summary.md", "stdout.jsonl", "stderr.log"):
    if not (report_dir / required).exists():
        sys.exit(f"missing {required}")
print("backend conformance contract smoke ok")
PY
