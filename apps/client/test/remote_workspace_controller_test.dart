import 'dart:io';

import 'package:entitlements/entitlements.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/local_agent_composition.dart';
import 'support/local_suggestion_fixture.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';
import 'package:resume_all_in_one_client/src/remote_resume_ai_service.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';
import 'package:resume_all_in_one_client/src/resume_workspace_controller.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  test('基础生成在人工确认前不写库，确认后创建 aiConfirmed 首版本', () async {
    final database = LocalStorageDatabase.inMemory();
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'remote-workspace-controller-test-',
    );
    final gatewayApi = _ControllerGatewayApi(semanticReview: true);
    final controller = _createController(
      database: database,
      temporaryDirectory: temporaryDirectory,
      gatewayApi: gatewayApi,
    );
    addTearDown(() async {
      controller.dispose();
      await database.close();
      await temporaryDirectory.delete(recursive: true);
    });
    await controller.initialize();
    await controller.setNetworkEnabled(true);
    await controller.setRemotePersonalDataWarningAcknowledged(true);
    expect(
      await controller.registerRemoteAccount(
        phoneE164: '+15550001234',
        password: 'TestPass2026!',
      ),
      isTrue,
    );

    final pendingChange = await controller.prepareBasicRemoteResume(
      BasicResumeComposeDraft(
        documentTitle: '远程生成简历',
        sourceText: '负责 Flutter 客户端开发',
        fullName: '张三',
        phone: '',
        email: '',
        preciseAddress: '',
      ),
    );

    expect(pendingChange, isNotNull);
    expect(await DriftResumeRepository(database).listDocuments(), isEmpty);
    expect(pendingChange!.requiresSemanticReview, isTrue);
    expect(await controller.acceptPendingRemoteChange(), isFalse);
    expect(await DriftResumeRepository(database).listDocuments(), isEmpty);
    expect(controller.pendingRemoteResumeChange, same(pendingChange));
    expect(
      await controller.acceptPendingRemoteChange(confirmedSemanticReview: true),
      isTrue,
    );
    expect(controller.currentVersion!.source, ResumeVersionSource.aiConfirmed);
    expect(
      ResumeAiProvenance.fromResume(
        controller.currentVersion!.content,
      )!.operationId,
      pendingChange.operationId,
    );
    expect(controller.currentVersion!.content.profile.fullName, '张三');
    expect(
      ResumeAigcMetadata.fromResume(
        controller.currentVersion!.content,
      )!.contentProducer,
      'Ji Ouqi',
    );
    expect(controller.documents, hasLength(1));
    expect(
      controller
          .remoteAccountSnapshot
          .accessByCapability[RemoteAiCapability.basicResumeCompose]!
          .remainingMonthlyBasicGenerations,
      9,
    );
    final originalAi = controller.currentVersion!.content;
    final edited = originalAi.toJson();
    (edited['profile']! as Map)['headline'] = '手工调整后的岗位';
    expect(
      await controller.saveContent(
        title: controller.currentDocument!.title,
        content: ResumeData.fromJson(edited),
      ),
      SaveOutcome.saved,
    );
    expect(
      ResumeAiProvenance.fromResume(
        controller.currentVersion!.content,
      )!.operationId,
      pendingChange.operationId,
    );
    expect(
      ResumeAigcMetadata.fromResume(
        controller.currentVersion!.content,
      )!.propagateId,
      pendingChange.operationId,
    );
    expect(
      await controller.duplicateCurrent(),
      DocumentLifecycleOutcome.completed,
    );
    expect(
      ResumeAiProvenance.fromResume(
        controller.currentVersion!.content,
      )!.operationId,
      pendingChange.operationId,
    );
    expect(
      ResumeAigcMetadata.fromResume(
        controller.currentVersion!.content,
      )!.contentProducer,
      'Ji Ouqi',
    );
  });

  test('未确认隐私提醒时不发起远程生成', () async {
    final database = LocalStorageDatabase.inMemory();
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'remote-privacy-gate-test-',
    );
    final gatewayApi = _ControllerGatewayApi();
    final controller = _createController(
      database: database,
      temporaryDirectory: temporaryDirectory,
      gatewayApi: gatewayApi,
    );
    addTearDown(() async {
      controller.dispose();
      await database.close();
      await temporaryDirectory.delete(recursive: true);
    });
    await controller.initialize();
    await controller.setNetworkEnabled(true);
    await controller.signInRemoteAccount(
      phoneE164: '+15550001234',
      password: 'TestPass2026!',
    );

    final pendingChange = await controller.prepareBasicRemoteResume(
      BasicResumeComposeDraft(
        documentTitle: '远程生成简历',
        sourceText: '负责 Flutter 客户端开发',
        fullName: '',
        phone: '',
        email: '',
        preciseAddress: '',
      ),
    );

    expect(pendingChange, isNull);
    expect(controller.formError, contains('隐私提醒'));
    expect(gatewayApi.remoteRequestCount, 0);
  });
}

ResumeWorkspaceController _createController({
  required LocalStorageDatabase database,
  required Directory temporaryDirectory,
  required GatewayApi gatewayApi,
}) {
  final resumeRepository = DriftResumeRepository(database);
  final auditRepository = DriftAgentAuditRepository(database);
  final remoteAccountService = RemoteAccountService(
    gatewayApi: gatewayApi,
    clock: () => DateTime.utc(2026, 10, 3, 12),
  );
  return ResumeWorkspaceController(
    repository: resumeRepository,
    settingsRepository: DriftAppSettingsRepository(database),
    localAgentCheckService: createOfflineLocalAgentCheckService(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
    ),
    localResumeSuggestionService: createOfflineLocalResumeSuggestionService(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
    ),
    localDataManagementService: LocalDataManagementService(
      repository: DriftLocalDataRepository(database),
      rootDirectory: () async => temporaryDirectory,
    ),
    accessPolicy: CapabilityAccessPolicy.mvp(),
    fileExporter: ResumeFileExporter(
      rootDirectory: () async => temporaryDirectory,
    ),
    importFilePicker: const SystemResumeImportFilePicker(),
    remoteAccountService: remoteAccountService,
    remoteResumeAiService: RemoteResumeAiService(
      accountService: remoteAccountService,
      nextId: _SequentialIds().next,
    ),
    clock: () => DateTime.utc(2026, 10, 3, 12),
  );
}

final class _SequentialIds {
  int _value = 0;

  String next(String namespace) => '$namespace-${++_value}';
}

final class _ControllerGatewayApi implements GatewayApi {
  _ControllerGatewayApi({this.semanticReview = false});

  final bool semanticReview;
  int remoteRequestCount = 0;

  @override
  Future<void> registerFakeAccount({
    required String phoneE164,
    required String password,
  }) async {}

  @override
  Future<GatewaySession> createSession({
    required String phoneE164,
    required String password,
  }) async {
    return GatewaySession(
      token: 'session-token',
      expiresAtUtc: DateTime.utc(2026, 11, 3, 12),
    );
  }

  @override
  Future<GatewayAccessSnapshot> readAccess({
    required RemoteAiCapability capability,
    required String sessionToken,
  }) async {
    return GatewayAccessSnapshot(
      capability: capability,
      plan: GatewaySubscriptionPlan.free,
      allowed: capability == RemoteAiCapability.basicResumeCompose,
      reason: capability == RemoteAiCapability.basicResumeCompose
          ? 'allowed'
          : 'subscription_required',
      remainingMonthlyBasicGenerations:
          capability == RemoteAiCapability.basicResumeCompose
          ? 10 - remoteRequestCount
          : null,
    );
  }

  @override
  Future<GatewayRemoteAiResponse> submitRemoteAiRequest({
    required String sessionToken,
    required String clientRequestId,
    required String idempotencyKey,
    required RemoteAiCapability capability,
    required Map<String, Object?> input,
  }) async {
    remoteRequestCount++;
    return GatewayRemoteAiResponse(
      operationId: 'operation-$remoteRequestCount',
      aigcMetadata: ResumeAigcMetadata.firstGeneration(
        providerName: 'Ji Ouqi',
        contentId: 'operation-$remoteRequestCount',
      ),
      clientRequestId: clientRequestId,
      capability: capability,
      output: {
        ..._basicComposeOutput(),
        if (semanticReview) 'warnings': [remoteSemanticReviewWarning],
      },
      promptVersion: 'basic-resume-compose.v1',
    );
  }

  @override
  void close() {}
}

Map<String, Object?> _basicComposeOutput() => {
  'outputVersion': 'basicResumeCompose.v1',
  'summary': '已整理为基础简历。',
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
