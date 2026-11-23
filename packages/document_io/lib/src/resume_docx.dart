import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:resume_domain/resume_domain.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import 'resume_pdf_exporter.dart';
import 'resume_page_layout.dart';
import 'resume_photo_validation.dart';
import 'resume_aigc_pdf_metadata.dart';

// 前六种角色及其旧版固定样式保留，用于读取已有 Word 修改稿。
enum ResumeWordStyle {
  title,
  subtitle,
  heading,
  body,
  bullet,
  metadata,
  headline,
  contact,
  entryHeader,
}

final class ResumeWordParagraph {
  const ResumeWordParagraph({required this.text, required this.style});

  final String text;
  final ResumeWordStyle style;
}

final class ResumeWordDocument {
  ResumeWordDocument({
    required List<ResumeWordParagraph> paragraphs,
    this.photo,
    this.aiProvenance,
    this.aigcMetadata,
  }) : paragraphs = List.unmodifiable(paragraphs);

  final List<ResumeWordParagraph> paragraphs;
  final ResumePhoto? photo;
  final ResumeAiProvenance? aiProvenance;
  final ResumeAigcMetadata? aigcMetadata;
  String? get aiNotice =>
      aigcMetadata?.notice ??
      (aiProvenance == null ? null : ResumeAiProvenance.notice);
}

/// 只接受本应用的固定模板，文稿不是 Canonical 事实源。
final class ResumeDocxCodec {
  const ResumeDocxCodec({this.validator = const ResumeValidator()});

  final ResumeValidator validator;
  static const maxFileBytes = 4 * 1024 * 1024;
  static const maxParagraphs = 10000;
  static const maxTextCharacters = 500000;

  ResumeWordDocument fromResume(ResumeData resume) {
    final validation = validator.validate(resume);
    if (!validation.isValid) throw ResumeValidationException(validation);
    final paragraphs = <ResumeWordParagraph>[];
    void add(String text, [ResumeWordStyle style = ResumeWordStyle.body]) {
      if (text.isNotEmpty) {
        paragraphs.add(ResumeWordParagraph(text: text, style: style));
      }
    }

    void heading(String text) => add(text, ResumeWordStyle.heading);
    void bullets(List<String> texts) {
      for (final text in texts) {
        add(text, ResumeWordStyle.bullet);
      }
    }

    final profile = resume.profile;
    add(
      profile.fullName.trim().isEmpty ? '未命名简历' : profile.fullName,
      ResumeWordStyle.title,
    );
    add(profile.headline, ResumeWordStyle.headline);
    add(
      [
        profile.email,
        profile.phone,
        profile.location,
      ].where((detail) => detail.isNotEmpty).join(' · '),
      ResumeWordStyle.contact,
    );
    if (profile.links.isNotEmpty) heading('链接');
    for (final link in profile.links) {
      add('${link.label}：${link.url}');
    }
    if (resume.workExperiences.isNotEmpty) heading('工作经历');
    for (final experience in resume.workExperiences) {
      add(
        _entryHeaderText(
          _dateRange(experience.dateRange),
          experience.organization,
          experience.position,
        ),
        ResumeWordStyle.entryHeader,
      );
      add(experience.summary);
      bullets(experience.highlights);
    }
    if (resume.educations.isNotEmpty) heading('教育经历');
    for (final education in resume.educations) {
      add(
        _entryHeaderText(
          _dateRange(education.dateRange),
          education.institution,
          [
            education.degree,
            education.fieldOfStudy,
          ].where((detail) => detail.isNotEmpty).join(' · '),
        ),
        ResumeWordStyle.entryHeader,
      );
      bullets(education.highlights);
    }
    if (resume.projects.isNotEmpty) heading('项目经历');
    for (final project in resume.projects) {
      add(
        _entryHeaderText(
          project.dateRange == null ? '' : _dateRange(project.dateRange!),
          project.name,
          project.role,
        ),
        ResumeWordStyle.entryHeader,
      );
      add(project.summary);
      bullets(project.highlights);
      for (final link in project.links) {
        add('${link.label}：${link.url}');
      }
    }
    if (resume.skillGroups.isNotEmpty) heading('技能');
    for (final group in resume.skillGroups) {
      add('${group.name}：${group.skills.join('、')}');
    }
    if (resume.certifications.isNotEmpty) heading('证书');
    for (final certificate in resume.certifications) {
      add(certificate.name, ResumeWordStyle.subtitle);
      add(
        [
          certificate.issuer,
          if (certificate.issuedOn case final date?) '颁发：${_date(date)}',
          if (certificate.expiresOn case final date?) '到期：${_date(date)}',
          certificate.credentialId,
        ].where((detail) => detail.isNotEmpty).join(' · '),
        ResumeWordStyle.metadata,
      );
      add(certificate.credentialUrl);
    }
    if (resume.languages.isNotEmpty) heading('语言');
    for (final language in resume.languages) {
      add('${language.name}：${_proficiency(language.proficiency)}');
    }
    for (final section in resume.customSections) {
      heading(section.title);
      for (final entry in section.items) {
        add(entry.title, ResumeWordStyle.subtitle);
        add(entry.description);
      }
    }
    if (resume.unmapped.isNotEmpty) {
      heading('待确认内容');
      // 整体保留未知原文；不按猜测的子结构筛选，避免丢掉未识别的字段。
      add(const JsonEncoder.withIndent('  ').convert(resume.unmapped));
    }
    final document = ResumeWordDocument(
      paragraphs: paragraphs,
      photo: profile.photo,
      aiProvenance: ResumeAiProvenance.fromResume(resume),
      aigcMetadata: ResumeAigcMetadata.fromResume(resume),
    );
    _validateDocument(document);
    return document;
  }

  Uint8List encode(ResumeWordDocument document) {
    _validateDocument(document);
    final documentXml = _documentXml(document);
    _validateXmlStructure(documentXml, photoLayout: document.photo != null);
    final package = Archive();
    for (final part in {
      ..._partsFor(
        photo: document.photo != null,
        ai: document.aiProvenance != null || document.aigcMetadata != null,
      ),
      'word/document.xml': documentXml,
      if (document.aiProvenance != null || document.aigcMetadata != null)
        _aiMetadataPath: _aiMetadata(
          document.aiProvenance,
          document.aigcMetadata,
        ),
      if (document.photo case final photo?)
        _photoMetadataPath: _photoMetadata(photo.extensions),
    }.entries) {
      final content = utf8.encode(part.value);
      // STORE 避免任何解压膨胀；本轮只读取本应用生成的文件。
      package.add(
        ArchiveFile(part.key, content.length, content)
          ..compression = CompressionType.none,
      );
    }
    if (document.photo case final photo?) {
      final content = photo.bytes;
      package.add(
        ArchiveFile(_photoPath, content.length, content)
          ..compression = CompressionType.none,
      );
    }
    final bytes = Uint8List.fromList(ZipEncoder().encode(package));
    if (bytes.length > maxFileBytes) {
      throw const FormatException('Word 文稿超过 4 MiB 上限，请减少内容后重试。');
    }
    return bytes;
  }

  ResumeWordDocument decode(Uint8List bytes) {
    if (bytes.length > maxFileBytes || bytes.length < 22) {
      throw const FormatException('Word 文稿大小无效或超过 4 MiB 上限。');
    }
    try {
      return _decodePackage(bytes);
    } on ArchiveException {
      throw const FormatException('Word 文稿包已损坏，请保留原文件并重新生成。');
    } on RangeError {
      throw const FormatException('Word 文稿包不完整，请保留原文件并重新生成。');
    } on XmlException {
      throw const FormatException('Word 文稿 XML 已损坏，请保留原文件并重新生成。');
    }
  }

  ResumeWordDocument _decodePackage(Uint8List bytes) {
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    final photoLayout = directory.fileHeaders.any(
      (part) => part.filename == _photoPath,
    );
    final aiLayout = directory.fileHeaders.any(
      (part) => part.filename == _aiMetadataPath,
    );
    final expectedPaths = {
      ..._templateParts.keys,
      'word/document.xml',
      if (photoLayout) _photoPath,
      if (photoLayout) _photoMetadataPath,
      if (aiLayout) _aiMetadataPath,
    };
    if (directory.fileHeaders.length != expectedPaths.length ||
        directory.totalCentralDirectoryEntries != expectedPaths.length ||
        directory.numberOfThisDisk != 0 ||
        directory.diskWithTheStartOfTheCentralDirectory != 0) {
      throw const FormatException('只支持本应用生成的 Word 文稿包。');
    }
    final paths = <String>{};
    var totalSize = 0;
    final parts = <String, String>{};
    ResumePhoto? photo;
    for (final header in directory.fileHeaders) {
      final file = header.file;
      if (!paths.add(header.filename) ||
          !expectedPaths.contains(header.filename) ||
          file == null ||
          file.filename != header.filename ||
          header.compressionMethod != 0 ||
          file.compressionMethod != CompressionType.none ||
          (header.generalPurposeBitFlag & ~0x800) != 0 ||
          (file.flags & ~0x800) != 0 ||
          header.compressedSize != header.uncompressedSize ||
          header.uncompressedSize < 0 ||
          (header.externalFileAttributes >> 16 & 0xf000) == 0xa000) {
        throw const FormatException('Word 文稿包含不支持的路径、压缩方式或文件结构。');
      }
      totalSize += header.uncompressedSize;
      if (totalSize > maxFileBytes) {
        throw const FormatException('Word 文稿内容超过读取上限。');
      }
      final content = file.getStream().toUint8List();
      if (content.length != header.uncompressedSize ||
          getCrc32(content) != header.crc32) {
        throw const FormatException('Word 文稿校验失败，请保留原文件并重新生成。');
      }
      if (header.filename == _photoPath) {
        if (content.length > 512 * 1024) {
          throw const FormatException('Word 证件照超过 512 KiB 上限。');
        }
        photo = ResumePhoto(
          dataBase64: base64Encode(content),
          mimeType: 'image/jpeg',
          width: 500,
          height: 700,
        );
        continue;
      }
      final xml = utf8.decode(content);
      if (header.filename != _photoMetadataPath && xml.contains('<!')) {
        throw const FormatException('Word 文稿不支持 DTD、实体声明或附加 XML 标记。');
      }
      parts[header.filename] = xml;
    }
    // 显式识别两个固定版本，不放宽成接受任意 Office 样式或关系。
    final legacyLayout =
        parts['word/styles.xml'] == _legacyTemplateParts['word/styles.xml'];
    if (legacyLayout && aiLayout) {
      throw const FormatException('旧版 Word 文稿不支持新增的来源记录结构。');
    }
    final expectedParts = legacyLayout
        ? _legacyTemplateParts
        : _partsFor(photo: photoLayout, ai: aiLayout);
    for (final part in expectedParts.entries) {
      if (parts[part.key] != part.value) {
        throw const FormatException('Word 文稿的样式或关系不受支持，请使用应用内编辑。');
      }
    }
    if (photo != null) {
      final metadata = parts[_photoMetadataPath]!;
      _validatePhotoMetadata(metadata);
      final fields = jsonDecode(metadata);
      if (fields is! Map<String, dynamic> ||
          fields.length != 1 ||
          fields['extensions'] is! Map<String, dynamic>) {
        throw const FormatException('Word 证件照附加字段结构无效。');
      }
      photo = ResumePhoto(
        dataBase64: photo.dataBase64,
        mimeType: photo.mimeType,
        width: photo.width,
        height: photo.height,
        extensions: Map<String, Object?>.from(fields['extensions'] as Map),
      );
      if (_photoMetadata(photo.extensions) != metadata) {
        throw const FormatException('Word 证件照附加字段格式无效。');
      }
    }
    final sourceXml = parts['word/document.xml']!;
    _validateXmlStructure(sourceXml, photoLayout: photoLayout);
    final xmlDocument = XmlDocument.parse(sourceXml);
    final body = xmlDocument.rootElement.getElement('w:body');
    if (body == null) throw const FormatException('Word 文稿缺少正文。');
    final paragraphs = <ResumeWordParagraph>[];
    final paragraphElements = <XmlElement>[];
    if (photoLayout) {
      final table = body.getElement('w:tbl');
      final cell = table?.getElement('w:tr')?.getElement('w:tc');
      if (cell == null) throw const FormatException('Word 文稿缺少固定照片页眉。');
      paragraphElements.addAll(cell.findElements('w:p'));
    }
    paragraphElements.addAll(body.findElements('w:p'));
    for (final paragraph in paragraphElements) {
      if (paragraphs.length >= maxParagraphs + (aiLayout ? 1 : 0)) {
        throw const FormatException('Word 文稿段落数量超过上限。');
      }
      final styleName = paragraph
          .getElement('w:pPr')
          ?.getElement('w:pStyle')
          ?.getAttribute('w:val');
      final styles = ResumeWordStyle.values.where(
        (style) => style.name == styleName,
      );
      if (styles.length != 1) throw const FormatException('Word 文稿含有不支持的段落样式。');
      if (legacyLayout && styles.single.index >= 6) {
        throw const FormatException('旧版 Word 文稿含有不支持的段落样式。');
      }
      final text = StringBuffer();
      for (final run in paragraph.findElements('w:r')) {
        for (final element in run.childElements) {
          switch (element.name.qualified) {
            case 'w:t':
              text.write(element.innerText);
            case 'w:br':
              text.write('\n');
            case 'w:tab':
              text.write('\t');
            case 'w:drawing':
              // 仅容许 v3 固定照片对象；末尾完整重建会核对其每个节点和属性。
              if (!photoLayout || paragraphs.isNotEmpty) {
                throw const FormatException('Word 文稿含有不支持的图片对象。');
              }
            default:
              throw const FormatException('Word 文稿含有不支持的正文对象或格式。');
          }
        }
      }
      var paragraphText = text.toString();
      if (styles.single == ResumeWordStyle.bullet) {
        final marker = legacyLayout ? '· ' : '• ';
        if (!paragraphText.startsWith(marker)) {
          throw const FormatException('Word 成果条目的格式已改变。');
        }
        paragraphText = paragraphText.substring(2);
      }
      paragraphs.add(
        ResumeWordParagraph(text: paragraphText, style: styles.single),
      );
    }
    final (aiProvenance, aigcMetadata) = aiLayout
        ? _decodeAiMetadata(parts[_aiMetadataPath]!)
        : (null, null);
    final aiNotice =
        aigcMetadata?.notice ??
        (aiProvenance == null ? null : ResumeAiProvenance.notice);
    if (aiNotice != null) {
      if (paragraphs.isEmpty ||
          paragraphs.last.style != ResumeWordStyle.metadata ||
          paragraphs.last.text != aiNotice) {
        throw const FormatException('AI 生成内容标识缺失或被修改，请保留原文稿。');
      }
      paragraphs.removeLast();
    }
    final document = ResumeWordDocument(
      paragraphs: paragraphs,
      photo: photo,
      aiProvenance: aiProvenance,
      aigcMetadata: aigcMetadata,
    );
    _validateDocument(document);
    // 从实际正文还原后完整核对，防止表格、修订、隐藏文字及行内格式被静默丢弃。
    if (_documentXml(document, legacyLayout: legacyLayout) != sourceXml) {
      throw const FormatException('Word 文稿包含不支持的格式或结构，请使用应用内编辑。');
    }
    return document;
  }
}

void _validateXmlStructure(String sourceXml, {bool photoLayout = false}) {
  var depth = 0;
  var elementCount = 0;
  // 先流式检查再建立 DOM，避免畸形深嵌套或海量空节点耗尽内存。
  for (final event in parseEvents(
    sourceXml,
    validateNesting: true,
    validateNamespace: true,
    validateDocument: true,
  )) {
    if (event is XmlStartElementEvent) {
      elementCount++;
      if (depth >= (photoLayout ? 16 : 6) || elementCount > 100000) {
        throw const FormatException('Word 文稿结构过深或元素数量超过上限。');
      }
      if (!event.isSelfClosing) depth++;
    } else if (event is XmlEndElementEvent) {
      depth--;
    }
  }
}

/// 转换入口只接收 DOCX 字节，不持有原始 ResumeData 快照。
final class ResumeDocxPdfConverter {
  const ResumeDocxPdfConverter();

  Future<Uint8List> convert(
    Uint8List docxBytes, {
    required ResumePdfFonts fonts,
  }) async {
    final wordDocument = const ResumeDocxCodec().decode(docxBytes);
    final regularGlyphs = TtfParser(fonts.regular).charToGlyphIndexMap;
    final boldGlyphs = TtfParser(fonts.bold).charToGlyphIndexMap;
    for (final paragraph in wordDocument.paragraphs) {
      final glyphs = switch (paragraph.style) {
        ResumeWordStyle.title ||
        ResumeWordStyle.subtitle ||
        ResumeWordStyle.heading ||
        ResumeWordStyle.entryHeader => boldGlyphs,
        _ => regularGlyphs,
      };
      // 字体缺字必须阻止转换；不能让渲染库用空框替代用户事实。
      for (final rune in paragraph.text.runes) {
        if (rune != 9 && rune != 10 && rune != 13 && (glyphs[rune] ?? 0) == 0) {
          throw const FormatException(
            '文稿含当前 PDF 字体不支持的字符，请在 Word 中调整后重新转换。原文稿仍保留。',
          );
        }
      }
    }
    final regularFont = pw.Font.ttf(fonts.regular);
    final boldFont = pw.Font.ttf(fonts.bold);
    final theme = pw.ThemeData.withFont(base: regularFont, bold: boldFont);
    final pdfDocument = pw.Document(
      producer: '简历全能帮',
      theme: theme,
      subject: wordDocument.aiNotice,
      keywords: wordDocument.aiProvenance?.toMetadataJson(),
    );
    if (wordDocument.aigcMetadata case final aigc?) {
      addResumeAigcPdfMetadata(pdfDocument.document, aigc);
    }
    try {
      pdfDocument.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(
            ResumePageLayout.marginLeftMm * PdfPageFormat.mm,
            ResumePageLayout.marginTopMm * PdfPageFormat.mm,
            ResumePageLayout.marginRightMm * PdfPageFormat.mm,
            ResumePageLayout.marginBottomMm * PdfPageFormat.mm,
          ),
          maxPages: 1000,
          theme: theme,
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          footer: (context) => pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              '第 ${context.pageNumber} / ${context.pagesCount} 页',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
            ),
          ),
          build: (_) => _wordPdfContent(wordDocument, regularFont, boldFont),
        ),
      );
      return await pdfDocument.save(enableEventLoopBalancing: true);
    } on PdfException {
      throw const FormatException('文稿内容无法在当前 PDF 模板中完整排版，请调整后重新转换。原文稿仍保留。');
    }
  }
}

List<pw.Widget> _wordPdfContent(
  ResumeWordDocument document,
  pw.Font regularFont,
  pw.Font boldFont,
) {
  final count = document.photo == null ? 0 : _profileParagraphCount(document);
  return [
    if (document.aiNotice case final notice?) ...[
      pw.Text(notice),
      pw.SizedBox(height: 2 * PdfPageFormat.mm),
    ],
    if (document.photo case final photo?) ...[
      ResumePageLayout.photoProfileHeader(
        bytes: photo.bytes,
        text: [
          for (final paragraph in document.paragraphs.take(count)) ...[
            ..._wordPdfParagraphs(paragraph, regularFont, boldFont),
            pw.SizedBox(
              height: paragraph.style == ResumeWordStyle.title ? 5 : 2,
            ),
          ],
        ],
      ),
      pw.SizedBox(height: 2 * PdfPageFormat.mm),
    ],
    for (final paragraph in document.paragraphs.skip(count)) ...[
      if (paragraph.style == ResumeWordStyle.heading) pw.NewPage(freeSpace: 60),
      if (paragraph.style == ResumeWordStyle.entryHeader ||
          paragraph.style == ResumeWordStyle.subtitle)
        pw.NewPage(freeSpace: 34),
      ..._wordPdfParagraphs(paragraph, regularFont, boldFont),
      pw.SizedBox(height: paragraph.style == ResumeWordStyle.title ? 5 : 2),
    ],
  ];
}

List<pw.Widget> _wordPdfParagraphs(
  ResumeWordParagraph paragraph,
  pw.Font regularFont,
  pw.Font boldFont,
) {
  final style = paragraph.style;
  final bold =
      style == ResumeWordStyle.title ||
      style == ResumeWordStyle.heading ||
      style == ResumeWordStyle.subtitle ||
      style == ResumeWordStyle.entryHeader;
  final textStyle = pw.TextStyle(
    font: bold ? boldFont : regularFont,
    fontSize: switch (style) {
      ResumeWordStyle.title => ResumePageLayout.titleFontSize,
      ResumeWordStyle.heading => ResumePageLayout.headingFontSize,
      _ => ResumePageLayout.bodyFontSize,
    },
    lineSpacing: ResumePageLayout.lineSpacing,
    color: PdfColors.black,
  );
  if (style == ResumeWordStyle.entryHeader) {
    final fields = paragraph.text.split('\t');
    if (fields.length == 3) {
      return ResumePageLayout.entryHeader(
        date: fields[0],
        title: fields[1],
        role: fields[2],
        boldFont: boldFont,
      );
    }
  }
  if (style == ResumeWordStyle.bullet) {
    return [ResumePageLayout.bullet(_wrapLongTokens(paragraph.text))];
  }
  final centered =
      style == ResumeWordStyle.title ||
      style == ResumeWordStyle.headline ||
      style == ResumeWordStyle.contact;
  final text = pw.Text(
    centered
        ? ResumePageLayout.wrapProfileText(paragraph.text)
        : _wrapLongTokens(paragraph.text),
    textAlign: centered ? pw.TextAlign.center : pw.TextAlign.left,
    style: textStyle,
    overflow: pw.TextOverflow.span,
  );
  if (style == ResumeWordStyle.heading) {
    return [
      pw.SizedBox(height: 6),
      text,
      pw.Divider(
        height: 5,
        thickness: ResumePageLayout.headingRuleWidth,
        color: PdfColors.black,
      ),
    ];
  }
  return [if (centered) pw.Center(child: text) else text];
}

void _validateDocument(ResumeWordDocument document) {
  if (document.paragraphs.isEmpty ||
      document.paragraphs.length > ResumeDocxCodec.maxParagraphs) {
    throw const FormatException('Word 文稿需包含 1 至 10000 个段落。');
  }
  var textCharacters = 0;
  for (final paragraph in document.paragraphs) {
    textCharacters += paragraph.text.length;
    for (final rune in paragraph.text.runes) {
      if (!(rune == 9 ||
          rune == 10 ||
          rune == 13 ||
          rune >= 0x20 && rune <= 0xd7ff ||
          rune >= 0xe000 && rune <= 0xfffd ||
          rune >= 0x10000 && rune <= 0x10ffff)) {
        throw const FormatException('Word 文稿包含无法保存的控制字符。');
      }
    }
  }
  if (textCharacters > ResumeDocxCodec.maxTextCharacters) {
    throw const FormatException('Word 文稿文字超过 500000 字符上限。');
  }
  if (document.photo != null) {
    validatePrintPhotoBytes(document.photo!.bytes);
    _profileParagraphCount(document);
    _photoMetadata(document.photo!.extensions);
  }
}

String _documentXml(ResumeWordDocument document, {bool legacyLayout = false}) {
  final body = StringBuffer();
  var headerCount = 0;
  if (document.photo != null) {
    headerCount = _profileParagraphCount(document);
    body.write(
      '<w:tbl><w:tblPr><w:tblW w:w="10546" w:type="dxa"/>'
      '<w:tblLayout w:type="fixed"/><w:tblCellMar>'
      '<w:top w:w="0" w:type="dxa"/><w:left w:w="0" w:type="dxa"/>'
      '<w:bottom w:w="0" w:type="dxa"/><w:right w:w="0" w:type="dxa"/>'
      '</w:tblCellMar></w:tblPr><w:tblGrid><w:gridCol w:w="10546"/>'
      '</w:tblGrid><w:tr><w:trPr><w:cantSplit/>'
      '<w:trHeight w:val="1985" w:hRule="atLeast"/></w:trPr>'
      '<w:tc><w:tcPr><w:tcW w:w="10546" w:type="dxa"/>'
      '<w:vAlign w:val="top"/></w:tcPr>',
    );
    for (var index = 0; index < headerCount; index++) {
      body.write(
        _paragraphXml(
          document.paragraphs[index],
          photoHeader: true,
          drawing: index == 0,
        ),
      );
    }
    body.write('</w:tc></w:tr></w:tbl>');
  }
  for (final paragraph in document.paragraphs.skip(headerCount)) {
    body.write(_paragraphXml(paragraph, legacyLayout: legacyLayout));
  }
  if (document.aiNotice case final notice?) {
    body.write(
      _paragraphXml(
        ResumeWordParagraph(text: notice, style: ResumeWordStyle.metadata),
      ),
    );
  }
  final margins = legacyLayout
      ? '<w:pgMar w:top="907" w:right="907" w:bottom="907" w:left="907" w:header="0" w:footer="0" w:gutter="0"/>'
      : '<w:pgMar w:top="680" w:right="680" w:bottom="794" w:left="680" w:header="0" w:footer="0" w:gutter="0"/>';
  final photoNamespaces = document.photo == null
      ? ''
      : ' xmlns:r="$_officeRelationsNamespace" xmlns:wp="$_drawingWordNamespace"'
            ' xmlns:a="$_drawingNamespace" xmlns:pic="$_pictureNamespace"';
  return '$_declaration<w:document xmlns:w="$_wordNamespace"$photoNamespaces><w:body>$body'
      '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>$margins</w:sectPr>'
      '</w:body></w:document>';
}

String _paragraphXml(
  ResumeWordParagraph paragraph, {
  bool legacyLayout = false,
  bool photoHeader = false,
  bool drawing = false,
}) {
  final body = StringBuffer(
    '<w:p><w:pPr><w:pStyle w:val="${paragraph.style.name}"/>'
    '${photoHeader ? '<w:ind w:left="1701" w:right="1701"/>' : ''}'
    '</w:pPr><w:r>${drawing ? _photoDrawing : ''}',
  );
  final marker = legacyLayout ? '· ' : '• ';
  final text =
      '${paragraph.style == ResumeWordStyle.bullet ? marker : ''}'
      '${paragraph.text}';
  for (final segment in text.split(RegExp(r'(?=[\n\t\r])|(?<=[\n\t\r])'))) {
    body.write(switch (segment) {
      '\n' => '<w:br/>',
      '\t' => '<w:tab/>',
      '\r' => '<w:t xml:space="preserve">&#13;</w:t>',
      _ => '<w:t xml:space="preserve">${XmlText(segment).toXmlString()}</w:t>',
    });
  }
  body.write('</w:r></w:p>');
  return body.toString();
}

int _profileParagraphCount(ResumeWordDocument document) {
  if (document.paragraphs.isEmpty ||
      document.paragraphs.first.style != ResumeWordStyle.title) {
    throw const FormatException('带照片的 Word 文稿须以姓名标题开头。');
  }
  var count = 1;
  for (final style in [ResumeWordStyle.headline, ResumeWordStyle.contact]) {
    if (count < document.paragraphs.length &&
        document.paragraphs[count].style == style) {
      count++;
    }
  }
  // 有照片时页眉是一个不可分割区块，不能允许无限量文字撑出首页。
  if (document.paragraphs
              .take(count)
              .fold<int>(0, (sum, p) => sum + p.text.length) >
          1200 ||
      document.paragraphs.first.text.length > 240) {
    throw const FormatException('带照片的基本信息超过 1200 字符，请缩短后导出。');
  }
  return count;
}

String _photoMetadata(JsonMap extensions) {
  final json = jsonEncode({'extensions': extensions});
  _validatePhotoMetadata(json);
  return json;
}

void _validatePhotoMetadata(String json) {
  if (utf8.encode(json).length > 64 * 1024) {
    throw const FormatException('Word 证件照附加字段超过 64 KiB。');
  }
  var depth = 0;
  var quoted = false;
  var escaped = false;
  for (final code in json.codeUnits) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (code == 92) {
        escaped = true;
      } else if (code == 34) {
        quoted = false;
      }
    } else if (code == 34) {
      quoted = true;
    } else if (code == 123 || code == 91) {
      if (++depth > 32) throw const FormatException('Word 证件照附加字段结构过深。');
    } else if (code == 125 || code == 93) {
      depth--;
    }
  }
}

String _wrapLongTokens(String text) =>
    text.replaceAllMapped(RegExp(r'[^\s\u2e80-\u9fff]{48,}'), (match) {
      final runes = match[0]!.runes.toList();
      return [
        for (var start = 0; start < runes.length; start += 40)
          String.fromCharCodes(
            runes.sublist(start, (start + 40).clamp(0, runes.length)),
          ),
      ].join('\n');
    });

String _entryHeaderText(String date, String title, String role) {
  final columns = ResumePageLayout.canUseEntryColumns(
    date: date,
    title: title,
    role: role,
  );
  // 长字段换成可自然跨页的独立行；只改变布局，不截断或缩写事实。
  return [date, title, role].join(columns ? '\t' : '\n');
}

String _date(ResumeDate date) =>
    '${date.year}${date.month == null ? '' : '.${date.month.toString().padLeft(2, '0')}'}';
String _dateRange(DateRange range) =>
    '${_date(range.start)}${range.isCurrent
        ? ' - 至今'
        : range.end == null
        ? ''
        : ' - ${_date(range.end!)}'}';
String _proficiency(LanguageProficiency proficiency) => switch (proficiency) {
  LanguageProficiency.native => '母语',
  LanguageProficiency.fluent => '流利',
  LanguageProficiency.professional => '工作熟练',
  LanguageProficiency.intermediate => '中级',
  LanguageProficiency.basic => '基础',
  LanguageProficiency.unspecified => '未指定',
};

const _declaration = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
const _wordNamespace =
    'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _relationsNamespace =
    'http://schemas.openxmlformats.org/package/2006/relationships';
const _officeRelationsNamespace =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _drawingWordNamespace =
    'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing';
const _drawingNamespace =
    'http://schemas.openxmlformats.org/drawingml/2006/main';
const _pictureNamespace =
    'http://schemas.openxmlformats.org/drawingml/2006/picture';
const _photoPath = 'word/media/resume-photo.jpg';
const _photoMetadataPath = 'word/photo.json';
const _aiMetadataPath = 'docProps/custom.xml';
const _customPropertiesNamespace =
    'http://schemas.openxmlformats.org/officeDocument/2006/custom-properties';
const _variantNamespace =
    'http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes';

// Custom properties may hold separate application provenance and one AIGC label.
Map<String, String> _partsFor({required bool photo, required bool ai}) {
  final parts = Map<String, String>.of(
    photo ? _photoTemplateParts : _templateParts,
  );
  if (!ai) return parts;
  parts['[Content_Types].xml'] = parts['[Content_Types].xml']!.replaceFirst(
    '</Types>',
    '<Override PartName="/$_aiMetadataPath" '
        'ContentType="application/vnd.openxmlformats-officedocument.custom-properties+xml"/></Types>',
  );
  parts['_rels/.rels'] = parts['_rels/.rels']!.replaceFirst(
    '</Relationships>',
    '<Relationship Id="rIdAiProvenance" '
        'Type="$_officeRelationsNamespace/custom-properties" '
        'Target="$_aiMetadataPath"/></Relationships>',
  );
  return parts;
}

String _aiMetadata(ResumeAiProvenance? provenance, ResumeAigcMetadata? aigc) {
  var id = 2;
  String property(String name, String value) =>
      '<property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="${id++}" '
      'name="$name"><vt:lpwstr>${XmlText(value).toXmlString()}'
      '</vt:lpwstr></property>';
  return '$_declaration<Properties xmlns="$_customPropertiesNamespace" '
      'xmlns:vt="$_variantNamespace">'
      '${provenance == null ? '' : property('ResumeAllInOneAiProvenance', jsonEncode(provenance.toJson()))}'
      '${aigc == null ? '' : property('AIGC', aigc.toJsonString())}'
      '</Properties>';
}

(ResumeAiProvenance?, ResumeAigcMetadata?) _decodeAiMetadata(String source) {
  if (utf8.encode(source).length > 128 * 1024) {
    throw const FormatException('Word AI 来源或标识记录超过大小限制。');
  }
  _validateXmlStructure(source);
  final xml = XmlDocument.parse(source);
  ResumeAiProvenance? provenance;
  ResumeAigcMetadata? aigc;
  final names = <String>{};
  for (final property in xml.rootElement.childElements) {
    final name = property.getAttribute('name');
    final value = property.getElement('vt:lpwstr')?.innerText;
    if (name == null || !names.add(name) || value == null) {
      throw const FormatException('Word AI 来源或标识缺失或重复。');
    }
    switch (name) {
      case 'ResumeAllInOneAiProvenance':
        provenance = ResumeAiProvenance.fromJson(jsonDecode(value));
      case 'AIGC':
        if (utf8.encode(value).length > ResumeAigcMetadata.maxJsonBytes) {
          throw const FormatException('AIGC 元数据超过 16 KiB。');
        }
        aigc = ResumeAigcMetadata.fromJson(jsonDecode(value));
      default:
        throw const FormatException('Word 自定义属性不受支持。');
    }
  }
  if (names.isEmpty || _aiMetadata(provenance, aigc) != source) {
    throw const FormatException('Word AI 来源记录结构不受支持。');
  }
  return (provenance, aigc);
}

// EMU 为 1/914400 英寸：25×35mm；首页页顶 12mm，右边距 12mm。
const _photoDrawing =
    '<w:drawing><wp:anchor distT="0" distB="0" distL="0" distR="0"'
    ' simplePos="0" relativeHeight="1" behindDoc="0" locked="1" layoutInCell="0" allowOverlap="0">'
    '<wp:simplePos x="0" y="0"/><wp:positionH relativeFrom="page">'
    '<wp:posOffset>6228000</wp:posOffset></wp:positionH>'
    '<wp:positionV relativeFrom="page"><wp:posOffset>432000</wp:posOffset></wp:positionV>'
    '<wp:extent cx="900000" cy="1260000"/><wp:effectExtent l="0" t="0" r="0" b="0"/>'
    '<wp:wrapNone/><wp:docPr id="1" name="证件照"/>'
    '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
    '<a:graphic><a:graphicData uri="$_pictureNamespace"><pic:pic>'
    '<pic:nvPicPr><pic:cNvPr id="0" name="resume-photo.jpg"/>'
    '<pic:cNvPicPr><a:picLocks noChangeAspect="1"/></pic:cNvPicPr></pic:nvPicPr>'
    '<pic:blipFill><a:blip r:embed="rIdPhoto"/>'
    '<a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
    '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="900000" cy="1260000"/></a:xfrm>'
    '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
    '</pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing>';

final _templateParts = <String, String>{
  '[Content_Types].xml':
      '$_declaration<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>',
  '_rels/.rels':
      '$_declaration<Relationships xmlns="$_relationsNamespace">'
      '<Relationship Id="rId1" Type="$_officeRelationsNamespace/officeDocument" Target="word/document.xml"/></Relationships>',
  'word/_rels/document.xml.rels':
      '$_declaration<Relationships xmlns="$_relationsNamespace">'
      '<Relationship Id="rId1" Type="$_officeRelationsNamespace/styles" Target="styles.xml"/></Relationships>',
  'word/styles.xml':
      '$_declaration<w:styles xmlns:w="$_wordNamespace">'
      '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Noto Sans SC" w:hAnsi="Noto Sans SC" w:eastAsia="Noto Sans SC"/>'
      '<w:sz w:val="20"/><w:lang w:val="zh-CN" w:eastAsia="zh-CN"/></w:rPr></w:rPrDefault></w:docDefaults>'
      '${ResumeWordStyle.values.map(_styleXml).join()}</w:styles>',
};

final _legacyTemplateParts = <String, String>{
  ..._templateParts,
  'word/styles.xml':
      '$_declaration<w:styles xmlns:w="$_wordNamespace">'
      '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Noto Sans SC" w:hAnsi="Noto Sans SC" w:eastAsia="Noto Sans SC"/>'
      '<w:sz w:val="19"/><w:lang w:val="zh-CN" w:eastAsia="zh-CN"/></w:rPr></w:rPrDefault></w:docDefaults>'
      '${ResumeWordStyle.values.take(6).map(_legacyStyleXml).join()}</w:styles>',
};

final _photoTemplateParts = <String, String>{
  ..._templateParts,
  '[Content_Types].xml': _templateParts['[Content_Types].xml']!.replaceFirst(
    '</Types>',
    '<Default Extension="jpg" ContentType="image/jpeg"/>'
        '<Override PartName="/word/photo.json" ContentType="application/json"/></Types>',
  ),
  'word/_rels/document.xml.rels':
      _templateParts['word/_rels/document.xml.rels']!.replaceFirst(
        '</Relationships>',
        '<Relationship Id="rIdPhoto" Type="$_officeRelationsNamespace/image"'
            ' Target="media/resume-photo.jpg"/></Relationships>',
      ),
};

String _styleXml(ResumeWordStyle style) {
  final size = switch (style) {
    ResumeWordStyle.title => 40,
    ResumeWordStyle.heading => 22,
    _ => 20,
  };
  final bold = {
    ResumeWordStyle.title,
    ResumeWordStyle.heading,
    ResumeWordStyle.subtitle,
    ResumeWordStyle.entryHeader,
  }.contains(style);
  final centered = {
    ResumeWordStyle.title,
    ResumeWordStyle.headline,
    ResumeWordStyle.contact,
  }.contains(style);
  final before = style == ResumeWordStyle.heading
      ? 160
      : style == ResumeWordStyle.entryHeader
      ? 60
      : 0;
  final after = style == ResumeWordStyle.title
      ? 80
      : style == ResumeWordStyle.heading || style == ResumeWordStyle.contact
      ? 60
      : 30;
  return '<w:style w:type="paragraph" w:styleId="${style.name}"><w:name w:val="${style.name}"/>'
      '<w:pPr>${bold || centered ? '<w:keepNext/>' : ''}<w:widowControl/>'
      '${style == ResumeWordStyle.heading ? '<w:pBdr><w:bottom w:val="single" w:sz="4" w:space="3" w:color="000000"/></w:pBdr>' : ''}'
      '${style == ResumeWordStyle.entryHeader ? '<w:tabs><w:tab w:val="center" w:pos="5273"/><w:tab w:val="right" w:pos="10546"/></w:tabs>' : ''}'
      '<w:spacing w:before="$before" w:after="$after" w:line="300" w:lineRule="atLeast"/>'
      '${style == ResumeWordStyle.bullet ? '<w:ind w:left="240" w:hanging="240"/>' : ''}'
      '<w:jc w:val="${centered ? 'center' : 'left'}"/></w:pPr>'
      '<w:rPr>${bold ? '<w:b/>' : ''}<w:color w:val="000000"/><w:sz w:val="$size"/></w:rPr></w:style>';
}

String _legacyStyleXml(ResumeWordStyle style) {
  final size = switch (style) {
    ResumeWordStyle.title => 48,
    ResumeWordStyle.heading => 26,
    ResumeWordStyle.subtitle => 22,
    ResumeWordStyle.metadata => 17,
    _ => 19,
  };
  final bold = {
    ResumeWordStyle.title,
    ResumeWordStyle.heading,
    ResumeWordStyle.subtitle,
  }.contains(style);
  return '<w:style w:type="paragraph" w:styleId="${style.name}"><w:name w:val="${style.name}"/>'
      '<w:pPr><w:spacing w:after="100" w:line="300" w:lineRule="auto"/>${bold ? '<w:keepNext/>' : ''}</w:pPr>'
      '<w:rPr>${bold ? '<w:b/>' : ''}<w:sz w:val="$size"/></w:rPr></w:style>';
}
