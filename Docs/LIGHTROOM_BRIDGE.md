# Lightroom Catalog Bridge 使用指南

Catalog Bridge 是 RawGeoSync 的默认输出方式。它让一个照片根目录只增加一份
`RawGeoSync.locations.jsonl`，再由 Lightroom Classic 插件把其中已确认的位置批量写入当前目录。
RAW 文件始终只读；插件也不会直接修改 `.lrcat` 数据库文件。

## 第一次使用

1. 启动 RawGeoSync，保留默认输出“Lightroom Classic 单清单”。
2. 选择或拖入一个 `.gpx` 文件，也可以选择包含多个 GPX 的目录。
3. 选择照片活动根目录。建议选择同时包含 `Z50`、`Z5` 等相机子目录的活动目录，而不是更高层的整个照片库。
4. 完成分析，复核黄色和粗略候选，并勾选本次要交给 Lightroom 的照片。
5. 点击生成清单。照片根目录只会创建或原子更新一个 `RawGeoSync.locations.jsonl`。
6. 在结果页点击“安装/更新 Lightroom 插件”。如果 Lightroom 正在运行，安装后重启一次 Lightroom。
7. 先把对应 RAW 导入 Lightroom Classic，再选择菜单“图库 → 插件增效工具 → RawGeoSync：导入位置清单…”。
8. 选择刚生成的清单，检查预检数量后开始导入。插件默认处理清单全部照片；需要时可限制为 Lightroom 当前选择。

插件按清单父目录和照片相对路径精确查找，不使用文件名模糊匹配。已有不同 GPS 会在预检中明确计数，并由本次已确认清单覆盖；相同坐标跳过，原文件离线、路径缺失或字节数不一致的照片安全跳过。

## 撤销与恢复

一次成功导入会形成 Lightroom 原生撤销记录，同时把恢复所需的敏感事务收据保存在 Lightroom 的 Application Support 目录，而不是照片目录。

- 刚导入后可以使用 Lightroom 的“撤销”；大批任务按 200 张提交，系统撤销可能按批次出现，插件菜单才是整批恢复入口。
- Lightroom 重启后，使用“图库 → 插件增效工具 → RawGeoSync：撤销最近一次导入…”。
- 如果照片的 GPS 在导入后又被用户或其他插件修改，持久撤销会跳过该照片，不覆盖较新的工作。
- 导入中取消、写入失败或复读不一致时，插件自动恢复此前已经提交的批次；若自动恢复受到外部并发修改阻止，收据仍可用于安全补救。

事务收据包含原 GPS 和恢复信息，应和 Catalog 备份一样视为敏感本地数据。不要上传或纳入 Git。

不再需要历史撤销时，可运行“图库 → 插件增效工具 → RawGeoSync：打开撤销收据文件夹…”，在 Finder 中手工清理旧 `.jsonl` 收据。删除收据后无法再用插件恢复对应批次，因此插件不会自动清理。

## 关于 XMP

插件只调用 Lightroom SDK 写入 Catalog。若 Lightroom 偏好设置中启用了“自动将更改写入 XMP”，Lightroom 自身仍可能生成 sidecar；公开 SDK 无法可靠读取或关闭这个选项。希望照片目录始终只有单一清单时，请先在 Lightroom 的“目录设置 → 元数据”中关闭自动写入 XMP。

已有 XMP 不会被自动删除。需要绕过 Lightroom Catalog、与其他软件交换元数据时，可以在 RawGeoSync 输出选项中切回“XMP Sidecar（兼容模式）”。

## 日常启动与更新

日常可从 Finder、Spotlight 或启动台打开 `RawGeoSync.app`，也可以运行：

```sh
open "$HOME/Applications/RawGeoSync.app"
```

源码更新后，在项目目录运行 `./Scripts/build-release.sh` 会重新构建并安全替换本机应用。插件有更新时，打开应用后再次点击“安装/更新 Lightroom 插件”，然后重启 Lightroom。

## 常见问题

### 清单中的照片显示“不在当前目录”

先确认 RAW 已导入当前 Lightroom Catalog。若移动了整个活动目录，先在 Lightroom 使用“查找丢失的文件夹”或“更新文件夹位置”指向新路径，并让清单随目录一起移动；若单独改了 RAW 文件名或目录层级，请回到 RawGeoSync 重新分析并生成清单。

### 导入后地图或元数据面板没有立即刷新

插件会直接复读 Catalog 元数据验证写入。若结果页显示验证成功但界面仍旧，切换照片或重启 Lightroom 后再看；界面缓存不能替代插件复读结果。

### 为什么离线照片不写入

离线状态下只能依赖 Catalog 路径和智能预览，无法核验磁盘文件身份。为避免把坐标写给错误照片，当前版本默认跳过，待原文件联机后重新导入清单即可。

### 清单是否可以分享

不建议。清单包含精确坐标、照片相对路径、拍摄时间、相机型号、可能的机身/内部序列号、快门数、匹配证据摘要及轨迹摘要。权限仅授予当前用户读取；它不上传网络，但仍应按敏感位置与设备身份数据保护。

### 不通过 App，怎样安装独立插件 ZIP

解压 `RawGeoSync-Lightroom-Bridge-<version>.zip`，在 Lightroom 的“文件 → 增效工具管理器…”中点击“添加”，选择解压后的 `RawGeoSync.lrplugin`。确认状态为已安装且版本为 0.3.x 后重启 Lightroom。不要把 Lightroom 指向 ZIP 文件本身。
