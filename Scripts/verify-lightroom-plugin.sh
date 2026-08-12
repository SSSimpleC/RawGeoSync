#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
PLUGIN_ROOT="$PROJECT_ROOT/LightroomPlugin/RawGeoSync.lrplugin"

[[ -f "$PLUGIN_ROOT/Info.lua" ]] || {
  print -u2 "缺少 Lightroom 插件 Info.lua"
  exit 1
}
[[ -f "$PLUGIN_ROOT/MetadataDefinition.lua" ]] || {
  print -u2 "缺少 Lightroom 元数据声明"
  exit 1
}

grep -q 'LrToolkitIdentifier = "com.sssimplec.rawgeosync.lightroom"' "$PLUGIN_ROOT/Info.lua"
grep -q 'VERSION.major = 0' "$PLUGIN_ROOT/Info.lua"
grep -q 'VERSION.minor = 3' "$PLUGIN_ROOT/Info.lua"
grep -q 'VERSION.revision = 0' "$PLUGIN_ROOT/Info.lua"
grep -q 'metadataFieldsForPhotos' "$PLUGIN_ROOT/MetadataDefinition.lua"
grep -q 'Manifest.FORMAT = "com.sssimplec.rawgeosync.locations"' "$PLUGIN_ROOT/Manifest.lua"
grep -q 'Manifest.SCHEMA_MAJOR = 1' "$PLUGIN_ROOT/Manifest.lua"
grep -q 'Manifest.SCHEMA_MINOR = 0' "$PLUGIN_ROOT/Manifest.lua"

print "Lightroom 插件版本、标识和 schema 校验通过"
