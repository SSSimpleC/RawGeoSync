# RawGeoSync

RawGeoSync 是一款离线 macOS 应用。它把相机照片的拍摄时间与 GPX 轨迹进行匹配，在用户预览和确认后生成一份位置清单，再由配套的 Lightroom Classic 插件批量写入 Catalog。兼容模式仍可写入 Lightroom 可读取的 XMP sidecar；两种模式都永远不修改相机 RAW 文件。

## 核心能力

- 支持选择或拖入单个 GPX 文件，也可递归读取目录内“一生足迹”导出的 GPX 1.0/1.1 轨迹。
- 读取 Nikon Z50 NEF 的原始拍摄时间，并对常见 RAW、DNG、JPEG、TIFF 提供实验性扫描。
- 支持 IANA 时区和相机时钟秒级偏移。
- 区分可靠匹配、待确认匹配、停留候选和缺轨。
- 在表格与地图上批量复核位置。
- 默认每个照片根目录只生成一个 `RawGeoSync.locations.jsonl`，避免逐照片 sidecar 带来的文件数量翻倍。
- 配套 Lightroom Classic 插件支持预检、批量写入、复读验证和跨重启整批撤销。
- 兼容模式继续原子创建或合并同名 XMP，保留 Lightroom 已有编辑。

v0.2 的设计在此基础上引入可追溯的多来源证据链：照片自带 GPS、GPX、相机定位、同一拍摄 burst、照片序列、跨相机锚点和活动区都可以提供候选。弱候选只补足缺失，不能覆盖强候选；冲突、传播跳数和用户确认会保留在本地事务记录中。详细规则见 [ADR 0002](Docs/Decisions/0002-matching-v2.md)。

## 数据安全原则

- RAW 只读；默认只写单一桥接清单和 Lightroom Catalog，兼容接口只接受 XMP sidecar 目标。
- 分析默认为 dry run；只有用户确认后才写入。
- 不上传照片、轨迹、坐标或日志，不做反向地理编码。
- MapKit 地图仅在地图可见时连接 Apple 获取地图瓦片。
- 真实 GPX、RAW、位置清单和本地测试副本都被 Git 忽略。

## 开发环境

- macOS 15+
- Xcode 26.3+
- Swift 6（严格并发检查）
- ExifTool 固定随应用资源分发，不要求用户安装 Homebrew
- Lightroom Classic 15.4.1+（使用默认 Catalog Bridge 时）

首次构建前，确保活动开发目录为：

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

开发命令：

```sh
./Scripts/repository-policy-check.sh
./Scripts/test.sh
./Scripts/build.sh
```

运行与 CI 等价的 Debug/Release、静态分析和仓库策略门禁：

```sh
./Scripts/ci.sh
```

使用未提交的真实数据做只读全量回归：

```sh
./Scripts/real-data-regression.sh \
  --gpx-dir "$GPX_DIR" \
  --photo-dir "$PHOTO_DIR" \
  --cli "$REGRESSION_CLI"
```

回归接口接收 GPX 目录和照片目录，使用 macOS sandbox 拒绝源目录写入，并在运行前后比较逐文件 SHA-256 与基础元数据；报告默认只写入被 Git 忽略的 `.local/real-regression/`。找不到 v2 CLI 或 CLI 明确返回“能力不可用”时脚本会输出 `SKIP`，其他能力探测错误会失败；发布验收加 `--require-capability`，不得把跳过当作通过。详细契约和性能门槛见 [测试规范](Docs/TESTING.md)。

最终 Release 应用安装到 `~/Applications/RawGeoSync.app`，Debug 构建位于 `.local/Debug`。Xcode DerivedData 使用系统临时目录并在命令结束后清理，避免在项目内留下几十 GB 的稀疏编译缓存。真实样本和本地报告只能放在被 Git 忽略的 `.local/` 或用户自选目录，不得写入或复制回原始照片目录。

## 使用建议

默认工作流：

1. 在 RawGeoSync 选择 GPX 和照片根目录，分析并勾选要应用位置的照片。
2. 生成照片根目录中的 `RawGeoSync.locations.jsonl`。
3. 先把这些照片导入 Lightroom Classic。
4. 安装随 App 提供的 RawGeoSync 插件，在“图库 → 插件增效工具”中导入清单。
5. 检查插件预览后应用；不同的现有 GPS 会按本次清单覆盖，离线照片会跳过。

Lightroom 开启“自动将更改写入 XMP”时，Lightroom 自己仍可能创建 sidecar；插件无法通过公开 SDK 可靠关闭或检测此设置。要保持每个照片目录只有一份清单，请在 Lightroom 中关闭该选项。

传统 XMP 模式建议在 Lightroom 导入或修改 sidecar 前执行。若照片或 XMP 在预览后发生变化，应用会把它标记为冲突并跳过。

分析完成后，只有“可靠”结果默认勾选写入；停留候选、最近点和其他待确认结果必须按区间复核并主动勾选。写入前应用会展示创建、更新、已应用与冲突数量。撤销仅在 sidecar 未被 Lightroom 等程序继续修改时执行，避免抹掉后续编辑。

“全选照片”直接切换当前“全部 / 可靠 / 待确认 / 粗略 / 未匹配”筛选结果左侧的写入复选框，不是表格行选择。未匹配照片可以预先勾选，但在用户为其指定有效坐标之前仍会安全跳过；已有 GPS 的照片也会被勾选，并在写入预检中明确列为更新或冲突。

本机 Release 应用位于 `~/Applications/RawGeoSync.app`。将应用安装到不受桌面 iCloud FileProvider 管理的用户应用程序目录，可以避免隔离属性被云端元数据反复恢复；构建脚本还会生成仅供本机运行的临时签名。若未来面向他人分发，仍需另行配置 Developer ID、Hardened Runtime 和 Apple 公证。可通过 `RAWGEOSYNC_INSTALL_DIR` 自定义安装目录。

日常启动可以在 Finder 中双击该 `.app`，或在终端执行：

```sh
open "$HOME/Applications/RawGeoSync.app"
```

如果源码发生变化，在项目目录执行 `./Scripts/build-release.sh` 即会重新构建并更新用户“应用程序”目录中的版本，之后可从 Finder、Spotlight 或启动台打开。

相机时钟偏移定义为：`相机显示时间 - 真实当地时间`。相机快了 30 秒时填写 `+30`，匹配时应用会从照片时间减去30秒。

## 许可证

RawGeoSync 使用 MIT License。内置 ExifTool 及其 Perl 库遵循上游各自许可证，详见 `Vendor/ExifTool` 中的第三方声明。

## 项目规范

- [贡献指南](CONTRIBUTING.md)
- [安全策略](SECURITY.md)
- [隐私说明](Docs/PRIVACY.md)
- [测试与验收](Docs/TESTING.md)
- [Lightroom Catalog Bridge 使用指南](Docs/LIGHTROOM_BRIDGE.md)
- [发布清单](Docs/RELEASE.md)
- [匹配 v2 决策](Docs/Decisions/0002-matching-v2.md)
- [Lightroom Catalog Bridge 决策](Docs/Decisions/0003-lightroom-catalog-bridge.md)
- [更新日志](CHANGELOG.md)
