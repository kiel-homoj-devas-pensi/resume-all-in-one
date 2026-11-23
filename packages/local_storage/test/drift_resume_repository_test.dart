import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:local_storage/local_storage.dart';
import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';

final _createdAt = DateTime.utc(2026, 10, 1, 8, 0, 0, 123, 456);

ResumeData _content(String name, {String email = 'user@example.com'}) {
  return ResumeData(
    profile: ResumeProfile(
      id: 'profile-$name',
      fullName: name,
      headline: '软件工程师',
      email: email,
      phone: '13800000000',
      location: '上海',
      extensions: const {
        'futureProfileField': {'enabled': true},
      },
    ),
    extensions: const {
      'futureRootField': ['保留'],
    },
  );
}

ResumeDocument _document({
  required String id,
  required String currentVersionId,
  required DateTime updatedAt,
  String title = '主简历',
}) {
  return ResumeDocument(
    id: id,
    title: title,
    currentVersionId: currentVersionId,
    createdAt: _createdAt,
    updatedAt: updatedAt,
    metadata: const {
      'tags': ['中文'],
    },
    extensions: const {'futureDocumentField': true},
  );
}

ResumeVersion _version({
  required String id,
  required String documentId,
  required String? parentVersionId,
  required ResumeData content,
  required ResumeVersionSource source,
  required DateTime createdAt,
}) {
  return ResumeVersion(
    id: id,
    documentId: documentId,
    parentVersionId: parentVersionId,
    schemaVersion: currentResumeSchemaVersion,
    content: content,
    source: source,
    createdAt: createdAt,
    extensions: const {'futureVersionField': 1},
  );
}

void main() {
  late LocalStorageDatabase database;
  late DriftResumeRepository repository;
  late bool databaseIsOpen;

  setUp(() {
    database = LocalStorageDatabase.inMemory();
    repository = DriftResumeRepository(database);
    databaseIsOpen = true;
  });

  tearDown(() async {
    if (databaseIsOpen) {
      await database.close();
    }
  });

  test('创建并读取文档与首个版本，未知字段保持不变', () async {
    final document = _document(
      id: 'document-001',
      currentVersionId: 'version-001',
      updatedAt: _createdAt,
    );
    final version = _version(
      id: 'version-001',
      documentId: document.id,
      parentVersionId: null,
      content: _content('张三'),
      source: ResumeVersionSource.created,
      createdAt: _createdAt,
    );

    await repository.createDocument(document, version);

    expect(
      jsonDeepEquals(
        (await repository.findDocument(document.id))!.toJson(),
        document.toJson(),
      ),
      isTrue,
    );
    expect(
      jsonDeepEquals(
        (await repository.findCurrentVersion(document.id))!.toJson(),
        version.toJson(),
      ),
      isTrue,
    );
    expect(await repository.listDocuments(), hasLength(1));
    expect(await repository.listVersions(document.id), hasLength(1));
  });

  test('追加版本原子更新当前指针且不修改历史版本', () async {
    final version1 = _version(
      id: 'version-001',
      documentId: 'document-001',
      parentVersionId: null,
      content: _content('张三'),
      source: ResumeVersionSource.created,
      createdAt: _createdAt,
    );
    await repository.createDocument(
      _document(
        id: 'document-001',
        currentVersionId: version1.id,
        updatedAt: _createdAt,
      ),
      version1,
    );

    final editedAt = _createdAt.add(const Duration(minutes: 1));
    final version2 = _version(
      id: 'version-002',
      documentId: 'document-001',
      parentVersionId: version1.id,
      content: _content('张三（新版）'),
      source: ResumeVersionSource.edited,
      createdAt: editedAt,
    );
    await repository.saveVersion(
      document: _document(
        id: 'document-001',
        currentVersionId: version2.id,
        updatedAt: editedAt,
        title: '主简历（更新）',
      ),
      version: version2,
      expectedCurrentVersionId: version1.id,
    );

    final current = await repository.findCurrentVersion('document-001');
    final history = await repository.listVersions('document-001');
    expect(current!.id, version2.id);
    expect(history.map((item) => item.id), [version2.id, version1.id]);
    expect(
      jsonDeepEquals(
        (await repository.findVersion(version1.id))!.toJson(),
        version1.toJson(),
      ),
      isTrue,
    );
  });

  test('版本插入后推进指针失败时事务回滚，重试只追加一次', () async {
    final originalVersion = _version(
      id: 'version-original',
      documentId: 'document-rollback',
      parentVersionId: null,
      content: _content('原始内容'),
      source: ResumeVersionSource.created,
      createdAt: _createdAt,
    );
    final originalDocument = _document(
      id: originalVersion.documentId,
      currentVersionId: originalVersion.id,
      updatedAt: _createdAt,
    );
    await repository.createDocument(originalDocument, originalVersion);
    final editedVersion = _version(
      id: 'version-edited',
      documentId: originalDocument.id,
      parentVersionId: originalVersion.id,
      content: _content('待保存内容'),
      source: ResumeVersionSource.edited,
      createdAt: _createdAt.add(const Duration(minutes: 1)),
    );
    final updatedDocument = _document(
      id: originalDocument.id,
      currentVersionId: editedVersion.id,
      updatedAt: editedVersion.createdAt,
      title: '待更新标题',
    );
    // 推进指针时故意失败，证明之前插入的版本也会被撤回。
    await database.customStatement(
      "CREATE TRIGGER fail_document_update BEFORE UPDATE ON resume_documents "
      "BEGIN SELECT RAISE(ABORT, 'synthetic_update_failure'); END",
    );
    await expectLater(
      repository.saveVersion(
        document: updatedDocument,
        version: editedVersion,
        expectedCurrentVersionId: originalVersion.id,
      ),
      throwsA(isA<Exception>()),
    );
    expect(await repository.findVersion(editedVersion.id), isNull);
    expect(await repository.listVersions(originalDocument.id), hasLength(1));
    expect(
      (await repository.findDocument(originalDocument.id))!.toJson(),
      originalDocument.toJson(),
    );
    expect(
      (await repository.findVersion(originalVersion.id))!.toJson(),
      originalVersion.toJson(),
    );

    await database.customStatement('DROP TRIGGER fail_document_update');
    await repository.saveVersion(
      document: updatedDocument,
      version: editedVersion,
      expectedCurrentVersionId: originalVersion.id,
    );
    expect(await repository.listVersions(originalDocument.id), hasLength(2));
    expect(
      (await repository.findDocument(originalDocument.id))!.currentVersionId,
      editedVersion.id,
    );
  });

  test('并发冲突不写入新版本且不移动当前指针', () async {
    final version1 = _version(
      id: 'version-001',
      documentId: 'document-001',
      parentVersionId: null,
      content: _content('张三'),
      source: ResumeVersionSource.created,
      createdAt: _createdAt,
    );
    await repository.createDocument(
      _document(
        id: 'document-001',
        currentVersionId: version1.id,
        updatedAt: _createdAt,
      ),
      version1,
    );

    final version2 = _version(
      id: 'version-002',
      documentId: 'document-001',
      parentVersionId: version1.id,
      content: _content('张三 2'),
      source: ResumeVersionSource.edited,
      createdAt: _createdAt.add(const Duration(minutes: 1)),
    );
    await repository.saveVersion(
      document: _document(
        id: 'document-001',
        currentVersionId: version2.id,
        updatedAt: version2.createdAt,
      ),
      version: version2,
      expectedCurrentVersionId: version1.id,
    );

    final staleVersion = _version(
      id: 'version-stale',
      documentId: 'document-001',
      parentVersionId: version1.id,
      content: _content('过期写入'),
      source: ResumeVersionSource.edited,
      createdAt: _createdAt.add(const Duration(minutes: 2)),
    );
    await expectLater(
      repository.saveVersion(
        document: _document(
          id: 'document-001',
          currentVersionId: staleVersion.id,
          updatedAt: staleVersion.createdAt,
        ),
        version: staleVersion,
        expectedCurrentVersionId: version1.id,
      ),
      throwsA(isA<ResumeWriteConflict>()),
    );

    expect(await repository.findVersion(staleVersion.id), isNull);
    expect(
      (await repository.findCurrentVersion('document-001'))!.id,
      version2.id,
    );
  });

  test('复制使用新文档和首版本，两个历史相互独立', () async {
    final originalVersion = _version(
      id: 'version-original',
      documentId: 'document-original',
      parentVersionId: null,
      content: _content('张三'),
      source: ResumeVersionSource.created,
      createdAt: _createdAt,
    );
    await repository.createDocument(
      _document(
        id: 'document-original',
        currentVersionId: originalVersion.id,
        updatedAt: _createdAt,
      ),
      originalVersion,
    );

    final copiedVersion = _version(
      id: 'version-copy',
      documentId: 'document-copy',
      parentVersionId: null,
      content: originalVersion.content,
      source: ResumeVersionSource.created,
      createdAt: _createdAt.add(const Duration(minutes: 1)),
    );
    await repository.createDocument(
      _document(
        id: 'document-copy',
        currentVersionId: copiedVersion.id,
        updatedAt: copiedVersion.createdAt,
        title: '主简历副本',
      ),
      copiedVersion,
    );

    expect(await repository.listDocuments(), hasLength(2));
    expect(await repository.listVersions('document-original'), hasLength(1));
    expect(await repository.listVersions('document-copy'), hasLength(1));
    expect(
      jsonDeepEquals(
        (await repository.findVersion(copiedVersion.id))!.content.toJson(),
        originalVersion.content.toJson(),
      ),
      isTrue,
    );
  });

  test('恢复历史生成新版本而不是移动或覆盖旧版本', () async {
    final version1 = _version(
      id: 'version-001',
      documentId: 'document-001',
      parentVersionId: null,
      content: _content('初始内容'),
      source: ResumeVersionSource.created,
      createdAt: _createdAt,
    );
    await repository.createDocument(
      _document(
        id: 'document-001',
        currentVersionId: version1.id,
        updatedAt: _createdAt,
      ),
      version1,
    );

    final version2 = _version(
      id: 'version-002',
      documentId: 'document-001',
      parentVersionId: version1.id,
      content: _content('编辑内容'),
      source: ResumeVersionSource.edited,
      createdAt: _createdAt.add(const Duration(minutes: 1)),
    );
    await repository.saveVersion(
      document: _document(
        id: 'document-001',
        currentVersionId: version2.id,
        updatedAt: version2.createdAt,
      ),
      version: version2,
      expectedCurrentVersionId: version1.id,
    );

    final restored = _version(
      id: 'version-003',
      documentId: 'document-001',
      parentVersionId: version2.id,
      content: version1.content,
      source: ResumeVersionSource.restored,
      createdAt: _createdAt.add(const Duration(minutes: 2)),
    );
    await repository.saveVersion(
      document: _document(
        id: 'document-001',
        currentVersionId: restored.id,
        updatedAt: restored.createdAt,
      ),
      version: restored,
      expectedCurrentVersionId: version2.id,
    );

    final history = await repository.listVersions('document-001');
    expect(history.map((item) => item.id), [
      restored.id,
      version2.id,
      version1.id,
    ]);
    expect(history.first.source, ResumeVersionSource.restored);
    expect(
      jsonDeepEquals(history.first.content.toJson(), version1.content.toJson()),
      isTrue,
    );
  });

  test('删除文档级联删除版本且重复删除返回 false', () async {
    final version = _version(
      id: 'version-001',
      documentId: 'document-001',
      parentVersionId: null,
      content: _content('张三'),
      source: ResumeVersionSource.created,
      createdAt: _createdAt,
    );
    await repository.createDocument(
      _document(
        id: 'document-001',
        currentVersionId: version.id,
        updatedAt: _createdAt,
      ),
      version,
    );

    expect(await repository.deleteDocument('document-001'), isTrue);
    expect(await repository.findDocument('document-001'), isNull);
    expect(await repository.findVersion(version.id), isNull);
    expect(await repository.deleteDocument('document-001'), isFalse);
  });

  test('validation 失败时不产生部分文档', () async {
    final invalid = _version(
      id: 'version-invalid',
      documentId: 'document-invalid',
      parentVersionId: null,
      content: _content('张三', email: 'invalid-email'),
      source: ResumeVersionSource.created,
      createdAt: _createdAt,
    );

    await expectLater(
      repository.createDocument(
        _document(
          id: 'document-invalid',
          currentVersionId: invalid.id,
          updatedAt: _createdAt,
        ),
        invalid,
      ),
      throwsA(isA<ResumeValidationException>()),
    );
    expect(await repository.findDocument('document-invalid'), isNull);
  });

  test('损坏的持久化 JSON 被拒绝且异常不包含正文', () async {
    final version = _version(
      id: 'version-001',
      documentId: 'document-001',
      parentVersionId: null,
      content: _content('敏感姓名'),
      source: ResumeVersionSource.created,
      createdAt: _createdAt,
    );
    await repository.createDocument(
      _document(
        id: 'document-001',
        currentVersionId: version.id,
        updatedAt: _createdAt,
      ),
      version,
    );
    await database.customUpdate(
      'UPDATE resume_versions SET content_json = ? WHERE id = ?',
      variables: [
        const Variable<String>('{"profile":"敏感姓名"}'),
        Variable<String>(version.id),
      ],
      updates: {database.resumeVersions},
    );

    final matcher = isA<StoredResumeDataException>().having(
      (error) => error.toString(),
      'message',
      isNot(contains('敏感姓名')),
    );
    await expectLater(repository.findVersion(version.id), throwsA(matcher));
  });

  test('操作过程不打印简历正文', () async {
    final output = <String>[];
    await runZoned(
      () async {
        final version = _version(
          id: 'version-private',
          documentId: 'document-private',
          parentVersionId: null,
          content: _content('不应出现在日志中的姓名'),
          source: ResumeVersionSource.created,
          createdAt: _createdAt,
        );
        await repository.createDocument(
          _document(
            id: 'document-private',
            currentVersionId: version.id,
            updatedAt: _createdAt,
          ),
          version,
        );
        await repository.findCurrentVersion('document-private');
      },
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => output.add(line),
      ),
    );

    expect(output.join('\n'), isNot(contains('不应出现在日志中的姓名')));
  });

  test('文件数据库跨重启持久化且重复打开保持 v4', () async {
    await database.close();
    databaseIsOpen = false;
    final directory = await Directory.systemTemp.createTemp(
      'resume-local-storage-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}resume.sqlite',
    );
    try {
      final firstDatabase = LocalStorageDatabase.openFile(file);
      final firstRepository = DriftResumeRepository(firstDatabase);
      final version = _version(
        id: 'version-persisted',
        documentId: 'document-persisted',
        parentVersionId: null,
        content: _content('持久化用户'),
        source: ResumeVersionSource.created,
        createdAt: _createdAt,
      );
      await firstRepository.createDocument(
        _document(
          id: 'document-persisted',
          currentVersionId: version.id,
          updatedAt: _createdAt,
        ),
        version,
      );
      await firstDatabase.close();

      for (var attempt = 0; attempt < 2; attempt++) {
        final reopened = LocalStorageDatabase.openFile(file);
        final reopenedRepository = DriftResumeRepository(reopened);
        expect(
          (await reopenedRepository.findCurrentVersion(
            'document-persisted',
          ))!.id,
          version.id,
        );
        final userVersion = await reopened
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(userVersion.read<int>('user_version'), 4);
        expect(
          await reopened.customSelect('PRAGMA foreign_key_check').get(),
          isEmpty,
        );
        await reopened.close();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('新库联网开启并跨重启持久化', () async {
    await database.close();
    databaseIsOpen = false;
    final directory = await Directory.systemTemp.createTemp(
      'resume-app-settings-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}resume.sqlite',
    );
    try {
      final firstDatabase = LocalStorageDatabase.openFile(file);
      final firstSettings = DriftAppSettingsRepository(
        firstDatabase,
        clock: () => _createdAt,
      );
      expect(await firstSettings.getNetworkEnabled(), isTrue);
      await firstSettings.setNetworkEnabled(true);
      await firstDatabase.close();

      final reopened = LocalStorageDatabase.openFile(file);
      final reopenedSettings = DriftAppSettingsRepository(reopened);
      expect(await reopenedSettings.getNetworkEnabled(), isTrue);
      await reopened.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('v1 升级到 v4 保留简历并使联网设置默认关闭', () async {
    await database.close();
    databaseIsOpen = false;
    final directory = await Directory.systemTemp.createTemp(
      'resume-storage-migration-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}resume.sqlite',
    );
    try {
      final currentDatabase = LocalStorageDatabase.openFile(file);
      final currentRepository = DriftResumeRepository(currentDatabase);
      final version = _version(
        id: 'version-before-migration',
        documentId: 'document-before-migration',
        parentVersionId: null,
        content: _content('迁移用户'),
        source: ResumeVersionSource.created,
        createdAt: _createdAt,
      );
      await currentRepository.createDocument(
        _document(
          id: version.documentId,
          currentVersionId: version.id,
          updatedAt: _createdAt,
        ),
        version,
      );
      await currentDatabase.customStatement('DROP TABLE tool_calls');
      await currentDatabase.customStatement('DROP TABLE agent_runs');
      await currentDatabase.customStatement('DROP TABLE app_settings');
      for (final table in [
        'remote_review_records',
        'remote_conversations',
        'remote_acceptance_receipts',
      ]) {
        await currentDatabase.customStatement('DROP TABLE $table');
      }
      await currentDatabase.customStatement('PRAGMA user_version = 1');
      await currentDatabase.close();

      final migrated = LocalStorageDatabase.openFile(file);
      final migratedRepository = DriftResumeRepository(migrated);
      final migratedSettings = DriftAppSettingsRepository(migrated);
      expect(
        (await migratedRepository.findCurrentVersion(version.documentId))!.id,
        version.id,
      );
      expect(
        await migratedRepository.listVersions(version.documentId),
        hasLength(1),
      );
      expect(await migratedSettings.getNetworkEnabled(), isFalse);
      final userVersion = await migrated
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(userVersion.read<int>('user_version'), 4);
      final auditTables = await migrated
          .customSelect(
            "SELECT name FROM sqlite_master "
            "WHERE type = 'table' AND name IN ('agent_runs', 'tool_calls')",
          )
          .get();
      expect(auditTables, hasLength(2));
      await migrated.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('v2 升级到 v4 保留简历与联网设置并创建审计表', () async {
    await database.close();
    databaseIsOpen = false;
    final directory = await Directory.systemTemp.createTemp(
      'resume-storage-v2-migration-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}resume.sqlite',
    );
    try {
      final currentDatabase = LocalStorageDatabase.openFile(file);
      final currentRepository = DriftResumeRepository(currentDatabase);
      final currentSettings = DriftAppSettingsRepository(
        currentDatabase,
        clock: () => _createdAt,
      );
      final version = _version(
        id: 'version-from-v2',
        documentId: 'document-from-v2',
        parentVersionId: null,
        content: _content('v2 迁移用户'),
        source: ResumeVersionSource.created,
        createdAt: _createdAt,
      );
      await currentRepository.createDocument(
        _document(
          id: version.documentId,
          currentVersionId: version.id,
          updatedAt: _createdAt,
        ),
        version,
      );
      await currentSettings.setNetworkEnabled(true);
      await currentDatabase.customStatement('DROP TABLE tool_calls');
      await currentDatabase.customStatement('DROP TABLE agent_runs');
      for (final table in [
        'remote_review_records',
        'remote_conversations',
        'remote_acceptance_receipts',
      ]) {
        await currentDatabase.customStatement('DROP TABLE $table');
      }
      await currentDatabase.customStatement('PRAGMA user_version = 2');
      await currentDatabase.close();

      final migrated = LocalStorageDatabase.openFile(file);
      final migratedRepository = DriftResumeRepository(migrated);
      final migratedSettings = DriftAppSettingsRepository(migrated);
      expect(
        (await migratedRepository.findCurrentVersion(version.documentId))!.id,
        version.id,
      );
      expect(await migratedSettings.getNetworkEnabled(), isTrue);
      final userVersion = await migrated
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(userVersion.read<int>('user_version'), 4);
      final auditTables = await migrated
          .customSelect(
            "SELECT name FROM sqlite_master "
            "WHERE type = 'table' AND name IN ('agent_runs', 'tool_calls')",
          )
          .get();
      expect(auditTables, hasLength(2));
      await migrated.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('Repository 查询结果集合不可修改', () async {
    final documents = await repository.listDocuments();
    final versions = await repository.listVersions('missing');

    expect(
      () => documents.add(
        _document(
          id: 'new',
          currentVersionId: 'version-new',
          updatedAt: _createdAt,
        ),
      ),
      throwsUnsupportedError,
    );
    expect(
      () => versions.add(
        _version(
          id: 'version-new',
          documentId: 'new',
          parentVersionId: null,
          content: _content('新用户'),
          source: ResumeVersionSource.created,
          createdAt: _createdAt,
        ),
      ),
      throwsUnsupportedError,
    );
  });
}
