import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:resume_domain/resume_domain.dart';

import 'database.dart';
import 'drift_agent_audit_repository.dart';
import 'drift_resume_repository.dart';

const localDataExportMaxRows = 10000;
const localDataExportMaxRawBytes = 4 * 1024 * 1024;
const localDataExportMaxJsonDepth = 64;
const localDataExportMaxJsonNodes = 200000;

final class LocalDataExportLimitException implements Exception {
  const LocalDataExportLimitException(this.message);
  final String message;

  @override
  String toString() => 'LocalDataExportLimitException: $message';
}

final class LocalResumeDataSnapshot {
  LocalResumeDataSnapshot({
    required this.document,
    required List<ResumeVersion> versions,
  }) : versions = List<ResumeVersion>.unmodifiable(versions);

  final ResumeDocument document;
  final List<ResumeVersion> versions;
}

final class LocalBooleanSettingSnapshot {
  const LocalBooleanSettingSnapshot({
    required this.key,
    required this.value,
    required this.updatedAtUtc,
  });

  final String key;
  final bool value;
  final DateTime updatedAtUtc;
}

final class LocalAgentAuditSnapshot {
  LocalAgentAuditSnapshot({
    required this.run,
    required List<ToolCallAuditRecord> toolCalls,
  }) : toolCalls = List<ToolCallAuditRecord>.unmodifiable(toolCalls);

  final AgentRunAuditRecord run;
  final List<ToolCallAuditRecord> toolCalls;
}

final class LocalDataSnapshot {
  LocalDataSnapshot({
    required this.storageSchemaVersion,
    required List<LocalResumeDataSnapshot> resumes,
    required List<LocalBooleanSettingSnapshot> settings,
    required List<LocalAgentAuditSnapshot> agentAudits,
  }) : resumes = List<LocalResumeDataSnapshot>.unmodifiable(resumes),
       settings = List<LocalBooleanSettingSnapshot>.unmodifiable(settings),
       agentAudits = List<LocalAgentAuditSnapshot>.unmodifiable(agentAudits);

  final int storageSchemaVersion;
  final List<LocalResumeDataSnapshot> resumes;
  final List<LocalBooleanSettingSnapshot> settings;
  final List<LocalAgentAuditSnapshot> agentAudits;
}

final class LocalDataClearResult {
  const LocalDataClearResult({
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

final class LocalDataRestoreValidationException implements Exception {
  const LocalDataRestoreValidationException(this.message);

  final String message;

  @override
  String toString() => 'LocalDataRestoreValidationException: $message';
}

/// 任何文档或版本身份冲突都拒绝整份恢复，不覆盖或重映射身份。
final class LocalDataRestoreConflict implements Exception {
  const LocalDataRestoreConflict();

  @override
  String toString() => 'LocalDataRestoreConflict: 目标库已存在档案中的身份';
}

abstract interface class LocalDataRepository {
  Future<LocalDataSnapshot> readSnapshot();

  /// 在同一读事务先检查资源规模，超限时不载入正文或产生部分档案。
  Future<LocalDataSnapshot> readExportSnapshot();

  Future<void> restoreResumes(List<LocalResumeDataSnapshot> resumes);

  Future<LocalDataClearResult> clearAll();
}

final class DriftLocalDataRepository implements LocalDataRepository {
  const DriftLocalDataRepository(this._database);

  final LocalStorageDatabase _database;

  @override
  Future<void> restoreResumes(List<LocalResumeDataSnapshot> resumes) async {
    // 固定调用者传入的集合；领域对象已不可变，后续 await 不受列表修改影响。
    final snapshots = List<LocalResumeDataSnapshot>.unmodifiable(resumes);
    _validateRestore(snapshots);

    await _database.transaction(() async {
      // 在实际写入的同一事务重新复核身份，不能依赖预览时的库状态。
      for (final snapshot in snapshots) {
        final document =
            await (_database.select(_database.resumeDocuments)
                  ..where((table) => table.id.equals(snapshot.document.id)))
                .getSingleOrNull();
        if (document != null) throw const LocalDataRestoreConflict();
        for (final version in snapshot.versions) {
          final existing = await (_database.select(
            _database.resumeVersions,
          )..where((table) => table.id.equals(version.id))).getSingleOrNull();
          if (existing != null) throw const LocalDataRestoreConflict();
        }
      }

      for (final snapshot in snapshots) {
        final document = snapshot.document;
        await _database
            .into(_database.resumeDocuments)
            .insert(
              ResumeDocumentsCompanion.insert(
                id: document.id,
                title: document.title,
                createdAt: document.createdAt.toUtc(),
                updatedAt: document.updatedAt.toUtc(),
                metadataJson: jsonEncode(document.metadata),
                extensionsJson: jsonEncode(document.extensions),
              ),
            );
        for (final version in snapshot.versions) {
          await _database
              .into(_database.resumeVersions)
              .insert(
                ResumeVersionsCompanion.insert(
                  id: version.id,
                  documentId: version.documentId,
                  parentVersionId: Value(version.parentVersionId),
                  schemaVersion: version.schemaVersion,
                  contentJson: jsonEncode(version.content.toJson()),
                  source: version.source.name,
                  createdAt: version.createdAt.toUtc(),
                  extensionsJson: jsonEncode(version.extensions),
                ),
              );
        }
        // 只在完整历史已插入后恢复原指针；这一步失败也回滚所有文档。
        final updated =
            await (_database.update(
              _database.resumeDocuments,
            )..where((table) => table.id.equals(document.id))).write(
              ResumeDocumentsCompanion(
                currentVersionId: Value(document.currentVersionId),
              ),
            );
        if (updated != 1) throw StateError('档案恢复的文档更新数量异常');
      }
    });
  }

  void _validateRestore(List<LocalResumeDataSnapshot> snapshots) {
    final documentIds = <String>{};
    final versionIds = <String>{};
    for (final snapshot in snapshots) {
      final document = snapshot.document;
      if (document.id.trim().isEmpty || document.title.trim().isEmpty) {
        throw const LocalDataRestoreValidationException('文档身份或标题为空');
      }
      if (!documentIds.add(document.id)) {
        throw const LocalDataRestoreValidationException('档案包含重复文档身份');
      }
      if (document.updatedAt.isBefore(document.createdAt)) {
        throw const LocalDataRestoreValidationException('文档更新时间早于创建时间');
      }
      final versions = <String, ResumeVersion>{};
      for (final version in snapshot.versions) {
        if (version.id.trim().isEmpty || version.documentId != document.id) {
          throw const LocalDataRestoreValidationException('版本身份或文档归属无效');
        }
        if (!versionIds.add(version.id)) {
          throw const LocalDataRestoreValidationException('档案包含重复版本身份');
        }
        if (version.schemaVersion != currentResumeSchemaVersion ||
            !const ResumeValidator().validate(version.content).isValid) {
          throw const LocalDataRestoreValidationException('档案中的简历未通过验证');
        }
        versions[version.id] = version;
      }
      final currentId = document.currentVersionId;
      if (currentId != null && !versions.containsKey(currentId)) {
        throw const LocalDataRestoreValidationException('当前指针不在文档历史中');
      }
      for (final version in versions.values) {
        final parentId = version.parentVersionId;
        if (parentId != null && !versions.containsKey(parentId)) {
          throw const LocalDataRestoreValidationException('父版本不在同一文档历史中');
        }
      }
      final verifiedIds = <String>{};
      for (final version in versions.values) {
        final ancestorIds = <String>{};
        String? ancestorId = version.id;
        // 迭代检查乱序、多个根和长链，避免递归及重复遍历已验证的链。
        while (ancestorId != null && !verifiedIds.contains(ancestorId)) {
          if (!ancestorIds.add(ancestorId)) {
            throw const LocalDataRestoreValidationException('历史父链包含循环');
          }
          ancestorId = versions[ancestorId]!.parentVersionId;
        }
        verifiedIds.addAll(ancestorIds);
      }
    }
  }

  @override
  Future<LocalDataSnapshot> readSnapshot() => _readSnapshot(forExport: false);

  @override
  Future<LocalDataSnapshot> readExportSnapshot() =>
      _readSnapshot(forExport: true);

  Future<void> _checkExportSize() async {
    // 只汇总档案实际包含的五表；远程缓存与收据不属于档案。
    // BLOB length 是 SQLite UTF-8 字节数，不能用字符 length 估算中文。
    const textColumns = {
      'resume_documents': [
        'id',
        'title',
        'current_version_id',
        'metadata_json',
        'extensions_json',
      ],
      'resume_versions': [
        'id',
        'document_id',
        'parent_version_id',
        'schema_version',
        'content_json',
        'source',
        'extensions_json',
      ],
      'app_settings': ['setting_key'],
      'agent_runs': [
        'id',
        'request_id',
        'document_id',
        'resume_version_id',
        'status',
        'route_status',
        'error_code',
      ],
      'tool_calls': [
        'id',
        'agent_run_id',
        'tool_name',
        'tool_version',
        'status',
        'error_code',
      ],
    };
    var rows = 0;
    var rawBytes = 0;
    for (final entry in textColumns.entries) {
      final byteExpression = entry.value
          .map((column) => 'COALESCE(length(CAST($column AS BLOB)), 0)')
          .join(' + ');
      final result = await _database
          .customSelect(
            'SELECT COUNT(*) AS row_count, '
            'COALESCE(SUM($byteExpression), 0) AS raw_bytes FROM ${entry.key}',
          )
          .getSingle();
      rows += result.read<int>('row_count');
      rawBytes += result.read<int>('raw_bytes');
      if (rows > localDataExportMaxRows) {
        throw const LocalDataExportLimitException('本地数据超过档案导出的 10000 行上限');
      }
      if (rawBytes > localDataExportMaxRawBytes) {
        throw const LocalDataExportLimitException('本地数据超过档案导出的 4 MiB 原始文本上限');
      }
    }
  }

  Future<void> _checkExportJsonStructure() async {
    // 在领域 fromJson/deepFreeze 的递归处理之前检查持久化 JSON。
    // 前面的 SQL 字节限制已将本轮载入原始文本限定为 4 MiB。
    const jsonColumns = {
      'resume_documents': ['metadata_json', 'extensions_json'],
      'resume_versions': ['content_json', 'extensions_json'],
    };
    var nodes = 0;
    for (final entry in jsonColumns.entries) {
      final rows = await _database
          .customSelect('SELECT ${entry.value.join(', ')} FROM ${entry.key}')
          .get();
      for (final row in rows) {
        for (final column in entry.value) {
          var depth = 0;
          var inString = false;
          var escaped = false;
          var inScalar = false;
          final text = row.read<String>(column);
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
              depth++;
              inScalar = false;
              nodes++;
              if (depth > localDataExportMaxJsonDepth) {
                throw const LocalDataExportLimitException(
                  '本地 JSON 容器深度超过 64 层',
                );
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
            if (nodes > localDataExportMaxJsonNodes) {
              throw const LocalDataExportLimitException('本地 JSON 项数超过 200000');
            }
          }
        }
      }
    }
  }

  Future<LocalDataSnapshot> _readSnapshot({required bool forExport}) {
    return _database.transaction(() async {
      if (forExport) {
        await _checkExportSize();
        await _checkExportJsonStructure();
      }
      final resumeRepository = DriftResumeRepository(_database);
      final auditRepository = DriftAgentAuditRepository(_database);
      final resumeDocuments = await resumeRepository.listDocuments();
      final resumeSnapshots = <LocalResumeDataSnapshot>[];
      for (final resumeDocument in resumeDocuments) {
        resumeSnapshots.add(
          LocalResumeDataSnapshot(
            document: resumeDocument,
            versions: await resumeRepository.listVersions(resumeDocument.id),
          ),
        );
      }

      final settingRows = await (_database.select(
        _database.appSettings,
      )..orderBy([(setting) => OrderingTerm.asc(setting.settingKey)])).get();
      final settingSnapshots = settingRows
          .map(
            (settingRow) => LocalBooleanSettingSnapshot(
              key: settingRow.settingKey,
              value: settingRow.boolValue,
              updatedAtUtc: settingRow.updatedAt.toUtc(),
            ),
          )
          .toList(growable: false);

      final agentAuditSnapshots = <LocalAgentAuditSnapshot>[];
      for (final agentRun in await auditRepository.listRuns()) {
        agentAuditSnapshots.add(
          LocalAgentAuditSnapshot(
            run: agentRun,
            toolCalls: await auditRepository.listToolCalls(agentRun.id),
          ),
        );
      }

      return LocalDataSnapshot(
        storageSchemaVersion: _database.schemaVersion,
        resumes: resumeSnapshots,
        settings: settingSnapshots,
        agentAudits: agentAuditSnapshots,
      );
    });
  }

  @override
  Future<LocalDataClearResult> clearAll() {
    return _database.transaction(() async {
      // 先删子表再删父表，让删除数量可核对，也不依赖级联行为隐藏实际结果。
      await _database.customStatement('DELETE FROM remote_review_records');
      await _database.customStatement('DELETE FROM remote_conversations');
      await _database.customStatement('DELETE FROM remote_acceptance_receipts');
      final deletedToolCalls = await _database.delete(_database.toolCalls).go();
      final deletedAgentRuns = await _database.delete(_database.agentRuns).go();
      final deletedVersions = await _database
          .delete(_database.resumeVersions)
          .go();
      final deletedDocuments = await _database
          .delete(_database.resumeDocuments)
          .go();
      final deletedSettings = await _database
          .delete(_database.appSettings)
          .go();
      return LocalDataClearResult(
        documentCount: deletedDocuments,
        versionCount: deletedVersions,
        settingCount: deletedSettings,
        agentRunCount: deletedAgentRuns,
        toolCallCount: deletedToolCalls,
      );
    });
  }
}
