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
# Note: --show-codecov-path returns a JSON export path, not the raw .profdata; we ignore it here.

# 3) Locate the latest profdata and binary paths
# Prefer the SwiftPM codecov folder if present
PROFDATA=$(find "$BUILD_DIR" -type f -name "default.profdata" | sort | tail -n 1)

if [[ -z "$PROFDATA" ]]; then
  echo "error: default.profdata not found under $BUILD_DIR" >&2
  exit 1
fi

# Validate profdata format quickly (optional). Some Xcode/LLVM combos may not be compatible; treat as a warning.
if command -v /usr/bin/xcrun >/dev/null 2>&1; then
  if ! /usr/bin/xcrun llvm-profdata show -instr-profile "$PROFDATA" >/dev/null 2>&1; then
    echo "warning: llvm-profdata failed to read $PROFDATA (continuing anyway)" >&2
  fi
fi

# Find test bundle executable (*.xctest/Contents/MacOS/<name>)
TEST_BIN=$(find "$BUILD_DIR" -type f -path "*.xctest/Contents/MacOS/*" \( -not -path "*.dSYM/*" \) -print -quit 2>/dev/null || true)

# Include built product executables from SwiftPM bin path (e.g., bckp, bckp-app) if present
BIN_DIR=$(swift build --show-bin-path)
PROD_BINS=()
for exe in bckp bckp-app; do
  if [[ -x "$BIN_DIR/$exe" ]]; then PROD_BINS+=("$BIN_DIR/$exe"); fi
done

BINARIES=( )
if [[ -n "$TEST_BIN" ]]; then BINARIES+=("$TEST_BIN"); fi
if [[ ${#PROD_BINS[@]} -gt 0 ]]; then BINARIES+=("${PROD_BINS[@]}"); fi

if [[ ${#BINARIES[@]} -eq 0 ]]; then
  echo "error: could not locate test bundle or product executables." >&2
  echo " looked for: *.xctest/Contents/MacOS/* and $BIN_DIR/(bckp|bckp-app)" >&2
  exit 1
fi

echo "Using profdata: $PROFDATA"
for b in "${BINARIES[@]}"; do echo "Using binary: $b"; done

# 4) Export lcov
/usr/bin/xcrun llvm-cov export \
  -format=lcov \
  -instr-profile "$PROFDATA" \
  "${BINARIES[@]}" \
  > "$LCOV_FILE"

# 5) Optional HTML via genhtml if installed (lcov package)
if command -v genhtml >/dev/null 2>&1; then
  genhtml -o "$HTML_DIR" "$LCOV_FILE" >/dev/null
  echo "HTML report: $HTML_DIR/index.html"
  if $OPEN_REPORT; then open "$HTML_DIR/index.html"; fi
fi

echo "LCOV report: $LCOV_FILE"
