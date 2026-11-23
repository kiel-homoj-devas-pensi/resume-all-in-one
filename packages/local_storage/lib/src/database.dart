import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

part 'database.g.dart';

/// Drift 默认只保存 Unix 秒；这里保留领域时间戳的完整微秒精度。
final class _UtcDateTimeMicrosConverter extends TypeConverter<DateTime, int> {
  const _UtcDateTimeMicrosConverter();

  @override
  DateTime fromSql(int fromDb) {
    return DateTime.fromMicrosecondsSinceEpoch(fromDb, isUtc: true);
  }

  @override
  int toSql(DateTime value) => value.toUtc().microsecondsSinceEpoch;
}

@DataClassName('ResumeDocumentRow')
class ResumeDocuments extends Table {
  TextColumn get id => text().withLength(min: 1)();

  TextColumn get title => text().withLength(min: 1)();

  TextColumn get currentVersionId => text().nullable()();

  IntColumn get createdAt =>
      integer().map(const _UtcDateTimeMicrosConverter())();

  IntColumn get updatedAt =>
      integer().map(const _UtcDateTimeMicrosConverter())();

  TextColumn get metadataJson => text()();

  TextColumn get extensionsJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ResumeVersionRow')
@TableIndex(
  name: 'resume_versions_document_created',
  columns: {#documentId, #createdAt},
)
class ResumeVersions extends Table {
  TextColumn get id => text().withLength(min: 1)();

  TextColumn get documentId =>
      text().references(ResumeDocuments, #id, onDelete: KeyAction.cascade)();

  TextColumn get parentVersionId => text().nullable()();

  TextColumn get schemaVersion => text().withLength(min: 1)();

  TextColumn get contentJson => text()();

  TextColumn get source => text().withLength(min: 1)();

  IntColumn get createdAt =>
      integer().map(const _UtcDateTimeMicrosConverter())();

  TextColumn get extensionsJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('AppSettingRow')
class AppSettings extends Table {
  TextColumn get settingKey => text().withLength(min: 1)();

  BoolColumn get boolValue => boolean()();

  IntColumn get updatedAt =>
      integer().map(const _UtcDateTimeMicrosConverter())();

  @override
  Set<Column<Object>> get primaryKey => {settingKey};
}

@DataClassName('AgentRunRow')
@TableIndex(
  name: 'agent_runs_document_started',
  columns: {#documentId, #startedAt},
)
class AgentRuns extends Table {
  TextColumn get id => text().withLength(min: 1)();

  TextColumn get requestId => text().withLength(min: 1).unique()();

  TextColumn get documentId => text().withLength(min: 1)();

  TextColumn get resumeVersionId => text().withLength(min: 1)();

  TextColumn get status => text().withLength(min: 1)();

  TextColumn get routeStatus => text().withLength(min: 1)();

  IntColumn get startedAt =>
      integer().map(const _UtcDateTimeMicrosConverter())();

  IntColumn get finishedAt =>
      integer().map(const _UtcDateTimeMicrosConverter())();

  IntColumn get toolCallCount => integer().withDefault(const Constant(0))();

  TextColumn get errorCode => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ToolCallRow')
@TableIndex(name: 'tool_calls_run_started', columns: {#agentRunId, #startedAt})
class ToolCalls extends Table {
  TextColumn get id => text().withLength(min: 1)();

  TextColumn get agentRunId =>
      text().references(AgentRuns, #id, onDelete: KeyAction.cascade)();

  TextColumn get toolName => text().withLength(min: 1)();

  TextColumn get toolVersion => text().withLength(min: 1)();

  TextColumn get status => text().withLength(min: 1)();

  IntColumn get startedAt =>
      integer().map(const _UtcDateTimeMicrosConverter())();

  IntColumn get finishedAt =>
      integer().map(const _UtcDateTimeMicrosConverter())();

  BoolColumn get offline => boolean()();

  BoolColumn get replayed => boolean()();

  TextColumn get errorCode => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DriftDatabase(
  tables: [ResumeDocuments, ResumeVersions, AppSettings, AgentRuns, ToolCalls],
)
final class LocalStorageDatabase extends _$LocalStorageDatabase {
  LocalStorageDatabase(super.executor);

  factory LocalStorageDatabase.inMemory() {
    return LocalStorageDatabase(NativeDatabase.memory());
  }

  factory LocalStorageDatabase.openFile(File file) {
    return LocalStorageDatabase(NativeDatabase.createInBackground(file));
  }

  @override
  int get schemaVersion => 4;

  Future<void> _createRemoteReviewTables() async {
    await customStatement(
      'CREATE TABLE remote_review_records (record_id TEXT PRIMARY KEY, account_id TEXT NOT NULL, document_id TEXT, payload_json TEXT NOT NULL, expires_at INTEGER NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE remote_conversations (account_id TEXT NOT NULL, document_id TEXT NOT NULL, payload_json TEXT NOT NULL, expires_at INTEGER NOT NULL, PRIMARY KEY (account_id, document_id))',
    );
    // 确认凭据不随文档删除级联，防止旧候选在删除后重新创建简历。
    await customStatement(
      'CREATE TABLE remote_acceptance_receipts (record_id TEXT PRIMARY KEY, document_id TEXT NOT NULL, version_id TEXT NOT NULL)',
    );
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await migrator.createAll();
      await _createRemoteReviewTables();
      // 只有首次建库属于新安装。升级和清空后的缺键仍按旧行为关闭，
      // 不能把旧用户没有记录的选择推断为上传授权。
      await into(appSettings).insert(
        AppSettingsCompanion.insert(
          settingKey: 'network_enabled',
          boolValue: true,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    },
    onUpgrade: (migrator, from, to) async {
      if (from < 1) {
        await migrator.createAll();
        await _createRemoteReviewTables();
        return;
      }
      if (from < 2) {
        await migrator.createTable(appSettings);
      }
      if (from < 3) {
        await migrator.createTable(agentRuns);
        await migrator.createTable(toolCalls);
        // createTable 不会创建独立声明的 @TableIndex。
        await migrator.createIndex(agentRunsDocumentStarted);
        await migrator.createIndex(toolCallsRunStarted);
      }
      if (from < 4) await _createRemoteReviewTables();
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      // 旧开发库可能已升到 v4，却漏建了这两个审计索引。
      // 只补回已知缺项，不尝试修复未知的表或数据损坏。
      for (final index in [agentRunsDocumentStarted, toolCallsRunStarted]) {
        final statement = index.createStatementsByDialect[SqlDialect.sqlite]!;
        await customStatement(
          statement.replaceFirst(
            'CREATE INDEX ',
            'CREATE INDEX IF NOT EXISTS ',
          ),
        );
      }
    },
  );
}
