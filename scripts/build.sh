#!/bin/bash
# Builds build/Storage Manager.app with swiftc directly (only the Xcode Command Line Tools are needed).
# Usage: scripts/build.sh [--debug] [--check]
set -euo pipefail
cd "$(dirname "$0")/.."

OPT="-O"; CHECK=0
for arg in "$@"; do
  case "$arg" in
    --debug) OPT="-Onone -g" ;;
    --check) CHECK=1 ;;
  esac
done

command -v swiftc >/dev/null || { echo "swiftc not found. Install the tools with: xcode-select --install"; exit 1; }

OUT=.build/app
APP="build/Storage Manager.app"
mkdir -p "$OUT"

newer_than() { # true if any file in the given dirs is newer than $1
  local target=$1; shift
  [ ! -e "$target" ] || [ -n "$(find "$@" -newer "$target" -type f 2>/dev/null | head -1)" ]
}

if newer_than "$OUT/libStorageCore.a" Sources/StorageCore; then
  echo "• Compiling StorageCore…"
  swiftc $OPT -parse-as-library -module-name StorageCore -emit-library -static \
    -emit-module -emit-module-path "$OUT/StorageCore.swiftmodule" \
    -o "$OUT/libStorageCore.a" Sources/StorageCore/*.swift
fi

if [ "$CHECK" = 1 ]; then
  echo "• Running safety checks…"
  swiftc -Onone -I "$OUT" -L "$OUT" -lStorageCore Sources/SafetyChecks/main.swift -o "$OUT/SafetyChecks"
  "$OUT/SafetyChecks"
fi

if newer_than "$OUT/StorageManager" Sources/StorageCore Sources/StorageManager; then
  echo "• Compiling Storage Manager…"
  swiftc $OPT -parse-as-library -module-name StorageManager -I "$OUT" -L "$OUT" -lStorageCore \
    -o "$OUT/StorageManager" Sources/StorageManager/*.swift
fi

echo "• Assembling app bundle…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/StorageManager" "$APP/Contents/MacOS/StorageManager"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ Built $APP"
