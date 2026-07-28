#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIGURATION="${DAILY_WALLPAPER_CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DAILY_WALLPAPER_BUILD_DIR:-$PROJECT_ROOT/.build}"

xcodebuild \
  -project "$PROJECT_ROOT/DailyWallpaper.xcodeproj" \
  -scheme DailyWallpaper \
  -configuration "$BUILD_CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGN_IDENTITY=- \
  build

echo "App: $DERIVED_DATA_PATH/Build/Products/$BUILD_CONFIGURATION/DailyWallpaper.app"
