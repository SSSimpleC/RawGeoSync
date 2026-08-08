#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

mkdir -p "$PROJECT_ROOT/.local/DerivedData"

xcodebuild \
  -project "$PROJECT_ROOT/RawGeoSync.xcodeproj" \
  -scheme RawGeoSync \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PROJECT_ROOT/.local/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build

