import 'dart:convert';
import 'dart:typed_data';

import 'package:resume_domain/resume_domain.dart';

const defaultResumeImportMaxBytes = 512 * 1024;
const defaultResumeDocumentImportMaxBytes = 4 * 1024 * 1024;

enum ResumeTextImportFormat { plainText, markdown, docx, pdf }

enum ResumeTextImportFailure {
  unsupportedFileType,
  inputTooLarge,
  invalidUtf8,
  emptyInput,
  invalidDocument,
  encryptedDocument,
  documentTooComplex,
  documentTimeout,
}

final class ResumeTextImportException implements Exception {
  const ResumeTextImportException(this.failure, this.message);

  final ResumeTextImportFailure failure;
  final String message;

  @override
  String toString() => 'ResumeTextImportException(${failure.name}): $message';
}

final class ResumeImportPreview {
  const ResumeImportPreview({
    required this.format,
    required this.resume,
    required this.validation,
    required this.unmappedLineCount,
  });

  final ResumeTextImportFormat format;
  final ResumeData resume;
  final ResumeValidationResult validation;
  final int unmappedLineCount;

  bool get canCommit => validation.isValid;
}

final class ResumeTextImporter {
  const ResumeTextImporter({
    this.validator = const ResumeValidator(),
    this.maxBytes = defaultResumeImportMaxBytes,
  }) : assert(maxBytes > 0);

  final ResumeValidator validator;
  final int maxBytes;

  ResumeImportPreview importBytes(
    Uint8List fileBytes, {
    required String fileName,
    required String profileId,
  }) {
    final importFormat = _formatForFileName(fileName);
    if (fileBytes.length > maxBytes) {
      throw ResumeTextImportException(
        ResumeTextImportFailure.inputTooLarge,
        '导入文件不能超过 $maxBytes 字节',
      );
    }

    final String decodedText;
    try {
      decodedText = utf8.decode(fileBytes, allowMalformed: false);
    } on FormatException {
      throw const ResumeTextImportException(
        ResumeTextImportFailure.invalidUtf8,
        '文件不是有效的 UTF-8 文本',
      );
    }

    final textWithoutBom = decodedText.startsWith('\uFEFF')
        ? decodedText.substring(1)
        : decodedText;
    return importText(
      textWithoutBom,
      format: importFormat,
      profileId: profileId,
    );
  }

  ResumeImportPreview importText(
    String sourceText, {
    required ResumeTextImportFormat format,
    required String profileId,
  }) {
    if (profileId.trim().isEmpty) {
      throw ArgumentError.value(profileId, 'profileId', '不能为空');
    }
    if (utf8.encode(sourceText).length > maxBytes) {
      throw ResumeTextImportException(
        ResumeTextImportFailure.inputTooLarge,
        '导入文本不能超过 $maxBytes 字节',
      );
    }
    if (sourceText.trim().isEmpty) {
      throw const ResumeTextImportException(
        ResumeTextImportFailure.emptyInput,
        '导入文件没有可读取的文本',
      );
    }

    final logicalLines = sourceText.split(RegExp(r'\r\n|\n|\r'));
    final labeledLines = <String, List<_LabeledLine>>{};
    for (final indexedLine in logicalLines.indexed) {
      final lineNumber = indexedLine.$1 + 1;
      final labelMatch = _profileLabelPattern.firstMatch(indexedLine.$2);
      if (labelMatch == null) {
        continue;
      }
      final label = labelMatch.group(1)!.trim();
      if (!_supportedProfileLabels.contains(label)) {
        continue;
      }
      labeledLines
          .putIfAbsent(
            label == '意向职业岗位' ? '职业标题' : label,
            () => <_LabeledLine>[],
          )
          .add(
            _LabeledLine(
              lineNumber: lineNumber,
              value: labelMatch.group(2)!.trim(),
            ),
          );
    }

    final mappedLineNumbers = <int>{};
    String mappedValue(String label) {
      final candidates = labeledLines[label] ?? const <_LabeledLine>[];
      if (candidates.length != 1 || candidates.single.value.isEmpty) {
        return '';
      }
      mappedLineNumbers.add(candidates.single.lineNumber);
      return candidates.single.value;
    }

    final fullName = mappedValue('姓名');
    final headline = mappedValue('职业标题');
    final email = mappedValue('邮箱');
    final phone = mappedValue('电话');
    final location = mappedValue('所在地');

    final unmappedLines = <JsonMap>[];
    for (final indexedLine in logicalLines.indexed) {
      final lineNumber = indexedLine.$1 + 1;
      if (indexedLine.$2.trim().isEmpty ||
          mappedLineNumbers.contains(lineNumber)) {
        continue;
      }
      unmappedLines.add({'lineNumber': lineNumber, 'text': indexedLine.$2});
    }

    final unmapped = unmappedLines.isEmpty
        ? const <String, Object?>{}
        : <String, Object?>{
            'textImport': {'format': format.name, 'lines': unmappedLines},
          };
    final importedResume = ResumeData(
      profile: ResumeProfile(
        id: profileId,
        fullName: fullName,
        headline: headline,
        email: email,
        phone: phone,
        location: location,
      ),
      unmapped: unmapped,
    );
    final validationResult = validator.validate(importedResume);
    return ResumeImportPreview(
      format: format,
      resume: importedResume,
      validation: validationResult,
      unmappedLineCount: unmappedLines.length,
    );
  }

  ResumeTextImportFormat _formatForFileName(String fileName) {
    final normalizedName = fileName.trim().toLowerCase();
    if (normalizedName.endsWith('.txt')) {
      return ResumeTextImportFormat.plainText;
    }
    if (normalizedName.endsWith('.md')) {
      return ResumeTextImportFormat.markdown;
    }
    throw const ResumeTextImportException(
      ResumeTextImportFailure.unsupportedFileType,
      '只支持 .txt 和 .md 文件',
    );
  }
}

final _profileLabelPattern = RegExp(r'^\s*([^:：]+)\s*[:：]\s*(.*?)\s*$');

const _supportedProfileLabels = {'姓名', '职业标题', '意向职业岗位', '邮箱', '电话', '所在地'};

final class _LabeledLine {
  const _LabeledLine({required this.lineNumber, required this.value});

  final int lineNumber;
  final String value;
}
