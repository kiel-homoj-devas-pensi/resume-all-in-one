import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:agent_runtime/agent_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:model_router/model_router.dart';
import 'package:resume_all_in_one_client/src/local_agent_check_service.dart';
import 'package:resume_domain/resume_domain.dart';

final _testTime = DateTime.utc(2026, 10, 2, 10, 0, 0, 123, 456);

void main() {
  late LocalStorageDatabase database;
  late DriftResumeRepository resumeRepository;
  late DriftAgentAuditRepository auditRepository;
  late int idCounter;

  setUp(() async {
    database = LocalStorageDatabase.inMemory();
    resumeRepository = DriftResumeRepository(database);
    auditRepository = DriftAgentAuditRepository(database);
    idCounter = 0;
    await _seedResume(resumeRepository);
  });

  tearDown(() => database.close());

  String nextId(String namespace) => '$namespace-${++idCounter}';

  test('离线本地计划只接收版本元数据并完成两项只读检查', () async {
    ModelRequest? capturedRequest;
    final service = _service(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
      nextId: nextId,
      generate: (request) async {
        capturedRequest = request;
        return _validResponse(request);
      },
    );

    final checkResult = await service.checkSavedVersion(
      documentId: 'document-001',
      resumeVersionId: 'version-001',
      networkEnabled: false,
    );

    expect(checkResult.status, LocalAgentCheckStatus.completed);
    expect(checkResult.executedToolCount, 2);
    expect(checkResult.validationIssueCount, 0);
    expect(checkResult.repeatedContentGroupCount, 1);
    expect(capturedRequest!.privacyPolicy, ModelPrivacyPolicy.localOnly);
    expect(capturedRequest!.input.keys, {
      'documentId',
      'resumeVersionId',
      'intent',
    });
    expect(capturedRequest!.input.toString(), isNot(contains('敏感姓名')));
    expect(capturedRequest!.tools.map((tool) => tool.name), [
      'find_repeated_content',
      'validate_resume',
    ]);

    final storedRun = await auditRepository.findRun('agent-run-1');
    final storedCalls = await auditRepository.listToolCalls('agent-run-1');
    expect(storedRun!.status, LocalAgentCheckStatus.completed.name);
    expect(storedRun.routeStatus, ModelRouteStatus.selected.name);
    expect(storedCalls, hasLength(2));
    expect(
      storedCalls.map((toolCall) => toolCall.toolName),
      containsAll(['validate_resume', 'find_repeated_content']),
    );
  });

  test('Provider 返回未知工具时拒绝整个计划且不执行工具', () async {
    final service = _service(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
      nextId: nextId,
      generate: (request) async => _responseForPlan(
        AgentPlan(
          actions: [
            ToolCall(
              callId: '${request.requestId}-illegal',
              toolName: 'run_shell',
              arguments: const {'versionId': 'version-001'},
              requestedBy: 'test-provider',
              idempotencyKey: '${request.requestId}-illegal-key',
            ),
          ],
          requiresConfirmation: false,
          riskLevel: AgentRiskLevel.low,
        ),
      ),
    );

    final checkResult = await service.checkSavedVersion(
      documentId: 'document-001',
      resumeVersionId: 'version-001',
      networkEnabled: false,
    );

    expect(checkResult.status, LocalAgentCheckStatus.invalidPlan);
    expect(checkResult.errorCode, 'plan_not_allowed');
    expect(checkResult.executedToolCount, 0);
    expect(await auditRepository.listToolCalls('agent-run-1'), isEmpty);
  });

  test('计划缺少、重复只读工具或复用幂等键时不误报检查完成', () async {
    var planIndex = 0;
    final invalidPlans = [
      AgentPlan(
        actions: [_toolCall('missing-repeated', 'validate_resume')],
        requiresConfirmation: false,
        riskLevel: AgentRiskLevel.low,
      ),
      AgentPlan(
        actions: [
          _toolCall('duplicate-validate-1', 'validate_resume'),
          _toolCall('duplicate-validate-2', 'validate_resume'),
        ],
        requiresConfirmation: false,
        riskLevel: AgentRiskLevel.low,
      ),
      AgentPlan(
        actions: [
          _toolCall(
            'shared-key-validate',
            'validate_resume',
            idempotencyKey: 'shared-key',
          ),
          _toolCall(
            'shared-key-repeated',
            'find_repeated_content',
            idempotencyKey: 'shared-key',
          ),
        ],
        requiresConfirmation: false,
        riskLevel: AgentRiskLevel.low,
      ),
    ];
    final service = _service(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
      nextId: nextId,
      generate: (_) async => _responseForPlan(invalidPlans[planIndex++]),
    );

    for (var attempt = 0; attempt < invalidPlans.length; attempt++) {
      final checkResult = await service.checkSavedVersion(
        documentId: 'document-001',
        resumeVersionId: 'version-001',
        networkEnabled: false,
      );

      expect(checkResult.status, LocalAgentCheckStatus.invalidPlan);
      expect(checkResult.errorCode, 'plan_not_allowed');
      expect(checkResult.executedToolCount, 0);
    }
  });

  test('Provider 能力不足返回可解释状态并写入零工具审计', () async {
    final service = _service(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
      nextId: nextId,
      capabilities: const {ModelCapability.textGeneration},
    );

    final checkResult = await service.checkSavedVersion(
      documentId: 'document-001',
      resumeVersionId: 'version-001',
      networkEnabled: false,
    );

    expect(checkResult.status, LocalAgentCheckStatus.capabilityUnavailable);
    expect(checkResult.errorCode, 'route_capability_unavailable');
    expect((await auditRepository.findRun('agent-run-1'))!.toolCallCount, 0);
  });

  test('预先取消不调用 Provider 并返回 cancelled', () async {
    var providerWasCalled = false;
    final service = _service(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
      nextId: nextId,
      generate: (request) async {
        providerWasCalled = true;
        return _validResponse(request);
      },
    );
    final cancellationToken = LocalAgentCancellationToken()..cancel();

    final checkResult = await service.checkSavedVersion(
      documentId: 'document-001',
      resumeVersionId: 'version-001',
      networkEnabled: false,
      cancellationToken: cancellationToken,
    );

    expect(checkResult.status, LocalAgentCheckStatus.cancelled);
    expect(providerWasCalled, isFalse);
  });

  test('Provider 不返回时按上限结束且不自动重试', () async {
    var providerCallCount = 0;
    final service = _service(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
      nextId: nextId,
      providerTimeout: const Duration(milliseconds: 5),
      generate: (_) {
        providerCallCount++;
        return Completer<ModelResponse>().future;
      },
    );

    final checkResult = await service.checkSavedVersion(
      documentId: 'document-001',
      resumeVersionId: 'version-001',
      networkEnabled: false,
    );

    expect(checkResult.status, LocalAgentCheckStatus.timedOut);
    expect(checkResult.errorCode, 'provider_timeout');
    expect(providerCallCount, 1);
  });

  test('Provider 故障不暴露原始消息并返回稳定错误码', () async {
    final service = _service(
      resumeRepository: resumeRepository,
      auditRepository: auditRepository,
      nextId: nextId,
      generate: (_) async => throw const ModelProviderException(
        kind: ModelProviderFailureKind.unavailable,
        message: '包含内部路径与密钥的原始错误',
      ),
    );

    final checkResult = await service.checkSavedVersion(
      documentId: 'document-001',
      resumeVersionId: 'version-001',
      networkEnabled: false,
    );

    expect(checkResult.status, LocalAgentCheckStatus.providerFailed);
    expect(checkResult.errorCode, 'provider_failed');
    expect(
      (await auditRepository.findRun('agent-run-1'))!.errorCode,
      'provider_failed',
    );
  });
}

LocalAgentCheckService _service({
  required ResumeRepository resumeRepository,
  required AgentAuditRepository auditRepository,
  required String Function(String namespace) nextId,
  Set<ModelCapability> capabilities = const {
    ModelCapability.structuredOutput,
    ModelCapability.toolCalling,
  },
  Future<ModelResponse> Function(ModelRequest request)? generate,
  Duration providerTimeout = const Duration(seconds: 1),
}) {
  final runtime = AgentRuntime(
    repository: resumeRepository,
    now: () => _testTime,
    nextId: nextId,
  );
  final provider = FakeModelProvider(
    descriptor: ProviderDescriptor(
      providerKey: 'test-local-provider',
      location: ProviderLocation.local,
      capabilities: capabilities,
    ),
    generate: generate,
  );
  return LocalAgentCheckService(
    runtime: runtime,
    router: ModelRouter(
      ModelRegistry(
        registrations: [
          ProviderRegistration(provider: provider, modelId: 'test-model'),
        ],
      ),
    ),
    auditRepository: auditRepository,
    clock: () => _testTime,
    nextId: nextId,
    providerTimeout: providerTimeout,
  );
}

ModelResponse _validResponse(ModelRequest request) {
  final versionId = request.input['resumeVersionId']! as String;
  return _responseForPlan(
    AgentPlan(
      actions: [
        ToolCall(
          callId: '${request.requestId}-validate',
          toolName: 'validate_resume',
          arguments: {'versionId': versionId},
          requestedBy: 'test-provider',
          idempotencyKey: '${request.requestId}-validate-key',
        ),
        ToolCall(
          callId: '${request.requestId}-repeated',
          toolName: 'find_repeated_content',
          arguments: {'versionId': versionId},
          requestedBy: 'test-provider',
          idempotencyKey: '${request.requestId}-repeated-key',
        ),
      ],
      requiresConfirmation: false,
      riskLevel: AgentRiskLevel.low,
    ),
  );
}

ModelResponse _responseForPlan(AgentPlan plan) {
  return ModelResponse(
    text: 'test-plan',
    structuredData: plan.toJson(),
    usage: ModelUsage(inputTokens: 0, outputTokens: 0),
    finishReason: ModelFinishReason.completed,
  );
}

ToolCall _toolCall(String callId, String toolName, {String? idempotencyKey}) {
  return ToolCall(
    callId: callId,
    toolName: toolName,
    arguments: const {'versionId': 'version-001'},
    requestedBy: 'test-provider',
    idempotencyKey: idempotencyKey ?? '$callId-key',
  );
}

Future<void> _seedResume(ResumeRepository repository) async {
  final resumeContent = ResumeData(
    profile: ResumeProfile(
      id: 'profile-001',
      fullName: '敏感姓名',
      headline: 'Flutter 工程师',
      email: 'private@example.com',
      phone: '',
      location: '',
    ),
    workExperiences: [
      WorkExperience(
        id: 'work-001',
        organization: '示例公司',
        position: '工程师',
        dateRange: DateRange(
          start: ResumeDate(year: 2024),
          end: null,
          isCurrent: true,
        ),
        summary: '负责离线功能',
        highlights: const ['负责离线功能'],
      ),
    ],
  );
  final version = ResumeVersion(
    id: 'version-001',
    documentId: 'document-001',
    parentVersionId: null,
    schemaVersion: currentResumeSchemaVersion,
    content: resumeContent,
    source: ResumeVersionSource.created,
    createdAt: _testTime,
  );
  await repository.createDocument(
    ResumeDocument(
      id: 'document-001',
      title: '本地简历',
      currentVersionId: version.id,
      createdAt: _testTime,
      updatedAt: _testTime,
    ),
    version,
  );
}
