#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
TEMP_ROOT="${TMPDIR:-/tmp}"
DERIVED_DATA="$(mktemp -d "${TEMP_ROOT%/}/RawGeoSync-Release.XXXXXX")"
OUTPUT_ROOT="${RAWGEOSYNC_INSTALL_DIR:-${HOME}/Applications}"
FINAL_APP="$OUTPUT_ROOT/RawGeoSync.app"

cleanup() {
  case "$DERIVED_DATA" in
    "${TEMP_ROOT%/}"/RawGeoSync-Release.*)
      find "$DERIVED_DATA" -depth -delete 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT INT TERM

xcodebuild \
  -project "$PROJECT_ROOT/RawGeoSync.xcodeproj" \
  -scheme RawGeoSync \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "$OUTPUT_ROOT"
STAGED_APP="$OUTPUT_ROOT/.RawGeoSync.app.staged"
if [[ -e "$STAGED_APP" ]]; then
  find "$STAGED_APP" -depth -delete
fi
ditto --noqtn "$DERIVED_DATA/Build/Products/Release/RawGeoSync.app" "$STAGED_APP"
xattr -dr com.apple.quarantine "$STAGED_APP" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
if [[ -e "$FINAL_APP" ]]; then
  find "$FINAL_APP" -depth -delete
fi
mv "$STAGED_APP" "$FINAL_APP"
xattr -dr com.apple.quarantine "$FINAL_APP" 2>/dev/null || true
codesign --verify --deep --strict "$FINAL_APP"

print "Release 应用已更新："
print "$FINAL_APP"
