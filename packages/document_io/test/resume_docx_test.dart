import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:document_io/document_io.dart';
import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

void main() {
  const codec = ResumeDocxCodec();
  late ResumeData resume;
  late ResumePdfFonts fonts;
  setUpAll(() {
    resume = const CanonicalResumeCodec().decode(
      File('test/fixtures/pdf_resume_input.json').readAsStringSync(),
    );
    fonts = ResumePdfFonts(
      regular: ByteData.sublistView(
        File('lib/assets/fonts/NotoSansSC-Regular.ttf').readAsBytesSync(),
      ),
      bold: ByteData.sublistView(
        File('lib/assets/fonts/NotoSansSC-Bold.ttf').readAsBytesSync(),
      ),
    );
  });

  test('全部简历区段生成真实 Word 包，独立 XML 读取可见中文与事实', () {
    final originalJson = const CanonicalResumeCodec().encode(resume);
    final wordDocument = codec.fromResume(resume);
    final encoded = codec.encode(wordDocument);
    final package = ZipDecoder().decodeBytes(encoded);
    expect(
      package.files.map((file) => file.name),
      containsAll([
        '[Content_Types].xml',
        '_rels/.rels',
        'word/document.xml',
        'word/styles.xml',
        'word/_rels/document.xml.rels',
      ]),
    );
    final xml = XmlDocument.parse(
      utf8.decode(package.findFile('word/document.xml')!.content),
    );
    final bodyText = xml.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 't')
        .map((element) => element.innerText)
        .join('\n');
    for (final expected in [
      '林晓舟',
      'xiaozhou.lin@example.com',
      '13800000000',
      '杭州',
      '个人主页',
      'https://example.com/xiaozhou',
      '工作经历',
      '示例科技有限公司',
      '高级客户端工程师',
      '2022.03 - 至今',
      '教育经历',
      '工学学士',
      '计算机科学与技术',
      '项目经历',
      '核心开发者',
      '项目说明',
      '技能',
      'Widget Test',
      '证书',
      '示例技术协会',
      '颁发：2024.05',
      '到期：2027.05',
      'CERT-2024-001',
      '语言',
      '中文：母语',
      '英语：工作熟练',
      '开源与分享',
      '工程实践分享',
      '待确认内容',
      '补充说明：愿意参与技术文档建设与新人辅导。',
      '该字段尚未映射，但必须在导出中可见。',
    ]) {
      expect(bodyText, contains(expected), reason: expected);
    }
    expect(
      codec.decode(encoded).paragraphs.map((paragraph) => paragraph.text),
      wordDocument.paragraphs.map((paragraph) => paragraph.text),
    );
    expect(const CanonicalResumeCodec().encode(resume), originalJson);
  });

  test('特殊字符、空段落、空格、换行和所有段落样式可无损编辑往返', () {
    final source = ResumeWordDocument(
      paragraphs: [
        for (final style in ResumeWordStyle.values)
          ResumeWordParagraph(
            text: ' 中文 <&> "引号"  English\n第二行\t制表\r\n末尾 ',
            style: style,
          ),
        const ResumeWordParagraph(text: '', style: ResumeWordStyle.body),
      ],
    );
    final decoded = codec.decode(codec.encode(source));
    expect(
      decoded.paragraphs.map((paragraph) => paragraph.text),
      source.paragraphs.map((paragraph) => paragraph.text),
    );
    expect(
      decoded.paragraphs.map((paragraph) => paragraph.style),
      source.paragraphs.map((paragraph) => paragraph.style),
    );
    expect(() => decoded.paragraphs.clear(), throwsUnsupportedError);
  });

  test('已保存的旧版修改稿仍可读取和转换，原字节保持不变', () async {
    final oldFile = File('test/fixtures/legacy-resume-v1.docx');
    final before = oldFile.readAsBytesSync();
    final oldDocument = codec.decode(before);
    expect(oldDocument.paragraphs[1].text, '修改后的 Word 正文 · DOCX to PDF 验证');
    expect(oldDocument.paragraphs.map((p) => p.text), contains('林晓舟'));
    final pdf = await const ResumeDocxPdfConverter().convert(
      before,
      fonts: fonts,
    );
    expect(ascii.decode(pdf.take(5).toList()), '%PDF-');
    expect(oldFile.readAsBytesSync(), before);
    final saved = codec.decode(codec.encode(oldDocument));
    expect(
      saved.paragraphs.map((p) => p.text),
      oldDocument.paragraphs.map((p) => p.text),
    );
    expect(
      saved.paragraphs.map((p) => p.style),
      oldDocument.paragraphs.map((p) => p.style),
    );
  });

  test('新旧样式与页边距不能混搭，旧版不能伪装新增段落角色', () {
    final oldBytes = File(
      'test/fixtures/legacy-resume-v1.docx',
    ).readAsBytesSync();
    final current = codec.encode(codec.fromResume(resume));
    final currentStyles = utf8.decode(
      ZipDecoder().decodeBytes(current).findFile('word/styles.xml')!.content,
    );
    expect(
      () => codec.decode(
        _rewritePart(oldBytes, 'word/styles.xml', (_) => currentStyles),
      ),
      throwsFormatException,
    );
    expect(
      () => codec.decode(
        _rewritePart(
          oldBytes,
          'word/document.xml',
          (xml) => xml.replaceFirst('w:val="subtitle"', 'w:val="entryHeader"'),
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => codec.decode(
        _rewritePart(
          current,
          'word/document.xml',
          (xml) => xml.replaceFirst('w:top="680"', 'w:top="907"'),
        ),
      ),
      throwsFormatException,
    );
  });

  test('经历三列从已有字段生成，长字段自动换行且内容不丢失', () {
    final data = resume.toJson();
    final work =
        (data['workExperiences']! as List).first as Map<String, Object?>;
    final longOrganization = '超长组织名称保持完整' * 12;
    work['organization'] = longOrganization;
    final changed = ResumeData.fromJson(data);
    final canonical = const CanonicalResumeCodec().encode(changed);
    final document = codec.fromResume(changed);
    final header = document.paragraphs.firstWhere(
      (p) =>
          p.style == ResumeWordStyle.entryHeader &&
          p.text.contains(longOrganization),
    );
    expect(header.text, contains('\n'));
    expect(header.text, contains(longOrganization));
    expect(header.text, contains('2022.03 - 至今'));
    expect(
      codec.decode(codec.encode(document)).paragraphs.map((p) => p.text),
      document.paragraphs.map((p) => p.text),
    );
    expect(const CanonicalResumeCodec().encode(changed), canonical);
  });

  test('宽汉字标题即使不超过旧长度阈值也退为分行，避免Word跨列挤压', () {
    final data = resume.toJson();
    final work =
        (data['workExperiences']! as List).first as Map<String, Object?>;
    final organization = '单位' * 17;
    final position = '岗位' * 13;
    work['organization'] = organization;
    work['position'] = position;
    final changed = ResumeData.fromJson(data);
    final document = codec.fromResume(changed);
    final header = document.paragraphs.firstWhere(
      (p) =>
          p.style == ResumeWordStyle.entryHeader &&
          p.text.contains(organization),
    );
    expect(header.text, '2022.03 - 至今\n$organization\n$position');
    expect(
      codec.decode(codec.encode(document)).paragraphs.map((p) => p.text),
      document.paragraphs.map((p) => p.text),
    );
  });

  test('非法源简历在生成 Word 前被 validation 拒绝', () {
    final invalidJson = resume.toJson();
    (invalidJson['profile']! as Map<String, Object?>)['email'] = 'invalid';
    expect(
      () => codec.fromResume(ResumeData.fromJson(invalidJson)),
      throwsA(isA<ResumeValidationException>()),
    );
  });

  test('保存修改后只从新 DOCX 正文转 PDF，旧副本保持原字节', () async {
    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'resume-docx-test-',
    );
    addTearDown(() => temporaryDirectory.deleteSync(recursive: true));
    final original = codec.encode(_document('甲'));
    final oldFile = File('${temporaryDirectory.path}/old.docx')
      ..writeAsBytesSync(original);
    final readDocument = codec.decode(oldFile.readAsBytesSync());
    final edited = ResumeWordDocument(
      paragraphs: [
        ResumeWordParagraph(
          text: '乙',
          style: readDocument.paragraphs.single.style,
        ),
      ],
    );
    final newFile = File('${temporaryDirectory.path}/new.docx')
      ..writeAsBytesSync(codec.encode(edited));
    final pdf = await const ResumeDocxPdfConverter().convert(
      newFile.readAsBytesSync(),
      fonts: fonts,
    );
    expect(oldFile.readAsBytesSync(), original);
    expect(codec.decode(newFile.readAsBytesSync()).paragraphs.single.text, '乙');
    final pdfStreams = _uncompressedPdfStreams(pdf).toUpperCase();
    // 独立读取 PDF 的 ToUnicode 字体映射，证明进入渲染的字符来自修改正文。
    expect(pdfStreams, contains('<4E59>'));
    expect(pdfStreams, isNot(contains('<7532>')));
    expect(
      latin1.decode(pdf),
      matches(RegExp(r'/MediaBox\s*\[0 0 595\.\d+ 841\.\d+\]')),
    );
  });

  test('超长中文正文可以跨页，英文长 token 不越界', () async {
    final pdf = await const ResumeDocxPdfConverter().convert(
      codec.encode(
        _document(
          '${List.filled(300, '长段落必须完整跨页保留，包含中文与 English。').join()}\n${'longtoken' * 100}',
        ),
      ),
      fonts: fonts,
    );
    expect(
      RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(pdf)).length,
      greaterThanOrEqualTo(3),
    );
  });

  test('字体不支持的字符保留在 Word 中并明确阻止 PDF 缺字转换', () async {
    final docx = codec.encode(_document('保留原文 \u{1f9d1}'));
    expect(codec.decode(docx).paragraphs.single.text, '保留原文 \u{1f9d1}');
    await expectLater(
      const ResumeDocxPdfConverter().convert(docx, fonts: fonts),
      throwsFormatException,
    );
    expect(codec.decode(docx).paragraphs.single.text, '保留原文 \u{1f9d1}');
  });

  test('损坏 ZIP、超限文字和非法 XML 控制字符被明确拒绝', () {
    for (final bytes in [
      Uint8List(4),
      Uint8List(80),
      Uint8List(ResumeDocxCodec.maxFileBytes + 1),
    ]) {
      expect(() => codec.decode(bytes), throwsFormatException);
    }
    expect(
      () => codec.encode(
        _document('字' * (ResumeDocxCodec.maxTextCharacters + 1)),
      ),
      throwsFormatException,
    );
    expect(() => codec.encode(_document('控制\u0000字符')), throwsFormatException);
    expect(
      () => codec.encode(ResumeWordDocument(paragraphs: [])),
      throwsFormatException,
    );
  });

  test('表格、行内格式、外部关系、DTD、未知样式不被静默丢弃', () {
    final original = codec.encode(_document('测试正文'));
    for (final mutation in <String Function(String)>[
      (xml) => xml.replaceFirst('<w:sectPr>', '<w:tbl/><w:sectPr>'),
      (xml) => xml.replaceFirst('<w:r>', '<w:r><w:rPr><w:b/></w:rPr>'),
      (xml) => xml.replaceFirst('w:val="body"', 'w:val="unknown"'),
      (xml) => xml.replaceFirst(
        '<w:document',
        '<!DOCTYPE test [<!ENTITY text "正文">]><w:document',
      ),
      (xml) => xml.replaceFirst('<w:t ', '<w:t w:hidden="true" '),
    ]) {
      expect(
        () =>
            codec.decode(_rewritePart(original, 'word/document.xml', mutation)),
        throwsFormatException,
      );
    }
    expect(
      () => codec.decode(
        _rewritePart(
          original,
          'word/_rels/document.xml.rels',
          (xml) => xml.replaceFirst(
            'Target="styles.xml"',
            'Target="https://example.com" TargetMode="External"',
          ),
        ),
      ),
      throwsFormatException,
    );
  });

  test('额外包路径、篡改 CRC 和非应用压缩方式被拒绝', () {
    final original = codec.encode(_document('路径边界'));
    for (final path in [
      '../evil.xml',
      '/word/evil.xml',
      r'word\evil.xml',
      'word/vbaProject.bin',
    ]) {
      final package = ZipDecoder().decodeBytes(original);
      package.add(
        ArchiveFile(path, 1, [65])..compression = CompressionType.none,
      );
      expect(
        () => codec.decode(Uint8List.fromList(ZipEncoder().encode(package))),
        throwsFormatException,
      );
    }
    final corrupt = Uint8List.fromList(original);
    final centralOffset = _signatureOffset(corrupt, 0x02014b50);
    corrupt[centralOffset + 16] ^= 1;
    expect(() => codec.decode(corrupt), throwsFormatException);
    final compressed = ZipDecoder().decodeBytes(original);
    for (final part in compressed) {
      part.compression = CompressionType.deflate;
    }
    expect(
      () => codec.decode(Uint8List.fromList(ZipEncoder().encode(compressed))),
      throwsFormatException,
    );
  });

  test('异常 XML 深度与节点数量在建立正文树之前被拒绝', () {
    final original = codec.encode(_document('有界文稿'));
    expect(
      () => codec.decode(
        _rewritePart(
          original,
          'word/document.xml',
          (xml) =>
              xml.replaceFirst('有界文稿', '${'<w:x>' * 10}正文${'</w:x>' * 10}'),
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => codec.decode(
        _rewritePart(
          original,
          'word/document.xml',
          (xml) => xml.replaceFirst('有界文稿', '<w:br/>' * 100001),
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => codec.encode(
        ResumeWordDocument(
          paragraphs: List.filled(
            ResumeDocxCodec.maxParagraphs + 1,
            const ResumeWordParagraph(text: '', style: ResumeWordStyle.body),
          ),
        ),
      ),
      throwsFormatException,
    );
  });

  test('重复中央目录路径、越界包路径和伪造体积均被拒绝', () {
    final original = codec.encode(_document('包结构验证'));
    final directory = ZipDirectory()..read(InputMemoryStream(original));
    final centralOffsets = <int>[];
    var centralOffset = directory.centralDirectoryOffset;
    final data = ByteData.sublistView(original);
    for (final header in directory.fileHeaders) {
      centralOffsets.add(centralOffset);
      centralOffset +=
          46 +
          utf8.encode(header.filename).length +
          data.getUint16(centralOffset + 30, Endian.little) +
          data.getUint16(centralOffset + 32, Endian.little);
    }
    final duplicated = Uint8List.fromList(original);
    final duplicateData = ByteData.sublistView(duplicated);
    // 让第二个中央目录项重用第一个局部文件，不能把它当作另一合法部件。
    duplicateData.setUint32(
      centralOffsets[1] + 42,
      directory.fileHeaders.first.localHeaderOffset,
      Endian.little,
    );
    expect(() => codec.decode(duplicated), throwsFormatException);
    final traversed = Uint8List.fromList(original);
    traversed.setRange(centralOffsets[1] + 46, centralOffsets[1] + 49, [
      46,
      46,
      47,
    ]);
    expect(() => codec.decode(traversed), throwsFormatException);
    final oversized = Uint8List.fromList(original);
    final oversizedData = ByteData.sublistView(oversized);
    oversizedData.setUint32(
      centralOffsets.first + 20,
      ResumeDocxCodec.maxFileBytes + 1,
      Endian.little,
    );
    oversizedData.setUint32(
      centralOffsets.first + 24,
      ResumeDocxCodec.maxFileBytes + 1,
      Endian.little,
    );
    expect(() => codec.decode(oversized), throwsFormatException);
  });
}

ResumeWordDocument _document(String text) => ResumeWordDocument(
  paragraphs: [ResumeWordParagraph(text: text, style: ResumeWordStyle.body)],
);

Uint8List _rewritePart(
  Uint8List source,
  String path,
  String Function(String) mutate,
) {
  final package = ZipDecoder().decodeBytes(source);
  final replacement = utf8.encode(
    mutate(utf8.decode(package.findFile(path)!.content)),
  );
  package.add(
    ArchiveFile(path, replacement.length, replacement)
      ..compression = CompressionType.none,
  );
  return Uint8List.fromList(ZipEncoder().encode(package));
}

int _signatureOffset(Uint8List source, int signature) {
  final data = ByteData.sublistView(source);
  for (var offset = 0; offset < source.length - 4; offset++) {
    if (data.getUint32(offset, Endian.little) == signature) return offset;
  }
  throw StateError('测试 ZIP 缺少预期结构');
}

String _uncompressedPdfStreams(Uint8List pdf) {
  final pdfString = latin1.decode(pdf);
  final decodedStreams = StringBuffer();
  for (final match in RegExp(
    r'<<(.*?)>>\s*stream\r?\n(.*?)\r?\nendstream',
    dotAll: true,
  ).allMatches(pdfString)) {
    final content = latin1.encode(match[2]!);
    if (match[1]!.contains('/FlateDecode')) {
      decodedStreams.writeln(
        latin1.decode(const ZLibDecoder().decodeBytes(content)),
      );
    } else {
      decodedStreams.writeln(match[2]);
    }
  }
  return decodedStreams.toString();
}
