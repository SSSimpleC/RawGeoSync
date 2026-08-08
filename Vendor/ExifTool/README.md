# ExifTool vendor directory

RawGeoSync 随应用固定分发官方 ExifTool Perl 版本，不依赖用户安装。当前锁定版本为13.59：

- 版本、来源和归档 SHA-256 记录在 `VERSION.json`。
- 上游原始许可说明保留在 `UPSTREAM-README`。
- 分发声明位于 `THIRD-PARTY-NOTICES.md`。
- 应用通过 `/usr/bin/perl exiftool` 启动，并让脚本自动加载同目录的 `lib`。

升级必须单独审查并运行 NEF 读取、XMP 合并、幂等和 Lightroom 兼容回归。
