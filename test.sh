#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/build/tests"
MODULE_CACHE_DIR="$PROJECT_DIR/build/ModuleCache"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" xcrun swiftc \
  -framework Foundation \
  "$PROJECT_DIR/Sources/TokenUsage.swift" \
  "$PROJECT_DIR/Sources/CodexUsageParser.swift" \
  "$PROJECT_DIR/Sources/CodexUsageScanner.swift" \
  "$PROJECT_DIR/Sources/HourlyUsageAggregator.swift" \
  "$PROJECT_DIR/Tests/main.swift" \
  -o "$BUILD_DIR/UsageTests"

"$BUILD_DIR/UsageTests"
