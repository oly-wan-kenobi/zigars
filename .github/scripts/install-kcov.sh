#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

if command -v kcov >/dev/null 2>&1; then
  kcov --version
  exit 0
fi

sudo apt-get update
if sudo apt-get install -y --no-install-recommends kcov; then
  kcov --version
  exit 0
fi

# Ubuntu 24.04 has no kcov package, so build a pinned upstream release.
KCOV_VERSION="${KCOV_VERSION:-v43}"
KCOV_COMMIT="${KCOV_COMMIT:-a39874f938ce13f7a65f253120d1ec946b349ffe}"
KCOV_PREFIX="${KCOV_PREFIX:-$HOME/.cache/kcov/${KCOV_VERSION}}"

sudo apt-get install -y --no-install-recommends \
  binutils-dev \
  build-essential \
  ca-certificates \
  cmake \
  git \
  libcurl4-openssl-dev \
  libdw-dev \
  libelf-dev \
  libiberty-dev \
  libssl-dev \
  ninja-build \
  python3 \
  zlib1g-dev

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

git init "$workdir/kcov"
git -C "$workdir/kcov" remote add origin https://github.com/SimonKagstrom/kcov.git
git -C "$workdir/kcov" fetch --depth 1 origin "refs/tags/${KCOV_VERSION}:refs/tags/${KCOV_VERSION}"
git -C "$workdir/kcov" checkout --detach "${KCOV_VERSION}"
actual_commit="$(git -C "$workdir/kcov" rev-parse HEAD)"
test "$actual_commit" = "$KCOV_COMMIT"

cmake -S "$workdir/kcov" -B "$workdir/kcov/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$KCOV_PREFIX"
cmake --build "$workdir/kcov/build" --target install

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s/bin\n' "$KCOV_PREFIX" >>"$GITHUB_PATH"
fi

"$KCOV_PREFIX/bin/kcov" --version
