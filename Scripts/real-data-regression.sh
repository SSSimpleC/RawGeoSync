#!/bin/zsh
set -euo pipefail
zmodload zsh/datetime

PROJECT_ROOT="${0:A:h:h}"
GPX_DIRECTORY="${RAWGEOSYNC_GPX_DIR:-}"
PHOTO_DIRECTORY="${RAWGEOSYNC_PHOTO_DIR:-}"
CLI_PATH="${RAWGEOSYNC_REGRESSION_CLI:-$PROJECT_ROOT/.local/bin/rawgeosync-regression}"
OUTPUT_ROOT="${RAWGEOSYNC_REGRESSION_OUTPUT_ROOT:-$PROJECT_ROOT/.local/real-regression}"
REQUIRE_CAPABILITY=0

usage() {
  cat <<'EOF'
用法：
  Scripts/real-data-regression.sh \
    --gpx-dir <GPX目录> \
    --photo-dir <照片目录> \
    [--cli <回归CLI>] \
    [--output-root <输出目录>] \
    [--require-capability]

也可使用 RAWGEOSYNC_GPX_DIR、RAWGEOSYNC_PHOTO_DIR、
RAWGEOSYNC_REGRESSION_CLI 和 RAWGEOSYNC_REGRESSION_OUTPUT_ROOT。

脚本只向 output-root 写入报告；仓库内输出必须已被 Git 忽略。它会用
macOS sandbox 拒绝源目录写入，并在前后比较 SHA-256 与基础文件元数据。

未找到 v2 回归 CLI，或 CLI 以状态 78 明确表示能力不可用时，默认输出
SKIP；其他能力探测错误均失败。发布门禁应加 --require-capability。
EOF
}

fail() {
  print -u2 "错误：$1"
  exit 1
}

capability_unavailable() {
  local message="$1"
  if (( REQUIRE_CAPABILITY )); then
    fail "$message"
  fi
  print "SKIP: $message"
  exit 0
}

validate_json_object() {
  local input="$1"
  local first_character
  first_character="$(awk 'match($0, /[^[:space:]]/) { print substr($0, RSTART, 1); exit }' "$input")"
  [[ "$first_character" == "{" ]] || return 1
  /usr/bin/plutil -convert xml1 -o /dev/null -- "$input" >/dev/null 2>&1
}

while (( $# > 0 )); do
  case "$1" in
    --gpx-dir)
      (( $# >= 2 )) || fail "--gpx-dir 缺少参数"
      GPX_DIRECTORY="$2"
      shift 2
      ;;
    --photo-dir)
      (( $# >= 2 )) || fail "--photo-dir 缺少参数"
      PHOTO_DIRECTORY="$2"
      shift 2
      ;;
    --cli)
      (( $# >= 2 )) || fail "--cli 缺少参数"
      CLI_PATH="$2"
      shift 2
      ;;
    --output-root)
      (( $# >= 2 )) || fail "--output-root 缺少参数"
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --require-capability)
      REQUIRE_CAPABILITY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "未知参数：$1"
      ;;
  esac
done

[[ -n "$GPX_DIRECTORY" ]] || fail "请通过 --gpx-dir 或 RAWGEOSYNC_GPX_DIR 提供GPX目录"
[[ -n "$PHOTO_DIRECTORY" ]] || fail "请通过 --photo-dir 或 RAWGEOSYNC_PHOTO_DIR 提供照片目录"
[[ -d "$GPX_DIRECTORY" ]] || fail "GPX目录不存在或不可读"
[[ -d "$PHOTO_DIRECTORY" ]] || fail "照片目录不存在或不可读"

GPX_DIRECTORY="${GPX_DIRECTORY:A}"
PHOTO_DIRECTORY="${PHOTO_DIRECTORY:A}"
CLI_PATH="${CLI_PATH:A}"

[[ -z "$(find "$GPX_DIRECTORY" -type l -print -quit)" ]] \
  || fail "GPX目录包含符号链接，无法证明链接目标保持只读"
[[ -z "$(find "$PHOTO_DIRECTORY" -type l -print -quit)" ]] \
  || fail "照片目录包含符号链接，无法证明链接目标保持只读"
[[ -n "$(find "$GPX_DIRECTORY" -type f -iname '*.gpx' -print -quit)" ]] \
  || fail "GPX目录中没有 .gpx 文件"
[[ -n "$(find "$PHOTO_DIRECTORY" -type f \( \
  -iname '*.nef' -o -iname '*.nrw' -o -iname '*.arw' -o -iname '*.cr2' \
  -o -iname '*.cr3' -o -iname '*.raf' -o -iname '*.orf' -o -iname '*.rw2' \
  -o -iname '*.dng' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.tif' \
  -o -iname '*.tiff' \) -print -quit)" ]] || fail "照片目录中没有受支持的照片"

[[ -x "$CLI_PATH" ]] || capability_unavailable "未找到可执行的v2回归CLI；通过 --cli 指定"

OUTPUT_ROOT="${OUTPUT_ROOT:A}"
validate_output_location() {
  local source_root
  for source_root in "$GPX_DIRECTORY" "$PHOTO_DIRECTORY"; do
    case "$OUTPUT_ROOT/" in
      "$source_root/"*)
        fail "输出目录与输入目录存在包含关系，拒绝运行"
        ;;
    esac
    case "$source_root/" in
      "$OUTPUT_ROOT/"*)
        fail "输出目录与输入目录存在包含关系，拒绝运行"
        ;;
    esac
  done
}
validate_output_location
if [[ "$OUTPUT_ROOT" == "$PROJECT_ROOT" ]]; then
  fail "输出目录不能是仓库根目录"
fi
case "$OUTPUT_ROOT/" in
  "$PROJECT_ROOT/"*)
    OUTPUT_RELATIVE_PATH="${OUTPUT_ROOT#"$PROJECT_ROOT/"}"
    git -C "$PROJECT_ROOT" check-ignore -q -- "$OUTPUT_RELATIVE_PATH" \
      || fail "仓库内输出目录必须先被.gitignore明确忽略"
    ;;
esac
mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="${OUTPUT_ROOT:A}"
validate_output_location

RUN_ROOT="$(mktemp -d "${OUTPUT_ROOT%/}/run.XXXXXX")"
CAPABILITIES="$RUN_ROOT/capabilities.json"
CAPABILITY_STDERR="$RUN_ROOT/capabilities.stderr.log"

set +e
"$CLI_PATH" capabilities --format json >"$CAPABILITIES" 2>"$CAPABILITY_STDERR"
CAPABILITY_STATUS=$?
set -e
(( CAPABILITY_STATUS == 0 )) \
  || {
    if (( CAPABILITY_STATUS == 78 )); then
      capability_unavailable "CLI明确报告v2回归能力不可用（报告保留在 $RUN_ROOT）"
    fi
    fail "CLI能力探测异常退出（状态 $CAPABILITY_STATUS；报告保留在 $RUN_ROOT）"
  }
validate_json_object "$CAPABILITIES" \
  || fail "CLI能力输出不是有效JSON（报告保留在 $RUN_ROOT）"

SCHEMA_VERSION="$(/usr/bin/plutil -extract schemaVersion raw -o - "$CAPABILITIES" 2>/dev/null || true)"
HAS_DRY_RUN="$(/usr/bin/plutil -extract features.fullCorpusDryRun raw -o - "$CAPABILITIES" 2>/dev/null || true)"
READ_ONLY_GUARANTEE="$(/usr/bin/plutil -extract guarantees.readOnlySourceDirectories raw -o - "$CAPABILITIES" 2>/dev/null || true)"
[[ "$SCHEMA_VERSION" == "1" && "$HAS_DRY_RUN" == "true" && "$READ_ONLY_GUARANTEE" == "true" ]] \
  || fail "CLI能力契约回退：缺少schemaVersion=1、fullCorpusDryRun或readOnlySourceDirectories（报告保留在 $RUN_ROOT）"

snapshot_tree() {
  local source_root="$1"
  local destination="$2"
  /usr/bin/perl -MFile::Find -MDigest::SHA -MJSON::PP -e '
    use strict;
    use warnings;
    my ($root, $destination) = @ARGV;
    chdir $root or die "cannot chdir to input root\n";
    my @paths;
    find({
      no_chdir => 1,
      wanted => sub {
        my $path = $File::Find::name;
        $path =~ s{^\./}{};
        $path = q{.} if $path eq q{};
        push @paths, $path;
      }
    }, q{.});
    open my $output, q{>:raw}, $destination or die "cannot create snapshot\n";
    for my $path (sort @paths) {
      my @metadata = lstat $path;
      die "cannot stat input entry\n" unless @metadata;
      my %record = (
        path => $path,
        device => $metadata[0],
        inode => $metadata[1],
        mode => sprintf(q{%04o}, $metadata[2] & 07777),
        linkCount => $metadata[3],
        uid => $metadata[4],
        gid => $metadata[5],
        mtime => $metadata[9],
        ctime => $metadata[10],
      );
      if (-l _) {
        $record{type} = q{symlink};
        $record{target} = readlink $path;
      } elsif (-d _) {
        $record{type} = q{directory};
      } elsif (-f _) {
        $record{type} = q{file};
        $record{size} = $metadata[7];
        open my $input, q{<:raw}, $path or die "cannot read input file\n";
        $record{sha256} = Digest::SHA->new(256)->addfile($input)->hexdigest;
        close $input;
      } else {
        $record{type} = q{other};
      }
      print {$output} JSON::PP->new->canonical->encode(\%record), "\n";
    }
    close $output;
  ' "$source_root" "$destination"
}

print "正在建立只读前置快照；该阶段会完整读取输入文件但不会写入输入目录。"
snapshot_tree "$GPX_DIRECTORY" "$RUN_ROOT/gpx.before.jsonl"
snapshot_tree "$PHOTO_DIRECTORY" "$RUN_ROOT/photos.before.jsonl"

REPORT="$RUN_ROOT/dry-run-report.json"
RUNTIME_LOG="$RUN_ROOT/runtime.stderr-and-time.log"
STDOUT_LOG="$RUN_ROOT/runtime.stdout.log"
SANDBOX_PROFILE="$RUN_ROOT/read-only-inputs.sb"
print -r -- '(version 1)
(allow default)
(deny file-write* (subpath (param "GPX_SOURCE")))
(deny file-write* (subpath (param "PHOTO_SOURCE")))' >"$SANDBOX_PROFILE"
START_TIME=$EPOCHREALTIME
set +e
/usr/bin/time -l /usr/bin/sandbox-exec \
  -D "GPX_SOURCE=$GPX_DIRECTORY" \
  -D "PHOTO_SOURCE=$PHOTO_DIRECTORY" \
  -f "$SANDBOX_PROFILE" \
  "$CLI_PATH" dry-run \
  --gpx-directory "$GPX_DIRECTORY" \
  --photo-directory "$PHOTO_DIRECTORY" \
  --report "$REPORT" \
  --read-only-source-directories \
  >"$STDOUT_LOG" 2>"$RUNTIME_LOG"
CLI_STATUS=$?
set -e
ELAPSED_SECONDS=$(( EPOCHREALTIME - START_TIME ))

print "正在建立后置快照并验证输入目录完全未变。"
snapshot_tree "$GPX_DIRECTORY" "$RUN_ROOT/gpx.after.jsonl"
snapshot_tree "$PHOTO_DIRECTORY" "$RUN_ROOT/photos.after.jsonl"

INPUTS_UNCHANGED=1
cmp -s "$RUN_ROOT/gpx.before.jsonl" "$RUN_ROOT/gpx.after.jsonl" || INPUTS_UNCHANGED=0
cmp -s "$RUN_ROOT/photos.before.jsonl" "$RUN_ROOT/photos.after.jsonl" || INPUTS_UNCHANGED=0
(( INPUTS_UNCHANGED == 1 )) || fail "dry-run改变了输入目录；证据保留在 $RUN_ROOT"
(( CLI_STATUS == 0 )) || fail "dry-run CLI退出码为 $CLI_STATUS；证据保留在 $RUN_ROOT"
[[ -s "$REPORT" ]] || fail "dry-run未生成报告；证据保留在 $RUN_ROOT"
validate_json_object "$REPORT" || fail "dry-run报告不是有效JSON；证据保留在 $RUN_ROOT"

REPORT_MODE="$(/usr/bin/plutil -extract mode raw -o - "$REPORT" 2>/dev/null || true)"
REPORT_SCHEMA="$(/usr/bin/plutil -extract schemaVersion raw -o - "$REPORT" 2>/dev/null || true)"
[[ "$REPORT_MODE" == "dry-run" && "$REPORT_SCHEMA" == "1" ]] \
  || fail "dry-run报告缺少mode=dry-run或schemaVersion=1；证据保留在 $RUN_ROOT"

MAX_RSS_BYTES="$(awk '/maximum resident set size/ { print $1; exit }' "$RUNTIME_LOG")"
printf 'PASS: 全量只读回归完成，输入目录SHA-256快照未变化。\n'
printf 'CLI wall time: %.3f 秒\n' "$ELAPSED_SECONDS"
if [[ -n "$MAX_RSS_BYTES" ]]; then
  printf 'CLI maximum resident set size: %s bytes\n' "$MAX_RSS_BYTES"
fi
print "本地证据目录：$RUN_ROOT"
