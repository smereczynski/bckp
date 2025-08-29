#!/usr/bin/env bash
set -euo pipefail
# SwiftPM coverage helper: builds with coverage, runs tests, exports .profdata and an lcov report.
# Usage: scripts/swiftpm-coverage.sh [--open]

OPEN_REPORT=false
if [[ "${1:-}" == "--open" ]]; then OPEN_REPORT=true; fi

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/.build"
COVER_DIR="$ROOT_DIR/.coverage"
LCOV_FILE="$COVER_DIR/coverage.lcov"
HTML_DIR="$COVER_DIR/html"

mkdir -p "$COVER_DIR"

# 1) Clean old coverage
rm -f "$LCOV_FILE"
rm -rf "$HTML_DIR"

# 2) Build & test with coverage
swift test --enable-code-coverage

# 3) Locate the latest profdata and binary paths
PROFDATA=$(find "$BUILD_DIR" -name "default.profdata" | sort | tail -n 1)
if [[ -z "$PROFDATA" ]]; then
  echo "error: default.profdata not found under $BUILD_DIR" >&2
  exit 1
fi

# Find test bundle and product binaries for llvm-cov to map symbols
BINARIES=$(find "$BUILD_DIR" -type f \( -name "*xctest" -o -name "*" -a -perm +111 \) | grep -E "/Products/.*" | tr '\n' ' ' || true)

# 4) Export lcov
/usr/bin/xcrun llvm-cov export \
  -format=lcov \
  -instr-profile "$PROFDATA" \
  $BINARIES \
  > "$LCOV_FILE"

# 5) Optional HTML via genhtml if installed (lcov package)
if command -v genhtml >/dev/null 2>&1; then
  genhtml -o "$HTML_DIR" "$LCOV_FILE" >/dev/null
  echo "HTML report: $HTML_DIR/index.html"
  if $OPEN_REPORT; then open "$HTML_DIR/index.html"; fi
fi

echo "LCOV report: $LCOV_FILE"
