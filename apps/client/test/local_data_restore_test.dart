import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:entitlements/entitlements.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/local_agent_composition.dart';
import 'support/local_suggestion_fixture.dart';
import 'package:resume_all_in_one_client/src/local_data_archive_file_picker.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';
import 'package:resume_all_in_one_client/src/remote_resume_ai_service.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';
import 'package:resume_all_in_one_client/src/resume_workspace_controller.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  late LocalStorageDatabase database;
  late Directory directory;
  late SyntheticArchivePicker picker;
  late ResumeWorkspaceController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('archive-flow-test-');
    database = LocalStorageDatabase.openFile(
      File('${directory.path}/target.sqlite'),
    );
    await DriftAppSettingsRepository(database).setNetworkEnabled(false);
    picker = SyntheticArchivePicker();
    controller = createRestoreController(database, picker, directory);
    await controller.initialize();
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  test('真实导出经 worker 预览和确认恢复，重开文件库逐字段保留全部历史', () async {
    final source = LocalStorageDatabase.inMemory();
    final LocalDataExportResult exported;
    final LocalDataSnapshot sourceSnapshot;
    try {
      await DriftLocalDataRepository(
        source,
      ).restoreResumes(syntheticRestoreResumes());
      final settings = DriftAppSettingsRepository(source);
      await settings.setNetworkEnabled(true);
      await settings.setRemotePersonalDataWarningAcknowledged(true);
      await settings.setThemePreference(AppThemePreference.dark);
      await seedSyntheticArchiveAudit(source);
      sourceSnapshot = await DriftLocalDataRepository(source).readSnapshot();
      exported = await LocalDataManagementService(
        repository: DriftLocalDataRepository(source),
        rootDirectory: () async => directory,
      ).exportAll();
      picker.bytes = await exported.file.readAsBytes();
    } finally {
      await source.close();
    }
    final targetSettingsBefore = await protectedRestoreRows(database);
    final selectedBytes = List<int>.of(picker.bytes!);

    final preview = await controller.prepareLocalDataRestore();

    expect(preview, isNotNull);
    expect(preview!.summary.documentCount, 2);
    expect(preview.summary.versionCount, 6);
    expect(preview.summary.settingCount, 4);
    expect(preview.summary.agentRunCount, 1);
    expect(preview.summary.toolCallCount, 1);
    expect(
      resumesByIdentity(preview.resumes),
      resumesByIdentity(sourceSnapshot.resumes),
    );
    expect(
      await DriftResumeRepository(database).listDocuments(),
      isEmpty,
      reason: '完成文件选择、worker 校验和预览都不写库',
    );
    expect(await controller.confirmLocalDataRestore(preview), isTrue);
    expect(controller.pendingLocalDataRestore, isNull);
    expect(controller.isBusy, isFalse);
    expect(controller.documents, hasLength(2));
    expect(controller.message, contains('已恢复 2 份简历与 6 个历史版本'));
    expect(controller.networkEnabled, isFalse);
    expect(
      await protectedRestoreRows(database),
      targetSettingsBefore,
      reason: '旧档案的联网同意、主题和审计均不恢复',
    );
    expect(picker.bytes, selectedBytes);
    expect(await exported.file.readAsBytes(), selectedBytes);

    controller.dispose();
    await database.close();
    database = LocalStorageDatabase.openFile(
      File('${directory.path}/target.sqlite'),
    );
    controller = createRestoreController(database, picker, directory);
    await controller.initialize();
    final reopened = await DriftLocalDataRepository(database).readSnapshot();
    expect(
      resumesByIdentity(reopened.resumes),
      resumesByIdentity(sourceSnapshot.resumes),
    );
    expect(
      await DriftResumeRepository(database).findCurrentVersion('archive-b'),
      isNull,
    );
    expect(await protectedRestoreRows(database), targetSettingsBefore);
    expect(controller.networkEnabled, isFalse);
  });

  test('选择取消及预览取消都不写库，旧预览不能随后提交', () async {
    expect(await controller.prepareLocalDataRestore(), isNull);
    expect(controller.isBusy, isFalse);
    picker.bytes = syntheticRestoreBytes();
    final preview = await controller.prepareLocalDataRestore();
    controller.cancelLocalDataRestore();
    expect(controller.pendingLocalDataRestore, isNull);
    expect(await controller.confirmLocalDataRestore(preview!), isFalse);
    expect(await DriftResumeRepository(database).listDocuments(), isEmpty);
    expect(controller.networkEnabled, isFalse);
  });

  test('worker 拒绝损坏 UTF8/JSON/格式/重复身份/父链，失败不留下待提交资料', () async {
    final invalid = <Uint8List>[
      Uint8List.fromList([0xff, 0xfe, 0x80]),
      Uint8List.fromList(utf8.encode('{synthetic-broken')),
      mutateRestoreBytes((archive) => archive['exportFormatVersion'] = '9.9.9'),
      mutateRestoreBytes((archive) {
        final resumes = archive['resumes']! as List<Object?>;
        resumes.add(resumes.first);
      }),
      mutateRestoreBytes((archive) {
        final resume = (archive['resumes']! as List<Object?>).first as JsonMap;
        ((resume['versions']! as List<Object?>).first
                as JsonMap)['parentVersionId'] =
            'absent';
      }),
      mutateRestoreBytes((archive) => archive['resumes'] = <Object?>[]),
    ];
    final before = await protectedRestoreRows(database);
    for (final bytes in invalid) {
      picker.bytes = bytes;
      expect(await controller.prepareLocalDataRestore(), isNull);
      expect(controller.formError, isNotNull);
      expect(controller.pendingLocalDataRestore, isNull);
      expect(controller.isBusy, isFalse);
      expect(await DriftResumeRepository(database).listDocuments(), isEmpty);
      expect(await protectedRestoreRows(database), before);
    }
  });

  test('预览后目标出现身份冲突，确认整体拒绝且不添加另一份文档', () async {
    picker.bytes = syntheticRestoreBytes();
    final preview = await controller.prepareLocalDataRestore();
    await DriftLocalDataRepository(
      database,
    ).restoreResumes([syntheticRestoreResumes().last]);
    final before = await DriftLocalDataRepository(database).readSnapshot();
    expect(await controller.confirmLocalDataRestore(preview!), isFalse);
    expect(controller.formError, contains('整份恢复已拒绝'));
    expect(controller.isBusy, isFalse);
    expect(
      resumesByIdentity(
        (await DriftLocalDataRepository(database).readSnapshot()).resumes,
      ),
      resumesByIdentity(before.resumes),
    );
    expect(
      await DriftResumeRepository(database).findDocument('archive-a'),
      isNull,
    );
  });

  test('重新选择已经恢复的档案按冲突拒绝，不复制文档或追加版本', () async {
    picker.bytes = syntheticRestoreBytes();
    final first = await controller.prepareLocalDataRestore();
    expect(await controller.confirmLocalDataRestore(first!), isTrue);
    final before = await DriftLocalDataRepository(database).readSnapshot();
    final repeat = await controller.prepareLocalDataRestore();
    expect(await controller.confirmLocalDataRestore(repeat!), isFalse);
    expect(controller.formError, contains('已在本机存在'));
    expect(
      resumesByIdentity(
        (await DriftLocalDataRepository(database).readSnapshot()).resumes,
      ),
      resumesByIdentity(before.resumes),
    );
  });

  test('末尾写入失败由控制器如实反馈，事务回滚且可明确重试', () async {
    await database.customStatement(
      "CREATE TRIGGER reject_restore BEFORE INSERT ON resume_versions WHEN NEW.id = 'archive-b-v3' BEGIN SELECT RAISE(ABORT, 'synthetic private path'); END",
    );
    picker.bytes = syntheticRestoreBytes();
    final preview = await controller.prepareLocalDataRestore();
    expect(await controller.confirmLocalDataRestore(preview!), isFalse);
    expect(controller.formError, contains('现有资料保持不变'));
    expect(controller.formError, isNot(contains('synthetic private path')));
    expect(controller.message, isNull);
    expect(controller.isBusy, isFalse);
    expect(await DriftResumeRepository(database).listDocuments(), isEmpty);
    await database.customStatement('DROP TRIGGER reject_restore');
    expect(await controller.confirmLocalDataRestore(preview), isTrue);
    expect(await DriftResumeRepository(database).listDocuments(), hasLength(2));
  });

  test('事务成功后列表读取失败仍返回已提交，清除预览防止盲目重试', () async {
    controller.dispose();
    final reader = _FailOnceListRepository(DriftResumeRepository(database));
    controller = createRestoreController(
      database,
      picker,
      directory,
      resumeRepository: reader,
    );
    await controller.initialize();
    picker.bytes = syntheticRestoreBytes();
    final preview = await controller.prepareLocalDataRestore();
    reader.failNextList = true;
    expect(await controller.confirmLocalDataRestore(preview!), isTrue);
    expect(reader.failedReads, 1);
    expect(controller.formError, isNull);
    expect(controller.message, contains('已恢复，但列表刷新未完成'));
    expect(controller.message, contains('不要重复恢复'));
    expect(controller.message, isNot(contains('synthetic secret')));
    expect(controller.pendingLocalDataRestore, isNull);
    expect(controller.isBusy, isFalse);
    expect(await controller.confirmLocalDataRestore(preview), isFalse);
    expect(
      resumesByIdentity(
        (await DriftLocalDataRepository(database).readSnapshot()).resumes,
      ),
      resumesByIdentity(syntheticRestoreResumes()),
    );
  });

  test('选择和提交期间重复点击不重开选择器、不重复事务且最终解除忙碌', () async {
    controller.dispose();
    final writer = _GatedRestoreRepository(DriftLocalDataRepository(database));
    controller = createRestoreController(
      database,
      picker,
      directory,
      localDataRepository: writer,
    );
    await controller.initialize();
    await controller.createDocument(title: '保留原件', fullName: '合成原姓名');
    final original = controller.currentVersion!;
    final originalDocument = controller.currentDocument!;
    picker.gate = Completer<SelectedLocalDataArchiveFile?>();
    final preparing = controller.prepareLocalDataRestore();
    expect(controller.isBusy, isTrue);
    expect(await controller.prepareLocalDataRestore(), isNull);
    expect(picker.calls, 1);
    picker.gate!.complete(
      SelectedLocalDataArchiveFile(bytes: syntheticRestoreBytes()),
    );
    final preview = await preparing;
    expect(controller.isBusy, isFalse);
    final committing = controller.confirmLocalDataRestore(preview!);
    await writer.entered.future;
    expect(controller.isBusy, isTrue);
    expect(await controller.confirmLocalDataRestore(preview), isFalse);
    expect(await controller.prepareLocalDataRestore(), isNull);
    expect(picker.calls, 1);
    expect(writer.restoreCalls, 1);
    expect(
      await controller.createDocument(title: '并发新建', fullName: '并发姓名'),
      isFalse,
    );
    expect(
      await controller.deleteDocument(original.documentId),
      DocumentLifecycleOutcome.failed,
    );
    expect(await controller.clearAllLocalData(), isNull);
    expect(
      await controller.saveContent(title: '并发修改', content: original.content),
      SaveOutcome.blocked,
    );
    expect(
      await controller.restoreVersion(original.id),
      DocumentLifecycleOutcome.failed,
    );
    expect(controller.currentVersion!.id, original.id);
    expect(controller.currentDocument!.toJson(), originalDocument.toJson());
    expect(controller.isBusy, isTrue);
    expect(await DriftResumeRepository(database).listDocuments(), hasLength(1));
    expect(
      await DriftResumeRepository(database).listVersions(original.documentId),
      hasLength(1),
    );
    writer.release.complete();
    expect(await committing, isTrue);
    expect(controller.isBusy, isFalse);
    expect(writer.restoreCalls, 1);
    expect(await DriftResumeRepository(database).listDocuments(), hasLength(3));
    expect(
      (await DriftResumeRepository(
        database,
      ).findDocument(original.documentId))!.toJson(),
      originalDocument.toJson(),
    );
  });

  test('真实导出快照前置拒绝超限，控制器退出忙碌且旧文件和数据库保留', () async {
    await DriftLocalDataRepository(
      database,
    ).restoreResumes(syntheticRestoreResumes());
    final oversizedExtension = jsonEncode({
      'syntheticPadding': 'x' * localDataExportMaxRawBytes,
    });
    await database.customStatement(
      "UPDATE resume_versions SET extensions_json = ? WHERE id = 'archive-a-v1'",
      [oversizedExtension],
    );
    final exportDirectory = Directory('${directory.path}/local_data_exports');
    await exportDirectory.create();
    final existing = File('${exportDirectory.path}/synthetic-original.json');
    await existing.writeAsString('synthetic existing export', flush: true);
    final before = await database
        .customSelect('SELECT * FROM resume_versions ORDER BY id')
        .get();

    expect(await controller.exportAllLocalData(), isNull);

    expect(controller.formError, isNotNull);
    expect(controller.message, isNull);
    expect(controller.isBusy, isFalse);
    expect(await existing.readAsString(), 'synthetic existing export');
    expect(exportDirectory.listSync().map((entry) => entry.absolute.uri), [
      existing.absolute.uri,
    ]);
    expect(
      (await database
              .customSelect('SELECT * FROM resume_versions ORDER BY id')
              .get())
          .map((row) => row.data),
      before.map((row) => row.data),
    );
    expect(await DriftResumeRepository(database).listDocuments(), hasLength(2));
  });
}

// Shared synthetic fixture used by the consumer and real-app UI acceptance tests.
final class SyntheticArchivePicker implements LocalDataArchiveFilePicker {
  Uint8List? bytes;
  Completer<SelectedLocalDataArchiveFile?>? gate;
  int calls = 0;

  @override
  Future<SelectedLocalDataArchiveFile?> pickArchive() async {
    calls++;
    if (gate != null) return gate!.future;
    final value = bytes;
    return value == null ? null : SelectedLocalDataArchiveFile(bytes: value);
  }
}

ResumeWorkspaceController createRestoreController(
  LocalStorageDatabase database,
  SyntheticArchivePicker picker,
  Directory directory, {
  ResumeRepository? resumeRepository,
  LocalDataRepository? localDataRepository,
}) {
  final repository = resumeRepository ?? DriftResumeRepository(database);
  final account = RemoteAccountService(gatewayApi: null);
  return ResumeWorkspaceController(
    repository: repository,
    settingsRepository: DriftAppSettingsRepository(database),
    localAgentCheckService: createOfflineLocalAgentCheckService(
      resumeRepository: repository,
      auditRepository: DriftAgentAuditRepository(database),
    ),
    localResumeSuggestionService: createOfflineLocalResumeSuggestionService(
      resumeRepository: repository,
      auditRepository: DriftAgentAuditRepository(database),
    ),
    localDataManagementService: LocalDataManagementService(
      repository: localDataRepository ?? DriftLocalDataRepository(database),
      rootDirectory: () async => directory,
      archiveFilePicker: picker,
    ),
    accessPolicy: CapabilityAccessPolicy.mvp(),
    fileExporter: ResumeFileExporter(rootDirectory: () async => directory),
    importFilePicker: const SystemResumeImportFilePicker(),
    remoteAccountService: account,
    remoteResumeAiService: RemoteResumeAiService(accountService: account),
  );
}

List<LocalResumeDataSnapshot> syntheticRestoreResumes() {
  final at = DateTime.utc(2026, 10, 12, 6, 0, 0, 123, 456);
  LocalResumeDataSnapshot resume(String id, {bool nullCurrent = false}) {
    final content = ResumeData(
      profile: ResumeProfile(
        id: '$id-profile',
        fullName: '合成姓名',
        headline: '合成工程师',
        email: '',
        phone: '',
        location: '',
        extensions: const {
          'futureProfile': {'enabled': true},
        },
      ),
      extensions: const {
        'futureContent': ['保留', 42],
      },
      unmapped: const {
        'legacy': {'text': '人工映射合成内容'},
      },
    );
    ResumeVersion version(int index, String? parent) => ResumeVersion(
      id: '$id-v$index',
      documentId: id,
      parentVersionId: parent,
      schemaVersion: currentResumeSchemaVersion,
      content: content,
      source: index == 2
          ? ResumeVersionSource.restored
          : ResumeVersionSource.imported,
      createdAt: at.add(Duration(microseconds: index)),
      extensions: const {
        'futureVersion': [true, null],
      },
    );
    return LocalResumeDataSnapshot(
      document: ResumeDocument(
        id: id,
        title: '合成档案 $id',
        currentVersionId: nullCurrent ? null : '$id-v2',
        createdAt: at,
        updatedAt: at.add(const Duration(microseconds: 7)),
        metadata: const {
          'nested': {
            'labels': ['合成'],
          },
        },
        extensions: const {
          'futureDocument': {'revision': 7},
        },
      ),
      versions: [version(2, '$id-v1'), version(1, null), version(3, null)],
    );
  }

  return [resume('archive-a'), resume('archive-b', nullCurrent: true)];
}

Uint8List syntheticRestoreBytes() => Uint8List.fromList(
  utf8.encode(
    const LocalDataArchiveCodec().encode(
      LocalDataSnapshot(
        storageSchemaVersion: 4,
        resumes: syntheticRestoreResumes(),
        settings: const [],
        agentAudits: const [],
      ),
      DateTime.utc(2026, 10, 12, 7),
    ),
  ),
);

Uint8List mutateRestoreBytes(void Function(JsonMap) mutate) {
  final archive = jsonDecode(utf8.decode(syntheticRestoreBytes())) as JsonMap;
  mutate(archive);
  return Uint8List.fromList(utf8.encode(jsonEncode(archive)));
}

JsonMap resumesByIdentity(List<LocalResumeDataSnapshot> resumes) => {
  for (final resume in resumes)
    resume.document.id: {
      'document': resume.document.toJson(),
      'versions': {
        for (final version in resume.versions) version.id: version.toJson(),
      },
    },
};

Future<List<List<JsonMap>>> protectedRestoreRows(
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

Future<void> seedSyntheticArchiveAudit(LocalStorageDatabase database) async {
  final at = DateTime.utc(2026, 10, 12, 7);
  await DriftAgentAuditRepository(database).recordRun(
    AgentRunAuditRecord(
      id: 'synthetic-run',
      requestId: 'synthetic-request',
      documentId: 'archive-a',
      resumeVersionId: 'archive-a-v2',
      status: 'completed',
      routeStatus: 'selected',
      startedAt: at,
      finishedAt: at.add(const Duration(milliseconds: 10)),
      toolCallCount: 1,
    ),
    [
      ToolCallAuditRecord(
        id: 'synthetic-call',
        agentRunId: 'synthetic-run',
        toolName: 'validate_resume',
        toolVersion: '0.1.0',
        status: 'success',
        startedAt: at,
        finishedAt: at.add(const Duration(milliseconds: 5)),
        offline: true,
        replayed: false,
      ),
    ],
  );
}

final class _GatedRestoreRepository implements LocalDataRepository {
  _GatedRestoreRepository(this.delegate);
  final LocalDataRepository delegate;
  final entered = Completer<void>();
  final release = Completer<void>();
  int restoreCalls = 0;
  @override
  Future<LocalDataSnapshot> readSnapshot() => delegate.readSnapshot();
  @override
  Future<LocalDataSnapshot> readExportSnapshot() =>
      delegate.readExportSnapshot();
  @override
  Future<LocalDataClearResult> clearAll() => delegate.clearAll();
  @override
  Future<void> restoreResumes(List<LocalResumeDataSnapshot> resumes) async {
    restoreCalls++;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    await delegate.restoreResumes(resumes);
  }
}

final class _FailOnceListRepository implements ResumeRepository {
  _FailOnceListRepository(this.delegate);
  final ResumeRepository delegate;
  bool failNextList = false;
  int failedReads = 0;
  @override
  Future<List<ResumeDocument>> listDocuments() async {
    if (failNextList) {
      failNextList = false;
      failedReads++;
      throw StateError('synthetic secret read failure');
    }
    return delegate.listDocuments();
  }

  @override
  Future<void> createDocument(
    ResumeDocument document,
    ResumeVersion initialVersion,
  ) => delegate.createDocument(document, initialVersion);
  @override
  Future<void> saveVersion({
    required ResumeDocument document,
    required ResumeVersion version,
    required String expectedCurrentVersionId,
  }) => delegate.saveVersion(
    document: document,
    version: version,
    expectedCurrentVersionId: expectedCurrentVersionId,
  );
  @override
  Future<bool> deleteDocument(String documentId) =>
      delegate.deleteDocument(documentId);
  @override
  Future<ResumeDocument?> findDocument(String documentId) =>
      delegate.findDocument(documentId);
  @override
  Future<ResumeVersion?> findVersion(String versionId) =>
      delegate.findVersion(versionId);
  @override
  Future<ResumeVersion?> findCurrentVersion(String documentId) =>
      delegate.findCurrentVersion(documentId);
  @override
  Future<List<ResumeVersion>> listVersions(String documentId) =>
      delegate.listVersions(documentId);
}
