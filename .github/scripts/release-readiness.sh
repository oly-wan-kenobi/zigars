#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

fail() {
  printf 'release-readiness: %s\n' "$*" >&2
  exit 1
}

command -v git >/dev/null || fail "git is required for source evidence"

source_commit="$(git rev-parse HEAD)"
git_status_short="$(git status --short --untracked-files=all)"
source_tree_clean=true
if [[ -n "$git_status_short" ]]; then
  source_tree_clean=false
fi

export ZIGARS_SOURCE_COMMIT="$source_commit"
export ZIGARS_SOURCE_TREE_CLEAN="$source_tree_clean"
export ZIGARS_GIT_STATUS_SHORT="$git_status_short"

if [[ "$source_tree_clean" != "true" && "${ZIGARS_ALLOW_DIRTY_RELEASE_READINESS:-0}" != "1" ]]; then
  printf 'release-readiness: source tree is dirty; refusing to produce release-citable evidence\n' >&2
  printf '%s\n' "$git_status_short" >&2
  printf 'release-readiness: rerun from a clean tree or set ZIGARS_ALLOW_DIRTY_RELEASE_READINESS=1 for non-release evidence\n' >&2
  exit 1
fi

report_dir="${ZIGARS_RELEASE_READINESS_DIR:-release-readiness}"
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd -P)"
export ZIGARS_RELEASE_READINESS_DIR="$report_dir"

printf 'release-readiness: report directory %s\n' "$report_dir"

use_pinned_backend_setup="${ZIGARS_USE_PINNED_BACKEND_SETUP:-${ZIGARS_REPO_PINNED_BACKEND_SETUP:-0}}"
case "$use_pinned_backend_setup" in
  1|true|TRUE|yes|YES)
    real_backend_dir="${ZIGARS_REAL_BACKENDS_DIR:-$repo_root/.zigars-cache/real-backends}"
    export ZIGARS_REAL_BACKENDS_DIR="$real_backend_dir"
    printf 'release-readiness: provisioning repo-pinned optional backends under %s\n' "$real_backend_dir"
    bash .github/scripts/setup-real-backends.sh
    # shellcheck disable=SC1090
    source "$real_backend_dir/env.sh"
    export ZIGARS_ZWANZIG_PATH ZIGARS_ZFLAME_PATH ZIGARS_DIFF_FOLDED_PATH
    backend_setup_evidence_dir="$report_dir/backend-provisioning"
    mkdir -p "$backend_setup_evidence_dir"
    cp "$real_backend_dir/real_backend_pins.json" "$backend_setup_evidence_dir/real_backend_pins.json"
    cp "$real_backend_dir/checksums.sha256" "$backend_setup_evidence_dir/checksums.sha256"
    export ZIGARS_PINNED_BACKEND_SETUP="true"
    export ZIGARS_PINNED_BACKEND_SETUP_DIR="$real_backend_dir"
    export ZIGARS_PINNED_BACKEND_SETUP_EVIDENCE_DIR="$backend_setup_evidence_dir"
    ;;
  0|false|FALSE|no|NO|"")
    export ZIGARS_PINNED_BACKEND_SETUP="false"
    ;;
  *)
    fail "ZIGARS_USE_PINNED_BACKEND_SETUP must be 1/true or 0/false, got: $use_pinned_backend_setup"
    ;;
esac

zig build release-check
zig build dist release-asset-smoke

ZIGARS_CONFORMANCE_REPORT_DIR="$report_dir/backend-conformance" \
ZIGARS_CLAIMED_BACKENDS="${ZIGARS_CLAIMED_BACKENDS:-zls,zwanzig,zflame,diff_folded}" \
bash .github/scripts/backend-conformance.sh

ZIGARS_ZLS_CONFORMANCE_REPORT_DIR="$report_dir/zls-conformance" \
bash .github/scripts/real-zls-conformance.sh

python3 <<'PY'
import hashlib
import json
import os
import pathlib
import time

root = pathlib.Path(os.environ.get("ZIGARS_RELEASE_READINESS_DIR", "release-readiness")).resolve()
backend = json.loads((root / "backend-conformance" / "report.json").read_text())
zls = json.loads((root / "zls-conformance" / "report.json").read_text())
if backend.get("result") != "passed":
    raise SystemExit("backend conformance did not pass")
if zls.get("result") != "passed":
    raise SystemExit("ZLS conformance did not pass")

source_commit = os.environ["ZIGARS_SOURCE_COMMIT"]
subreport_commits = {
    "backend_conformance": backend.get("source_commit"),
    "zls_conformance": zls.get("source_commit"),
}
for report_name, report_commit in subreport_commits.items():
    if not report_commit:
        raise SystemExit(f"{report_name} report is missing source_commit")
    if report_commit != source_commit:
        raise SystemExit(
            f"{report_name} source_commit {report_commit} does not match top-level {source_commit}"
        )

source_tree_clean = os.environ["ZIGARS_SOURCE_TREE_CLEAN"] == "true"
git_status_short = os.environ.get("ZIGARS_GIT_STATUS_SHORT", "")
claimed_backends_raw = os.environ.get("ZIGARS_CLAIMED_BACKENDS", "zls,zwanzig,zflame,diff_folded")


def optional_env(name):
    value = os.environ.get(name)
    if value is None or value == "":
        return None
    return value


def command_digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def path_input(name, default):
    return os.environ.get(name, default)


def read_workflow_dispatch_inputs():
    event_path = optional_env("GITHUB_EVENT_PATH")
    if event_path is None:
        return {}
    try:
        event = json.loads(pathlib.Path(event_path).read_text())
    except Exception:
        return {}
    inputs = event.get("inputs")
    if not isinstance(inputs, dict):
        return {}
    return {str(key): str(value) for key, value in inputs.items() if value is not None}


workflow_dispatch_inputs = read_workflow_dispatch_inputs()
setup_command_name = None
setup_command_value = None
for candidate in (
    "ZIGARS_RELEASE_SETUP_COMMAND",
    "ZIGARS_BACKEND_SETUP_COMMAND",
    "ZIGARS_SETUP_COMMAND",
    "INPUT_SETUP_COMMAND",
):
    value = optional_env(candidate)
    if value is not None:
        setup_command_name = candidate
        setup_command_value = value
        break
if setup_command_value is None and workflow_dispatch_inputs.get("setup_command"):
    setup_command_name = "workflow_dispatch.inputs.setup_command"
    setup_command_value = workflow_dispatch_inputs["setup_command"]


def file_evidence(path):
    if path is None:
        return None
    file_path = pathlib.Path(path)
    if not file_path.exists():
        return None
    return {
        "path": str(file_path),
        "sha256": hashlib.sha256(file_path.read_bytes()).hexdigest(),
        "bytes": file_path.stat().st_size,
    }


pinned_setup_enabled = os.environ.get("ZIGARS_PINNED_BACKEND_SETUP") == "true"
pinned_setup_evidence_dir = optional_env("ZIGARS_PINNED_BACKEND_SETUP_EVIDENCE_DIR")
pinned_setup_manifest = None
pinned_setup_checksums = None
if pinned_setup_evidence_dir is not None:
    evidence_dir = pathlib.Path(pinned_setup_evidence_dir)
    pinned_setup_manifest = file_evidence(evidence_dir / "real_backend_pins.json")
    pinned_setup_checksums = file_evidence(evidence_dir / "checksums.sha256")

setup = {
    "setup_command_present": setup_command_value is not None,
    "setup_command_env": setup_command_name,
    "setup_command_sha256": command_digest(setup_command_value) if setup_command_value is not None else None,
    "repo_pinned_setup": {
        "enabled": pinned_setup_enabled,
        "setup_script": ".github/scripts/setup-real-backends.sh" if pinned_setup_enabled else None,
        "cache_dir": optional_env("ZIGARS_PINNED_BACKEND_SETUP_DIR"),
        "evidence_dir": pinned_setup_evidence_dir,
        "pin_manifest": pinned_setup_manifest,
        "checksums": pinned_setup_checksums,
    },
    "pins": {
        key: value
        for key in (
            "ZIGARS_ZIG_VERSION",
            "ZIGARS_ZLS_VERSION",
            "ZIGARS_ZWANZIG_VERSION",
            "ZIGARS_ZWANZIG_SOURCE",
            "ZIGARS_ZWANZIG_COMMIT",
            "ZIGARS_ZWANZIG_SHA256",
            "ZIGARS_ZFLAME_VERSION",
            "ZIGARS_ZFLAME_SOURCE",
            "ZIGARS_ZFLAME_COMMIT",
            "ZIGARS_ZFLAME_SHA256",
            "ZIGARS_DIFF_FOLDED_VERSION",
            "ZIGARS_DIFF_FOLDED_SOURCE",
            "ZIGARS_DIFF_FOLDED_COMMIT",
            "ZIGARS_DIFF_FOLDED_SHA256",
        )
        if (value := optional_env(key)) is not None
    },
}

backend_path_inputs = {
    "zigars": path_input("ZIGARS_BINARY", "zig-out/bin/zigars"),
    "zig": path_input("ZIGARS_ZIG_PATH", "zig"),
    "zls": path_input("ZIGARS_ZLS_PATH", "zls"),
    "zwanzig": path_input("ZIGARS_ZWANZIG_PATH", "zwanzig"),
    "zflame": path_input("ZIGARS_ZFLAME_PATH", "zflame"),
    "diff_folded": path_input("ZIGARS_DIFF_FOLDED_PATH", "diff-folded"),
}
resolved_backends = {
    name: {
        "path": entry.get("resolved_path") or entry.get("path"),
        "requested_path": entry.get("path"),
        "sha256": entry.get("sha256"),
    }
    for name, entry in backend.get("backends", {}).items()
    if isinstance(entry, dict)
}
zls_conformance_backends = {
    name: {
        "path": entry.get("path"),
        "sha256": entry.get("sha256"),
    }
    for name, entry in zls.get("backends", {}).items()
    if isinstance(entry, dict)
}

workflow_dispatch_inputs_sanitized = {
    key: value
    for key, value in workflow_dispatch_inputs.items()
    if key != "setup_command"
}
if workflow_dispatch_inputs.get("setup_command"):
    workflow_dispatch_inputs_sanitized["setup_command_sha256"] = command_digest(
        workflow_dispatch_inputs["setup_command"]
    )

workflow = {
    "identity": "github_actions" if os.environ.get("GITHUB_ACTIONS") == "true" else "local_script",
    "local_script": ".github/scripts/release-readiness.sh",
    "workflow_name": os.environ.get("GITHUB_WORKFLOW"),
    "workflow_ref": os.environ.get("GITHUB_WORKFLOW_REF"),
    "workflow_sha": os.environ.get("GITHUB_WORKFLOW_SHA"),
    "run_id": os.environ.get("GITHUB_RUN_ID"),
    "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
    "job": os.environ.get("GITHUB_JOB"),
    "event_name": os.environ.get("GITHUB_EVENT_NAME"),
    "repository": os.environ.get("GITHUB_REPOSITORY"),
    "workflow_dispatch_inputs": workflow_dispatch_inputs_sanitized,
}

summary = {
    "kind": "zigars_release_readiness_report",
    "schema_version": 2,
    "generated_unix": int(time.time()),
    "result": "passed",
    "source_commit": source_commit,
    "source_tree_clean": source_tree_clean,
    "git_status_short": git_status_short,
    "dirty_override": os.environ.get("ZIGARS_ALLOW_DIRTY_RELEASE_READINESS") == "1",
    "workflow": workflow,
    "backend_inputs": {
        "path_inputs": backend_path_inputs,
        "claimed_backends_raw": claimed_backends_raw,
        "claimed_backends": backend.get("claimed_backends", []),
        "resolved_backends": resolved_backends,
        "zls_conformance_backends": zls_conformance_backends,
    },
    "setup": setup,
    "subreport_commits": subreport_commits,
    "backend_conformance": str(root / "backend-conformance" / "report.json"),
    "zls_conformance": str(root / "zls-conformance" / "report.json"),
    "claimed_backends": backend.get("claimed_backends", []),
    "compatibility_matrix": backend.get("compatibility_matrix", []),
}
(root / "release-readiness.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")

summary_heading = "Release-note-ready Evidence Summary" if source_tree_clean else "Non-release Evidence Summary"
markdown = [
    "# Zigars Release Readiness",
    "",
    "Result: passed",
    f"Source commit: `{source_commit}`",
    f"Source tree clean: `{str(source_tree_clean).lower()}`",
]
if git_status_short:
    markdown.extend([
        "",
        "Source status:",
        "",
        "```",
        git_status_short,
        "```",
    ])
if not source_tree_clean:
    markdown.extend([
        "",
        "This run used `ZIGARS_ALLOW_DIRTY_RELEASE_READINESS=1`. Treat it as non-release evidence and rerun from a clean tree before citing it in release notes.",
    ])
markdown.extend([
    "",
    f"## {summary_heading}",
    "",
    "- Local release gate: `zig build release-check` passed.",
    "- Release assets: `zig build dist release-asset-smoke` passed.",
    "- Real backend conformance: see `backend-conformance/summary.md`.",
    "- Real ZLS conformance: see `zls-conformance/summary.md`.",
    f"- Workflow identity: `{workflow['identity']}` via `{workflow['local_script']}`.",
    f"- Repo-pinned backend setup: `{'enabled' if pinned_setup_enabled else 'disabled'}`.",
])
if pinned_setup_manifest is not None:
    markdown.append(f"- Backend pin manifest: `backend-provisioning/real_backend_pins.json` sha256 `{pinned_setup_manifest['sha256']}`.")
if pinned_setup_checksums is not None:
    markdown.append(f"- Backend binary checksums: `backend-provisioning/checksums.sha256` sha256 `{pinned_setup_checksums['sha256']}`.")
markdown.extend([
    "",
    "## Backend Inputs",
    "",
    "| Backend | Requested path | Resolved path | SHA-256 |",
    "|---|---|---|---|",
])
for backend_name, requested in backend_path_inputs.items():
    resolved = resolved_backends.get(backend_name) or zls_conformance_backends.get(backend_name) or {}
    markdown.append(
        f"| `{backend_name}` | `{requested}` | `{resolved.get('path', 'not recorded')}` | `{resolved.get('sha256', 'not recorded')}` |"
    )
markdown.extend([
    "",
    "## Optional Backend Status",
    "",
    "| Backend | Claim | Status | Evidence |",
    "|---|---|---|---|",
])
for row in summary["compatibility_matrix"]:
    evidence = row.get("evidence")
    if evidence is None:
        scenario_names = row.get("scenario_names") or []
        evidence_paths = row.get("evidence_paths") or []
        parts = []
        if scenario_names:
            parts.append("scenarios: " + ", ".join(str(item) for item in scenario_names))
        if evidence_paths:
            parts.append("evidence paths: " + ", ".join(str(item) for item in evidence_paths[:3]))
        evidence = "; ".join(parts) if parts else "not recorded"
    markdown.append(
        f"| `{row.get('backend', 'unknown')}` | {row.get('claim', 'unknown')} | {row.get('status', 'unknown')} | {evidence} |"
    )
if not summary["compatibility_matrix"]:
    for backend_name in summary["claimed_backends"]:
        status_text = "passed real conformance for this release candidate" if source_tree_clean else "passed real conformance in this non-release run"
        markdown.append(f"| `{backend_name}` | claimed | passed | {status_text} |")
(root / "release-readiness.md").write_text("\n".join(markdown) + "\n")
print(f"release-readiness: summary {root / 'release-readiness.md'}")
PY
