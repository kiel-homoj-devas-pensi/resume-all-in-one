import 'package:agent_protocol/agent_protocol.dart';
import 'package:model_router/model_router.dart';
import 'package:test/test.dart';

void main() {
  group('ModelRegistry', () {
    test('拒绝重复 Provider key，配置快照不可修改', () {
      final first = _registration(_provider('local'));
      final duplicate = _registration(_provider('local'));

      expect(
        () => ModelRegistry(registrations: [first, duplicate]),
        throwsArgumentError,
      );

      final registry = ModelRegistry(registrations: [first]);
      expect(() => registry.registrations.add(first), throwsUnsupportedError);
      expect(registry.find('local'), same(first));
    });
  });

  group('ModelRequest', () {
    test('结构化输入与能力集合不可变', () {
      final nested = <String, Object?>{
        'profile': <String, Object?>{'headline': 'Flutter 工程师'},
      };
      final capabilities = <ModelCapability>{ModelCapability.textGeneration};
      final request = _request(input: nested, capabilities: capabilities);

      (nested['profile']! as Map<String, Object?>)['headline'] = '已修改';
      capabilities.add(ModelCapability.toolCalling);

      expect(
        (request.input['profile']! as Map<String, Object?>)['headline'],
        'Flutter 工程师',
      );
      expect(
        () => request.requiredCapabilities.add(ModelCapability.toolCalling),
        throwsUnsupportedError,
      );
    });

    test('工具声明必须同时要求 toolCalling 能力', () {
      expect(() => _request(tools: [_toolDescriptor()]), throwsArgumentError);
    });
  });

  group('ModelRouter', () {
    test('本地优先于更高优先级的远程 Provider', () async {
      final local = _provider('local');
      final remote = _provider('remote', location: ProviderLocation.remote);
      final router = _router([
        _registration(remote, priority: 100, metered: true),
        _registration(local, priority: 0),
      ]);

      final decision = await router.route(
        _request(privacy: ModelPrivacyPolicy.remoteAllowed),
        ModelRoutingContext(networkEnabled: true, availableQuotaUnits: 10),
      );

      expect(decision.status, ModelRouteStatus.selected);
      expect(decision.selected!.providerKey, 'local');
      expect(local.healthCheckCount, 1);
      expect(remote.healthCheckCount, 0);
    });

    test('能力不足时不执行健康检查', () async {
      final provider = _provider('text-only');
      final decision = await _router([_registration(provider)]).route(
        _request(
          capabilities: const {
            ModelCapability.textGeneration,
            ModelCapability.structuredOutput,
          },
        ),
        _offlineContext,
      );

      expect(decision.status, ModelRouteStatus.capabilityUnavailable);
      expect(provider.healthCheckCount, 0);
      expect(
        decision.attempts.single.status,
        ModelCandidateStatus.capabilityMismatch,
      );
    });

    test('localOnly 在健康检查前阻断远程 Provider', () async {
      final remote = _provider('remote', location: ProviderLocation.remote);
      final decision = await _router([
        _registration(remote),
      ]).route(_request(), _onlineContext);

      expect(decision.status, ModelRouteStatus.privacyRestricted);
      expect(remote.healthCheckCount, 0);
    });

    test('联网关闭时返回 networkDisabled', () async {
      final remote = _provider('remote', location: ProviderLocation.remote);
      final decision = await _router([_registration(remote)]).route(
        _request(privacy: ModelPrivacyPolicy.remoteAllowed),
        _offlineContext,
      );

      expect(decision.status, ModelRouteStatus.networkDisabled);
      expect(remote.healthCheckCount, 0);
    });

    test('额度不足时返回 quotaExceeded', () async {
      final remote = _provider('metered', location: ProviderLocation.remote);
      final decision = await _router([_registration(remote, metered: true)])
          .route(
            _request(
              privacy: ModelPrivacyPolicy.remoteAllowed,
              estimatedQuotaUnits: 2,
            ),
            ModelRoutingContext(networkEnabled: true, availableQuotaUnits: 1),
          );

      expect(decision.status, ModelRouteStatus.quotaExceeded);
      expect(remote.healthCheckCount, 0);
    });

    test('首选 Provider 不健康时降级到后备 Provider', () async {
      final primary = _provider('primary', healthy: false);
      final fallback = _provider('fallback');
      final decision = await _router([
        _registration(primary, priority: 10),
        _registration(fallback),
      ]).route(_request(), _offlineContext);

      expect(decision.status, ModelRouteStatus.selected);
      expect(decision.selected!.providerKey, 'fallback');
      expect(decision.attempts.map((attempt) => attempt.status), [
        ModelCandidateStatus.unhealthy,
        ModelCandidateStatus.selected,
      ]);
    });

    test('健康检查异常不泄露原始错误且可继续降级', () async {
      final broken = _provider(
        'broken',
        healthCheckError: StateError('sensitive-provider-detail'),
      );
      final fallback = _provider('fallback');
      final decision = await _router([
        _registration(broken, priority: 10),
        _registration(fallback),
      ]).route(_request(), _offlineContext);

      expect(decision.status, ModelRouteStatus.selected);
      expect(decision.selected!.providerKey, 'fallback');
      expect(
        decision.attempts.first.reason,
        isNot(contains('sensitive-provider-detail')),
      );
    });

    test('全部合规 Provider 失败时返回 providerUnavailable', () async {
      final unhealthy = _provider('unhealthy', healthy: false);
      final decision = await _router([
        _registration(unhealthy),
      ]).route(_request(), _offlineContext);

      expect(decision.status, ModelRouteStatus.providerUnavailable);
      expect(unhealthy.healthCheckCount, 1);
    });

    test('已取消请求不会访问 Provider', () async {
      final provider = _provider('local');
      final token = ModelCancellationToken()..cancel();
      final decision = await _router([
        _registration(provider),
      ]).route(_request(cancellationToken: token), _offlineContext);

      expect(decision.status, ModelRouteStatus.cancelled);
      expect(provider.healthCheckCount, 0);
    });
  });

  test('Fake Provider 可生成确定性响应并分类取消错误', () async {
    final provider = _provider('local');
    final response = await provider.generate(_request());
    final token = ModelCancellationToken()..cancel();

    expect(response.text, 'fake:request-001');
    expect(provider.generateCount, 1);
    await expectLater(
      provider.generate(_request(cancellationToken: token)),
      throwsA(
        isA<ModelProviderException>().having(
          (error) => error.kind,
          'kind',
          ModelProviderFailureKind.cancelled,
        ),
      ),
    );
  });
}

final _offlineContext = ModelRoutingContext(
  networkEnabled: false,
  availableQuotaUnits: 0,
);

final _onlineContext = ModelRoutingContext(
  networkEnabled: true,
  availableQuotaUnits: 10,
);

ModelRouter _router(List<ProviderRegistration> registrations) {
  return ModelRouter(ModelRegistry(registrations: registrations));
}

ProviderRegistration _registration(
  FakeModelProvider provider, {
  int priority = 0,
  bool metered = false,
}) {
  return ProviderRegistration(
    provider: provider,
    modelId: 'configured-${provider.descriptor.providerKey}',
    priority: priority,
    metered: metered,
  );
}

FakeModelProvider _provider(
  String key, {
  ProviderLocation location = ProviderLocation.local,
  Set<ModelCapability> capabilities = const {ModelCapability.textGeneration},
  bool healthy = true,
  Object? healthCheckError,
}) {
  return FakeModelProvider(
    descriptor: ProviderDescriptor(
      providerKey: key,
      location: location,
      capabilities: capabilities,
    ),
    healthy: healthy,
    healthCheckError: healthCheckError,
  );
}

ModelRequest _request({
  Map<String, Object?> input = const {'prompt': '检查简历'},
  Set<ModelCapability> capabilities = const {ModelCapability.textGeneration},
  List<ToolDescriptor> tools = const [],
  ModelPrivacyPolicy privacy = ModelPrivacyPolicy.localOnly,
  int estimatedQuotaUnits = 1,
  ModelCancellationToken? cancellationToken,
}) {
  return ModelRequest(
    requestId: 'request-001',
    taskType: ModelTaskType.analysis,
    input: input,
    requiredCapabilities: capabilities,
    tools: tools,
    contextBudgetTokens: 2048,
    estimatedQuotaUnits: estimatedQuotaUnits,
    privacyPolicy: privacy,
    cancellationToken: cancellationToken,
  );
}

ToolDescriptor _toolDescriptor() {
  return ToolDescriptor(
    name: 'read_resume',
    version: currentAgentProtocolVersion,
    inputSchema: const {'type': 'object'},
    outputSchema: const {'type': 'object'},
    permission: ToolPermission.resumeRead,
    access: ToolAccess.read,
    usesNetwork: false,
    retryable: true,
    timeoutMs: 5000,
    auditFields: const ['toolName'],
  );
}
