#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${DAILY_WALLPAPER_BUILD_DIR:-$PROJECT_ROOT/.build}"

xcodebuild \
  -project "$PROJECT_ROOT/DailyWallpaper.xcodeproj" \
  -scheme DailyWallpaper \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_IDENTITY=- \
  test
