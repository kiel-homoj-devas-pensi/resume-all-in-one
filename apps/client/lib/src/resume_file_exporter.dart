import 'dart:io';

import 'package:document_io/document_io.dart';
import 'package:flutter/services.dart';
import 'package:resume_domain/resume_domain.dart';

import 'resume_word_store.dart';

typedef ResumeFontLoader = Future<ByteData> Function(String assetKey);

final class ResumeFileExporter {
  ResumeFileExporter({
    required Future<Directory> Function() rootDirectory,
    this.markdownExporter = const ResumeMarkdownExporter(),
    this.jsonExporter = const ResumeJsonExporter(),
    this.pdfExporter = const ResumePdfExporter(),
    ResumeFontLoader? fontLoader,
  }) : _rootDirectory = rootDirectory,
       _fontLoader = fontLoader ?? rootBundle.load;

  final Future<Directory> Function() _rootDirectory;
  final ResumeFontLoader _fontLoader;
  final ResumeMarkdownExporter markdownExporter;
  final ResumeJsonExporter jsonExporter;
  final ResumePdfExporter pdfExporter;
  late final wordStore = ResumeWordStore(
    rootDirectory: _rootDirectory,
    fontLoader: _fontLoader,
  );

  Future<File> export({
    required ResumeDocument document,
    required ResumeVersion version,
    required ResumeExportFormat format,
  }) async {
    final exportedText = switch (format) {
      ResumeExportFormat.markdown => markdownExporter.export(version.content),
      ResumeExportFormat.json => jsonExporter.export(version.content),
    };
    final exportedFile = await _buildExportFile(
      document: document,
      version: version,
      fileExtension: format.fileExtension,
    );
    await exportedFile.writeAsString(exportedText, flush: true);
    return exportedFile;
  }

  Future<Uint8List> buildPdfBytes(ResumeVersion version) async {
    final regularFontData = await _fontLoader(
      'packages/document_io/assets/fonts/NotoSansSC-Regular.ttf',
    );
    final boldFontData = await _fontLoader(
      'packages/document_io/assets/fonts/NotoSansSC-Bold.ttf',
    );
    return pdfExporter.export(
      version.content,
      fonts: ResumePdfFonts(regular: regularFontData, bold: boldFontData),
    );
  }

  Future<File> exportPdf({
    required ResumeDocument document,
    required ResumeVersion version,
    required Uint8List pdfBytes,
  }) async {
    final exportedFile = await _buildExportFile(
      document: document,
      version: version,
      fileExtension: 'pdf',
    );
    await exportedFile.writeAsBytes(pdfBytes, flush: true);
    return exportedFile;
  }

  Future<File> _buildExportFile({
    required ResumeDocument document,
    required ResumeVersion version,
    required String fileExtension,
  }) async {
    final applicationDocumentsDirectory = await _rootDirectory();
    final resumeExportDirectory = Directory(
      '${applicationDocumentsDirectory.path}'
      '${Platform.pathSeparator}resume_exports',
    );
    await resumeExportDirectory.create(recursive: true);

    // 文件名只包含内部 ID，不使用姓名或标题，避免文件系统元数据泄露简历事实。
    final safeDocumentId = _safeFileNamePart(document.id);
    final safeVersionId = _safeFileNamePart(version.id);
    final exportedFile = File(
      '${resumeExportDirectory.path}${Platform.pathSeparator}'
      'resume_${safeDocumentId}_$safeVersionId.$fileExtension',
    );
    return exportedFile;
  }

  String _safeFileNamePart(String identifier) {
    final sanitizedIdentifier = identifier.replaceAll(
      RegExp('[^A-Za-z0-9_-]'),
      '_',
    );
    if (sanitizedIdentifier.isEmpty) {
      return 'unknown';
    }
    return sanitizedIdentifier.length <= 48
        ? sanitizedIdentifier
        : sanitizedIdentifier.substring(0, 48);
  }
}
