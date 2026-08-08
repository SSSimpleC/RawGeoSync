# 参与贡献

感谢你关注 RawGeoSync。项目目前以 macOS 本机离线处理和个人照片工作流为目标，外部贡献应先确认不会改变 RAW 只读、XMP sidecar 输出和隐私边界。

## 开发环境

- macOS 15 或更高版本
- Xcode 26.3 或兼容的 Swift 6 工具链
- 系统 Perl 仅用于运行随项目锁定的 ExifTool 13.59
- Swift 依赖只使用本地 Swift Package，不提交 Homebrew 或 Conda 环境

首次开发前，确认 `xcode-select -p` 指向完整 Xcode，而不是只安装 Command Line Tools。

## 数据与隐私

不要提交真实 NEF、其他照片、GPX、XMP、地图截图或含坐标的日志。真实样本只能放在被 Git 忽略的 `.local/` 下，并且写入测试必须使用副本。合成夹具应固定使用虚构时间和位置。

RawGeoSync 不上传照片、轨迹或坐标。新增网络请求、遥测、反向地理编码或云端依赖需要单独的设计讨论和用户同意。

## 修改流程

1. 从 `main` 创建主题分支，分支名使用 `agent/<简短描述>` 或 `feature/<简短描述>`。
2. 先修改核心模型和测试，再修改适配器或界面；不要让 SwiftUI 视图直接依赖 GPX/XML 或 ExifTool 细节。
3. 运行 `Scripts/format-check.sh`、`Scripts/verify-vendor.sh` 和 `Scripts/test.sh`。
4. 提交信息使用简短、可读的动词开头，例如 `feat: ...`、`fix: ...`、`test: ...`、`docs: ...`。
5. Pull Request 中说明行为变化、数据安全影响和已运行的验证命令。

## 元数据边界

- RAW 文件永远不能作为写入目标。
- GPS 写入只能通过同名 XMP sidecar 完成。
- 不要修改 `DateTimeOriginal`，也不要未经用户确认覆盖已有 GPS。
- 更新 ExifTool 时必须同步版本清单、归档 SHA-256、上游许可证说明和真实契约测试。

## Pull Request 检查清单

- [ ] 没有提交真实照片、GPX、XMP、绝对路径或秘密
- [ ] 新增策略分支有合成单元测试
- [ ] 取消、失败、冲突和重复运行仍然安全
- [ ] RAW SHA-256 在相关测试前后保持不变
- [ ] 格式检查、包测试和应用构建通过
- [ ] README、CHANGELOG 或决策文档已同步更新
