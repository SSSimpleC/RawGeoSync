#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEMP_ROOT="${TMPDIR:-/tmp}"
DERIVED_DATA="$(mktemp -d "${TEMP_ROOT%/}/RawGeoSync-Tests.XXXXXX")"

cleanup() {
  case "$DERIVED_DATA" in
    "${TEMP_ROOT%/}"/RawGeoSync-Tests.*)
      find "$DERIVED_DATA" -depth -delete 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT INT TERM

"$PROJECT_ROOT/Scripts/verify-vendor.sh"
swift test \
  --package-path "$PROJECT_ROOT/RawGeoCore" \
  --scratch-path "$DERIVED_DATA/SwiftPM/RawGeoCore"
swift test \
  --package-path "$PROJECT_ROOT/MetadataInfrastructure" \
  --scratch-path "$DERIVED_DATA/SwiftPM/MetadataInfrastructure"

xcodebuild \
  -project "$PROJECT_ROOT/RawGeoSync.xcodeproj" \
  -scheme RawGeoSync \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  test
