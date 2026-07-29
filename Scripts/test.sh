#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${DAILY_WALLPAPER_BUILD_DIR:-$PROJECT_ROOT/.build}"
TEST_DESTINATION="${DAILY_WALLPAPER_TEST_DESTINATION:-platform=macOS,arch=arm64}"

xcodebuild \
  -project "$PROJECT_ROOT/DailyWallpaper.xcodeproj" \
  -scheme DailyWallpaper \
  -configuration Debug \
  -destination "$TEST_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_IDENTITY=- \
  test
