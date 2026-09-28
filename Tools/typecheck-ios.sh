#!/usr/bin/env bash
#
# Type-check the iOS sources on a machine that has no Apple frameworks.
#
# The iOS target imports CoreBluetooth, WebKit, UIKit, SwiftUI and Security,
# none of which exist in the open-source Swift toolchain. This script builds
# the stub modules in Tools/AppleStubs and then compiles the real iOS sources
# against them, which catches type errors that a syntax-only `swiftc -parse`
# cannot.
#
# CI on a real macOS runner remains authoritative: a wrong stub signature would
# produce a false pass here.
#
# Usage: Tools/typecheck-ios.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/bfg-typecheck"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Building stub modules"
# UIKit and CoreBluetooth and Security are leaves; WebKit and SwiftUI depend on UIKit.
for module in UIKit CoreBluetooth Security WebKit SwiftUI; do
    printf '    %-15s' "$module"
    swiftc -emit-module -parse-as-library \
        -module-name "$module" \
        -emit-module-path "$OUT/$module.swiftmodule" \
        -I "$OUT" \
        "$ROOT/Tools/AppleStubs/$module.swift"
    echo "ok"
done

echo "==> Building BFGCore"
swiftc -emit-module -parse-as-library \
    -module-name BFGCore \
    -emit-module-path "$OUT/BFGCore.swiftmodule" \
    -I "$OUT" \
    "$ROOT"/Sources/BFGCore/*.swift
echo "    ok"

echo "==> Type-checking iOS sources"
swiftc -typecheck \
    -module-name BFGCalibration \
    -I "$OUT" \
    "$ROOT"/ios/BFGCalibration/*.swift

echo
echo "Type check passed: $(ls "$ROOT"/ios/BFGCalibration/*.swift | wc -l) files"
