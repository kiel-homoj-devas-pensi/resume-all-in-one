import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A bundled revision is identified by all its content, not just its label.
final class LegalBundle {
  LegalBundle.fromJson(Map<String, dynamic> value)
    : _json = jsonDecode(jsonEncode(value)) as Map<String, dynamic> {
    if (_json['schemaVersion'] != 1 ||
        _json['bundleId'] is! String ||
        (_json['bundleId'] as String).trim().isEmpty ||
        !{'draft', 'final', 'published'}.contains(_json['status']) ||
        _json['operator'] is! Map ||
        _json['documents'] is! List ||
        _json['pendingFields'] is! List) {
      throw const FormatException('协议资料格式无效');
    }
    documents = List.unmodifiable(
      (_json['documents'] as List).map(
        (item) =>
            LegalDocument.fromJson(Map<String, dynamic>.from(item as Map)),
      ),
    );
    pendingFields = List.unmodifiable(
      (_json['pendingFields'] as List).map(
        (item) =>
            LegalPendingField.fromJson(Map<String, dynamic>.from(item as Map)),
      ),
    );
    if (documents.length != 2 ||
        documents.map((e) => e.id).toSet().difference({
          'terms',
          'privacy',
        }).isNotEmpty ||
        documents.map((e) => e.id).toSet().length != 2) {
      throw const FormatException('协议与隐私政策必须同时提供');
    }
  }

  final Map<String, dynamic> _json;
  late final List<LegalDocument> documents;
  late final List<LegalPendingField> pendingFields;

  String get bundleId => _json['bundleId'] as String;
  String get status => _json['status'] as String;
  DateTime? get effectiveAt => _date(_json['effectiveAt']);
  DateTime? get publishedAt => _date(_json['publishedAt']);
  late final String contentHash = sha256
      .convert(utf8.encode(jsonEncode(_canonical(_json))))
      .toString();

  bool get isComplete {
    final operator = _json['operator'] as Map;
    return {'final', 'published'}.contains(status) &&
        pendingFields.isEmpty &&
        publishedAt != null &&
        effectiveAt != null &&
        !effectiveAt!.isBefore(publishedAt!) &&
        ['name', 'contactEmail'].every(
          (key) =>
              operator[key] is String &&
              (operator[key] as String).trim().isNotEmpty,
        ) &&
        !jsonEncode(_json).contains(RegExp(r'\{\{[^}]+\}\}'));
  }

  String get statusLabel => !isComplete
      ? '草案：待补充后生效'
      : status == 'final'
      ? '已定稿；当前使用规则随主动同意适用'
      : '已发布文本';

  String get publicationDateLabel => _beijingDate(publishedAt);
  String get effectiveDateLabel => _beijingDate(effectiveAt);

  Map<String, dynamic> toJson() =>
      jsonDecode(jsonEncode(_json)) as Map<String, dynamic>;

  String renderText(String source) =>
      source.replaceAllMapped(RegExp(r'\{\{([a-zA-Z0-9_.]+)\}\}'), (match) {
        final key = match[1]!;
        dynamic value = _json;
        for (final part in key.split('.')) {
          value = value is Map ? value[part] : null;
        }
        if (value is String && value.trim().isNotEmpty) return value;
        final labels = pendingFields.where((item) => item.key == key);
        return '________（待补：${labels.isEmpty ? key : labels.first.label}）';
      });
}

final class LegalDocument {
  LegalDocument.fromJson(Map<String, dynamic> value)
    : id = value['id'] as String,
      title = value['title'] as String,
      version = value['version'] as String,
      sections = List.unmodifiable(
        (value['sections'] as List).map(
          (item) =>
              LegalSection.fromJson(Map<String, dynamic>.from(item as Map)),
        ),
      ) {
    if (id.isEmpty ||
        title.trim().isEmpty ||
        version.trim().isEmpty ||
        sections.isEmpty) {
      throw const FormatException('协议正文不完整');
    }
  }
  final String id;
  final String title;
  final String version;
  final List<LegalSection> sections;

  String plainText(LegalBundle bundle) => [
    '$title 版本 $version',
    bundle.statusLabel,
    '${bundle.status == 'final' ? '计划公开公布' : '公布'}：${bundle.publicationDateLabel}（北京时间）',
    '${bundle.status == 'final' ? '计划公开生效' : '生效'}：${bundle.effectiveDateLabel}（北京时间）',
    for (final section in sections) ...[
      '',
      section.heading,
      for (final paragraph in section.paragraphs) bundle.renderText(paragraph),
    ],
  ].join('\n');
}

final class LegalSection {
  LegalSection.fromJson(Map<String, dynamic> value)
    : id = value['id'] as String,
      heading = value['heading'] as String,
      important = value['important'] as bool,
      paragraphs = List<String>.unmodifiable(
        (value['paragraphs'] as List).cast<String>(),
      ) {
    if (id.isEmpty ||
        heading.trim().isEmpty ||
        paragraphs.isEmpty ||
        paragraphs.any((p) => p.trim().isEmpty)) {
      throw const FormatException('协议章节不完整');
    }
  }
  final String id;
  final String heading;
  final bool important;
  final List<String> paragraphs;
}

final class LegalPendingField {
  LegalPendingField.fromJson(Map<String, dynamic> value)
    : key = value['key'] as String,
      label = value['label'] as String,
      reason = value['reason'] as String;
  final String key;
  final String label;
  final String reason;
}

enum LegalConsentAction { accepted, localOnly, withdrawn }

final class LegalConsentRecord {
  const LegalConsentRecord({
    required this.sequence,
    required this.action,
    required this.bundleHash,
    required this.recordedAtUtc,
    required this.suppressReminder,
    this.adultConfirmed = false,
  });

  factory LegalConsentRecord.fromJson(Map<String, dynamic> value) =>
      LegalConsentRecord(
        sequence: value['sequence'] as int,
        action: LegalConsentAction.values.byName(value['action'] as String),
        bundleHash: value['bundleHash'] as String,
        recordedAtUtc: DateTime.parse(value['recordedAtUtc'] as String).toUtc(),
        suppressReminder: value['suppressReminder'] as bool,
        // Earlier device records contain no age declaration. Never infer one.
        adultConfirmed: value['adultConfirmed'] as bool? ?? false,
      );
  final int sequence;
  final LegalConsentAction action;
  final String bundleHash;
  final DateTime recordedAtUtc;
  final bool suppressReminder;
  final bool adultConfirmed;

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'action': action.name,
    'bundleHash': bundleHash,
    'recordedAtUtc': recordedAtUtc.toUtc().toIso8601String(),
    'suppressReminder': suppressReminder,
    'adultConfirmed': adultConfirmed,
  };
}

final class LegalConsentEntry {
  LegalConsentEntry({required this.record, required this.bundle}) {
    if (record.sequence < 1 ||
        record.bundleHash != bundle.contentHash ||
        (record.action == LegalConsentAction.accepted && !bundle.isComplete)) {
      throw const FormatException('协议记录与正文不一致');
    }
  }
  factory LegalConsentEntry.fromJson(Map<String, dynamic> value) {
    if (value['schemaVersion'] != 1 || value.keys.length != 3) {
      throw const FormatException('协议记录版本无效');
    }
    return LegalConsentEntry(
      record: LegalConsentRecord.fromJson(
        Map<String, dynamic>.from(value['record'] as Map),
      ),
      bundle: LegalBundle.fromJson(
        Map<String, dynamic>.from(value['bundle'] as Map),
      ),
    );
  }
  final LegalConsentRecord record;
  final LegalBundle bundle;
  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'record': record.toJson(),
    'bundle': bundle.toJson(),
  };
}

DateTime? _date(dynamic value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

String _beijingDate(DateTime? value) {
  if (value == null) return '________（待补）';
  final date = value.toUtc().add(const Duration(hours: 8));
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}
