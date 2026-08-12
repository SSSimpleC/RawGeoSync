#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEMP_ROOT="${TMPDIR:-/tmp}"

stage() {
  print "\n==> $1"
}

stage "准备CI临时目录"
DERIVED_DATA="$(mktemp -d "${TEMP_ROOT%/}/RawGeoSync-CI.XXXXXX")" || {
  print -u2 "无法在 $TEMP_ROOT 创建CI临时目录"
  exit 1
}

cleanup() {
  case "$DERIVED_DATA" in
    "${TEMP_ROOT%/}"/RawGeoSync-CI.*)
      find "$DERIVED_DATA" -depth -delete 2>/dev/null || true
      ;;
  esac
}
trap cleanup EXIT INT TERM

XCODE_VERSION="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
print "使用Xcode $XCODE_VERSION（$DEVELOPER_DIR）"
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

stage "检查仓库隐私与文件策略"
"$PROJECT_ROOT/Scripts/repository-policy-check.sh"
stage "校验内置ExifTool"
"$PROJECT_ROOT/Scripts/verify-vendor.sh"
stage "校验Lightroom插件契约"
"$PROJECT_ROOT/Scripts/verify-lightroom-plugin.sh"
stage "检查Swift格式"
"$PROJECT_ROOT/Scripts/format-check.sh"
stage "运行Debug测试与应用构建"
"$PROJECT_ROOT/Scripts/test.sh"

stage "运行RawGeoCore Release测试"
swift test \
  --configuration release \
  --package-path "$PROJECT_ROOT/RawGeoCore" \
  --scratch-path "$DERIVED_DATA/SwiftPM/RawGeoCore-Release"
stage "运行MetadataInfrastructure Release测试"
swift test \
  --configuration release \
  --package-path "$PROJECT_ROOT/MetadataInfrastructure" \
  --scratch-path "$DERIVED_DATA/SwiftPM/MetadataInfrastructure-Release"

stage "构建Release应用"
xcodebuild \
  -project "$PROJECT_ROOT/RawGeoSync.xcodeproj" \
  -scheme RawGeoSync \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA/App" \
  CODE_SIGNING_ALLOWED=NO \
  build

stage "运行静态分析"
xcodebuild \
  -project "$PROJECT_ROOT/RawGeoSync.xcodeproj" \
  -scheme RawGeoSync \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA/App" \
  CODE_SIGNING_ALLOWED=NO \
  analyze

print "CI等价门禁全部通过"
