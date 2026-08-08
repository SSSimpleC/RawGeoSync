#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

"$PROJECT_ROOT/Scripts/verify-vendor.sh"
swift test --package-path "$PROJECT_ROOT/RawGeoCore"
swift test --package-path "$PROJECT_ROOT/MetadataInfrastructure"

mkdir -p "$PROJECT_ROOT/.local/DerivedData"
xcodebuild \
  -project "$PROJECT_ROOT/RawGeoSync.xcodeproj" \
  -scheme RawGeoSync \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PROJECT_ROOT/.local/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build
