#!/usr/bin/env bash
set -euo pipefail
mkdir -p artifacts
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb logcat -c || true
adb shell am start -n space.tsukuyomi.tsukuyomi_space_app/.MainActivity
for attempt in $(seq 1 30); do
  adb logcat -d -b main -v brief > artifacts/android-smoke.log 2>&1 || true
  if grep -q 'TSUKUYOMI_LIVE2D_OK' artifacts/android-smoke.log; then
    grep 'TSUKUYOMI_LIVE2D_OK' artifacts/android-smoke.log
    exit 0
  fi
  if grep -q 'TSUKUYOMI_LIVE2D_FAILED' artifacts/android-smoke.log; then
    cat artifacts/android-smoke.log
    exit 1
  fi
  sleep 2
done
cat artifacts/android-smoke.log
exit 1
