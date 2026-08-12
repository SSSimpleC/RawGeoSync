# 发布清单

本文档用于维护者发布 RawGeoSync 的源码或 macOS 构建。

## 源码发布

1. 确认工作区干净，目标提交已合并到 `main`。
2. 更新 `CHANGELOG.md`、README 和本次决策文档。
3. 执行 `Scripts/ci.sh`，完成仓库策略、vendor、格式、两个 Swift Package 的 Debug/Release 测试、应用 Debug/Release 构建与静态分析。
4. 检查 `git status` 和 CI 日志，确认没有照片、轨迹、XMP、本机路径、真实坐标、日志或密钥。
5. 为版本创建带注释的 Git tag，并推送提交和 tag。

## v0.2 匹配与全量回归门禁

1. 确认 [ADR 0002](Decisions/0002-matching-v2.md) 的来源层级、阈值、reason code 与实现一致。
2. 用合成夹具验证每个门槛两侧、强候选冲突、传播单跳、循环拒绝、航班断段和活动区降级。
3. 使用参数化真实数据执行：

   ```sh
   ./Scripts/real-data-regression.sh \
     --gpx-dir "$GPX_DIR" \
     --photo-dir "$PHOTO_DIR" \
     --cli "$REGRESSION_CLI" \
     --require-capability
   ```

4. 在同一机器运行三次，分类和规则分布完全一致；wall time 与峰值内存满足 [测试规范](TESTING.md) 的回归预算。
5. 只在 `.local/` 的最小照片副本上执行 XMP 应用、幂等和撤销；原始 GPX、照片目录及 RAW SHA-256 前后不变。
6. 不上传真实 dry-run 报告、哈希清单、文件名、坐标或性能日志原件。PR 和 Release 仅记录脱敏聚合指标。

`--require-capability` 只禁止缺失能力被跳过；发布者仍需完成第 2、4、5 步的语义、性能与副本写入验收。

## 构建发布

个人本机使用可以发布未签名的 `.app`。对外分发前必须：

- 使用 Developer ID Application 签名；
- 启用 Hardened Runtime；
- 使用 Apple `notarytool` 公证并 staple；
- 在无 Homebrew、无用户安装 ExifTool 的干净 macOS 账号中验证；
- 发布压缩包 SHA-256，并在 GitHub Release 中附上变更说明。

Mac App Store 不是当前 MVP 目标。若未来进入 Mac App Store，需要重新设计 App Sandbox、用户选定目录权限、ExifTool helper 和崩溃恢复流程。

## v0.3 Catalog Bridge 门禁

1. 确认 [ADR 0003](Decisions/0003-lightroom-catalog-bridge.md) 与 JSONL schema、App 默认输出和插件实现一致。
2. Swift 与 Lua 共享 golden fixtures 全部通过，仓库策略已扫描 `.lua`，真实生成清单保持 Git ignored。
3. 在独立 Lightroom Catalog 上完成 20 张完整功能样本和 100 张五批次真机样本；完成 1000、5000、10000 条合成复杂度验收。不得使用正式 Catalog 或照片原件。
4. Auto XMP 关闭时证明 RAW 目录只增加一份清单，RAW 内容和 mtime 不变；开启时验证警告与 Lightroom 实际行为一致。
5. 验证原生 Undo、跨重启插件撤销、取消自动回滚、后续编辑冲突保护和重复导入 no-op。
6. 确认插件 ZIP 与 App 内置插件的版本、schema major/minor 和 SHA-256 一致。
7. 发布物同时包含 App ZIP、`RawGeoSync-Lightroom-Bridge-<version>.zip`、校验文件和安装/日常使用说明。

本机构建上述三份发布物：

```sh
./Scripts/package-release.sh 0.3.0
```

输出位于被 Git 忽略的 `.local/release/v0.3.0/`。脚本会核对 App 版本、内置插件与独立插件逐文件一致，再生成 `SHA256SUMS.txt`。

## 发布前数据安全验收

- 分析阶段不产生照片目录写入；
- 默认桥接只创建或原子替换单一位置清单；兼容模式才创建或更新同名 XMP，RAW SHA-256 不变；
- Catalog 中已有不同 GPS 会在预览明确计数并按本次清单覆盖；插件撤销收据必须先成功持久化；
- 重复运行识别为 already-applied 且不改变 XMP mtime；
- 取消、单项失败和崩溃不会留下半写 XMP；
- XMP 和 Catalog 撤销遇到后续 Lightroom 修改时必须拒绝覆盖；
- 强候选冲突、传播循环和跨活动区候选不能自动写入；
- 源无 hacc 时界面和报告都显示 unknown，不生成伪精度；
- 全量 dry-run 的输入目录前后 SHA-256 清单完全一致。

## 第三方组件

ExifTool 及其 Perl 库保留上游版权和 Artistic/GPL 许可证。每次升级必须更新 `Vendor/ExifTool/VERSION.json`、上游来源、归档 SHA-256 和 `THIRD-PARTY-NOTICES.md`。
