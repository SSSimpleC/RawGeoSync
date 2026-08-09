#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

xcodebuild \
  -project "$PROJECT_ROOT/RawGeoSync.xcodeproj" \
  -scheme RawGeoSync \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PROJECT_ROOT/.local/DerivedData-Release-Final" \
  CODE_SIGNING_ALLOWED=NO \
  build

print "Release 应用已更新："
print "$PROJECT_ROOT/.local/DerivedData-Release-Final/Build/Products/Release/RawGeoSync.app"
