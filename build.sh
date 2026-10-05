#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

ARCH="${ARCH:-$(uname -m)}"
VERSION="${VERSION:-dev}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported ARCH: $ARCH" >&2; exit 1 ;; esac
VERSION_CLEAN="${VERSION#v}"
if [[ ! "$VERSION_CLEAN" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "VERSION must contain only letters, digits, dots, underscores or hyphens" >&2
  exit 1
fi

mkdir -p .build/module-cache
build_dir=$(mktemp -d .build/build.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
printf 'let currentVersion = "%s"\n' "$VERSION_CLEAN" > "$build_dir/Version.swift"
swiftc -O -swift-version 6 -parse-as-library \
  -target "${ARCH}-apple-macosx13.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$PWD/.build/module-cache" \
  Sources/Macron/*.swift "$build_dir/Version.swift" \
  -o "macron-${ARCH}"
echo "Built macron-${ARCH} with version ${VERSION_CLEAN}"
