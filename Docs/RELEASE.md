# 发布清单

本文档用于维护者发布 RawGeoSync 的源码或 macOS 构建。

## 源码发布

1. 确认工作区干净，目标提交已合并到 `main`。
2. 更新 `CHANGELOG.md`、README 和本次决策文档。
3. 执行 `Scripts/format-check.sh`、`Scripts/verify-vendor.sh`、两个 Swift Package 的 Debug/Release 测试，以及应用 Debug/Release 构建。
4. 执行 `xcodebuild analyze`，检查 `git diff --check`，确认没有照片、轨迹、XMP、日志或密钥。
5. 为版本创建带注释的 Git tag，并推送提交和 tag。

## 构建发布

个人本机使用可以发布未签名的 `.app`。对外分发前必须：

- 使用 Developer ID Application 签名；
- 启用 Hardened Runtime；
- 使用 Apple `notarytool` 公证并 staple；
- 在无 Homebrew、无用户安装 ExifTool 的干净 macOS 账号中验证；
- 发布压缩包 SHA-256，并在 GitHub Release 中附上变更说明。

Mac App Store 不是当前 MVP 目标。若未来进入 Mac App Store，需要重新设计 App Sandbox、用户选定目录权限、ExifTool helper 和崩溃恢复流程。

## 发布前数据安全验收

- 分析阶段不产生照片目录写入；
- 写入只创建或更新同名 XMP，NEF SHA-256 不变；
- 已有不同 GPS 默认跳过；
- 重复运行识别为 already-applied 且不改变 XMP mtime；
- 取消、单项失败和崩溃不会留下半写 XMP；
- 撤销遇到后续 Lightroom 修改时必须拒绝覆盖。

## 第三方组件

ExifTool 及其 Perl 库保留上游版权和 Artistic/GPL 许可证。每次升级必须更新 `Vendor/ExifTool/VERSION.json`、上游来源、归档 SHA-256 和 `THIRD-PARTY-NOTICES.md`。
