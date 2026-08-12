# ADR 0003：以 Lightroom Catalog Bridge 作为默认输出

- 状态：已接受
- 日期：2026-08-12
- 取代范围：补充 ADR 0001；不移除其 XMP 安全边界

## 背景

逐照片 XMP 在大批量任务中同时带来两个问题：照片目录文件数量翻倍，以及写入前后对每张 RAW、XMP 和事务清单进行校验所造成的高延迟。现有 XMP 实现仍适合作为与 Lightroom Catalog 无关的兼容输出，但不适合作为数千张照片的默认路径。

Lightroom Classic SDK 允许插件在 Catalog 写事务内更新原生 GPS 和海拔，而无需改写 RAW。用户已决定默认使用 Catalog Bridge、保留 XMP 兼容模式；桥接清单只包含在 RawGeoSync 中明确勾选且具有最终坐标的照片。

## 决策

RawGeoSync 默认在用户选择的照片根目录生成唯一的 `RawGeoSync.locations.jsonl`。清单使用 UTF-8 JSON Lines，由 header、按相对路径稳定排序的 asset records 和 trailer 组成，并使用 SHA-256 校验记录与整体 payload。

清单只保存相对路径和完成目录身份核验所需的最少信息；禁止绝对路径、basename 模糊匹配、路径大小写归一化和完整 RAW SHA。写入通过同目录临时文件和原子替换完成；相同语义重复导出不改动文件。

配套的纯 Lua Lightroom Classic 插件负责：

- 流式验证清单并按 `manifest parent + relativePath` 精确查找 Catalog 照片；
- 在写入前展示可写、相同、覆盖、离线、缺失和身份冲突数量；
- 默认处理清单全部记录，也允许限制为 Lightroom 当前选择；
- 按用户选择，以新清单覆盖 Catalog 中不同的 GPS；
- 跳过离线或身份无法核验的照片；
- 写入原生 GPS、可选海拔和不含明文坐标的来源 token；
- 批量复读验证，并提供跨 Lightroom 重启仍可用的安全整批撤销。

插件不得解析 GPX、运行 ExifTool/Python/shell、启动网络服务、直接访问 `.lrcat` SQLite，或在照片目录写日志和撤销记录。

现有 XMP 输出继续存在，但桥接实现不得复用 XMP transaction 的逐 RAW 摘要、逐 sidecar 备份/复读和逐条事务清单保存循环。桥接结果只能称为“清单已生成”；只有插件完成 Catalog 复读后才能称为“GPS 已应用并验证”。

## 数据与隐私

清单包含精确位置，权限设为仅当前用户，Git 默认忽略。它不包含绝对照片路径、GPX 路径或完整轨迹。插件日志默认只记录匿名标识、数量和错误类型。

撤销收据位于用户的 Lightroom Application Support 范围，不进入照片目录。收据保存恢复所需的原 GPS/海拔和摘要，因此同样视为敏感数据；清理必须由用户显式执行。

## 兼容边界

- 首发支持 macOS 15 及 Lightroom Classic 15.4.1 或更高版本。
- 不支持云端版 Lightroom。
- 插件无法通过公开 SDK 可靠读取 Lightroom 的“自动写入 XMP”设置，因此始终提示：启用该选项时，Lightroom 自身仍可能创建 sidecar。
- 已存在的 XMP 不自动删除或迁移。
- 清单没有海拔时保留 Catalog 现有海拔；只有清单明确提供海拔才更新。

## 验收门禁

- Auto XMP 关闭时，大批量任务在照片根目录只增加一份清单，RAW 内容与 mtime 不变。
- 清单导出、插件预检、写入和复读的复杂度为 O(N)，不读取完整 RAW 内容。
- 取消或意外失败最终全成或全退；显式撤销不覆盖导入后被用户再次修改的坐标。
- 同名跨目录照片、Unicode 路径、活动目录整体移动、离线照片和损坏清单均有自动或真机测试。
