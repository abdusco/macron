#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "$PWD/.build/module-cache" \
  Sources/Macron/Config.swift Sources/Macron/Service.swift Sources/Macron/Runner.swift \
  Tests/MacronTests.swift -o .build/macron-tests
.build/macron-tests
