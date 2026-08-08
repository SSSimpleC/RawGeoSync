#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
VENDOR_ROOT="$PROJECT_ROOT/Vendor/ExifTool"
EXPECTED_VERSION="13.59"

[[ -x "$VENDOR_ROOT/exiftool" ]]
[[ -f "$VENDOR_ROOT/lib/Image/ExifTool.pm" ]]
[[ -f "$VENDOR_ROOT/VERSION.json" ]]

ACTUAL_VERSION="$(/usr/bin/perl "$VENDOR_ROOT/exiftool" -ver)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  print -u2 "ExifTool版本不符：预期 $EXPECTED_VERSION，实际 $ACTUAL_VERSION"
  exit 1
fi

/usr/bin/python3 - "$VENDOR_ROOT/VERSION.json" "$EXPECTED_VERSION" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if manifest.get("version") != sys.argv[2]:
    raise SystemExit("VERSION.json 中的版本与锁定版本不符")
if len(manifest.get("archiveSHA256", "")) != 64:
    raise SystemExit("VERSION.json 缺少有效的归档 SHA-256")
PY

print "ExifTool $ACTUAL_VERSION vendor校验通过"

