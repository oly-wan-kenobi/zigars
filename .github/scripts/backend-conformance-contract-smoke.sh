#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

binary="${ZIGAR_BINARY:-zig-out/bin/zigar}"
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

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/zigar-conformance-contract.XXXXXX")"
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
if [ "$1" = "--help" ]; then echo "fake zwanzig help"; exit 0; fi
echo '{"diagnostics":[]}'
SH

cat >"$tmpdir/zflame" <<'SH'
#!/bin/sh
if [ "$1" = "--help" ]; then echo "fake zflame help"; exit 0; fi
echo '<svg xmlns="http://www.w3.org/2000/svg"></svg>'
SH

cat >"$tmpdir/diff-folded" <<'SH'
#!/bin/sh
if [ "$1" = "--help" ]; then echo "fake diff-folded help"; exit 0; fi
case "$1" in
  --output=*) out="${1#--output=}" ;;
  *) exit 2 ;;
esac
printf 'root;diff 1\n' > "$out"
SH

chmod +x "$tmpdir/zls" "$tmpdir/zwanzig" "$tmpdir/zflame" "$tmpdir/diff-folded"

report_dir="$tmpdir/report"
ZIGAR_BINARY="$binary" \
ZIGAR_ZLS_PATH="$tmpdir/zls" \
ZIGAR_ZWANZIG_PATH="$tmpdir/zwanzig" \
ZIGAR_ZFLAME_PATH="$tmpdir/zflame" \
ZIGAR_DIFF_FOLDED_PATH="$tmpdir/diff-folded" \
ZIGAR_CONFORMANCE_REPORT_DIR="$report_dir" \
ZIGAR_CONFORMANCE_TIMEOUT_SECONDS=20 \
bash .github/scripts/backend-conformance.sh >/dev/null

REPORT_DIR="$report_dir" python3 <<'PY'
import json
import os
import pathlib
import sys

report_dir = pathlib.Path(os.environ["REPORT_DIR"])
report = json.loads((report_dir / "report.json").read_text())
if report.get("kind") != "zigar_backend_conformance_report":
    sys.exit("unexpected report kind")
if report.get("result") != "passed":
    sys.exit("conformance report did not pass")
for backend in ("zigar", "zig", "zls", "zwanzig", "zflame", "diff_folded"):
    entry = report["backends"][backend]
    if len(entry.get("sha256", "")) != 64:
        sys.exit(f"missing sha256 for {backend}")
for artifact in ("profile.svg", "diff.svg"):
    entry = report["artifacts"][artifact]
    if len(entry.get("sha256", "")) != 64 or entry.get("bytes", 0) <= 0:
        sys.exit(f"invalid artifact evidence for {artifact}")
for required in ("summary.md", "stdout.jsonl", "stderr.log"):
    if not (report_dir / required).exists():
        sys.exit(f"missing {required}")
print("backend conformance contract smoke ok")
PY
