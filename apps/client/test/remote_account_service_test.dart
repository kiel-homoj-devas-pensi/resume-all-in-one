import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';

void main() {
  final currentTime = DateTime.utc(2026, 10, 3, 12);
  const validPhone = '+15550001234';
  const validPassword = 'TestPass2026!';

  test('注册后自动登录并以服务端三项访问决策组成套餐快照', () async {
    final gatewayApi = _FakeGatewayApi(
      plan: GatewaySubscriptionPlan.free,
      remainingBasicGenerations: 9,
    );
    final accountService = RemoteAccountService(
      gatewayApi: gatewayApi,
      clock: () => currentTime,
    );

    await accountService.registerAndSignIn(
      phoneE164: validPhone,
      password: validPassword,
    );

    expect(gatewayApi.registerCallCount, 1);
    expect(gatewayApi.sessionCallCount, 1);
    expect(gatewayApi.accessCallCount, 3);
    expect(accountService.snapshot.isSignedIn, isTrue);
    expect(accountService.snapshot.maskedPhone, '+155****1234');
    expect(accountService.snapshot.plan, GatewaySubscriptionPlan.free);
    expect(
      accountService
          .snapshot
          .accessByCapability[RemoteAiCapability.basicResumeCompose]
          ?.remainingMonthlyBasicGenerations,
      9,
    );
  });

  test('真实手机号和过短密码在任何 Gateway 请求前被拒绝', () async {
    final gatewayApi = _FakeGatewayApi();
    final accountService = RemoteAccountService(gatewayApi: gatewayApi);

    await expectLater(
      accountService.signIn(
        phoneE164: '+8613800138000',
        password: validPassword,
      ),
      throwsA(isA<RemoteAccountInputException>()),
    );
    await expectLater(
      accountService.signIn(phoneE164: validPhone, password: 'too-short'),
      throwsA(isA<RemoteAccountInputException>()),
    );

    expect(gatewayApi.sessionCallCount, 0);
  });

  test('退出本机登录后 token 不再可用于远程请求', () async {
    final gatewayApi = _FakeGatewayApi();
    final accountService = RemoteAccountService(
      gatewayApi: gatewayApi,
      clock: () => currentTime,
    );
    await accountService.signIn(phoneE164: validPhone, password: validPassword);

    accountService.signOutLocally();

    expect(
      accountService.snapshot.status,
      RemoteAccountSessionStatus.signedOut,
    );
    expect(
      () => accountService.submitRemoteAiRequest(
        clientRequestId: 'client-request-001',
        idempotencyKey: 'idempotency-001',
        capability: RemoteAiCapability.basicResumeCompose,
        input: const {},
      ),
      throwsA(
        isA<GatewayApiException>().having(
          (error) => error.code,
          'code',
          'unauthenticated',
        ),
      ),
    );
  });

  test('三项能力返回不同套餐时拒绝建立不一致快照', () async {
    final gatewayApi = _FakeGatewayApi(inconsistentPlan: true);
    final accountService = RemoteAccountService(
      gatewayApi: gatewayApi,
      clock: () => currentTime,
    );

    await expectLater(
      accountService.signIn(phoneE164: validPhone, password: validPassword),
      throwsA(
        isA<GatewayApiException>().having(
          (error) => error.code,
          'code',
          'invalid_gateway_response',
        ),
      ),
    );
    expect(
      accountService.snapshot.status,
      RemoteAccountSessionStatus.signedOut,
    );
  });

  test('未配置 Gateway 时保持明确的不可用状态', () async {
    final accountService = RemoteAccountService(gatewayApi: null);

    expect(
      accountService.snapshot.status,
      RemoteAccountSessionStatus.gatewayUnavailable,
    );
    await expectLater(
      accountService.signIn(phoneE164: validPhone, password: validPassword),
      throwsA(
        isA<GatewayApiException>().having(
          (error) => error.code,
          'code',
          'gateway_not_configured',
        ),
      ),
    );
  });
}

final class _FakeGatewayApi implements GatewayApi {
  _FakeGatewayApi({
    this.plan = GatewaySubscriptionPlan.pro,
    this.remainingBasicGenerations,
    this.inconsistentPlan = false,
  });

  final GatewaySubscriptionPlan plan;
  final int? remainingBasicGenerations;
  final bool inconsistentPlan;
  int registerCallCount = 0;
  int sessionCallCount = 0;
  int accessCallCount = 0;

  @override
  Future<void> registerFakeAccount({
    required String phoneE164,
    required String password,
  }) async {
    registerCallCount++;
  }

  @override
  Future<GatewaySession> createSession({
    required String phoneE164,
    required String password,
  }) async {
    sessionCallCount++;
    return GatewaySession(
      token: 'session-token',
      expiresAtUtc: DateTime.utc(2026, 11, 2, 12),
    );
  }

  @override
  Future<GatewayAccessSnapshot> readAccess({
    required RemoteAiCapability capability,
    required String sessionToken,
  }) async {
    accessCallCount++;
    final snapshotPlan =
        inconsistentPlan &&
            capability == RemoteAiCapability.resumeOptimizationConversation
        ? GatewaySubscriptionPlan.free
        : plan;
    return GatewayAccessSnapshot(
      capability: capability,
      plan: snapshotPlan,
      allowed:
          snapshotPlan == GatewaySubscriptionPlan.pro ||
          capability == RemoteAiCapability.basicResumeCompose,
      reason: 'allowed',
      remainingMonthlyBasicGenerations:
          capability == RemoteAiCapability.basicResumeCompose
          ? remainingBasicGenerations
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
    return GatewayRemoteAiResponse(
      operationId: 'operation-001',
      clientRequestId: clientRequestId,
      capability: capability,
      output: const {'outputVersion': 'basicResumeCompose.v1'},
      promptVersion: 'prompt.v1',
    );
  }

  @override
  void close() {}
}
