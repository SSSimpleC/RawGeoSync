#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEMP_ROOT="${TMPDIR:-/tmp}"
DERIVED_DATA="$(mktemp -d "${TEMP_ROOT%/}/RawGeoSync-CI.XXXXXX")"

cleanup() {
  case "$DERIVED_DATA" in
    "${TEMP_ROOT%/}"/RawGeoSync-CI.*)
      find "$DERIVED_DATA" -depth -delete 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT INT TERM

XCODE_VERSION="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
awk -v actual="$XCODE_VERSION" -v minimum="26.3" '
  BEGIN {
    split(actual, a, ".");
    split(minimum, m, ".");
    if ((a[1] + 0) < (m[1] + 0) || ((a[1] + 0) == (m[1] + 0) && (a[2] + 0) < (m[2] + 0))) {
      exit 1;
    }
  }
' || {
  print -u2 "CI要求Xcode 26.3或更高版本，当前为 $XCODE_VERSION"
  exit 1
}

"$PROJECT_ROOT/Scripts/repository-policy-check.sh"
"$PROJECT_ROOT/Scripts/verify-vendor.sh"
"$PROJECT_ROOT/Scripts/format-check.sh"
"$PROJECT_ROOT/Scripts/test.sh"

swift test \
  --configuration release \
  --package-path "$PROJECT_ROOT/RawGeoCore" \
  --scratch-path "$DERIVED_DATA/SwiftPM/RawGeoCore-Release"
swift test \
  --configuration release \
  --package-path "$PROJECT_ROOT/MetadataInfrastructure" \
  --scratch-path "$DERIVED_DATA/SwiftPM/MetadataInfrastructure-Release"

xcodebuild \
  -project "$PROJECT_ROOT/RawGeoSync.xcodeproj" \
  -scheme RawGeoSync \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA/App" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project "$PROJECT_ROOT/RawGeoSync.xcodeproj" \
  -scheme RawGeoSync \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA/App" \
  CODE_SIGNING_ALLOWED=NO \
  analyze

print "CI等价门禁全部通过"
