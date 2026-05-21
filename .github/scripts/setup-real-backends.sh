#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'setup-real-backends: error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf 'setup-real-backends: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: bash .github/scripts/setup-real-backends.sh

Provision repo-pinned optional release-validation backends into:
  .zigar-cache/real-backends/bin

Environment:
  ZIGAR_REAL_BACKENDS_DIR  Override the cache/output directory.
  ZIGAR_ZIG_PATH           Zig executable used for source builds; must be 0.16.0.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 0 ]]; then
  usage >&2
  die "unexpected arguments: $*"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest_path="$repo_root/tools/real_backend_pins.json"
patch_path="$repo_root/tools/backend-patches/zflame-pin-zbench-archive.patch"
cache_root="${ZIGAR_REAL_BACKENDS_DIR:-$repo_root/.zigar-cache/real-backends}"
bin_dir="$cache_root/bin"
downloads_dir="$cache_root/downloads"
extract_dir="$cache_root/extract"
src_dir="$cache_root/src/zflame-4bb890d891390519bf3eec0ce1d08b8175a175ab"
zig_global_cache="$cache_root/zig-global-cache"

required_zig_version="0.16.0"
zwanzig_version="0.11.0"
zwanzig_tag="v0.11.0"
zflame_repo="https://github.com/hendriknielaender/zflame"
zflame_tag="v0.0.2"
zflame_commit="4bb890d891390519bf3eec0ce1d08b8175a175ab"
zflame_patch_sha256="3fc443cb37bac5e8689d5df78a4e5b8780497f05389bba2740399bc0919cadb6"

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command '$1'"
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    die "missing sha256sum or shasum for checksum verification"
  fi
}

verify_sha256() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(sha256_file "$path")"
  [[ "$actual" == "$expected" ]] || die "$label checksum mismatch: expected $expected, got $actual"
}

download_file() {
  local url="$1"
  local output="$2"
  local expected_sha="$3"
  local label="$4"
  if [[ -f "$output" ]]; then
    if [[ "$(sha256_file "$output")" == "$expected_sha" ]]; then
      note "using cached $label"
      return
    fi
    note "discarding cached $label with mismatched checksum"
    rm -f "$output"
  fi
  note "downloading $label"
  curl --fail --location --show-error --retry 3 --output "$output" "$url"
  verify_sha256 "$output" "$expected_sha" "$label"
}

detect_platform() {
  local os
  local arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os:$arch" in
    Darwin:arm64) printf 'macos-aarch64' ;;
    Linux:x86_64 | Linux:amd64) printf 'linux-x86_64' ;;
    *)
      die "unsupported platform $os/$arch; pinned zwanzig $zwanzig_tag has setup support for macos-aarch64 and linux-x86_64"
      ;;
  esac
}

resolve_zig() {
  local configured="${ZIGAR_ZIG_PATH:-zig}"
  local resolved
  resolved="$(command -v "$configured" 2>/dev/null || true)"
  [[ -n "$resolved" ]] || die "could not resolve Zig executable '$configured'"
  local actual
  actual="$("$resolved" version 2>/dev/null || true)"
  [[ "$actual" == "$required_zig_version" ]] || die "Zig $required_zig_version is required for source builds; '$resolved version' returned '${actual:-<no output>}'"
  printf '%s' "$resolved"
}

install_zwanzig() {
  local platform="$1"
  local archive_name
  local archive_url
  local archive_sha
  case "$platform" in
    macos-aarch64)
      archive_name="zwanzig-v$zwanzig_version-macos-aarch64.tar.gz"
      archive_url="https://github.com/forketyfork/zwanzig/releases/download/$zwanzig_tag/$archive_name"
      archive_sha="8b42de9c4f8ff1ea6323b34944fe2437ab473ab9de2f3b7742b960deafa1813a"
      ;;
    linux-x86_64)
      archive_name="zwanzig-v$zwanzig_version-linux-x86_64.tar.gz"
      archive_url="https://github.com/forketyfork/zwanzig/releases/download/$zwanzig_tag/$archive_name"
      archive_sha="b8f05be32f968a45b4643d8c5a1c20a5dcb3bc28859a19162ec898f9ba9e681c"
      ;;
    *)
      die "no pinned zwanzig release asset for $platform"
      ;;
  esac

  local archive_path="$downloads_dir/$archive_name"
  local work_dir="$extract_dir/zwanzig"
  download_file "$archive_url" "$archive_path" "$archive_sha" "$archive_name"
  rm -rf "$work_dir"
  mkdir -p "$work_dir"
  tar -xzf "$archive_path" -C "$work_dir"

  local candidate="$work_dir/zwanzig"
  if [[ ! -f "$candidate" ]]; then
    candidate="$(find "$work_dir" -type f -name zwanzig -print -quit)"
  fi
  [[ -n "$candidate" && -f "$candidate" ]] || die "zwanzig binary was not found in $archive_name"
  cp "$candidate" "$bin_dir/zwanzig"
  chmod 0755 "$bin_dir/zwanzig"
  "$bin_dir/zwanzig" --version >/dev/null || "$bin_dir/zwanzig" --help >/dev/null || die "zwanzig probe failed after install"
}

build_zflame_suite() {
  local zig_path="$1"
  verify_sha256 "$patch_path" "$zflame_patch_sha256" "zflame patch"

  rm -rf "$src_dir"
  note "cloning zflame $zflame_tag"
  git clone --depth 1 --branch "$zflame_tag" "$zflame_repo" "$src_dir" || die "failed to clone zflame $zflame_tag"

  local actual_commit
  actual_commit="$(git -C "$src_dir" rev-parse HEAD)"
  [[ "$actual_commit" == "$zflame_commit" ]] || die "zflame tag $zflame_tag resolved to $actual_commit, expected $zflame_commit"

  git -C "$src_dir" apply --check "$patch_path" || die "zflame patch no longer applies cleanly to $zflame_commit"
  git -C "$src_dir" apply "$patch_path"

  note "building zflame and diff-folded with Zig $required_zig_version"
  (
    cd "$src_dir"
    "$zig_path" build \
      --cache-dir "$src_dir/.zig-cache" \
      --global-cache-dir "$zig_global_cache" \
      -Doptimize=ReleaseSafe \
      --summary all
  )

  [[ -x "$src_dir/zig-out/bin/zflame" ]] || die "zflame build did not produce zig-out/bin/zflame"
  [[ -x "$src_dir/zig-out/bin/diff-folded" ]] || die "zflame build did not produce zig-out/bin/diff-folded"
  cp "$src_dir/zig-out/bin/zflame" "$bin_dir/zflame"
  cp "$src_dir/zig-out/bin/diff-folded" "$bin_dir/diff-folded"
  chmod 0755 "$bin_dir/zflame" "$bin_dir/diff-folded"
  "$bin_dir/zflame" --help >/dev/null || die "zflame probe failed after build"
  "$bin_dir/diff-folded" --help >/dev/null || die "diff-folded probe failed after build"
}

write_outputs() {
  cp "$manifest_path" "$cache_root/real_backend_pins.json"
  {
    printf 'export ZIGAR_ZWANZIG_PATH=%q\n' "$bin_dir/zwanzig"
    printf 'export ZIGAR_ZFLAME_PATH=%q\n' "$bin_dir/zflame"
    printf 'export ZIGAR_DIFF_FOLDED_PATH=%q\n' "$bin_dir/diff-folded"
  } >"$cache_root/env.sh"
  {
    printf '%s  %s\n' "$(sha256_file "$bin_dir/zwanzig")" "$bin_dir/zwanzig"
    printf '%s  %s\n' "$(sha256_file "$bin_dir/zflame")" "$bin_dir/zflame"
    printf '%s  %s\n' "$(sha256_file "$bin_dir/diff-folded")" "$bin_dir/diff-folded"
    printf '%s  %s\n' "$(sha256_file "$cache_root/real_backend_pins.json")" "$cache_root/real_backend_pins.json"
  } >"$cache_root/checksums.sha256"
}

main() {
  need_command awk
  need_command curl
  need_command find
  need_command git
  need_command tar
  [[ -f "$manifest_path" ]] || die "missing pin manifest $manifest_path"
  [[ -f "$patch_path" ]] || die "missing zflame patch $patch_path"

  mkdir -p "$bin_dir" "$downloads_dir" "$extract_dir" "$zig_global_cache" "$(dirname "$src_dir")"

  local platform
  platform="$(detect_platform)"
  local zig_path
  zig_path="$(resolve_zig)"

  note "platform $platform"
  install_zwanzig "$platform"
  build_zflame_suite "$zig_path"
  write_outputs

  note "provisioned real backends under $bin_dir"
  note "source $cache_root/env.sh before release-readiness to use these paths"
  printf 'ZIGAR_ZWANZIG_PATH=%s\n' "$bin_dir/zwanzig"
  printf 'ZIGAR_ZFLAME_PATH=%s\n' "$bin_dir/zflame"
  printf 'ZIGAR_DIFF_FOLDED_PATH=%s\n' "$bin_dir/diff-folded"
}

main "$@"
