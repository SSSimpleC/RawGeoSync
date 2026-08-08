# RawGeoSync

RawGeoSync 是一款离线 macOS 应用。它把相机照片的拍摄时间与 GPX 轨迹进行匹配，在用户预览和确认后，将 GPS 写入 Lightroom 可读取的 XMP sidecar。应用永远不修改相机 RAW 文件。

## 首版能力

- 读取“一生足迹”导出的 GPX 1.0/1.1 轨迹。
- 读取 Nikon Z50 NEF 的原始拍摄时间，并对常见 RAW、DNG、JPEG、TIFF 提供实验性扫描。
- 支持 IANA 时区和相机时钟秒级偏移。
- 区分可靠匹配、待确认匹配、停留候选和缺轨。
- 在表格与地图上批量复核位置。
- 原子创建或合并同名 XMP，保留 Lightroom 已有编辑。
- 支持幂等写入、冲突检测、事务记录和安全撤销。

## 数据安全原则

- RAW 只读，写入接口只接受 XMP sidecar 目标。
- 分析默认为 dry run；只有用户确认后才写入。
- 不上传照片、轨迹、坐标或日志，不做反向地理编码。
- MapKit 地图仅在地图可见时连接 Apple 获取地图瓦片。
- 真实 GPX、RAW 和本地测试副本都被 Git 忽略。

## 开发环境

- macOS 15+
- Xcode 26.3+
- Swift 6（严格并发检查）
- ExifTool 固定随应用资源分发，不要求用户安装 Homebrew

首次构建前，确保活动开发目录为：

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

开发命令：

```sh
./Scripts/test.sh
./Scripts/build.sh
```

使用当前真实样本做只读验收：

```sh
RAWGEOSYNC_GPX_PATH='/Users/simplechen/Downloads/2026.01.01-2026.12.31.gpx' \
RAWGEOSYNC_PHOTO_DIR='/Users/simplechen/Picture/2026-8-8 我们四在东莞/Z50' \
./Scripts/real-sample-smoke.sh
```

命令行构建产物和临时测试副本统一位于 `.local/`，不会污染源码或用户原始照片目录。

## 使用建议

推荐在 Lightroom 导入或修改 sidecar 前执行 RawGeoSync。若照片或 XMP 在预览后发生变化，应用会把它标记为冲突并跳过。已有不同 GPS 默认不会覆盖。

分析完成后，只有“可靠”结果默认勾选写入；停留候选、最近点和其他待确认结果必须按区间复核并主动勾选。写入前应用会展示创建、更新、已应用与冲突数量。撤销仅在 sidecar 未被 Lightroom 等程序继续修改时执行，避免抹掉后续编辑。

本机 Release 应用位于 `.local/DerivedData-Release-Final/Build/Products/Release/RawGeoSync.app`。这是未签名的个人本机构建；若未来面向他人分发，需要另行配置 Developer ID、Hardened Runtime 和 Apple 公证。

相机时钟偏移定义为：`相机显示时间 - 真实当地时间`。相机快了 30 秒时填写 `+30`，匹配时应用会从照片时间减去30秒。

## 许可证

RawGeoSync 使用 MIT License。内置 ExifTool 及其 Perl 库遵循上游各自许可证，详见 `Vendor/ExifTool` 中的第三方声明。
