#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/android"

if command -v gradle >/dev/null 2>&1; then
  gradle assembleDebug
elif [ -x "$ROOT/build/gradle-8.13/bin/gradle" ]; then
  "$ROOT/build/gradle-8.13/bin/gradle" assembleDebug
else
  echo "Gradle not found. Install Gradle 8.13+ (e.g. brew install gradle) and retry." >&2
  exit 1
fi

mkdir -p "$ROOT/dist"
cp "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk" "$ROOT/dist/neardoc-android.apk"
echo "Built: $ROOT/dist/neardoc-android.apk"
