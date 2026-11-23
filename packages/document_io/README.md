# document_io

将已验证的 `ResumeData` 导出为 Markdown、Canonical JSON、中文 A4 PDF 或应用内 DOCX。渲染层不访问文件系统或网络，文件保存由客户端负责。

Task 022 新增 `ResumeWordDocument`、`ResumeDocxCodec` 和 `ResumeDocxPdfConverter`。Word 段落保留标题、副标题、章节、正文、成果条目和元数据样式。`fromResume` 首先执行领域 validation；`convert` 只接收实际 DOCX 字节，文稿修改不会回写 Canonical。

PDF 使用仓库内 Noto Sans SC 字体；遇到未覆盖的字符（例如部分 emoji）明确拒绝转换，保留完整 Word 原文，避免输出缺字文件。

DOCX 是包含正文、样式、内容类型与内部关系的真实 OOXML ZIP 包。仅支持应用内固定模板：无照片保持 v2 并兼容既有 v1；有照片使用 v3 的固定无边框首页基本信息表格、一个 JPEG 部件和固定内部图片关系。照片打印尺寸 25×35mm、页顶和页右边距 12mm，基本信息左右对称预留空间，姓名、选填意向岗位、联系信息仍按 A4 整页中线居中。已规范化照片完整等比显示，无照片不生成空框。`ResumeWordDocument.photo` 和固定小型 metadata 部件保留照片及未知字段，应用内修改文字后不会丢图，Word 转 PDF 使用实际保存字节。

安全边界沿用 ZIP STORE，拒绝压缩、重复或越界路径、附加部件、外部关系、DTD、任意表格/图片/行内格式及其他模板改动；固定 v3 结构通过完整重建核对，未开放通用 Office 对象。包最大 4 MiB、最多 10000 段、500000 UTF-16 字符、100000 XML 元素，v1/v2 最深 6 层、固定 v3 最深 16 层；结构在建立 DOM 前流式检查。打印图片 ≤512 KiB，真实 JPEG 尺寸 500×700、1/3 颜色通道、采样因子最多 2、单 baseline 扫描，并实际解码像素及核对方向；附加字段 ≤64 KiB/32 层。带照片页眉最多 1200 字符（姓名标题最多 240），超限明确拒绝而不截断。不能无损转换的结构抛出中文 `FormatException`，不按未知结构猜测正文。此边界不承诺兼容外部 Word 编辑器重新保存的文件。

文本导入识别“意向职业岗位”和旧“职业标题”；两个标签同时出现时，保持原文待确认，避免覆盖。

```powershell
dart pub get
dart format --output=none --set-exit-if-changed lib test
dart analyze
dart test
```
