import 'dart:io';

import 'package:entitlements/entitlements.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/local_agent_composition.dart';
import 'support/local_suggestion_fixture.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';
import 'package:resume_all_in_one_client/src/remote_resume_ai_service.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_home_page.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';
import 'package:resume_all_in_one_client/src/resume_workspace_controller.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  late LocalStorageDatabase database;
  late _FailOnceRepository repository;
  late _RecoveryGatewayApi gateway;
  late ResumeWorkspaceController controller;

  setUp(() async {
    database = LocalStorageDatabase.inMemory();
    repository = _FailOnceRepository(DriftResumeRepository(database));
    gateway = _RecoveryGatewayApi();
    final accountService = RemoteAccountService(
      gatewayApi: gateway,
      clock: () => DateTime.utc(2026, 10, 5),
    );
    controller = ResumeWorkspaceController(
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
        repository: DriftLocalDataRepository(database),
        rootDirectory: () async => Directory.systemTemp,
      ),
      accessPolicy: CapabilityAccessPolicy.mvp(),
      fileExporter: ResumeFileExporter(
        rootDirectory: () async => Directory.systemTemp,
      ),
      importFilePicker: const SystemResumeImportFilePicker(),
      remoteAccountService: accountService,
      remoteResumeAiService: RemoteResumeAiService(
        accountService: accountService,
      ),
      clock: () => DateTime.utc(2026, 10, 5),
    );
    await controller.initialize();
    await controller.setNetworkEnabled(true);
    await controller.setRemotePersonalDataWarningAcknowledged(true);
    await controller.signInRemoteAccount(
      phoneE164: '+15550001234',
      password: 'TestPass2026!',
    );
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
  });

  test('关闭控制器并重登恢复候选，断网确认后再重启不恢复', () async {
    controller.dispose();
    gateway = _PersistentRecoveryGatewayApi();
    controller = _persistentController(database, gateway);
    await controller.initialize();
    await controller.signInRemoteAccount(
      phoneE164: '+15550001234',
      password: 'TestPass2026!',
    );
    await controller.prepareBasicRemoteResume(
      BasicResumeComposeDraft(
        documentTitle: '恢复测试',
        sourceText: '参与接口开发',
        fullName: '',
        phone: '',
        email: '',
        preciseAddress: '',
      ),
    );
    expect(gateway.requestCount, 1);
    controller.dispose();
    controller = _persistentController(database, gateway);
    await controller.initialize();
    expect(
      controller.pendingRemoteResumeChange,
      isNull,
      reason: '未登录不能显示其他账号候选',
    );
    await controller.signInRemoteAccount(
      phoneE164: '+15550001234',
      password: 'TestPass2026!',
    );
    expect(controller.pendingRemoteResumeChange, isNotNull);
    await controller.setNetworkEnabled(false);
    expect(await controller.acceptPendingRemoteChange(), isTrue);
    expect(gateway.requestCount, 1);
    expect(await repository.listDocuments(), hasLength(1));
    await controller.restoreRemoteReview();
    expect(controller.pendingRemoteResumeChange, isNull);
  });

  test('候选保存和拒绝的磁盘故障明确保留当前审阅，重试不调用模型', () async {
    controller.dispose();
    gateway = _PersistentRecoveryGatewayApi();
    final reviews = _FaultReviewRepository(database);
    controller = _persistentController(database, gateway, reviews: reviews);
    await controller.initialize();
    await controller.signInRemoteAccount(
      phoneE164: '+15550001234',
      password: 'TestPass2026!',
    );
    reviews.failSave = true;
    await controller.prepareBasicRemoteResume(
      BasicResumeComposeDraft(
        documentTitle: '磁盘测试',
        sourceText: '参与接口开发',
        fullName: '',
        phone: '',
        email: '',
        preciseAddress: '',
      ),
    );
    expect(controller.pendingRemoteResumeChange, isNotNull);
    expect(controller.latestRemoteWarnings.join(), contains('未能保存'));
    reviews.failDiscard = true;
    expect(await controller.rejectPendingRemoteChange(), isFalse);
    expect(controller.pendingRemoteResumeChange, isNotNull);
    expect(await controller.rejectPendingRemoteChange(), isTrue);
    expect(gateway.requestCount, 1);
    expect(await repository.listDocuments(), isEmpty);
  });

  test('提交成功但返回链故障，重复人工确认识别凭据，不新增第二份简历', () async {
    controller.dispose();
    gateway = _PersistentRecoveryGatewayApi();
    final reviews = _FaultReviewRepository(database);
    controller = _persistentController(database, gateway, reviews: reviews);
    await controller.initialize();
    await controller.signInRemoteAccount(
      phoneE164: '+15550001234',
      password: 'TestPass2026!',
    );
    await controller.prepareBasicRemoteResume(
      BasicResumeComposeDraft(
        documentTitle: '回执测试',
        sourceText: '参与接口开发',
        fullName: '',
        phone: '',
        email: '',
        preciseAddress: '',
      ),
    );
    reviews.failAfterCommit = true;
    expect(await controller.acceptPendingRemoteChange(), isFalse);
    expect(await repository.listDocuments(), hasLength(1));
    expect(await controller.acceptPendingRemoteChange(), isTrue);
    expect(await repository.listDocuments(), hasLength(1));
    expect(gateway.requestCount, 1);
  });

  testWidgets('发送前被本地阻止时如实说明保存范围，返回编辑保留材料且不发请求', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ResumeHomePage(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _tap(tester, const Key('AI创建基础简历'));
    await tester.enterText(find.byKey(const Key('AI碎片信息')), '参与页面开发，月份待确认');
    await controller.setNetworkEnabled(false);
    await _tap(tester, const Key('提交基础生成'));
    expect(find.text('本次未生成候选'), findsOneWidget);
    expect(find.textContaining('本次输入仍保留在编辑窗口'), findsOneWidget);
    expect(find.textContaining('输入草稿已保留'), findsNothing);
    expect(gateway.requestCount, 0);
    expect(await controller.readUnfinishedAiTasks(), isEmpty);
    await tester.tap(find.text('返回编辑'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('AI碎片信息')))
          .controller!
          .text,
      '参与页面开发，月份待确认',
    );
    expect(gateway.requestCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('未提供账号标识的超时仍如实保留当前输入，返回编辑不再次生成', (tester) async {
    gateway.failWithTimeout = true;
    await tester.pumpWidget(
      MaterialApp(home: ResumeHomePage(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _tap(tester, const Key('AI创建基础简历'));
    await tester.enterText(
      find.byKey(const Key('AI碎片信息')),
      '去年和同学做过页面，具体月份记不清',
    );
    await _tap(tester, const Key('提交基础生成'));
    expect(find.text('本次未生成候选'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(
      find.textContaining('本次输入仍保留在编辑窗口'),
      findsOneWidget,
      reason: find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .join('|'),
    );
    expect(gateway.requestCount, 1);
    expect(await repository.listDocuments(), isEmpty);
    await tester.tap(find.text('返回编辑'));
    await tester.pumpAndSettle();
    expect(find.text('去年和同学做过页面，具体月份记不清'), findsOneWidget);
    expect(gateway.requestCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final existingDocument in [false, true]) {
    testWidgets('${existingDocument ? '远程追加' : '远程创建'}提交后刷新失败仍关闭审阅，不能重复确认', (
      tester,
    ) async {
      if (existingDocument) {
        await controller.createDocument(title: '原始简历', fullName: '测试姓名');
      }
      await tester.pumpWidget(
        MaterialApp(home: ResumeHomePage(controller: controller)),
      );
      await tester.pumpAndSettle();
      if (existingDocument) {
        await _openAiTask(tester);
        await _tap(tester, const Key('按目标岗位优化'));
        await tester.enterText(find.byKey(const Key('目标岗位输入框')), 'Flutter 工程师');
        await _tap(tester, const Key('提交岗位优化'));
      } else {
        await _tap(tester, const Key('AI创建基础简历'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('简历标题输入框')));
        await tester.enterText(find.byKey(const Key('简历标题输入框')), 'AI 生成简历');
        await tester.enterText(
          find.byKey(const Key('AI碎片信息')),
          '负责 Flutter 客户端开发',
        );
        await _tap(tester, const Key('提交基础生成'));
      }
      repository.writeAttempts = 0;
      repository.failReadAfterWrite = true;
      await _tap(tester, const Key('确认远程建议'));
      expect(find.text('审阅联网 AI 建议'), findsNothing);
      expect(find.textContaining('界面刷新失败'), findsOneWidget);
      expect(controller.pendingRemoteResumeChange, isNull);
      expect(
        controller.currentVersion!.source,
        ResumeVersionSource.aiConfirmed,
      );
      expect(
        controller.currentVersion!.content.profile.headline,
        'Flutter 工程师',
      );
      expect(await repository.listDocuments(), hasLength(1));
      expect(
        await repository.listVersions(controller.currentDocument!.id),
        hasLength(existingDocument ? 2 : 1),
      );
      expect(await controller.acceptPendingRemoteChange(), isFalse);
      expect(repository.writeAttempts, 1);
      expect(gateway.requestCount, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final retry in [false, true]) {
      final flowName = existingDocument ? '岗位优化追加版本' : 'AI 起草创建简历';
      final recovery = retry ? '再次人工确认后只保存一次' : '拒绝建议后解除等待状态';
      testWidgets('$flowName写入失败仍可审阅，$recovery', (tester) async {
        try {
          if (existingDocument) {
            await controller.createDocument(title: '原始简历', fullName: '测试姓名');
          }
          final originalVersion = controller.currentVersion;
          repository.writeAttempts = 0;
          repository.failNextWrite = true;

          await tester.pumpWidget(
            MaterialApp(home: ResumeHomePage(controller: controller)),
          );
          await tester.pumpAndSettle();
          if (existingDocument) {
            await _openAiTask(tester);
            await _tap(tester, const Key('按目标岗位优化'));
            await tester.enterText(
              find.byKey(const Key('目标岗位输入框')),
              'Flutter 工程师',
            );
            await _tap(tester, const Key('提交岗位优化'));
          } else {
            await _tap(tester, const Key('AI创建基础简历'));
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.byKey(const Key('简历标题输入框')));
            await tester.enterText(find.byKey(const Key('简历标题输入框')), 'AI 生成简历');
            await tester.enterText(
              find.byKey(const Key('AI碎片信息')),
              '负责 Flutter 客户端开发',
            );
            await _tap(tester, const Key('提交基础生成'));
          }
          expect(find.text('审阅联网 AI 建议'), findsOneWidget);
          expect(gateway.requestCount, 1);
          expect(repository.writeAttempts, 0);

          await _tap(tester, const Key('确认远程建议'));
          expect(find.text('审阅联网 AI 建议'), findsOneWidget);
          expect(controller.pendingRemoteResumeChange, isNotNull);
          expect(repository.writeAttempts, 1);
          expect(controller.currentVersion?.id, originalVersion?.id);
          expect(
            await repository.listDocuments(),
            hasLength(existingDocument ? 1 : 0),
          );
          await tester.pump(const Duration(seconds: 2));
          expect(repository.writeAttempts, 1, reason: '重新显示审阅不自动重试写库');
          expect(gateway.requestCount, 1, reason: '本地保存失败不重新消耗远程请求');

          await _tap(tester, Key(retry ? '确认远程建议' : '拒绝远程建议'));
          expect(find.text('审阅联网 AI 建议'), findsNothing);
          expect(controller.pendingRemoteResumeChange, isNull);
          expect(repository.writeAttempts, retry ? 2 : 1);
          expect(gateway.requestCount, 1);
          if (retry) {
            expect(
              controller.currentVersion!.source,
              ResumeVersionSource.aiConfirmed,
            );
            expect(
              controller.currentVersion!.content.profile.headline,
              'Flutter 工程师',
            );
            expect(controller.versions, hasLength(existingDocument ? 2 : 1));
          } else {
            expect(controller.currentVersion?.id, originalVersion?.id);
            expect(
              await repository.listDocuments(),
              hasLength(existingDocument ? 1 : 0),
            );
          }
          if (existingDocument || retry) {
            if (existingDocument) await _tap(tester, const Key('AI返回手工编辑'));
            expect(
              tester
                  .widget<FilledButton>(find.byKey(const Key('保存新版本')))
                  .onPressed,
              isNotNull,
            );
            await _tap(tester, const Key('返回简历列表'));
            expect(controller.currentDocument, isNull);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      });
    }
  }
}

Future<void> _openAiTask(WidgetTester tester) async {
  expect(find.byKey(const Key('按目标岗位优化')), findsNothing);
  await _tap(tester, const Key('返回简历列表'));
  await _tap(tester, const Key('导航_助手'));
  await _tap(tester, const Key('AI选择已有简历'));
  expect(find.byType(SimpleDialogOption), findsOneWidget);
  await tester.tap(find.byType(SimpleDialogOption));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

final class _FailOnceRepository implements ResumeRepository {
  _FailOnceRepository(this.delegate);

  final ResumeRepository delegate;
  bool failNextWrite = false;
  bool failReadAfterWrite = false;
  bool _failNextRead = false;
  int writeAttempts = 0;

  void _beforeWrite() {
    writeAttempts++;
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('synthetic recoverable write failure');
    }
  }

  @override
  Future<void> createDocument(
    ResumeDocument document,
    ResumeVersion initialVersion,
  ) async {
    _beforeWrite();
    await delegate.createDocument(document, initialVersion);
    _failNextRead = failReadAfterWrite;
    failReadAfterWrite = false;
  }

  @override
  Future<void> saveVersion({
    required ResumeDocument document,
    required ResumeVersion version,
    required String expectedCurrentVersionId,
  }) async {
    _beforeWrite();
    await delegate.saveVersion(
      document: document,
      version: version,
      expectedCurrentVersionId: expectedCurrentVersionId,
    );
    _failNextRead = failReadAfterWrite;
    failReadAfterWrite = false;
  }

  @override
  Future<bool> deleteDocument(String documentId) =>
      delegate.deleteDocument(documentId);
  @override
  Future<ResumeVersion?> findCurrentVersion(String documentId) =>
      delegate.findCurrentVersion(documentId);
  @override
  Future<ResumeDocument?> findDocument(String documentId) =>
      delegate.findDocument(documentId);
  @override
  Future<ResumeVersion?> findVersion(String versionId) =>
      delegate.findVersion(versionId);
  @override
  Future<List<ResumeDocument>> listDocuments() async {
    if (_failNextRead) {
      _failNextRead = false;
      throw StateError('synthetic read failure after commit');
    }
    return delegate.listDocuments();
  }

  @override
  Future<List<ResumeVersion>> listVersions(String documentId) =>
      delegate.listVersions(documentId);
}

class _RecoveryGatewayApi implements GatewayApi {
  int requestCount = 0;
  bool failWithTimeout = false;

  @override
  Future<GatewaySession> createSession({
    required String phoneE164,
    required String password,
  }) async => GatewaySession(
    token: 'synthetic-session',
    expiresAtUtc: DateTime.utc(2026, 11, 1),
  );

  @override
  Future<void> registerFakeAccount({
    required String phoneE164,
    required String password,
  }) async {}

  @override
  Future<GatewayAccessSnapshot> readAccess({
    required RemoteAiCapability capability,
    required String sessionToken,
  }) async => GatewayAccessSnapshot(
    capability: capability,
    plan: GatewaySubscriptionPlan.pro,
    allowed: true,
    reason: 'allowed',
    remainingMonthlyBasicGenerations: null,
  );

  @override
  Future<GatewayRemoteAiResponse> submitRemoteAiRequest({
    required String sessionToken,
    required String clientRequestId,
    required String idempotencyKey,
    required RemoteAiCapability capability,
    required Map<String, Object?> input,
  }) async {
    requestCount++;
    if (failWithTimeout) {
      throw const GatewayApiException(
        code: 'provider_timeout',
        message: '远程调用结果尚不确定',
        retryable: false,
      );
    }
    final basic = capability == RemoteAiCapability.basicResumeCompose;
    return GatewayRemoteAiResponse(
      operationId: 'recovery-operation-$requestCount',
      clientRequestId: clientRequestId,
      capability: capability,
      promptVersion: basic
          ? 'basic-resume-compose.v1'
          : 'targeted-resume-optimization.v1',
      output: basic ? _basicOutput : _optimizationOutput,
    );
  }

  @override
  void close() {}
}

final _basicOutput = <String, Object?>{
  'outputVersion': 'basicResumeCompose.v1',
  'summary': '已按用户片段整理。',
  'candidateResume': {
    'schemaVersion': currentResumeSchemaVersion,
    'profile': {
      'id': 'profile-remote',
      'headline': 'Flutter 工程师',
      'coarseLocation': '',
    },
    'workExperiences': <Object?>[],
    'educations': <Object?>[],
    'projects': <Object?>[],
    'skillGroups': <Object?>[],
    'certifications': <Object?>[],
    'languages': <Object?>[],
    'customSections': <Object?>[],
  },
  'sourceReferences': [
    {
      'path': '/profile/headline',
      'fragmentIds': ['fragment-1'],
    },
  ],
  'missingInformation': <Object?>[],
  'warnings': <Object?>[],
};

final _optimizationOutput = <String, Object?>{
  'outputVersion': 'targetedResumeOptimization.v1',
  'summary': '请核对新的职业标题。',
  'proposedPatch': {
    'operations': [
      {
        'type': 'replace',
        'path': '/profile/headline',
        'oldValue': '',
        'newValue': 'Flutter 工程师',
        'reason': '对齐用户选择的目标岗位。',
        'source': 'remoteAi',
        'category': 'wording',
      },
    ],
  },
  'missingInformation': <Object?>[],
  'warnings': <Object?>[],
  'nextAction': 'reviewPatch',
};

ResumeWorkspaceController _persistentController(
  LocalStorageDatabase database,
  GatewayApi gateway, {
  DriftRemoteReviewRepository? reviews,
}) {
  final repository = DriftResumeRepository(database);
  final account = RemoteAccountService(
    gatewayApi: gateway,
    clock: () => DateTime.utc(2026, 10, 9),
  );
  reviews ??= DriftRemoteReviewRepository(database);
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
      repository: DriftLocalDataRepository(database),
      rootDirectory: () async => Directory.systemTemp,
    ),
    accessPolicy: CapabilityAccessPolicy.mvp(),
    fileExporter: ResumeFileExporter(
      rootDirectory: () async => Directory.systemTemp,
    ),
    importFilePicker: const SystemResumeImportFilePicker(),
    remoteAccountService: account,
    remoteResumeAiService: RemoteResumeAiService(
      accountService: account,
      reviewRepository: reviews,
    ),
    reviewRepository: reviews,
    clock: () => DateTime.utc(2026, 10, 9),
  );
}

final class _FaultReviewRepository extends DriftRemoteReviewRepository {
  _FaultReviewRepository(super.database);
  bool failSave = false;
  bool failDiscard = false;
  bool failAfterCommit = false;
  @override
  Future<void> saveReview(
    String accountId,
    String recordId,
    String? documentId,
    String payload,
    DateTime expiresAt,
  ) async {
    if (failSave) {
      failSave = false;
      throw const FileSystemException('synthetic disk failure');
    }
    await super.saveReview(accountId, recordId, documentId, payload, expiresAt);
  }

  @override
  Future<void> discardReview(String id) async {
    if (failDiscard) {
      failDiscard = false;
      throw const FileSystemException('synthetic disk failure');
    }
    await super.discardReview(id);
  }

  @override
  Future<void> commitReview({
    required String recordId,
    required ResumeDocument document,
    required ResumeVersion version,
    String? expectedVersionId,
  }) async {
    await super.commitReview(
      recordId: recordId,
      document: document,
      version: version,
      expectedVersionId: expectedVersionId,
    );
    if (failAfterCommit) {
      failAfterCommit = false;
      throw StateError('synthetic post-commit failure');
    }
  }
}

final class _PersistentRecoveryGatewayApi extends _RecoveryGatewayApi
    implements GatewayOperationApi {
  @override
  Future<String> readAccountId({required String sessionToken}) async =>
      'synthetic-owner';
  @override
  Future<GatewayOperationStatus> lookupOperation({
    required String sessionToken,
    required RemoteAiCapability capability,
    String? usageOperationId,
    String? idempotencyKey,
  }) async => throw UnimplementedError();
}
