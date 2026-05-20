#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

report_dir="${ZIGAR_RELEASE_READINESS_DIR:-release-readiness}"
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd -P)"
export ZIGAR_RELEASE_READINESS_DIR="$report_dir"

printf 'release-readiness: report directory %s\n' "$report_dir"

zig build release-check
zig build dist release-asset-smoke

ZIGAR_CONFORMANCE_REPORT_DIR="$report_dir/backend-conformance" \
ZIGAR_CLAIMED_BACKENDS="${ZIGAR_CLAIMED_BACKENDS:-zls,zwanzig,zflame,diff_folded}" \
bash .github/scripts/backend-conformance.sh

ZIGAR_ZLS_CONFORMANCE_REPORT_DIR="$report_dir/zls-conformance" \
bash .github/scripts/real-zls-conformance.sh

python3 <<'PY'
import json
import os
import pathlib
import time

root = pathlib.Path(os.environ.get("ZIGAR_RELEASE_READINESS_DIR", "release-readiness")).resolve()
backend = json.loads((root / "backend-conformance" / "report.json").read_text())
zls = json.loads((root / "zls-conformance" / "report.json").read_text())
if backend.get("result") != "passed":
    raise SystemExit("backend conformance did not pass")
if zls.get("result") != "passed":
    raise SystemExit("ZLS conformance did not pass")

summary = {
    "kind": "zigar_release_readiness_report",
    "schema_version": 1,
    "generated_unix": int(time.time()),
    "result": "passed",
    "source_commit": backend.get("source_commit"),
    "backend_conformance": str(root / "backend-conformance" / "report.json"),
    "zls_conformance": str(root / "zls-conformance" / "report.json"),
    "claimed_backends": backend.get("claimed_backends", []),
}
(root / "release-readiness.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")

markdown = [
    "# Zigar Release Readiness",
    "",
    "Result: passed",
    f"Source commit: `{summary['source_commit']}`",
    "",
    "## Evidence",
    "",
    "- Local release gate: `zig build release-check` passed.",
    "- Release assets: `zig build dist release-asset-smoke` passed.",
    "- Real backend conformance: see `backend-conformance/summary.md`.",
    "- Real ZLS conformance: see `zls-conformance/summary.md`.",
    "",
    "## Claimed Optional Backends",
    "",
]
for backend_name in summary["claimed_backends"]:
    markdown.append(f"- `{backend_name}`: passed real conformance for this release candidate.")
(root / "release-readiness.md").write_text("\n".join(markdown) + "\n")
print(f"release-readiness: summary {root / 'release-readiness.md'}")
PY
