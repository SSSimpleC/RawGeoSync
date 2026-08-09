#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
TEMP_ROOT="${TMPDIR:-/tmp}"
DERIVED_DATA="$(mktemp -d "${TEMP_ROOT%/}/RawGeoSync-Smoke.XXXXXX")"

cleanup() {
  case "$DERIVED_DATA" in
    "${TEMP_ROOT%/}"/RawGeoSync-Smoke.*)
      find "$DERIVED_DATA" -depth -delete 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT INT TERM

: "${RAWGEOSYNC_GPX_PATH:?请设置 RAWGEOSYNC_GPX_PATH}"
: "${RAWGEOSYNC_PHOTO_DIR:?请设置 RAWGEOSYNC_PHOTO_DIR}"

xcodebuild \
  -project "$PROJECT_ROOT/RawGeoSync.xcodeproj" \
  -scheme RawGeoSyncSmoke \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

"$DERIVED_DATA/Build/Products/Debug/RawGeoSyncSmoke" \
  "$RAWGEOSYNC_GPX_PATH" \
  "$RAWGEOSYNC_PHOTO_DIR" \
  --expect-current-sample
