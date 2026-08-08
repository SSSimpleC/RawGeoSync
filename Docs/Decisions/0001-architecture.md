# ADR 0001：首版架构与安全边界

状态：已接受（2026-08-08）

## 决策

RawGeoSync 使用 Swift 6、SwiftUI 和少量 AppKit 构建原生 macOS 15+ 应用。算法位于纯 Foundation 的 `RawGeoCore`；ExifTool、XMP 和事务位于 `MetadataInfrastructure`；应用层只负责交互与编排。

首版只面向本机个人使用，不启用 App Sandbox，不做公证或远端发布。应用不使用网络服务；MapKit 只在地图可见时按系统行为加载瓦片。

## 不可破坏的边界

1. RAW 文件永远只读。
2. 自动写入只针对同名 XMP sidecar。
3. 待确认匹配默认不选中。
4. 已有不同 GPS 默认跳过。
5. 所有写入先生成不可变计划，再逐文件原子应用并复读验证。
6. 取消和单文件失败保留已成功文件，不产生半写文件。

## 数据与状态

UserDefaults 只保存时区、相机偏移等非敏感偏好。事务清单和原 XMP 备份位于 Application Support；不持久化 GPX 轨迹内容，不在日志记录路径、文件名、坐标或拍摄时间。

