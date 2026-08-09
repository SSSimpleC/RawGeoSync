# 测试与验收规范

## 测试层级

1. `RawGeoCore` 合成单元测试覆盖 GPX、时间归一化、规则边界、证据优先级、传播单跳和冲突解析。
2. `MetadataInfrastructure` 合成与 ExifTool 契约测试覆盖只读扫描、XMP 合并、幂等、原子写入、取消、失败继续和安全撤销。
3. 应用构建与静态分析验证 Swift 6 严格并发和模块集成。
4. 参数化真实数据回归只执行 dry-run，用于发现记录器行为、相机元数据和全量性能问题。
5. 写入验收只对 `.local/` 中的最小副本执行，不接触原始目录。

测试数量会随功能演进，不在文档中锁定。门禁以命令退出状态、行为断言和不变量为准。

## 本地与 CI 命令

快速开发验证：

```sh
./Scripts/repository-policy-check.sh
./Scripts/format-check.sh
./Scripts/test.sh
```

与 CI 等价的完整门禁会额外运行两个 Package 的 Release 测试、应用 Release 构建和 `xcodebuild analyze`：

```sh
./Scripts/ci.sh
```

## v2 规则验收

合成夹具至少覆盖以下边界及其门槛两侧：

- GPX 断段、倒序、重复时间戳、孤立坏点、长空洞和航班边界；
- direct、same-asset、GPX、相机 fix、burst、sequence、有界停留、跨相机和活动区的优先级；
- 传播只使用非复核 primary anchor、只传播一跳且不能形成循环；
- 可比较强候选相距超过冲突门槛时保持 `conflict`；
- 活动区等弱候选不能覆盖强候选；
- 源无 hacc 时保持 unknown，不产生伪米级精度；
- 时区、夏令时歧义、相机时钟偏移和多相机校准；
- 每张照片恰有一个终态，分类计数之和等于扫描照片数。

阈值改变需要添加“刚好低于、等于、刚好高于”三类测试，并同步 ADR。

## 真实只读全量回归

真实路径只能通过参数或环境变量提供：

```sh
./Scripts/real-data-regression.sh \
  --gpx-dir "$GPX_DIR" \
  --photo-dir "$PHOTO_DIR" \
  --cli "$REGRESSION_CLI"
```

脚本要求 GPX **目录** 和照片目录，并拒绝包含符号链接的输入，避免链接目标逃出只读证明范围。仓库内输出目录必须由 `git check-ignore` 明确确认已忽略。脚本通过 macOS sandbox 拒绝对两个源目录的写入，再把能力声明、CLI 输出、dry-run 报告、性能日志和输入目录前后内容/基础元数据快照写到 `.local/real-regression/`。未来 CLI 的稳定契约为：

```text
<cli> capabilities --format json
<cli> dry-run --gpx-directory <dir> --photo-directory <dir> \
  --report <local-json> --read-only-source-directories
```

能力 JSON 必须声明 `schemaVersion=1`、`features.fullCorpusDryRun=true` 和 `guarantees.readOnlySourceDirectories=true`；报告必须声明 `schemaVersion=1` 与 `mode=dry-run`。找不到 CLI，或 CLI 以退出状态 78 明确表示能力不可用时，脚本默认输出 `SKIP`；发布验收使用 `--require-capability` 将这两种情况变为失败。CLI 已存在时的崩溃、权限错误、无效 JSON 或契约回退一律失败，不能降级成跳过。

`--require-capability` 只证明发布候选具备并完成了一次全量 dry-run，不替代下面的重复性、语义和性能验收。当前 CLI 报告 API 尚未稳定，因此脚本只机器校验 schema、mode、退出状态、sandbox 和输入快照；唯一终态、reason code、冲突与规则分布由发布清单显式复核，待报告 schema 冻结后再提升为机器门禁。

真实回归通过条件：

- sandbox 未报告源目录写入，且 GPX 和照片目录前后内容哈希、inode、mode、uid/gid、链接数、mtime 和 ctime 一致，没有新增 XMP、缓存或隐藏文件；
- 所有可读取照片进入唯一终态，失败项有脱敏 reason code；
- 重复运行在相同输入与配置下得到相同分类、候选来源和规则分布；
- 强冲突、飞行边界和跨活动段不会被覆盖优先模式越过；
- 报告不把证据等级描述为概率或传感器精度。

精度字段还必须覆盖四种组合：源 hacc 与几何推断半径可同时存在；多锚推断可以 hacc 为 nil 而半径非 nil；单锚且无源 hacc 时两者都为 nil；UI 与报告始终把“传感器精度”和“推断范围”分栏展示。

## 性能验收

CLI 运行时间与输入哈希时间分开记录。`real-data-regression.sh` 报告 CLI wall time 和 macOS `time -l` 的 maximum resident set size；逐文件 SHA-256 只用于只读证明，不计入匹配性能。

发布候选在同一台机器、相同电源模式、相同输入和空闲系统下连续运行三次，取中位数：

- 分类计数、规则分布和终态必须三次完全一致；
- 相对已接受基线，wall time 不得回退超过 20%，峰值常驻内存不得回退超过 15%；
- 没有历史基线时，先记录脱敏的照片数、轨迹点数、wall time、峰值内存和工具链，作为该机器的 v0.2 基线；
- 合成缩放测试把照片数和轨迹点数各扩大一倍时，wall time 不应超过原来的 2.5 倍；超出必须分析算法复杂度后才能发布。

不同机器的绝对耗时不可直接比较。性能证据只提交聚合指标，不提交本地路径、文件名、坐标或报告原件。

本地基线保存在 `.local/performance-baselines/<机器类别>-<工具链>.json`，至少包含 schemaVersion、应用版本、macOS/Xcode/Swift 版本、脱敏语料标识、照片数、轨迹点数、三次 wall/RSS 原始值和中位数。比较公式为 `(候选中位数 - 基线中位数) / 基线中位数`；wall 结果不得大于 0.20，RSS 不得大于 0.15。缩放夹具记录一倍与两倍规模的同一指标，并计算 `两倍 / 一倍`，不得大于 2.5。基线文件只留本机，不进入 Git。

## 副本写入验收

从真实数据中选择最小集合，复制到 `.local/write-regression/<随机目录>/` 后执行：首次预检、应用、复读、第二次预检、撤销。必须证明 RAW SHA-256 始终不变，第二次预检为 already-applied 且 XMP mtime 不变，撤销不会覆盖之后被 Lightroom 修改的 sidecar。原始目录的前后快照也必须保持一致。
