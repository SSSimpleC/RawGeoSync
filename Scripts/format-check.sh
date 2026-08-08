#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

SWIFT_FILES=()
while IFS= read -r file; do
  SWIFT_FILES+=("$file")
done < <(find "$PROJECT_ROOT/RawGeoCore" "$PROJECT_ROOT/MetadataInfrastructure" "$PROJECT_ROOT/RawGeoSyncApp" -name '*.swift' -type f | sort)

if (( ${#SWIFT_FILES[@]} == 0 )); then
  exit 0
fi

xcrun swift-format lint --strict "${SWIFT_FILES[@]}"
