import 'dart:convert';

import 'package:resume_domain/resume_domain.dart';

enum ResumeExportFormat { markdown, json }

extension ResumeExportFormatProperties on ResumeExportFormat {
  String get fileExtension => switch (this) {
    ResumeExportFormat.markdown => 'md',
    ResumeExportFormat.json => 'json',
  };
}

final class ResumeJsonExporter {
  const ResumeJsonExporter({this.codec = const CanonicalResumeCodec()});

  final CanonicalResumeCodec codec;

  String export(ResumeData resume) {
    ResumeAigcMetadata.fromResume(resume);
    final validatedJson = codec.encode(resume);
    final canonicalJsonObject = jsonDecode(validatedJson);
    return '${const JsonEncoder.withIndent('  ').convert(canonicalJsonObject)}\n';
  }
}

final class ResumeMarkdownExporter {
  const ResumeMarkdownExporter({this.validator = const ResumeValidator()});

  final ResumeValidator validator;

  String export(ResumeData resume) {
    final validationResult = validator.validate(resume);
    if (!validationResult.isValid) {
      throw ResumeValidationException(validationResult);
    }

    // 固定章节顺序让同一版本的导出结果可比较，也便于 fixture 捕获意外变化。
    final markdown = StringBuffer();
    final aigc = ResumeAigcMetadata.fromResume(resume);
    if (aigc != null) {
      markdown.writeln('---');
      markdown.writeln('AIGC:');
      for (final entry in aigc.toJson().entries) {
        markdown.writeln('  ${entry.key}: ${jsonEncode(entry.value)}');
      }
      markdown.writeln('---');
    }
    final aiNotice = ResumeAiProvenance.noticeForResume(resume);
    if (aiNotice != null) {
      markdown.writeln(aiNotice);
      markdown.writeln();
    }
    final profile = resume.profile;
    final displayName = profile.fullName.trim();
    markdown.writeln(
      '# ${_inline(displayName.isEmpty ? '未命名简历' : displayName)}',
    );

    _paragraph(markdown, profile.headline);

    final contactDetails =
        <String>[profile.email, profile.phone, profile.location]
            .map((detail) => detail.trim())
            .where((detail) => detail.isNotEmpty)
            .toList();
    if (contactDetails.isNotEmpty) {
      markdown.writeln(contactDetails.map(_inline).join(' · '));
      markdown.writeln();
    }

    if (profile.links.isNotEmpty) {
      markdown.writeln('## 链接');
      markdown.writeln();
      for (final link in profile.links) {
        markdown.writeln('- [${_inline(link.label)}](${link.url})');
      }
      markdown.writeln();
    }

    if (resume.workExperiences.isNotEmpty) {
      markdown.writeln('## 工作经历');
      markdown.writeln();
      for (final workExperience in resume.workExperiences) {
        markdown.writeln(
          '### ${_inline(workExperience.position)} · '
          '${_inline(workExperience.organization)}',
        );
        markdown.writeln();
        markdown.writeln('_${_dateRange(workExperience.dateRange)}_');
        markdown.writeln();
        _paragraph(markdown, workExperience.summary);
        _bullets(markdown, workExperience.highlights);
      }
    }

    if (resume.educations.isNotEmpty) {
      markdown.writeln('## 教育经历');
      markdown.writeln();
      for (final education in resume.educations) {
        final qualification = [education.degree, education.fieldOfStudy]
            .map((field) => field.trim())
            .where((field) => field.isNotEmpty)
            .map(_inline)
            .join(' · ');
        markdown.writeln('### ${_inline(education.institution)}');
        markdown.writeln();
        if (qualification.isNotEmpty) {
          markdown.writeln(qualification);
        }
        markdown.writeln('_${_dateRange(education.dateRange)}_');
        markdown.writeln();
        _bullets(markdown, education.highlights);
      }
    }

    if (resume.projects.isNotEmpty) {
      markdown.writeln('## 项目经历');
      markdown.writeln();
      for (final project in resume.projects) {
        markdown.writeln('### ${_inline(project.name)}');
        markdown.writeln();
        final projectMetadata = <String>[
          project.role.trim(),
          if (project.dateRange case final dateRange?) _dateRange(dateRange),
        ].where((field) => field.isNotEmpty).map(_inline).join(' · ');
        if (projectMetadata.isNotEmpty) {
          markdown.writeln(projectMetadata);
          markdown.writeln();
        }
        _paragraph(markdown, project.summary);
        _bullets(markdown, project.highlights);
        for (final projectLink in project.links) {
          markdown.writeln(
            '- [${_inline(projectLink.label)}](${projectLink.url})',
          );
        }
        if (project.links.isNotEmpty) {
          markdown.writeln();
        }
      }
    }

    if (resume.skillGroups.isNotEmpty) {
      markdown.writeln('## 技能');
      markdown.writeln();
      for (final skillGroup in resume.skillGroups) {
        final skillList = skillGroup.skills.map(_inline).join('、');
        markdown.writeln('- **${_inline(skillGroup.name)}：** $skillList');
      }
      markdown.writeln();
    }

    if (resume.certifications.isNotEmpty) {
      markdown.writeln('## 证书');
      markdown.writeln();
      for (final certification in resume.certifications) {
        final certificationDetails = <String>[
          certification.issuer.trim(),
          if (certification.issuedOn case final issuedOn?)
            '颁发：${_date(issuedOn)}',
          if (certification.expiresOn case final expiresOn?)
            '到期：${_date(expiresOn)}',
          certification.credentialId.trim(),
        ].where((detail) => detail.isNotEmpty).map(_inline).join(' · ');
        final certificationName = _inline(certification.name);
        final certificationLabel = certification.credentialUrl.trim().isEmpty
            ? '**$certificationName**'
            : '[$certificationName](${certification.credentialUrl})';
        markdown.writeln(
          '- $certificationLabel'
          '${certificationDetails.isEmpty ? '' : ' — $certificationDetails'}',
        );
      }
      markdown.writeln();
    }

    if (resume.languages.isNotEmpty) {
      markdown.writeln('## 语言');
      markdown.writeln();
      for (final language in resume.languages) {
        markdown.writeln(
          '- ${_inline(language.name)}：${_proficiency(language.proficiency)}',
        );
      }
      markdown.writeln();
    }

    for (final customSection in resume.customSections) {
      markdown.writeln('## ${_inline(customSection.title)}');
      markdown.writeln();
      for (final customItem in customSection.items) {
        markdown.writeln('### ${_inline(customItem.title)}');
        markdown.writeln();
        _paragraph(markdown, customItem.description);
      }
    }

    if (resume.unmapped.isNotEmpty) {
      markdown.writeln('## 待确认内容');
      markdown.writeln();
      markdown.writeln('以下内容尚未映射到正式简历字段：');
      markdown.writeln();
      final unmappedJson = const JsonEncoder.withIndent(
        '  ',
      ).convert(resume.unmapped);
      for (final jsonLine in const LineSplitter().convert(unmappedJson)) {
        markdown.writeln('    $jsonLine');
      }
      markdown.writeln();
    }

    return '${markdown.toString().trimRight()}\n';
  }

  void _paragraph(StringBuffer markdown, String paragraphText) {
    final text = paragraphText.trim();
    if (text.isEmpty) {
      return;
    }
    markdown.writeln(text);
    markdown.writeln();
  }

  void _bullets(StringBuffer markdown, List<String> bulletTexts) {
    for (final bulletText in bulletTexts) {
      markdown.writeln('- ${bulletText.trim()}');
    }
    if (bulletTexts.isNotEmpty) {
      markdown.writeln();
    }
  }

  String _dateRange(DateRange range) {
    final start = _date(range.start);
    if (range.isCurrent) {
      return '$start – 至今';
    }
    final end = range.end;
    return end == null ? start : '$start – ${_date(end)}';
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

  String _inline(String text) {
    return text
        .trim()
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .replaceAll(r'\', r'\\')
        .replaceAll('*', r'\*')
        .replaceAll('_', r'\_')
        .replaceAll('[', r'\[')
        .replaceAll(']', r'\]');
  }
}
