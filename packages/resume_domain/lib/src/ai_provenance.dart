import 'dart:convert';

import 'aigc_metadata.dart';
import 'model.dart';

/// Application provenance, not a GB 45438 provider code or certified signature.
/// Absence means unrecorded origin; it does not prove human authorship.
final class ResumeAiProvenance {
  ResumeAiProvenance({required this.operationId}) {
    if (operationId.trim().isEmpty || operationId.length > 512) {
      throw const FormatException('AI 来源操作编号无效。');
    }
  }

  static const extensionKey = 'resumeAllInOneAiProvenance';
  static const notice = '本简历含AI生成内容，请核对事实。';
  static const candidateNotice = 'AI生成候选内容，请核对事实后再保存。';
  static String? noticeForResume(ResumeData resume) =>
      ResumeAigcMetadata.fromResume(resume)?.notice ??
      (fromResume(resume) == null ? null : notice);
  final String operationId;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'origin': 'remoteResumeGeneration',
    'operationId': operationId,
    'notice': notice,
  };

  /// ASCII JSON also remains readable by PDF metadata implementations that do
  /// not support Unicode Info strings. This is not a GB 45438 label encoder.
  String toMetadataJson() => jsonEncode(toJson()).replaceAllMapped(
    RegExp(r'[^\x20-\x7e]'),
    (match) =>
        '\\u${match[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
  );

  factory ResumeAiProvenance.fromJson(Object? json) {
    if (json is! Map ||
        json['schemaVersion'] != 1 ||
        json['origin'] != 'remoteResumeGeneration' ||
        json['notice'] != notice ||
        json['operationId'] is! String) {
      throw const FormatException('AI 来源记录不可读取，请保留原始资料。');
    }
    return ResumeAiProvenance(operationId: json['operationId'] as String);
  }

  static ResumeAiProvenance? fromResume(ResumeData resume) {
    if (!resume.extensions.containsKey(extensionKey)) return null;
    return ResumeAiProvenance.fromJson(resume.extensions[extensionKey]);
  }

  ResumeData attachTo(ResumeData resume) =>
      ResumeData.fromJson({...resume.toJson(), extensionKey: toJson()});
}
