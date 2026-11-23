import 'dart:io';

import 'package:entitlements/entitlements.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/local_agent_composition.dart';
import 'support/local_suggestion_fixture.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';
import 'package:resume_all_in_one_client/src/remote_resume_ai_service.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';
import 'package:resume_all_in_one_client/src/resume_workspace_controller.dart';

void main() {
  late LocalStorageDatabase database;
  late DriftResumeRepository resumeRepository;
  late Directory temporaryDirectory;
  late ResumeWorkspaceController controller;

  setUp(() async {
    database = LocalStorageDatabase.inMemory();
    resumeRepository = DriftResumeRepository(database);
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'privacy-local-data-controller-test-',
    );
    final remoteAccountService = RemoteAccountService(gatewayApi: null);
    controller = ResumeWorkspaceController(
      repository: resumeRepository,
      settingsRepository: DriftAppSettingsRepository(database),
      localAgentCheckService: createOfflineLocalAgentCheckService(
        resumeRepository: resumeRepository,
        auditRepository: DriftAgentAuditRepository(database),
        clock: () => DateTime.utc(2026, 10, 2, 8),
      ),
      localResumeSuggestionService: createOfflineLocalResumeSuggestionService(
        resumeRepository: resumeRepository,
        auditRepository: DriftAgentAuditRepository(database),
        clock: () => DateTime.utc(2026, 10, 2, 8),
      ),
      localDataManagementService: LocalDataManagementService(
        repository: DriftLocalDataRepository(database),
        rootDirectory: () async => temporaryDirectory,
        clock: () => DateTime.utc(2026, 10, 2, 9),
      ),
      accessPolicy: CapabilityAccessPolicy.mvp(),
      fileExporter: ResumeFileExporter(
        rootDirectory: () async => temporaryDirectory,
      ),
      importFilePicker: const SystemResumeImportFilePicker(),
      remoteAccountService: remoteAccountService,
      remoteResumeAiService: RemoteResumeAiService(
        accountService: remoteAccountService,
      ),
      clock: () => DateTime.utc(2026, 10, 2, 8),
    );
    await controller.initialize();
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('全量导出覆盖本地事实并在清空数据库后保留备份文件', () async {
    await controller.createDocument(title: '隐私测试简历', fullName: '张三');
    await controller.runLocalAgentCheck();
    await controller.setNetworkEnabled(true);

    final exportResult = await controller.exportAllLocalData();

    expect(exportResult, isNotNull);
    expect(exportResult!.summary.documentCount, 1);
    expect(exportResult.summary.versionCount, 1);
    expect(exportResult.summary.settingCount, 1);
    expect(exportResult.summary.agentRunCount, 1);
    expect(exportResult.summary.toolCallCount, 2);
    final reparsedSummary = const LocalDataArchiveCodec().decode(
      await exportResult.file.readAsString(),
    );
    expect(reparsedSummary.documentCount, 1);
    expect(reparsedSummary.agentRunCount, 1);

    final draftGeneration = controller.remoteDraftGeneration;
    final clearResult = await controller.clearAllLocalData();

    expect(clearResult, isNotNull);
    expect(controller.remoteDraftGeneration, greaterThan(draftGeneration));
    expect(clearResult!.documentCount, 1);
    expect(clearResult.versionCount, 1);
    expect(clearResult.settingCount, 1);
    expect(clearResult.agentRunCount, 1);
    expect(clearResult.toolCallCount, 2);
    expect(controller.documents, isEmpty);
    expect(controller.currentDocument, isNull);
    expect(controller.networkEnabled, isFalse);
    expect(controller.message, contains('已清空 1 份简历、1 个版本和 1 条 Agent 审计'));
    expect(await exportResult.file.exists(), isTrue);
    final emptySnapshot = await DriftLocalDataRepository(
      database,
    ).readSnapshot();
    expect(emptySnapshot.resumes, isEmpty);
    expect(emptySnapshot.settings, isEmpty);
    expect(emptySnapshot.agentAudits, isEmpty);
    expect(
      controller.capabilityDecisions
          .singleWhere(
            (decision) =>
                decision.capability == ProductCapability.cloudAiRewrite,
          )
          .status,
      AccessDecisionStatus.networkDisabled,
    );
  });

  test('按 ID 删除非当前简历不打断编辑，删除当前简历才退出编辑', () async {
    await controller.createDocument(title: '第一份简历', fullName: '张三');
    final firstDocumentId = controller.currentDocument!.id;
    await controller.createDocument(title: '第二份简历', fullName: '李四');
    final secondDocumentId = controller.currentDocument!.id;

    expect(
      await controller.deleteDocument(firstDocumentId),
      DocumentLifecycleOutcome.completed,
    );
    expect(controller.documents.map((document) => document.id), [
      secondDocumentId,
    ]);
    expect(controller.currentDocument!.id, secondDocumentId);

    expect(
      await controller.deleteDocument(secondDocumentId),
      DocumentLifecycleOutcome.completed,
    );
    expect(controller.documents, isEmpty);
    expect(controller.currentDocument, isNull);
    expect(controller.currentVersion, isNull);
  });
}
