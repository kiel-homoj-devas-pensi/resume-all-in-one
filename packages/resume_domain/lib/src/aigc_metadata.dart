import 'dart:convert';

import 'model.dart';

/// GB 45438 appendix E fields; identities must be supplied by the caller.
/// This validates structure, not the identity or authenticity of an upstream label.
final class ResumeAigcMetadata {
  ResumeAigcMetadata({
    required this.label,
    required this.contentProducer,
    required this.produceId,
    required this.contentPropagator,
    required this.propagateId,
    this.reservedCode1 = '',
    this.reservedCode2 = '',
  }) {
    if (!const {'1', '2', '3'}.contains(label)) {
      throw const FormatException('AIGC Label 必须为字符串 1、2 或 3。');
    }
    for (final entry in toJson().entries) {
      final reserved = entry.key.startsWith('ReservedCode');
      final limit = reserved ? 4096 : 512;
      final value = entry.value;
      if (value.length > limit ||
          (!reserved && value.trim().isEmpty) ||
          value.runes.any(
            (rune) =>
                rune < 0x20 ||
                rune >= 0x7f && rune <= 0x9f ||
                rune >= 0x200b && rune <= 0x200f ||
                rune >= 0x2028 && rune <= 0x202e ||
                rune >= 0x2060 && rune <= 0x206f ||
                rune == 0xfeff ||
                rune >= 0xd800 && rune <= 0xdfff,
          )) {
        throw FormatException('AIGC ${entry.key} 为空、超长或包含控制字符。');
      }
    }
    if (utf8.encode(toJsonString()).length > maxJsonBytes) {
      throw const FormatException('AIGC 元数据超过 16 KiB。');
    }
  }

  /// First write: GB appendix E note 1 uses identical generation/propagation
  /// identities and IDs. No provider name, code or content ID is invented here.
  factory ResumeAigcMetadata.firstGeneration({
    required String providerName,
    required String contentId,
    String reservedCode1 = '',
    String reservedCode2 = '',
  }) => ResumeAigcMetadata(
    label: '1',
    contentProducer: providerName,
    produceId: contentId,
    contentPropagator: providerName,
    propagateId: contentId,
    reservedCode1: reservedCode1,
    reservedCode2: reservedCode2,
  );

  static const extensionKey = 'AIGC';
  static const maxJsonBytes = 16 * 1024;
  static const fieldNames = {
    'Label',
    'ContentProducer',
    'ProduceID',
    'ReservedCode1',
    'ContentPropagator',
    'PropagateID',
    'ReservedCode2',
  };
  final String label;
  final String contentProducer;
  final String produceId;
  final String reservedCode1;
  final String contentPropagator;
  final String propagateId;
  final String reservedCode2;

  String get notice => switch (label) {
    '1' => '本简历含AI生成内容，请核对事实。',
    '2' => '本简历含可能由AI生成的内容，请核对事实。',
    _ => '本简历含疑似由AI生成的内容，请核对事实。',
  };

  Map<String, String> toJson() => {
    'Label': label,
    'ContentProducer': contentProducer,
    'ProduceID': produceId,
    'ReservedCode1': reservedCode1,
    'ContentPropagator': contentPropagator,
    'PropagateID': propagateId,
    'ReservedCode2': reservedCode2,
  };

  String toJsonString() => jsonEncode(toJson());

  factory ResumeAigcMetadata.fromJson(Object? json) {
    if (json is! Map ||
        json.length != fieldNames.length ||
        !json.keys.every(fieldNames.contains) ||
        !json.values.every((value) => value is String)) {
      throw const FormatException('AIGC 元数据必须恰含七个字符串字段。');
    }
    return ResumeAigcMetadata(
      label: json['Label'] as String,
      contentProducer: json['ContentProducer'] as String,
      produceId: json['ProduceID'] as String,
      reservedCode1: json['ReservedCode1'] as String,
      contentPropagator: json['ContentPropagator'] as String,
      propagateId: json['PropagateID'] as String,
      reservedCode2: json['ReservedCode2'] as String,
    );
  }

  static ResumeAigcMetadata? fromResume(ResumeData resume) =>
      resume.extensions.containsKey(extensionKey)
      ? ResumeAigcMetadata.fromJson(resume.extensions[extensionKey])
      : null;

  ResumeData attachTo(ResumeData resume) =>
      ResumeData.fromJson({...resume.toJson(), extensionKey: toJson()});
}
