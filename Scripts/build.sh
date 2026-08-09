#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEMP_ROOT="${TMPDIR:-/tmp}"
DERIVED_DATA="$(mktemp -d "${TEMP_ROOT%/}/RawGeoSync-Debug.XXXXXX")"
OUTPUT_ROOT="$PROJECT_ROOT/.local/Debug"
FINAL_APP="$OUTPUT_ROOT/RawGeoSync.app"
PREVIOUS_APP="$OUTPUT_ROOT/.RawGeoSync.app.previous"

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
xattr -dr com.apple.quarantine "$STAGED_APP" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
if [[ -e "$PREVIOUS_APP" ]]; then
  find "$PREVIOUS_APP" -depth -delete
fi
if [[ -e "$FINAL_APP" ]]; then
  mv "$FINAL_APP" "$PREVIOUS_APP"
fi
INSTALL_OK=0
if mv "$STAGED_APP" "$FINAL_APP"; then
  INSTALL_OK=1
fi
xattr -dr com.apple.quarantine "$FINAL_APP" 2>/dev/null || true
if (( INSTALL_OK )) && codesign --verify --deep --strict "$FINAL_APP"; then
  [[ ! -e "$PREVIOUS_APP" ]] || find "$PREVIOUS_APP" -depth -delete
else
  [[ ! -e "$FINAL_APP" ]] || find "$FINAL_APP" -depth -delete
  [[ ! -e "$PREVIOUS_APP" ]] || mv "$PREVIOUS_APP" "$FINAL_APP"
  print -u2 "Debug 应用安装验证失败；已恢复上一版本。"
  exit 1
fi

print "Debug 应用已更新："
print "$FINAL_APP"
