import 'dart:convert';
import 'dart:typed_data';

import 'package:document_io/document_io.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

final class SelectedResumeTextFile {
  const SelectedResumeTextFile({
    required this.fileName,
    required this.bytes,
    this.extractedText,
    this.extractedFormat,
  });

  final String fileName;
  final Uint8List bytes;
  final String? extractedText;
  final ResumeTextImportFormat? extractedFormat;

  ResumeImportPreview createPreview({required String profileId}) {
    final text = extractedText;
    final format = extractedFormat;
    if (text != null && format != null) {
      return const ResumeTextImporter().importText(
        text,
        format: format,
        profileId: profileId,
      );
    }
    return const ResumeTextImporter().importBytes(
      bytes,
      fileName: fileName,
      profileId: profileId,
    );
  }
}

/// 将平台文件选择能力收束为导入流程真正需要的文件名和字节。
abstract interface class ResumeImportFilePicker {
  Future<SelectedResumeTextFile?> pickResumeTextFile();
}

final class SystemResumeImportFilePicker implements ResumeImportFilePicker {
  const SystemResumeImportFilePicker({
    Future<XFile?> Function({required List<XTypeGroup> acceptedTypeGroups})?
    pickFile,
    MethodChannel channel = const MethodChannel(
      'resume_all_in_one/text_import',
    ),
  }) : _pickFile = pickFile,
       _channel = channel;

  final Future<XFile?> Function({required List<XTypeGroup> acceptedTypeGroups})?
  _pickFile;
  final MethodChannel _channel;

  @override
  Future<SelectedResumeTextFile?> pickResumeTextFile() async {
    // Android 的 file_selector 会先整文件分配内存，必须在原生读取时限量。
    if (_pickFile == null &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      return _pickAndroidFile();
    }
    const resumeTextFiles = XTypeGroup(
      label: '纯文本或 Markdown 简历',
      extensions: ['txt', 'md'],
      mimeTypes: ['text/plain', 'text/markdown'],
      uniformTypeIdentifiers: ['public.plain-text', 'public.text'],
    );
    final selectedFile = await (_pickFile ?? openFile)(
      acceptedTypeGroups: const [resumeTextFiles],
    );
    if (selectedFile == null) {
      return null;
    }
    if (await selectedFile.length() > defaultResumeImportMaxBytes) {
      throw const ResumeTextImportException(
        ResumeTextImportFailure.inputTooLarge,
        '导入文件不能超过 512 KiB',
      );
    }
    final bytes = BytesBuilder(copy: false);
    // 文件可能在长度检查后增长；流式检查也必须在累积正文前执行。
    await for (final chunk in selectedFile.openRead()) {
      if (bytes.length + chunk.length > defaultResumeImportMaxBytes) {
        throw const ResumeTextImportException(
          ResumeTextImportFailure.inputTooLarge,
          '导入文件不能超过 512 KiB',
        );
      }
      bytes.add(chunk);
    }
    return SelectedResumeTextFile(
      fileName: selectedFile.name,
      bytes: bytes.takeBytes(),
    );
  }

  Future<SelectedResumeTextFile?> _pickAndroidFile() async {
    final Map<String, Object?>? result;
    try {
      result = await _channel.invokeMapMethod<String, Object?>(
        'pickResumeTextFile',
      );
    } on PlatformException catch (error) {
      if (error.code == 'input_too_large') {
        throw const ResumeTextImportException(
          ResumeTextImportFailure.inputTooLarge,
          '导入文件不能超过 512 KiB',
        );
      }
      if (error.code == 'unsupported_file_type') {
        throw const ResumeTextImportException(
          ResumeTextImportFailure.unsupportedFileType,
          '请选择 TXT、Markdown、Word DOCX 或 PDF 文件。',
        );
      }
      final mapped = _documentError(error.code);
      if (mapped != null) throw mapped;
      rethrow;
    }
    if (result == null) return null;
    final name = result['fileName'];
    final bytes = result['bytes'];
    if (name is! String || name.trim().isEmpty || bytes is! Uint8List) {
      throw const FormatException('文件选择返回值无效');
    }
    final extractedText = result['extractedText'];
    final extractedFormat = result['format'];
    if (extractedText != null || extractedFormat != null) {
      final format = switch (extractedFormat) {
        'docx' => ResumeTextImportFormat.docx,
        'pdf' => ResumeTextImportFormat.pdf,
        _ => null,
      };
      if (extractedText is! String ||
          format == null ||
          !name.toLowerCase().endsWith('.${format.name}')) {
        throw const FormatException('文档提取返回值无效');
      }
      if (utf8.encode(extractedText).length > defaultResumeImportMaxBytes) {
        throw _documentError('document_too_complex')!;
      }
      return SelectedResumeTextFile(
        fileName: name,
        bytes: Uint8List(0),
        extractedText: extractedText,
        extractedFormat: format,
      );
    }
    if (bytes.length > defaultResumeImportMaxBytes) {
      throw const ResumeTextImportException(
        ResumeTextImportFailure.inputTooLarge,
        '导入文件不能超过 512 KiB',
      );
    }
    return SelectedResumeTextFile(fileName: name, bytes: bytes);
  }
}

ResumeTextImportException? _documentError(String code) => switch (code) {
  'document_input_too_large' => const ResumeTextImportException(
    ResumeTextImportFailure.inputTooLarge,
    'Word DOCX 和 PDF 文件不能超过 4 MiB，请精简图片或拆分后导入。',
  ),
  'legacy_word_document' => const ResumeTextImportException(
    ResumeTextImportFailure.unsupportedFileType,
    '暂不支持旧版 Word DOC，请用 Word 或 WPS 另存为 DOCX 后导入。',
  ),
  'invalid_document' => const ResumeTextImportException(
    ResumeTextImportFailure.invalidDocument,
    '文档损坏或格式不受支持，请保留原件，另存为 DOCX 或文字 PDF 后重试。',
  ),
  'encrypted_document' => const ResumeTextImportException(
    ResumeTextImportFailure.encryptedDocument,
    '无法导入加密或禁止提取文字的 PDF，请先用阅读器保存可读取的副本。',
  ),
  'no_document_text' => const ResumeTextImportException(
    ResumeTextImportFailure.emptyInput,
    '未找到可提取文字；扫描件和图片需要先进行文字识别，再导入文本。',
  ),
  'unsupported_document_content' => const ResumeTextImportException(
    ResumeTextImportFailure.invalidDocument,
    '文档包含无法直接读取的嵌入内容，请另存为文字 PDF 或 TXT 后导入。',
  ),
  'document_too_complex' => const ResumeTextImportException(
    ResumeTextImportFailure.documentTooComplex,
    '文档过于复杂：最多 50 页 PDF、512 KiB 文字；请拆分后导入。',
  ),
  'document_timeout' => const ResumeTextImportException(
    ResumeTextImportFailure.documentTimeout,
    '文档提取超过 15 秒，已停止。请简化或另存为文字文件后重试。',
  ),
  _ => null,
};
