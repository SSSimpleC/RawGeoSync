#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
TEMP_ROOT="${TMPDIR:-/tmp}"
DERIVED_DATA="$(mktemp -d "${TEMP_ROOT%/}/RawGeoSync-Debug.XXXXXX")"
OUTPUT_ROOT="$PROJECT_ROOT/.local/Debug"
FINAL_APP="$OUTPUT_ROOT/RawGeoSync.app"

cleanup() {
  case "$DERIVED_DATA" in
    "${TEMP_ROOT%/}"/RawGeoSync-Debug.*)
      find "$DERIVED_DATA" -depth -delete 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT INT TERM

xcodebuild \
  -project "$PROJECT_ROOT/RawGeoSync.xcodeproj" \
  -scheme RawGeoSync \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "$OUTPUT_ROOT"
STAGED_APP="$OUTPUT_ROOT/.RawGeoSync.app.staged"
if [[ -e "$STAGED_APP" ]]; then
  find "$STAGED_APP" -depth -delete
fi
ditto "$DERIVED_DATA/Build/Products/Debug/RawGeoSync.app" "$STAGED_APP"
if [[ -e "$FINAL_APP" ]]; then
  find "$FINAL_APP" -depth -delete
fi
mv "$STAGED_APP" "$FINAL_APP"

print "Debug 应用已更新："
print "$FINAL_APP"
