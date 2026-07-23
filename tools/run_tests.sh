#!/bin/bash
# Compile and run Plonker Blocker's logic tests (tools/Tests.swift + src/Shared.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
echo "==> Compiling tests"
swiftc -o build/mbtests tools/Tests.swift src/Shared.swift \
    -framework Cocoa -framework Security -framework UserNotifications
echo "==> Running"
./build/mbtests
