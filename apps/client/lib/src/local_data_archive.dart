import 'dart:convert';
import 'dart:typed_data';

import 'package:local_storage/local_storage.dart';
import 'package:resume_domain/resume_domain.dart';

const currentLocalDataExportFormatVersion = '0.1.0';
const localDataArchiveMaxBytes = 8 * 1024 * 1024;
const localDataArchiveMaxContainerDepth = localDataExportMaxJsonDepth;
// 每个 JSON 值（含容器）和每个对象键各计一项。
const localDataArchiveMaxNodes = localDataExportMaxJsonNodes;

final class LocalDataArchiveException implements Exception {
  const LocalDataArchiveException(this.message);

  final String message;

  @override
  String toString() => 'LocalDataArchiveException: $message';
}

final class LocalDataArchiveSummary {
  const LocalDataArchiveSummary({
    required this.documentCount,
    required this.versionCount,
    required this.settingCount,
    required this.agentRunCount,
    required this.toolCallCount,
  });

  final int documentCount;
  final int versionCount;
  final int settingCount;
  final int agentRunCount;
  final int toolCallCount;
}

final class LocalDataArchive {
  LocalDataArchive({
    required List<LocalResumeDataSnapshot> resumes,
    required this.summary,
  }) : resumes = List.unmodifiable(resumes);
  final List<LocalResumeDataSnapshot> resumes;
  final LocalDataArchiveSummary summary;
}

final class LocalDataArchiveCodec {
  const LocalDataArchiveCodec();

  String encode(LocalDataSnapshot snapshot, DateTime exportedAtUtc) {
    if (!exportedAtUtc.isUtc) {
      throw ArgumentError.value(exportedAtUtc, 'exportedAtUtc', '必须是 UTC 时间');
    }
    // 两处领域 toJson 会递归复制未知 JSON，先用迭代检查保护它们。
    for (final resume in snapshot.resumes) {
      _checkJsonTree(resume.document.metadata, parentDepth: 4);
      for (final version in resume.versions) {
        _checkJsonTree(version.content.unmapped, parentDepth: 6);
      }
    }
    final archive = <String, Object?>{
      'exportFormatVersion': currentLocalDataExportFormatVersion,
      'exportedAtUtc': exportedAtUtc.toIso8601String(),
      'storageSchemaVersion': snapshot.storageSchemaVersion,
      'resumes': snapshot.resumes
          .map(
            (resumeSnapshot) => {
              'document': resumeSnapshot.document.toJson(),
              'versions': resumeSnapshot.versions
                  .map((resumeVersion) => resumeVersion.toJson())
                  .toList(),
            },
          )
          .toList(),
      'settings': snapshot.settings
          .map(
            (settingSnapshot) => {
              'key': settingSnapshot.key,
              'value': settingSnapshot.value,
              'updatedAtUtc': settingSnapshot.updatedAtUtc.toIso8601String(),
            },
          )
          .toList(),
      'agentAudits': snapshot.agentAudits
          .map(
            (auditSnapshot) => {
              'run': _agentRunToJson(auditSnapshot.run),
              'toolCalls': auditSnapshot.toolCalls
                  .map(_toolCallToJson)
                  .toList(),
            },
          )
          .toList(),
    };
    _checkJsonTree(archive);
    final output = _BoundedArchiveByteSink(collect: true);
    final conversion = JsonUtf8Encoder('  ').startChunkedConversion(output);
    conversion.add(archive);
    conversion.close();
    return utf8.decode(output.takeBytes());
  }

  LocalDataArchiveSummary decode(String archiveText) =>
      parse(archiveText).summary;

  LocalDataArchive parse(String archiveText) {
    _checkArchiveText(archiveText);
    final Object? decodedArchive;
    try {
      decodedArchive = jsonDecode(archiveText);
    } on FormatException {
      throw const LocalDataArchiveException('导出文件不是有效 JSON');
    }
    try {
      final archive = _expectMap(decodedArchive, r'$');
      final exportFormatVersion = _expectString(
        archive['exportFormatVersion'],
        r'$/exportFormatVersion',
      );
      if (exportFormatVersion != currentLocalDataExportFormatVersion) {
        throw const LocalDataArchiveException('不支持的本地数据导出格式版本');
      }
      _expectUtcTime(archive['exportedAtUtc'], r'$/exportedAtUtc');
      final storageSchemaVersion = _expectInt(
        archive['storageSchemaVersion'],
        r'$/storageSchemaVersion',
      );
      if (storageSchemaVersion < 1 || storageSchemaVersion > 4) {
        throw const LocalDataArchiveException('不支持的本地存储 Schema 版本');
      }

      final documentIds = <String>{};
      final versionIds = <String>{};
      var versionCount = 0;
      final resumes = <LocalResumeDataSnapshot>[];
      final resumeEntries = _expectList(archive['resumes'], r'$/resumes');
      for (final indexedResume in resumeEntries.indexed) {
        final resumePath =
            r'$/resumes/'
            '${indexedResume.$1}';
        final resumeEntry = _expectMap(indexedResume.$2, resumePath);
        final resumeDocument = ResumeDocument.fromJson(
          _expectMap(resumeEntry['document'], '$resumePath/document'),
          '$resumePath/document',
        );
        _expectString(resumeDocument.id, '$resumePath/document/id');
        _expectString(resumeDocument.title, '$resumePath/document/title');
        _expectOptionalString(
          resumeDocument.currentVersionId,
          '$resumePath/document/currentVersionId',
        );
        if (resumeDocument.updatedAt.isBefore(resumeDocument.createdAt)) {
          throw const LocalDataArchiveException('文档更新时间早于创建时间');
        }
        if (!documentIds.add(resumeDocument.id)) {
          throw const LocalDataArchiveException('导出文件包含重复文档 ID');
        }
        final documentVersions = <String, ResumeVersion>{};
        final versionEntries = _expectList(
          resumeEntry['versions'],
          '$resumePath/versions',
        );
        for (final indexedVersion in versionEntries.indexed) {
          final versionPath = '$resumePath/versions/${indexedVersion.$1}';
          final resumeVersion = ResumeVersion.fromJson(
            _expectMap(indexedVersion.$2, versionPath),
            versionPath,
          );
          _expectString(resumeVersion.id, '$versionPath/id');
          _expectOptionalString(
            resumeVersion.parentVersionId,
            '$versionPath/parentVersionId',
          );
          final validation = const ResumeValidator().validate(
            resumeVersion.content,
          );
          if (!validation.isValid) throw ResumeValidationException(validation);
          if (resumeVersion.documentId != resumeDocument.id) {
            throw const LocalDataArchiveException('版本不属于所在文档');
          }
          if (!versionIds.add(resumeVersion.id)) {
            throw const LocalDataArchiveException('导出文件包含重复版本 ID');
          }
          documentVersions[resumeVersion.id] = resumeVersion;
          versionCount++;
        }
        final currentVersionId = resumeDocument.currentVersionId;
        if (currentVersionId != null &&
            !documentVersions.containsKey(currentVersionId)) {
          throw const LocalDataArchiveException('文档当前版本指针不在历史版本中');
        }
        _validateVersionParents(documentVersions);
        resumes.add(
          LocalResumeDataSnapshot(
            document: resumeDocument,
            versions: List.unmodifiable(documentVersions.values),
          ),
        );
      }

      final settingKeys = <String>{};
      final settingEntries = _expectList(archive['settings'], r'$/settings');
      for (final indexedSetting in settingEntries.indexed) {
        final settingPath =
            r'$/settings/'
            '${indexedSetting.$1}';
        final settingEntry = _expectMap(indexedSetting.$2, settingPath);
        final settingKey = _expectString(
          settingEntry['key'],
          '$settingPath/key',
        );
        if (!settingKeys.add(settingKey)) {
          throw const LocalDataArchiveException('导出文件包含重复设置 key');
        }
        _expectBool(settingEntry['value'], '$settingPath/value');
        _expectUtcTime(
          settingEntry['updatedAtUtc'],
          '$settingPath/updatedAtUtc',
        );
      }

      final agentRunIds = <String>{};
      final agentRequestIds = <String>{};
      final toolCallIds = <String>{};
      var toolCallCount = 0;
      final auditEntries = _expectList(
        archive['agentAudits'],
        r'$/agentAudits',
      );
      for (final indexedAudit in auditEntries.indexed) {
        final auditPath =
            r'$/agentAudits/'
            '${indexedAudit.$1}';
        final auditEntry = _expectMap(indexedAudit.$2, auditPath);
        final runEntry = _expectMap(auditEntry['run'], '$auditPath/run');
        final runId = _validateAgentRun(runEntry, '$auditPath/run');
        if (!agentRunIds.add(runId)) {
          throw const LocalDataArchiveException('导出文件包含重复 Agent run ID');
        }
        if (!agentRequestIds.add(
          _expectString(runEntry['requestId'], '$auditPath/run/requestId'),
        )) {
          throw const LocalDataArchiveException('导出文件包含重复 Agent request ID');
        }
        final toolCallEntries = _expectList(
          auditEntry['toolCalls'],
          '$auditPath/toolCalls',
        );
        final declaredToolCallCount = _expectInt(
          runEntry['toolCallCount'],
          '$auditPath/run/toolCallCount',
        );
        if (declaredToolCallCount != toolCallEntries.length) {
          throw const LocalDataArchiveException('Agent run 的工具计数不一致');
        }
        for (final indexedToolCall in toolCallEntries.indexed) {
          final toolCallPath = '$auditPath/toolCalls/${indexedToolCall.$1}';
          final toolCallEntry = _expectMap(indexedToolCall.$2, toolCallPath);
          final toolCallId = _validateToolCall(
            toolCallEntry,
            toolCallPath,
            runId,
          );
          if (!toolCallIds.add(toolCallId)) {
            throw const LocalDataArchiveException('导出文件包含重复工具调用 ID');
          }
          toolCallCount++;
        }
      }

      return LocalDataArchive(
        resumes: resumes,
        summary: LocalDataArchiveSummary(
          documentCount: resumeEntries.length,
          versionCount: versionCount,
          settingCount: settingEntries.length,
          agentRunCount: auditEntries.length,
          toolCallCount: toolCallCount,
        ),
      );
    } on LocalDataArchiveException {
      rethrow;
    } on SchemaFormatException {
      throw const LocalDataArchiveException('导出文件包含无效的简历数据');
    } on ResumeValidationException {
      throw const LocalDataArchiveException('导出文件中的简历未通过验证');
    } on Object {
      throw const LocalDataArchiveException('导出文件结构无效');
    }
  }
}

final class _BoundedArchiveByteSink implements Sink<List<int>> {
  _BoundedArchiveByteSink({required bool collect})
    : _bytes = collect ? BytesBuilder(copy: false) : null;

  final BytesBuilder? _bytes;
  int _length = 0;

  @override
  void add(List<int> bytes) {
    _length += bytes.length;
    if (_length > localDataArchiveMaxBytes) {
      throw const LocalDataArchiveException('档案超过 8 MiB 文件上限');
    }
    _bytes?.add(bytes);
  }

  Uint8List takeBytes() => _bytes!.takeBytes();

  @override
  void close() {}
}

void _checkArchiveText(String text) {
  // 先阻止巨型编码分配，随后精确检查多字节文字；不保留编码副本。
  if (text.length > localDataArchiveMaxBytes) {
    throw const LocalDataArchiveException('档案超过 8 MiB 文件上限');
  }
  final byteCounter = utf8.encoder.startChunkedConversion(
    _BoundedArchiveByteSink(collect: false),
  );
  for (var offset = 0; offset < text.length; offset += 4096) {
    final end = offset + 4096 < text.length ? offset + 4096 : text.length;
    byteCounter.addSlice(text, offset, end, false);
  }
  byteCounter.close();

  var depth = 0;
  var nodes = 0;
  var inString = false;
  var escaped = false;
  var inScalar = false;
  for (var index = 0; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (unit == 92) {
        escaped = true;
      } else if (unit == 34) {
        inString = false;
      }
      continue;
    }
    if (unit == 34) {
      inString = true;
      inScalar = false;
      nodes++;
    } else if (unit == 123 || unit == 91) {
      inScalar = false;
      depth++;
      nodes++;
      if (depth > localDataArchiveMaxContainerDepth) {
        throw const LocalDataArchiveException('档案 JSON 容器深度超过 64 层');
      }
    } else if (unit == 125 || unit == 93) {
      depth--;
      inScalar = false;
    } else if (unit == 44 || unit == 58 || unit <= 32) {
      inScalar = false;
    } else if (!inScalar) {
      inScalar = true;
      nodes++;
    }
    if (nodes > localDataArchiveMaxNodes) {
      throw const LocalDataArchiveException('档案 JSON 项数超过 200000');
    }
  }
  // 该扫描只检查资源边界，JSON语法仍交给标准解析器完整验证。
}

void _checkJsonTree(Object? value, {int parentDepth = 0}) {
  // 用迭代器栈而非展开全部子节点，额外栈空间只与深度有关。
  final pending = <(Iterator<Object?>, int)>[
    ([value].iterator, parentDepth),
  ];
  var nodes = 0;
  while (pending.isNotEmpty) {
    final (iterator, depth) = pending.last;
    if (!iterator.moveNext()) {
      pending.removeLast();
      continue;
    }
    nodes++;
    final item = iterator.current;
    if (item is Map<String, Object?> || item is List<Object?>) {
      final nextDepth = depth + 1;
      if (nextDepth > localDataArchiveMaxContainerDepth) {
        throw const LocalDataArchiveException('档案 JSON 容器深度超过 64 层');
      }
      if (item is Map<String, Object?>) {
        nodes += item.length; // JSON对象键同样计入词法项数。
        pending.add((item.values.iterator, nextDepth));
      } else {
        pending.add(((item as List<Object?>).iterator, nextDepth));
      }
    }
    if (nodes > localDataArchiveMaxNodes) {
      throw const LocalDataArchiveException('档案 JSON 项数超过 200000');
    }
  }
}

void _validateVersionParents(Map<String, ResumeVersion> versions) {
  for (final version in versions.values) {
    final parentId = version.parentVersionId;
    if (parentId != null && !versions.containsKey(parentId)) {
      throw const LocalDataArchiveException('父版本不在所在文档的历史版本中');
    }
  }
  final verifiedIds = <String>{};
  for (final version in versions.values) {
    final ancestorIds = <String>{};
    String? currentId = version.id;
    // 不依赖数组顺序，也不递归展开可能很长的历史链。
    while (currentId != null && !verifiedIds.contains(currentId)) {
      if (!ancestorIds.add(currentId)) {
        throw const LocalDataArchiveException('历史版本父链包含循环引用');
      }
      currentId = versions[currentId]!.parentVersionId;
    }
    verifiedIds.addAll(ancestorIds);
  }
}

Map<String, Object?> _agentRunToJson(AgentRunAuditRecord run) => {
  'id': run.id,
  'requestId': run.requestId,
  'documentId': run.documentId,
  'resumeVersionId': run.resumeVersionId,
  'status': run.status,
  'routeStatus': run.routeStatus,
  'startedAtUtc': run.startedAt.toUtc().toIso8601String(),
  'finishedAtUtc': run.finishedAt.toUtc().toIso8601String(),
  'toolCallCount': run.toolCallCount,
  'errorCode': run.errorCode,
};

Map<String, Object?> _toolCallToJson(ToolCallAuditRecord toolCall) => {
  'id': toolCall.id,
  'agentRunId': toolCall.agentRunId,
  'toolName': toolCall.toolName,
  'toolVersion': toolCall.toolVersion,
  'status': toolCall.status,
  'startedAtUtc': toolCall.startedAt.toUtc().toIso8601String(),
  'finishedAtUtc': toolCall.finishedAt.toUtc().toIso8601String(),
  'offline': toolCall.offline,
  'replayed': toolCall.replayed,
  'errorCode': toolCall.errorCode,
};

String _validateAgentRun(Map<String, Object?> run, String path) {
  final runId = _expectString(run['id'], '$path/id');
  _expectString(run['requestId'], '$path/requestId');
  _expectString(run['documentId'], '$path/documentId');
  _expectString(run['resumeVersionId'], '$path/resumeVersionId');
  _expectString(run['status'], '$path/status');
  _expectString(run['routeStatus'], '$path/routeStatus');
  final startedAt = _expectUtcTime(run['startedAtUtc'], '$path/startedAtUtc');
  final finishedAt = _expectUtcTime(
    run['finishedAtUtc'],
    '$path/finishedAtUtc',
  );
  if (finishedAt.isBefore(startedAt)) {
    throw const LocalDataArchiveException('Agent run 结束时间早于开始时间');
  }
  final toolCallCount = _expectInt(run['toolCallCount'], '$path/toolCallCount');
  if (toolCallCount < 0) {
    throw const LocalDataArchiveException('Agent run 工具计数不能小于 0');
  }
  _expectOptionalString(run['errorCode'], '$path/errorCode');
  return runId;
}

String _validateToolCall(
  Map<String, Object?> toolCall,
  String path,
  String expectedRunId,
) {
  final toolCallId = _expectString(toolCall['id'], '$path/id');
  final agentRunId = _expectString(toolCall['agentRunId'], '$path/agentRunId');
  if (agentRunId != expectedRunId) {
    throw const LocalDataArchiveException('工具调用不属于所在 Agent run');
  }
  _expectString(toolCall['toolName'], '$path/toolName');
  _expectString(toolCall['toolVersion'], '$path/toolVersion');
  _expectString(toolCall['status'], '$path/status');
  final startedAt = _expectUtcTime(
    toolCall['startedAtUtc'],
    '$path/startedAtUtc',
  );
  final finishedAt = _expectUtcTime(
    toolCall['finishedAtUtc'],
    '$path/finishedAtUtc',
  );
  if (finishedAt.isBefore(startedAt)) {
    throw const LocalDataArchiveException('工具调用结束时间早于开始时间');
  }
  _expectBool(toolCall['offline'], '$path/offline');
  _expectBool(toolCall['replayed'], '$path/replayed');
  _expectOptionalString(toolCall['errorCode'], '$path/errorCode');
  return toolCallId;
}

Map<String, Object?> _expectMap(Object? value, String path) {
  if (value is! Map<String, Object?>) {
    throw LocalDataArchiveException('$path 必须是对象');
  }
  return value;
}

List<Object?> _expectList(Object? value, String path) {
  if (value is! List<Object?>) {
    throw LocalDataArchiveException('$path 必须是数组');
  }
  return value;
}

String _expectString(Object? value, String path) {
  if (value is! String || value.trim().isEmpty) {
    throw LocalDataArchiveException('$path 必须是非空字符串');
  }
  return value;
}

String? _expectOptionalString(Object? value, String path) {
  if (value == null) {
    return null;
  }
  return _expectString(value, path);
}

int _expectInt(Object? value, String path) {
  if (value is! int) {
    throw LocalDataArchiveException('$path 必须是整数');
  }
  return value;
}

bool _expectBool(Object? value, String path) {
  if (value is! bool) {
    throw LocalDataArchiveException('$path 必须是布尔值');
  }
  return value;
}

DateTime _expectUtcTime(Object? value, String path) {
  final timestamp = _expectString(value, path);
  final components = RegExp(
    r'^([+-]?\d{4,6})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(timestamp);
  if (components == null) {
    throw LocalDataArchiveException('$path 必须是有效 UTC 时间');
  }
  final DateTime parsedTimestamp;
  try {
    parsedTimestamp = DateTime.parse(timestamp);
  } on FormatException {
    throw LocalDataArchiveException('$path 必须是有效时间');
  }
  if (!parsedTimestamp.isUtc) {
    throw LocalDataArchiveException('$path 必须是 UTC 时间');
  }
  final calendar = List<int>.generate(
    6,
    (index) => int.parse(components.group(index + 1)!),
  );
  final normalized = DateTime.utc(
    calendar[0],
    calendar[1],
    calendar[2],
    calendar[3],
    calendar[4],
    calendar[5],
  );
  final normalizedCalendar = [
    normalized.year,
    normalized.month,
    normalized.day,
    normalized.hour,
    normalized.minute,
    normalized.second,
  ];
  for (var index = 0; index < calendar.length; index++) {
    if (calendar[index] != normalizedCalendar[index]) {
      throw LocalDataArchiveException('$path 包含无效日期或时刻');
    }
  }
  final zone = components.group(7)!;
  if (zone != 'Z' &&
      (int.parse(zone.substring(1, 3)) >= 24 ||
          int.parse(zone.substring(4, 6)) >= 60)) {
    throw LocalDataArchiveException('$path 包含无效时区偏移');
  }
  return parsedTimestamp;
}
