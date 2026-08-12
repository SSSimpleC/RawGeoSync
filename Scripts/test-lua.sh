#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"

if [[ -n "${RAWGEOSYNC_LUA:-}" ]]; then
  LUA_EXECUTABLE="$RAWGEOSYNC_LUA"
elif [[ -x "$PROJECT_ROOT/.local/conda-lua51/bin/lua" ]]; then
  LUA_EXECUTABLE="$PROJECT_ROOT/.local/conda-lua51/bin/lua"
elif [[ -x "$PROJECT_ROOT/.local/conda-lua54/bin/lua" ]]; then
  LUA_EXECUTABLE="$PROJECT_ROOT/.local/conda-lua54/bin/lua"
elif command -v lua >/dev/null 2>&1; then
  LUA_EXECUTABLE="$(command -v lua)"
else
  print -u2 "找不到 Lua。请执行：conda create -y -p \"$PROJECT_ROOT/.local/conda-lua51\" -c conda-forge lua=5.1"
  exit 1
fi

"$LUA_EXECUTABLE" -v
for source_file in "$PROJECT_ROOT"/LightroomPlugin/RawGeoSync.lrplugin/*.lua \
  "$PROJECT_ROOT"/LightroomPlugin/Tests/*.lua; do
  "${LUA_EXECUTABLE:h}/luac" -p "$source_file"
done

"$LUA_EXECUTABLE" "$PROJECT_ROOT/LightroomPlugin/Tests/run.lua"
