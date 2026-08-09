## 变更内容

<!-- 简述做了什么，以及为什么需要这项变更。 -->

## 验证

- [ ] `Scripts/format-check.sh`
- [ ] `Scripts/verify-vendor.sh`
- [ ] `Scripts/repository-policy-check.sh`
- [ ] `swift test --package-path RawGeoCore`
- [ ] `swift test --package-path MetadataInfrastructure`
- [ ] RawGeoSync Debug 构建
- [ ] RawGeoSync Release 构建与 `xcodebuild analyze`

## 数据与安全

- [ ] 未提交真实照片、GPX、XMP、坐标、绝对路径或秘密
- [ ] 未改变 RAW 只读和 XMP sidecar 边界
- [ ] 已有 GPS、取消、失败、重复运行行为已检查
- [ ] 若修改了元数据写入，已补充事务或契约测试
- [ ] 若修改了匹配规则，已覆盖阈值边界、来源优先级、单跳传播和强冲突
- [ ] 真实 dry-run 报告、路径、文件名、坐标和哈希清单未上传

## 其他

<!-- 说明兼容性、迁移、文档或发布影响。 -->
