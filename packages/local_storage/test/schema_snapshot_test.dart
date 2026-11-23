import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';

// Instantiate only frozen DDL. No current table definitions are used to create
// the expected schema or the historical database being migrated.
final class _SnapshotDatabase extends GeneratedDatabase {
  _SnapshotDatabase(super.executor, this.schemaVersion, this.statements);

  @override
  final int schemaVersion;

  final List<String> statements;

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final statement in statements) {
        await customStatement(statement);
      }
    },
    beforeOpen: (_) => customStatement('PRAGMA foreign_keys = ON'),
  );
}

List<String> _historicalStatements(int version) {
  final snapshot =
      jsonDecode(
            File(
              'drift_schemas/drift_schema_v$version.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final entities = snapshot['fixed_sql'] as List<Object?>;
  final statements = <String>[];
  for (final entity in entities) {
    final alternatives =
        (entity as Map<String, Object?>)['sql'] as List<Object?>;
    final sqlite = alternatives.cast<Map<String, Object?>>().singleWhere(
      (alternative) => alternative['dialect'] == 'sqlite',
    );
    statements.add(sqlite['sql'] as String);
  }
  return statements;
}

List<String> _currentStatements() => File('drift_schemas/sqlite_schema_v4.sql')
    .readAsStringSync()
    .replaceAll(RegExp(r'^--[^\r\n]*', multiLine: true), '')
    .split(';')
    .map((statement) => statement.trim())
    .where((statement) => statement.isNotEmpty)
    .toList();

String _canonicalDdl(String statement) => statement
    .replaceAll('IF NOT EXISTS ', '')
    .replaceAll('"', '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

Future<List<Map<String, Object?>>> _rows(
  GeneratedDatabase database,
  String statement,
) async => [
  for (final row in await database.customSelect(statement).get()) row.data,
];

Future<Map<String, Object?>> _structure(GeneratedDatabase database) async {
  final entities = await _rows(
    database,
    "SELECT type, name, tbl_name, sql FROM sqlite_schema "
    "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
  );
  final tableNames = [
    for (final entity in entities)
      if (entity['type'] == 'table') entity['name'] as String,
  ];
  final indexNames = [
    for (final entity in entities)
      if (entity['type'] == 'index') entity['name'] as String,
  ];
  return {
    'entities': [
      for (final entity in entities)
        {...entity, 'sql': _canonicalDdl(entity['sql'] as String)},
    ],
    'columns': {
      for (final name in tableNames)
        name: await _rows(database, 'PRAGMA table_info("$name")'),
    },
    'foreignKeys': {
      for (final name in tableNames)
        name: await _rows(database, 'PRAGMA foreign_key_list("$name")'),
    },
    'indexes': {
      for (final name in tableNames)
        name: await _rows(database, 'PRAGMA index_list("$name")'),
    },
    'indexColumns': {
      for (final name in indexNames)
        name: await _rows(database, 'PRAGMA index_xinfo("$name")'),
    },
    'userVersion': await _rows(database, 'PRAGMA user_version'),
    'foreignKeysEnabled': await _rows(database, 'PRAGMA foreign_keys'),
  };
}

Future<Map<String, Object?>> _expectedStructure() async {
  final snapshot = _SnapshotDatabase(
    NativeDatabase.memory(),
    4,
    _currentStatements(),
  );
  try {
    return await _structure(snapshot);
  } finally {
    await snapshot.close();
  }
}

final _createdAt = DateTime.utc(2026, 10, 12, 6, 0, 0, 123, 456);
final _updatedAt = _createdAt.add(const Duration(microseconds: 7));

ResumeData _content(int version) => ResumeData(
  profile: ResumeProfile(
    id: 'synthetic-profile',
    fullName: '合成迁移用户 $version',
    headline: '工程师',
    email: 'synthetic@example.com',
    phone: '13800000000',
    location: '上海',
    extensions: const {
      'futureProfile': {'preserved': true},
    },
  ),
  extensions: const {
    'futureRoot': ['原值', 7],
  },
);

Future<void> _seedHistorical(_SnapshotDatabase database, int version) async {
  await database.customStatement(
    'INSERT INTO resume_documents '
    '(id, title, current_version_id, created_at, updated_at, '
    'metadata_json, extensions_json) VALUES (?, ?, ?, ?, ?, ?, ?)',
    [
      'synthetic-document',
      '合成迁移简历',
      'synthetic-version-2',
      _createdAt.microsecondsSinceEpoch,
      _updatedAt.microsecondsSinceEpoch,
      jsonEncode({
        'tags': ['保留'],
        'futureMetadata': 9,
      }),
      jsonEncode({
        'futureDocument': {'preserved': true},
      }),
    ],
  );
  for (var index = 1; index <= 2; index++) {
    await database.customStatement(
      'INSERT INTO resume_versions '
      '(id, document_id, parent_version_id, schema_version, '
      'content_json, source, created_at, extensions_json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        'synthetic-version-$index',
        'synthetic-document',
        index == 1 ? null : 'synthetic-version-1',
        currentResumeSchemaVersion,
        const CanonicalResumeCodec().encode(_content(index)),
        index == 1 ? 'created' : 'edited',
        _createdAt.add(Duration(microseconds: index)).microsecondsSinceEpoch,
        jsonEncode({'futureVersion': index}),
      ],
    );
  }
  if (version >= 2) {
    await database.customStatement(
      'INSERT INTO app_settings (setting_key, bool_value, updated_at) '
      'VALUES (?, ?, ?)',
      ['network_enabled', 0, _updatedAt.microsecondsSinceEpoch],
    );
  }
}

void main() {
  test('完整SQLite v4快照与首次建库一致，包括运行期DDL和约束', () async {
    final database = LocalStorageDatabase.inMemory();
    try {
      final actual = await _structure(database);
      expect(actual, await _expectedStructure());
      final entities = actual['entities'] as List<Object?>;
      expect(
        entities.where(
          (entity) => (entity as Map<String, Object?>)['type'] == 'table',
        ),
        hasLength(8),
      );
      expect(
        entities.where(
          (entity) => (entity as Map<String, Object?>)['type'] == 'index',
        ),
        hasLength(3),
      );
      expect(actual['userVersion'], [
        {'user_version': 4},
      ]);
    } finally {
      await database.close();
    }
  });

  for (var historicalVersion = 1; historicalVersion <= 4; historicalVersion++) {
    final description = historicalVersion == 4
        ? '已升v4但缺两审计索引的开发库重开补齐且保留数据'
        : '固定v$historicalVersion快照建库后真实升级保留全部历史与微秒';
    test(description, () async {
      final directory = await Directory.systemTemp.createTemp(
        'synthetic-schema-migration-',
      );
      final file = File(
        '${directory.path}${Platform.pathSeparator}resume.sqlite',
      );
      try {
        final historical = _SnapshotDatabase(
          NativeDatabase(file),
          historicalVersion,
          historicalVersion == 4
              ? _currentStatements().where((statement) {
                  final ddl = _canonicalDdl(statement);
                  return !ddl.startsWith(
                        'CREATE INDEX agent_runs_document_started ',
                      ) &&
                      !ddl.startsWith('CREATE INDEX tool_calls_run_started ');
                }).toList()
              : _historicalStatements(historicalVersion),
        );
        late List<Map<String, Object?>> documentRows;
        late List<Map<String, Object?>> versionRows;
        late List<Map<String, Object?>> settingRows;
        try {
          await _seedHistorical(historical, historicalVersion);
          expect(await _rows(historical, 'PRAGMA user_version'), [
            {'user_version': historicalVersion},
          ]);
          if (historicalVersion == 4) {
            expect(
              await _rows(
                historical,
                "SELECT name FROM sqlite_schema WHERE type = 'index' "
                "AND name IN ('agent_runs_document_started', "
                "'tool_calls_run_started')",
              ),
              isEmpty,
            );
          }
          documentRows = await _rows(
            historical,
            'SELECT * FROM resume_documents',
          );
          versionRows = await _rows(
            historical,
            'SELECT * FROM resume_versions ORDER BY id',
          );
          settingRows = historicalVersion >= 2
              ? await _rows(historical, 'SELECT * FROM app_settings')
              : [];
        } finally {
          await historical.close();
        }

        final upgraded = LocalStorageDatabase.openFile(file);
        try {
          expect(await _structure(upgraded), await _expectedStructure());
          expect(
            await _rows(upgraded, 'SELECT * FROM resume_documents'),
            documentRows,
          );
          expect(
            await _rows(upgraded, 'SELECT * FROM resume_versions ORDER BY id'),
            versionRows,
          );
          expect(
            await _rows(upgraded, 'SELECT * FROM app_settings'),
            settingRows,
          );
          final repository = DriftResumeRepository(upgraded);
          final document = (await repository.findDocument(
            'synthetic-document',
          ))!;
          expect(document.createdAt, _createdAt);
          expect(document.updatedAt, _updatedAt);
          expect(document.currentVersionId, 'synthetic-version-2');
          expect(document.metadata['futureMetadata'], 9);
          expect(document.extensions['futureDocument'], {'preserved': true});
          final versions = await repository.listVersions(document.id);
          expect(versions.map((value) => value.id), [
            'synthetic-version-2',
            'synthetic-version-1',
          ]);
          for (var index = 1; index <= 2; index++) {
            final restored = (await repository.findVersion(
              'synthetic-version-$index',
            ))!;
            expect(
              restored.createdAt,
              _createdAt.add(Duration(microseconds: index)),
            );
            expect(restored.content.toJson(), _content(index).toJson());
            expect(restored.extensions['futureVersion'], index);
            expect(
              restored.parentVersionId,
              index == 1 ? null : 'synthetic-version-1',
            );
          }
          expect(
            await DriftAppSettingsRepository(upgraded).getNetworkEnabled(),
            isFalse,
          );
        } finally {
          await upgraded.close();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    });
  }
}
