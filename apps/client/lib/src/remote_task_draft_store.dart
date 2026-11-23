import 'dart:convert';
import 'dart:io';

/// Local task material only. Authentication and new sending consent are excluded.
final class RemoteTaskDraft {
  RemoteTaskDraft({
    required this.owner,
    required this.id,
    required this.kind,
    required this.createdAtUtc,
    required this.expiresAtUtc,
    required Map<String, Object?> material,
    this.documentId,
    this.baseVersionId,
    this.clientRequestId,
    this.submittedPersonalDataShared = false,
  }) : material = Map.unmodifiable(material) {
    if (owner.isEmpty ||
        owner.length > 128 ||
        id.isEmpty ||
        id.length > 128 ||
        !{'compose', 'optimize'}.contains(kind) ||
        !expiresAtUtc.isAfter(createdAtUtc) ||
        expiresAtUtc.difference(createdAtUtc) > const Duration(days: 7) ||
        (kind == 'compose' && (documentId != null || baseVersionId != null)) ||
        (kind == 'optimize' && (documentId == null || baseVersionId == null)) ||
        material.keys.any(
          (key) => !const {
            'documentTitle',
            'sourceText',
            'profileDocument',
            'naturalLanguageInput',
            'targetJobTitle',
            'jobDescription',
            'userInstruction',
          }.contains(key),
        ) ||
        utf8.encode(jsonEncode(material)).length > 262144) {
      throw const FormatException('未完成任务记录无效');
    }
  }

  final String owner;
  final String id;
  final String kind;
  final String? documentId;
  final String? baseVersionId;
  final String? clientRequestId;
  // Historical scope for retrieving the original result, never a new consent.
  final bool submittedPersonalDataShared;
  final DateTime createdAtUtc;
  final DateTime expiresAtUtc;
  final Map<String, Object?> material;

  Map<String, Object?> toJson() => {
    'owner': owner,
    'id': id,
    'kind': kind,
    'documentId': documentId,
    'baseVersionId': baseVersionId,
    'clientRequestId': clientRequestId,
    'submittedPersonalDataShared': submittedPersonalDataShared,
    'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
    'expiresAtUtc': expiresAtUtc.toUtc().toIso8601String(),
    'material': material,
  };

  factory RemoteTaskDraft.fromJson(Map<String, dynamic> value) {
    if (value.keys.toSet().difference(const {
      'owner',
      'id',
      'kind',
      'documentId',
      'baseVersionId',
      'clientRequestId',
      'submittedPersonalDataShared',
      'createdAtUtc',
      'expiresAtUtc',
      'material',
    }).isNotEmpty) {
      throw const FormatException('未知任务字段');
    }
    return RemoteTaskDraft(
      owner: value['owner'] as String,
      id: value['id'] as String,
      kind: value['kind'] as String,
      documentId: value['documentId'] as String?,
      baseVersionId: value['baseVersionId'] as String?,
      clientRequestId: value['clientRequestId'] as String?,
      submittedPersonalDataShared: value['submittedPersonalDataShared'] as bool,
      createdAtUtc: DateTime.parse(value['createdAtUtc'] as String).toUtc(),
      expiresAtUtc: DateTime.parse(value['expiresAtUtc'] as String).toUtc(),
      material: Map<String, Object?>.from(value['material'] as Map),
    );
  }
}

/// Private app storage, capped at 20 tasks and 1 MiB; excluded from resume export.
final class RemoteTaskDraftStore {
  RemoteTaskDraftStore({
    Future<Directory> Function()? rootDirectory,
    DateTime Function()? clock,
  }) : _root = rootDirectory,
       _clock = clock ?? (() => DateTime.now().toUtc());
  final Future<Directory> Function()? _root;
  final DateTime Function() _clock;
  List<RemoteTaskDraft>? _records;
  Future<void> _writes = Future.value();

  Future<File?> _file() async => _root == null
      ? null
      : File(
          '${(await _root()).path}${Platform.pathSeparator}ai_task_drafts_v1.json',
        );

  Future<List<RemoteTaskDraft>> _all() async {
    if (_records != null) return _records!;
    final file = await _file();
    if (file == null || !await file.exists()) return _records = [];
    if (await file.length() > 1048576) throw const FormatException('任务记录过大');
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (json['schemaVersion'] != 1 || json.keys.length != 2) {
      throw const FormatException('未知任务记录版本');
    }
    final records = (json['tasks'] as List)
        .map((item) => RemoteTaskDraft.fromJson(item as Map<String, dynamic>))
        .toList();
    if (records.length > 20 ||
        records.map((e) => '${e.owner}:${e.id}').toSet().length !=
            records.length) {
      throw const FormatException('任务记录重复');
    }
    return _records = records;
  }

  Future<List<RemoteTaskDraft>> read(String owner) async {
    await _writes;
    if ((await _all()).any((e) => !e.expiresAtUtc.isAfter(_clock().toUtc()))) {
      await _mutate((_) {});
    }
    return List.unmodifiable((await _all()).where((e) => e.owner == owner));
  }

  Future<void> save(RemoteTaskDraft draft) => _mutate((rows) {
    rows.removeWhere((e) => e.owner == draft.owner && e.id == draft.id);
    rows.add(draft);
  });
  Future<void> remove(String owner, String id) => _mutate(
    (rows) => rows.removeWhere((e) => e.owner == owner && e.id == id),
  );

  Future<void> clear() {
    final write = _writes.then((_) async {
      // Clearing remains possible even when a prior file cannot be decoded.
      await _persist(const []);
      _records = [];
    });
    _writes = write.then((_) {}, onError: (Object e, StackTrace s) {});
    return write;
  }

  Future<void> _persist(List<RemoteTaskDraft> rows) async {
    final text = jsonEncode({
      'schemaVersion': 1,
      'tasks': rows.map((e) => e.toJson()).toList(),
    });
    if (utf8.encode(text).length > 1048576) {
      throw const FormatException('任务材料过大');
    }
    final file = await _file();
    if (file != null) {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
    }
  }

  Future<void> _mutate(void Function(List<RemoteTaskDraft>) action) {
    final write = _writes.then((_) async {
      final next = [...await _all()]
        ..removeWhere((e) => !e.expiresAtUtc.isAfter(_clock().toUtc()));
      action(next);
      if (next.length > 20) throw const FormatException('请先处理未完成任务');
      await _persist(next);
      _records = next;
    });
    _writes = write.then((_) {}, onError: (Object e, StackTrace s) {});
    return write;
  }
}
