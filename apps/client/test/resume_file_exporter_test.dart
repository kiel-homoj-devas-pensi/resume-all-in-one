import 'dart:io';

import 'package:document_io/document_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('导出写入应用目录且文件名不包含用户姓名或标题', () async {
    final root = await Directory.systemTemp.createTemp('resume-export-test-');
    try {
      final exporter = ResumeFileExporter(rootDirectory: () async => root);
      final now = DateTime.utc(2026, 10, 1);
      final content = ResumeData(
        profile: ResumeProfile(
          id: 'profile-001',
          fullName: '敏感姓名',
          headline: '工程师',
          email: '',
          phone: '',
          location: '',
        ),
      );
      final document = ResumeDocument(
        id: '../document-001',
        title: '敏感标题',
        currentVersionId: 'version:001',
        createdAt: now,
        updatedAt: now,
      );
      final version = ResumeVersion(
        id: 'version:001',
        documentId: document.id,
        parentVersionId: null,
        schemaVersion: currentResumeSchemaVersion,
        content: content,
        source: ResumeVersionSource.created,
        createdAt: now,
      );

      final markdown = await exporter.export(
        document: document,
        version: version,
        format: ResumeExportFormat.markdown,
      );
      final json = await exporter.export(
        document: document,
        version: version,
        format: ResumeExportFormat.json,
      );

      expect(
        markdown.parent.path,
        '${root.path}${Platform.pathSeparator}resume_exports',
      );
      expect(markdown.path, isNot(contains('敏感姓名')));
      expect(markdown.path, isNot(contains('敏感标题')));
      expect(markdown.path, endsWith('.md'));
      expect(json.path, endsWith('.json'));
      expect(await markdown.readAsString(), contains('# 敏感姓名'));
      expect(await json.readAsString(), contains('"schemaVersion": "0.1.0"'));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('PDF 预览生成不落盘，确认导出时写入完全相同的字节', () async {
    final root = await Directory.systemTemp.createTemp('resume-pdf-test-');
    try {
      final exporter = ResumeFileExporter(rootDirectory: () async => root);
      final now = DateTime.utc(2026, 10, 2);
      final content = ResumeData(
        profile: ResumeProfile(
          id: 'profile-pdf',
          fullName: '中文预览',
          headline: '工程师',
          email: '',
          phone: '',
          location: '',
        ),
      );
      final document = ResumeDocument(
        id: '../document-pdf',
        title: '不应出现在文件名中的标题',
        currentVersionId: 'version:pdf',
        createdAt: now,
        updatedAt: now,
      );
      final version = ResumeVersion(
        id: 'version:pdf',
        documentId: document.id,
        parentVersionId: null,
        schemaVersion: currentResumeSchemaVersion,
        content: content,
        source: ResumeVersionSource.created,
        createdAt: now,
      );

      final previewBytes = await exporter.buildPdfBytes(version);
      final exportDirectory = Directory(
        '${root.path}${Platform.pathSeparator}resume_exports',
      );
      expect(await exportDirectory.exists(), isFalse);

      final pdfFile = await exporter.exportPdf(
        document: document,
        version: version,
        pdfBytes: previewBytes,
      );

      expect(pdfFile.path, endsWith('.pdf'));
      expect(pdfFile.path, isNot(contains('中文预览')));
      expect(pdfFile.path, isNot(contains('不应出现在文件名中的标题')));
      expect(await pdfFile.readAsBytes(), previewBytes);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
