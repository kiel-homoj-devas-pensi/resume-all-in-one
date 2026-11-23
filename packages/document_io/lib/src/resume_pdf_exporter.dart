import 'dart:convert';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:resume_domain/resume_domain.dart';

import 'resume_page_layout.dart';
import 'resume_aigc_pdf_metadata.dart';

final class ResumePdfFonts {
  const ResumePdfFonts({required this.regular, required this.bold});

  final ByteData regular;
  final ByteData bold;
}

final class ResumePdfExporter {
  const ResumePdfExporter({this.validator = const ResumeValidator()});

  final ResumeValidator validator;

  Future<Uint8List> export(
    ResumeData resume, {
    required ResumePdfFonts fonts,
  }) async {
    final validationResult = validator.validate(resume);
    if (!validationResult.isValid) {
      throw ResumeValidationException(validationResult);
    }

    final template = _ChineseResumePdfTemplate(resume: resume, fonts: fonts);
    final aigc = ResumeAigcMetadata.fromResume(resume);
    final pdfDocument = pw.Document(
      pageMode: PdfPageMode.outlines,
      producer: '简历全能帮',
      subject: ResumeAiProvenance.noticeForResume(resume),
      keywords: ResumeAiProvenance.fromResume(resume)?.toMetadataJson(),
      theme: template.theme,
    );
    if (aigc != null) {
      addResumeAigcPdfMetadata(pdfDocument.document, aigc);
    }
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
        theme: template.theme,
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        header: template.buildPageHeader,
        footer: template.buildPageFooter,
        build: (_) => template.buildContent(),
      ),
    );
    return pdfDocument.save(enableEventLoopBalancing: true);
  }
}

final class _ChineseResumePdfTemplate {
  _ChineseResumePdfTemplate({
    required this.resume,
    required ResumePdfFonts fonts,
  }) : regularFont = pw.Font.ttf(fonts.regular),
       boldFont = pw.Font.ttf(fonts.bold) {
    final fontTheme = pw.ThemeData.withFont(base: regularFont, bold: boldFont);
    theme = fontTheme.copyWith(
      defaultTextStyle: fontTheme.defaultTextStyle.copyWith(
        fontSize: ResumePageLayout.bodyFontSize,
        lineSpacing: ResumePageLayout.lineSpacing,
        color: _ink,
      ),
      paragraphStyle: fontTheme.paragraphStyle.copyWith(
        fontSize: ResumePageLayout.bodyFontSize,
        lineSpacing: ResumePageLayout.lineSpacing,
        color: _ink,
      ),
      bulletStyle: fontTheme.bulletStyle.copyWith(
        fontSize: ResumePageLayout.bodyFontSize,
        lineSpacing: ResumePageLayout.lineSpacing,
        color: _ink,
      ),
    );
  }

  final ResumeData resume;
  final pw.Font regularFont;
  final pw.Font boldFont;
  late final pw.ThemeData theme;

  pw.Widget buildPageHeader(pw.Context context) {
    if (context.pageNumber == 1) {
      return pw.SizedBox();
    }
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 2 * PdfPageFormat.mm),
      child: pw.Text(
        _displayName,
        style: pw.TextStyle(font: boldFont, fontSize: 8, color: _ink),
        overflow: pw.TextOverflow.span,
      ),
    );
  }

  pw.Widget buildPageFooter(pw.Context context) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 2 * PdfPageFormat.mm),
      alignment: pw.Alignment.centerRight,
      child: pw.Text(
        '第 ${context.pageNumber} / ${context.pagesCount} 页',
        style: pw.TextStyle(fontSize: 8, color: _muted),
      ),
    );
  }

  List<pw.Widget> buildContent() {
    final content = <pw.Widget>[];
    if (ResumeAiProvenance.noticeForResume(resume) case final notice?) {
      content.add(pw.Text(notice));
      content.add(pw.SizedBox(height: 2 * PdfPageFormat.mm));
    }
    _addProfileHeader(content);
    _addLinks(content);
    _addWorkExperiences(content);
    _addEducations(content);
    _addProjects(content);
    _addSkillGroups(content);
    _addCertifications(content);
    _addLanguages(content);
    _addCustomSections(content);
    _addUnmapped(content);
    return content;
  }

  String get _displayName {
    final fullName = resume.profile.fullName.trim();
    return fullName.isEmpty ? '未命名简历' : fullName;
  }

  void _addProfileHeader(List<pw.Widget> content) {
    final profile = resume.profile;
    final header = <pw.Widget>[];
    final contactDetails = [
      profile.email.trim(),
      profile.phone.trim(),
      profile.location.trim(),
    ].where((detail) => detail.isNotEmpty).toList();
    header.add(
      pw.Center(
        child: pw.Text(
          ResumePageLayout.wrapProfileText(_displayName),
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            font: boldFont,
            fontSize: ResumePageLayout.titleFontSize,
            color: _ink,
          ),
          overflow: pw.TextOverflow.span,
        ),
      ),
    );
    if (profile.headline.trim().isNotEmpty) {
      header
        ..add(pw.SizedBox(height: 1 * PdfPageFormat.mm))
        ..add(
          pw.Center(
            child: pw.Text(
              ResumePageLayout.wrapProfileText(profile.headline.trim()),
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(
                fontSize: ResumePageLayout.bodyFontSize,
              ),
              overflow: pw.TextOverflow.span,
            ),
          ),
        );
    }
    if (contactDetails.isNotEmpty) {
      header
        ..add(pw.SizedBox(height: 1 * PdfPageFormat.mm))
        ..add(
          pw.Center(
            child: pw.Text(
              ResumePageLayout.wrapProfileText(contactDetails.join('  ·  ')),
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(
                fontSize: ResumePageLayout.metadataFontSize,
              ),
              overflow: pw.TextOverflow.span,
            ),
          ),
        );
    }
    final photo = profile.photo;
    if (photo == null) {
      content.addAll(header);
    } else {
      content.add(
        ResumePageLayout.photoProfileHeader(bytes: photo.bytes, text: header),
      );
    }
    content.add(pw.SizedBox(height: 2 * PdfPageFormat.mm));
  }

  void _addLinks(List<pw.Widget> content) {
    if (resume.profile.links.isEmpty) {
      return;
    }
    _startSection(content, '链接');
    for (final link in resume.profile.links) {
      content
        ..add(
          pw.UrlLink(
            destination: link.url,
            child: pw.Text(
              link.label.trim(),
              style: const pw.TextStyle(color: _ink),
              overflow: pw.TextOverflow.span,
            ),
          ),
        )
        ..add(
          pw.Text(
            _softWrapLongToken(link.url.trim()),
            style: const pw.TextStyle(fontSize: ResumePageLayout.bodyFontSize),
            overflow: pw.TextOverflow.span,
          ),
        )
        ..add(_entryGap());
    }
  }

  void _addWorkExperiences(List<pw.Widget> content) {
    if (resume.workExperiences.isEmpty) {
      return;
    }
    _startSection(content, '工作经历');
    for (final experience in resume.workExperiences) {
      _keepEntryHeadingTogether(content);
      _addEntryHeader(
        content,
        date: _dateRange(experience.dateRange),
        organization: experience.organization,
        role: experience.position,
      );
      _addParagraph(content, experience.summary);
      _addBullets(content, experience.highlights);
      content.add(_entryGap());
    }
  }

  void _addEducations(List<pw.Widget> content) {
    if (resume.educations.isEmpty) {
      return;
    }
    _startSection(content, '教育经历');
    for (final education in resume.educations) {
      _keepEntryHeadingTogether(content);
      final qualification = [
        education.degree.trim(),
        education.fieldOfStudy.trim(),
      ].where((detail) => detail.isNotEmpty).join(' · ');
      _addEntryHeader(
        content,
        date: _dateRange(education.dateRange),
        organization: education.institution,
        role: qualification,
      );
      _addBullets(content, education.highlights);
      content.add(_entryGap());
    }
  }

  void _addProjects(List<pw.Widget> content) {
    if (resume.projects.isEmpty) {
      return;
    }
    _startSection(content, '项目经历');
    for (final project in resume.projects) {
      _keepEntryHeadingTogether(content);
      _addEntryHeader(
        content,
        date: project.dateRange == null ? '' : _dateRange(project.dateRange!),
        organization: project.name,
        role: project.role,
      );
      _addParagraph(content, project.summary);
      _addBullets(content, project.highlights);
      for (final projectLink in project.links) {
        content.add(
          pw.UrlLink(
            destination: projectLink.url,
            child: pw.Text(
              '${projectLink.label.trim()}：'
              '${_softWrapLongToken(projectLink.url.trim())}',
              style: const pw.TextStyle(color: _ink),
              overflow: pw.TextOverflow.span,
            ),
          ),
        );
      }
      content.add(_entryGap());
    }
  }

  void _addSkillGroups(List<pw.Widget> content) {
    if (resume.skillGroups.isEmpty) {
      return;
    }
    _startSection(content, '技能');
    for (final skillGroup in resume.skillGroups) {
      content.add(
        pw.Text(
          '${skillGroup.name.trim()}：${skillGroup.skills.join('、')}',
          overflow: pw.TextOverflow.span,
        ),
      );
      content.add(pw.SizedBox(height: 1.2 * PdfPageFormat.mm));
    }
  }

  void _addCertifications(List<pw.Widget> content) {
    if (resume.certifications.isEmpty) {
      return;
    }
    _startSection(content, '证书');
    for (final certification in resume.certifications) {
      _keepEntryHeadingTogether(content);
      content.add(_entryTitle(certification.name));
      final details = [
        certification.issuer.trim(),
        if (certification.issuedOn case final issuedOn?)
          '颁发：${_date(issuedOn)}',
        if (certification.expiresOn case final expiresOn?)
          '到期：${_date(expiresOn)}',
        certification.credentialId.trim(),
      ].where((detail) => detail.isNotEmpty).join('  |  ');
      if (details.isNotEmpty) {
        content.add(_metadata(details));
      }
      if (certification.credentialUrl.trim().isNotEmpty) {
        content.add(
          pw.UrlLink(
            destination: certification.credentialUrl,
            child: pw.Text(
              _softWrapLongToken(certification.credentialUrl.trim()),
              style: const pw.TextStyle(color: _ink),
              overflow: pw.TextOverflow.span,
            ),
          ),
        );
      }
      content.add(_entryGap());
    }
  }

  void _addLanguages(List<pw.Widget> content) {
    if (resume.languages.isEmpty) {
      return;
    }
    _startSection(content, '语言');
    for (final language in resume.languages) {
      content.add(
        pw.Text(
          '${language.name.trim()}：${_proficiency(language.proficiency)}',
          overflow: pw.TextOverflow.span,
        ),
      );
      content.add(pw.SizedBox(height: 1.2 * PdfPageFormat.mm));
    }
  }

  void _addCustomSections(List<pw.Widget> content) {
    for (final customSection in resume.customSections) {
      _startSection(content, customSection.title.trim());
      for (final customItem in customSection.items) {
        _keepEntryHeadingTogether(content);
        content.add(_entryTitle(customItem.title));
        _addParagraph(content, customItem.description);
        content.add(_entryGap());
      }
    }
  }

  void _addUnmapped(List<pw.Widget> content) {
    if (resume.unmapped.isEmpty) {
      return;
    }
    _startSection(content, '待确认内容');
    for (final unmappedLine in _unmappedDisplayLines(resume.unmapped)) {
      content.add(
        pw.Text(
          unmappedLine,
          style: const pw.TextStyle(fontSize: ResumePageLayout.bodyFontSize),
          overflow: pw.TextOverflow.span,
        ),
      );
      content.add(pw.SizedBox(height: 1.2 * PdfPageFormat.mm));
    }
  }

  void _startSection(List<pw.Widget> content, String title) {
    content
      // 预留章节标题和首条内容的空间，避免标题单独留在页尾。
      ..add(pw.NewPage(freeSpace: 54))
      ..add(
        pw.Container(
          width: double.infinity,
          margin: const pw.EdgeInsets.only(
            top: 2 * PdfPageFormat.mm,
            bottom: 1.2 * PdfPageFormat.mm,
          ),
          padding: const pw.EdgeInsets.only(bottom: 0.8 * PdfPageFormat.mm),
          decoration: const pw.BoxDecoration(
            border: pw.Border(
              bottom: pw.BorderSide(
                width: ResumePageLayout.headingRuleWidth,
                color: _ink,
              ),
            ),
          ),
          child: pw.Text(
            title,
            style: pw.TextStyle(
              font: boldFont,
              fontSize: ResumePageLayout.headingFontSize,
              color: _ink,
            ),
            overflow: pw.TextOverflow.span,
          ),
        ),
      );
  }

  void _keepEntryHeadingTogether(List<pw.Widget> content) {
    content.add(pw.NewPage(freeSpace: 42));
  }

  void _addEntryHeader(
    List<pw.Widget> content, {
    required String date,
    required String organization,
    required String role,
  }) {
    content.addAll(
      ResumePageLayout.entryHeader(
        date: date,
        title: organization,
        role: role,
        boldFont: boldFont,
      ),
    );
  }

  pw.Widget _entryTitle(String title) {
    return pw.Text(
      title.trim(),
      style: pw.TextStyle(
        font: boldFont,
        fontSize: ResumePageLayout.entryFontSize,
        color: _ink,
      ),
      overflow: pw.TextOverflow.span,
    );
  }

  pw.Widget _metadata(String metadata) {
    return pw.Text(
      metadata,
      style: const pw.TextStyle(
        fontSize: ResumePageLayout.metadataFontSize,
        color: _ink,
      ),
      overflow: pw.TextOverflow.span,
    );
  }

  void _addParagraph(List<pw.Widget> content, String paragraph) {
    final trimmedParagraph = paragraph.trim();
    if (trimmedParagraph.isEmpty) {
      return;
    }
    content
      ..add(pw.SizedBox(height: 0.6 * PdfPageFormat.mm))
      ..add(pw.Text(trimmedParagraph, overflow: pw.TextOverflow.span));
  }

  void _addBullets(List<pw.Widget> content, List<String> bullets) {
    for (final bullet in bullets) {
      content
        ..add(pw.SizedBox(height: 0.4 * PdfPageFormat.mm))
        ..add(ResumePageLayout.bullet(bullet.trim()));
    }
  }

  pw.Widget _entryGap() => pw.SizedBox(height: 1.4 * PdfPageFormat.mm);

  String _dateRange(DateRange range) {
    final start = _date(range.start);
    if (range.isCurrent) {
      return '$start - 至今';
    }
    final end = range.end;
    return end == null ? start : '$start - ${_date(end)}';
  }

  String _date(ResumeDate date) {
    final month = date.month;
    return month == null
        ? '${date.year}'
        : '${date.year}.${month.toString().padLeft(2, '0')}';
  }

  String _proficiency(LanguageProficiency proficiency) => switch (proficiency) {
    LanguageProficiency.native => '母语',
    LanguageProficiency.fluent => '流利',
    LanguageProficiency.professional => '工作熟练',
    LanguageProficiency.intermediate => '中级',
    LanguageProficiency.basic => '基础',
    LanguageProficiency.unspecified => '未指定',
  };

  List<String> _unmappedDisplayLines(JsonMap unmapped) {
    final displayLines = <String>[];
    final remainingUnmapped = Map<String, Object?>.from(unmapped);
    final textImport = remainingUnmapped.remove('textImport');
    if (textImport is Map && textImport['lines'] is List) {
      for (final storedLine in textImport['lines']! as List) {
        if (storedLine is Map &&
            storedLine['lineNumber'] is int &&
            storedLine['text'] is String) {
          displayLines.add(
            '原第 ${storedLine['lineNumber']} 行：${storedLine['text']}',
          );
        }
      }
    } else if (textImport != null) {
      remainingUnmapped['textImport'] = textImport;
    }
    if (remainingUnmapped.isNotEmpty) {
      displayLines.add(
        const JsonEncoder.withIndent('  ').convert(remainingUnmapped),
      );
    }
    return displayLines;
  }

  String _softWrapLongToken(String text) {
    const chunkSize = 64;
    final codePoints = text.runes.toList(growable: false);
    if (codePoints.length <= chunkSize) {
      return text;
    }
    final chunks = <String>[];
    for (var offset = 0; offset < codePoints.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, codePoints.length);
      chunks.add(String.fromCharCodes(codePoints.sublist(offset, end)));
    }
    // PDF 字体不保证包含零宽空格；显式换行能稳定切开长 token，也不会产生缺字警告。
    return chunks.join('\n');
  }
}

const _ink = PdfColors.black;
const _muted = PdfColors.grey700;
