import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:document_io/document_io.dart';
import 'package:test/test.dart';

void main() {
  test('意向职业岗位兼容旧标签，冲突标签保留全部原文', () {
    const importer = ResumeTextImporter();
    final imported = importer.importText(
      '姓名：测试姓名\n意向职业岗位：软件工程师',
      format: ResumeTextImportFormat.plainText,
      profileId: 'profile-label-test',
    );
    expect(imported.resume.profile.headline, '软件工程师');
    expect(imported.unmappedLineCount, 0);
    final conflict = importer.importText(
      '姓名：测试姓名\n意向职业岗位：软件工程师\n职业标题：设计师',
      format: ResumeTextImportFormat.plainText,
      profileId: 'profile-label-conflict',
    );
    expect(conflict.resume.profile.headline, '');
    expect(conflict.unmappedLineCount, 2);
    expect(jsonEncode(conflict.resume.unmapped), contains('意向职业岗位：软件工程师'));
    expect(jsonEncode(conflict.resume.unmapped), contains('职业标题：设计师'));
  });
  const importer = ResumeTextImporter();

  group('纯文本与 Markdown 保守导入', () {
    test('唯一显式标签映射到 Profile，自由文本保留在 unmapped', () {
      final preview = importer.importBytes(
        File('test/fixtures/import_profile.txt').readAsBytesSync(),
        fileName: 'profile.TXT',
        profileId: 'profile-imported',
      );

      expect(preview.format, ResumeTextImportFormat.plainText);
      expect(preview.resume.profile.fullName, '张三');
      expect(preview.resume.profile.headline, 'Flutter 工程师');
      expect(preview.resume.profile.email, 'zhangsan@example.com');
      expect(preview.resume.profile.phone, '13800000000');
      expect(preview.resume.profile.location, '上海');
      expect(preview.unmappedLineCount, 1);
      expect(preview.resume.unmapped, {
        'textImport': {
          'format': 'plainText',
          'lines': [
            {'lineNumber': 7, 'text': '十年移动端开发经验，具体经历待人工整理。'},
          ],
        },
      });
      expect(preview.canCommit, isTrue);
    });

    test('Markdown 标题和经历不被猜测，按原行号进入 unmapped', () {
      final preview = importer.importBytes(
        File('test/fixtures/import_resume.md').readAsBytesSync(),
        fileName: 'resume.md',
        profileId: 'profile-markdown',
      );

      expect(preview.resume.profile.fullName, '张三');
      expect(preview.resume.workExperiences, isEmpty);
      expect(preview.unmappedLineCount, 3);
      final textImport = preview.resume.unmapped['textImport']! as Map;
      expect(textImport['lines'], [
        {'lineNumber': 1, 'text': '# 张三的简历'},
        {'lineNumber': 6, 'text': '## 工作经历'},
        {'lineNumber': 8, 'text': '- 2024 年起负责移动端架构'},
      ]);
    });

    test('重复标签保持未映射，不擅自选择第一项或最后一项', () {
      final preview = importer.importText(
        '姓名：张三\r\n姓名：李四\r\n邮箱：user@example.com',
        format: ResumeTextImportFormat.plainText,
        profileId: 'profile-duplicate',
      );

      expect(preview.resume.profile.fullName, isEmpty);
      expect(preview.resume.profile.email, 'user@example.com');
      expect(preview.unmappedLineCount, 2);
      expect(preview.canCommit, isTrue);
    });

    test('UTF-8 BOM 可读取，非法 UTF-8 被明确拒绝', () {
      final bomPreview = importer.importBytes(
        Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('姓名：张三')]),
        fileName: 'bom.txt',
        profileId: 'profile-bom',
      );
      expect(bomPreview.resume.profile.fullName, '张三');

      expect(
        () => importer.importBytes(
          Uint8List.fromList([0xFF, 0xFE, 0x00]),
          fileName: 'invalid.txt',
          profileId: 'profile-invalid',
        ),
        throwsA(
          isA<ResumeTextImportException>().having(
            (error) => error.failure,
            'failure',
            ResumeTextImportFailure.invalidUtf8,
          ),
        ),
      );
    });

    test('空输入、超长输入和不支持的扩展名在预览前拒绝', () {
      expect(
        () => importer.importText(
          '   ',
          format: ResumeTextImportFormat.plainText,
          profileId: 'profile-empty',
        ),
        throwsA(
          isA<ResumeTextImportException>().having(
            (error) => error.failure,
            'failure',
            ResumeTextImportFailure.emptyInput,
          ),
        ),
      );

      expect(
        () => importer.importBytes(
          Uint8List(defaultResumeImportMaxBytes + 1),
          fileName: 'large.md',
          profileId: 'profile-large',
        ),
        throwsA(
          isA<ResumeTextImportException>().having(
            (error) => error.failure,
            'failure',
            ResumeTextImportFailure.inputTooLarge,
          ),
        ),
      );

      expect(
        () => importer.importBytes(
          Uint8List.fromList(utf8.encode('姓名：张三')),
          fileName: 'resume.pdf',
          profileId: 'profile-pdf',
        ),
        throwsA(
          isA<ResumeTextImportException>().having(
            (error) => error.failure,
            'failure',
            ResumeTextImportFailure.unsupportedFileType,
          ),
        ),
      );
    });

    test('显式但非法的邮箱保留到预览，并由 validation 阻止确认', () {
      final preview = importer.importText(
        '姓名：张三\n邮箱：not-an-email',
        format: ResumeTextImportFormat.plainText,
        profileId: 'profile-invalid-email',
      );

      expect(preview.resume.profile.email, 'not-an-email');
      expect(preview.canCommit, isFalse);
      expect(
        preview.validation.issues.any(
          (issue) => issue.ruleId == 'email.format' && issue.blocksCommit,
        ),
        isTrue,
      );
    });
  });
}
