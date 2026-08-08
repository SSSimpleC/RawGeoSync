#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

: "${RAWGEOSYNC_GPX_PATH:?请设置 RAWGEOSYNC_GPX_PATH}"
: "${RAWGEOSYNC_PHOTO_DIR:?请设置 RAWGEOSYNC_PHOTO_DIR}"

xcodebuild \
  -project "$PROJECT_ROOT/RawGeoSync.xcodeproj" \
  -scheme RawGeoSyncSmoke \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PROJECT_ROOT/.local/SmokeDerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

"$PROJECT_ROOT/.local/SmokeDerivedData/Build/Products/Debug/RawGeoSyncSmoke" \
  "$RAWGEOSYNC_GPX_PATH" \
  "$RAWGEOSYNC_PHOTO_DIR" \
  --expect-current-sample
