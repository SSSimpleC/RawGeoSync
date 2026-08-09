#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
print -u2 "提示：real-sample-smoke.sh 已由参数化的只读全量回归接口取代。"
exec "$PROJECT_ROOT/Scripts/real-data-regression.sh" "$@"
