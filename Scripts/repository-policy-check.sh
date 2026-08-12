#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"

fail() {
  print -u2 "仓库策略检查失败：$1"
  exit 1
}

print "检查脚本语法与权限"
for script in Scripts/*.sh; do
  /bin/zsh -n "$script" || fail "$script 不是有效的zsh脚本"
  [[ -x "$script" ]] || fail "$script 缺少可执行权限"
done

print "收集仓库文件清单"
SCAN_FILES=()
REPOSITORY_FILES=()
while IFS= read -r repository_file; do
  REPOSITORY_FILES+=("$repository_file")
  case "$repository_file" in
    Vendor/*) ;;
    *.md | *.sh | *.swift | *.lua | *.yml | *.yaml | *.json | *.jsonl | *.log | *.txt | *.plist \
      | *.xml | *.pbxproj | *.xcscheme | *.xcconfig)
      SCAN_FILES+=("$repository_file")
      ;;
  esac
done < <(git ls-files --cached --others --exclude-standard)

print "检查本机绝对路径"
ABSOLUTE_PATH_SCAN_FILES=()
for scan_file in "${SCAN_FILES[@]}"; do
  [[ "$scan_file" == "Scripts/repository-policy-check.sh" ]] \
    || ABSOLUTE_PATH_SCAN_FILES+=("$scan_file")
done
LOCAL_HOME_PATTERN='/(Users|home|Volumes|private|var/folders)/|[A-Za-z]:\\Users\\|\\\\[A-Za-z0-9_.-]+\\[A-Za-z0-9$_.-]+'
ABSOLUTE_PATH_MATCHES="$(
  grep -nEH "$LOCAL_HOME_PATTERN" -- "${ABSOLUTE_PATH_SCAN_FILES[@]}" || true
)"
[[ -z "$ABSOLUTE_PATH_MATCHES" ]] || {
  print -u2 "$ABSOLUTE_PATH_MATCHES"
  fail "跟踪文件包含本机绝对路径"
}

print "检查密钥与访问令牌"
SECRET_MATCHES="$(
  grep -nEH '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[0-9A-Za-z]{20,}|github_pat_[0-9A-Za-z_]{20,}|sk-[0-9A-Za-z_-]{20,}|xox[baprs]-[0-9A-Za-z-]{10,})' \
    -- "${SCAN_FILES[@]}" || true
)"
[[ -z "$SECRET_MATCHES" ]] || {
  print -u2 "$SECRET_MATCHES"
  fail "跟踪文件疑似包含私钥或访问令牌"
}

print "检查高精度坐标"
SENSITIVE_TEXT_FILES=()
for scan_file in "${SCAN_FILES[@]}"; do
  case "$scan_file" in
    *.md | *.sh | *.lua | *.yml | *.yaml | *.json | *.jsonl | *.log | *.txt | *.plist | *.xml \
      | *.pbxproj | *.xcscheme | *.xcconfig)
      SENSITIVE_TEXT_FILES+=("$scan_file")
      ;;
    *.swift)
      case "$scan_file" in
        */Tests/*) ;;
        *) SENSITIVE_TEXT_FILES+=("$scan_file") ;;
      esac
      ;;
  esac
done
COORDINATE_MATCHES="$(
  grep -nEH '[-+]?[0-9]{1,3}\.[0-9]{5,}[,[:space:]]+[-+]?[0-9]{1,3}\.[0-9]{5,}' \
    -- "${SENSITIVE_TEXT_FILES[@]}" || true
)"
[[ -z "$COORDINATE_MATCHES" ]] || {
  print -u2 "$COORDINATE_MATCHES"
  fail "文档或脚本疑似包含高精度坐标"
}

print "检查禁止纳入版本控制的媒体与回归产物"
FORBIDDEN_TRACKED_FILES=()
for repository_file in "${REPOSITORY_FILES[@]}"; do
  lower_name="${repository_file:l}"
  case "$lower_name" in
    *.nef|*.nrw|*.arw|*.cr2|*.cr3|*.raf|*.orf|*.rw2|*.dng|*.xmp|*.jpg|*.jpeg|*.tif \
      |*.tiff|*.heic|*.png)
      FORBIDDEN_TRACKED_FILES+=("$repository_file")
      ;;
    *.gpx)
      case "$repository_file" in
        */Tests/Fixtures/*.gpx | */Tests/Fixtures/**/*.gpx) ;;
        *) FORBIDDEN_TRACKED_FILES+=("$repository_file") ;;
      esac
      ;;
    */dry-run-report.json|*/capabilities.stderr.log|*/runtime.stderr-and-time.log \
      |*/runtime.stdout.log|*/gpx.before.jsonl|*/gpx.after.jsonl \
      |*/photos.before.jsonl|*/photos.after.jsonl)
      FORBIDDEN_TRACKED_FILES+=("$repository_file")
      ;;
  esac
done
(( ${#FORBIDDEN_TRACKED_FILES[@]} == 0 )) || {
  print -l -u2 -- "${FORBIDDEN_TRACKED_FILES[@]}"
  fail "仓库跟踪了真实照片、XMP或非合成GPX"
}

print "检查Git空白字符"
git diff --check
git diff --cached --check
git show --check --format= HEAD >/dev/null
print "仓库策略检查通过"
