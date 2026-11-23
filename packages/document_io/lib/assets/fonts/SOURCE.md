# Noto Sans SC 字体来源

- 上游仓库：`https://github.com/notofonts/noto-cjk`
- 固定版本：`Sans2.004`
- 上游文件：`Sans/Variable/TTF/Subset/NotoSansSC-VF.ttf`
- 许可证：SIL Open Font License 1.1，全文见 `OFL-1.1.txt`
- `OFL-1.1.txt` 开头保留这两份字体 name 表中的版权告知；App 将完整文件作为资产登记到 Flutter 许可页，字体二进制和下列固定哈希未改。
- 派生方式：FontTools 4.60.1 `varLib.instancer`，分别固定 `wght=400` 与 `wght=700`

| 文件 | SHA-256 |
| --- | --- |
| 上游 `NotoSansSC-VF.ttf` | `d68bafcb48a2707749396aa12bbbd833cb70401f3a9a689fd2902c7e0d295964` |
| `NotoSansSC-Regular.ttf` | `dda88ae81ecf89fde9baab7122f0bb6b7e43ccf27b2b9b867312304c205c4119` |
| `NotoSansSC-Bold.ttf` | `81f0ca7262d72b1820c48ffd1c1cb2f60b91f86a18b80e87d4c0eae441dc45b7` |

这两份静态字体只用于离线生成中文 PDF。保留上游哈希和派生参数，是为了让二进制来源可以复核。升级字体时必须同时更新版本、哈希、视觉快照和 Android 构建结果。
