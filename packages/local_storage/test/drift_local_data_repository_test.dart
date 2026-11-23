import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:local_storage/local_storage.dart';
import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';

final _createdAt = DateTime.utc(2026, 10, 2, 8);
final _updatedAt = DateTime.utc(2026, 10, 2, 9);

void main() {
  late LocalStorageDatabase database;
  late DriftResumeRepository resumeRepository;
  late DriftAgentAuditRepository auditRepository;
  late DriftAppSettingsRepository settingsRepository;
  late DriftLocalDataRepository localDataRepository;

  setUp(() async {
    database = LocalStorageDatabase.inMemory();
    resumeRepository = DriftResumeRepository(database);
    auditRepository = DriftAgentAuditRepository(database);
    settingsRepository = DriftAppSettingsRepository(
      database,
      clock: () => _updatedAt,
    );
    localDataRepository = DriftLocalDataRepository(database);
    await _seedResume(resumeRepository);
    await settingsRepository.setNetworkEnabled(true);
    await auditRepository.recordRun(_agentRun(), [_toolCall()]);
  });

  tearDown(() => database.close());

  test('受限导出与普通快照一致且不含远程缓存', () async {
    await database.customStatement(
      'INSERT INTO remote_review_records VALUES (?, ?, NULL, ?, 0)',
      ['remote', 'account', 'X' * (localDataExportMaxRawBytes + 1)],
    );
    final regular = await localDataRepository.readSnapshot();
    final bounded = await localDataRepository.readExportSnapshot();
    expect(_resumesJson(bounded), _resumesJson(regular));
    expect(bounded.settings.length, regular.settings.length);
    expect(bounded.agentAudits.length, regular.agentAudits.length);
  });

  test('导出在读取无效巨型正文前拒绝且不影响普通读取或清空', () async {
    await database.customStatement(
      'UPDATE resume_versions SET content_json = ? WHERE id = ?',
      ['X' * (localDataExportMaxRawBytes + 1), 'version-001'],
    );
    await expectLater(
      localDataRepository.readExportSnapshot(),
      throwsA(isA<LocalDataExportLimitException>()),
    );
    final retained = await database
        .customSelect(
          'SELECT length(content_json) AS size FROM resume_versions WHERE id = ?',
          variables: [const Variable('version-001')],
        )
        .getSingle();
    expect(retained.read<int>('size'), localDataExportMaxRawBytes + 1);
    final result = await localDataRepository.clearAll();
    expect(result.versionCount, 2);
  });

  test('UTF8多字节与文档标题同样计入导出前置字节限制', () async {
    await database.customStatement('UPDATE resume_documents SET title = ?', [
      '中' * (localDataExportMaxRawBytes ~/ 3 + 1),
    ]);
    await expectLater(
      localDataRepository.readExportSnapshot(),
      throwsA(isA<LocalDataExportLimitException>()),
    );
    expect((await localDataRepository.readSnapshot()).resumes, hasLength(1));
  });

  test('原始文本恰好4MiB通过，多一字节整体拒绝', () async {
    await localDataRepository.clearAll();
    await database.customStatement(
      'INSERT INTO app_settings VALUES (?, 0, 0)',
      ['X' * localDataExportMaxRawBytes],
    );
    expect(
      (await localDataRepository.readExportSnapshot()).settings,
      hasLength(1),
    );
    await database.customStatement(
      "UPDATE app_settings SET setting_key = setting_key || 'X'",
    );
    await expectLater(
      localDataRepository.readExportSnapshot(),
      throwsA(isA<LocalDataExportLimitException>()),
    );
    expect(
      (await localDataRepository.readSnapshot()).settings.single.key.length,
      localDataExportMaxRawBytes + 1,
    );
  });

  test('库内深JSON在领域递归读取前拒绝，正文与普通清空保留', () async {
    final nested = '${'[' * 65}null${']' * 65}';
    await database.customStatement(
      'UPDATE resume_versions SET content_json = ? WHERE id = ?',
      [nested, 'version-001'],
    );
    await expectLater(
      localDataRepository.readExportSnapshot(),
      throwsA(
        isA<LocalDataExportLimitException>().having(
          (error) => error.message,
          '结构限制',
          contains('64'),
        ),
      ),
    );
    final retained = await database
        .customSelect(
          'SELECT content_json FROM resume_versions WHERE id = ?',
          variables: [const Variable('version-001')],
        )
        .getSingle();
    expect(retained.read<String>('content_json'), nested);
    expect((await localDataRepository.clearAll()).versionCount, 2);
  });

  test('库内全部JSON文本累计项数受限且引号内括号不计深度', () async {
    final harmless = '{"literal": "${'[]{}' * 100}"}';
    await database.customStatement(
      'UPDATE resume_documents SET metadata_json = ?',
      [harmless],
    );
    expect(
      (await localDataRepository.readExportSnapshot()).resumes,
      hasLength(1),
    );
    final tinyNodes = '[${List.filled(100001, 'null').join(',')}]';
    await database.customStatement(
      'UPDATE resume_documents SET metadata_json = ?, extensions_json = ?',
      [tinyNodes, tinyNodes],
    );
    await expectLater(
      localDataRepository.readExportSnapshot(),
      throwsA(
        isA<LocalDataExportLimitException>().having(
          (error) => error.message,
          '结构限制',
          contains('200000'),
        ),
      ),
    );
  });

  test('全部档案表合计10000行可读，增加一行拒绝且普通快照不受限', () async {
    // 初始文档1、版本2、设置1、run1、tool1，共6行。
    await database.customStatement('''
      WITH RECURSIVE counter(n) AS (
        SELECT 1 UNION ALL SELECT n + 1 FROM counter WHERE n < 9994
      ) INSERT INTO app_settings(setting_key, bool_value, updated_at)
        SELECT 'synthetic-' || n, 0, 0 FROM counter
    ''');
    final accepted = await localDataRepository.readExportSnapshot();
    expect(accepted.settings, hasLength(9995));
    await database.customStatement(
      "INSERT INTO app_settings VALUES ('one-over', 0, 0)",
    );
    await expectLater(
      localDataRepository.readExportSnapshot(),
      throwsA(isA<LocalDataExportLimitException>()),
    );
    expect(
      (await localDataRepository.readSnapshot()).settings,
      hasLength(9996),
    );
  });

  test('一致性快照包含全部版本、设置与脱敏 Agent 审计', () async {
    final snapshot = await localDataRepository.readSnapshot();

    expect(snapshot.storageSchemaVersion, 4);
    expect(snapshot.resumes, hasLength(1));
    expect(snapshot.resumes.single.document.currentVersionId, 'version-002');
    expect(snapshot.resumes.single.versions.map((version) => version.id), [
      'version-002',
      'version-001',
    ]);
    expect(snapshot.settings.single.key, 'network_enabled');
    expect(snapshot.settings.single.value, isTrue);
    expect(snapshot.settings.single.updatedAtUtc, _updatedAt);
    expect(snapshot.agentAudits.single.run.id, 'run-001');
    expect(
      snapshot.agentAudits.single.toolCalls.single.toolName,
      'validate_resume',
    );
    expect(() => snapshot.resumes.clear(), throwsUnsupportedError);
    expect(
      () => snapshot.resumes.single.versions.clear(),
      throwsUnsupportedError,
    );
  });

  test('事务清空返回可核对数量并使联网偏好恢复默认关闭', () async {
    final clearResult = await localDataRepository.clearAll();

    expect(clearResult.documentCount, 1);
    expect(clearResult.versionCount, 2);
    expect(clearResult.settingCount, 1);
    expect(clearResult.agentRunCount, 1);
    expect(clearResult.toolCallCount, 1);
    expect(await resumeRepository.listDocuments(), isEmpty);
    expect(await settingsRepository.getNetworkEnabled(), isFalse);
    final emptySnapshot = await localDataRepository.readSnapshot();
    expect(emptySnapshot.resumes, isEmpty);
    expect(emptySnapshot.settings, isEmpty);
    expect(emptySnapshot.agentAudits, isEmpty);
  });

  test('多文档乱序历史、多个根和空指针恢复保留身份与未知字段', () async {
    final resumes = [
      _archiveResume('archive-a'),
      _archiveResume('archive-b', nullCurrent: true),
      _archiveResume('archive-empty', empty: true),
    ];
    await localDataRepository.restoreResumes(resumes);
    final restored = await localDataRepository.readSnapshot();

    expect(restored.resumes, hasLength(4));
    for (final original in resumes) {
      final actual = restored.resumes.singleWhere(
        (entry) => entry.document.id == original.document.id,
      );
      expect(_resumeJson(actual), _resumeJson(original));
    }
    expect(await resumeRepository.findCurrentVersion('archive-b'), isNull);
    expect(await resumeRepository.findCurrentVersion('archive-empty'), isNull);
  });

  test('恢复仅添加简历历史，原简历、联网选择、审计及远程表原值不变', () async {
    await settingsRepository.setNetworkEnabled(false);
    await database.customStatement(
      "INSERT INTO remote_review_records VALUES ('remote-1', 'account-1', 'document-001', '{}', 1)",
    );
    await database.customStatement(
      "INSERT INTO remote_conversations VALUES ('account-1', 'document-001', '{}', 1)",
    );
    await database.customStatement(
      "INSERT INTO remote_acceptance_receipts VALUES ('remote-1', 'document-001', 'version-002')",
    );
    final before = await localDataRepository.readSnapshot();
    final protectedBefore = await _nonResumeRows(database);

    await localDataRepository.restoreResumes([_archiveResume('archive-a')]);

    final after = await localDataRepository.readSnapshot();
    expect(
      _resumeJson(
        after.resumes.singleWhere((s) => s.document.id == 'document-001'),
      ),
      _resumeJson(before.resumes.single),
    );
    expect(await settingsRepository.getNetworkEnabled(), isFalse);
    expect(
      after.settings.single.updatedAtUtc,
      before.settings.single.updatedAtUtc,
    );
    expect(await _nonResumeRows(database), protectedBefore);
  });

  test('档案内重复文档或跨文档重复版本身份整体拒绝且错误不含正文', () async {
    final first = _archiveResume('archive-a');
    final second = _archiveResume('archive-b');
    final duplicatedVersion = _replaceVersions(second, [
      ...second.versions.take(2),
      _changeVersion(second.versions.last, {'id': first.versions.last.id}),
    ]);
    for (final resumes in [
      [first, first],
      [first, duplicatedVersion],
    ]) {
      await expectLater(
        localDataRepository.restoreResumes(resumes),
        throwsA(isA<LocalDataRestoreValidationException>()),
      );
      expect((await localDataRepository.readSnapshot()).resumes, hasLength(1));
    }
    try {
      await localDataRepository.restoreResumes([first, first]);
    } on LocalDataRestoreValidationException catch (error) {
      expect(error.toString(), isNot(contains('合成姓名')));
      expect(error.toString(), isNot(contains('archive-a')));
    }
  });

  test('目标文档冲突、目标版本冲突和重复恢复均整体拒绝', () async {
    final collidingDocument = _archiveResume('document-001');
    final versionSource = _archiveResume('archive-b');
    final collidingVersion = _replaceVersions(versionSource, [
      ...versionSource.versions.take(2),
      _changeVersion(versionSource.versions.last, {'id': 'version-001'}),
    ]);
    for (final colliding in [collidingDocument, collidingVersion]) {
      await expectLater(
        localDataRepository.restoreResumes([
          _archiveResume('archive-a'),
          colliding,
        ]),
        throwsA(isA<LocalDataRestoreConflict>()),
      );
      expect((await localDataRepository.readSnapshot()).resumes, hasLength(1));
    }
    await localDataRepository.restoreResumes([_archiveResume('archive-a')]);
    final beforeRepeat = _resumesJson(await localDataRepository.readSnapshot());
    await expectLater(
      localDataRepository.restoreResumes([_archiveResume('archive-a')]),
      throwsA(isA<LocalDataRestoreConflict>()),
    );
    expect(
      _resumesJson(await localDataRepository.readSnapshot()),
      beforeRepeat,
    );
  });

  test('缺失或跨文档父链、自环及多版本环全部拒绝，不依赖数组顺序', () async {
    final original = _archiveResume('archive-a');
    final firstId = original.versions.first.id;
    final secondId = original.versions[1].id;
    final invalidVersions = [
      [
        _changeVersion(original.versions.first, {'parentVersionId': 'missing'}),
        ...original.versions.skip(1),
      ],
      [
        _changeVersion(original.versions.first, {
          'parentVersionId': 'archive-b-2',
        }),
        ...original.versions.skip(1),
      ],
      [
        _changeVersion(original.versions.first, {'parentVersionId': firstId}),
        ...original.versions.skip(1),
      ],
      [
        _changeVersion(original.versions.first, {'parentVersionId': secondId}),
        _changeVersion(original.versions[1], {'parentVersionId': firstId}),
        ...original.versions.skip(2),
      ],
    ];
    for (final versions in invalidVersions) {
      await expectLater(
        localDataRepository.restoreResumes([
          _replaceVersions(original, versions),
          _archiveResume('archive-b'),
        ]),
        throwsA(isA<LocalDataRestoreValidationException>()),
      );
      expect((await localDataRepository.readSnapshot()).resumes, hasLength(1));
    }
  });

  test('绕过档案解析的非法指针、归属、空身份、时间及Canonical仍拒绝', () async {
    final original = _archiveResume('archive-a');
    final invalid = [
      LocalResumeDataSnapshot(
        document: ResumeDocument.fromJson({
          ...original.document.toJson(),
          'currentVersionId': 'missing',
        }),
        versions: original.versions,
      ),
      LocalResumeDataSnapshot(
        document: ResumeDocument.fromJson({
          ...original.document.toJson(),
          'updatedAt': _createdAt.toIso8601String(),
        }),
        versions: original.versions,
      ),
      LocalResumeDataSnapshot(
        document: ResumeDocument.fromJson({
          ...original.document.toJson(),
          'title': ' ',
        }),
        versions: original.versions,
      ),
      _replaceVersions(original, [
        _changeVersion(original.versions.first, {'documentId': 'other'}),
        ...original.versions.skip(1),
      ]),
      _replaceVersions(original, [
        _changeVersion(original.versions.first, {'id': ' '}),
        ...original.versions.skip(1),
      ]),
      _replaceVersions(original, [
        _changeVersion(original.versions.first, {'parentVersionId': ' '}),
        ...original.versions.skip(1),
      ]),
      _replaceVersions(original, [
        _changeVersion(original.versions.first, {
          'content': {
            ...original.versions.first.content.toJson(),
            'profile': {
              ...original.versions.first.content.profile.toJson(),
              'email': 'invalid',
            },
          },
        }),
        ...original.versions.skip(1),
      ]),
    ];
    for (final snapshot in invalid) {
      await expectLater(
        localDataRepository.restoreResumes([
          _archiveResume('archive-b'),
          snapshot,
        ]),
        throwsA(isA<LocalDataRestoreValidationException>()),
      );
      expect((await localDataRepository.readSnapshot()).resumes, hasLength(1));
    }
  });

  test('最后版本插入失败或最后指针推进失败均回滚整份，原历史保留', () async {
    final before = _resumesJson(await localDataRepository.readSnapshot());
    for (final trigger in [
      "CREATE TRIGGER reject_restore BEFORE INSERT ON resume_versions WHEN NEW.id = 'archive-b-3' BEGIN SELECT RAISE(ABORT, 'synthetic insert failure'); END",
      "CREATE TRIGGER reject_restore BEFORE UPDATE OF current_version_id ON resume_documents WHEN NEW.id = 'archive-b' BEGIN SELECT RAISE(ABORT, 'synthetic pointer failure'); END",
    ]) {
      await database.customStatement(trigger);
      await expectLater(
        localDataRepository.restoreResumes([
          _archiveResume('archive-a'),
          _archiveResume('archive-b'),
        ]),
        throwsA(isA<Exception>()),
      );
      expect(_resumesJson(await localDataRepository.readSnapshot()), before);
      await database.customStatement('DROP TRIGGER reject_restore');
    }
    await localDataRepository.restoreResumes([
      _archiveResume('archive-a'),
      _archiveResume('archive-b'),
    ]);
    expect((await localDataRepository.readSnapshot()).resumes, hasLength(3));
  });

  test('实际SQLite提交失败回滚文档、版本和指针，随后可正常恢复', () async {
    final before = _resumesJson(await localDataRepository.readSnapshot());
    await database.customStatement(
      'CREATE TABLE restore_commit_guard(document_id TEXT REFERENCES resume_documents(id) DEFERRABLE INITIALLY DEFERRED)',
    );
    await database.customStatement(
      "CREATE TRIGGER reject_restore_commit AFTER INSERT ON resume_versions WHEN NEW.id = 'archive-b-3' BEGIN INSERT INTO restore_commit_guard VALUES ('missing'); END",
    );
    await expectLater(
      localDataRepository.restoreResumes([
        _archiveResume('archive-a'),
        _archiveResume('archive-b'),
      ]),
      throwsA(isA<Exception>()),
    );
    expect(_resumesJson(await localDataRepository.readSnapshot()), before);
    expect(
      await database.customSelect('SELECT * FROM restore_commit_guard').get(),
      isEmpty,
    );
    await database.customStatement('DROP TRIGGER reject_restore_commit');
    await database.customStatement('DROP TABLE restore_commit_guard');
    await localDataRepository.restoreResumes([_archiveResume('archive-a')]);
    expect((await localDataRepository.readSnapshot()).resumes, hasLength(2));
  });

  test('独立文件库恢复全部历史并重开逐字段一致，失败恢复重开也无半写', () async {
    final directory = await Directory.systemTemp.createTemp(
      'resume-archive-restore-',
    );
    final file = File('${directory.path}/synthetic.sqlite');
    LocalStorageDatabase? target;
    try {
      await localDataRepository.restoreResumes([
        _archiveResume('archive-a'),
        _archiveResume('archive-b', nullCurrent: true),
      ]);
      final source = await localDataRepository.readSnapshot();
      target = LocalStorageDatabase.openFile(file);
      await DriftLocalDataRepository(target).restoreResumes(source.resumes);
      await target.close();
      target = LocalStorageDatabase.openFile(file);
      expect(
        _resumesJson(await DriftLocalDataRepository(target).readSnapshot()),
        _resumesJson(source),
      );
      expect(await DriftAgentAuditRepository(target).listRuns(), isEmpty);

      final before = _resumesJson(
        await DriftLocalDataRepository(target).readSnapshot(),
      );
      await target.customStatement(
        "CREATE TRIGGER reject_disk_restore BEFORE INSERT ON resume_versions WHEN NEW.id = 'archive-d-3' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
      );
      await expectLater(
        DriftLocalDataRepository(target).restoreResumes([
          _archiveResume('archive-c'),
          _archiveResume('archive-d'),
        ]),
        throwsA(isA<Exception>()),
      );
      await target.close();
      target = LocalStorageDatabase.openFile(file);
      expect(
        _resumesJson(await DriftLocalDataRepository(target).readSnapshot()),
        before,
      );
    } finally {
      await target?.close();
      await directory.delete(recursive: true);
    }
  });

  test('恢复长且乱序的父链不递归、不丢版本', () async {
    final original = _archiveResume('archive-long');
    final versions = List<ResumeVersion>.generate(1500, (index) {
      return _changeVersion(original.versions.first, {
        'id': 'long-$index',
        'parentVersionId': index == 0 ? null : 'long-${index - 1}',
      });
    }).reversed.toList();
    await localDataRepository.restoreResumes([
      LocalResumeDataSnapshot(
        document: ResumeDocument.fromJson({
          ...original.document.toJson(),
          'currentVersionId': 'long-1499',
        }),
        versions: versions,
      ),
    ]);
    expect(
      await resumeRepository.listVersions('archive-long'),
      hasLength(1500),
    );
    expect(
      (await resumeRepository.findCurrentVersion('archive-long'))?.id,
      'long-1499',
    );
  });
}

LocalResumeDataSnapshot _archiveResume(
  String id, {
  bool nullCurrent = false,
  bool empty = false,
}) {
  final createdAt = DateTime.utc(2026, 10, 12, 6, 0, 0, 123, 456);
  final content = ResumeData(
    profile: ResumeProfile(
      id: 'stable-profile',
      fullName: '合成姓名',
      headline: '合成工程师',
      email: '',
      phone: '',
      location: '',
      extensions: const {
        'futureProfile': {'present': true},
      },
    ),
    extensions: const {
      'futureRoot': ['保留', 1],
    },
    unmapped: const {
      'legacy': {'text': '保留原值'},
    },
  );
  ResumeVersion version(int index, String? parent) => ResumeVersion(
    id: '$id-$index',
    documentId: id,
    parentVersionId: parent,
    schemaVersion: currentResumeSchemaVersion,
    content: content,
    source: index == 2
        ? ResumeVersionSource.restored
        : ResumeVersionSource.imported,
    createdAt: createdAt.add(Duration(microseconds: index)),
    extensions: const {
      'futureVersion': [true, null],
    },
  );
  return LocalResumeDataSnapshot(
    document: ResumeDocument(
      id: id,
      title: '合成档案',
      currentVersionId: nullCurrent || empty ? null : '$id-2',
      createdAt: createdAt,
      updatedAt: createdAt.add(const Duration(microseconds: 7)),
      metadata: const {
        'nested': {
          'labels': ['合成'],
        },
      },
      extensions: const {
        'futureDocument': {'value': 9},
      },
    ),
    versions: empty
        ? []
        : [version(2, '$id-1'), version(1, null), version(3, null)],
  );
}

ResumeVersion _changeVersion(ResumeVersion original, JsonMap fields) =>
    ResumeVersion.fromJson({...original.toJson(), ...fields});

LocalResumeDataSnapshot _replaceVersions(
  LocalResumeDataSnapshot original,
  List<ResumeVersion> versions,
) => LocalResumeDataSnapshot(document: original.document, versions: versions);

JsonMap _resumeJson(LocalResumeDataSnapshot snapshot) => {
  'document': snapshot.document.toJson(),
  'versions': {
    for (final version in snapshot.versions) version.id: version.toJson(),
  },
};

JsonMap _resumesJson(LocalDataSnapshot snapshot) => {
  for (final resume in snapshot.resumes)
    resume.document.id: _resumeJson(resume),
};

Future<List<List<JsonMap>>> _nonResumeRows(
  LocalStorageDatabase database,
) async {
  final rows = <List<JsonMap>>[];
  for (final table in [
    'app_settings',
    'agent_runs',
    'tool_calls',
    'remote_review_records',
    'remote_conversations',
    'remote_acceptance_receipts',
  ]) {
    rows.add(
      (await database.customSelect('SELECT * FROM $table').get())
          .map((row) => row.data)
          .toList(),
    );
  }
  return rows;
}

Future<void> _seedResume(ResumeRepository repository) async {
  final createdContent = ResumeData(
    profile: ResumeProfile(
      id: 'profile-001',
      fullName: '张三',
      headline: '工程师',
      email: '',
      phone: '',
      location: '',
    ),
  );
  final createdVersion = ResumeVersion(
    id: 'version-001',
    documentId: 'document-001',
    parentVersionId: null,
    schemaVersion: currentResumeSchemaVersion,
    content: createdContent,
    source: ResumeVersionSource.created,
    createdAt: _createdAt,
  );
  final createdDocument = ResumeDocument(
    id: 'document-001',
    title: '本地简历',
    currentVersionId: createdVersion.id,
    createdAt: _createdAt,
    updatedAt: _createdAt,
  );
  await repository.createDocument(createdDocument, createdVersion);

  final editedVersion = ResumeVersion(
    id: 'version-002',
    documentId: createdDocument.id,
    parentVersionId: createdVersion.id,
    schemaVersion: currentResumeSchemaVersion,
    content: ResumeData(
      profile: ResumeProfile(
        id: 'profile-001',
        fullName: '张三',
        headline: '高级工程师',
        email: '',
        phone: '',
        location: '',
      ),
    ),
    source: ResumeVersionSource.edited,
    createdAt: _updatedAt,
  );
  await repository.saveVersion(
    document: ResumeDocument(
      id: createdDocument.id,
      title: createdDocument.title,
      currentVersionId: editedVersion.id,
      createdAt: createdDocument.createdAt,
      updatedAt: _updatedAt,
    ),
    version: editedVersion,
    expectedCurrentVersionId: createdVersion.id,
  );
}

AgentRunAuditRecord _agentRun() {
  return AgentRunAuditRecord(
    id: 'run-001',
    requestId: 'request-001',
    documentId: 'document-001',
    resumeVersionId: 'version-002',
    status: 'completed',
    routeStatus: 'selected',
    startedAt: _updatedAt,
    finishedAt: _updatedAt.add(const Duration(milliseconds: 10)),
    toolCallCount: 1,
  );
}

ToolCallAuditRecord _toolCall() {
  return ToolCallAuditRecord(
    id: 'call-001',
    agentRunId: 'run-001',
    toolName: 'validate_resume',
    toolVersion: '0.1.0',
    status: 'success',
    startedAt: _updatedAt,
    finishedAt: _updatedAt.add(const Duration(milliseconds: 5)),
    offline: true,
    replayed: false,
  );
}
