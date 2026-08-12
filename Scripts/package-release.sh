#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEMP_ROOT="${TMPDIR:-/tmp}"
DERIVED_DATA="$(mktemp -d "${TEMP_ROOT%/}/RawGeoSync-Package.XXXXXX")"
VERSION="${1:-0.3.0}"
OUTPUT_ROOT="$PROJECT_ROOT/.local/release/v$VERSION"

cleanup() {
  case "$DERIVED_DATA" in
    "${TEMP_ROOT%/}"/RawGeoSync-Package.*)
      find "$DERIVED_DATA" -depth -delete 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT INT TERM

[[ "$VERSION" == <->.<->.<-> ]] || {
  print -u2 "版本必须采用 x.y.z 格式"
  exit 1
}

"$PROJECT_ROOT/Scripts/verify-lightroom-plugin.sh"
mkdir -p "$OUTPUT_ROOT"

xcodebuild \
  -project "$PROJECT_ROOT/RawGeoSync.xcodeproj" \
  -scheme RawGeoSync \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$DERIVED_DATA/Build/Products/Release/RawGeoSync.app"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$APP_VERSION" == "$VERSION" ]] || {
  print -u2 "App 版本 $APP_VERSION 与发布版本 $VERSION 不一致"
  exit 1
}

PLUGIN_VERSION="$({
  awk '/VERSION.major =/ { major=$3 } /VERSION.minor =/ { minor=$3 } /VERSION.revision =/ { revision=$3 } END { print major "." minor "." revision }' \
    "$PROJECT_ROOT/LightroomPlugin/RawGeoSync.lrplugin/Info.lua"
})"
[[ "$PLUGIN_VERSION" == "$VERSION" ]] || {
  print -u2 "插件版本 $PLUGIN_VERSION 与发布版本 $VERSION 不一致"
  exit 1
}

diff -qr \
  "$PROJECT_ROOT/LightroomPlugin/RawGeoSync.lrplugin" \
  "$APP/Contents/Resources/RawGeoSync.lrplugin"

APP_ARCHIVE="$OUTPUT_ROOT/RawGeoSync-$VERSION-macOS-arm64.zip"
PLUGIN_ARCHIVE="$OUTPUT_ROOT/RawGeoSync-Lightroom-Bridge-$VERSION.zip"
CHECKSUMS="$OUTPUT_ROOT/SHA256SUMS.txt"

ditto -c -k --keepParent --sequesterRsrc "$APP" "$APP_ARCHIVE"
ditto -c -k --keepParent \
  "$PROJECT_ROOT/LightroomPlugin/RawGeoSync.lrplugin" \
  "$PLUGIN_ARCHIVE"
cp "$PROJECT_ROOT/Docs/LIGHTROOM_BRIDGE.md" "$OUTPUT_ROOT/Lightroom-Bridge-使用指南.md"
(
  cd "$OUTPUT_ROOT"
  shasum -a 256 \
    "${APP_ARCHIVE:t}" \
    "${PLUGIN_ARCHIVE:t}" \
    'Lightroom-Bridge-使用指南.md' > "${CHECKSUMS:t}"
)

print "发布物已生成：$OUTPUT_ROOT"
