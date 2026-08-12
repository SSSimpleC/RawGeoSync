# 参与贡献

感谢你关注 RawGeoSync。项目目前以 macOS 本机离线处理和个人照片工作流为目标，外部贡献应先确认不会改变 RAW 只读、Lightroom Catalog Bridge、XMP 兼容输出和隐私边界。

## 开发环境

- macOS 15 或更高版本
- Xcode 26.3 或兼容的 Swift 6 工具链
- 系统 Perl 仅用于运行随项目锁定的 ExifTool 13.59
- Swift 依赖只使用本地 Swift Package；Lua 测试环境放在被忽略的项目 `.local/` conda 环境，不修改 base

首次开发前，确认 `xcode-select -p` 指向完整 Xcode，而不是只安装 Command Line Tools。

## 数据与隐私

不要提交真实 NEF、其他照片、GPX、XMP、地图截图或含坐标的日志。不要在源码、文档、Issue 或 PR 中写入真实绝对路径、文件名和精确时间线。真实样本只能通过参数引用；本地报告放在被 Git 忽略的 `.local/` 下，写入测试必须使用副本。合成夹具应固定使用虚构时间和位置。

RawGeoSync 不上传照片、轨迹或坐标。新增网络请求、遥测、反向地理编码或云端依赖需要单独的设计讨论和用户同意。

## 修改流程

1. 从 `main` 创建主题分支，分支名使用 `agent/<简短描述>` 或 `feature/<简短描述>`。
2. 先修改核心模型和测试，再修改适配器或界面；不要让 SwiftUI 视图直接依赖 GPX/XML 或 ExifTool 细节。
3. 运行 `Scripts/repository-policy-check.sh`、`Scripts/format-check.sh`、`Scripts/verify-vendor.sh` 和 `Scripts/test.sh`。合并前运行一次 `Scripts/ci.sh`。
4. 提交信息使用简短、可读的动词开头，例如 `feat: ...`、`fix: ...`、`test: ...`、`docs: ...`。
5. Pull Request 中说明行为变化、数据安全影响和已运行的验证命令。

匹配规则的阈值、来源优先级、传播边界或 confidence 语义发生变化时，必须同步更新 ADR、reason code 测试和 dry-run 报告契约。证据等级不是概率；只有来源明确给出 hacc 时才能展示传感器精度。

## 真实数据回归

`Scripts/real-data-regression.sh` 是唯一支持的原始数据只读入口。它接收 GPX 目录和照片目录，不接受写入目标；报告和前后哈希清单只能写入 `.local/` 或另一个与输入目录无包含关系的目录。

真实回归结果不得上传。PR 中只写脱敏聚合信息，例如照片数、轨迹点数、规则计数、wall time 和峰值内存。需要测试 XMP 写入时，先创建新的 `.local/write-regression/` 副本，并人工核对解析后的目标路径不是原始目录。

## 元数据边界

- RAW 文件永远不能作为写入目标。
- 默认 GPS 写入通过版本化清单和 Lightroom 插件完成；兼容模式才写同名 XMP sidecar。
- 不要修改 `DateTimeOriginal`。Catalog Bridge 按用户已锁定策略以本次清单覆盖不同 GPS，但必须提供预览和可恢复的整批撤销。
- 禁止 basename 模糊匹配、直接访问 `.lrcat` SQLite、在插件中启动网络/shell/ExifTool/Python，或把绝对照片路径写入清单。
- 更新 ExifTool 时必须同步版本清单、归档 SHA-256、上游许可证说明和真实契约测试。

## Pull Request 检查清单

- [ ] 没有提交真实照片、GPX、XMP、绝对路径或秘密
- [ ] 新增策略分支有合成单元测试
- [ ] 候选来源、reason code、传播跳数和冲突行为可解释
- [ ] 未把规则推断范围写成传感器精度或概率
- [ ] 取消、失败、冲突和重复运行仍然安全
- [ ] RAW SHA-256 在相关测试前后保持不变
- [ ] 仓库策略、格式检查、包测试、应用构建和静态分析通过
- [ ] README、CHANGELOG 或决策文档已同步更新
