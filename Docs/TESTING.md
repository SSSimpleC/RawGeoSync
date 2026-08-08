# 测试与验收

## 自动回归

`Scripts/test.sh` 依次运行核心包、元数据包和 macOS 应用构建。当前基线为 RawGeoCore 23 项、MetadataInfrastructure 15 项全部通过；另执行 Release 测试、`xcodebuild analyze` 和 Swift 格式检查。测试数据必须是合成数据，不得提交真实坐标、照片或年度 GPX。

重点覆盖：GPX格式与坏点、时区和相机偏移、匹配阈值边界、大圆插值、停留候选、缺轨、多轨冲突、ExifTool进程错误、XMP合并、幂等、原子写入、失败继续和安全撤销。

## 真实样本

真实样本只读引用：

- `/Users/simplechen/Downloads/2026.01.01-2026.12.31.gpx`
- `/Users/simplechen/Picture/2026-8-8 我们四在东莞/Z50`

黄金预览为29张可靠匹配、23张属于同一停留候选批次、0张跨明显缺轨自动插值。任何写测试必须先复制必要文件到 `.local/tmp/<唯一目录>`，并验证原始 NEF 的 SHA-256 始终不变。

真实写入验收须满足：复制品生成29个 XMP；第二次预检全部识别为 already-applied 且 mtime 不变；撤销后29个新建 XMP 全部移除；原始目录与复制目录的52个 NEF SHA-256 前后一致。真实原图目录不得出现 XMP。
